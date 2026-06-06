import 'dart:async';
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
import '../../services/app_settings.dart';
import '../../sync/dto/sync_dto.dart';
import '../../sync/server/sync_server.dart';
import '../../sync/sync_provider.dart';
import '../../sync/ui/conflict_resolution_screen.dart';
import '../../widgets/app_shell.dart' show appScaffoldKey, navigateToCapture, navigateToEntry, navigateToTask;
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
  // Kachelgröße (max. Spaltenbreite) der Thumbnail-Ansicht
  double _gridTileSize = AppSettings.getGridTileSize();
  // 'date_desc' | 'date_asc' | 'name_asc' | 'name_desc'
  String _sortBy = 'date_desc';
  int _filterIndex = 0; // 0=Alle 1=Inbox 2=Angeheftet
  // IDs von gerade gewischten Einträgen – sofort aus der Liste entfernen,
  // bevor die DB-Aktualisierung den Stream neu aufbaut.
  final _dismissedIds = <String>{};

  static const _filterStatuses = ['all', 'inbox', 'pinned', 'done', 'archived', 'sub_note'];


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Konflikt-Dialog automatisch anzeigen wenn neue Konflikte auftreten
    ref.listenManual(syncStateProvider, (prev, next) {
      if (next.pendingConflicts.isEmpty) return;
      if (prev?.pendingConflicts.length == next.pendingConflicts.length) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showConflictDialog(next.pendingConflicts);
      });
    });
  }

  void _showConflictDialog(List<SyncConflict> conflicts) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ConflictDialog(conflicts: conflicts),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _setGridTileSize(double size) {
    final clamped = size.clamp(110.0, 320.0);
    setState(() => _gridTileSize = clamped);
    AppSettings.saveGridTileSize(clamped);
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
        'sub_note' => e.entry.status == 'sub_note',
        // 'all' zeigt alles AUSSER Sub-Notizen
        _          => e.entry.status != 'sub_note',
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

  /// Ordnet die Liste so um, dass Subtasks direkt unter ihrem Parent-Task
  /// stehen (eingerückt). Gibt die neue Reihenfolge + Set der Subtask-IDs zurück.
  /// Subtasks deren Parent nicht sichtbar ist, bleiben als normale Einträge.
  (List<EntryWithDetails>, Set<String>) _groupSubtasks(
      List<EntryWithDetails> entries) {
    final byId = {for (final e in entries) e.entry.id: e};
    final childrenOf = <String, List<EntryWithDetails>>{};
    final subtaskIds = <String>{};
    final topLevel = <EntryWithDetails>[];

    for (final e in entries) {
      final parentId = e.properties
          .where((p) => p.key == 'parent_entry_id')
          .firstOrNull
          ?.value;
      if (parentId != null && parentId.isNotEmpty && byId.containsKey(parentId)) {
        childrenOf.putIfAbsent(parentId, () => []).add(e);
        subtaskIds.add(e.entry.id);
      } else {
        topLevel.add(e);
      }
    }
    if (subtaskIds.isEmpty) return (entries, const <String>{});

    final result = <EntryWithDetails>[];
    for (final e in topLevel) {
      result.add(e);
      final kids = childrenOf[e.entry.id];
      if (kids != null) result.addAll(kids);
    }
    return (result, subtaskIds);
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
      body: RefreshIndicator(
        onRefresh: Platform.isMacOS || Platform.isWindows || Platform.isLinux
            ? () async {} // Desktop: kein Pull-to-Refresh (kein Touch)
            : () async {
                if (AppSettings.getSyncEnabled()) {
                  await ref.read(syncStateProvider.notifier).triggerSync();
                }
              },
        color: MFColors.teal,
        child: CustomScrollView(
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
              // Zoom-Steuerung nur in der Thumbnail-Ansicht
              if (_viewMode == 'view_grid') ...[
                IconButton(
                  icon: const Icon(Icons.zoom_out_rounded,
                      color: MFColors.textSecondary, size: 20),
                  tooltip: 'Kacheln größer',
                  onPressed: () => _setGridTileSize(_gridTileSize + 40),
                ),
                IconButton(
                  icon: const Icon(Icons.zoom_in_rounded,
                      color: MFColors.textSecondary, size: 20),
                  tooltip: 'Kacheln kleiner',
                  onPressed: () => _setGridTileSize(_gridTileSize - 40),
                ),
              ],
              // Sync-Status-Button
              _SyncStatusButton(),
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
              final flat = _filterAndSort(allEntries, filter)
                  .where((e) => !_dismissedIds.contains(e.entry.id))
                  .toList();
              // Subtasks unter ihren Parent einsortieren (außer Grid-Ansicht)
              final (entries, subtaskIds) = _viewMode == 'view_grid'
                  ? (flat, const <String>{})
                  : _groupSubtasks(flat);
              if (entries.isEmpty) {
                return SliverFillRemaining(
                  child: _EmptyFeed(
                      onCapture: () => navigateToCapture(context, ref)),
                );
              }
              if (_viewMode == 'view_grid') {
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                  sliver: SliverGrid(
                    // Responsive: Kachelbreite skalierbar (_gridTileSize),
                    // Spaltenzahl ergibt sich aus der Fensterbreite.
                    gridDelegate:
                        SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: _gridTileSize,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 0.78,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) => _GridCard(
                        item: entries[i],
                        onTap: () => entries[i].entry.type == 'task'
                            ? navigateToTask(context, ref, entries[i].entry.id)
                            : navigateToEntry(context, ref, entries[i].entry.id),
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
                    final isSubtask = subtaskIds.contains(item.entry.id);
                    return Padding(
                      key: ValueKey('feed-${item.entry.id}'),
                      padding: EdgeInsets.only(left: isSubtask ? 24 : 0),
                      child: Dismissible(
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
                        onTap: () => item.entry.type == 'task'
                            ? navigateToTask(context, ref, item.entry.id)
                            : navigateToEntry(context, ref, item.entry.id),
                        onToggleTask: item.entry.type == 'task'
                            ? () => ref.read(entryRepositoryProvider).toggleTaskStatus(item.entry.id)
                            : null,
                      ),
                    ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
      ), // RefreshIndicator

      floatingActionButton: FloatingActionButton(
        onPressed: () => navigateToCapture(context, ref),
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
      child: SingleChildScrollView(
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
                isExpanded: true,
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
                  child: Text(k,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
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

  // (label | null=icon-only, icon, tooltip)
  static const _filterDefs = [
    (label: 'Alle',  icon: Icons.dynamic_feed_outlined, tip: 'Alle'),
    (label: null,    icon: Icons.inbox_outlined,         tip: 'Inbox'),
    (label: null,    icon: Icons.push_pin_outlined,      tip: 'Angeheftet'),
    (label: null,    icon: Icons.check_circle_outline,   tip: 'Erledigt'),
    (label: null,    icon: Icons.archive_outlined,       tip: 'Archiviert'),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: _filterDefs.asMap().entries.map((entry) {
          final i = entry.key;
          final def = entry.value;
          final active = i == selectedIndex;
          final isText = def.label != null;
          return Padding(
            padding: EdgeInsets.only(
                right: i < _filterDefs.length - 1 ? 6 : 0),
            child: Tooltip(
              message: def.tip,
              child: GestureDetector(
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: isText
                      ? const EdgeInsets.symmetric(horizontal: 14, vertical: 6)
                      : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: active ? MFColors.tealBg : MFColors.surface,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: active ? MFColors.tealDark : MFColors.border,
                    ),
                  ),
                  child: isText
                      ? Text(def.label!,
                          style: TextStyle(
                              fontSize: 12,
                              color: active ? MFColors.teal : MFColors.textSecondary,
                              fontWeight: active ? FontWeight.bold : FontWeight.w500))
                      : Icon(def.icon, size: 17,
                          color: active ? MFColors.teal : MFColors.textSecondary),
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
                      cacheHeight: 180,
                      errorBuilder: (_, __, ___) => _placeholder(entry.type),
                    )
                  : coverLocalPath != null
                      ? Image.file(
                          File(coverLocalPath),
                          width: double.infinity,
                          height: 90,
                          fit: BoxFit.cover,
                          cacheHeight: 180,
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

// ── Sync-Status-Button in der AppBar ──────────────────────────────────────────

class _SyncStatusButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SyncStatusButton> createState() => _SyncStatusButtonState();
}

class _SyncStatusButtonState extends ConsumerState<_SyncStatusButton> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Im Server-Modus die verbundenen Clients live aktualisieren
    if (AppSettings.getSyncRole() == SyncRole.server) {
      _refreshTimer = Timer.periodic(
          const Duration(seconds: 5), (_) { if (mounted) setState(() {}); });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isServer = AppSettings.getSyncRole() == SyncRole.server;
    return isServer ? _buildServerCloud(context) : _buildClientCloud(context);
  }

  // ── Server-Modus: zeigt verbundene Clients (kein aktiver Sync-Status) ──────
  Widget _buildServerCloud(BuildContext context) {
    if (!AppSettings.getSyncEnabled()) return const SizedBox.shrink();

    final count = SyncServer.instance?.onlineClientCount ?? 0;
    final hasClients = count > 0;
    final color = hasClients ? const Color(0xFF10B981) : MFColors.textSecondary;

    final cloud = Stack(clipBehavior: Clip.none, children: [
      Icon(hasClients ? Icons.cloud_done : Icons.cloud_outlined,
          color: color, size: 24),
      Positioned(
        right: -7, top: -7,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          constraints: const BoxConstraints(minWidth: 16),
          decoration: BoxDecoration(
            color: hasClients ? const Color(0xFF10B981) : MFColors.textMuted,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: MFColors.bg, width: 1.5),
          ),
          child: Text('$count',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.white,
                  fontWeight: FontWeight.bold, height: 1.1)),
        ),
      ),
    ]);

    return IconButton(
      icon: cloud,
      tooltip: hasClients
          ? '$count ${count == 1 ? 'Gerät' : 'Geräte'} verbunden · '
              'tippen für Sync-Ping'
          : 'Keine Geräte verbunden',
      onPressed: () {
        // Server stößt einen Sync bei allen Clients an
        SyncServer.instance?.syncNotifyRequestedAt = DateTime.now().toUtc();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(hasClients
              ? 'Sync-Ping an $count ${count == 1 ? 'Gerät' : 'Geräte'} gesendet'
              : 'Keine verbundenen Geräte'),
          behavior: SnackBarBehavior.floating,
        ));
      },
    );
  }

  // ── Client-Modus: zeigt den eigenen Sync-Status ────────────────────────────
  Widget _buildClientCloud(BuildContext context) {
    final state = ref.watch(syncStateProvider);

    if (state.status == SyncStatus.disabled ||
        state.status == SyncStatus.notConfigured) {
      return const SizedBox.shrink();
    }

    final (icon, color) = switch (state.status) {
      SyncStatus.syncing => (Icons.sync, MFColors.teal),
      SyncStatus.success => (Icons.cloud_done_outlined, MFColors.teal),
      SyncStatus.error => (Icons.cloud_off_outlined, Colors.red),
      _ => (Icons.cloud_outlined, MFColors.textSecondary),
    };

    final cloudIcon = state.status == SyncStatus.syncing
        ? const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: MFColors.teal))
        : Icon(icon, color: color, size: 22);

    return IconButton(
      icon: cloudIcon,
      tooltip: switch (state.status) {
        SyncStatus.syncing => 'Synchronisiert…',
        SyncStatus.success => 'Synchronisiert',
        SyncStatus.error => state.message ?? 'Sync-Fehler',
        _ => 'Jetzt synchronisieren',
      },
      onPressed: state.status == SyncStatus.syncing
          ? null
          : () => ref.read(syncStateProvider.notifier).triggerSync(),
    );
  }
}

// ── Konflikt-Dialog ───────────────────────────────────────────────────────────

class _ConflictDialog extends ConsumerWidget {
  final List<SyncConflict> conflicts;
  const _ConflictDialog({required this.conflicts});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entryCount = conflicts.where((c) => c.entityType == 'entry').length;
    final containerCount = conflicts.where((c) => c.entityType == 'container').length;

    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.sync_problem, color: Colors.orange),
        const SizedBox(width: 8),
        Text('${conflicts.length} Sync-Konflikte'),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sowohl lokal als auch auf dem Server wurden Änderungen vorgenommen:',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (entryCount > 0)
            Text('• $entryCount Eintrag${entryCount == 1 ? '' : 'träge'}',
                style: const TextStyle(fontSize: 13)),
          if (containerCount > 0)
            Text('• $containerCount Container',
                style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 16),
          const Text('Was soll übernommen werden?',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
      actions: [
        // Detailübersicht: einzeln entscheiden
        TextButton.icon(
          onPressed: () {
            Navigator.pop(context);
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ConflictResolutionScreen(conflicts: conflicts),
            ));
          },
          icon: const Icon(Icons.list_alt_outlined, size: 16),
          label: const Text('Details ansehen'),
        ),
        // Server-Version behalten
        TextButton(
          onPressed: () {
            ref.read(syncStateProvider.notifier).resolveConflicts(ConflictResolution.server);
            Navigator.pop(context);
          },
          child: const Text('Server (alle)'),
        ),
        // Meine Version erzwingen
        TextButton(
          onPressed: () {
            ref.read(syncStateProvider.notifier).resolveConflicts(ConflictResolution.mine);
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Lokale Versionen werden übertragen…')),
            );
          },
          child: const Text('Meine (alle)'),
        ),
      ],
    );
  }
}
