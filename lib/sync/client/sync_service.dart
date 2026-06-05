import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../dto/sync_dto.dart';
import '../client/sync_api_client.dart';
import '../../data/db/app_database.dart';
import '../../data/db/daos/entry_dao.dart';
import '../../data/db/daos/container_dao.dart';
import '../../core/vault_manager.dart';
import '../../services/app_settings.dart';

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
    final firstSync = lastSyncAt == null;

    // ── PULL ─────────────────────────────────────────────────────────────────
    // Alle Exceptions fangen (TimeoutException, SocketException, FormatException…)

    SyncPullResponse pullResp;
    try {
      pullResp = await client.pull(since: lastSyncAt);
    } catch (e) {
      return SyncResult.failed('Pull fehlgeschlagen: $e');
    }

    // _applyPull übernimmt Server-Versionen (LWW gegen Shadow) und erkennt
    // ECHTE Konflikte (lokal UND Server seit dem Shadow geändert). Beim
    // allerersten Sync gibt es nie Konflikte — alles wird einfach übernommen.
    List<SyncConflict> conflicts;
    try {
      conflicts = await _applyPull(pullResp, firstSync: firstSync);
    } catch (e) {
      return SyncResult.failed('Lokale Datenbank-Aktualisierung fehlgeschlagen: $e');
    }

    // ── PUSH ─────────────────────────────────────────────────────────────────
    // Nur wirklich lokal geänderte Einträge (dirty), NICHT die gerade gepullten.
    // Einträge mit echtem Konflikt werden NICHT gepusht (warten auf Entscheidung).
    final conflictIds = conflicts.map((c) => c.entityId).toSet();

    final dirtyEntries = (await entryDao.getDirty())
        .where((e) => !conflictIds.contains(e.id))
        .toList();
    final dirtyContainers = (await containerDao.getDirty())
        .where((c) => !conflictIds.contains(c.id))
        .toList();

    // Tombstones: beim Erstsync alle, sonst nur seit dem letzten Sync gelöschte
    final tombstones = <SyncTombstone>[];
    final deletedEntries = firstSync
        ? await entryDao.getAllSoftDeleted()
        : await entryDao.getSoftDeletedSince(lastSyncAt);
    for (final e in deletedEntries) {
      tombstones.add(SyncTombstone(
        entityType: 'entry',
        entityId: e.id,
        deletedAt: e.deletedAt!.toIso8601String(),
      ));
    }
    final deletedContainers = firstSync
        ? await containerDao.getAllSoftDeleted()
        : await containerDao.getSoftDeletedSince(lastSyncAt);
    for (final c in deletedContainers) {
      tombstones.add(SyncTombstone(
        entityType: 'container',
        entityId: c.id,
        deletedAt: c.deletedAt!.toIso8601String(),
      ));
    }

    // Build push payload
    final syncEntries = await _toSyncEntries(dirtyEntries);
    final syncContainers = _toSyncContainers(dirtyContainers);

    if (syncEntries.isNotEmpty ||
        syncContainers.isNotEmpty ||
        tombstones.isNotEmpty) {
      try {
        final deviceId = AppSettings.getDeviceId();
        // Server macht reines LWW; das conflicts-Feld der Antwort wird
        // ignoriert — Konflikte werden clientseitig beim Pull erkannt.
        await client.push(SyncPushRequest(
          deviceId: deviceId,
          entries: syncEntries,
          containers: syncContainers,
          tombstones: tombstones,
        ));
      } catch (e) {
        return SyncResult.failed('Push fehlgeschlagen: $e');
      }
    }

    // ── Anhänge übertragen (best-effort, blockiert den Sync-Erfolg nicht) ────
    try {
      await _uploadAttachments(client);
      await _downloadMissingAttachments(client);
    } catch (e) {
      debugPrint('[Sync] Anhang-Übertragung mit Fehler beendet: $e');
    }

    // ── Finalize ─────────────────────────────────────────────────────────────
    // Erfolgreich gepushte Einträge auf Shadow setzen (syncUpdatedAt = updatedAt)
    // → nicht mehr dirty, werden beim nächsten Sync nicht erneut gepusht.
    for (final e in dirtyEntries) {
      await entryDao.markSyncedToShadow(e.id);
    }
    for (final c in dirtyContainers) {
      await containerDao.markSyncedToShadow(c.id);
    }

    final now = DateTime.now().toUtc();
    await AppSettings.saveLastSyncAt(now);

    if (conflicts.isNotEmpty) {
      debugPrint('[Sync] ${conflicts.length} echte(r) Konflikt(e) erkannt');
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

  // ── Apply pull response to local DB (Shadow-Version-Modell) ────────────────
  //
  // Übernimmt Server-Versionen und erkennt ECHTE Konflikte:
  //   localDirty   = lokal geändert seit letztem Abgleich (updatedAt > shadow)
  //   serverChanged= Server-Version weicht vom letzten Abgleich ab (serverTs != shadow)
  //   → Konflikt nur wenn BEIDES zutrifft. Sonst gewinnt die jeweils einzige
  //     geänderte Seite lautlos (kein "alles ist ein Konflikt" mehr).

  Future<List<SyncConflict>> _applyPull(SyncPullResponse pull,
      {bool firstSync = false}) async {
    final vaultAttsPath = await VaultManager.getAttachmentsPath();
    final conflicts = <SyncConflict>[];

    if (pull.tombstones.isNotEmpty) {
      debugPrint('[Sync] ${pull.tombstones.length} Tombstone(s) empfangen '
          '→ werden in den Papierkorb verschoben');
    }

    await db.transaction(() async {
      // 1. Tombstones zuerst (Soft-Delete → Papierkorb)
      for (final t in pull.tombstones) {
        if (t.entityType == 'entry') {
          await entryDao.softDelete(t.entityId);
        } else if (t.entityType == 'container') {
          await containerDao.softDelete(t.entityId);
        }
      }

      // 2. Container VOR Entries (FK: entry_containers → containers)
      for (final sc in pull.containers) {
        final existing = await (db.select(db.containers)
              ..where((c) => c.id.equals(sc.id)))
            .getSingleOrNull();
        final serverTs = DateTime.tryParse(sc.updatedAt)?.toUtc();
        if (existing?.deletedAt != null) continue; // lokaler Tombstone gewinnt

        if (existing == null || firstSync) {
          await _writeServerContainer(sc, serverTs);
          continue;
        }

        final shadow = existing.syncUpdatedAt;
        final localDirty = shadow == null || existing.updatedAt.isAfter(shadow);
        final serverChanged = shadow == null ||
            (serverTs != null && !_sameInstant(serverTs, shadow));

        if (!localDirty) {
          // Nur Server hat geändert (oder gar nichts) → übernehmen
          await _writeServerContainer(sc, serverTs);
        } else if (!serverChanged) {
          // Nur lokal geändert → lokale Version behalten, wird gepusht
          continue;
        } else {
          // Beide geändert → echter Konflikt
          conflicts.add(SyncConflict(
            entityType: 'container',
            entityId: sc.id,
            serverModifiedAt: sc.updatedAt,
            localModifiedAt: existing.updatedAt.toIso8601String(),
            serverData: sc.toJson(),
          ));
        }
      }

      // 3. Entries
      for (final se in pull.entries) {
        final existing = await entryDao.getById(se.id);
        final serverTs = DateTime.tryParse(se.updatedAt)?.toUtc();
        if (existing?.deletedAt != null) continue; // lokaler Tombstone gewinnt

        if (existing == null || firstSync) {
          await _writeServerEntry(se, serverTs, vaultAttsPath);
          continue;
        }

        final shadow = existing.syncUpdatedAt;
        final localDirty = shadow == null || existing.updatedAt.isAfter(shadow);
        final serverChanged = shadow == null ||
            (serverTs != null && !_sameInstant(serverTs, shadow));

        if (!localDirty) {
          await _writeServerEntry(se, serverTs, vaultAttsPath);
        } else if (!serverChanged) {
          continue; // nur lokal geändert → behalten, wird gepusht
        } else {
          conflicts.add(SyncConflict(
            entityType: 'entry',
            entityId: se.id,
            serverModifiedAt: se.updatedAt,
            localModifiedAt: existing.updatedAt.toIso8601String(),
            serverData: se.toJson(),
          ));
        }
      }
    });

    return conflicts;
  }

  static bool _sameInstant(DateTime a, DateTime b) =>
      a.toUtc().millisecondsSinceEpoch == b.toUtc().millisecondsSinceEpoch;

  /// Schreibt eine Server-Container-Version lokal; setzt Shadow = serverTs.
  Future<void> _writeServerContainer(SyncContainer sc, DateTime? serverTs) async {
    final ts = serverTs ?? DateTime.now().toUtc();
    await db.into(db.containers).insertOnConflictUpdate(ContainersCompanion(
      id: Value(sc.id),
      kind: Value(sc.kind),
      name: Value(sc.name),
      description: Value(sc.description),
      icon: Value(sc.icon),
      color: Value(sc.color),
      createdAt: Value(DateTime.tryParse(sc.createdAt)?.toUtc() ?? ts),
      updatedAt: Value(ts),
      archived: Value(sc.archived),
      filterTag: Value(sc.filterTag),
      filterStatus: Value(sc.filterStatus),
      filterType: Value(sc.filterType),
      sortOrder: Value(sc.sortOrder),
      viewMode: Value(sc.viewMode),
      parentId: Value(sc.parentId),
      syncUpdatedAt: Value(ts), // Shadow = Server-Version → nicht dirty
    ));
  }

  /// Schreibt eine Server-Entry-Version lokal (inkl. Relationen + Anhang-Meta);
  /// setzt Shadow = serverTs.
  Future<void> _writeServerEntry(
      SyncEntry se, DateTime? serverTs, String vaultAttsPath) async {
    final ts = serverTs ?? DateTime.now().toUtc();
    await db.into(db.entries).insertOnConflictUpdate(EntriesCompanion(
      id: Value(se.id),
      createdAt: Value(DateTime.tryParse(se.createdAt)?.toUtc() ?? ts),
      updatedAt: Value(ts),
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
      syncUpdatedAt: Value(ts), // Shadow = Server-Version → nicht dirty
    ));

    // entry_containers
    await (db.delete(db.entryContainers)
          ..where((ec) => ec.entryId.equals(se.id)))
        .go();
    for (final cid in se.containers) {
      final containerExists = await (db.select(db.containers)
            ..where((c) => c.id.equals(cid) & c.deletedAt.isNull()))
          .getSingleOrNull();
      if (containerExists == null) continue;
      await db.into(db.entryContainers).insertOnConflictUpdate(
        EntryContainersCompanion(
          entryId: Value(se.id),
          containerId: Value(cid),
        ),
      );
    }

    // Properties
    await (db.delete(db.entryProperties)..where((p) => p.entryId.equals(se.id))).go();
    for (final prop in se.properties) {
      final key = prop['key'] as String? ?? '';
      if (key.isEmpty) continue;
      await db.into(db.entryProperties).insertOnConflictUpdate(
        EntryPropertiesCompanion(
          id: Value('prop-${se.id}-$key'),
          entryId: Value(se.id),
          key: Value(key),
          value: Value(prop['value'] as String?),
          type: Value(prop['type'] as String? ?? 'text'),
        ),
      );
    }

    // Tags
    await (db.delete(db.entryTags)..where((t) => t.entryId.equals(se.id))).go();
    for (final tagName in se.tags) {
      if (tagName.isEmpty) continue;
      final tagId = 'tag-$tagName';
      await db.into(db.tags).insertOnConflictUpdate(
        TagsCompanion(id: Value(tagId), name: Value(tagName)),
      );
      await db.into(db.entryTags).insertOnConflictUpdate(
        EntryTagsCompanion(entryId: Value(se.id), tagId: Value(tagId)),
      );
    }

    // Anhang-Metadaten (Binärdaten via _downloadMissingAttachments)
    for (final attMap in se.attachments) {
      final attId = _attStr(attMap, 'id');
      if (attId.isEmpty) continue;
      final fileName = _attStr(attMap, 'fileName', 'file_name').isNotEmpty
          ? _attStr(attMap, 'fileName', 'file_name')
          : attId;
      final ext = p.extension(fileName);
      final localPath = p.join(vaultAttsPath, '$attId$ext');
      final mimeType = _attStr(attMap, 'mimeType', 'mime_type').isNotEmpty
          ? _attStr(attMap, 'mimeType', 'mime_type')
          : 'application/octet-stream';
      await db.into(db.attachments).insertOnConflictUpdate(
        AttachmentsCompanion(
          id: Value(attId),
          entryId: Value(se.id),
          type: Value(_attStr(attMap, 'type').isNotEmpty
              ? _attStr(attMap, 'type') : 'file'),
          mimeType: Value(mimeType),
          localPath: Value(localPath),
          fileName: Value(fileName),
          fileSize: Value(_attInt(attMap, 'fileSize', 'size') ?? 0),
          durationMs: Value(_attInt(attMap, 'durationMs', 'duration_ms')),
          transcription: Value(attMap['transcription'] as String?),
          createdAt: Value(DateTime.tryParse(
                  _attStr(attMap, 'createdAt', 'created_at'))?.toUtc() ??
              DateTime.now().toUtc()),
        ),
      );
    }
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
        attachments: await (db.select(db.attachments)
              ..where((a) => a.entryId.equals(e.id)))
            .get()
            .then((list) => list.map((a) => {
                  'id': a.id,
                  'entryId': a.entryId,
                  'type': a.type,
                  'mimeType': a.mimeType,
                  'fileName': a.fileName,
                  'fileSize': a.fileSize,
                  'durationMs': a.durationMs,
                  'localPath': a.localPath,
                  'transcription': a.transcription,
                  'createdAt': a.createdAt.toIso8601String(),
                }).toList()),
      ));
    }
    return result;
  }

  /// Konflikt-Auflösung "Meine Version behalten": lokale Version mit frischem
  /// Zeitstempel pushen (gewinnt LWW), danach Shadow setzen.
  Future<void> resolveConflictsMine(List<SyncConflict> conflicts) async {
    final serverUrl = AppSettings.getSyncServerUrl();
    if (serverUrl == null) return;
    final client = SyncApiClient(serverUrl);
    final now = DateTime.now().toUtc();

    final forcedEntries = <SyncEntry>[];
    final forcedContainers = <SyncContainer>[];

    for (final conflict in conflicts) {
      if (conflict.entityType == 'entry') {
        final entry = await entryDao.getById(conflict.entityId);
        if (entry == null) continue;
        // updatedAt lokal in die Zukunft setzen → gewinnt LWW + ist > Shadow
        await (db.update(db.entries)..where((e) => e.id.equals(entry.id)))
            .write(EntriesCompanion(updatedAt: Value(now)));
        final entries = await _toSyncEntries([(await entryDao.getById(entry.id))!]);
        if (entries.isNotEmpty) forcedEntries.add(entries.first);
      } else if (conflict.entityType == 'container') {
        await (db.update(db.containers)..where((c) => c.id.equals(conflict.entityId)))
            .write(ContainersCompanion(updatedAt: Value(now)));
        final c = await (db.select(db.containers)
              ..where((row) => row.id.equals(conflict.entityId)))
            .getSingleOrNull();
        if (c != null) forcedContainers.addAll(_toSyncContainers([c]));
      }
    }

    if (forcedEntries.isEmpty && forcedContainers.isEmpty) return;
    try {
      await client.push(SyncPushRequest(
        deviceId: AppSettings.getDeviceId(),
        entries: forcedEntries,
        containers: forcedContainers,
        tombstones: [],
      ));
      // Erfolgreich gepusht → Shadow setzen (nicht mehr dirty)
      for (final e in forcedEntries) {
        await entryDao.markSyncedToShadow(e.id);
      }
      for (final c in forcedContainers) {
        await containerDao.markSyncedToShadow(c.id);
      }
    } catch (e) {
      debugPrint('[Sync] resolveConflictsMine push fehlgeschlagen: $e');
    }
  }

  /// Konflikt-Auflösung "Server-Version übernehmen": die im Konflikt
  /// mitgelieferte Server-Version lokal anwenden (überschreibt lokale Änderung).
  Future<void> resolveConflictsServer(List<SyncConflict> conflicts) async {
    final vaultAttsPath = await VaultManager.getAttachmentsPath();
    await db.transaction(() async {
      for (final conflict in conflicts) {
        final data = conflict.serverData;
        if (data == null) continue;
        if (conflict.entityType == 'entry') {
          final se = SyncEntry.fromJson(data);
          await _writeServerEntry(
              se, DateTime.tryParse(se.updatedAt)?.toUtc(), vaultAttsPath);
        } else if (conflict.entityType == 'container') {
          final sc = SyncContainer.fromJson(data);
          await _writeServerContainer(
              sc, DateTime.tryParse(sc.updatedAt)?.toUtc());
        }
      }
    });
  }

  // ── Anhänge hochladen ─────────────────────────────────────────────────────

  /// Lädt alle lokalen Anhang-Dateien hoch, deren Datei vorhanden ist.
  /// Läuft über ALLE Anhänge (nicht nur dirty entries), damit ein einmal
  /// fehlgeschlagener Upload beim nächsten Sync erneut versucht wird.
  Future<int> _uploadAttachments(SyncApiClient client) async {
    final atts = await db.select(db.attachments).get();
    var uploaded = 0;
    for (final att in atts) {
      try {
        final file = File(att.localPath);
        if (!file.existsSync()) {
          debugPrint('[Sync] Upload übersprungen (Datei fehlt lokal): '
              '${att.id} → ${att.localPath}');
          continue;
        }
        final bytes = await file.readAsBytes();
        await client.uploadAttachment(att.id, bytes, att.mimeType);
        uploaded++;
      } catch (e) {
        debugPrint('[Sync] Upload fehlgeschlagen für ${att.id}: $e');
      }
    }
    if (uploaded > 0) debugPrint('[Sync] $uploaded Anhang/Anhänge hochgeladen');
    return uploaded;
  }

  // ── Hilfsfunktionen für camelCase/snake_case Normierung ─────────────────────

  static String _attStr(Map<String, dynamic> m, String camel, [String? snake]) =>
      (m[camel] as String?) ?? (snake != null ? m[snake] as String? : null) ?? '';

  static int? _attInt(Map<String, dynamic> m, String camel, [String? snake]) =>
      (m[camel] as int?) ?? (snake != null ? m[snake] as int? : null);

  // ── Fehlende Anhänge herunterladen ────────────────────────────────────────

  /// Lädt alle Anhang-Dateien herunter, die lokal in der DB stehen, deren
  /// Datei aber (noch) nicht auf der Platte liegt. Läuft über ALLE Anhänge,
  /// nicht nur über den aktuellen Pull-Delta — so wird ein einmal
  /// fehlgeschlagener Download bei jedem Sync erneut versucht.
  Future<int> _downloadMissingAttachments(SyncApiClient client) async {
    final vaultAttsPath = await VaultManager.getAttachmentsPath();
    await Directory(vaultAttsPath).create(recursive: true);

    final atts = await db.select(db.attachments).get();
    var downloaded = 0;

    for (final att in atts) {
      // Schon vorhanden? Überspringen.
      if (att.localPath.isNotEmpty && File(att.localPath).existsSync()) continue;

      // Zielpfad im lokalen Vault festlegen
      final ext = p.extension(att.fileName.isNotEmpty ? att.fileName : att.id);
      final localPath = p.join(vaultAttsPath, '${att.id}$ext');

      if (File(localPath).existsSync()) {
        // Datei liegt schon da, nur DB-Pfad korrigieren
        if (att.localPath != localPath) {
          await (db.update(db.attachments)..where((a) => a.id.equals(att.id)))
              .write(AttachmentsCompanion(localPath: Value(localPath)));
        }
        continue;
      }

      try {
        final bytes = await client.downloadAttachment(att.id);
        if (bytes.isEmpty) {
          debugPrint('[Sync] Download leer für ${att.id} — übersprungen');
          continue;
        }
        await File(localPath).writeAsBytes(bytes);
        // localPath aktualisieren → triggert watchByEntry → UI rendert Datei
        await (db.update(db.attachments)..where((a) => a.id.equals(att.id)))
            .write(AttachmentsCompanion(localPath: Value(localPath)));
        downloaded++;
      } catch (e) {
        debugPrint('[Sync] Download fehlgeschlagen für ${att.id}: $e');
      }
    }
    if (downloaded > 0) {
      debugPrint('[Sync] $downloaded Anhang/Anhänge heruntergeladen');
    }
    return downloaded;
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
