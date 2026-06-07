import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/di.dart';
import '../../../core/theme.dart';
import '../../../data/repositories/entry_repository.dart';

Color _priorityColor(String? p) => switch (p) {
      'low' => MFColors.textMuted,
      'medium' => const Color(0xFFF59E0B),
      'high' => const Color(0xFFF97316),
      'urgent' => const Color(0xFFEF4444),
      _ => Colors.transparent,
    };

class TaskListItem extends ConsumerWidget {
  final EntryWithDetails task;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  const TaskListItem({super.key, required this.task, this.onTap,
      this.onLongPress, this.selectionMode = false, this.selected = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = task.entry;
    final isDone = entry.status == 'done';
    final priority = EntryRepository.getTaskProperty(task, 'task_priority');
    final sourceNoteId =
        EntryRepository.getTaskProperty(task, 'task_source_entry_id');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? MFColors.tealBg : MFColors.surface,
        borderRadius: BorderRadius.circular(10),
        shape: selectionMode && selected
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: MFColors.teal, width: 2))
            : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Prioritätsstreifen
                if (priority != null)
                  Container(
                    width: 3,
                    height: 38,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: _priorityColor(priority),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  )
                else
                  const SizedBox(width: 11),

                // Checkbox
                GestureDetector(
                  onTap: () => ref
                      .read(entryRepositoryProvider)
                      .toggleTaskStatus(entry.id),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1, right: 12),
                    child: Icon(
                      isDone
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: isDone ? MFColors.teal : MFColors.textMuted,
                    ),
                  ),
                ),

                // Inhalt
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title ?? entry.body,
                        style: TextStyle(
                          fontSize: 14,
                          color: isDone
                              ? MFColors.textMuted
                              : MFColors.textPrimary,
                          decoration:
                              isDone ? TextDecoration.lineThrough : null,
                          decorationColor: MFColors.textMuted,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (sourceNoteId != null || task.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Row(
                            children: [
                              if (sourceNoteId != null) ...[
                                const Icon(Icons.article_outlined,
                                    size: 11, color: MFColors.textMuted),
                                const SizedBox(width: 3),
                                const Text(
                                  'Notiz',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: MFColors.textMuted),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (task.tags.isNotEmpty)
                                Expanded(
                                  child: Text(
                                    task.tags.map((t) => '#$t').join(' '),
                                    style: const TextStyle(
                                        fontSize: 11, color: MFColors.teal),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),

                // Datum
                if (entry.reminderAt != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 2),
                    child: Text(
                      _formatDate(entry.reminderAt!),
                      style: TextStyle(
                        fontSize: 11,
                        color: _dueDateColor(entry.reminderAt!),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(dt.year, dt.month, dt.day);
    if (d.isBefore(today)) return '${dt.day}.${dt.month}';
    if (d.isAtSameMomentAs(today)) return 'Heute';
    if (d.isAtSameMomentAs(today.add(const Duration(days: 1)))) return 'Morgen';
    return '${dt.day}.${dt.month}';
  }

  static Color _dueDateColor(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(dt.year, dt.month, dt.day);
    if (d.isBefore(today)) return const Color(0xFFEF4444);
    if (d.isAtSameMomentAs(today)) return MFColors.teal;
    return MFColors.textMuted;
  }
}
