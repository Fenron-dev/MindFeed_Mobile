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
    return entryDao.watchAll(sortOrder: sortOrder).asyncMap(_bulkEnrich);
  }

  Stream<List<EntryWithDetails>> watchByContainer(String containerId) {
    return entryDao.watchByContainer(containerId).asyncMap(_bulkEnrich);
  }

  Future<EntryWithDetails?> getById(String id) async {
    final entry = await entryDao.getById(id);
    if (entry == null) return null;
    return _enrichSingle(entry);
  }

  /// Reaktiver Stream: aktualisiert sich automatisch nach Edits
  Stream<EntryWithDetails?> watchById(String id) {
    return entryDao.watchById(id).asyncMap((entry) async {
      if (entry == null) return null;
      return _enrichSingle(entry);
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
    List<String> containerIds = const [],
  }) async {
    final id = 'e-${_uuid.v4()}';
    final now = DateTime.now().toUtc();

    final hasUrl = sourceUrl != null && sourceUrl.isNotEmpty;
    final resolvedType = hasUrl ? 'link' : type;

    // Titel: URL-Titel bevorzugen, dann explizit, dann aus Body
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : (urlTitle != null && urlTitle.isNotEmpty)
            ? urlTitle
            : _extractTitle(body);

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
  }) async {
    final existing = await entryDao.getById(id);
    if (existing == null) throw StateError('Entry $id nicht gefunden');

    await entryDao.upsert(EntriesCompanion(
      id: Value(id),
      body: body != null ? Value(body) : Value(existing.body),
      title: title != null ? Value(title) : Value(existing.title),
      status: status != null ? Value(status) : Value(existing.status),
      pinned: pinned != null ? Value(pinned) : Value(existing.pinned),
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

    return (await getById(id))!;
  }

  Future<void> deleteEntry(String id) => entryDao.deleteById(id);

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

  String _extractTitle(String body) {
    final firstLine = body.split('\n').first.replaceAll(RegExp(r'[#*`_]'), '').trim();
    if (firstLine.isEmpty) return 'Neue Aufzeichnung';
    return firstLine.length > 50 ? '${firstLine.substring(0, 50)}…' : firstLine;
  }
}

