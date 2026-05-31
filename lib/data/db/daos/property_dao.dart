import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/properties.dart';

part 'property_dao.g.dart';

@DriftAccessor(tables: [EntryProperties, EntryLinks])
class PropertyDao extends DatabaseAccessor<AppDatabase> with _$PropertyDaoMixin {
  PropertyDao(super.db);

  Stream<List<EntryProperty>> watchByEntry(String entryId) =>
      (select(entryProperties)
            ..where((p) => p.entryId.equals(entryId)))
          .watch();

  Future<void> setProperties(String entryId, List<EntryPropertiesCompanion> props) async {
    await (delete(entryProperties)..where((p) => p.entryId.equals(entryId))).go();
    for (final p in props) {
      await into(entryProperties).insertOnConflictUpdate(p);
    }
  }

  Future<void> upsertLink(String fromId, String toId) =>
      into(entryLinks).insertOnConflictUpdate(
        EntryLinksCompanion(fromId: Value(fromId), toId: Value(toId)),
      );

  Future<List<EntryLink>> getBacklinks(String entryId) =>
      (select(entryLinks)..where((l) => l.toId.equals(entryId))).get();
}
