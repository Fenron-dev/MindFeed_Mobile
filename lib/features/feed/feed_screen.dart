import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../core/di.dart';
import '../../data/repositories/entry_repository.dart';
import '../../domain/feed_filter.dart';
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
  // IDs von gerade gewischten Einträgen – sofort aus der Liste entfernen,
  // bevor die DB-Aktualisierung den Stream neu aufbaut.
  final _dismissedIds = <String>{};

  static const _filterStatuses = ['all', 'inbox', 'pinned', 'done', 'archived'];

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

  List<EntryWithDetails> _filterAndSort(
      List<EntryWithDetails> entries, FeedFilter filter) {
    final status = _filterStatuses[_filterIndex];
    var result = entries.where((e) {
      // Status-Filter
      final statusOk = switch (status) {
        'inbox'    => e.entry.status == 'inbox',
        'pinned'   => e.entry.pinned,
        'done'     => e.entry.status == 'done',
        'archived' => e.entry.status == 'archived',
        _          => true,
      };
      if (!statusOk) return false;

      // Entry-Typ-Filter
      if (filter.entryType != null && e.entry.type != filter.entryType) {
        return false;
      }

      // Property-Regeln
      for (final rule in filter.propRules.entries) {
        final match = e.properties.where((p) =>
            p.key.toLowerCase() == rule.key.toLowerCase()).firstOrNull;
        if (match == null) return false; // Key existiert nicht
        if (rule.value != null &&
            rule.value!.isNotEmpty &&
            !(match.value ?? '').toLowerCase().contains(rule.value!.toLowerCase())) {
          return false;
        }
      }
      return true;
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
    final filter   = ref.watch(feedFilterProvider);

    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
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
              // Filter-Button (leuchtet wenn aktiv)
              IconButton(
                icon: Icon(
                  filter.isActive ? Icons.filter_alt : Icons.filter_alt_outlined,
                  color: filter.isActive ? MFColors.teal : MFColors.textSecondary,
                  size: 22,
                ),
                tooltip: 'Filter',
                onPressed: () => _showFilterSheet(context, filter),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert,
                    color: MFColors.textSecondary, size: 22),
                tooltip: 'Ansicht',
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
              preferredSize: Size.fromHeight(filter.isActive ? 88 : 44),
              child: Column(children: [
                _QuickFilterBar(
                  selectedIndex: _filterIndex,
                  onChanged: (i) => setState(() => _filterIndex = i),
                ),
                if (filter.isActive)
                  _ActiveFilterBar(filter: filter),
              ]),
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
              final entries = _filterAndSort(allEntries, filter)
                  .where((e) => !_dismissedIds.contains(e.entry.id))
                  .toList();
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
                  itemBuilder: (ctx, i) {
                    final item = entries[i];
                    return Dismissible(
                      key: ValueKey(item.entry.id),
                      // Rechts wischen → Erledigt
                      background: _SwipeBg(
                        color: const Color(0xFF14B8A6),
                        icon: Icons.check_circle_outline,
                        label: 'Erledigt',
                        alignment: Alignment.centerLeft,
                      ),
                      // Links wischen → Archivieren
                      secondaryBackground: _SwipeBg(
                        color: const Color(0xFF6366F1),
                        icon: Icons.archive_outlined,
                        label: 'Archivieren',
                        alignment: Alignment.centerRight,
                      ),
                      confirmDismiss: (dir) async {
                        // Nicht wischen wenn bereits in diesem Status
                        if (dir == DismissDirection.startToEnd &&
                            item.entry.status == 'done') return false;
                        if (dir == DismissDirection.endToStart &&
                            item.entry.status == 'archived') return false;
                        return true;
                      },
                      onDismissed: (dir) {
                        final newStatus = dir == DismissDirection.startToEnd
                            ? 'done'
                            : 'archived';
                        final label = newStatus == 'done'
                            ? 'Erledigt'
                            : 'Archiviert';
                        final oldStatus = item.entry.status;
                        final entryId = item.entry.id;
                        // Sofort aus der Liste entfernen — synchron, vor dem DB-Aufruf
                        setState(() => _dismissedIds.add(entryId));
                        // DB-Aktualisierung fire-and-forget
                        ref.read(entryRepositoryProvider)
                            .updateEntry(entryId, status: newStatus);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                            content: Text(
                                '${item.entry.title ?? 'Eintrag'} → $label'),
                            action: SnackBarAction(
                              label: 'Rückgängig',
                              onPressed: () {
                                setState(() => _dismissedIds.remove(entryId));
                                ref.read(entryRepositoryProvider)
                                    .updateEntry(entryId, status: oldStatus);
                              },
                            ),
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 4),
                          ));
                        }
                      },
                      child: EntryCard(
                        item: item,
                        compact: _viewMode == 'view_list',
                        onTap: () => context.push(
                            AppRoutes.entryDetailPath(item.entry.id)),
                      ),
                    );
                  },
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

  // ── Filter-Sheet ────────────────────────────────────────────────────────────
  Future<void> _showFilterSheet(BuildContext ctx, FeedFilter current) async {
    await showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FilterSheet(
        current: current,
        propertyDao: ref.read(propertyDaoProvider),
        onApply: (f) => ref.read(feedFilterProvider.notifier).state = f,
      ),
    );
  }
}

// ─── Aktive Filter als Chips ──────────────────────────────────────────────────
class _ActiveFilterBar extends ConsumerWidget {
  final FeedFilter filter;
  const _ActiveFilterBar({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(children: [
        // Typ-Chip
        if (filter.entryType != null)
          _FilterChip(
            label: _typeLabel(filter.entryType!),
            onRemove: () => ref.read(feedFilterProvider.notifier).update(
              (f) => FeedFilter(propRules: f.propRules),
            ),
          ),
        // Property-Chips
        ...filter.propRules.entries.map((r) => _FilterChip(
          label: r.value != null && r.value!.isNotEmpty
              ? '${r.key}: ${r.value}'
              : r.key,
          onRemove: () {
            final rules = Map<String, String?>.from(filter.propRules)
              ..remove(r.key);
            ref.read(feedFilterProvider.notifier).update(
              (f) => FeedFilter(entryType: f.entryType, propRules: rules),
            );
          },
        )),
        // Alle löschen
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () => ref.read(feedFilterProvider.notifier).state = const FeedFilter(),
          child: const Icon(Icons.close, size: 14, color: MFColors.textMuted),
        ),
      ]),
    );
  }

  String _typeLabel(String t) => switch (t) {
    'link'  => '🔗 Link',
    'image' => '🖼️ Bild',
    'audio' => '🎙️ Audio',
    _       => '📝 Text',
  };
}

class _FilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _FilterChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 6),
    padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
    decoration: BoxDecoration(
      color: MFColors.tealBg,
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: MFColors.tealDark),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(
          fontSize: 10, color: MFColors.teal, fontWeight: FontWeight.w600)),
      const SizedBox(width: 4),
      GestureDetector(
        onTap: onRemove,
        child: const Icon(Icons.close, size: 12, color: MFColors.teal),
      ),
    ]),
  );
}

// ─── Filter-Bottom-Sheet ──────────────────────────────────────────────────────
class _FilterSheet extends StatefulWidget {
  final FeedFilter current;
  final dynamic propertyDao;
  final ValueChanged<FeedFilter> onApply;
  const _FilterSheet({
    required this.current,
    required this.propertyDao,
    required this.onApply,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  String? _entryType;
  Map<String, String?> _propRules = {};
  List<String> _availableKeys = [];
  String? _selectedKey;
  final _valueCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _entryType = widget.current.entryType;
    _propRules = Map.from(widget.current.propRules);
    _loadKeys();
  }

  @override
  void dispose() {
    _valueCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadKeys() async {
    final keys = await widget.propertyDao.getUniqueKeys();
    if (mounted) setState(() => _availableKeys = keys);
  }

  void _addRule() {
    final key = _selectedKey;
    if (key == null || key.isEmpty) return;
    setState(() {
      _propRules[key] = _valueCtrl.text.trim().isEmpty ? null : _valueCtrl.text.trim();
      _selectedKey = null;
      _valueCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20,
          24 + MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: MFColors.border,
                borderRadius: BorderRadius.circular(99)),
          )),
          const Text('FILTER', style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold,
              color: MFColors.textMuted, letterSpacing: 1.2)),
          const SizedBox(height: 14),

          // Entry-Typ
          const Text('Eintragstyp', style: TextStyle(
              fontSize: 11, color: MFColors.textMuted)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6,
            children: [
              for (final (type, label) in [
                (null, 'Alle'), ('text', '📝 Text'),
                ('link', '🔗 Link'), ('image', '🖼️ Bild'),
                ('audio', '🎙️ Audio'),
              ])
                GestureDetector(
                  onTap: () => setState(() => _entryType = type),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _entryType == type
                          ? MFColors.tealBg : MFColors.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _entryType == type ? MFColors.teal : MFColors.border,
                      ),
                    ),
                    child: Text(label, style: TextStyle(
                        fontSize: 12,
                        color: _entryType == type
                            ? MFColors.teal : MFColors.textSecondary)),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 16),

          // Aktive Property-Regeln
          if (_propRules.isNotEmpty) ...[
            const Text('Aktive Filter', style: TextStyle(
                fontSize: 11, color: MFColors.textMuted)),
            const SizedBox(height: 6),
            Wrap(spacing: 5, runSpacing: 4,
              children: _propRules.entries.map((r) => _FilterChip(
                label: r.value != null && r.value!.isNotEmpty
                    ? '${r.key}: ${r.value}' : r.key,
                onRemove: () => setState(() => _propRules.remove(r.key)),
              )).toList(),
            ),
            const SizedBox(height: 14),
          ],

          // Neue Property-Regel hinzufügen
          const Text('Property-Filter', style: TextStyle(
              fontSize: 11, color: MFColors.textMuted)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                value: _selectedKey,
                hint: const Text('Key', style: TextStyle(
                    fontSize: 12, color: MFColors.textMuted)),
                dropdownColor: MFColors.surface,
                style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.border)),
                  focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.teal)),
                ),
                items: _availableKeys.map((k) => DropdownMenuItem(
                  value: k,
                  child: Text(k, style: const TextStyle(fontSize: 12)),
                )).toList(),
                onChanged: (v) => setState(() => _selectedKey = v),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _valueCtrl,
                style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'Wert (optional)',
                  hintStyle: TextStyle(fontSize: 11, color: MFColors.textMuted),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.border)),
                  focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.teal)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              onPressed: _addRule,
              icon: const Icon(Icons.add, color: MFColors.teal, size: 20),
              padding: EdgeInsets.zero,
            ),
          ]),

          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  widget.onApply(const FeedFilter());
                  Navigator.pop(context);
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: MFColors.textMuted,
                  side: const BorderSide(color: MFColors.border),
                ),
                child: const Text('Zurücksetzen'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () {
                  widget.onApply(FeedFilter(
                    entryType: _entryType,
                    propRules: _propRules,
                  ));
                  Navigator.pop(context);
                },
                style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
                child: const Text('Anwenden',
                    style: TextStyle(color: MFColors.bg, fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// ─── Swipe-Hintergrund ────────────────────────────────────────────────────────
class _SwipeBg extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final Alignment alignment;
  const _SwipeBg({
    required this.color,
    required this.icon,
    required this.label,
    required this.alignment,
  });

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: alignment,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 3),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );
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

  static const _filters = ['Alle', 'Inbox', 'Angeheftet', 'Erledigt', 'Archiviert'];

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
    final coverLocalPath = coverUrl == null
        ? item.attachments
            .where((a) => a.type == 'image')
            .firstOrNull
            ?.localPath
        : null;

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
                  : coverLocalPath != null
                      ? Image.file(
                          File(coverLocalPath),
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
