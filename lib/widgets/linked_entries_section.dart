import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/di.dart';
import '../core/theme.dart';
import '../features/entry_detail/entry_detail_provider.dart';
import 'app_shell.dart' show navigateToEntry, navigateToTask;
import 'entry_picker.dart';

/// Zeigt die manuellen/Wikilink-Verknüpfungen eines Eintrags ("Verknüpft mit")
/// mit Hinzufügen (Picker) und Entfernen. Wiederverwendbar in Note- und
/// Task-Detail.
class LinkedEntriesSection extends ConsumerWidget {
  final String entryId;
  const LinkedEntriesSection({super.key, required this.entryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linksAsync = ref.watch(outgoingLinksProvider(entryId));
    final links = linksAsync.asData?.value ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(children: [
          const Icon(Icons.link_rounded, size: 13, color: MFColors.textMuted),
          const SizedBox(width: 6),
          const Text('VERKNÜPFT MIT',
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.bold,
                  color: MFColors.textMuted, letterSpacing: 1.2)),
          if (links.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: MFColors.tealBg, borderRadius: BorderRadius.circular(99)),
              child: Text('${links.length}',
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold, color: MFColors.teal)),
            ),
          ],
          const Spacer(),
          GestureDetector(
            onTap: () async {
              final picked =
                  await showEntryPicker(context, ref, excludeId: entryId);
              if (picked != null) {
                await ref.read(entryRepositoryProvider)
                    .addLink(entryId, picked.entry.id);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: MFColors.tealBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF0F766E)),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add_link_rounded, size: 13, color: MFColors.teal),
                SizedBox(width: 4),
                Text('Verknüpfen',
                    style: TextStyle(fontSize: 11, color: MFColors.teal,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ]),
        if (links.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...links.map((e) {
            final isTask = e.entry.type == 'task';
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                decoration: BoxDecoration(
                  color: MFColors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: MFColors.border),
                ),
                child: Row(children: [
                  Icon(isTask ? Icons.task_alt_rounded : Icons.notes_rounded,
                      size: 13, color: isTask ? MFColors.teal : MFColors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => isTask
                          ? navigateToTask(context, ref, e.entry.id)
                          : navigateToEntry(context, ref, e.entry.id),
                      child: Text(
                        e.entry.title ?? e.entry.body,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFFA78BFA),
                            decoration: TextDecoration.underline,
                            decorationColor: Color(0xFF7C6BB0)),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => ref.read(entryRepositoryProvider)
                        .removeLink(entryId, e.entry.id),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 13, color: MFColors.textMuted),
                    ),
                  ),
                ]),
              ),
            );
          }),
        ],
      ],
    );
  }
}
