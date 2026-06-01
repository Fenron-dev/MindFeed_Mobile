import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../data/db/app_database.dart';

class BackupResult {
  final String path;
  final String filename;
  final int sizeBytes;
  final DateTime createdAt;

  const BackupResult({
    required this.path,
    required this.filename,
    required this.sizeBytes,
    required this.createdAt,
  });

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class BackupService {
  static Future<String> _vaultRoot() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'MindFeed', 'default');
  }

  // ─── Backup erstellen ──────────────────────────────────────────────────────

  static Future<BackupResult> createBackup(AppDatabase db) async {
    // WAL vollständig in Hauptdatei schreiben bevor wir kopieren
    // → Backup enthält konsistenten Snapshot, kein WAL nötig
    await db.customStatement('PRAGMA wal_checkpoint(FULL)');

    final root = await _vaultRoot();
    final dbPath = p.join(root, 'mindfeed.db');
    final backupsDir = Directory(p.join(root, 'backups'));
    await backupsDir.create(recursive: true);

    final ts = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
    final zipPath = p.join(backupsDir.path, 'mindfeed_$ts.zip');

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    // Nur Hauptdatei — nach FULL checkpoint sind alle Daten drin
    if (File(dbPath).existsSync()) {
      encoder.addFile(File(dbPath), 'mindfeed.db');
    }

    // Anhänge
    final attachmentsDir = Directory(p.join(root, 'attachments'));
    if (attachmentsDir.existsSync()) {
      await for (final entity
          in attachmentsDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final rel = p.relative(entity.path, from: root);
          encoder.addFile(entity, rel);
        }
      }
    }

    encoder.close();

    final file = File(zipPath);
    return BackupResult(
      path: zipPath,
      filename: p.basename(zipPath),
      sizeBytes: file.lengthSync(),
      createdAt: DateTime.now(),
    );
  }

  // ─── Backup teilen ────────────────────────────────────────────────────────

  static Future<void> shareBackup(BackupResult backup) async {
    await Share.shareXFiles(
      [XFile(backup.path, mimeType: 'application/zip')],
      subject: 'MindFeed Backup ${backup.filename}',
    );
  }

  // ─── Backup wiederherstellen ──────────────────────────────────────────────

  /// Stellt ein Backup wieder her.
  /// Reihenfolge: Temp-Extraktion → DB schließen → atomar umbenennen → WAL löschen
  /// So wird verhindert dass _launchApp() eine halb-geschriebene DB öffnet.
  static Future<void> restore(
      String zipPath, AppDatabase currentDb) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Validierung
    final dbEntry = archive.findFile('mindfeed.db');
    if (dbEntry == null) {
      throw Exception('Ungültige Backup-Datei: mindfeed.db nicht gefunden.');
    }

    final root = await _vaultRoot();
    final dbPath = p.join(root, 'mindfeed.db');
    final tempDbPath = p.join(root, 'mindfeed_restore.db');

    // 1. DB-Datei zuerst in TEMP schreiben (DB läuft noch)
    await File(tempDbPath).writeAsBytes(dbEntry.content as List<int>);

    // 2. Anhänge in korrekten Pfad schreiben (bevor DB geschlossen wird)
    for (final file in archive) {
      if (!file.isFile || file.name == 'mindfeed.db') continue;
      final target = File(p.join(root, file.name));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.content as List<int>);
    }

    // 3. Jetzt erst DB schließen (alle Dateien sind bereits auf Disk)
    await currentDb.close();

    // 4. Temp-Datei atomar in echten DB-Pfad verschieben
    if (await File(tempDbPath).exists()) {
      await File(tempDbPath).rename(dbPath);
    }

    // 5. WAL + SHM löschen → neue DB startet sauber ohne Konflikte
    for (final ext in ['-wal', '-shm']) {
      final f = File('$dbPath$ext');
      if (await f.exists()) await f.delete();
    }
  }

  // ─── Lokale Backups auflisten ─────────────────────────────────────────────

  static Future<List<BackupResult>> listLocalBackups() async {
    final root = await _vaultRoot();
    final dir = Directory(p.join(root, 'backups'));
    if (!dir.existsSync()) return [];

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.zip'))
        .toList();

    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    return files.map((f) => BackupResult(
          path: f.path,
          filename: p.basename(f.path),
          sizeBytes: f.lengthSync(),
          createdAt: f.statSync().modified,
        )).toList();
  }

  // ─── Lokales Backup löschen ───────────────────────────────────────────────

  static Future<void> deleteBackup(String path) =>
      File(path).delete();
}
