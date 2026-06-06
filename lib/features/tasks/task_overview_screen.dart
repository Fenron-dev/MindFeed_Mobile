import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme.dart';
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
                _GroupHeader(
                  label: 'Überfällig',
                  count: groups.overdue.length,
                  color: const Color(0xFFEF4444),
                ),
                ...groups.overdue.map((t) => TaskListItem(
                      key: ValueKey(t.entry.id),
                      task: t,
                      onTap: () => navigateToTask(context, ref, t.entry.id),
                    )),
              ],
              if (groups.today.isNotEmpty) ...[
                _GroupHeader(
                  label: 'Heute',
                  count: groups.today.length,
                  color: MFColors.teal,
                ),
                ...groups.today.map((t) => TaskListItem(
                      key: ValueKey(t.entry.id),
                      task: t,
                      onTap: () => navigateToTask(context, ref, t.entry.id),
                    )),
              ],
              if (groups.thisWeek.isNotEmpty) ...[
                _GroupHeader(
                  label: 'Diese Woche',
                  count: groups.thisWeek.length,
                  color: MFColors.textSecondary,
                ),
                ...groups.thisWeek.map((t) => TaskListItem(
                      key: ValueKey(t.entry.id),
                      task: t,
                      onTap: () => navigateToTask(context, ref, t.entry.id),
                    )),
              ],
              if (groups.later.isNotEmpty) ...[
                _GroupHeader(
                  label: 'Später',
                  count: groups.later.length,
                  color: MFColors.textMuted,
                ),
                ...groups.later.map((t) => TaskListItem(
                      key: ValueKey(t.entry.id),
                      task: t,
                      onTap: () => navigateToTask(context, ref, t.entry.id),
                    )),
              ],
              if (groups.noDate.isNotEmpty) ...[
                _GroupHeader(
                  label: 'Kein Datum',
                  count: groups.noDate.length,
                  color: MFColors.textMuted,
                ),
                ...groups.noDate.map((t) => TaskListItem(
                      key: ValueKey(t.entry.id),
                      task: t,
                      onTap: () => navigateToTask(context, ref, t.entry.id),
                    )),
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
