import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../features/feed/feed_provider.dart';
import '../../widgets/entry_card.dart';
import 'container_provider.dart';

class ContainerDetailScreen extends ConsumerStatefulWidget {
  final String containerId;
  const ContainerDetailScreen({super.key, required this.containerId});

  @override
  ConsumerState<ContainerDetailScreen> createState() =>
      _ContainerDetailScreenState();
}

class _ContainerDetailScreenState
    extends ConsumerState<ContainerDetailScreen> {
  String _sortBy = 'date_desc'; // 'date_desc' | 'name_asc'

  @override
  Widget build(BuildContext context) {
    final containersAsync = ref.watch(allContainersProvider);
    final feedAsync =
        ref.watch(containerFeedProvider(widget.containerId));

    final container = containersAsync.whenData(
      (list) => list.where((c) => c.id == widget.containerId).firstOrNull,
    ).valueOrNull;

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: MFColors.textSecondary),
          onPressed: () => context.pop(),
        ),
        title: container != null
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                _ContainerIcon(container),
                const SizedBox(width: 8),
                Text(
                  container.name,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: MFColors.textPrimary),
                ),
              ])
            : const SizedBox.shrink(),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_outlined,
                color: MFColors.textSecondary, size: 22),
            color: MFColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: MFColors.border),
            ),
            onSelected: (v) => setState(() => _sortBy = v),
            itemBuilder: (_) => [
              _sortItem('date_desc', Icons.access_time_outlined,
                  'Datum (neueste zuerst)', _sortBy == 'date_desc'),
              _sortItem('name_asc', Icons.sort_by_alpha_outlined,
                  'Name (A–Z)', _sortBy == 'name_asc'),
            ],
          ),
        ],
      ),
      body: feedAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: MFColors.teal)),
        error: (e, _) => Center(
            child: Text('Fehler: $e',
                style: const TextStyle(color: Colors.red))),
        data: (entries) {
          var sorted = [...entries];
          if (_sortBy == 'name_asc') {
            sorted.sort((a, b) =>
                (a.entry.title ?? '').toLowerCase()
                    .compareTo((b.entry.title ?? '').toLowerCase()));
          }

          if (sorted.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.inbox_outlined,
                      size: 48, color: MFColors.border),
                  const SizedBox(height: 12),
                  Text(
                    container != null
                        ? '${container.name} ist leer'
                        : 'Keine Einträge',
                    style: const TextStyle(
                        fontSize: 15, color: MFColors.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Füge Einträge über den Feed hinzu.',
                    style: TextStyle(
                        fontSize: 12, color: MFColors.textMuted),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => EntryCard(
              item: sorted[i],
              onTap: () => context.push(
                  AppRoutes.entryDetailPath(sorted[i].entry.id)),
            ),
          );
        },
      ),
    );
  }

  PopupMenuItem<String> _sortItem(
          String value, IconData icon, String label, bool active) =>
      PopupMenuItem(
        value: value,
        child: Row(children: [
          Icon(icon,
              size: 18,
              color: active ? MFColors.teal : MFColors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: active ? MFColors.teal : MFColors.textPrimary,
                    fontSize: 13,
                    fontWeight:
                        active ? FontWeight.w600 : FontWeight.normal)),
          ),
          if (active)
            const Icon(Icons.check_rounded,
                size: 16, color: MFColors.teal),
        ]),
      );
}

// ─── Container-Icon ───────────────────────────────────────────────────────────

class _ContainerIcon extends StatelessWidget {
  final dynamic container; // Container from Drift
  const _ContainerIcon(this.container);

  static IconData _iconFor(String name) => switch (name.toLowerCase()) {
        'folder' || 'project' => Icons.folder_outlined,
        'compass' || 'area' => Icons.explore_outlined,
        'link' => Icons.link_rounded,
        'inbox' => Icons.inbox_outlined,
        'book' => Icons.menu_book_outlined,
        'layers' => Icons.layers_outlined,
        _ => Icons.circle_outlined,
      };

  static Color _parseColor(String hex) {
    try {
      return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));
    } catch (_) {
      return MFColors.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) => Icon(
        _iconFor(container.icon as String),
        size: 18,
        color: _parseColor(container.color as String),
      );
}
