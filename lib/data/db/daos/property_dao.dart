import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/properties.dart';

part 'property_dao.g.dart';

@DriftAccessor(tables: [EntryProperties, EntryLinks])
class PropertyDao extends DatabaseAccessor<AppDatabase> with _$PropertyDaoMixin {
  PropertyDao(super.db);

  Stream<List<EntryProperty>> watchByEntry(String entryId) =>
      (select(entryProperties)
            ..where((p) => p.entryId.equals(entryId)))
          .watch();

  Future<void> setProperties(String entryId, List<EntryPropertiesCompanion> props) async {
    await (delete(entryProperties)..where((p) => p.entryId.equals(entryId))).go();
    for (final p in props) {
      await into(entryProperties).insertOnConflictUpdate(p);
    }
    // Eltern-Eintrag als geändert markieren, damit die Property-Änderung beim
    // nächsten Sync als "dirty" erkannt und übertragen wird (Shadow-Modell).
    final mainDb = attachedDatabase;
    await (mainDb.update(mainDb.entries)..where((e) => e.id.equals(entryId)))
        .write(EntriesCompanion(updatedAt: Value(DateTime.now().toUtc())));
  }

  Future<void> upsertLink(String fromId, String toId, {bool manual = false}) =>
      into(entryLinks).insertOnConflictUpdate(
        EntryLinksCompanion(
            fromId: Value(fromId), toId: Value(toId), manual: Value(manual)),
      );

  Future<List<EntryLink>> getBacklinks(String entryId) =>
      (select(entryLinks)..where((l) => l.toId.equals(entryId))).get();

  /// Ausgehende Verknüpfungen (Wikilink + manuell).
  Future<List<EntryLink>> getOutgoingLinks(String fromId) =>
      (select(entryLinks)..where((l) => l.fromId.equals(fromId))).get();

  /// Ersetzt nur die aus [[Wikilinks]] abgeleiteten (manual=false) Links.
  /// Manuelle Verknüpfungen bleiben erhalten.
  Future<void> setOutgoingLinks(String fromId, List<String> toIds) async {
    await (delete(entryLinks)
          ..where((l) => l.fromId.equals(fromId) & l.manual.equals(false)))
        .go();
    for (final toId in toIds) {
      await upsertLink(fromId, toId);
    }
  }

  /// Fügt eine manuelle, bidirektional auffindbare Verknüpfung hinzu.
  Future<void> addManualLink(String fromId, String toId) =>
      upsertLink(fromId, toId, manual: true);

  /// Entfernt eine Verknüpfung (egal ob manuell oder Wikilink).
  Future<void> removeLink(String fromId, String toId) =>
      (delete(entryLinks)
            ..where((l) => l.fromId.equals(fromId) & l.toId.equals(toId)))
          .go();

  /// Alle eindeutigen Property-Keys (für Filter-UI)
  Future<List<String>> getUniqueKeys() async {
    final rows = await customSelect(
      'SELECT DISTINCT key FROM entry_properties '
      'WHERE key NOT IN (\'og_image\',\'og_title\',\'og_description\',\'domain\') '
      'ORDER BY key',
      readsFrom: {entryProperties},
    ).get();
    return rows.map((r) => r.read<String>('key')).toList();
  }
}
