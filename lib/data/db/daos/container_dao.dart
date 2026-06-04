import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/containers.dart';

part 'container_dao.g.dart';

@DriftAccessor(tables: [Containers])
class ContainerDao extends DatabaseAccessor<AppDatabase> with _$ContainerDaoMixin {
  ContainerDao(super.db);

  Stream<List<Container>> watchAll() =>
      (select(containers)
            ..where((c) => c.archived.equals(false))
            ..orderBy([(c) => OrderingTerm.asc(c.name)]))
          .watch();

  Stream<List<Container>> watchByKind(String kind) =>
      (select(containers)
            ..where((c) => c.kind.equals(kind) & c.archived.equals(false)))
          .watch();

  Future<void> upsert(ContainersCompanion container) =>
      into(containers).insertOnConflictUpdate(container);

  Future<void> deleteById(String id) =>
      (delete(containers)..where((c) => c.id.equals(id))).go();

  // ── Sync helpers ────────────────────────────────────────────────────────────

  Future<List<Container>> getModifiedSince(DateTime since) =>
      (select(containers)
            ..where((c) =>
                c.updatedAt.isBiggerThanValue(since) & c.deletedAt.isNull()))
          .get();

  Future<List<Container>> getUnsynced() =>
      (select(containers)
            ..where((c) => c.deletedAt.isNull()))
          .get();

  Future<List<Container>> getSoftDeletedSince(DateTime since) =>
      (select(containers)
            ..where((c) =>
                c.deletedAt.isNotNull() &
                c.deletedAt.isBiggerThanValue(since)))
          .get();

  Future<void> softDelete(String id) =>
      (update(containers)..where((c) => c.id.equals(id))).write(
        ContainersCompanion(deletedAt: Value(DateTime.now().toUtc())),
      );
}
