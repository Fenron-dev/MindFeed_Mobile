import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../data/repositories/entry_repository.dart';
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
  // 'date_desc' | 'date_asc' | 'name_asc' | 'name_desc'
  String _sortBy = 'date_desc';

  String get _sortLabel => switch (_sortBy) {
        'date_asc'  => 'Datum ↑',
        'name_asc'  => 'Name A → Z',
        'name_desc' => 'Name Z → A',
        _           => 'Datum ↓',
      };

  void _toggleSort(String key) => setState(() {
        if (key == 'sort_date') {
          _sortBy = _sortBy == 'date_desc' ? 'date_asc' : 'date_desc';
        } else {
          _sortBy = _sortBy == 'name_asc' ? 'name_desc' : 'name_asc';
        }
      });

  List<EntryWithDetails> _applySort(List<EntryWithDetails> entries) {
    final result = [...entries];
    switch (_sortBy) {
      case 'date_asc':
        result.sort((a, b) => a.entry.createdAt.compareTo(b.entry.createdAt));
      case 'name_asc':
        result.sort((a, b) => (a.entry.title ?? '').toLowerCase()
            .compareTo((b.entry.title ?? '').toLowerCase()));
      case 'name_desc':
        result.sort((a, b) => (b.entry.title ?? '').toLowerCase()
            .compareTo((a.entry.title ?? '').toLowerCase()));
      // date_desc: Provider/Feed bereits sortiert
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final containersAsync = ref.watch(allContainersProvider);
    final container = containersAsync
        .whenData((list) =>
            list.where((c) => c.id == widget.containerId).firstOrNull)
        .valueOrNull;

    // Smart Hubs filtern aus allen Einträgen; Projects/Areas nutzen Membership
    final isHub = container?.kind == 'hub';
    final rawFeedAsync = isHub
        ? ref.watch(feedProvider) // alle Einträge
        : ref.watch(containerFeedProvider(widget.containerId));

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
                Flexible(
                  child: Text(
                    container.name,
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: MFColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ])
            : const SizedBox.shrink(),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_outlined,
                color: MFColors.textSecondary, size: 22),
            tooltip: _sortLabel,
            color: MFColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: MFColors.border),
            ),
            onSelected: _toggleSort,
            itemBuilder: (_) => [
              _sortItem('sort_date',
                  _sortBy == 'date_asc'
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  _sortBy == 'date_asc'
                      ? 'Datum ↑ (älteste zuerst)'
                      : 'Datum ↓ (neueste zuerst)',
                  _sortBy.startsWith('date')),
              _sortItem('sort_name',
                  _sortBy == 'name_desc'
                      ? Icons.text_rotation_angledown_outlined
                      : Icons.sort_by_alpha_outlined,
                  _sortBy == 'name_desc' ? 'Name Z → A' : 'Name A → Z',
                  _sortBy.startsWith('name')),
            ],
          ),
        ],
      ),
      body: rawFeedAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: MFColors.teal)),
        error: (e, _) => Center(
            child: Text('Fehler: $e',
                style: const TextStyle(color: Colors.red))),
        data: (allEntries) {
          // Smart Hub: nach Filterkriterien filtern
          final filtered = isHub && container != null
              ? allEntries.where((e) {
                  bool ok = true;
                  final fs = container.filterStatus;
                  final ft = container.filterTag;
                  final ftype = container.filterType;
                  if (fs != null && fs.isNotEmpty) ok = ok && e.entry.status == fs;
                  if (ft != null && ft.isNotEmpty) ok = ok && e.tags.contains(ft);
                  if (ftype != null && ftype.isNotEmpty) ok = ok && e.entry.type == ftype;
                  return ok;
                }).toList()
              : allEntries;

          final entries = _applySort(filtered);

          if (entries.isEmpty) {
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
                    style:
                        TextStyle(fontSize: 12, color: MFColors.textMuted),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => EntryCard(
              item: entries[i],
              onTap: () => context
                  .push(AppRoutes.entryDetailPath(entries[i].entry.id)),
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
            const Icon(Icons.check_rounded, size: 16, color: MFColors.teal),
        ]),
      );
}

// ─── Container-Icon ───────────────────────────────────────────────────────────

class _ContainerIcon extends StatelessWidget {
  final dynamic container;
  const _ContainerIcon(this.container);

  static IconData _iconFor(String name) => switch (name.toLowerCase()) {
        'folder' || 'project' => Icons.folder_outlined,
        'compass' || 'area'   => Icons.explore_outlined,
        'link'                => Icons.link_rounded,
        'inbox'               => Icons.inbox_outlined,
        'book'                => Icons.menu_book_outlined,
        'layers'              => Icons.layers_outlined,
        _                     => Icons.circle_outlined,
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
