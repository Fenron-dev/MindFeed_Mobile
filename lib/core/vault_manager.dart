import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../data/db/app_database.dart';

class VaultManager {
  /// Öffnet den Standard-Vault (oder legt ihn an).
  /// Erstellt die nötigen Unterordner (attachments, backups).
  static Future<AppDatabase> openDefaultVault() async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(dir.path, 'MindFeed', 'default'));
    await vaultDir.create(recursive: true);
    await Directory(p.join(vaultDir.path, 'attachments')).create(recursive: true);
    await Directory(p.join(vaultDir.path, 'backups')).create(recursive: true);

    final dbPath = p.join(vaultDir.path, 'mindfeed.db');
    return AppDatabase(dbPath);
  }

  /// Pfad zum attachments-Ordner des aktiven Vaults.
  static Future<String> getAttachmentsPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'MindFeed', 'default', 'attachments');
  }
}
