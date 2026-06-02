import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../data/db/app_database.dart';
import 'app_settings.dart';

// ─── Backup / Restore ────────────────────────────────────────────────────────
//
// Strategie: JSON-basiertes Import/Export — die DB wird NIEMALS geschlossen.
// Restore schreibt direkt in die laufende Drift-DB (Transaktion).
// Drift-StreamProvider aktualisieren sich automatisch → kein Neustart nötig.
//
// ZIP-Backup enthält data.json + alle Anhangsdateien (attachments/*).
// JSON-Backup enthält nur die Metadaten (ohne Dateien).

const int _kBackupVersion = 2;

class BackupService {
  static Future<String> _vaultRoot() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'MindFeed', 'default');
  }

  // ─── Serialisierung ────────────────────────────────────────────────────────

  static Map<String, dynamic> _serEntry(Entry e) => {
        'id': e.id,
        'createdAt': e.createdAt.toIso8601String(),
        'updatedAt': e.updatedAt.toIso8601String(),
        'type': e.type,
        'title': e.title,
        'body': e.body,
        'status': e.status,
        'pinned': e.pinned,
        'geoLat': e.geoLat,
        'geoLng': e.geoLng,
        'reminderAt': e.reminderAt?.toIso8601String(),
        'sourceUrl': e.sourceUrl,
        'sourceApp': e.sourceApp,
        'lang': e.lang,
        'aiEnrichedAt': e.aiEnrichedAt?.toIso8601String(),
      };

  static Map<String, dynamic> _serContainer(Container c) => {
        'id': c.id,
        'kind': c.kind,
        'name': c.name,
        'description': c.description,
        'icon': c.icon,
        'color': c.color,
        'createdAt': c.createdAt.toIso8601String(),
        'archived': c.archived,
        'filterTag': c.filterTag,
        'filterStatus': c.filterStatus,
        'filterType': c.filterType,
        'sortOrder': c.sortOrder,
        'viewMode': c.viewMode,
        'parentId': c.parentId,
      };

  static Map<String, dynamic> _serAttachment(Attachment a) => {
        'id': a.id,
        'entryId': a.entryId,
        'type': a.type,
        'mimeType': a.mimeType,
        'localPath': a.localPath,
        'fileName': a.fileName,
        'fileSize': a.fileSize,
        'durationMs': a.durationMs,
        'ocrText': a.ocrText,
        'transcription': a.transcription,
        'createdAt': a.createdAt.toIso8601String(),
      };

  // ─── Alle Tabellen → Map ───────────────────────────────────────────────────

  static Future<Map<String, dynamic>> _buildMap(AppDatabase db) async {
    final entries = await db.select(db.entries).get();
    final tags = await db.select(db.tags).get();
    final entryTagRows = await db.select(db.entryTags).get();
    final containers = await db.select(db.containers).get();
    final entryContainerRows = await db.select(db.entryContainers).get();
    final properties = await db.select(db.entryProperties).get();
    final links = await db.select(db.entryLinks).get();
    final attachments = await db.select(db.attachments).get();

    return {
      'version': _kBackupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': AppSettings.exportSettings(),
      'entries': entries.map(_serEntry).toList(),
      'tags': tags
          .map((t) => {
                'id': t.id,
                'name': t.name,
                'parentId': t.parentId,
                'color': t.color,
                'icon': t.icon,
              })
          .toList(),
      'entryTags': entryTagRows
          .map((et) => {'entryId': et.entryId, 'tagId': et.tagId})
          .toList(),
      'containers': containers.map(_serContainer).toList(),
      'entryContainers': entryContainerRows
          .map((ec) => {'entryId': ec.entryId, 'containerId': ec.containerId})
          .toList(),
      'properties': properties
          .map((p) => {
                'id': p.id,
                'entryId': p.entryId,
                'key': p.key,
                'value': p.value,
                'type': p.type,
              })
          .toList(),
      'links': links
          .map((l) => {'fromId': l.fromId, 'toId': l.toId})
          .toList(),
      'attachments': attachments.map(_serAttachment).toList(),
    };
  }

  // ─── JSON exportieren & teilen ────────────────────────────────────────────

  static Future<void> shareJson(AppDatabase db) async {
    final map = await _buildMap(db);
    final json = const JsonEncoder.withIndent('  ').convert(map);
    final dateStr = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'mindfeed_$dateStr.json'));
    await file.writeAsString(json, encoding: utf8);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      subject: 'MindFeed Backup $dateStr',
    );
  }

  // ─── ZIP erstellen (JSON + Anhänge) ───────────────────────────────────────

  static Future<BackupResult> createZipBackup(AppDatabase db) async {
    await db.customStatement('PRAGMA wal_checkpoint(FULL)');

    final root = await _vaultRoot();
    final map = await _buildMap(db);
    final json = const JsonEncoder.withIndent('  ').convert(map);

    final backupsDir = Directory(p.join(root, 'backups'));
    await backupsDir.create(recursive: true);
    final ts = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
    final zipPath = p.join(backupsDir.path, 'mindfeed_$ts.zip');

    // JSON-Datei temporär schreiben, dann in ZIP packen
    final tmpJson = File(p.join(root, '_tmp_data.json'));
    await tmpJson.writeAsString(json, encoding: utf8);

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    encoder.addFile(tmpJson, 'data.json');

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
    if (await tmpJson.exists()) await tmpJson.delete();

    final file = File(zipPath);
    return BackupResult(
      path: zipPath,
      filename: p.basename(zipPath),
      sizeBytes: file.lengthSync(),
      createdAt: DateTime.now(),
    );
  }

  static Future<void> shareBackup(BackupResult backup) async {
    await Share.shareXFiles(
      [XFile(backup.path, mimeType: 'application/zip')],
      subject: 'MindFeed Backup',
    );
  }

  // ─── JSON aus Datei importieren ───────────────────────────────────────────

  static Future<ImportResult> importFromPicker(AppDatabase db) async {
    // withData: false vermeidet iOS-Freeze bei Cloud-Dateien.
    // Wir lesen die Datei danach selbst über den Pfad.
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'zip'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return ImportResult.cancelled();

    final file = picked.files.single;
    final path = file.path;
    if (path == null) return ImportResult.error('Datei-Pfad nicht verfügbar');

    final isZip = file.name.toLowerCase().endsWith('.zip');

    if (isZip) {
      return restoreFromZip(path, db);
    }

    // JSON
    try {
      final raw = await File(path).readAsString();
      return _importJsonString(db, raw);
    } catch (_) {
      return ImportResult.error('Datei konnte nicht gelesen werden');
    }
  }

  // ─── ZIP wiederherstellen (kein DB-Neustart!) ─────────────────────────────

  static Future<ImportResult> restoreFromZip(
      String zipPath, AppDatabase db) async {
    try {
      return _restoreFromZipBytes(
          await File(zipPath).readAsBytes(), db);
    } catch (e) {
      return ImportResult.error('ZIP-Lesefehler: $e');
    }
  }

  static Future<ImportResult> _restoreFromZipBytes(
      List<int> zipBytes, AppDatabase db) async {
    try {
      final archive = ZipDecoder().decodeBytes(zipBytes);

      // ── Neues Format: data.json + attachments/* ──────────────────────────
      final jsonEntry = archive.findFile('data.json');
      if (jsonEntry != null) {
        final root = await _vaultRoot();
        final raw = utf8.decode(jsonEntry.content as List<int>);
        final result = await _importJsonString(db, raw);
        if (!result.isSuccess) return result;
        for (final f in archive) {
          if (!f.isFile || f.name == 'data.json') continue;
          final target = File(p.join(root, f.name));
          await target.parent.create(recursive: true);
          await target.writeAsBytes(f.content as List<int>);
        }
        return result;
      }

      // ── Altes Format: mindfeed.db → Temp-DB öffnen, Daten lesen ─────────
      final dbEntry = archive.findFile('mindfeed.db');
      if (dbEntry != null) {
        return await _restoreFromLegacyDb(archive, db);
      }

      return ImportResult.error('Unbekanntes Backup-Format (kein data.json / mindfeed.db)');
    } catch (e) {
      return ImportResult.error('ZIP-Fehler: $e');
    }
  }

  /// Liest Daten aus einem alten Backup (ZIP mit mindfeed.db) und importiert
  /// sie in die laufende DB. Schließt die laufende DB NICHT.
  static Future<ImportResult> _restoreFromLegacyDb(
      Archive archive, AppDatabase db) async {
    final root = await _vaultRoot();
    final tempPath = p.join(root, '_restore_legacy.db');
    AppDatabase? tempDb;
    try {
      // SQLite-Datei aus ZIP in temporären Pfad schreiben
      final dbEntry = archive.findFile('mindfeed.db')!;
      await File(tempPath).writeAsBytes(dbEntry.content as List<int>);

      // WAL-Checkpoint erzwingen damit alle Daten in der .db-Datei sind
      tempDb = AppDatabase(tempPath);
      await tempDb.customStatement('PRAGMA wal_checkpoint(FULL)');

      // Alle Tabellen aus der Temp-DB lesen
      final map = await _buildMap(tempDb);
      await tempDb.close();
      tempDb = null;

      // In die laufende DB importieren
      final result = await _importJsonString(
          db, const JsonEncoder().convert(map));

      // Anhänge aus ZIP in Vault kopieren
      if (result.isSuccess) {
        for (final f in archive) {
          if (!f.isFile || f.name.startsWith('mindfeed.db')) continue;
          final target = File(p.join(root, f.name));
          await target.parent.create(recursive: true);
          await target.writeAsBytes(f.content as List<int>);
        }
      }
      return result;
    } catch (e) {
      return ImportResult.error('Legacy-Import fehlgeschlagen: $e');
    } finally {
      try { await tempDb?.close(); } catch (_) {}
      for (final ext in ['', '-wal', '-shm']) {
        try { await File('$tempPath$ext').delete(); } catch (_) {}
      }
    }
  }

  // ─── JSON-String in laufende DB importieren ───────────────────────────────

  static Future<ImportResult> importFromJsonString(
          AppDatabase db, String raw) =>
      _importJsonString(db, raw);

  static Future<ImportResult> _importJsonString(
      AppDatabase db, String raw) async {
    final Map<String, dynamic> backup;
    try {
      backup = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return ImportResult.error('Ungültige JSON-Datei');
    }

    final version = backup['version'] as int? ?? 0;
    if (version < 1 || version > _kBackupVersion) {
      return ImportResult.error('Unbekanntes Format (Version $version)');
    }

    try {
      await db.transaction(() async {
        // Kinder zuerst löschen (FK-Reihenfolge)
        await db.delete(db.entryTags).go();
        await db.delete(db.entryContainers).go();
        await db.delete(db.entryLinks).go();
        await db.delete(db.entryProperties).go();
        await db.delete(db.attachments).go();
        await db.delete(db.entries).go();
        await db.delete(db.tags).go();
        await db.delete(db.containers).go();

        // Eltern zuerst einfügen (insertOrReplace: idempotent)
        for (final e in (backup['entries'] as List? ?? [])) {
          await db.into(db.entries)
              .insertOnConflictUpdate(_deserEntry(e));
        }
        for (final t in (backup['tags'] as List? ?? [])) {
          await db.into(db.tags).insertOnConflictUpdate(TagsCompanion(
            id: Value(t['id'] as String),
            name: Value(t['name'] as String),
            parentId: Value(t['parentId'] as String?),
            color: Value(t['color'] as String?),
            icon: Value(t['icon'] as String?),
          ));
        }
        for (final c in (backup['containers'] as List? ?? [])) {
          await db.into(db.containers)
              .insertOnConflictUpdate(_deserContainer(c));
        }

        // Kinder einfügen
        for (final et in (backup['entryTags'] as List? ?? [])) {
          await db.into(db.entryTags).insertOnConflictUpdate(EntryTagsCompanion(
            entryId: Value(et['entryId'] as String),
            tagId: Value(et['tagId'] as String),
          ));
        }
        for (final ec in (backup['entryContainers'] as List? ?? [])) {
          await db.into(db.entryContainers)
              .insertOnConflictUpdate(EntryContainersCompanion(
            entryId: Value(ec['entryId'] as String),
            containerId: Value(ec['containerId'] as String),
          ));
        }
        for (final l in (backup['links'] as List? ?? [])) {
          await db.into(db.entryLinks).insertOnConflictUpdate(EntryLinksCompanion(
            fromId: Value(l['fromId'] as String),
            toId: Value(l['toId'] as String),
          ));
        }
        for (final pr in (backup['properties'] as List? ?? [])) {
          await db.into(db.entryProperties)
              .insertOnConflictUpdate(EntryPropertiesCompanion(
            id: Value(pr['id'] as String),
            entryId: Value(pr['entryId'] as String),
            key: Value(pr['key'] as String),
            value: Value(pr['value'] as String?),
            type: Value(pr['type'] as String? ?? 'text'),
          ));
        }
        for (final a in (backup['attachments'] as List? ?? [])) {
          await db.into(db.attachments)
              .insertOnConflictUpdate(_deserAttachment(a));
        }
      });

      final count = (backup['entries'] as List?)?.length ?? 0;

      // Einstellungen wiederherstellen (Templates, Tag-Stil, API-Felder, …)
      final settings = backup['settings'] as Map<String, dynamic>?;
      if (settings != null) {
        await AppSettings.importSettings(settings);
      }

      return ImportResult.success(count);
    } catch (e) {
      return ImportResult.error('Import-Fehler: $e');
    }
  }

  // ─── Deserialisierung ──────────────────────────────────────────────────────

  static EntriesCompanion _deserEntry(Map<String, dynamic> e) =>
      EntriesCompanion(
        id: Value(e['id'] as String),
        createdAt: Value(_dt(e['createdAt'])),
        updatedAt: Value(_dt(e['updatedAt'])),
        type: Value(e['type'] as String? ?? 'text'),
        title: Value(e['title'] as String?),
        body: Value(e['body'] as String? ?? ''),
        status: Value(e['status'] as String? ?? 'inbox'),
        pinned: Value(e['pinned'] as bool? ?? false),
        geoLat: Value((e['geoLat'] as num?)?.toDouble()),
        geoLng: Value((e['geoLng'] as num?)?.toDouble()),
        reminderAt: Value(_dtOpt(e['reminderAt'])),
        sourceUrl: Value(e['sourceUrl'] as String?),
        sourceApp: Value(e['sourceApp'] as String?),
        lang: Value(e['lang'] as String?),
        aiEnrichedAt: Value(_dtOpt(e['aiEnrichedAt'])),
      );

  static ContainersCompanion _deserContainer(Map<String, dynamic> c) =>
      ContainersCompanion(
        id: Value(c['id'] as String),
        kind: Value(c['kind'] as String? ?? 'project'),
        name: Value(c['name'] as String),
        description: Value(c['description'] as String?),
        icon: Value(c['icon'] as String? ?? 'folder'),
        color: Value(c['color'] as String? ?? '#14B8A6'),
        createdAt: Value(_dt(c['createdAt'])),
        archived: Value(c['archived'] as bool? ?? false),
        filterTag: Value(c['filterTag'] as String?),
        filterStatus: Value(c['filterStatus'] as String?),
        filterType: Value(c['filterType'] as String?),
        sortOrder: Value(c['sortOrder'] as String? ?? 'desc'),
        viewMode: Value(c['viewMode'] as String? ?? 'list'),
        parentId: Value(c['parentId'] as String?),
      );

  static AttachmentsCompanion _deserAttachment(Map<String, dynamic> a) =>
      AttachmentsCompanion(
        id: Value(a['id'] as String),
        entryId: Value(a['entryId'] as String),
        type: Value(a['type'] as String),
        mimeType: Value(a['mimeType'] as String),
        localPath: Value(a['localPath'] as String),
        fileName: Value(a['fileName'] as String),
        fileSize: Value(a['fileSize'] as int? ?? 0),
        durationMs: Value(a['durationMs'] as int?),
        ocrText: Value(a['ocrText'] as String?),
        transcription: Value(a['transcription'] as String?),
        createdAt: Value(_dt(a['createdAt'])),
      );

  static DateTime _dt(dynamic v) =>
      DateTime.tryParse(v as String? ?? '') ?? DateTime.now().toUtc();
  static DateTime? _dtOpt(dynamic v) =>
      v == null ? null : DateTime.tryParse(v as String);

  // ─── Lokale Backups ────────────────────────────────────────────────────────

  static Future<BackupResult> saveToDir(
      AppDatabase db, String dirPath) async {
    await Directory(dirPath).create(recursive: true);
    final map = await _buildMap(db);
    final json = const JsonEncoder.withIndent('  ').convert(map);
    final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final file = File(p.join(dirPath, 'mindfeed_backup_$dateStr.json'));
    await file.writeAsString(json, encoding: utf8);

    // Alte Backups bereinigen (> 7 Tage)
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await for (final entity in Directory(dirPath).list()) {
        if (entity is File &&
            entity.path.contains('mindfeed_backup_') &&
            (entity.path.endsWith('.json') ||
                entity.path.endsWith('.zip'))) {
          if ((await entity.stat()).modified.isBefore(cutoff)) {
            await entity.delete();
          }
        }
      }
    } catch (_) {}

    return BackupResult(
      path: file.path,
      filename: p.basename(file.path),
      sizeBytes: file.lengthSync(),
      createdAt: DateTime.now(),
    );
  }

  static Future<List<BackupResult>> listLocalBackups() async {
    final root = await _vaultRoot();
    final dir = Directory(p.join(root, 'backups'));
    if (!dir.existsSync()) return [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.zip') || f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) =>
          b.statSync().modified.compareTo(a.statSync().modified));
    return files
        .map((f) => BackupResult(
              path: f.path,
              filename: p.basename(f.path),
              sizeBytes: f.lengthSync(),
              createdAt: f.statSync().modified,
            ))
        .toList();
  }

  static Future<void> deleteBackup(String path) => File(path).delete();
}

// ─── Ergebnistypen ────────────────────────────────────────────────────────────

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
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class ImportResult {
  final bool cancelled;
  final String? error;
  final int entryCount;

  ImportResult._({this.cancelled = false, this.error, this.entryCount = 0});

  factory ImportResult.cancelled() => ImportResult._();
  factory ImportResult.error(String e) => ImportResult._(error: e);
  factory ImportResult.success(int count) =>
      ImportResult._(entryCount: count);

  bool get isSuccess => !cancelled && error == null;
}
