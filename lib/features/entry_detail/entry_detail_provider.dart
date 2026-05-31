import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../data/repositories/entry_repository.dart';

final entryDetailProvider =
    FutureProvider.autoDispose.family<EntryWithDetails?, String>((ref, id) {
  return ref.watch(entryRepositoryProvider).getById(id);
});
