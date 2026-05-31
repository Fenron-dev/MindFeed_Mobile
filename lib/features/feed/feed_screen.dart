import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../widgets/app_shell.dart' show appScaffoldKey;
import '../../widgets/entry_card.dart';
import 'feed_provider.dart';

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _scrollController = ScrollController();
  bool _barsVisible = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final direction = _scrollController.position.userScrollDirection;
    if (direction == ScrollDirection.reverse && _barsVisible) {
      setState(() => _barsVisible = false);
    } else if (direction == ScrollDirection.forward && !_barsVisible) {
      setState(() => _barsVisible = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(feedProvider);

    return Scaffold(
      // ─── AppBar (Gmail-Style: verschwindet beim Runterscrollen) ──
      appBar: _barsVisible
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.menu, color: MFColors.textSecondary),
                // GlobalKey öffnet den Drawer des äußeren AppShell-Scaffolds
                onPressed: () => appScaffoldKey.currentState?.openDrawer(),
              ),
              title: const Text(
                'MindFeed',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: MFColors.textPrimary,
                ),
              ),
              actions: [
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert,
                      color: MFColors.textSecondary, size: 22),
                  tooltip: 'Ansicht & Filter',
                  color: MFColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: MFColors.border),
                  ),
                  onSelected: (value) {
                    // TODO: Aktionen implementieren
                  },
                  itemBuilder: (_) => [
                    _menuItem('view_list', Icons.view_list_outlined, 'Listenansicht'),
                    _menuItem('view_cards', Icons.dashboard_outlined, 'Kartenansicht'),
                    _menuItem('view_grid', Icons.grid_view_outlined, 'Thumbnail-Ansicht'),
                    const PopupMenuDivider(),
                    _menuItem('sort_date', Icons.access_time_outlined, 'Sortierung: Datum'),
                    _menuItem('sort_name', Icons.sort_by_alpha_outlined, 'Sortierung: Name'),
                    const PopupMenuDivider(),
                    _menuItem('filter', Icons.tune_outlined, 'Filter & Quickfilter…'),
                  ],
                ),
              ],
            )
          : null,

      body: Column(
        children: [
          if (_barsVisible) const _QuickFilterBar(),
          Expanded(
            child: feedAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(color: MFColors.teal),
              ),
              error: (err, _) => Center(
                child: Text('Fehler: $err',
                    style: const TextStyle(color: Colors.red)),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return _EmptyFeed(
                    onCapture: () => context.push(AppRoutes.capture),
                  );
                }
                return ListView.separated(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => EntryCard(
                    item: entries[i],
                    onTap: () => context.push(
                      AppRoutes.entryDetailPath(entries[i].entry.id),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),

      floatingActionButton: AnimatedScale(
        scale: 1.0,
        duration: const Duration(milliseconds: 200),
        child: FloatingActionButton(
          onPressed: () => context.push(AppRoutes.capture),
          tooltip: 'Neuer Eintrag',
          child: const Icon(Icons.edit_outlined),
        ),
      ),
    );
  }
}

PopupMenuItem<String> _menuItem(String value, IconData icon, String label) =>
    PopupMenuItem(
      value: value,
      child: Row(children: [
        Icon(icon, size: 18, color: MFColors.textSecondary),
        const SizedBox(width: 12),
        Text(label,
            style: const TextStyle(
                color: MFColors.textPrimary, fontSize: 13)),
      ]),
    );

// ─── Schnellfilter-Leiste ────────────────────────────────────────────────────
class _QuickFilterBar extends StatefulWidget {
  const _QuickFilterBar();

  @override
  State<_QuickFilterBar> createState() => _QuickFilterBarState();
}

class _QuickFilterBarState extends State<_QuickFilterBar> {
  int _selected = 0;
  static const _filters = ['Alle', 'Inbox', 'Angeheftet'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: _filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final active = i == _selected;
          return ChoiceChip(
            label: Text(
              _filters[i],
              style: TextStyle(
                fontSize: 12,
                color: active ? MFColors.teal : MFColors.textSecondary,
                fontWeight: active ? FontWeight.bold : FontWeight.w500,
              ),
            ),
            selected: active,
            onSelected: (_) => setState(() => _selected = i),
            backgroundColor: MFColors.surface,
            selectedColor: MFColors.tealBg,
            checkmarkColor: MFColors.teal,
            side: BorderSide(
              color: active ? MFColors.tealDark : MFColors.border,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            visualDensity: VisualDensity.compact,
            showCheckmark: false,
          );
        },
      ),
    );
  }
}

// ─── Leerer Feed ─────────────────────────────────────────────────────────────
class _EmptyFeed extends StatelessWidget {
  final VoidCallback onCapture;
  const _EmptyFeed({required this.onCapture});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.psychology_outlined,
              size: 56, color: MFColors.border),
          const SizedBox(height: 16),
          const Text(
            'Dein Second Brain ist noch leer',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: MFColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tippe auf + um deinen ersten Gedanken festzuhalten.',
            style: TextStyle(fontSize: 13, color: MFColors.textMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onCapture,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Ersten Eintrag erstellen'),
            style: FilledButton.styleFrom(
              backgroundColor: MFColors.teal,
              foregroundColor: MFColors.bg,
            ),
          ),
        ],
      ),
    );
  }
}
