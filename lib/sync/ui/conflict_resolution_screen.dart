import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../dto/sync_dto.dart';
import '../sync_provider.dart';

class ConflictResolutionScreen extends ConsumerWidget {
  final List<SyncConflict> conflicts;
  const ConflictResolutionScreen({super.key, required this.conflicts});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync-Konflikte'),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(syncStateProvider.notifier).clearConflicts();
              Navigator.pop(context);
            },
            child: const Text('Schließen'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${conflicts.length} Konflikt${conflicts.length != 1 ? 'e' : ''}: '
                    'Sowohl lokal als auch auf dem Server wurden Änderungen vorgenommen.',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: conflicts.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final conflict = conflicts[i];
                return _ConflictTile(conflict: conflict);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ConflictTile extends StatelessWidget {
  final SyncConflict conflict;
  const _ConflictTile({required this.conflict});

  @override
  Widget build(BuildContext context) {
    final serverTs = DateTime.tryParse(conflict.serverModifiedAt);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        conflict.entityType == 'entry' ? Icons.article_outlined : Icons.folder_outlined,
        color: Colors.orange,
      ),
      title: Text(
        '${conflict.entityType == 'entry' ? 'Eintrag' : 'Container'}: ${conflict.entityId}',
        style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: serverTs != null
          ? Text(
              'Server-Version: ${_formatDate(serverTs)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            )
          : null,
      trailing: Text(
        'Server gewann',
        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
