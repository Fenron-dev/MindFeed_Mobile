import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../data/repositories/entry_repository.dart';
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
  // 'view_list' | 'view_cards' | 'view_grid'
  String _viewMode = 'view_cards';
  // 'date_desc' | 'date_asc' | 'name_asc' | 'name_desc'
  String _sortBy = 'date_desc';
  int _filterIndex = 0; // 0=Alle 1=Inbox 2=Angeheftet

  static const _filterStatuses = ['all', 'inbox', 'pinned'];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onMenuAction(String value) {
    setState(() {
      switch (value) {
        case 'view_list':  _viewMode = 'view_list'; break;
        case 'view_cards': _viewMode = 'view_cards'; break;
        case 'view_grid':  _viewMode = 'view_grid'; break;
        // Toggle beim erneuten Tippen
        case 'sort_date':
          _sortBy = _sortBy == 'date_desc' ? 'date_asc' : 'date_desc'; break;
        case 'sort_name':
          _sortBy = _sortBy == 'name_asc' ? 'name_desc' : 'name_asc'; break;
      }
    });
  }

  List<EntryWithDetails> _filterAndSort(List<EntryWithDetails> entries) {
    final status = _filterStatuses[_filterIndex];
    var result = entries.where((e) => switch (status) {
      'inbox'  => e.entry.status == 'inbox',
      'pinned' => e.entry.pinned,
      _        => true,
    }).toList();

    switch (_sortBy) {
      case 'date_asc':
        result.sort((a, b) =>
            a.entry.createdAt.compareTo(b.entry.createdAt));
      case 'name_asc':
        result.sort((a, b) =>
            (a.entry.title ?? '').toLowerCase()
                .compareTo((b.entry.title ?? '').toLowerCase()));
      case 'name_desc':
        result.sort((a, b) =>
            (b.entry.title ?? '').toLowerCase()
                .compareTo((a.entry.title ?? '').toLowerCase()));
      // date_desc: Provider sortiert bereits desc
    }
    return result;
  }

  String get _sortDateLabel => _sortBy == 'date_asc'
      ? 'Datum ↑ (älteste zuerst)'
      : 'Datum ↓ (neueste zuerst)';
  String get _sortNameLabel =>
      _sortBy == 'name_desc' ? 'Name Z → A' : 'Name A → Z';

  IconData get _sortDateIcon => _sortBy == 'date_asc'
      ? Icons.arrow_upward_rounded
      : Icons.arrow_downward_rounded;
  IconData get _sortNameIcon => _sortBy == 'name_desc'
      ? Icons.text_rotation_angledown_outlined
      : Icons.sort_by_alpha_outlined;

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(feedProvider);

    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // SliverAppBar: floating + snap = Gmail-Style sanfte Animation
          SliverAppBar(
            floating: true,
            snap: true,
            backgroundColor: MFColors.bg,
            surfaceTintColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.menu, color: MFColors.textSecondary),
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
                onSelected: _onMenuAction,
                itemBuilder: (_) => [
                  _menuItem('view_list',  Icons.view_list_outlined,  'Listenansicht',    _viewMode == 'view_list'),
                  _menuItem('view_cards', Icons.dashboard_outlined,  'Kartenansicht',    _viewMode == 'view_cards'),
                  _menuItem('view_grid',  Icons.grid_view_outlined,  'Thumbnail-Ansicht',_viewMode == 'view_grid'),
                  const PopupMenuDivider(),
                  _menuItem('sort_date', _sortDateIcon, _sortDateLabel, _sortBy.startsWith('date')),
                  _menuItem('sort_name', _sortNameIcon, _sortNameLabel, _sortBy.startsWith('name')),
                ],
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(44),
              child: _QuickFilterBar(
                selectedIndex: _filterIndex,
                onChanged: (i) => setState(() => _filterIndex = i),
              ),
            ),
          ),

          // Inhalt
          feedAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(
                  child: CircularProgressIndicator(color: MFColors.teal)),
            ),
            error: (err, _) => SliverFillRemaining(
              child: Center(
                  child: Text('Fehler: $err',
                      style: const TextStyle(color: Colors.red))),
            ),
            data: (allEntries) {
              final entries = _filterAndSort(allEntries);
              if (entries.isEmpty) {
                return SliverFillRemaining(
                  child: _EmptyFeed(
                      onCapture: () => context.push(AppRoutes.capture)),
                );
              }
              if (_viewMode == 'view_grid') {
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 0.8,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) => _GridCard(
                        item: entries[i],
                        onTap: () => context.push(
                            AppRoutes.entryDetailPath(entries[i].entry.id)),
                      ),
                      childCount: entries.length,
                    ),
                  ),
                );
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                sliver: SliverList.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => EntryCard(
                    item: entries[i],
                    compact: _viewMode == 'view_list',
                    onTap: () => context.push(
                        AppRoutes.entryDetailPath(entries[i].entry.id)),
                  ),
                ),
              );
            },
          ),
        ],
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push(AppRoutes.capture),
        tooltip: 'Neuer Eintrag',
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }
}

PopupMenuItem<String> _menuItem(
    String value, IconData icon, String label, [bool active = false]) =>
    PopupMenuItem(
      value: value,
      child: Row(children: [
        Icon(icon, size: 18,
            color: active ? MFColors.teal : MFColors.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: active ? MFColors.teal : MFColors.textPrimary,
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
        ),
        if (active)
          const Icon(Icons.check_rounded, size: 16, color: MFColors.teal),
      ]),
    );

// ─── Schnellfilter-Leiste ────────────────────────────────────────────────────
class _QuickFilterBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const _QuickFilterBar({
    required this.selectedIndex,
    required this.onChanged,
  });

  static const _filters = ['Alle', 'Inbox', 'Angeheftet'];

  @override
  Widget build(BuildContext context) {
    // SingleChildScrollView + Row: Row misst Chips sofort korrekt (kein Clip).
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: _filters.asMap().entries.map((entry) {
          final i = entry.key;
          final label = entry.value;
          final active = i == selectedIndex;
          return Padding(
            padding: EdgeInsets.only(right: i < _filters.length - 1 ? 6 : 0),
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: active ? MFColors.tealBg : MFColors.surface,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: active ? MFColors.tealDark : MFColors.border,
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: active
                        ? MFColors.teal
                        : MFColors.textSecondary,
                    fontWeight:
                        active ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── Grid-Karte (Thumbnail-Ansicht) ──────────────────────────────────────────
class _GridCard extends StatelessWidget {
  final EntryWithDetails item;
  final VoidCallback onTap;
  const _GridCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final entry = item.entry;
    final coverUrl = item.properties
        .where((p) =>
            ['og_image', 'cover_image', 'cover', 'bild'].contains(p.key.toLowerCase()))
        .firstOrNull
        ?.value;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: entry.pinned ? const Color(0xFF831843) : MFColors.border,
            width: entry.pinned ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
              child: coverUrl != null
                  ? Image.network(
                      coverUrl,
                      width: double.infinity,
                      height: 90,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholder(entry.type),
                    )
                  : _placeholder(entry.type),
            ),
            // Text
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (entry.title != null && entry.title!.isNotEmpty)
                      Text(
                        entry.title!,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: MFColors.textPrimary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const Spacer(),
                    Text(
                      DateFormat('dd.MM.yy').format(entry.createdAt.toLocal()),
                      style: const TextStyle(
                          fontSize: 10, color: MFColors.textMuted,
                          fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(String type) {
    final (icon, color) = switch (type) {
      'link'  => (Icons.link_rounded,     const Color(0xFF60A5FA)),
      'image' => (Icons.image_outlined,   const Color(0xFFA78BFA)),
      'audio' => (Icons.mic_outlined,     const Color(0xFFC084FC)),
      _       => (Icons.notes_rounded,    MFColors.textMuted),
    };
    return Container(
      width: double.infinity,
      height: 90,
      color: MFColors.surfaceAlt,
      child: Icon(icon, size: 28, color: color),
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
