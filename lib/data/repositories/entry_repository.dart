import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../core/vault_manager.dart';
import '../db/app_database.dart';
import '../db/daos/entry_dao.dart';
import '../db/daos/tag_dao.dart';
import '../db/daos/attachment_dao.dart';
import '../db/daos/property_dao.dart';
import 'package:drift/drift.dart';
import '../../domain/tag_parser.dart';
import '../../domain/task_parser.dart';
import '../../domain/recurrence_calculator.dart';
import '../../domain/wikilink_parser.dart';
import '../../services/notification_service.dart';

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
        // Rows enthalten bereits alle Entry-Spalten (SELECT *) → direkt mappen
        // statt N× getById (vermeidet N+1).
        final filtered = rows
            .map((r) => db.entries.map(r.data))
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

  /// Alle Tasks die aus einer bestimmten Notiz (inline) erstellt wurden.
  Stream<List<EntryWithDetails>> watchTasksBySourceNote(String noteId) {
    return db.customSelect(
      '''
      SELECT DISTINCT e.*
      FROM entries e
      INNER JOIN entry_properties ep ON ep.entry_id = e.id
      WHERE ep.key = 'task_source_entry_id' AND ep.value = ?
        AND e.type = 'task' AND e.deleted_at IS NULL
      ORDER BY e.created_at ASC
      ''',
      variables: [Variable.withString(noteId)],
      readsFrom: {db.entries, db.entryProperties},
    ).watch().asyncMap((rows) async {
      final entries = rows.map((r) => db.entries.map(r.data)).toList();
      return _bulkEnrich(entries);
    });
  }

  /// Verarbeitet Inline-Task-Zeilen nach dem Speichern einer Notiz:
  /// Erstellt Task-Entries für neue Zeilen und injiziert Block-Refs in den Body.
  /// Gibt den aktualisierten Body zurück (oder den originalen wenn keine Änderung).
  Future<String> processInlineTasks(String entryId, String body) async {
    final lines = TaskParser.parse(body);
    if (lines.isEmpty) return body;

    // Nur neue Zeilen ohne Block-Ref verarbeiten
    final newLines = lines.where((l) => l.blockRef == null).toList();
    if (newLines.isEmpty) return body;

    String updatedBody = body;

    for (final line in newLines) {
      final task = await createTask(
        title: line.title.isEmpty ? 'Aufgabe' : line.title,
        dueAt: line.dueDate,
        priority: line.priority,
        sourceEntryId: entryId,
      );
      // Block-Ref injizieren (Position relativ zu updatedBody aktualisieren)
      final freshLines = TaskParser.parse(updatedBody);
      final matchLine = freshLines.firstWhere(
        (l) =>
            l.blockRef == null &&
            l.title == line.title &&
            l.isDone == line.isDone,
        orElse: () => line,
      );
      updatedBody =
          TaskParser.injectBlockRef(updatedBody, matchLine, task.entry.id);
    }

    return updatedBody;
  }

  /// Reaktiver Stream aller Tasks (type='task'), nach Fälligkeit sortiert.
  Stream<List<EntryWithDetails>> watchTasks() {
    return db.customSelect(
      '''
      SELECT * FROM entries
      WHERE type = 'task' AND deleted_at IS NULL
      ORDER BY
        CASE WHEN reminder_at IS NULL THEN 1 ELSE 0 END,
        reminder_at ASC,
        created_at DESC
      ''',
      readsFrom: {
        db.entries, db.entryProperties, db.tags,
        db.entryTags, db.entryContainers,
      },
    ).watch().asyncMap((rows) async {
      final entries = rows
          .map((r) => db.entries.map(r.data))
          .where((e) => e.deletedAt == null)
          .toList();
      return _bulkEnrich(entries);
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
      final entries = rows.map((r) => db.entries.map(r.data)).toList();
      return _bulkEnrich(entries);
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
    // Video-Plattformen → eigener Typ 'video', sonst 'link'
    final isVideoUrl = hasUrl && _isVideoUrl(sourceUrl, urlDomain, urlMediaType);
    final resolvedType = hasUrl ? (isVideoUrl ? 'video' : 'link') : type;

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

  /// Fügt dem Eintrag einen Tag hinzu (in-place, andere bleiben).
  Future<void> addTag(String entryId, String tagName) async {
    final clean = tagName.trim().replaceAll(RegExp(r'^#'), '');
    if (clean.isEmpty) return;
    await tagDao.addEntryTag(entryId, clean.toLowerCase());
    await entryDao.upsert(EntriesCompanion(
        id: Value(entryId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Entfernt einen Tag vom Eintrag.
  Future<void> removeTag(String entryId, String tagName) async {
    await tagDao.removeEntryTag(entryId, tagName);
    await entryDao.upsert(EntriesCompanion(
        id: Value(entryId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Aktualisiert genau eine Property in-place (für Toggle/Rating/Wert-Edit).
  /// Kein Lösch-/Neu-Schreiben aller Properties → kein Scroll-Sprung, kein
  /// Changelog-Spam. Touch der updatedAt für Sync.
  Future<void> setPropertyValue(
      String entryId, String propId, String? value) async {
    await propertyDao.updateValue(propId, value);
    await entryDao.upsert(EntriesCompanion(
        id: Value(entryId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Fügt eine einzelne Property hinzu (ohne andere zu berühren).
  Future<void> addProperty(
      String entryId, String key, String? value, String type) async {
    await db.into(db.entryProperties).insertOnConflictUpdate(
      EntryPropertiesCompanion(
        id: Value('prop-${_uuid.v4()}'),
        entryId: Value(entryId),
        key: Value(key),
        value: Value(value),
        type: Value(type),
      ),
    );
    await entryDao.upsert(EntriesCompanion(
        id: Value(entryId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Setzt eine Property per Key (für Sammelbearbeitung). [append]=true hängt
  /// an den bestehenden Wert an (komma-getrennt), sonst ersetzen. Fehlt der Key,
  /// wird er angelegt.
  Future<void> setPropertyByKey(
      String entryId, String key, String? value, String type,
      {bool append = false}) async {
    final existing = await (db.select(db.entryProperties)
          ..where((p) => p.entryId.equals(entryId) & p.key.equals(key)))
        .getSingleOrNull();
    if (existing == null) {
      await addProperty(entryId, key, value, type);
      return;
    }
    final newVal = append
        ? [existing.value ?? '', value ?? '']
            .where((s) => s.trim().isNotEmpty)
            .join(', ')
        : value;
    await propertyDao.updateValue(existing.id, newVal);
    await entryDao.upsert(EntriesCompanion(
        id: Value(entryId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Entfernt eine Property per Key (für Sammelbearbeitung).
  Future<void> removePropertyByKey(String entryId, String key) async {
    await (db.delete(db.entryProperties)
          ..where((p) => p.entryId.equals(entryId) & p.key.equals(key)))
        .go();
    await entryDao.upsert(EntriesCompanion(
        id: Value(entryId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Löscht eine einzelne Property anhand ihrer ID.
  Future<void> deletePropertyById(String entryId, String propId) async {
    await (db.delete(db.entryProperties)..where((p) => p.id.equals(propId))).go();
    await entryDao.upsert(EntriesCompanion(
        id: Value(entryId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Verschiebt Eintrag in den Papierkorb (Soft-Delete, Tombstone für Sync).
  Future<void> deleteEntry(String id) async {
    final logId = await _logChange(id, 'delete', 'In den Papierkorb verschoben');
    await entryDao.softDelete(id);
    // Geplante Erinnerung entfernen
    await NotificationService.cancel(NotificationService.idFromEntryId(id));
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

  // ─── Task-spezifische Methoden ────────────────────────────────────────────────

  /// Erstellt einen neuen Task-Entry mit optionalen Task-Properties.
  Future<EntryWithDetails> createTask({
    required String title,
    String body = '',
    DateTime? dueAt,
    String? priority,
    List<String> containerIds = const [],
    String? sourceEntryId,
  }) async {
    final id = 'e-${_uuid.v4()}';
    final now = DateTime.now().toUtc();

    final companion = EntriesCompanion(
      id: Value(id),
      body: Value(body),
      title: Value(title.trim().isEmpty ? null : title.trim()),
      type: const Value('task'),
      status: const Value('inbox'),
      reminderAt: Value(dueAt?.toUtc()),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
    await entryDao.upsert(companion);

    // Tags aus Body parsen
    if (body.isNotEmpty) {
      await tagDao.setEntryTags(id, TagParser.parse(body));
    }

    // Task-Properties speichern
    final props = <EntryPropertiesCompanion>[];
    void addProp(String key, String? val, String type) {
      if (val != null && val.isNotEmpty) {
        props.add(EntryPropertiesCompanion(
          id: Value('prop-$id-$key'),
          entryId: Value(id),
          key: Value(key),
          value: Value(val),
          type: Value(type),
        ));
      }
    }
    addProp('task_priority', priority, 'select');
    addProp('task_source_entry_id', sourceEntryId, 'text');
    if (props.isNotEmpty) await propertyDao.setProperties(id, props);

    if (containerIds.isNotEmpty) {
      await entryDao.setContainers(id, containerIds);
    }

    // Push-Erinnerung planen, falls Fälligkeitsdatum in der Zukunft liegt
    if (dueAt != null) await syncTaskNotification(id);

    return (await getById(id))!;
  }

  /// Wechselt den Status eines Tasks zwischen offen (inbox) und erledigt (done).
  /// Bei wiederkehrenden Tasks wird automatisch die nächste Instanz erstellt.
  Future<void> toggleTaskStatus(String id) async {
    final existing = await entryDao.getById(id);
    if (existing == null || existing.type != 'task') return;

    final isDone = existing.status == 'done';
    final newStatus = isDone ? 'inbox' : 'done';
    final completedAt = isDone ? null : DateTime.now().toUtc().toIso8601String();

    final logId = await _logChange(id, 'status',
        isDone ? 'Aufgabe wieder geöffnet' : 'Aufgabe erledigt');

    await entryDao.upsert(EntriesCompanion(
      id: Value(id),
      status: Value(newStatus),
      updatedAt: Value(DateTime.now().toUtc()),
    ));

    await db.into(db.entryProperties).insertOnConflictUpdate(
      EntryPropertiesCompanion(
        id: Value('prop-$id-task_completed_at'),
        entryId: Value(id),
        key: const Value('task_completed_at'),
        value: Value(completedAt),
        type: const Value('date'),
      ),
    );

    // Wiederkehrende Task: nächste Instanz erstellen wenn gerade erledigt
    if (!isDone && existing.reminderAt != null) {
      final enriched = await getById(id);
      if (enriched != null) {
        final rrule = getTaskProperty(enriched, 'task_recurrence');
        final seriesId = getTaskProperty(enriched, 'task_series_id') ??
            RecurrenceHelper.generateSeriesId();
        final nextDue =
            RecurrenceHelper.nextDueDate(existing.reminderAt!, rrule);
        if (nextDue != null) {
          await _createRecurringInstance(enriched, nextDue, seriesId);
          // Aktuelle Instanz mit seriesId markieren falls noch nicht vorhanden
          if (getTaskProperty(enriched, 'task_series_id') == null) {
            await setTaskProperty(id, 'task_series_id', seriesId, type: 'text');
          }
        }
      }
    }

    // Erinnerung aktualisieren: erledigt → löschen, wieder geöffnet → ggf. neu planen
    await syncTaskNotification(id);

    await _finalizeLog(logId, id);
  }

  /// Erstellt eine neue Instanz eines wiederkehrenden Tasks.
  Future<void> _createRecurringInstance(
      EntryWithDetails template, DateTime dueAt, String seriesId) async {
    final title = template.entry.title ?? 'Aufgabe';
    final priority = getTaskProperty(template, 'task_priority');
    final rrule = getTaskProperty(template, 'task_recurrence');
    final sourceNoteId = getTaskProperty(template, 'task_source_entry_id');

    final newTask = await createTask(
      title: title,
      body: template.entry.body,
      dueAt: dueAt,
      priority: priority,
      containerIds: template.containerIds,
      sourceEntryId: sourceNoteId,
    );

    // Series-ID + Wiederholungsregel übertragen
    await setTaskProperty(newTask.entry.id, 'task_series_id', seriesId,
        type: 'text');
    if (rrule != null) {
      await setTaskProperty(newTask.entry.id, 'task_recurrence', rrule,
          type: 'text');
    }
  }

  /// Löscht einen Task: optional alle folgenden Instanzen der Series.
  Future<void> deleteTask(String id, {bool andFollowing = false}) async {
    if (!andFollowing) {
      await deleteEntry(id);
      return;
    }

    // Task laden um Series-ID und Fälligkeitsdatum zu lesen
    final task = await getById(id);
    if (task == null) {
      await deleteEntry(id);
      return;
    }
    final seriesId = getTaskProperty(task, 'task_series_id');
    if (seriesId == null) {
      await deleteEntry(id);
      return;
    }

    // Alle Instanzen der Serie mit dueDate >= dieser Instanz löschen
    final currentDue = task.entry.reminderAt;
    final allSeries = await db.customSelect(
      '''
      SELECT DISTINCT e.id, e.reminder_at
      FROM entries e
      INNER JOIN entry_properties ep ON ep.entry_id = e.id
      WHERE ep.key = 'task_series_id' AND ep.value = ?
        AND e.deleted_at IS NULL
      ''',
      variables: [Variable.withString(seriesId)],
      readsFrom: {db.entries, db.entryProperties},
    ).get();

    for (final row in allSeries) {
      final rowId = row.read<String>('id');
      final rowDue = row.readNullable<DateTime>('reminder_at');
      if (currentDue == null || rowDue == null || !rowDue.isBefore(currentDue)) {
        await deleteEntry(rowId);
      }
    }
  }

  /// Plant oder löscht die Push-Erinnerung für einen Task anhand seines
  /// Fälligkeitsdatums (reminderAt) und Status. Offen + zukünftig → planen,
  /// sonst → vorhandene Erinnerung löschen.
  Future<void> syncTaskNotification(String id) async {
    final e = await entryDao.getById(id);
    final notifId = NotificationService.idFromEntryId(id);
    if (e == null || e.type != 'task') {
      await NotificationService.cancel(notifId);
      return;
    }
    final due = e.reminderAt?.toLocal();
    final active = e.status != 'done' && e.status != 'archived';
    if (due != null && active && due.isAfter(DateTime.now())) {
      await NotificationService.schedule(
        id: notifId,
        title: 'Aufgabe fällig',
        body: e.title ?? e.body,
        when: due,
      );
    } else {
      await NotificationService.cancel(notifId);
    }
  }

  /// Setzt eine einzelne Task-Property (z.B. task_priority, task_recurrence).
  Future<void> setTaskProperty(String entryId, String key, String? value,
      {String type = 'text'}) async {
    await db.into(db.entryProperties).insertOnConflictUpdate(
      EntryPropertiesCompanion(
        id: Value('prop-$entryId-$key'),
        entryId: Value(entryId),
        key: Value(key),
        value: Value(value),
        type: Value(type),
      ),
    );
    await entryDao.upsert(EntriesCompanion(
      id: Value(entryId),
      updatedAt: Value(DateTime.now().toUtc()),
    ));
  }

  /// Liest einen Task-Property-Wert aus einer bereits geladenen EntryWithDetails.
  static String? getTaskProperty(EntryWithDetails task, String key) {
    return task.properties
        .where((p) => p.key == key)
        .map((p) => p.value)
        .firstOrNull;
  }

  // ─── Manuelle Verknüpfungen ────────────────────────────────────────────────

  /// Verknüpft [fromId] manuell mit [toId] (bidirektional auffindbar via Backlinks).
  Future<void> addLink(String fromId, String toId) async {
    if (fromId == toId) return;
    await propertyDao.addManualLink(fromId, toId);
    await entryDao.upsert(EntriesCompanion(
        id: Value(fromId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Entfernt eine Verknüpfung zwischen [fromId] und [toId].
  Future<void> removeLink(String fromId, String toId) async {
    await propertyDao.removeLink(fromId, toId);
    await entryDao.upsert(EntriesCompanion(
        id: Value(fromId), updatedAt: Value(DateTime.now().toUtc())));
  }

  /// Reaktiver Stream der ausgehenden Verknüpfungen eines Eintrags (als Details).
  Stream<List<EntryWithDetails>> watchOutgoingLinks(String fromId) {
    return db.customSelect(
      '''
      SELECT e.* FROM entries e
      INNER JOIN entry_links l ON l.to_id = e.id
      WHERE l.from_id = ? AND e.deleted_at IS NULL
      ORDER BY e.updated_at DESC
      ''',
      variables: [Variable.withString(fromId)],
      readsFrom: {db.entries, db.entryLinks},
    ).watch().asyncMap((rows) async {
      final entries = rows.map((r) => db.entries.map(r.data)).toList();
      return _bulkEnrich(entries);
    });
  }

  /// Kopiert eine Datei ins Vault und hängt sie als Attachment an [entryId].
  /// Wiederverwendbar für nachträgliches Hinzufügen (Detail-Screen, Drag&Drop).
  Future<void> addAttachment(String entryId, String sourcePath,
      {String? fileName}) async {
    final src = File(sourcePath);
    if (!src.existsSync()) return;
    final base = await VaultManager.getAttachmentsPath();
    final now = DateTime.now();
    final subDir = Directory(
        p.join(base, '${now.year}', now.month.toString().padLeft(2, '0')));
    await subDir.create(recursive: true);
    final ext = p.extension(sourcePath).toLowerCase();
    final dest = p.join(subDir.path, '${now.millisecondsSinceEpoch}$ext');
    await src.copy(dest);

    final mime = _mimeForExt(ext.replaceFirst('.', ''));
    final type = _attachmentType(mime);
    await attachmentDao.upsert(AttachmentsCompanion(
      id: Value('att-${_uuid.v4()}'),
      entryId: Value(entryId),
      type: Value(type),
      mimeType: Value(mime),
      localPath: Value(dest),
      fileName: Value(fileName ?? p.basename(sourcePath)),
      fileSize: Value(await File(dest).length()),
    ));
    await entryDao.upsert(EntriesCompanion(
        id: Value(entryId), updatedAt: Value(DateTime.now().toUtc())));
  }

  static bool _isVideoUrl(String url, String? domain, String? mediaType) {
    if (mediaType != null &&
        (mediaType.toLowerCase().contains('video') ||
         mediaType.toLowerCase() == 'youtube')) {
      return true;
    }
    final u = url.toLowerCase();
    return u.contains('youtube.com/watch') || u.contains('youtu.be/') ||
        u.contains('vimeo.com/') || (domain == 'youtube.com');
  }

  static String _mimeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      case 'heic': return 'image/heic';
      case 'mp4': case 'm4v': return 'video/mp4';
      case 'mov': return 'video/quicktime';
      case 'mp3': return 'audio/mpeg';
      case 'm4a': return 'audio/mp4';
      case 'wav': return 'audio/wav';
      case 'pdf': return 'application/pdf';
      default: return 'application/octet-stream';
    }
  }

  static String _attachmentType(String mime) {
    if (mime.startsWith('image/')) return 'image';
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('audio/')) return 'audio';
    return 'document';
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

  // Echte Bulk-Queries (eine Query pro Tabelle via WHERE IN), statt N+1.
  // Wichtig: KEINE .watch().first-Streams — die würden pro Eintrag eine
  // Drift-Query-Stream-Subscription erzeugen und bei jeder DB-Änderung neu
  // feuern → das hat den Feed eingefroren.

  Future<Map<String, List<String>>> _bulkTags(List<String> ids) async {
    final result = {for (final id in ids) id: <String>[]};
    if (ids.isEmpty) return result;
    final rows = await db.customSelect(
      'SELECT et.entry_id AS eid, t.name AS name '
      'FROM entry_tags et INNER JOIN tags t ON t.id = et.tag_id '
      'WHERE et.entry_id IN (${_placeholders(ids)})',
      variables: ids.map(Variable.withString).toList(),
      readsFrom: {db.entryTags, db.tags},
    ).get();
    for (final r in rows) {
      result[r.read<String>('eid')]?.add(r.read<String>('name'));
    }
    return result;
  }

  Future<Map<String, List<EntryProperty>>> _bulkProperties(
      List<String> ids) async {
    final result = {for (final id in ids) id: <EntryProperty>[]};
    if (ids.isEmpty) return result;
    final rows = await (db.select(db.entryProperties)
          ..where((p) => p.entryId.isIn(ids)))
        .get();
    for (final p in rows) {
      result[p.entryId]?.add(p);
    }
    return result;
  }

  Future<Map<String, List<Attachment>>> _bulkAttachments(
      List<String> ids) async {
    final result = {for (final id in ids) id: <Attachment>[]};
    if (ids.isEmpty) return result;
    final rows = await (db.select(db.attachments)
          ..where((a) => a.entryId.isIn(ids))
          ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]))
        .get();
    for (final a in rows) {
      result[a.entryId]?.add(a);
    }
    return result;
  }

  Future<Map<String, List<String>>> _bulkContainers(List<String> ids) async {
    final result = {for (final id in ids) id: <String>[]};
    if (ids.isEmpty) return result;
    final rows = await (db.select(db.entryContainers)
          ..where((ec) => ec.entryId.isIn(ids)))
        .get();
    for (final ec in rows) {
      result[ec.entryId]?.add(ec.containerId);
    }
    return result;
  }

  static String _placeholders(List<String> ids) =>
      List.filled(ids.length, '?').join(', ');

}

