import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/repositories/entry_repository.dart';
import '../../widgets/app_shell.dart' show navigateToTask, navigateToNewTask;
import 'task_provider.dart';
import 'widgets/task_list_item.dart';

class TaskOverviewScreen extends ConsumerWidget {
  const TaskOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(groupedTasksProvider);

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        elevation: 0,
        title: const Text(
          'Aufgaben',
          style: TextStyle(
            color: MFColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list_rounded,
                color: MFColors.textSecondary),
            tooltip: 'Filtern',
            onPressed: () {
              // Phase 5: Filter-Sheet
            },
          ),
        ],
      ),
      body: groupsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: MFColors.teal),
        ),
        error: (e, _) => Center(
          child: Text('Fehler: $e',
              style: const TextStyle(color: MFColors.textMuted)),
        ),
        data: (groups) {
          if (groups.isEmpty) {
            return const _EmptyState();
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              if (groups.overdue.isNotEmpty) ...[
                _GroupHeader(label: 'Überfällig', count: groups.overdue.length, color: const Color(0xFFEF4444)),
                ..._buildNodeList(context, ref, groups.overdue),
              ],
              if (groups.today.isNotEmpty) ...[
                _GroupHeader(label: 'Heute', count: groups.today.length, color: MFColors.teal),
                ..._buildNodeList(context, ref, groups.today),
              ],
              if (groups.thisWeek.isNotEmpty) ...[
                _GroupHeader(label: 'Diese Woche', count: groups.thisWeek.length, color: MFColors.textSecondary),
                ..._buildNodeList(context, ref, groups.thisWeek),
              ],
              if (groups.later.isNotEmpty) ...[
                _GroupHeader(label: 'Später', count: groups.later.length, color: MFColors.textMuted),
                ..._buildNodeList(context, ref, groups.later),
              ],
              if (groups.noDate.isNotEmpty) ...[
                _GroupHeader(label: 'Kein Datum', count: groups.noDate.length, color: MFColors.textMuted),
                ..._buildNodeList(context, ref, groups.noDate),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => navigateToNewTask(context, ref),
        backgroundColor: MFColors.teal,
        foregroundColor: MFColors.bg,
        child: const Icon(Icons.add_task_rounded),
      ),
    );
  }
}

// ── Hilfsfunktionen ───────────────────────────────────────────────────────────

List<Widget> _buildNodeList(
    BuildContext context, WidgetRef ref, List<TaskNode> nodes) {
  final widgets = <Widget>[];
  for (final node in nodes) {
    widgets.add(TaskListItem(
      key: ValueKey(node.task.entry.id),
      task: node.task,
      onTap: () => navigateToTask(context, ref, node.task.entry.id),
    ));
    // Subtasks eingerückt darunter
    for (final sub in node.subtasks) {
      widgets.add(_SubtaskRow(
        key: ValueKey(sub.entry.id),
        task: sub,
        onTap: () => navigateToTask(context, ref, sub.entry.id),
        onToggle: () => ref.read(entryRepositoryProvider).toggleTaskStatus(sub.entry.id),
      ));
    }
  }
  return widgets;
}

class _SubtaskRow extends StatelessWidget {
  final EntryWithDetails task;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  const _SubtaskRow({super.key, required this.task, required this.onTap, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final isDone = task.entry.status == 'done';
    return Padding(
      padding: const EdgeInsets.only(left: 28, right: 12, bottom: 2),
      child: Material(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(children: [
              // Einrück-Indikator
              Container(
                width: 2, height: 16,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: MFColors.border,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              GestureDetector(
                onTap: onToggle,
                child: Icon(
                  isDone ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: isDone ? MFColors.teal : MFColors.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  task.entry.title ?? task.entry.body,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDone ? MFColors.textMuted : MFColors.textSecondary,
                    decoration: isDone ? TextDecoration.lineThrough : null,
                    decorationColor: MFColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _GroupHeader({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.task_alt_rounded, size: 56, color: MFColors.textMuted.withAlpha(80)),
          const SizedBox(height: 16),
          const Text(
            'Keine offenen Aufgaben',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: MFColors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tippe auf + um eine neue Aufgabe anzulegen.',
            style: TextStyle(fontSize: 13, color: MFColors.textMuted),
          ),
        ],
      ),
    );
  }
}
