import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../data/db/app_database.dart';
import '../services/app_settings.dart';

class VaultManager {
  // ─── Standard-Vault ────────────────────────────────────────────────────────

  /// Öffnet den Standard-Vault (oder legt ihn an).
  static Future<AppDatabase> openDefaultVault() async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(dir.path, 'MindFeed', 'default'));
    return _openAt(vaultDir.path, seedIfEmpty: true);
  }

  // ─── Custom-Vault (OracleVault-Ansatz) ────────────────────────────────────

  /// Öffnet einen Vault an einem beliebigen Pfad.
  /// Erstellt die nötigen Unterordner, legt aber KEINE Seed-Daten an
  /// (da der Vault bereits Daten enthält).
  static Future<AppDatabase> openVaultFromPath(String vaultPath) async {
    return _openAt(vaultPath, seedIfEmpty: false);
  }

  /// Gibt true zurück, wenn [path] ein gültiger MindFeed-Vault ist
  /// (enthält mindfeed.db).
  static bool isVault(String path) =>
      File(p.join(path, 'mindfeed.db')).existsSync();

  /// Liefert den gespeicherten Custom-Vault-Pfad (oder null).
  static String? getSavedVaultPath() => AppSettings.getVaultPath();

  /// Speichert [path] als Custom-Vault-Pfad.
  /// null löscht den Eintrag (→ Default-Vault wird wieder verwendet).
  static Future<void> saveVaultPath(String? path) =>
      AppSettings.saveVaultPath(path);

  // ─── Intern ────────────────────────────────────────────────────────────────

  static Future<AppDatabase> _openAt(
    String vaultPath, {
    required bool seedIfEmpty,
  }) async {
    await Directory(vaultPath).create(recursive: true);
    await Directory(p.join(vaultPath, 'attachments')).create(recursive: true);
    await Directory(p.join(vaultPath, 'backups')).create(recursive: true);

    final dbPath = p.join(vaultPath, 'mindfeed.db');
    final db = AppDatabase(dbPath);

    if (seedIfEmpty) await _seedIfEmpty(db);
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

  /// Gibt den Anhang-Pfad für den aktiven Vault zurück.
  static Future<String> getAttachmentsPath() async {
    final saved = getSavedVaultPath();
    if (saved != null && isVault(saved)) {
      return p.join(saved, 'attachments');
    }
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'MindFeed', 'default', 'attachments');
  }
}
