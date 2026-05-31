import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/tags.dart';

part 'tag_dao.g.dart';

@DriftAccessor(tables: [Tags, EntryTags])
class TagDao extends DatabaseAccessor<AppDatabase> with _$TagDaoMixin {
  TagDao(super.db);

  Stream<List<Tag>> watchAll() =>
      (select(tags)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<Tag?> getByName(String name) =>
      (select(tags)..where((t) => t.name.equals(name))).getSingleOrNull();

  Future<Tag> upsertByName(String name) async {
    final existing = await getByName(name);
    if (existing != null) return existing;

    final parentName = name.contains('/') ? name.substring(0, name.lastIndexOf('/')) : null;
    String? parentId;
    if (parentName != null) {
      final parent = await upsertByName(parentName);
      parentId = parent.id;
    }

    final id = 'tag-$name';
    await into(tags).insertOnConflictUpdate(TagsCompanion(
      id: Value(id),
      name: Value(name),
      parentId: Value(parentId),
    ));
    return (await getByName(name))!;
  }

  Future<void> setEntryTags(String entryId, List<String> tagNames) async {
    await (delete(entryTags)..where((et) => et.entryId.equals(entryId))).go();
    for (final name in tagNames) {
      final tag = await upsertByName(name);
      await into(entryTags).insertOnConflictUpdate(EntryTagsCompanion(
        entryId: Value(entryId),
        tagId: Value(tag.id),
      ));
    }
  }

  Future<List<String>> getTagNamesForEntry(String entryId) async {
    final rows = await (select(entryTags)
          ..where((et) => et.entryId.equals(entryId)))
        .get();
    final tagIds = rows.map((r) => r.tagId).toList();
    if (tagIds.isEmpty) return [];
    final tagRows = await (select(tags)
          ..where((t) => t.id.isIn(tagIds)))
        .get();
    return tagRows.map((t) => t.name).toList();
  }
}
