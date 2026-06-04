import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../dto/sync_dto.dart';
import '../client/sync_api_client.dart';
import '../../data/db/app_database.dart';
import '../../data/db/daos/entry_dao.dart';
import '../../data/db/daos/container_dao.dart';
import '../../services/app_settings.dart';

const _uuid = Uuid();

class SyncResult {
  final bool success;
  final String? error;
  final int pulledEntries;
  final int pushedEntries;
  final int pulledContainers;
  final int pushedContainers;
  final List<SyncConflict> conflicts;
  final DateTime completedAt;

  const SyncResult({
    required this.success,
    this.error,
    this.pulledEntries = 0,
    this.pushedEntries = 0,
    this.pulledContainers = 0,
    this.pushedContainers = 0,
    this.conflicts = const [],
    required this.completedAt,
  });

  static SyncResult failed(String error) => SyncResult(
        success: false,
        error: error,
        completedAt: DateTime.now(),
      );
}

class SyncService {
  final AppDatabase db;
  final EntryDao entryDao;
  final ContainerDao containerDao;

  SyncService({
    required this.db,
    required this.entryDao,
    required this.containerDao,
  });

  // ── Main sync cycle ────────────────────────────────────────────────────────

  Future<SyncResult> sync() async {
    final serverUrl = AppSettings.getSyncServerUrl();
    if (serverUrl == null || serverUrl.isEmpty) {
      return SyncResult.failed('Kein Server konfiguriert.');
    }

    final client = SyncApiClient(serverUrl);

    try {
      // 1. Health check
      await client.health();
    } on SyncException catch (e) {
      return SyncResult.failed('Server nicht erreichbar: ${e.message}');
    } catch (e) {
      return SyncResult.failed('Server nicht erreichbar: $e');
    }

    final lastSyncAt = AppSettings.getLastSyncAt();

    // ── PULL ─────────────────────────────────────────────────────────────────

    late SyncPullResponse pullResp;
    try {
      pullResp = await client.pull(since: lastSyncAt);
    } on SyncException catch (e) {
      return SyncResult.failed('Pull fehlgeschlagen: ${e.message}');
    }

    await _applyPull(pullResp);

    // ── PUSH ─────────────────────────────────────────────────────────────────

    final dirtyEntries = lastSyncAt != null
        ? await entryDao.getModifiedSince(lastSyncAt)
        : await entryDao.getUnsynced();

    final dirtyContainers = lastSyncAt != null
        ? await containerDao.getModifiedSince(lastSyncAt)
        : await containerDao.getUnsynced();

    // Tombstones (soft-deleted since lastSync)
    final tombstones = <SyncTombstone>[];
    if (lastSyncAt != null) {
      final deletedEntries = await entryDao.getSoftDeletedSince(lastSyncAt);
      for (final e in deletedEntries) {
        tombstones.add(SyncTombstone(
          entityType: 'entry',
          entityId: e.id,
          deletedAt: e.deletedAt!.toIso8601String(),
        ));
      }
      final deletedContainers = await containerDao.getSoftDeletedSince(lastSyncAt);
      for (final c in deletedContainers) {
        tombstones.add(SyncTombstone(
          entityType: 'container',
          entityId: c.id,
          deletedAt: c.deletedAt!.toIso8601String(),
        ));
      }
    }

    // Build push payload
    final syncEntries = await _toSyncEntries(dirtyEntries);
    final syncContainers = _toSyncContainers(dirtyContainers);

    List<SyncConflict> conflicts = [];
    if (syncEntries.isNotEmpty ||
        syncContainers.isNotEmpty ||
        tombstones.isNotEmpty) {
      try {
        final deviceId = AppSettings.getDeviceId();
        final pushResp = await client.push(SyncPushRequest(
          deviceId: deviceId,
          entries: syncEntries,
          containers: syncContainers,
          tombstones: tombstones,
        ));
        conflicts = pushResp.conflicts;
      } on SyncException catch (e) {
        return SyncResult.failed('Push fehlgeschlagen: ${e.message}');
      }
    }

    // ── Finalize ─────────────────────────────────────────────────────────────

    final now = DateTime.now().toUtc();
    await AppSettings.saveLastSyncAt(now);

    // Mark pushed entries as synced
    final syncedIds = syncEntries.map((e) => e.id).toList();
    if (syncedIds.isNotEmpty) {
      await entryDao.markSynced(syncedIds, now);
    }

    return SyncResult(
      success: true,
      pulledEntries: pullResp.entries.length,
      pushedEntries: syncEntries.length,
      pulledContainers: pullResp.containers.length,
      pushedContainers: syncContainers.length,
      conflicts: conflicts,
      completedAt: now,
    );
  }

  // ── Apply pull response to local DB ───────────────────────────────────────

  Future<void> _applyPull(SyncPullResponse pull) async {
    await db.transaction(() async {
      // 1. Apply tombstones first
      for (final t in pull.tombstones) {
        if (t.entityType == 'entry') {
          await entryDao.softDelete(t.entityId);
        } else if (t.entityType == 'container') {
          await containerDao.softDelete(t.entityId);
        }
      }

      // 2. Upsert entries (LWW: accept if server is newer or local doesn't exist)
      for (final se in pull.entries) {
        final existing = await entryDao.getById(se.id);
        final serverTs = DateTime.tryParse(se.updatedAt)?.toUtc();
        if (existing != null && serverTs != null) {
          if (!serverTs.isAfter(existing.updatedAt)) continue; // local is newer
        }
        if (existing?.deletedAt != null) continue; // local tombstone wins

        await db.into(db.entries).insertOnConflictUpdate(EntriesCompanion(
          id: Value(se.id),
          createdAt: Value(DateTime.tryParse(se.createdAt)?.toUtc() ?? DateTime.now().toUtc()),
          updatedAt: Value(serverTs ?? DateTime.now().toUtc()),
          type: Value(se.type),
          title: Value(se.title),
          body: Value(se.body),
          status: Value(se.status),
          pinned: Value(se.pinned),
          geoLat: Value(se.geoLat),
          geoLng: Value(se.geoLng),
          reminderAt: Value(se.reminderAt != null ? DateTime.tryParse(se.reminderAt!) : null),
          sourceUrl: Value(se.sourceUrl),
          sourceApp: Value(se.sourceApp),
          lang: Value(se.lang),
          aiEnrichedAt: Value(se.aiEnrichedAt != null ? DateTime.tryParse(se.aiEnrichedAt!) : null),
          syncUpdatedAt: Value(DateTime.now().toUtc()),
        ));

        // Sync relations: containers
        await (db.delete(db.entryContainers)
              ..where((ec) => ec.entryId.equals(se.id)))
            .go();
        for (final cid in se.containers) {
          await db.into(db.entryContainers).insertOnConflictUpdate(
            EntryContainersCompanion(
              entryId: Value(se.id),
              containerId: Value(cid),
            ),
          );
        }

        // Sync properties
        await (db.delete(db.entryProperties)
              ..where((p) => p.entryId.equals(se.id)))
            .go();
        for (final prop in se.properties) {
          await db.into(db.entryProperties).insertOnConflictUpdate(
            EntryPropertiesCompanion(
              id: Value('prop-${_uuid.v4()}'),
              entryId: Value(se.id),
              key: Value(prop['key'] as String? ?? ''),
              value: Value(prop['value'] as String?),
              type: Value(prop['type'] as String? ?? 'text'),
            ),
          );
        }
      }

      // 3. Upsert containers (LWW)
      for (final sc in pull.containers) {
        final existing = await (db.select(db.containers)
              ..where((c) => c.id.equals(sc.id)))
            .getSingleOrNull();
        final serverTs = DateTime.tryParse(sc.updatedAt)?.toUtc();
        if (existing != null && serverTs != null) {
          if (!serverTs.isAfter(existing.updatedAt)) continue;
        }
        if (existing?.deletedAt != null) continue;

        await db.into(db.containers).insertOnConflictUpdate(ContainersCompanion(
          id: Value(sc.id),
          kind: Value(sc.kind),
          name: Value(sc.name),
          description: Value(sc.description),
          icon: Value(sc.icon),
          color: Value(sc.color),
          createdAt: Value(DateTime.tryParse(sc.createdAt)?.toUtc() ?? DateTime.now().toUtc()),
          updatedAt: Value(serverTs ?? DateTime.now().toUtc()),
          archived: Value(sc.archived),
          filterTag: Value(sc.filterTag),
          filterStatus: Value(sc.filterStatus),
          filterType: Value(sc.filterType),
          sortOrder: Value(sc.sortOrder),
          viewMode: Value(sc.viewMode),
          parentId: Value(sc.parentId),
        ));
      }
    });
  }

  // ── Convert local Drift models → SyncDTO ──────────────────────────────────

  Future<List<SyncEntry>> _toSyncEntries(List<Entry> entries) async {
    final result = <SyncEntry>[];
    for (final e in entries) {
      final containerIds = await entryDao.getContainerIds(e.id);
      final props = await (db.select(db.entryProperties)
            ..where((p) => p.entryId.equals(e.id)))
          .get();
      final tagRows = await (db.select(db.entryTags)
            ..where((t) => t.entryId.equals(e.id)))
          .get();
      final tagNames = await Future.wait(tagRows.map((tr) async {
        final tag = await (db.select(db.tags)
              ..where((t) => t.id.equals(tr.tagId)))
            .getSingleOrNull();
        return tag?.name ?? '';
      })).then((list) => list.where((s) => s.isNotEmpty).toList());

      result.add(SyncEntry(
        id: e.id,
        createdAt: e.createdAt.toIso8601String(),
        updatedAt: e.updatedAt.toIso8601String(),
        type: e.type,
        title: e.title,
        body: e.body,
        status: e.status,
        pinned: e.pinned,
        geoLat: e.geoLat,
        geoLng: e.geoLng,
        reminderAt: e.reminderAt?.toIso8601String(),
        sourceUrl: e.sourceUrl,
        sourceApp: e.sourceApp,
        lang: e.lang,
        aiEnrichedAt: e.aiEnrichedAt?.toIso8601String(),
        tags: tagNames,
        containers: containerIds,
        properties: props
            .map((p) => {'key': p.key, 'value': p.value, 'type': p.type})
            .toList(),
        attachments: [],
      ));
    }
    return result;
  }

  List<SyncContainer> _toSyncContainers(List<Container> containers) =>
      containers.map((c) => SyncContainer(
            id: c.id,
            kind: c.kind,
            name: c.name,
            description: c.description,
            icon: c.icon,
            color: c.color,
            createdAt: c.createdAt.toIso8601String(),
            updatedAt: c.updatedAt.toIso8601String(),
            archived: c.archived,
            filterTag: c.filterTag,
            filterStatus: c.filterStatus,
            filterType: c.filterType,
            sortOrder: c.sortOrder,
            viewMode: c.viewMode,
            parentId: c.parentId,
          )).toList();
}
