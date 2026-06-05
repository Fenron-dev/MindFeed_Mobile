import 'package:drift/drift.dart';
import 'entries.dart';

/// Projekte / Bereiche / Smart Hubs (wie Gmail-Labels mit Unterordnern)
class Containers extends Table {
  TextColumn get id => text()();

  // 'project' | 'area' | 'hub'
  TextColumn get kind =>
      text().withDefault(const Constant('project'))();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();

  TextColumn get icon =>
      text().withDefault(const Constant('folder'))();
  TextColumn get color =>
      text().withDefault(const Constant('#14B8A6'))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  BoolColumn get archived =>
      boolean().withDefault(const Constant(false))();

  // Smart Hub filter
  TextColumn get filterTag => text().nullable()();
  TextColumn get filterStatus => text().nullable()();
  TextColumn get filterType => text().nullable()();

  // 'asc' | 'desc'
  TextColumn get sortOrder =>
      text().withDefault(const Constant('desc'))();
  // 'list' | 'cards' | 'thumbnail'
  TextColumn get viewMode =>
      text().withDefault(const Constant('list'))();

  TextColumn get parentId => text().nullable()();

  // Sync: Shadow-Version = updatedAt-Stand, der zuletzt mit dem Server
  // abgeglichen wurde. null = noch nie synchronisiert (lokal neu).
  DateTimeColumn get syncUpdatedAt => dateTime().nullable()();

  // Soft-Delete für Sync-Tombstones; null = aktiv
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// n:m — Entry ↔ Container
class EntryContainers extends Table {
  TextColumn get entryId =>
      text().references(Entries, #id, onDelete: KeyAction.cascade)();
  TextColumn get containerId =>
      text().references(Containers, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {entryId, containerId};
}
