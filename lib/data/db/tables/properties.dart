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

/// Verknüpfungen zwischen Entries (Wikilinks UND manuelle Links)
class EntryLinks extends Table {
  @ReferenceName('outgoingLinks')
  TextColumn get fromId =>
      text().references(Entries, #id, onDelete: KeyAction.cascade)();
  @ReferenceName('incomingLinks')
  TextColumn get toId =>
      text().references(Entries, #id, onDelete: KeyAction.cascade)();

  /// true = manuell verknüpft (bleibt bei Body-Edits erhalten);
  /// false = aus [[Wikilink]] abgeleitet (wird beim Reparse ersetzt).
  BoolColumn get manual => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {fromId, toId};
}
