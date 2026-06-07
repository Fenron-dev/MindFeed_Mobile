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
import '../selection/selection_provider.dart';
import '../selection/bulk_action_bar.dart';
import 'filter_builder_screen.dart';
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
  // Sortierung: Feld + Richtung. Feld: 'created'|'updated'|'title'|'due'|'prop:<key>'
  String _sortField = 'created';
  bool _sortAsc = false;
  // Schnellfilter (lokal, Tri-State): '' = alle. Keys:
  // 'inbox'|'pinned'|'done'|'archived'|'task'. _quickExcept = "alle außer".
  String _quickKey = '';
  bool _quickExcept = false;
  // IDs von gerade gewischten Einträgen – sofort aus der Liste entfernen,
  // bevor die DB-Aktualisierung den Stream neu aufbaut.
  final _dismissedIds = <String>{};

  /// Tri-State-Klick auf einen Schnellfilter-Chip: nur → außer → aus.
  void _cycleQuick(String key) {
    setState(() {
      if (_quickKey != key) {
        _quickKey = key; _quickExcept = false;
      } else if (!_quickExcept) {
        _quickExcept = true;
      } else {
        _quickKey = ''; _quickExcept = false;
      }
    });
  }


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
        // Sortierung: erneutes Tippen kehrt die Richtung um
        case 'sort_date':
          if (_sortField == 'created') { _sortAsc = !_sortAsc; }
          else { _sortField = 'created'; _sortAsc = false; }
          break;
        case 'sort_name':
          if (_sortField == 'title') { _sortAsc = !_sortAsc; }
          else { _sortField = 'title'; _sortAsc = true; }
          break;
      }
    });
  }

  /// Prüft den lokalen Schnellfilter (Tri-State). '' = alle (außer Sub-Notizen).
  bool _passesQuick(EntryWithDetails e) {
    if (_quickKey.isEmpty) return e.entry.status != 'sub_note';
    final match = switch (_quickKey) {
      'inbox'    => e.entry.status == 'inbox',
      'pinned'   => e.entry.pinned,
      'done'     => e.entry.status == 'done',
      'archived' => e.entry.status == 'archived',
      'task'     => e.entry.type == 'task',
      _          => true,
    };
    // Sub-Notizen grundsätzlich ausblenden (außer sie wären explizit gemeint)
    if (e.entry.status == 'sub_note') return false;
    return _quickExcept ? !match : match;
  }

  /// Wertet eine einzelne Bedingung gegen einen Eintrag aus.
  bool _matchesCondition(EntryWithDetails e, FilterCondition c) {
    final v = (c.value ?? '').toLowerCase();
    switch (c.field) {
      case FilterField.status:
        final ok = e.entry.status == c.value;
        return c.op == FilterOp.isNot ? !ok : ok;
      case FilterField.type:
        final ok = e.entry.type == c.value;
        return c.op == FilterOp.isNot ? !ok : ok;
      case FilterField.pinned:
        final ok = e.entry.pinned;
        return c.op == FilterOp.isNot ? !ok : ok;
      case FilterField.tag:
        final has = e.tags.any((t) => t.toLowerCase() == v);
        return (c.op == FilterOp.isNot || c.op == FilterOp.notContains) ? !has : has;
      case FilterField.container:
        final has = e.containerIds.contains(c.value);
        return c.op == FilterOp.isNot ? !has : has;
      case FilterField.property:
        final prop = e.properties
            .where((p) => p.key.toLowerCase() == (c.key ?? '').toLowerCase())
            .firstOrNull;
        switch (c.op) {
          case FilterOp.exists:    return prop != null;
          case FilterOp.notExists: return prop == null;
          case FilterOp.isNot:
            return !(prop != null && (prop.value ?? '').toLowerCase() == v);
          case FilterOp.notContains:
            return !(prop != null && (prop.value ?? '').toLowerCase().contains(v));
          case FilterOp.is_:
            return prop != null && (prop.value ?? '').toLowerCase() == v;
          default: // contains
            return prop != null && (prop.value ?? '').toLowerCase().contains(v);
        }
      case FilterField.createdDate:
        return _matchesDate(e.entry.createdAt, c);
      case FilterField.dueDate:
        return _matchesDate(e.entry.reminderAt, c);
    }
  }

  bool _matchesDate(DateTime? d, FilterCondition c) {
    if (d == null) return false;
    final day = DateTime(d.year, d.month, d.day);
    switch (c.op) {
      case FilterOp.before:
        return c.date1 != null && day.isBefore(_dayOf(c.date1!));
      case FilterOp.after:
        return c.date1 != null && day.isAfter(_dayOf(c.date1!));
      case FilterOp.between:
        if (c.date1 == null || c.date2 == null) return false;
        return !day.isBefore(_dayOf(c.date1!)) && !day.isAfter(_dayOf(c.date2!));
      default:
        return true;
    }
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  List<EntryWithDetails> _filterAndSort(
      List<EntryWithDetails> entries, FeedFilter filter) {
    var result = entries.where((e) {
      if (!_passesQuick(e)) return false;
      // Erweiterter Filter (DNF): mind. eine Gruppe muss vollständig passen
      if (filter.hasConditions) {
        final anyGroup = filter.groups.any((g) =>
            g.conditions.isNotEmpty &&
            g.conditions.every((c) => _matchesCondition(e, c)));
        if (!anyGroup) return false;
      }
      return true;
    }).toList();

    _applySort(result);
    return result;
  }

  void _applySort(List<EntryWithDetails> result) {
    int cmp(EntryWithDetails a, EntryWithDetails b) {
      if (_sortField == 'title') {
        return (a.entry.title ?? '').toLowerCase()
            .compareTo((b.entry.title ?? '').toLowerCase());
      }
      if (_sortField == 'updated') {
        return a.entry.updatedAt.compareTo(b.entry.updatedAt);
      }
      if (_sortField == 'due') {
        final ad = a.entry.reminderAt, bd = b.entry.reminderAt;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1; // ohne Datum ans Ende
        if (bd == null) return -1;
        return ad.compareTo(bd);
      }
      if (_sortField.startsWith('prop:')) {
        final key = _sortField.substring(5).toLowerCase();
        final av = a.properties.where((p) => p.key.toLowerCase() == key).firstOrNull?.value ?? '';
        final bv = b.properties.where((p) => p.key.toLowerCase() == key).firstOrNull?.value ?? '';
        final an = num.tryParse(av), bn = num.tryParse(bv);
        if (an != null && bn != null) return an.compareTo(bn);
        return av.toLowerCase().compareTo(bv.toLowerCase());
      }
      // 'created' (default)
      return a.entry.createdAt.compareTo(b.entry.createdAt);
    }
    result.sort((a, b) => _sortAsc ? cmp(a, b) : -cmp(a, b));
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

  bool get _sortByDate => _sortField == 'created';
  bool get _sortByName => _sortField == 'title';
  String get _sortDateLabel => (_sortByDate && _sortAsc)
      ? 'Datum ↑ (älteste zuerst)'
      : 'Datum ↓ (neueste zuerst)';
  String get _sortNameLabel =>
      (_sortByName && !_sortAsc) ? 'Name Z → A' : 'Name A → Z';

  IconData get _sortDateIcon => (_sortByDate && _sortAsc)
      ? Icons.arrow_upward_rounded
      : Icons.arrow_downward_rounded;
  IconData get _sortNameIcon => (_sortByName && !_sortAsc)
      ? Icons.text_rotation_angledown_outlined
      : Icons.sort_by_alpha_outlined;

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(feedProvider);
    final filter   = ref.watch(feedFilterProvider);
    final selectionMode = ref.watch(selectionModeProvider);
    final selectedIds = ref.watch(selectedIdsProvider);

    return Scaffold(
      bottomNavigationBar: const BulkActionBar(),
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
                onPressed: () => _showFilterBuilder(context, filter),
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
                  _menuItem('sort_date', _sortDateIcon, _sortDateLabel, _sortByDate),
                  _menuItem('sort_name', _sortNameIcon, _sortNameLabel, _sortByName),
                ],
              ),
            ],
            bottom: PreferredSize(
              preferredSize: Size.fromHeight(filter.isActive ? 88 : 44),
              child: Column(children: [
                _QuickFilterBar(
                  quickKey: _quickKey,
                  quickExcept: _quickExcept,
                  onQuick: _cycleQuick,
                  onOpenBuilder: () => _showFilterBuilder(context, filter),
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
                      (ctx, i) {
                        final id = entries[i].entry.id;
                        return _GridCard(
                          item: entries[i],
                          selected: selectionMode && selectedIds.contains(id),
                          onLongPress: () => ref.enterSelection(id),
                          onTap: () {
                            if (selectionMode) { ref.toggleSelected(id); return; }
                            entries[i].entry.type == 'task'
                                ? navigateToTask(context, ref, id)
                                : navigateToEntry(context, ref, id);
                          },
                        );
                      },
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
                    final id = item.entry.id;
                    final isSubtask = subtaskIds.contains(id);
                    final card = EntryCard(
                      item: item,
                      compact: _viewMode == 'view_list',
                      selectionMode: selectionMode,
                      selected: selectedIds.contains(id),
                      onTap: () {
                        if (selectionMode) { ref.toggleSelected(id); return; }
                        item.entry.type == 'task'
                            ? navigateToTask(context, ref, id)
                            : navigateToEntry(context, ref, id);
                      },
                      onLongPress: () => ref.enterSelection(id),
                      onToggleTask: item.entry.type == 'task'
                          ? () => ref.read(entryRepositoryProvider).toggleTaskStatus(id)
                          : null,
                    );
                    // Im Auswahlmodus kein Wischen (Konflikt mit Auswahl)
                    if (selectionMode) {
                      return Padding(
                        key: ValueKey('feed-$id'),
                        padding: EdgeInsets.only(left: isSubtask ? 24 : 0),
                        child: card,
                      );
                    }
                    return Padding(
                      key: ValueKey('feed-$id'),
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
                      child: card,
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
  Future<void> _showFilterBuilder(BuildContext ctx, FeedFilter current) async {
    final isDesktop =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    // Aktuelle Sortierung in den Filter übernehmen, damit der Builder sie zeigt
    final start = current.copyWith(sortField: _sortField, sortAsc: _sortAsc);
    FeedFilter? result;
    if (isDesktop) {
      result = await showDialog<FeedFilter>(
        context: ctx,
        builder: (_) => Dialog(
          backgroundColor: MFColors.surface,
          insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
            child: FilterBuilderScreen(initial: start),
          ),
        ),
      );
    } else {
      result = await Navigator.of(ctx).push<FeedFilter>(
        MaterialPageRoute(builder: (_) => FilterBuilderScreen(initial: start)),
      );
    }
    if (result != null) {
      ref.read(feedFilterProvider.notifier).state = result;
      setState(() {
        _sortField = result!.sortField;
        _sortAsc = result.sortAsc;
      });
    }
  }
}

// ─── Aktive Filter als Chips ──────────────────────────────────────────────────
class _ActiveFilterBar extends ConsumerWidget {
  final FeedFilter filter;
  const _ActiveFilterBar({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conds = filter.allConditions.toList();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(children: [
        ...conds.map((c) => _FilterChip(
              label: conditionLabel(c),
              onRemove: () => ref.read(feedFilterProvider.notifier).update(
                  (f) => f.removeWhere((x) => identical(x, c))),
            )),
        // (conditionLabel ist Top-Level in feed_filter.dart)
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () =>
              ref.read(feedFilterProvider.notifier).state = const FeedFilter(),
          child: const Icon(Icons.close, size: 14, color: MFColors.textMuted),
        ),
      ]),
    );
  }

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
class _QuickFilterBar extends ConsumerWidget {
  final String quickKey;          // '' | inbox | pinned | done | archived | task
  final bool quickExcept;
  final void Function(String key) onQuick;
  final VoidCallback onOpenBuilder;

  const _QuickFilterBar({
    required this.quickKey,
    required this.quickExcept,
    required this.onQuick,
    required this.onOpenBuilder,
  });

  static const _defs = [
    (key: '',         icon: Icons.dynamic_feed_outlined, tip: 'Alle'),
    (key: 'inbox',    icon: Icons.inbox_outlined,        tip: 'Inbox'),
    (key: 'pinned',   icon: Icons.push_pin_outlined,     tip: 'Angeheftet'),
    (key: 'done',     icon: Icons.check_circle_outline,  tip: 'Erledigt'),
    (key: 'archived', icon: Icons.archive_outlined,      tip: 'Archiviert'),
    (key: 'task',     icon: Icons.task_alt_outlined,     tip: 'Aufgaben'),
  ];

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_isDesktop) return _buildDesktop(context, ref);
    return _buildMobile(context, ref);
  }

  // Desktop: Inline-Tri-State-Chips + Gespeichert + Filter
  Widget _buildDesktop(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(children: [
        ..._defs.map((d) {
          final active = quickKey == d.key && (d.key.isNotEmpty);
          final except = active && quickExcept;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Tooltip(
              message: except ? '${d.tip} (außer)' : d.tip,
              child: GestureDetector(
                onTap: () => onQuick(d.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: (quickKey == d.key) ? MFColors.tealBg : MFColors.surface,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: except
                          ? const Color(0xFFEF4444)
                          : (quickKey == d.key ? MFColors.tealDark : MFColors.border),
                    ),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (except)
                      const Icon(Icons.block, size: 13, color: Color(0xFFEF4444))
                    else
                      Icon(d.icon, size: 17,
                          color: quickKey == d.key ? MFColors.teal : MFColors.textSecondary),
                  ]),
                ),
              ),
            ),
          );
        }),
        const SizedBox(width: 4),
        _SavedFiltersButton(),
        const SizedBox(width: 4),
        _miniButton(Icons.tune_rounded, 'Filter', onOpenBuilder),
      ]),
    );
  }

  // Mobile: zwei Dropdowns (Typ/Status, Gespeichert) + Filter-Button
  Widget _buildMobile(BuildContext context, WidgetRef ref) {
    final activeDef = _defs.firstWhere((d) => d.key == quickKey,
        orElse: () => _defs.first);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(children: [
        // Typ/Status-Dropdown (Tri-State via Einträge)
        PopupMenuButton<String>(
          onSelected: onQuick,
          color: MFColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: MFColors.border)),
          itemBuilder: (_) => _defs.where((d) => d.key.isNotEmpty).map((d) {
            final sel = quickKey == d.key;
            return PopupMenuItem<String>(
              value: d.key,
              child: Row(children: [
                Icon(d.icon, size: 16,
                    color: sel ? MFColors.teal : MFColors.textSecondary),
                const SizedBox(width: 10),
                Text(sel && quickExcept ? '${d.tip} (außer)' : d.tip,
                    style: TextStyle(color: sel ? MFColors.teal : MFColors.textPrimary)),
                if (sel) ...[
                  const Spacer(),
                  Icon(quickExcept ? Icons.block : Icons.check,
                      size: 14,
                      color: quickExcept ? const Color(0xFFEF4444) : MFColors.teal),
                ],
              ]),
            );
          }).toList(),
          child: _dropdownChip(
            quickKey.isEmpty ? Icons.dynamic_feed_outlined : activeDef.icon,
            quickKey.isEmpty ? 'Typ/Status'
                : (quickExcept ? '${activeDef.tip} (außer)' : activeDef.tip),
            quickKey.isNotEmpty,
          ),
        ),
        const SizedBox(width: 8),
        _SavedFiltersButton(),
        const Spacer(),
        _miniButton(Icons.tune_rounded, 'Filter', onOpenBuilder),
      ]),
    );
  }

  static Widget _dropdownChip(IconData icon, String label, bool active) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? MFColors.tealBg : MFColors.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: active ? MFColors.tealDark : MFColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: active ? MFColors.teal : MFColors.textSecondary),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12,
              color: active ? MFColors.teal : MFColors.textSecondary)),
          const Icon(Icons.expand_more, size: 16, color: MFColors.textMuted),
        ]),
      );

  static Widget _miniButton(IconData icon, String label, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: MFColors.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: MFColors.textSecondary),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(fontSize: 12, color: MFColors.textSecondary)),
          ]),
        ),
      );
}

/// Dropdown der gespeicherten Filter (+ aktuellen speichern).
class _SavedFiltersButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedFiltersProvider);
    return PopupMenuButton<String>(
      color: MFColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: MFColors.border)),
      onSelected: (id) async {
        if (id == '__save__') {
          await _saveCurrent(context, ref);
        } else {
          final f = saved.firstWhere((s) => s.id == id,
              orElse: () => saved.first);
          ref.read(feedFilterProvider.notifier).state = f.filter;
        }
      },
      itemBuilder: (_) => [
        ...saved.map((s) => PopupMenuItem<String>(
              value: s.id,
              child: Row(children: [
                Text(s.emoji ?? '🔖'),
                const SizedBox(width: 8),
                Expanded(child: Text(s.name,
                    style: const TextStyle(color: MFColors.textPrimary))),
                GestureDetector(
                  onTap: () {
                    final list = saved.where((x) => x.id != s.id).toList();
                    ref.read(savedFiltersProvider.notifier).state = list;
                    AppSettings.saveSavedFilters(list);
                    Navigator.of(context).pop();
                  },
                  child: const Icon(Icons.delete_outline, size: 15, color: MFColors.textMuted),
                ),
              ]),
            )),
        if (saved.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: '__save__',
          child: Row(children: [
            Icon(Icons.bookmark_add_outlined, size: 16, color: MFColors.teal),
            SizedBox(width: 8),
            Text('Aktuellen Filter speichern', style: TextStyle(color: MFColors.teal)),
          ]),
        ),
      ],
      child: _QuickFilterBar._dropdownChip(
          Icons.bookmark_outline_rounded, 'Gespeichert', false),
    );
  }

  Future<void> _saveCurrent(BuildContext context, WidgetRef ref) async {
    final current = ref.read(feedFilterProvider);
    if (!current.isActive) return;
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Filter speichern',
            style: TextStyle(color: MFColors.textPrimary)),
        content: TextField(
          controller: nameCtrl, autofocus: true,
          style: const TextStyle(color: MFColors.textPrimary),
          decoration: const InputDecoration(hintText: 'Name des Filters'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Abbrechen', style: TextStyle(color: MFColors.textMuted))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
              child: const Text('Speichern', style: TextStyle(color: MFColors.teal))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final list = [
      ...ref.read(savedFiltersProvider),
      SavedFilter(
          id: 'sf-${DateTime.now().millisecondsSinceEpoch}',
          name: name, filter: current),
    ];
    ref.read(savedFiltersProvider.notifier).state = list;
    await AppSettings.saveSavedFilters(list);
  }
}

// ─── Grid-Karte (Thumbnail-Ansicht) ──────────────────────────────────────────
class _GridCard extends StatelessWidget {
  final EntryWithDetails item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  const _GridCard({required this.item, required this.onTap, this.onLongPress, this.selected = false});

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
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? MFColors.teal
                : (entry.pinned ? const Color(0xFF831843) : MFColors.border),
            width: selected ? 2 : (entry.pinned ? 1.5 : 1),
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
