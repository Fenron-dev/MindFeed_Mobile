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
    return (select(entries)
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([
            (e) => OrderingTerm.desc(e.pinned),
            (e) => sortOrder == 'desc'
                ? OrderingTerm.desc(e.createdAt)
                : OrderingTerm.asc(e.createdAt),
          ]))
        .watch();
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
      ..where(entryContainers.containerId.equals(containerId) &
          entries.deletedAt.isNull())
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

  Future<Entry?> findByTitle(String title) async {
    final result = await (select(entries)
          ..where((e) => e.title.lower().equals(title.toLowerCase()))
          ..limit(1))
        .get();
    return result.isEmpty ? null : result.first;
  }

  Future<int> countByContainer(String containerId) async {
    final rows = await (select(entryContainers)
          ..where((ec) => ec.containerId.equals(containerId)))
        .get();
    return rows.length;
  }

  // ── Sync helpers (Shadow-Version-Modell) ────────────────────────────────────

  /// Lokal geänderte Einträge, die noch nicht mit dem Server abgeglichen sind.
  /// dirty = syncUpdatedAt IS NULL (neu) ODER updatedAt > syncUpdatedAt (geändert).
  /// Gepullte Server-Einträge (updatedAt == syncUpdatedAt) sind NICHT dirty —
  /// das verhindert, dass sie sofort wieder zurückgepusht werden.
  Future<List<Entry>> getDirty() =>
      (select(entries)
            ..where((e) =>
                e.deletedAt.isNull() &
                (e.syncUpdatedAt.isNull() |
                    e.updatedAt.isBiggerThan(e.syncUpdatedAt))))
          .get();

  /// Returns soft-deleted entries (tombstones) modified after [since].
  Future<List<Entry>> getSoftDeletedSince(DateTime since) =>
      (select(entries)
            ..where((e) =>
                e.deletedAt.isNotNull() &
                e.deletedAt.isBiggerThanValue(since)))
          .get();

  /// Alle Tombstones (für Full-Sync ohne since).
  Future<List<Entry>> getAllSoftDeleted() =>
      (select(entries)..where((e) => e.deletedAt.isNotNull())).get();

  /// Soft-deletes an entry (sets deletedAt).
  Future<void> softDelete(String id) =>
      (update(entries)..where((e) => e.id.equals(id)))
          .write(EntriesCompanion(deletedAt: Value(DateTime.now().toUtc())));

  /// Setzt die Shadow-Version: syncUpdatedAt = updatedAt. Danach gilt der
  /// Eintrag als mit dem Server abgeglichen (nicht mehr dirty).
  Future<void> markSyncedToShadow(String id) async {
    final e = await getById(id);
    if (e == null) return;
    await (update(entries)..where((row) => row.id.equals(id)))
        .write(EntriesCompanion(syncUpdatedAt: Value(e.updatedAt)));
  }

  // ── Tasks ──────────────────────────────────────────────────────────────────

  /// Alle Tasks (type='task'), nicht gelöscht, nach Fälligkeit sortiert.
  /// NULLs (kein Datum) kommen ans Ende.
  Stream<List<Entry>> watchTasks() {
    return db.customSelect(
      '''
      SELECT * FROM entries
      WHERE type = 'task' AND deleted_at IS NULL
      ORDER BY
        CASE WHEN reminder_at IS NULL THEN 1 ELSE 0 END,
        reminder_at ASC,
        created_at DESC
      ''',
      readsFrom: {db.entries},
    ).watch().map((rows) => rows.map((r) => Entry.fromJson(r.data)).toList());
  }

  // ── Papierkorb ──────────────────────────────────────────────────────────────

  /// Alle soft-gelöschten Einträge (Papierkorb), neueste zuerst.
  Stream<List<Entry>> watchTrashed() =>
      (select(entries)
            ..where((e) => e.deletedAt.isNotNull())
            ..orderBy([(e) => OrderingTerm.desc(e.deletedAt)]))
          .watch();

  /// Stellt einen Eintrag aus dem Papierkorb wieder her.
  Future<void> restore(String id) =>
      (update(entries)..where((e) => e.id.equals(id)))
          .write(const EntriesCompanion(deletedAt: Value(null)));

  /// Löscht einen Eintrag endgültig aus der Datenbank.
  Future<void> permanentlyDelete(String id) =>
      (delete(entries)..where((e) => e.id.equals(id))).go();

  /// Leert den Papierkorb vollständig (endgültige Löschung aller soft-deleted).
  Future<void> emptyTrash() =>
      (delete(entries)..where((e) => e.deletedAt.isNotNull())).go();

  /// Löscht Einträge im Papierkorb die älter als [days] Tage sind.
  Future<void> cleanTrashOlderThan(int days) {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    return (delete(entries)
          ..where((e) =>
              e.deletedAt.isNotNull() &
              e.deletedAt.isSmallerThanValue(cutoff)))
        .go();
  }
}
