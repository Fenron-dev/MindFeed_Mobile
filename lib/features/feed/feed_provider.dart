import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../data/repositories/entry_repository.dart';

// ─── Feed: alle Einträge reaktiv ──────────────────────────────────────────────
final feedProvider = StreamProvider<List<EntryWithDetails>>((ref) {
  // keepAlive verhindert Entsorgung beim Navigieren zum Capture-Screen
  ref.keepAlive();
  return ref.watch(entryRepositoryProvider).watchAll();
});

// ─── Feed für einen bestimmten Container ──────────────────────────────────────
final containerFeedProvider =
    StreamProvider.family<List<EntryWithDetails>, String>((ref, containerId) {
  return ref.watch(entryRepositoryProvider).watchByContainer(containerId);
});
