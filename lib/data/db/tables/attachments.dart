import 'package:drift/drift.dart';
import 'entries.dart';

/// Anhänge: Dateien liegen im Vault/attachments/ Ordner (KEIN Base64 in DB)
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get entryId =>
      text().references(Entries, #id, onDelete: KeyAction.cascade)();

  // 'image' | 'audio' | 'video' | 'document'
  TextColumn get type => text()();
  TextColumn get mimeType => text()();

  /// Relativer Pfad ab Vault-Root: "attachments/2025/01/foto.jpg"
  TextColumn get localPath => text()();
  TextColumn get fileName => text()();
  IntColumn get fileSize => integer().withDefault(const Constant(0))();

  IntColumn get durationMs => integer().nullable()();   // Audio/Video
  TextColumn get ocrText => text().nullable()();         // ML Kit OCR
  TextColumn get transcription => text().nullable()();   // Audio → Text

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  Set<Column> get primaryKey => {id};
}
