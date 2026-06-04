import 'package:drift/drift.dart';

class Entries extends Table {
  TextColumn get id => text()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  // 'text' | 'link' | 'image' | 'audio'
  TextColumn get type =>
      text().withDefault(const Constant('text'))();
  TextColumn get title => text().nullable()();
  TextColumn get body =>
      text().withDefault(const Constant(''))();

  // 'inbox' | 'active' | 'done' | 'archived'
  TextColumn get status =>
      text().withDefault(const Constant('inbox'))();
  BoolColumn get pinned =>
      boolean().withDefault(const Constant(false))();

  RealColumn get geoLat => real().nullable()();
  RealColumn get geoLng => real().nullable()();
  DateTimeColumn get reminderAt => dateTime().nullable()();

  TextColumn get sourceUrl => text().nullable()();
  TextColumn get sourceApp => text().nullable()();

  // AI metadata
  TextColumn get lang => text().nullable()();
  DateTimeColumn get aiEnrichedAt => dateTime().nullable()();

  // Sync: null = noch nicht auf Server gepusht
  TextColumn get serverId => text().nullable()();
  DateTimeColumn get syncUpdatedAt => dateTime().nullable()();

  // Soft-Delete für Sync-Tombstones; null = aktiv
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
