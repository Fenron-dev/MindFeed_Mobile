import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/repositories/entry_repository.dart';
import '../../domain/recurrence_calculator.dart';
import '../../features/entry_detail/entry_detail_provider.dart';
import '../../widgets/app_shell.dart' show navigateToEntry;
import 'task_provider.dart' show subtasksByParentProvider;
import 'widgets/recurrence_picker.dart';

// Prioritäten
const _priorities = ['low', 'medium', 'high', 'urgent'];

Color _priorityColor(String? p) => switch (p) {
      'low' => MFColors.textMuted,
      'medium' => const Color(0xFFF59E0B),
      'high' => const Color(0xFFF97316),
      'urgent' => const Color(0xFFEF4444),
      _ => MFColors.textMuted,
    };

IconData _priorityIcon(String? p) => switch (p) {
      'low' => Icons.arrow_downward_rounded,
      'medium' => Icons.remove_rounded,
      'high' => Icons.arrow_upward_rounded,
      'urgent' => Icons.priority_high_rounded,
      _ => Icons.flag_outlined,
    };

String _priorityLabel(String? p) => switch (p) {
      'low' => 'Niedrig',
      'medium' => 'Mittel',
      'high' => 'Hoch',
      'urgent' => 'Dringend',
      _ => 'Keine',
    };

class TaskDetailScreen extends ConsumerStatefulWidget {
  /// null = neuer Task, non-null = bestehender Task
  final String? taskId;
  final VoidCallback? onBack;

  const TaskDetailScreen({super.key, this.taskId, this.onBack});

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  bool _isEditing = false;
  bool _saving = false;

  // Lokaler State für neue Task-Erstellung / Bearbeitung
  DateTime? _localDueDate;
  String? _localPriority;
  RecurrenceRule? _localRecurrence;

  @override
  void initState() {
    super.initState();
    if (widget.taskId == null) {
      _isEditing = true;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _syncControllersFrom(EntryWithDetails task) {
    if (!_isEditing) {
      _titleCtrl.text = task.entry.title ?? '';
      _bodyCtrl.text = task.entry.body;
    }
  }

  Future<void> _openRecurrencePicker(RecurrenceRule? current) async {
    final result = await showRecurrencePicker(context, current);
    if (!mounted) return;
    setState(() => _localRecurrence = result);
  }

  Future<void> _deleteTask(EntryWithDetails task) async {
    final seriesId =
        EntryRepository.getTaskProperty(task, 'task_series_id');
    final hasRecurrence =
        EntryRepository.getTaskProperty(task, 'task_recurrence') != null ||
            seriesId != null;

    bool andFollowing = false;
    if (hasRecurrence) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: MFColors.surface,
          title: const Text('Aufgabe löschen',
              style: TextStyle(color: MFColors.textPrimary)),
          content: const Text(
            'Diese Aufgabe ist Teil einer Wiederholung. Was soll gelöscht werden?',
            style: TextStyle(color: MFColors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Abbrechen',
                  style: TextStyle(color: MFColors.textMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Nur diese',
                  style: TextStyle(color: MFColors.teal)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Diese und folgende',
                  style: TextStyle(color: Color(0xFFEF4444))),
            ),
          ],
        ),
      );
      if (choice == null) return;
      andFollowing = choice;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: MFColors.surface,
          title: const Text('Aufgabe löschen',
              style: TextStyle(color: MFColors.textPrimary)),
          content: const Text('Aufgabe wirklich in den Papierkorb verschieben?',
              style: TextStyle(color: MFColors.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Abbrechen',
                  style: TextStyle(color: MFColors.textMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Löschen',
                  style: TextStyle(color: Color(0xFFEF4444))),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    await ref.read(entryRepositoryProvider).deleteTask(task.entry.id,
        andFollowing: andFollowing);
    if (mounted) {
      if (widget.onBack != null) {
        widget.onBack!();
      } else if (context.canPop()) {
        context.pop();
      }
    }
  }

  Future<void> _save(EntryWithDetails? existing) async {
    if (_saving) return;
    final repo = ref.read(entryRepositoryProvider);
    final title = _titleCtrl.text.trim();

    setState(() => _saving = true);
    try {
      if (existing == null) {
        // Neuen Task erstellen
        final newTask = await repo.createTask(
          title: title,
          body: _bodyCtrl.text,
          dueAt: _localDueDate,
          priority: _localPriority,
        );
        // Wiederholung speichern
        if (_localRecurrence != null) {
          final seriesId = RecurrenceHelper.generateSeriesId();
          await repo.setTaskProperty(
              newTask.entry.id, 'task_recurrence', _localRecurrence!.toRrule(),
              type: 'text');
          await repo.setTaskProperty(
              newTask.entry.id, 'task_series_id', seriesId,
              type: 'text');
        }
        if (mounted) {
          if (widget.onBack != null) {
            widget.onBack!();
          } else if (context.canPop()) {
            context.pop();
          }
        }
      } else {
        // Bestehenden Task aktualisieren
        await repo.updateEntry(
          existing.entry.id,
          title: title.isEmpty ? null : title,
          body: _bodyCtrl.text,
          reminderAt: _localDueDate,
          clearReminder: _localDueDate == null &&
              existing.entry.reminderAt != null &&
              _dueDateWasCleared,
        );
        if (_localPriority != EntryRepository.getTaskProperty(existing, 'task_priority')) {
          await repo.setTaskProperty(
              existing.entry.id, 'task_priority', _localPriority,
              type: 'select');
        }
        // Wiederholung aktualisieren
        final currentRrule =
            EntryRepository.getTaskProperty(existing, 'task_recurrence');
        final newRrule = _localRecurrence?.toRrule();
        if (newRrule != currentRrule) {
          await repo.setTaskProperty(
              existing.entry.id, 'task_recurrence', newRrule,
              type: 'text');
          if (newRrule != null &&
              EntryRepository.getTaskProperty(existing, 'task_series_id') == null) {
            await repo.setTaskProperty(
                existing.entry.id, 'task_series_id',
                RecurrenceHelper.generateSeriesId(),
                type: 'text');
          }
        }
        setState(() => _isEditing = false);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _dueDateWasCleared = false;

  Future<void> _pickDueDate(DateTime? current) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: MFColors.teal,
            surface: MFColors.surface,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _localDueDate = picked;
        _dueDateWasCleared = false;
      });
    }
  }

  void _clearDueDate() {
    setState(() {
      _localDueDate = null;
      _dueDateWasCleared = true;
    });
  }

  Future<void> _toggleStatus(EntryWithDetails task) async {
    final repo = ref.read(entryRepositoryProvider);
    await repo.toggleTaskStatus(task.entry.id);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.taskId == null) {
      return _buildCreateForm(context);
    }

    final taskAsync = ref.watch(entryDetailProvider(widget.taskId!));
    return taskAsync.when(
      loading: () => Scaffold(
        backgroundColor: MFColors.bg,
        appBar: AppBar(backgroundColor: MFColors.bg),
        body: const Center(child: CircularProgressIndicator(color: MFColors.teal)),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: MFColors.bg,
        appBar: AppBar(backgroundColor: MFColors.bg),
        body: Center(child: Text('$e', style: const TextStyle(color: MFColors.textMuted))),
      ),
      data: (task) {
        if (task == null) {
          return Scaffold(
            backgroundColor: MFColors.bg,
            appBar: AppBar(backgroundColor: MFColors.bg),
            body: const Center(
              child: Text('Aufgabe nicht gefunden.',
                  style: TextStyle(color: MFColors.textMuted)),
            ),
          );
        }
        // Sync-Controller nur außerhalb Edit-Mode
        _syncControllersFrom(task);
        if (!_isEditing) {
          _localDueDate = task.entry.reminderAt;
          _localPriority = EntryRepository.getTaskProperty(task, 'task_priority');
        }
        return _buildDetailView(context, task);
      },
    );
  }

  Widget _buildDetailView(BuildContext context, EntryWithDetails task) {
    final isDone = task.entry.status == 'done';
    final sourceNoteId =
        EntryRepository.getTaskProperty(task, 'task_source_entry_id');
    final completedAt =
        EntryRepository.getTaskProperty(task, 'task_completed_at');

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: MFColors.textSecondary),
          onPressed: () {
            if (widget.onBack != null) {
              widget.onBack!();
            } else if (context.canPop()) {
              context.pop();
            }
          },
        ),
        actions: [
          if (_isEditing) ...[
            TextButton(
              onPressed: () => setState(() => _isEditing = false),
              child: const Text('Abbrechen',
                  style: TextStyle(color: MFColors.textMuted)),
            ),
            TextButton(
              onPressed: _saving ? null : () => _save(task),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: MFColors.teal))
                  : const Text('Speichern',
                      style: TextStyle(
                          color: MFColors.teal, fontWeight: FontWeight.w600)),
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: MFColors.textSecondary, size: 20),
              tooltip: 'Bearbeiten',
              onPressed: () {
                _titleCtrl.text = task.entry.title ?? '';
                _bodyCtrl.text = task.entry.body;
                _localDueDate = task.entry.reminderAt;
                _localPriority =
                    EntryRepository.getTaskProperty(task, 'task_priority');
                _localRecurrence = RecurrenceRule.fromRrule(
                    EntryRepository.getTaskProperty(task, 'task_recurrence'));
                setState(() => _isEditing = true);
              },
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded,
                color: MFColors.textMuted, size: 20),
            tooltip: 'Löschen',
            onPressed: () => _deleteTask(task),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        children: [
          // ─── Checkbox + Titel ───────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => _toggleStatus(task),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: Icon(
                    isDone
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 26,
                    color: isDone ? MFColors.teal : MFColors.textMuted,
                  ),
                ),
              ),
              Expanded(
                child: _isEditing
                    ? TextField(
                        controller: _titleCtrl,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: MFColors.textPrimary,
                          decoration: isDone ? TextDecoration.lineThrough : null,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Aufgabe…',
                          hintStyle: TextStyle(color: MFColors.textMuted),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        maxLines: null,
                        autofocus: true,
                      )
                    : Text(
                        task.entry.title ?? task.entry.body,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isDone ? MFColors.textMuted : MFColors.textPrimary,
                          decoration:
                              isDone ? TextDecoration.lineThrough : null,
                        ),
                      ),
              ),
            ],
          ),

          if (isDone && completedAt != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 38),
              child: Text(
                'Erledigt: ${_formatDateTime(completedAt)}',
                style: const TextStyle(fontSize: 12, color: MFColors.teal),
              ),
            ),
          ],

          const SizedBox(height: 20),
          const Divider(color: MFColors.border),
          const SizedBox(height: 12),

          // ─── Fälligkeit ─────────────────────────────────────────────
          _PropertyRow(
            icon: Icons.calendar_today_rounded,
            label: 'Fällig am',
            child: _isEditing
                ? Row(
                    children: [
                      GestureDetector(
                        onTap: () => _pickDueDate(_localDueDate),
                        child: Text(
                          _localDueDate != null
                              ? _formatDate(_localDueDate!)
                              : 'Kein Datum',
                          style: TextStyle(
                            fontSize: 14,
                            color: _localDueDate != null
                                ? _dueDateColor(_localDueDate!)
                                : MFColors.textMuted,
                          ),
                        ),
                      ),
                      if (_localDueDate != null)
                        GestureDetector(
                          onTap: _clearDueDate,
                          child: const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(Icons.close_rounded,
                                size: 14, color: MFColors.textMuted),
                          ),
                        ),
                    ],
                  )
                : Text(
                    task.entry.reminderAt != null
                        ? _formatDate(task.entry.reminderAt!)
                        : 'Kein Datum',
                    style: TextStyle(
                      fontSize: 14,
                      color: task.entry.reminderAt != null
                          ? _dueDateColor(task.entry.reminderAt!)
                          : MFColors.textMuted,
                    ),
                  ),
          ),

          const SizedBox(height: 8),

          // ─── Priorität ──────────────────────────────────────────────
          _PropertyRow(
            icon: Icons.flag_rounded,
            label: 'Priorität',
            child: _isEditing
                ? Wrap(
                    spacing: 6,
                    children: [null, ..._priorities].map((p) {
                      final selected = _localPriority == p;
                      return GestureDetector(
                        onTap: () => setState(() => _localPriority = p),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: selected
                                ? _priorityColor(p).withAlpha(30)
                                : MFColors.surface,
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(
                              color: selected
                                  ? _priorityColor(p)
                                  : MFColors.border,
                              width: selected ? 1.5 : 1,
                            ),
                          ),
                          child: Text(
                            p == null ? 'Keine' : _priorityLabel(p),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: selected
                                  ? _priorityColor(p)
                                  : MFColors.textSecondary,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  )
                : Row(
                    children: [
                      Icon(
                        _priorityIcon(EntryRepository.getTaskProperty(
                            task, 'task_priority')),
                        size: 14,
                        color: _priorityColor(EntryRepository.getTaskProperty(
                            task, 'task_priority')),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _priorityLabel(EntryRepository.getTaskProperty(
                            task, 'task_priority')),
                        style: TextStyle(
                          fontSize: 14,
                          color: _priorityColor(EntryRepository.getTaskProperty(
                              task, 'task_priority')),
                        ),
                      ),
                    ],
                  ),
          ),

          const SizedBox(height: 8),

          // ─── Wiederholung ────────────────────────────────────────────
          _PropertyRow(
            icon: Icons.repeat_rounded,
            label: 'Wiederholen',
            child: _isEditing
                ? GestureDetector(
                    onTap: () => _openRecurrencePicker(_localRecurrence),
                    child: Text(
                      _localRecurrence?.label ?? 'Nicht wiederholen',
                      style: TextStyle(
                        fontSize: 14,
                        color: _localRecurrence != null
                            ? MFColors.teal
                            : MFColors.textMuted,
                      ),
                    ),
                  )
                : Text(
                    RecurrenceRule.fromRrule(
                                EntryRepository.getTaskProperty(
                                    task, 'task_recurrence'))
                            ?.label ??
                        'Nicht wiederholen',
                    style: TextStyle(
                      fontSize: 14,
                      color: EntryRepository.getTaskProperty(
                                  task, 'task_recurrence') !=
                              null
                          ? MFColors.teal
                          : MFColors.textMuted,
                    ),
                  ),
          ),

          const SizedBox(height: 8),

          // ─── Tags ───────────────────────────────────────────────────
          if (task.tags.isNotEmpty) ...[
            _PropertyRow(
              icon: Icons.tag_rounded,
              label: 'Tags',
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: task.tags
                    .map((t) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: MFColors.tealBg,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '#$t',
                            style: const TextStyle(
                                fontSize: 12, color: MFColors.teal),
                          ),
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // ─── Container/Projekte ─────────────────────────────────────
          if (task.containerIds.isNotEmpty) ...[
            _PropertyRow(
              icon: Icons.folder_outlined,
              label: 'Projekt',
              child: Text(
                task.containerIds.join(', '),
                style: const TextStyle(
                    fontSize: 14, color: MFColors.textSecondary),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // ─── Quell-Notiz ────────────────────────────────────────────
          if (sourceNoteId != null) ...[
            _PropertyRow(
              icon: Icons.article_outlined,
              label: 'Aus Notiz',
              child: GestureDetector(
                onTap: () => navigateToEntry(context, ref, sourceNoteId),
                child: const Text(
                  'Zur Notiz →',
                  style: TextStyle(
                    fontSize: 14,
                    color: MFColors.teal,
                    decoration: TextDecoration.underline,
                    decorationColor: MFColors.teal,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],

          const Divider(color: MFColors.border),
          const SizedBox(height: 12),

          // ─── Beschreibung ───────────────────────────────────────────
          if (_isEditing)
            TextField(
              controller: _bodyCtrl,
              style: const TextStyle(
                  fontSize: 14, color: MFColors.textSecondary, height: 1.6),
              decoration: const InputDecoration(
                hintText: 'Beschreibung (optional)…',
                hintStyle: TextStyle(color: MFColors.textMuted),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              maxLines: null,
              minLines: 3,
            )
          else if (task.entry.body.isNotEmpty)
            Text(
              task.entry.body,
              style: const TextStyle(
                  fontSize: 14, color: MFColors.textSecondary, height: 1.6),
            )
          else
            const Text(
              'Keine Beschreibung',
              style: TextStyle(
                  fontSize: 14,
                  color: MFColors.textMuted,
                  fontStyle: FontStyle.italic),
            ),

          // ─── Subtasks ────────────────────────────────────────────────
          _SubtaskSection(parentId: task.entry.id),
        ],
      ),
    );
  }

  Widget _buildCreateForm(BuildContext context) {
    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        elevation: 0,
        title: const Text('Neue Aufgabe',
            style: TextStyle(
                color: MFColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: MFColors.textSecondary),
          onPressed: () {
            if (widget.onBack != null) {
              widget.onBack!();
            } else if (context.canPop()) {
              context.pop();
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: _saving || _titleCtrl.text.trim().isEmpty
                ? null
                : () => _save(null),
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: MFColors.teal))
                : const Text('Erstellen',
                    style: TextStyle(
                        color: MFColors.teal, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        children: [
          TextField(
            controller: _titleCtrl,
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: MFColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'Aufgabe…',
              hintStyle: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: MFColors.textMuted),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            maxLines: null,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          const Divider(color: MFColors.border),
          const SizedBox(height: 12),

          // Fälligkeit
          _PropertyRow(
            icon: Icons.calendar_today_rounded,
            label: 'Fällig am',
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => _pickDueDate(_localDueDate),
                  child: Text(
                    _localDueDate != null
                        ? _formatDate(_localDueDate!)
                        : 'Kein Datum',
                    style: TextStyle(
                      fontSize: 14,
                      color: _localDueDate != null
                          ? _dueDateColor(_localDueDate!)
                          : MFColors.textMuted,
                    ),
                  ),
                ),
                if (_localDueDate != null)
                  GestureDetector(
                    onTap: _clearDueDate,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.close_rounded,
                          size: 14, color: MFColors.textMuted),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Priorität
          _PropertyRow(
            icon: Icons.flag_rounded,
            label: 'Priorität',
            child: Wrap(
              spacing: 6,
              children: [null, ..._priorities].map((p) {
                final selected = _localPriority == p;
                return GestureDetector(
                  onTap: () => setState(() => _localPriority = p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: selected
                          ? _priorityColor(p).withAlpha(30)
                          : MFColors.surface,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: selected ? _priorityColor(p) : MFColors.border,
                        width: selected ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      p == null ? 'Keine' : _priorityLabel(p),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                        color: selected
                            ? _priorityColor(p)
                            : MFColors.textSecondary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),

          // Wiederholung
          _PropertyRow(
            icon: Icons.repeat_rounded,
            label: 'Wiederholen',
            child: GestureDetector(
              onTap: () => _openRecurrencePicker(_localRecurrence),
              child: Text(
                _localRecurrence?.label ?? 'Nicht wiederholen',
                style: TextStyle(
                  fontSize: 14,
                  color: _localRecurrence != null
                      ? MFColors.teal
                      : MFColors.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Divider(color: MFColors.border),
          const SizedBox(height: 12),

          TextField(
            controller: _bodyCtrl,
            style: const TextStyle(
                fontSize: 14, color: MFColors.textSecondary, height: 1.6),
            decoration: const InputDecoration(
              hintText: 'Beschreibung (optional)…',
              hintStyle: TextStyle(color: MFColors.textMuted),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            maxLines: null,
            minLines: 3,
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
    if (d.isAtSameMomentAs(today.subtract(const Duration(days: 1)))) {
      return 'Gestern';
    }
    return '${dt.day}.${dt.month}.${dt.year}';
  }

  static String _formatDateTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day}.${dt.month}.${dt.year}';
    } catch (_) {
      return iso;
    }
  }

  static Color _dueDateColor(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(dt.year, dt.month, dt.day);
    if (d.isBefore(today)) return const Color(0xFFEF4444);
    if (d.isAtSameMomentAs(today)) return MFColors.teal;
    return MFColors.textSecondary;
  }
}

// ── Subtask-Sektion ────────────────────────────────────────────────────────────

class _SubtaskSection extends ConsumerWidget {
  final String parentId;
  const _SubtaskSection({required this.parentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtasksAsync = ref.watch(subtasksByParentProvider(parentId));

    return subtasksAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (subtasks) {
        final taskSubtasks = subtasks
            .where((s) => s.entry.type == 'task')
            .toList();
        if (taskSubtasks.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            const Divider(color: MFColors.border),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'TEILAUFGABEN',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: MFColors.textMuted,
                    letterSpacing: 1.2),
              ),
            ),
            ...taskSubtasks.map((sub) {
              final isDone = sub.entry.status == 'done';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => ref
                          .read(entryRepositoryProvider)
                          .toggleTaskStatus(sub.entry.id),
                      child: Icon(
                        isDone
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: isDone ? MFColors.teal : MFColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        sub.entry.title ?? sub.entry.body,
                        style: TextStyle(
                          fontSize: 14,
                          color: isDone
                              ? MFColors.textMuted
                              : MFColors.textPrimary,
                          decoration:
                              isDone ? TextDecoration.lineThrough : null,
                          decorationColor: MFColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

// ── Hilfswidget: Property-Zeile ───────────────────────────────────────────────

class _PropertyRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;

  const _PropertyRow({
    required this.icon,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Row(
              children: [
                Icon(icon, size: 14, color: MFColors.textMuted),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                      fontSize: 13, color: MFColors.textMuted),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
