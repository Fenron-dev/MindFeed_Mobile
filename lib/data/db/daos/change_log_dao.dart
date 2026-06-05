import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/change_log.dart';

part 'change_log_dao.g.dart';

@DriftAccessor(tables: [ChangeLog])
class ChangeLogDao extends DatabaseAccessor<AppDatabase>
    with _$ChangeLogDaoMixin {
  ChangeLogDao(super.db);

  /// Die letzten [limit] Journal-Einträge, neueste zuerst.
  Stream<List<ChangeLogData>> watchRecent({int limit = 100}) =>
      (select(changeLog)
            ..orderBy([(c) => OrderingTerm.desc(c.createdAt)])
            ..limit(limit))
          .watch();

  Future<void> add(ChangeLogCompanion entry) =>
      into(changeLog).insert(entry);

  Future<ChangeLogData?> getById(String id) =>
      (select(changeLog)..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<void> markUndone(String id) =>
      (update(changeLog)..where((c) => c.id.equals(id)))
          .write(const ChangeLogCompanion(undone: Value(true)));

  /// Hält das Journal schlank: löscht Einträge älter als [days] Tage.
  Future<void> pruneOlderThan(int days) {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    return (delete(changeLog)
          ..where((c) => c.createdAt.isSmallerThanValue(cutoff)))
        .go();
  }

  Future<void> clearAll() => delete(changeLog).go();
}
