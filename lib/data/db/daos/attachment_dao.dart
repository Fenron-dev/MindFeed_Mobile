import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/attachments.dart';

part 'attachment_dao.g.dart';

@DriftAccessor(tables: [Attachments])
class AttachmentDao extends DatabaseAccessor<AppDatabase> with _$AttachmentDaoMixin {
  AttachmentDao(super.db);

  Stream<List<Attachment>> watchByEntry(String entryId) =>
      (select(attachments)
            ..where((a) => a.entryId.equals(entryId))
            ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]))
          .watch();

  Future<void> upsert(AttachmentsCompanion attachment) =>
      into(attachments).insertOnConflictUpdate(attachment);

  Future<void> deleteById(String id) =>
      (delete(attachments)..where((a) => a.id.equals(id))).go();
}
