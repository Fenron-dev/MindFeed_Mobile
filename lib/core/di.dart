import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/db/app_database.dart';
import '../data/db/daos/entry_dao.dart';
import '../data/db/daos/tag_dao.dart';
import '../data/db/daos/container_dao.dart';
import '../data/db/daos/attachment_dao.dart';
import '../data/db/daos/property_dao.dart';
import '../data/db/daos/change_log_dao.dart';
import '../data/repositories/entry_repository.dart';
import '../domain/feed_filter.dart';
import '../services/app_settings.dart';
// Sync providers are declared in sync/sync_provider.dart and imported where needed.
// Registering them here would create a circular dependency.

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
final changeLogDaoProvider =
    Provider<ChangeLogDao>((ref) => ref.watch(databaseProvider).changeLogDao);

/// Reaktiver Verlauf der letzten Änderungen (für Undo).
final changeLogProvider = StreamProvider((ref) {
  return ref.watch(changeLogDaoProvider).watchRecent();
});

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

/// Reaktiver Stream aller soft-gelöschten Einträge (Papierkorb).
final trashedEntriesProvider = StreamProvider((ref) {
  final dao = ref.watch(entryDaoProvider);
  return dao.watchTrashed();
});

// ─── App-weite Einstellungen (reaktiv) ────────────────────────────────────────
final tagStyleProvider =
    StateProvider<TagStyle>((ref) => AppSettings.loadTagStyle());

final templatesProvider =
    StateProvider<List<PropTemplate>>((ref) => AppSettings.loadTemplates());

// ─── Feed-Filter ──────────────────────────────────────────────────────────────
final feedFilterProvider =
    StateProvider<FeedFilter>((ref) => const FeedFilter());
