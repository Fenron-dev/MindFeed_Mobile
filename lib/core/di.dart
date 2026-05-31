import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/db/app_database.dart';
import '../data/db/daos/entry_dao.dart';
import '../data/db/daos/tag_dao.dart';
import '../data/db/daos/container_dao.dart';
import '../data/db/daos/attachment_dao.dart';
import '../data/db/daos/property_dao.dart';
import '../data/repositories/entry_repository.dart';

// ─── Database (wird in main.dart via override initialisiert) ──────────────────
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('DB nicht initialisiert'),
);

// ─── DAOs ─────────────────────────────────────────────────────────────────────
final entryDaoProvider =
    Provider<EntryDao>((ref) => ref.watch(databaseProvider).entryDao);
final tagDaoProvider =
    Provider<TagDao>((ref) => ref.watch(databaseProvider).tagDao);
final containerDaoProvider =
    Provider<ContainerDao>((ref) => ref.watch(databaseProvider).containerDao);
final attachmentDaoProvider =
    Provider<AttachmentDao>((ref) => ref.watch(databaseProvider).attachmentDao);
final propertyDaoProvider =
    Provider<PropertyDao>((ref) => ref.watch(databaseProvider).propertyDao);

// ─── Repositories ─────────────────────────────────────────────────────────────
final entryRepositoryProvider = Provider<EntryRepository>((ref) {
  return EntryRepository(
    db: ref.watch(databaseProvider),
    entryDao: ref.watch(entryDaoProvider),
    tagDao: ref.watch(tagDaoProvider),
    attachmentDao: ref.watch(attachmentDaoProvider),
    propertyDao: ref.watch(propertyDaoProvider),
  );
});
