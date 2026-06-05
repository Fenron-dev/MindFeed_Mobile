import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/db/app_database.dart' show ChangeLogData;

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logAsync = ref.watch(changeLogProvider);

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        title: const Text('Änderungsverlauf',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold,
                color: MFColors.textPrimary)),
        actions: [
          logAsync.maybeWhen(
            data: (items) => items.isEmpty
                ? const SizedBox.shrink()
                : TextButton(
                    onPressed: () => _confirmClear(context, ref),
                    child: const Text('Leeren',
                        style: TextStyle(color: MFColors.textMuted, fontSize: 13)),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: logAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: MFColors.teal)),
        error: (e, _) => Center(child: Text('Fehler: $e')),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.history, size: 64, color: MFColors.border),
                  SizedBox(height: 16),
                  Text('Noch keine Änderungen',
                      style: TextStyle(fontSize: 16, color: MFColors.textPrimary,
                          fontWeight: FontWeight.w500)),
                  SizedBox(height: 4),
                  Text('Bearbeitungen, Status-Wechsel und Konflikt-\n'
                      'Entscheidungen erscheinen hier — mit Rückgängig.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: MFColors.textMuted)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (ctx, i) => _LogCard(log: items[i]),
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verlauf leeren?'),
        content: const Text(
            'Der gesamte Änderungsverlauf wird gelöscht. Bereits gemachte '
            'Änderungen bleiben erhalten, nur die Rückgängig-Historie verschwindet.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Leeren'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(changeLogDaoProvider).clearAll();
    }
  }
}

class _LogCard extends ConsumerWidget {
  final ChangeLogData log;
  const _LogCard({required this.log});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, color) = switch (log.action) {
      'edit' => (Icons.edit_outlined, const Color(0xFF6366F1)),
      'status' => (Icons.flag_outlined, const Color(0xFFF59E0B)),
      'delete' => (Icons.delete_outline, Colors.redAccent),
      'conflict_server' => (Icons.cloud_download_outlined, const Color(0xFF6366F1)),
      'conflict_mine' => (Icons.smartphone_outlined, MFColors.teal),
      _ => (Icons.history, MFColors.textMuted),
    };
    final canUndo = !log.undone && log.beforeJson != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MFColors.border),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: log.undone ? MFColors.textMuted : color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              log.description,
              style: TextStyle(
                fontSize: 13,
                color: log.undone ? MFColors.textMuted : MFColors.textPrimary,
                decoration: log.undone ? TextDecoration.lineThrough : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              DateFormat('dd.MM.yy HH:mm').format(log.createdAt.toLocal()),
              style: const TextStyle(fontSize: 10, color: MFColors.textMuted,
                  fontFamily: 'monospace'),
            ),
          ]),
        ),
        if (log.undone)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('rückgängig',
                style: TextStyle(fontSize: 10, color: MFColors.textMuted)),
          )
        else if (canUndo)
          TextButton.icon(
            onPressed: () => _undo(context, ref),
            icon: const Icon(Icons.undo, size: 14),
            label: const Text('Rückgängig', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: MFColors.teal,
              visualDensity: VisualDensity.compact,
            ),
          ),
      ]),
    );
  }

  Future<void> _undo(BuildContext context, WidgetRef ref) async {
    await ref.read(entryRepositoryProvider).undoChange(log.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Änderung rückgängig gemacht'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}
