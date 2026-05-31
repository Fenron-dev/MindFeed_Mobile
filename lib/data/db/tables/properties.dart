import 'package:drift/drift.dart';
import 'entries.dart';

/// EAV: Frei definierbare Properties pro Entry
/// Typ-Enum: text | number | date | boolean | url | tags | select | rating
class EntryProperties extends Table {
  TextColumn get id => text()();
  TextColumn get entryId =>
      text().references(Entries, #id, onDelete: KeyAction.cascade)();
  TextColumn get key => text()();
  TextColumn get value => text().nullable()(); // JSON-encoded
  // text | number | date | boolean | url | tags | select | rating
  TextColumn get type =>
      text().withDefault(const Constant('text'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Wikilinks zwischen Entries
class EntryLinks extends Table {
  @ReferenceName('outgoingLinks')
  TextColumn get fromId =>
      text().references(Entries, #id, onDelete: KeyAction.cascade)();
  @ReferenceName('incomingLinks')
  TextColumn get toId =>
      text().references(Entries, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {fromId, toId};
}
