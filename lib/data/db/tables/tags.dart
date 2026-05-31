import 'package:drift/drift.dart';
import 'entries.dart';

/// Hierarchische Tags: "buch/sachbuch/psychologie"
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()(); // Voller Pfad: "buch/sachbuch"
  TextColumn get parentId => text().nullable()();
  TextColumn get color => text().nullable()();
  TextColumn get icon => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// n:m — Entry ↔ Tag
class EntryTags extends Table {
  TextColumn get entryId =>
      text().references(Entries, #id, onDelete: KeyAction.cascade)();
  TextColumn get tagId =>
      text().references(Tags, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {entryId, tagId};
}
