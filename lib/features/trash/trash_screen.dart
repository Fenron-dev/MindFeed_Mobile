import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/repositories/entry_repository.dart';
import '../../services/app_settings.dart';

class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trashedAsync = ref.watch(trashedEntriesProvider);
    final retentionDays = AppSettings.getTrashRetentionDays();

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        title: const Text('Papierkorb',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold,
                color: MFColors.textPrimary)),
        actions: [
          trashedAsync.maybeWhen(
            data: (items) => items.isEmpty
                ? const SizedBox.shrink()
                : TextButton.icon(
                    onPressed: () => _confirmEmptyTrash(context, ref),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16,
                        color: Colors.red),
                    label: const Text('Leeren',
                        style: TextStyle(color: Colors.red, fontSize: 13)),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Hinweis zur automatischen Löschung
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: MFColors.border),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline, size: 14, color: MFColors.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  retentionDays == 0
                      ? 'Einträge im Papierkorb werden nie automatisch gelöscht.'
                      : 'Einträge werden nach $retentionDays Tagen automatisch gelöscht.',
                  style: const TextStyle(fontSize: 12, color: MFColors.textMuted),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),

          // Liste
          Expanded(
            child: trashedAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(color: MFColors.teal)),
              error: (e, _) => Center(
                  child: Text('Fehler: $e',
                      style: const TextStyle(color: Colors.red))),
              data: (items) {
                if (items.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.delete_outline, size: 64,
                            color: MFColors.border),
                        const SizedBox(height: 16),
                        const Text('Papierkorb ist leer',
                            style: TextStyle(fontSize: 16,
                                color: MFColors.textPrimary,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(height: 4),
                        const Text('Gelöschte Einträge erscheinen hier',
                            style: TextStyle(fontSize: 12,
                                color: MFColors.textMuted)),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (ctx, i) => _TrashCard(entry: items[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmEmptyTrash(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Papierkorb leeren?'),
        content: const Text(
            'Alle Einträge werden endgültig gelöscht und können nicht wiederhergestellt werden.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Alles löschen'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(entryRepositoryProvider).emptyTrash();
    }
  }
}

class _TrashCard extends ConsumerWidget {
  final dynamic entry; // Entry from Drift

  const _TrashCard({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deletedAt = entry.deletedAt as DateTime?;
    final fmt = DateFormat('dd.MM.yy HH:mm');
    final daysInTrash = deletedAt != null
        ? DateTime.now().difference(deletedAt.toLocal()).inDays
        : 0;

    return Container(
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MFColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.title != null && (entry.title as String).isNotEmpty)
                  Text(entry.title as String,
                      style: const TextStyle(fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: MFColors.textPrimary)),
                if ((entry.body as String).isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    (entry.body as String).length > 120
                        ? '${(entry.body as String).substring(0, 120)}…'
                        : entry.body as String,
                    style: const TextStyle(fontSize: 12,
                        color: MFColors.textSecondary, height: 1.4),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.delete_outline, size: 12,
                      color: MFColors.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    deletedAt != null
                        ? 'Gelöscht: ${fmt.format(deletedAt.toLocal())} '
                          '(vor $daysInTrash ${daysInTrash == 1 ? 'Tag' : 'Tagen'})'
                        : 'Gelöscht',
                    style: const TextStyle(fontSize: 11,
                        color: MFColors.textMuted),
                  ),
                ]),
              ],
            ),
          ),
          const Divider(height: 1, color: MFColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _restore(context, ref),
                  icon: const Icon(Icons.restore, size: 14),
                  label: const Text('Wiederherstellen',
                      style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MFColors.teal,
                    side: const BorderSide(color: MFColors.teal),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _permanentlyDelete(context, ref),
                  icon: const Icon(Icons.delete_forever_outlined, size: 14),
                  label: const Text('Endgültig löschen',
                      style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    await ref.read(entryRepositoryProvider).restoreEntry(entry.id as String);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Eintrag wiederhergestellt'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _permanentlyDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Endgültig löschen?'),
        content: const Text('Dieser Eintrag wird unwiderruflich gelöscht.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(entryRepositoryProvider)
          .permanentlyDeleteEntry(entry.id as String);
    }
  }
}
