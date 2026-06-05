import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/containers.dart';

part 'container_dao.g.dart';

@DriftAccessor(tables: [Containers])
class ContainerDao extends DatabaseAccessor<AppDatabase> with _$ContainerDaoMixin {
  ContainerDao(super.db);

  Stream<List<Container>> watchAll() =>
      (select(containers)
            ..where((c) => c.archived.equals(false) & c.deletedAt.isNull())
            ..orderBy([(c) => OrderingTerm.asc(c.name)]))
          .watch();

  Stream<List<Container>> watchByKind(String kind) =>
      (select(containers)
            ..where((c) =>
                c.kind.equals(kind) &
                c.archived.equals(false) &
                c.deletedAt.isNull()))
          .watch();

  Future<void> upsert(ContainersCompanion container) =>
      into(containers).insertOnConflictUpdate(container);

  Future<void> deleteById(String id) =>
      (delete(containers)..where((c) => c.id.equals(id))).go();

  // ── Sync helpers (Shadow-Version-Modell) ────────────────────────────────────

  /// Lokal geänderte Container, die noch nicht mit dem Server abgeglichen sind.
  Future<List<Container>> getDirty() =>
      (select(containers)
            ..where((c) =>
                c.deletedAt.isNull() &
                (c.syncUpdatedAt.isNull() |
                    c.updatedAt.isBiggerThan(c.syncUpdatedAt))))
          .get();

  Future<List<Container>> getSoftDeletedSince(DateTime since) =>
      (select(containers)
            ..where((c) =>
                c.deletedAt.isNotNull() &
                c.deletedAt.isBiggerThanValue(since)))
          .get();

  Future<List<Container>> getAllSoftDeleted() =>
      (select(containers)..where((c) => c.deletedAt.isNotNull())).get();

  Future<void> softDelete(String id) =>
      (update(containers)..where((c) => c.id.equals(id))).write(
        ContainersCompanion(deletedAt: Value(DateTime.now().toUtc())),
      );

  /// Setzt die Shadow-Version: syncUpdatedAt = updatedAt.
  Future<void> markSyncedToShadow(String id) async {
    final c = await (select(containers)..where((row) => row.id.equals(id)))
        .getSingleOrNull();
    if (c == null) return;
    await (update(containers)..where((row) => row.id.equals(id)))
        .write(ContainersCompanion(syncUpdatedAt: Value(c.updatedAt)));
  }
}
