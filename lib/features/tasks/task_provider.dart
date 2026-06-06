import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../data/repositories/entry_repository.dart';

/// Repräsentiert einen Task mit seinen direkten Subtasks.
class TaskNode {
  final EntryWithDetails task;
  final List<EntryWithDetails> subtasks;
  const TaskNode({required this.task, this.subtasks = const []});
}

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

/// Gruppierte Tasks für die Übersicht — nur Top-Level-Tasks (keine Subtasks).
/// Subtasks werden als eingerückte Kinder unter dem jeweiligen Parent angezeigt.
final groupedTasksProvider = Provider<AsyncValue<TaskGroups>>((ref) {
  return ref.watch(tasksProvider).whenData((tasks) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekEnd = today.add(const Duration(days: 7));

    // Subtask-Map: parentId → Liste von Subtasks
    final subtaskMap = <String, List<EntryWithDetails>>{};
    final topLevel = <EntryWithDetails>[];

    for (final t in tasks) {
      if (t.entry.status == 'done' || t.entry.status == 'archived') continue;
      final parentId = EntryRepository.getTaskProperty(t, 'parent_entry_id');
      if (parentId != null && parentId.isNotEmpty) {
        subtaskMap.putIfAbsent(parentId, () => []).add(t);
      } else {
        topLevel.add(t);
      }
    }

    // Baut einen TaskNode: Top-Level-Task + seine Subtasks
    TaskNode toNode(EntryWithDetails t) => TaskNode(
      task: t,
      subtasks: subtaskMap[t.entry.id] ?? [],
    );

    final overdue = <TaskNode>[];
    final todayTasks = <TaskNode>[];
    final thisWeek = <TaskNode>[];
    final later = <TaskNode>[];
    final noDate = <TaskNode>[];

    for (final t in topLevel) {
      final node = toNode(t);
      final due = t.entry.reminderAt;
      if (due == null) { noDate.add(node); continue; }
      final dueDay = DateTime(due.year, due.month, due.day);
      if (dueDay.isBefore(today)) {
        overdue.add(node);
      } else if (dueDay.isAtSameMomentAs(today)) {
        todayTasks.add(node);
      } else if (dueDay.isBefore(weekEnd)) {
        thisWeek.add(node);
      } else {
        later.add(node);
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
  final List<TaskNode> overdue;
  final List<TaskNode> today;
  final List<TaskNode> thisWeek;
  final List<TaskNode> later;
  final List<TaskNode> noDate;

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
