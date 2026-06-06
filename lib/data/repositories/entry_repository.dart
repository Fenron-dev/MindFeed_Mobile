import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../db/app_database.dart';
import '../db/daos/entry_dao.dart';
import '../db/daos/tag_dao.dart';
import '../db/daos/attachment_dao.dart';
import '../db/daos/property_dao.dart';
import 'package:drift/drift.dart';
import '../../domain/tag_parser.dart';
import '../../domain/wikilink_parser.dart';

const _uuid = Uuid();

// ─── Modell: Entry + alle Relationen zusammengefasst ─────────────────────────
class EntryWithDetails {
  final Entry entry;
  final List<String> tags;
  final List<EntryProperty> properties;
  final List<Attachment> attachments;
  final List<String> containerIds;

  const EntryWithDetails({
    required this.entry,
    required this.tags,
    required this.properties,
    required this.attachments,
    required this.containerIds,
  });
}

// ─── Repository ───────────────────────────────────────────────────────────────
class EntryRepository {
  final AppDatabase db;
  final EntryDao entryDao;
  final TagDao tagDao;
  final AttachmentDao attachmentDao;
  final PropertyDao propertyDao;

  EntryRepository({
    required this.db,
    required this.entryDao,
    required this.tagDao,
    required this.attachmentDao,
    required this.propertyDao,
  });

  /// Feed: reaktiver Stream aller Einträge mit Details.
  /// Bulk-Load-Pattern aus Pomtechflow: eine Query pro Tabelle,
  /// dann in-memory joinen → kein N+1-Problem.
  Stream<List<EntryWithDetails>> watchAll({String sortOrder = 'desc'}) {
    // customSelect mit readsFrom auf ALLE relevanten Tabellen:
    // → Stream re-emittet auch wenn Properties, Tags oder Anhänge geändert werden
    final sql = sortOrder == 'asc'
        ? 'SELECT * FROM entries ORDER BY pinned DESC, created_at ASC'
        : 'SELECT * FROM entries ORDER BY pinned DESC, created_at DESC';
    List<EntryWithDetails> lastGood = const [];
    return db.customSelect(sql, readsFrom: {
      db.entries, db.entryProperties, db.tags,
      db.entryTags, db.attachments, db.entryContainers,
    }).watch().asyncMap((rows) async {
      // try-catch hält den Stream am Leben: eine transiente Exception würde
      // ihn sonst beenden → UI aktualisiert erst nach App-Neustart wieder.
      try {
        final ids = rows.map((r) => r.read<String>('id')).toList();
        final entryList = await Future.wait(ids.map(entryDao.getById));
        final filtered = entryList
            .whereType<Entry>()
            .where((e) => e.status != 'sub_note' && e.deletedAt == null)
            .toList();
        lastGood = await _bulkEnrich(filtered);
        return lastGood;
      } catch (e) {
        debugPrint('[Feed] watchAll Verarbeitung fehlgeschlagen, behalte '
            'letzten Stand: $e');
        return lastGood;
      }
    });
  }

  /// Sub-Notizen eines Eintrags (verknüpft via 'parent_entry_id'-Property)
  Stream<List<EntryWithDetails>> watchSubNotes(String parentEntryId) {
    return db.customSelect(
      '''
      SELECT DISTINCT e.*
      FROM entries e
      INNER JOIN entry_properties ep ON ep.entry_id = e.id
      WHERE ep.key = 'parent_entry_id' AND ep.value = ?
      ORDER BY e.created_at DESC
      ''',
      variables: [Variable.withString(parentEntryId)],
      readsFrom: {db.entries, db.entryProperties},
    ).watch().asyncMap((rows) async {
      final list = await Future.wait(rows.map((r) async {
        final id = r.read<String>('id');
        final e = await entryDao.getById(id);
        return e;
      }));
      return _bulkEnrich(list.whereType<Entry>().toList());
    });
  }

  Stream<List<EntryWithDetails>> watchByContainer(String containerId) {
    return entryDao.watchByContainer(containerId).asyncMap(_bulkEnrich);
  }

  Future<EntryWithDetails?> getById(String id) async {
    final entry = await entryDao.getById(id);
    if (entry == null) return null;
    return _enrichSingle(entry);
  }

  /// Reaktiver Stream: re-emittet bei JEDER Änderung (Properties, Tags, Anhänge)
  Stream<EntryWithDetails?> watchById(String id) {
    return db.customSelect(
      'SELECT * FROM entries WHERE id = ?',
      variables: [Variable.withString(id)],
      readsFrom: {
        db.entries, db.entryProperties, db.tags,
        db.entryTags, db.attachments, db.entryContainers,
      },
    ).watch().asyncMap((rows) async {
      try {
        if (rows.isEmpty) return null;
        final entry = await entryDao.getById(id);
        if (entry == null) return null;
        return await _enrichSingle(entry);
      } catch (e) {
        debugPrint('[Detail] watchById Verarbeitung fehlgeschlagen: $e');
        return null;
      }
    });
  }

  /// Erstellt einen neuen Eintrag.
  /// Wenn [urlTitle]/[urlDescription]/[urlImage]/[urlDomain] übergeben werden,
  /// werden sie als Properties gespeichert und der Typ wird auf 'link' gesetzt.
  Future<EntryWithDetails> createEntry({
    required String body,
    String? title,
    String type = 'text',
    String status = 'inbox',
    String? sourceUrl,
    String? urlTitle,
    String? urlDescription,
    String? urlImage,
    String? urlDomain,
    List<String> urlGenres = const [],
    int? urlScore,
    String? urlMediaType,
    // AniList-spezifisch
    String? anilistFormat,
    int? anilistEpisodes,
    int? anilistChapters,
    String? anilistStudio,
    int? anilistYear,
    String? anilistStatus,
    int? anilistSeason,
    int? anilistTotalSeasons,
    // YouTube-spezifisch
    String? urlAuthor,
    // GitHub-spezifisch
    int? githubStars,
    int? githubForks,
    String? githubLicense,
    String? githubWebsite,
    String? githubLanguage,
    String? githubDefaultBranch,
    Map<String, String> extraProps = const {},
    List<String> containerIds = const [],
  }) async {
    final id = 'e-${_uuid.v4()}';
    final now = DateTime.now().toUtc();

    final hasUrl = sourceUrl != null && sourceUrl.isNotEmpty;
    final resolvedType = hasUrl ? 'link' : type;

    // Titel: explizit, dann URL-Titel — nie automatisch aus Body extrahieren
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : (urlTitle != null && urlTitle.isNotEmpty)
            ? urlTitle
            : null;

    final companion = EntriesCompanion(
      id: Value(id),
      body: Value(body),
      title: Value(resolvedTitle),
      type: Value(resolvedType),
      status: Value(status),
      sourceUrl: Value(sourceUrl),
      createdAt: Value(now),
      updatedAt: Value(now),
    );

    await entryDao.upsert(companion);

    // Tags automatisch parsen und speichern
    final parsedTags = TagParser.parse(body);
    await tagDao.setEntryTags(id, parsedTags);

    // URL-Metadaten als Properties speichern
    if (hasUrl) {
      final props = <EntryPropertiesCompanion>[];
      void addProp(String key, String? value, String propType) {
        if (value != null && value.isNotEmpty) {
          props.add(EntryPropertiesCompanion(
            id: Value('prop-${_uuid.v4()}'),
            entryId: Value(id),
            key: Value(key),
            value: Value(value),
            type: Value(propType),
          ));
        }
      }
      addProp('og_title', urlTitle, 'string');
      addProp('og_description', urlDescription, 'string');
      addProp('og_image', urlImage, 'url');
      addProp('domain', urlDomain, 'string');
      if (urlGenres.isNotEmpty) addProp('genres', urlGenres.join(', '), 'string');
      if (urlScore != null) addProp('score', urlScore.toString(), 'number');
      if (urlMediaType != null) addProp('media_type', urlMediaType, 'string');
      // AniList-Metadaten als strukturierte Properties
      addProp('anilist_studio', anilistStudio, 'string');
      addProp('anilist_format', anilistFormat, 'string');
      if (anilistEpisodes != null) addProp('anilist_episodes', anilistEpisodes.toString(), 'number');
      if (anilistChapters != null) addProp('anilist_chapters', anilistChapters.toString(), 'number');
      if (anilistYear != null) addProp('anilist_year', anilistYear.toString(), 'string');
      addProp('anilist_status', anilistStatus, 'string');
      if (anilistSeason != null) addProp('anilist_season', anilistSeason.toString(), 'number');
      if (anilistTotalSeasons != null) addProp('anilist_total_seasons', anilistTotalSeasons.toString(), 'number');
      // YouTube (url_author als Legacy-Fallback, falls extraProps leer)
      if (extraProps.isEmpty && urlAuthor != null) {
        addProp('youtube_channel', urlAuthor, 'string');
      }
      // Generische Zusatz-Properties (BGG/VGG/RPGG)
      for (final e in extraProps.entries) {
        if (e.value.isNotEmpty) addProp(e.key, e.value, 'string');
      }
      // GitHub
      if (githubStars != null) addProp('github_stars', githubStars.toString(), 'number');
      if (githubForks != null) addProp('github_forks', githubForks.toString(), 'number');
      addProp('github_license', githubLicense, 'string');
      addProp('github_website', githubWebsite, 'url');
      addProp('github_language', githubLanguage, 'string');
      addProp('github_default_branch', githubDefaultBranch, 'string');
      if (props.isNotEmpty) {
        await propertyDao.setProperties(id, props);
      }
    }

    // Wikilinks auflösen und als EntryLinks persistieren
    final wikilinkTitles = WikilinkParser.parse(body);
    if (wikilinkTitles.isNotEmpty) {
      final resolvedIds = <String>[];
      for (final t in wikilinkTitles) {
        final target = await entryDao.findByTitle(t);
        if (target != null) resolvedIds.add(target.id);
      }
      await propertyDao.setOutgoingLinks(id, resolvedIds);
    }

    // Container-Zuordnungen
    if (containerIds.isNotEmpty) {
      await entryDao.setContainers(id, containerIds);
    }

    return (await getById(id))!;
  }

  Future<EntryWithDetails> updateEntry(
    String id, {
    String? body,
    String? title,
    String? status,
    bool? pinned,
    List<String>? containerIds,
    DateTime? reminderAt,
    bool clearReminder = false,
  }) async {
    final existing = await entryDao.getById(id);
    if (existing == null) throw StateError('Entry $id nicht gefunden');

    // Journal: Snapshot VOR der Änderung für Undo (nur bei inhaltlichen
    // Änderungen — Pin/Reminder sind trivial und werden nicht protokolliert).
    String? logId;
    if (body != null || title != null || status != null) {
      final desc = status != null
          ? 'Status geändert → ${_statusLabel(status)}'
          : (title != null && body == null
              ? 'Titel geändert'
              : 'Text geändert');
      logId = await _logChange(id, status != null ? 'status' : 'edit', desc);
    }

    await entryDao.upsert(EntriesCompanion(
      id: Value(id),
      body: body != null ? Value(body) : Value(existing.body),
      title: title != null ? Value(title) : Value(existing.title),
      status: status != null ? Value(status) : Value(existing.status),
      pinned: pinned != null ? Value(pinned) : Value(existing.pinned),
      reminderAt: clearReminder
          ? const Value(null)
          : reminderAt != null
              ? Value(reminderAt.toUtc())
              : Value(existing.reminderAt),
      updatedAt: Value(DateTime.now().toUtc()),
    ));

    if (body != null) {
      await tagDao.setEntryTags(id, TagParser.parse(body));
      // Wikilinks neu auflösen
      final titles = WikilinkParser.parse(body);
      final resolved = <String>[];
      for (final t in titles) {
        final target = await entryDao.findByTitle(t);
        if (target != null) resolved.add(target.id);
      }
      await propertyDao.setOutgoingLinks(id, resolved);
    }
    if (containerIds != null) {
      await entryDao.setContainers(id, containerIds);
    }

    await _finalizeLog(logId, id);
    return (await getById(id))!;
  }

  /// Setzt die Properties eines Eintrags und protokolliert die Änderung
  /// (Undo/Redo). Zentraler Einstieg statt direktem propertyDao.setProperties.
  Future<void> setEntryProperties(
      String entryId, List<EntryPropertiesCompanion> props,
      {String description = 'Eigenschaften geändert'}) async {
    final logId = await _logChange(entryId, 'edit', description);
    await propertyDao.setProperties(entryId, props);
    await _finalizeLog(logId, entryId);
  }

  /// Verschiebt Eintrag in den Papierkorb (Soft-Delete, Tombstone für Sync).
  Future<void> deleteEntry(String id) async {
    final logId = await _logChange(id, 'delete', 'In den Papierkorb verschoben');
    await entryDao.softDelete(id);
    await _finalizeLog(logId, id);
  }

  // ── Änderungs-Journal & Undo ────────────────────────────────────────────────

  static String _statusLabel(String s) => switch (s) {
        'done' => 'Erledigt',
        'archived' => 'Archiviert',
        'inbox' => 'Inbox',
        _ => s,
      };

  /// Serialisiert den aktuellen Zustand eines Eintrags inkl. Relationen.
  Future<String?> _snapshotJson(String id) async {
    final e = await entryDao.getById(id);
    if (e == null) return null;
    final containerIds = await entryDao.getContainerIds(id);
    final props = await (db.select(db.entryProperties)
          ..where((p) => p.entryId.equals(id)))
        .get();
    final tagRows = await (db.select(db.entryTags)
          ..where((t) => t.entryId.equals(id)))
        .get();
    final tagNames = <String>[];
    for (final tr in tagRows) {
      final tag = await (db.select(db.tags)..where((t) => t.id.equals(tr.tagId)))
          .getSingleOrNull();
      if (tag != null) tagNames.add(tag.name);
    }
    return jsonEncode({
      'id': e.id,
      'createdAt': e.createdAt.toIso8601String(),
      'updatedAt': e.updatedAt.toIso8601String(),
      'type': e.type,
      'title': e.title,
      'body': e.body,
      'status': e.status,
      'pinned': e.pinned,
      'reminderAt': e.reminderAt?.toIso8601String(),
      'sourceUrl': e.sourceUrl,
      'sourceApp': e.sourceApp,
      'lang': e.lang,
      'deletedAt': e.deletedAt?.toIso8601String(),
      'tags': tagNames,
      'containers': containerIds,
      'properties': props
          .map((p) => {'key': p.key, 'value': p.value, 'type': p.type})
          .toList(),
    });
  }

  /// Protokolliert eine Konflikt-Entscheidung (für Undo). Nur für Einträge —
  /// speichert den lokalen Zustand VOR dem Anwenden der Entscheidung.
  Future<String?> logConflictChoice(String entityId, bool serverWins) =>
      _logChange(
        entityId,
        serverWins ? 'conflict_server' : 'conflict_mine',
        serverWins
            ? 'Konflikt: Server-Version übernommen'
            : 'Konflikt: eigene Version behalten',
      );

  /// Protokolliert den Vorzustand und gibt die Log-ID zurück (für _finalizeLog).
  Future<String?> _logChange(
      String entityId, String action, String description) async {
    try {
      final snap = await _snapshotJson(entityId);
      final id = 'cl-${_uuid.v4()}';
      await db.changeLogDao.add(ChangeLogCompanion(
        id: Value(id),
        entityType: const Value('entry'),
        entityId: Value(entityId),
        action: Value(action),
        description: Value(description),
        beforeJson: Value(snap),
      ));
      return id;
    } catch (e) {
      debugPrint('[Journal] Logging fehlgeschlagen: $e');
      return null;
    }
  }

  /// Trägt den Nachzustand (afterJson) nach → ermöglicht Redo.
  Future<void> _finalizeLog(String? logId, String entityId) async {
    if (logId == null) return;
    try {
      final snap = await _snapshotJson(entityId);
      if (snap != null) await db.changeLogDao.setAfterJson(logId, snap);
    } catch (e) {
      debugPrint('[Journal] afterJson nachtragen fehlgeschlagen: $e');
    }
  }

  /// Macht eine protokollierte Änderung rückgängig (stellt beforeJson her).
  Future<void> undoChange(String logId) async {
    final log = await db.changeLogDao.getById(logId);
    if (log == null || log.undone || log.beforeJson == null) return;
    final data = jsonDecode(log.beforeJson!) as Map<String, dynamic>;
    await _restoreSnapshot(data);
    await db.changeLogDao.setUndone(logId, true);
  }

  /// Wiederholt eine rückgängig gemachte Änderung (stellt afterJson her).
  Future<void> redoChange(String logId) async {
    final log = await db.changeLogDao.getById(logId);
    if (log == null || !log.undone || log.afterJson == null) return;
    final data = jsonDecode(log.afterJson!) as Map<String, dynamic>;
    await _restoreSnapshot(data);
    await db.changeLogDao.setUndone(logId, false);
  }

  Future<void> _restoreSnapshot(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    await db.transaction(() async {
      await entryDao.upsert(EntriesCompanion(
        id: Value(id),
        createdAt: Value(DateTime.tryParse(data['createdAt'] as String? ?? '')
                ?.toUtc() ??
            DateTime.now().toUtc()),
        // updatedAt auf jetzt → gilt als neueste Version (gewinnt beim Sync)
        updatedAt: Value(DateTime.now().toUtc()),
        type: Value(data['type'] as String? ?? 'text'),
        title: Value(data['title'] as String?),
        body: Value(data['body'] as String? ?? ''),
        status: Value(data['status'] as String? ?? 'inbox'),
        pinned: Value(data['pinned'] as bool? ?? false),
        reminderAt: Value(data['reminderAt'] != null
            ? DateTime.tryParse(data['reminderAt'] as String)
            : null),
        sourceUrl: Value(data['sourceUrl'] as String?),
        sourceApp: Value(data['sourceApp'] as String?),
        lang: Value(data['lang'] as String?),
        // deletedAt aus Snapshot wiederherstellen (Undo eines Löschens → null)
        deletedAt: Value(data['deletedAt'] != null
            ? DateTime.tryParse(data['deletedAt'] as String)
            : null),
      ));

      // Tags wiederherstellen
      final tags = (data['tags'] as List<dynamic>?)?.cast<String>() ?? [];
      await tagDao.setEntryTags(id, tags);

      // Container-Zuordnungen
      final containers =
          (data['containers'] as List<dynamic>?)?.cast<String>() ?? [];
      await entryDao.setContainers(id, containers);

      // Properties
      await (db.delete(db.entryProperties)..where((p) => p.entryId.equals(id))).go();
      final props = (data['properties'] as List<dynamic>?) ?? [];
      for (final pr in props) {
        final m = pr as Map<String, dynamic>;
        final key = m['key'] as String? ?? '';
        if (key.isEmpty) continue;
        await db.into(db.entryProperties).insertOnConflictUpdate(
          EntryPropertiesCompanion(
            id: Value('prop-$id-$key'),
            entryId: Value(id),
            key: Value(key),
            value: Value(m['value'] as String?),
            type: Value(m['type'] as String? ?? 'text'),
          ),
        );
      }
    });
  }

  /// Stellt einen Eintrag aus dem Papierkorb wieder her.
  Future<void> restoreEntry(String id) => entryDao.restore(id);

  /// Löscht einen Eintrag endgültig (nur aus dem Papierkorb heraus).
  Future<void> permanentlyDeleteEntry(String id) => entryDao.permanentlyDelete(id);

  /// Leert den kompletten Papierkorb.
  Future<void> emptyTrash() => entryDao.emptyTrash();

  Future<List<EntryWithDetails>> search(String query) async {
    final entries = await db.searchFts(query);
    return _bulkEnrich(entries);
  }

  // ─── Interne Helfer ────────────────────────────────────────────────────────

  Future<List<EntryWithDetails>> _bulkEnrich(List<Entry> entries) async {
    if (entries.isEmpty) return [];
    final ids = entries.map((e) => e.id).toList();

    // Parallel laden
    final results = await Future.wait([
      _bulkTags(ids),
      _bulkProperties(ids),
      _bulkAttachments(ids),
      _bulkContainers(ids),
    ]);

    final tagsMap = results[0] as Map<String, List<String>>;
    final propsMap = results[1] as Map<String, List<EntryProperty>>;
    final attachMap = results[2] as Map<String, List<Attachment>>;
    final containerMap = results[3] as Map<String, List<String>>;

    return entries.map((e) => EntryWithDetails(
          entry: e,
          tags: tagsMap[e.id] ?? [],
          properties: propsMap[e.id] ?? [],
          attachments: attachMap[e.id] ?? [],
          containerIds: containerMap[e.id] ?? [],
        )).toList();
  }

  Future<EntryWithDetails> _enrichSingle(Entry entry) async {
    final enriched = await _bulkEnrich([entry]);
    return enriched.first;
  }

  Future<Map<String, List<String>>> _bulkTags(List<String> ids) async {
    final result = <String, List<String>>{};
    for (final id in ids) {
      result[id] = await tagDao.getTagNamesForEntry(id);
    }
    return result;
  }

  Future<Map<String, List<EntryProperty>>> _bulkProperties(
      List<String> ids) async {
    final result = <String, List<EntryProperty>>{};
    for (final id in ids) {
      result[id] = await propertyDao.watchByEntry(id).first;
    }
    return result;
  }

  Future<Map<String, List<Attachment>>> _bulkAttachments(
      List<String> ids) async {
    final result = <String, List<Attachment>>{};
    for (final id in ids) {
      result[id] = await attachmentDao.watchByEntry(id).first;
    }
    return result;
  }

  Future<Map<String, List<String>>> _bulkContainers(List<String> ids) async {
    final result = <String, List<String>>{};
    for (final id in ids) {
      result[id] = await entryDao.getContainerIds(id);
    }
    return result;
  }

}

