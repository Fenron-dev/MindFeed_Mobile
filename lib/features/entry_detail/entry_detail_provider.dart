import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../data/repositories/entry_repository.dart';

// StreamProvider statt FutureProvider → aktualisiert sich automatisch
// nach jedem updateEntry / pin-Toggle / Property-Edit
final entryDetailProvider =
    StreamProvider.autoDispose.family<EntryWithDetails?, String>((ref, id) {
  return ref.watch(entryRepositoryProvider).watchById(id);
});

// Backlinks: Einträge die auf diesen Eintrag verlinken ([[Wikilink]])
final backlinksProvider =
    FutureProvider.autoDispose.family<List<EntryWithDetails>, String>(
        (ref, entryId) async {
  final links =
      await ref.watch(propertyDaoProvider).getBacklinks(entryId);
  if (links.isEmpty) return [];
  final repo = ref.watch(entryRepositoryProvider);
  final results = await Future.wait(
    links.map((l) => repo.getById(l.fromId)),
  );
  return results.whereType<EntryWithDetails>().toList();
});
