import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../data/db/app_database.dart';

class VaultManager {
  /// Öffnet den Standard-Vault (oder legt ihn an).
  /// Erstellt die nötigen Unterordner und Seed-Daten beim ersten Start.
  static Future<AppDatabase> openDefaultVault() async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(dir.path, 'MindFeed', 'default'));
    await vaultDir.create(recursive: true);
    await Directory(p.join(vaultDir.path, 'attachments')).create(recursive: true);
    await Directory(p.join(vaultDir.path, 'backups')).create(recursive: true);

    final dbPath = p.join(vaultDir.path, 'mindfeed.db');
    final db = AppDatabase(dbPath);

    // Beim ersten Start Standard-Container anlegen
    await _seedIfEmpty(db);

    return db;
  }

  static Future<void> _seedIfEmpty(AppDatabase db) async {
    final existing = await db.containerDao.watchAll().first;
    if (existing.isNotEmpty) return;

    final now = DateTime.now().toUtc();
    final seeds = [
      ContainersCompanion(
        id: const Value('c-area-persoenlich'),
        kind: const Value('area'),
        name: const Value('Persönlich'),
        icon: const Value('compass'),
        color: const Value('#14B8A6'),
        createdAt: Value(now),
        archived: const Value(false),
      ),
      ContainersCompanion(
        id: const Value('c-hub-links'),
        kind: const Value('hub'),
        name: const Value('Links'),
        icon: const Value('link'),
        color: const Value('#3B82F6'),
        filterType: const Value('link'),
        createdAt: Value(now),
        archived: const Value(false),
      ),
      ContainersCompanion(
        id: const Value('c-hub-inbox'),
        kind: const Value('hub'),
        name: const Value('Inbox'),
        icon: const Value('inbox'),
        color: const Value('#6366F1'),
        filterStatus: const Value('inbox'),
        createdAt: Value(now),
        archived: const Value(false),
      ),
    ];

    for (final s in seeds) {
      await db.containerDao.upsert(s);
    }
  }

  static Future<String> getAttachmentsPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'MindFeed', 'default', 'attachments');
  }
}
