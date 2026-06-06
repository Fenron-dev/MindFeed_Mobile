import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../data/repositories/entry_repository.dart';

/// Subtasks eines Tasks (type='task' mit parent_entry_id = parentId).
/// Key = parentTaskId.
final subtasksByParentProvider =
    StreamProvider.autoDispose.family<List<EntryWithDetails>, String>(
        (ref, parentId) {
  return ref.watch(entryRepositoryProvider).watchSubNotes(parentId);
});

/// Tasks die aus einer bestimmten Notiz (inline) erstellt wurden.
/// Key = noteId.
final tasksBySourceNoteProvider =
    StreamProvider.family<List<EntryWithDetails>, String>((ref, noteId) {
  return ref.watch(entryRepositoryProvider).watchTasksBySourceNote(noteId);
});

/// Alle Tasks reaktiv, nach Fälligkeit sortiert (NULLs am Ende).
final tasksProvider = StreamProvider<List<EntryWithDetails>>((ref) {
  ref.keepAlive();
  return ref.watch(entryRepositoryProvider).watchTasks();
});

/// Gruppierte Tasks für die Übersicht: Überfällig / Heute / Woche / Später / Kein Datum.
final groupedTasksProvider = Provider<AsyncValue<TaskGroups>>((ref) {
  return ref.watch(tasksProvider).whenData((tasks) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekEnd = today.add(const Duration(days: 7));

    final overdue = <EntryWithDetails>[];
    final todayTasks = <EntryWithDetails>[];
    final thisWeek = <EntryWithDetails>[];
    final later = <EntryWithDetails>[];
    final noDate = <EntryWithDetails>[];

    for (final t in tasks) {
      // Erledigte/archivierte Tasks nicht in der Hauptliste zeigen
      if (t.entry.status == 'done' || t.entry.status == 'archived') continue;

      final due = t.entry.reminderAt;
      if (due == null) {
        noDate.add(t);
        continue;
      }
      final dueDay = DateTime(due.year, due.month, due.day);
      if (dueDay.isBefore(today)) {
        overdue.add(t);
      } else if (dueDay.isAtSameMomentAs(today)) {
        todayTasks.add(t);
      } else if (dueDay.isBefore(weekEnd)) {
        thisWeek.add(t);
      } else {
        later.add(t);
      }
    }

    return TaskGroups(
      overdue: overdue,
      today: todayTasks,
      thisWeek: thisWeek,
      later: later,
      noDate: noDate,
    );
  });
});

class TaskGroups {
  final List<EntryWithDetails> overdue;
  final List<EntryWithDetails> today;
  final List<EntryWithDetails> thisWeek;
  final List<EntryWithDetails> later;
  final List<EntryWithDetails> noDate;

  const TaskGroups({
    required this.overdue,
    required this.today,
    required this.thisWeek,
    required this.later,
    required this.noDate,
  });

  bool get isEmpty =>
      overdue.isEmpty && today.isEmpty && thisWeek.isEmpty &&
      later.isEmpty && noDate.isEmpty;
}
