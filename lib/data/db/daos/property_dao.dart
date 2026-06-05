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
    // Eltern-Eintrag als geändert markieren, damit die Property-Änderung beim
    // nächsten Sync als "dirty" erkannt und übertragen wird (Shadow-Modell).
    final mainDb = attachedDatabase;
    await (mainDb.update(mainDb.entries)..where((e) => e.id.equals(entryId)))
        .write(EntriesCompanion(updatedAt: Value(DateTime.now().toUtc())));
  }

  Future<void> upsertLink(String fromId, String toId) =>
      into(entryLinks).insertOnConflictUpdate(
        EntryLinksCompanion(fromId: Value(fromId), toId: Value(toId)),
      );

  Future<List<EntryLink>> getBacklinks(String entryId) =>
      (select(entryLinks)..where((l) => l.toId.equals(entryId))).get();

  Future<void> setOutgoingLinks(String fromId, List<String> toIds) async {
    await (delete(entryLinks)..where((l) => l.fromId.equals(fromId))).go();
    for (final toId in toIds) {
      await upsertLink(fromId, toId);
    }
  }

  /// Alle eindeutigen Property-Keys (für Filter-UI)
  Future<List<String>> getUniqueKeys() async {
    final rows = await customSelect(
      'SELECT DISTINCT key FROM entry_properties '
      'WHERE key NOT IN (\'og_image\',\'og_title\',\'og_description\',\'domain\') '
      'ORDER BY key',
      readsFrom: {entryProperties},
    ).get();
    return rows.map((r) => r.read<String>('key')).toList();
  }
}
