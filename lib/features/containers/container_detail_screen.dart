import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/repositories/entry_repository.dart';
import '../../data/repositories/container_repository.dart';
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
  String _sortBy = 'date_desc';
  bool _subFoldersCollapsed = false;

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
          // Bearbeiten-Button
          if (container != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: MFColors.textSecondary, size: 20),
              tooltip: 'Bearbeiten',
              onPressed: () =>
                  context.push(AppRoutes.containerEditPath(container.id)),
            ),
          // Löschen-Button
          if (container != null)
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: MFColors.textSecondary, size: 20),
              tooltip: 'Löschen',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: MFColors.surface,
                    title: const Text('Container löschen?',
                        style: TextStyle(color: MFColors.textPrimary)),
                    content: Text(
                        '"${container.name}" wird gelöscht. '
                        'Die enthaltenen Einträge bleiben erhalten.',
                        style: const TextStyle(
                            color: MFColors.textSecondary, fontSize: 13)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Abbrechen',
                              style: TextStyle(color: MFColors.textMuted))),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Löschen',
                              style: TextStyle(color: Colors.redAccent))),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  await ref
                      .read(containerRepositoryProvider)
                      .delete(container.id);
                  context.pop();
                }
              },
            ),
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
      floatingActionButton: FloatingActionButton(
        tooltip: 'Notiz hinzufügen',
        onPressed: () => context.push(
            '${AppRoutes.capture}?containerId=${widget.containerId}'),
        child: const Icon(Icons.edit_outlined),
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

          // Container-Beschreibung als Notiz-Header (wenn gesetzt)
          final hasDesc = container?.description?.isNotEmpty == true;

          if (entries.isEmpty && !hasDesc) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.edit_note_outlined,
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
                    'Tippe auf ✏️ um eine Notiz hinzuzufügen.',
                    style: TextStyle(fontSize: 12, color: MFColors.textMuted),
                  ),
                ],
              ),
            );
          }

          return CustomScrollView(
            slivers: [
              // ── Beschreibung / Kontext-Notiz ──────────────────────────
              if (hasDesc)
                SliverToBoxAdapter(
                  child: _ContainerNoteCard(
                    description: container!.description!,
                    onEdit: () =>
                        context.push(AppRoutes.containerEditPath(container.id)),
                  ),
                ),

              // ── Unterordner ────────────────────────────────────────
              SliverToBoxAdapter(
                child: _SubFoldersSection(
                  containerId: widget.containerId,
                  container: container,
                  collapsed: _subFoldersCollapsed,
                  onToggle: () =>
                      setState(() => _subFoldersCollapsed = !_subFoldersCollapsed),
                ),
              ),

              // ── Einträge ──────────────────────────────────────────────
              if (entries.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(12, hasDesc ? 4 : 8, 12, 88),
                  sliver: SliverList.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) => EntryCard(
                      item: entries[i],
                      onTap: () => context.push(
                          AppRoutes.entryDetailPath(entries[i].entry.id)),
                    ),
                  ),
                ),
            ],
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

// ─── Unterordner-Sektion ─────────────────────────────────────────────────────

class _SubFoldersSection extends ConsumerWidget {
  final String containerId;
  final dynamic container;
  final bool collapsed;
  final VoidCallback onToggle;

  const _SubFoldersSection({
    required this.containerId,
    required this.container,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allAsync = ref.watch(allContainersProvider);
    return allAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (all) {
        final children = all.where((c) => c.parentId == containerId).toList();
        if (children.isEmpty && container == null) {
          return const SizedBox.shrink();
        }

        final kind = (container?.kind as String?) ?? 'project';
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header-Zeile
              Row(children: [
                if (children.isNotEmpty)
                  GestureDetector(
                    onTap: onToggle,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('UNTERORDNER',
                          style: TextStyle(
                              fontSize: 9, fontWeight: FontWeight.bold,
                              color: MFColors.textMuted, letterSpacing: 1.2)),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                            color: MFColors.border,
                            borderRadius: BorderRadius.circular(99)),
                        child: Text('${children.length}',
                            style: const TextStyle(
                                fontSize: 9, color: MFColors.textMuted)),
                      ),
                      const SizedBox(width: 4),
                      Icon(collapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded,
                          size: 14, color: MFColors.textMuted),
                    ]),
                  )
                else
                  const SizedBox.shrink(),
                const Spacer(),
                // Unterordner erstellen
                GestureDetector(
                  onTap: () => context.push(
                      '${AppRoutes.containerNew}?kind=$kind&parentId=$containerId'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: MFColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: MFColors.border),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.create_new_folder_outlined,
                          size: 13, color: MFColors.teal),
                      SizedBox(width: 5),
                      Text('Unterordner',
                          style: TextStyle(fontSize: 11, color: MFColors.teal,
                              fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
              ]),

              // Unterordner-Liste
              if (!collapsed && children.isNotEmpty) ...[
                const SizedBox(height: 6),
                ...children.map((child) {
                  Color color;
                  try {
                    color = Color(int.parse(
                        'FF${child.color.replaceFirst('#', '')}', radix: 16));
                  } catch (_) {
                    color = MFColors.teal;
                  }
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    leading: Icon(_iconFor(child.icon), size: 16, color: color),
                    title: Text(child.name,
                        style: const TextStyle(
                            fontSize: 13, color: MFColors.textPrimary)),
                    trailing: const Icon(Icons.chevron_right,
                        size: 16, color: MFColors.textMuted),
                    onTap: () =>
                        context.push(AppRoutes.containerDetailPath(child.id)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  );
                }),
              ],
              const SizedBox(height: 4),
            ],
          ),
        );
      },
    );
  }

  static IconData _iconFor(String name) => switch (name.toLowerCase()) {
    'folder' || 'project' => Icons.folder_outlined,
    'compass' || 'area' => Icons.explore_outlined,
    'link' => Icons.link_rounded,
    'inbox' => Icons.inbox_outlined,
    'book' => Icons.menu_book_outlined,
    'layers' => Icons.layers_outlined,
    _ => Icons.folder_outlined,
  };
}

// ─── Beschreibungs-Karte ─────────────────────────────────────────────────────

class _ContainerNoteCard extends StatelessWidget {
  final String description;
  final VoidCallback onEdit;
  const _ContainerNoteCard({required this.description, required this.onEdit});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: GestureDetector(
          onTap: onEdit,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: MFColors.tealBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF0F766E), width: 0.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.notes_rounded, size: 13, color: MFColors.teal),
                  const SizedBox(width: 6),
                  const Text('NOTIZEN',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: MFColors.teal,
                          letterSpacing: 1.2)),
                  const Spacer(),
                  const Icon(Icons.edit_outlined, size: 13, color: MFColors.teal),
                ]),
                const SizedBox(height: 8),
                Text(description,
                    style: const TextStyle(
                        fontSize: 13,
                        color: MFColors.textPrimary,
                        height: 1.5)),
              ],
            ),
          ),
        ),
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
