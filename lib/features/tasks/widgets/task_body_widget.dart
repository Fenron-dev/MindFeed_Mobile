import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/di.dart';
import '../../../core/theme.dart';
import '../../../data/repositories/entry_repository.dart';
import '../../../domain/task_parser.dart';
import '../../../widgets/app_shell.dart' show navigateToTask;
import '../../../widgets/markdown_note.dart';
import '../task_provider.dart';

/// Rendert den Body einer Notiz mit live-interaktiven Task-Checkboxen.
///
/// Task-Zeilen mit Block-Ref (^abc123) werden als Checkboxen gerendert,
/// deren Status direkt aus dem verlinkten Task-Entry kommt.
/// Normaler Text wird per WikilinkText gerendert.
class TaskBodyWidget extends ConsumerWidget {
  final String body;
  final String noteId;
  final void Function(String title)? onWikilink;

  const TaskBodyWidget({
    super.key,
    required this.body,
    required this.noteId,
    this.onWikilink,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(tasksBySourceNoteProvider(noteId));

    return tasksAsync.when(
      loading: () => _buildBody(context, ref, {}),
      error: (_, __) => _buildBody(context, ref, {}),
      data: (tasks) {
        // Map: blockRef (shortId ohne 'e-') → EntryWithDetails
        final taskMap = <String, EntryWithDetails>{};
        for (final t in tasks) {
          final shortId = t.entry.id.replaceFirst('e-', '');
          taskMap[shortId] = t;
        }
        return _buildBody(context, ref, taskMap);
      },
    );
  }

  Widget _buildBody(
      BuildContext context, WidgetRef ref, Map<String, EntryWithDetails> taskMap) {
    final taskLines = TaskParser.parse(body);
    if (taskLines.isEmpty) {
      return _buildPlainText(context, ref, body);
    }

    final widgets = <Widget>[];
    int cursor = 0;

    for (final line in taskLines) {
      // Text vor der Task-Zeile
      if (line.startOffset > cursor) {
        final textBefore = body.substring(cursor, line.startOffset).trimRight();
        if (textBefore.isNotEmpty) {
          widgets.add(_buildPlainText(context, ref, textBefore));
          widgets.add(const SizedBox(height: 4));
        }
      }

      // Task-Zeile rendern
      widgets.add(_InlineTaskLine(
        line: line,
        task: line.blockRef != null ? taskMap[line.blockRef] : null,
        noteId: noteId,
        noteBody: body,
        onNavigate: (taskId) => navigateToTask(context, ref, taskId),
      ));

      cursor = line.endOffset;
    }

    // Restlicher Text nach der letzten Task-Zeile
    if (cursor < body.length) {
      final remaining = body.substring(cursor).trim();
      if (remaining.isNotEmpty) {
        widgets.add(const SizedBox(height: 4));
        widgets.add(_buildPlainText(context, ref, remaining));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildPlainText(
      BuildContext context, WidgetRef ref, String text) {
    // Block-Refs am Zeilenende ausblenden (z.B. ^abc123 die durch Parsing
    // nicht als Task-Zeile erkannt wurden)
    final cleaned = text.replaceAll(RegExp(r'\s*\^[a-zA-Z0-9_-]+\s*$', multiLine: true), '');
    return MarkdownNote(
      data: cleaned,
      onTag: (_) {},
      onWikilink: (title) async {
        onWikilink?.call(title);
      },
    );
  }
}

// ── Einzelne Inline-Task-Zeile ─────────────────────────────────────────────────

class _InlineTaskLine extends ConsumerStatefulWidget {
  final ParsedTaskLine line;
  final EntryWithDetails? task;
  final String noteId;
  final String noteBody;
  final void Function(String taskId)? onNavigate;

  const _InlineTaskLine({
    required this.line,
    required this.task,
    required this.noteId,
    required this.noteBody,
    this.onNavigate,
  });

  @override
  ConsumerState<_InlineTaskLine> createState() => _InlineTaskLineState();
}

class _InlineTaskLineState extends ConsumerState<_InlineTaskLine> {
  bool _toggling = false;

  Future<void> _toggle() async {
    final task = widget.task;
    if (task == null || _toggling) return;
    setState(() => _toggling = true);
    try {
      final repo = ref.read(entryRepositoryProvider);
      await repo.toggleTaskStatus(task.entry.id);
      // Synchronisiere auch den Body der Quell-Notiz
      final isDoneNow = task.entry.status != 'done';
      final updatedBody =
          TaskParser.setTaskDone(widget.noteBody, widget.line, isDoneNow);
      if (updatedBody != widget.noteBody) {
        await repo.updateEntry(widget.noteId, body: updatedBody);
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final isDone = task?.entry.status == 'done' || widget.line.isDone;
    final title = widget.line.title;
    final hasLink = task != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Checkbox
          GestureDetector(
            onTap: hasLink ? _toggle : null,
            child: Padding(
              padding: const EdgeInsets.only(top: 1, right: 10),
              child: _toggling
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: MFColors.teal),
                    )
                  : Icon(
                      isDone
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: isDone
                          ? MFColors.teal
                          : hasLink
                              ? MFColors.textMuted
                              : MFColors.border,
                    ),
            ),
          ),

          // Titel
          Expanded(
            child: GestureDetector(
              onTap: hasLink
                  ? () => widget.onNavigate?.call(task.entry.id)
                  : null,
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  color: isDone ? MFColors.textMuted : MFColors.textPrimary,
                  decoration: isDone ? TextDecoration.lineThrough : null,
                  decorationColor: MFColors.textMuted,
                  height: 1.5,
                ),
              ),
            ),
          ),

          // Fälligkeitsdatum (wenn vorhanden)
          if (widget.line.dueDate != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                _formatDate(widget.line.dueDate!),
                style: TextStyle(
                  fontSize: 11,
                  color: _dueDateColor(widget.line.dueDate!),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(dt.year, dt.month, dt.day);
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
