
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'tables/entries.dart';
import 'tables/tags.dart';
import 'tables/containers.dart';
import 'tables/attachments.dart';
import 'tables/properties.dart';
import 'daos/entry_dao.dart';
import 'daos/tag_dao.dart';
import 'daos/container_dao.dart';
import 'daos/attachment_dao.dart';
import 'daos/property_dao.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Entries,
    Tags,
    EntryTags,
    Containers,
    EntryContainers,
    Attachments,
    EntryProperties,
    EntryLinks,
  ],
  daos: [
    EntryDao,
    TagDao,
    ContainerDao,
    AttachmentDao,
    PropertyDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(String dbPath)
      : super(
          driftDatabase(
            name: dbPath,
            native: DriftNativeOptions(
              databasePath: () async => dbPath,
            ),
          ),
        );

  /// In-memory DB für Tests
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createFts5();
          await _createIndexes();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(entries, entries.deletedAt);
            await m.addColumn(containers, containers.updatedAt);
            await m.addColumn(containers, containers.deletedAt);
            // Backfill updatedAt für bestehende Container
            await customStatement(
                'UPDATE containers SET updated_at = created_at WHERE updated_at IS NULL');
          }
          if (from < 3) {
            await m.addColumn(containers, containers.syncUpdatedAt);
            // Bestehende Daten gelten als bereits abgeglichen → Shadow = updatedAt,
            // damit sie nicht beim ersten Sync als "dirty" zurückgepusht werden.
            await customStatement(
                'UPDATE containers SET sync_updated_at = updated_at');
            await customStatement(
                'UPDATE entries SET sync_updated_at = updated_at '
                'WHERE sync_updated_at IS NULL AND deleted_at IS NULL');
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA synchronous = NORMAL');
        },
      );

  Future<void> _createFts5() async {
    // FTS5-Index auf title + body für Volltextsuche
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts
      USING fts5(
        title,
        body,
        content='entries',
        content_rowid='rowid',
        tokenize='unicode61'
      )
    ''');

    // Sync-Trigger: INSERT
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS entries_ai
      AFTER INSERT ON entries BEGIN
        INSERT INTO entries_fts(rowid, title, body)
          VALUES (new.rowid, COALESCE(new.title, ''), new.body);
      END
    ''');

    // Sync-Trigger: UPDATE
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS entries_au
      AFTER UPDATE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, title, body)
          VALUES ('delete', old.rowid, COALESCE(old.title, ''), old.body);
        INSERT INTO entries_fts(rowid, title, body)
          VALUES (new.rowid, COALESCE(new.title, ''), new.body);
      END
    ''');

    // Sync-Trigger: DELETE
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS entries_ad
      AFTER DELETE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, title, body)
          VALUES ('delete', old.rowid, COALESCE(old.title, ''), old.body);
      END
    ''');
  }

  Future<void> _createIndexes() async {
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_entries_status ON entries(status)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_entries_created ON entries(created_at DESC)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_entries_pinned ON entries(pinned)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tags_name ON tags(name)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_entry_tags_entry ON entry_tags(entry_id)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_entry_containers_entry ON entry_containers(entry_id)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_attachments_entry ON attachments(entry_id)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_properties_entry ON entry_properties(entry_id)');
  }

  /// Suche: FTS5 mit LIKE-Fallback (Fuzzy).
  /// Gibt alle Entries zurück wenn query leer ist.
  Future<List<Entry>> searchFts(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      return (select(entries)
            ..orderBy([
              (e) => OrderingTerm.desc(e.pinned),
              (e) => OrderingTerm.desc(e.createdAt),
            ])
            ..limit(200))
          .get();
    }

    // 1. Versuch: FTS5 (schnell, relevanzbasiert)
    try {
      final safe = q.replaceAll('"', '').replaceAll("'", '').replaceAll('*', '');
      final rows = await customSelect(
        '''
        SELECT e.* FROM entries e
        INNER JOIN entries_fts fts ON fts.rowid = e.rowid
        WHERE entries_fts MATCH ?
        ORDER BY rank
        LIMIT 100
        ''',
        variables: [Variable.withString('$safe*')],
        readsFrom: {entries},
      ).get();
      if (rows.isNotEmpty) {
        return rows.map((r) => Entry.fromJson(r.data)).toList();
      }
    } catch (_) { /* FTS5 nicht verfügbar, Fallback */ }

    // 2. LIKE-Fallback (Fuzzy — sucht in Titel, Body, Tags)
    final like = '%${q.toLowerCase()}%';
    return (select(entries)
          ..where((e) =>
              e.title.lower().like(like) |
              e.body.lower().like(like) |
              e.sourceUrl.lower().like(like))
          ..orderBy([
            (e) => OrderingTerm.desc(e.pinned),
            (e) => OrderingTerm.desc(e.createdAt),
          ])
          ..limit(100))
        .get();
  }
}
