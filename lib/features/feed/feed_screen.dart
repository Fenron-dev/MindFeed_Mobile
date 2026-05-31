import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
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
              leading: Builder(
                builder: (ctx) => IconButton(
                  icon: const Icon(Icons.menu, color: MFColors.textSecondary),
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
              title: _SearchBar(),
              actions: [
                IconButton(
                  icon: const Icon(Icons.grid_view_outlined,
                      color: MFColors.textSecondary, size: 20),
                  tooltip: 'Ansicht wechseln',
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.sort_outlined,
                      color: MFColors.textSecondary, size: 20),
                  tooltip: 'Sortieren',
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.tune_outlined,
                      color: MFColors.textSecondary, size: 20),
                  tooltip: 'Filter',
                  onPressed: () {},
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

// ─── Suchleiste ──────────────────────────────────────────────────────────────
class _SearchBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go(AppRoutes.search),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: MFColors.border),
        ),
        child: const Row(
          children: [
            SizedBox(width: 12),
            Icon(Icons.search, size: 16, color: MFColors.textMuted),
            SizedBox(width: 8),
            Text(
              'Einträge durchsuchen…',
              style: TextStyle(fontSize: 13, color: MFColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Schnellfilter-Leiste ────────────────────────────────────────────────────
class _QuickFilterBar extends StatefulWidget {
  const _QuickFilterBar();

  @override
  State<_QuickFilterBar> createState() => _QuickFilterBarState();
}

class _QuickFilterBarState extends State<_QuickFilterBar> {
  int _selected = 0;

  // TODO: aus Einstellungen laden (welche 3 Filter aktiv)
  static const _filters = ['Alle', 'Inbox', 'Angeheftet'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final active = i == _selected;
          return FilterChip(
            label: Text(_filters[i]),
            selected: active,
            onSelected: (_) => setState(() => _selected = i),
            backgroundColor: MFColors.surface,
            selectedColor: MFColors.tealBg,
            checkmarkColor: MFColors.teal,
            labelStyle: TextStyle(
              fontSize: 11,
              color: active ? MFColors.teal : MFColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
            side: BorderSide(
              color: active ? MFColors.tealDark : MFColors.border,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            visualDensity: VisualDensity.compact,
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
