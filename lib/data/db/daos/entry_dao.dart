import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/entries.dart';
import '../tables/tags.dart';
import '../tables/containers.dart';

part 'entry_dao.g.dart';

@DriftAccessor(tables: [Entries, EntryTags, EntryContainers])
class EntryDao extends DatabaseAccessor<AppDatabase> with _$EntryDaoMixin {
  EntryDao(super.db);

  Stream<List<Entry>> watchAll({String sortOrder = 'desc'}) {
    final q = select(entries);
    if (sortOrder == 'desc') {
      q.orderBy([(e) => OrderingTerm.desc(e.createdAt)]);
    } else {
      q.orderBy([(e) => OrderingTerm.asc(e.createdAt)]);
    }
    return q.watch();
  }

  Stream<Entry?> watchById(String id) =>
      (select(entries)..where((e) => e.id.equals(id))).watchSingleOrNull();

  Future<Entry?> getById(String id) =>
      (select(entries)..where((e) => e.id.equals(id))).getSingleOrNull();

  Future<void> upsert(EntriesCompanion entry) =>
      into(entries).insertOnConflictUpdate(entry);

  Future<void> deleteById(String id) =>
      (delete(entries)..where((e) => e.id.equals(id))).go();

  Stream<List<Entry>> watchByContainer(String containerId) {
    final q = select(entries).join([
      innerJoin(
        entryContainers,
        entryContainers.entryId.equalsExp(entries.id),
      ),
    ])
      ..where(entryContainers.containerId.equals(containerId))
      ..orderBy([OrderingTerm.desc(entries.createdAt)]);
    return q.watch().map((rows) => rows.map((r) => r.readTable(entries)).toList());
  }

  Future<void> setContainers(String entryId, List<String> containerIds) async {
    await (delete(entryContainers)
          ..where((ec) => ec.entryId.equals(entryId)))
        .go();
    for (final cid in containerIds) {
      await into(entryContainers).insertOnConflictUpdate(
        EntryContainersCompanion(
          entryId: Value(entryId),
          containerId: Value(cid),
        ),
      );
    }
  }

  Future<List<String>> getContainerIds(String entryId) async {
    final rows = await (select(entryContainers)
          ..where((ec) => ec.entryId.equals(entryId)))
        .get();
    return rows.map((r) => r.containerId).toList();
  }
}
