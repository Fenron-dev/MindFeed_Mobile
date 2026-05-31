import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../data/repositories/entry_repository.dart';

// StreamProvider statt FutureProvider → aktualisiert sich automatisch
// nach jedem updateEntry / pin-Toggle / Property-Edit
final entryDetailProvider =
    StreamProvider.autoDispose.family<EntryWithDetails?, String>((ref, id) {
  return ref.watch(entryRepositoryProvider).watchById(id);
});
