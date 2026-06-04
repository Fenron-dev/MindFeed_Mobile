import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import '../../dto/sync_dto.dart';
import '../../../data/db/app_database.dart';
import '../sync_server.dart';
import 'package:drift/drift.dart';

Router syncRouter(AppDatabase db, SyncServer server) {
  final router = Router();

  // ── Auth helper (in-memory, kein Platform-Channel) ────────────────────────

  Response? _requireAuth(Request req) {
    final auth = req.headers['authorization'] ?? '';
    if (!auth.startsWith('Bearer ')) {
      return Response(401,
          body: jsonEncode({'error': 'unauthorized'}),
          headers: {'content-type': 'application/json'});
    }
    final deviceId = server.verifyAccessToken(auth.substring(7));
    if (deviceId == null) {
      return Response(401,
          body: jsonEncode({'error': 'invalid_token'}),
          headers: {'content-type': 'application/json'});
    }
    return null;
  }

  // ── GET /sync/pull ─────────────────────────────────────────────────────────

  router.get('/sync/pull', (Request req) async {
    final authErr = _requireAuth(req);
    if (authErr != null) return authErr;

    final sinceStr = req.url.queryParameters['since'];
    final since = sinceStr != null ? DateTime.tryParse(sinceStr) : null;

    // Fetch all active entries (not soft-deleted)
    final allEntries = await (db.select(db.entries)
          ..where((e) => e.deletedAt.isNull()))
        .get();

    final filteredEntries = since == null
        ? allEntries
        : allEntries.where((e) => e.updatedAt.isAfter(since)).toList();

    // Fetch all active containers (not soft-deleted)
    final allContainers = await (db.select(db.containers)
          ..where((c) => c.deletedAt.isNull()))
        .get();

    final filteredContainers = since == null
        ? allContainers
        : allContainers.where((c) => c.updatedAt.isAfter(since)).toList();

    // Build tombstones from soft-deleted entries and containers
    final tombstones = <SyncTombstone>[];
    if (since != null) {
      final deletedEntries = await (db.select(db.entries)
            ..where((e) =>
                e.deletedAt.isNotNull() &
                e.deletedAt.isBiggerThanValue(since)))
          .get();
      for (final e in deletedEntries) {
        tombstones.add(SyncTombstone(
          entityType: 'entry',
          entityId: e.id,
          deletedAt: e.deletedAt!.toIso8601String(),
        ));
      }

      final deletedContainers = await (db.select(db.containers)
            ..where((c) =>
                c.deletedAt.isNotNull() &
                c.deletedAt.isBiggerThanValue(since)))
          .get();
      for (final c in deletedContainers) {
        tombstones.add(SyncTombstone(
          entityType: 'container',
          entityId: c.id,
          deletedAt: c.deletedAt!.toIso8601String(),
        ));
      }
    } else {
      // Full sync: include all tombstones
      final deletedEntries = await (db.select(db.entries)
            ..where((e) => e.deletedAt.isNotNull()))
          .get();
      for (final e in deletedEntries) {
        tombstones.add(SyncTombstone(
          entityType: 'entry',
          entityId: e.id,
          deletedAt: e.deletedAt!.toIso8601String(),
        ));
      }
    }

    // Build entry JSON (needs container IDs and properties from relations)
    final entryJsonList = <Map<String, dynamic>>[];
    for (final e in filteredEntries) {
      final containerIds = await (db.select(db.entryContainers)
            ..where((ec) => ec.entryId.equals(e.id)))
          .get()
          .then((rows) => rows.map((r) => r.containerId).toList());

      final props = await (db.select(db.entryProperties)
            ..where((p) => p.entryId.equals(e.id)))
          .get();

      final tags = await (db.select(db.entryTags)
            ..where((t) => t.entryId.equals(e.id)))
          .get();

      final tagNames = await Future.wait(
        tags.map((t) => (db.select(db.tags)..where((tg) => tg.id.equals(t.tagId))).getSingleOrNull()),
      ).then((list) => list.whereType<Tag>().map((t) => t.name).toList());

      entryJsonList.add({
        'id': e.id,
        'created_at': e.createdAt.toIso8601String(),
        'updated_at': e.updatedAt.toIso8601String(),
        'type': e.type,
        'title': e.title,
        'body': e.body,
        'status': e.status,
        'pinned': e.pinned,
        'geo_lat': e.geoLat,
        'geo_lng': e.geoLng,
        'reminder_at': e.reminderAt?.toIso8601String(),
        'source_url': e.sourceUrl,
        'source_app': e.sourceApp,
        'lang': e.lang,
        'ai_enriched_at': e.aiEnrichedAt?.toIso8601String(),
        'tags': tagNames,
        'containers': containerIds,
        'properties': props
            .map((p) => {
                  'key': p.key,
                  'value': p.value,
                  'type': p.type,
                })
            .toList(),
        'attachments': [],
      });
    }

    final containerJsonList = filteredContainers
        .map((c) => {
              'id': c.id,
              'kind': c.kind,
              'name': c.name,
              'description': c.description,
              'icon': c.icon,
              'color': c.color,
              'created_at': c.createdAt.toIso8601String(),
              'updated_at': c.updatedAt.toIso8601String(),
              'archived': c.archived,
              'filter_tag': c.filterTag,
              'filter_status': c.filterStatus,
              'filter_type': c.filterType,
              'sort_order': c.sortOrder,
              'view_mode': c.viewMode,
              'parent_id': c.parentId,
            })
        .toList();

    return Response.ok(
      jsonEncode({
        'syncedAt': DateTime.now().toUtc().toIso8601String(),
        'serverDeviceId': '',
        'serverName': '',
        'entries': entryJsonList,
        'containers': containerJsonList,
        'tombstones': tombstones.map((t) => t.toJson()).toList(),
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  // ── POST /sync/push ────────────────────────────────────────────────────────

  router.post('/sync/push', (Request req) async {
    final authErr = _requireAuth(req);
    if (authErr != null) return authErr;

    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return Response(400,
          body: jsonEncode({'error': 'invalid_json'}),
          headers: {'content-type': 'application/json'});
    }

    final clientEntries = (body['entries'] as List<dynamic>? ?? [])
        .map((e) => SyncEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final clientContainers = (body['containers'] as List<dynamic>? ?? [])
        .map((c) => SyncContainer.fromJson(Map<String, dynamic>.from(c as Map)))
        .toList();
    final clientTombstones = (body['tombstones'] as List<dynamic>? ?? [])
        .map((t) => SyncTombstone.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList();

    final conflicts = <SyncConflict>[];

    await db.transaction(() async {
      // 1. Apply tombstones first
      for (final t in clientTombstones) {
        final deletedAt = DateTime.tryParse(t.deletedAt) ?? DateTime.now().toUtc();
        if (t.entityType == 'entry') {
          await (db.update(db.entries)..where((e) => e.id.equals(t.entityId)))
              .write(EntriesCompanion(deletedAt: Value(deletedAt)));
        } else if (t.entityType == 'container') {
          await (db.update(db.containers)..where((c) => c.id.equals(t.entityId)))
              .write(ContainersCompanion(deletedAt: Value(deletedAt)));
        }
      }

      // 2. Upsert entries (LWW)
      for (final incoming in clientEntries) {
        final existing = await (db.select(db.entries)
              ..where((e) => e.id.equals(incoming.id)))
            .getSingleOrNull();

        // Skip if already tombstoned locally
        if (existing?.deletedAt != null) continue;

        final incomingTs = DateTime.tryParse(incoming.updatedAt);
        if (existing != null && incomingTs != null) {
          if (!incomingTs.isAfter(existing.updatedAt)) {
            conflicts.add(SyncConflict(
              entityType: 'entry',
              entityId: incoming.id,
              serverModifiedAt: existing.updatedAt.toIso8601String(),
            ));
            continue;
          }
        }

        // Upsert the entry row
        await db.into(db.entries).insertOnConflictUpdate(EntriesCompanion(
          id: Value(incoming.id),
          createdAt: Value(DateTime.tryParse(incoming.createdAt)?.toUtc() ?? DateTime.now().toUtc()),
          updatedAt: Value(incomingTs?.toUtc() ?? DateTime.now().toUtc()),
          type: Value(incoming.type),
          title: Value(incoming.title),
          body: Value(incoming.body),
          status: Value(incoming.status),
          pinned: Value(incoming.pinned),
          geoLat: Value(incoming.geoLat),
          geoLng: Value(incoming.geoLng),
          reminderAt: Value(incoming.reminderAt != null ? DateTime.tryParse(incoming.reminderAt!) : null),
          sourceUrl: Value(incoming.sourceUrl),
          sourceApp: Value(incoming.sourceApp),
          lang: Value(incoming.lang),
          aiEnrichedAt: Value(incoming.aiEnrichedAt != null ? DateTime.tryParse(incoming.aiEnrichedAt!) : null),
          syncUpdatedAt: Value(DateTime.now().toUtc()),
        ));

        // Sync containers relation
        await (db.delete(db.entryContainers)
              ..where((ec) => ec.entryId.equals(incoming.id)))
            .go();
        for (final cid in incoming.containers) {
          await db.into(db.entryContainers).insertOnConflictUpdate(
            EntryContainersCompanion(
              entryId: Value(incoming.id),
              containerId: Value(cid),
            ),
          );
        }
      }

      // 3. Upsert containers (LWW)
      for (final incoming in clientContainers) {
        final existing = await (db.select(db.containers)
              ..where((c) => c.id.equals(incoming.id)))
            .getSingleOrNull();

        if (existing?.deletedAt != null) continue;

        final incomingTs = DateTime.tryParse(incoming.updatedAt);
        if (existing != null && incomingTs != null) {
          if (!incomingTs.isAfter(existing.updatedAt)) {
            conflicts.add(SyncConflict(
              entityType: 'container',
              entityId: incoming.id,
              serverModifiedAt: existing.updatedAt.toIso8601String(),
            ));
            continue;
          }
        }

        await db.into(db.containers).insertOnConflictUpdate(ContainersCompanion(
          id: Value(incoming.id),
          kind: Value(incoming.kind),
          name: Value(incoming.name),
          description: Value(incoming.description),
          icon: Value(incoming.icon),
          color: Value(incoming.color),
          createdAt: Value(DateTime.tryParse(incoming.createdAt)?.toUtc() ?? DateTime.now().toUtc()),
          updatedAt: Value(incomingTs?.toUtc() ?? DateTime.now().toUtc()),
          archived: Value(incoming.archived),
          filterTag: Value(incoming.filterTag),
          filterStatus: Value(incoming.filterStatus),
          filterType: Value(incoming.filterType),
          sortOrder: Value(incoming.sortOrder),
          viewMode: Value(incoming.viewMode),
          parentId: Value(incoming.parentId),
        ));
      }
    });

    return Response.ok(
      jsonEncode({'conflicts': conflicts.map((c) => {
        'entityType': c.entityType,
        'entityId': c.entityId,
        'serverModifiedAt': c.serverModifiedAt,
      }).toList()}),
      headers: {'content-type': 'application/json'},
    );
  });

  return router;
}
