import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../core/constants.dart';
import '../core/theme.dart';
import '../core/vault_manager.dart';
import '../data/repositories/container_repository.dart';
import '../features/capture/capture_screen.dart';
import '../features/containers/container_detail_screen.dart';
import '../features/containers/container_provider.dart';
import '../features/entry_detail/entry_detail_screen.dart';
import '../features/tasks/task_detail_screen.dart';
import '../services/app_settings.dart';

bool get _isDesktop =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// GlobalKey damit FeedScreen (verschachtelter Scaffold) den Drawer öffnen kann.
final appScaffoldKey = GlobalKey<ScaffoldState>();

class AppShell extends StatefulWidget {
  final StatefulNavigationShell shell;
  const AppShell({super.key, required this.shell});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _showNavBar = true;

  void _onDestinationSelected(int index) {
    // Tab-Wechsel → Nav immer wieder einblenden
    if (index != widget.shell.currentIndex) {
      setState(() => _showNavBar = true);
    }
    widget.shell.goBranch(index);
  }

  bool _handleScroll(ScrollNotification notification) {
    // Auf dem Settings-Tab (Index 3) immer sichtbar lassen
    if (widget.shell.currentIndex == 3) return false;

    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta > 3.0 && _showNavBar) {
        setState(() => _showNavBar = false);
      } else if (delta < -3.0 && !_showNavBar) {
        setState(() => _showNavBar = true);
      }
    } else if (notification is ScrollEndNotification) {
      if (notification.metrics.pixels <= 0) {
        setState(() => _showNavBar = true);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_isDesktop) return _DesktopShell(shell: widget.shell);

    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    const navContentHeight = 80.0;

    return Scaffold(
      key: appScaffoldKey,
      body: NotificationListener<ScrollNotification>(
        onNotification: _handleScroll,
        child: widget.shell,
      ),
      drawer: const MindFeedDrawer(),
      bottomNavigationBar: ClipRect(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          height: _showNavBar ? navContentHeight + bottomPad : 0.0,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: navContentHeight + bottomPad,
            child: NavigationBar(
              selectedIndex: widget.shell.currentIndex,
              onDestinationSelected: _onDestinationSelected,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dynamic_feed_outlined),
                  selectedIcon: Icon(Icons.dynamic_feed),
                  label: 'Feed',
                ),
                NavigationDestination(
                  icon: Icon(Icons.task_alt_outlined),
                  selectedIcon: Icon(Icons.task_alt_rounded),
                  label: 'Aufgaben',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search_outlined),
                  selectedIcon: Icon(Icons.search),
                  label: 'Suche',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Einstellungen',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Desktop-Layout: permanente Sidebar + Content ──────────────────────────────

// Provider für ausgewählten Container (Desktop Explorer-Stil)
final desktopSelectedContainerProvider = StateProvider<String?>((ref) => null);
// Provider für geöffneten Eintrag (Desktop inline-Ansicht)
final desktopSelectedEntryProvider = StateProvider<String?>((ref) => null);
// Provider für geöffneten Task (Desktop inline-Ansicht)
final desktopSelectedTaskProvider = StateProvider<String?>((ref) => null);
// Provider für Sidebar-Pin (true = permanent sichtbar)
final desktopSidebarPinnedProvider = StateProvider<bool>((ref) => true);
// Provider für inline Capture (Desktop)
final desktopCaptureProvider = StateProvider<_CaptureArgs?>((ref) => null);

/// Argumente für den inline Desktop-Capture.
class _CaptureArgs {
  final String? initialText;
  final List<String>? sharedFilePaths;
  final String? initialContainerId;
  final String? parentEntryId;
  const _CaptureArgs({
    this.initialText,
    this.sharedFilePaths,
    this.initialContainerId,
    this.parentEntryId,
  });
}

/// Navigiert zu einem Eintrag: auf Desktop inline, auf Mobile per Route.
void navigateToEntry(BuildContext context, WidgetRef ref, String entryId) {
  if (_isDesktop) {
    ref.read(desktopSelectedEntryProvider.notifier).state = entryId;
  } else {
    context.push(AppRoutes.entryDetailPath(entryId));
  }
}

/// Navigiert zu einem Task: auf Desktop inline, auf Mobile per Route.
void navigateToTask(BuildContext context, WidgetRef ref, String taskId) {
  if (_isDesktop) {
    ref.read(desktopSelectedTaskProvider.notifier).state = taskId;
  } else {
    context.push(AppRoutes.taskDetailPath(taskId));
  }
}

/// Öffnet den Capture-Screen: auf Desktop inline (mit Sidebar), auf Mobile als Route.
void navigateToCapture(
  BuildContext context,
  WidgetRef ref, {
  String? initialText,
  String? initialContainerId,
  String? parentEntryId,
}) {
  if (_isDesktop) {
    ref.read(desktopCaptureProvider.notifier).state = _CaptureArgs(
      initialText: initialText,
      initialContainerId: initialContainerId,
      parentEntryId: parentEntryId,
    );
  } else {
    final sb = StringBuffer(AppRoutes.capture);
    var first = true;
    void add(String k, String v) {
      sb.write(first ? '?' : '&');
      sb.write('$k=${Uri.encodeComponent(v)}');
      first = false;
    }
    if (initialText != null) add('sharedText', initialText);
    if (initialContainerId != null) add('containerId', initialContainerId);
    if (parentEntryId != null) add('parentEntryId', parentEntryId);
    context.push(sb.toString());
  }
}

class _DesktopShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell shell;
  const _DesktopShell({required this.shell});

  @override
  ConsumerState<_DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<_DesktopShell> {
  // Trackpad-Swipe-Akkumulator für Zwei-Finger-Zurück-Geste
  double _swipeAccX = 0;
  DateTime? _lastSwipeEvent;

  void _go(int index) {
    // Alle Detail-Overlays schließen, damit der Tab-Wechsel sofort sichtbar ist
    ref.read(desktopSelectedContainerProvider.notifier).state = null;
    ref.read(desktopSelectedEntryProvider.notifier).state = null;
    ref.read(desktopSelectedTaskProvider.notifier).state = null;
    ref.read(desktopCaptureProvider.notifier).state = null;
    widget.shell.goBranch(index);
  }

  /// Geht einen Schritt zurück: schließt das oberste Overlay bzw. poppt die
  /// Route. Wird von der Zwei-Finger-Swipe-Geste UND der ESC-Taste genutzt.
  void _handleBack() {
    // Capture → Entry → Task → Container → Router-Pop
    if (ref.read(desktopCaptureProvider) != null) {
      ref.read(desktopCaptureProvider.notifier).state = null;
    } else if (ref.read(desktopSelectedEntryProvider) != null) {
      ref.read(desktopSelectedEntryProvider.notifier).state = null;
    } else if (ref.read(desktopSelectedTaskProvider) != null) {
      ref.read(desktopSelectedTaskProvider.notifier).state = null;
    } else if (ref.read(desktopSelectedContainerProvider) != null) {
      ref.read(desktopSelectedContainerProvider.notifier).state = null;
    } else if (context.canPop()) {
      context.pop();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy.abs();
    // Nur horizontale Bewegung berücksichtigen
    if (dx.abs() < dy) return;

    final now = DateTime.now();
    if (_lastSwipeEvent != null &&
        now.difference(_lastSwipeEvent!) > const Duration(milliseconds: 300)) {
      _swipeAccX = 0; // Reset bei Pause
    }
    _swipeAccX += dx;
    _lastSwipeEvent = now;

    // Threshold: 120px akkumuliert → Swipe erkannt
    if (_swipeAccX.abs() > 120) {
      // dx > 0: Finger von rechts nach links (natural scroll) → zurück
      if (_swipeAccX > 0) _handleBack();
      _swipeAccX = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinned = ref.watch(desktopSidebarPinnedProvider);
    final selectedContainer = ref.watch(desktopSelectedContainerProvider);
    final selectedEntry = ref.watch(desktopSelectedEntryProvider);
    final selectedTask = ref.watch(desktopSelectedTaskProvider);
    final captureArgs = ref.watch(desktopCaptureProvider);

    final sidebar = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      width: pinned ? 240 : 0,
      child: pinned
          ? _DesktopSidebar(
              currentIndex: widget.shell.currentIndex,
              onDestinationSelected: _go,
              pinned: true,
            )
          : null,
    );

    // Hauptinhalt: Capture > Eintrag > Task > Container > Shell
    Widget mainContent;
    if (captureArgs != null) {
      mainContent = _DesktopCaptureView(
        args: captureArgs,
        onClose: () => ref.read(desktopCaptureProvider.notifier).state = null,
      );
    } else if (selectedEntry != null) {
      mainContent = _DesktopEntryView(
        entryId: selectedEntry,
        onClose: () => ref.read(desktopSelectedEntryProvider.notifier).state = null,
      );
    } else if (selectedTask != null) {
      mainContent = _DesktopTaskView(
        taskId: selectedTask,
        onClose: () => ref.read(desktopSelectedTaskProvider.notifier).state = null,
      );
    } else if (selectedContainer != null) {
      mainContent = _DesktopContainerView(
        containerId: selectedContainer,
        onClose: () => ref.read(desktopSelectedContainerProvider.notifier).state = null,
      );
    } else {
      mainContent = widget.shell;
    }

    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          // ESC = zurück/abbrechen (wie in Desktop-Apps üblich)
          const SingleActivator(LogicalKeyboardKey.escape): _handleBack,
          // Cmd+T = Neuer Task
          SingleActivator(LogicalKeyboardKey.keyT, meta: Platform.isMacOS, control: !Platform.isMacOS): () {
            ref.read(desktopCaptureProvider.notifier).state = null;
            ref.read(desktopSelectedEntryProvider.notifier).state = null;
            ref.read(desktopSelectedTaskProvider.notifier).state = null;
            widget.shell.goBranch(1); // Tasks-Tab
            context.push(AppRoutes.taskNew);
          },
          // Cmd+N = Neuer Eintrag (bestehender Shortcut, explizit dokumentiert)
          SingleActivator(LogicalKeyboardKey.keyN, meta: Platform.isMacOS, control: !Platform.isMacOS): () {
            navigateToCapture(context, ref);
          },
        },
        child: Scaffold(
      key: appScaffoldKey,
      drawer: pinned
          ? null
          : Drawer(
              child: _DesktopSidebar(
                currentIndex: widget.shell.currentIndex,
                onDestinationSelected: _go,
                pinned: false,
              ),
            ),
      body: Row(
        children: [
          if (pinned) ...[
            SizedBox(width: 240, child: sidebar),
            const VerticalDivider(width: 1, thickness: 1, color: MFColors.border),
          ],
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: _onPointerSignal,
              child: Stack(
                children: [
                  mainContent,
                  // Hamburger-Button rechts oben wenn Sidebar ausgeblendet
                  if (!pinned)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: MFColors.surface.withAlpha(220),
                        borderRadius: BorderRadius.circular(8),
                        child: IconButton(
                          icon: const Icon(Icons.menu, color: MFColors.textSecondary, size: 20),
                          tooltip: 'Seitenleiste anzeigen',
                          onPressed: () => appScaffoldKey.currentState?.openDrawer(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}

class _DesktopSidebar extends ConsumerWidget {
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool pinned;

  const _DesktopSidebar({
    required this.currentIndex,
    required this.onDestinationSelected,
    this.pinned = true,
  });

  String _vaultLabel() {
    final path = AppSettings.getVaultPath();
    if (path == null) return 'Standard-Vault';
    final name = p.basename(path);
    return name.isEmpty ? 'Standard-Vault' : name;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectsProvider);
    final areasAsync = ref.watch(areasProvider);
    final hubsAsync = ref.watch(hubsProvider);

    void navigate(String containerId) {
      // Offenen Eintrag/Capture schließen, damit der Container direkt erscheint
      ref.read(desktopSelectedEntryProvider.notifier).state = null;
      ref.read(desktopCaptureProvider.notifier).state = null;
      ref.read(desktopSelectedContainerProvider.notifier).state = containerId;
      // Drawer schließen wenn nicht gepinnt
      if (!pinned) Navigator.of(context).pop();
    }

    void togglePin() {
      if (pinned) {
        ref.read(desktopSidebarPinnedProvider.notifier).state = false;
      } else {
        ref.read(desktopSidebarPinnedProvider.notifier).state = true;
        // Drawer schließen
        Navigator.of(context).maybePop();
      }
    }

    return Container(
      color: MFColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // App-Header mit Pin-Button
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
            child: Row(children: [
              Container(
                width: 26, height: 26,
                decoration: BoxDecoration(
                  color: MFColors.tealBg,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(Icons.psychology_outlined,
                    color: MFColors.teal, size: 15),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('MindFeed',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: MFColors.textPrimary)),
              ),
              // Pin-Button: Toggle Sidebar anheften/ablösen
              IconButton(
                icon: Icon(
                  pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 16,
                ),
                tooltip: pinned ? 'Seitenleiste ausblenden' : 'Seitenleiste anheften',
                color: pinned ? MFColors.teal : MFColors.textMuted,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: togglePin,
              ),
            ]),
          ),
          const Divider(color: MFColors.border, height: 1),

          // ── Vault-Anzeige ──────────────────────────────────────────────────
          InkWell(
            onTap: () {
              if (!pinned) Navigator.of(context).maybePop();
              context.push(AppRoutes.vaultSwitcher);
            },
            child: Container(
              margin: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: MFColors.tealBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: MFColors.teal.withAlpha(60)),
              ),
              child: Row(children: [
                const Icon(Icons.folder_rounded, size: 15, color: MFColors.teal),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _vaultLabel(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: MFColors.teal,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const Icon(Icons.unfold_more, size: 14, color: MFColors.teal),
              ]),
            ),
          ),
          const Divider(color: MFColors.border, height: 1),
          const SizedBox(height: 6),

          // Neu-Button (prominent, ersetzt den weit entfernten FAB)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => navigateToCapture(context, ref),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Neuer Eintrag'),
                style: FilledButton.styleFrom(
                  backgroundColor: MFColors.teal,
                  foregroundColor: MFColors.bg,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(color: MFColors.border, height: 1),
          const SizedBox(height: 6),

          // Navigation
          _SidebarNavItem(
            icon: Icons.dynamic_feed_outlined,
            selectedIcon: Icons.dynamic_feed,
            label: 'Feed',
            selected: currentIndex == 0,
            onTap: () { onDestinationSelected(0); if (!pinned) Navigator.of(context).maybePop(); },
          ),
          _SidebarNavItem(
            icon: Icons.task_alt_outlined,
            selectedIcon: Icons.task_alt_rounded,
            label: 'Aufgaben',
            selected: currentIndex == 1,
            onTap: () { onDestinationSelected(1); if (!pinned) Navigator.of(context).maybePop(); },
          ),
          _SidebarNavItem(
            icon: Icons.search_outlined,
            selectedIcon: Icons.search,
            label: 'Suche',
            selected: currentIndex == 2,
            onTap: () { onDestinationSelected(2); if (!pinned) Navigator.of(context).maybePop(); },
          ),

          const SizedBox(height: 8),
          const Divider(color: MFColors.border, height: 1),
          const SizedBox(height: 4),

          // Container-Baum
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                _SectionHeaderWithAdd('BEREICHE',
                    onAdd: () => context.push('${AppRoutes.containerNew}?kind=area')),
                areasAsync.when(
                  loading: () => const _LoadingTile(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (tree) => _ContainerTree(tree: tree, onTap: navigate),
                ),
                _SectionHeaderWithAdd('PROJEKTE',
                    onAdd: () => context.push('${AppRoutes.containerNew}?kind=project')),
                projectsAsync.when(
                  loading: () => const _LoadingTile(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (tree) => tree.isEmpty
                      ? const _EmptyHint('Noch keine Projekte')
                      : _ContainerTree(tree: tree, onTap: navigate),
                ),
                _SectionHeaderWithAdd('SMART HUBS',
                    onAdd: () => context.push('${AppRoutes.containerNew}?kind=hub')),
                hubsAsync.when(
                  loading: () => const _LoadingTile(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (tree) => _ContainerTree(tree: tree, onTap: navigate),
                ),
              ],
            ),
          ),

          const Divider(color: MFColors.border, height: 1),

          // Einstellungen unten
          _SidebarNavItem(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: 'Einstellungen',
            selected: currentIndex == 3,
            onTap: () { onDestinationSelected(3); if (!pinned) Navigator.of(context).maybePop(); },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SidebarNavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? MFColors.tealBg : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(
              selected ? selectedIcon : icon,
              size: 16,
              color: selected ? MFColors.teal : MFColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? MFColors.teal : MFColors.textPrimary,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ─── Drawer ───────────────────────────────────────────────────────────────────

class MindFeedDrawer extends ConsumerWidget {
  const MindFeedDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectsProvider);
    final areasAsync = ref.watch(areasProvider);
    final hubsAsync = ref.watch(hubsProvider);

    void navigate(String containerId) {
      context.push(AppRoutes.containerDetailPath(containerId));
      Navigator.pop(context);
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
              child: Row(children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: MFColors.tealBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.psychology_outlined,
                      color: MFColors.teal, size: 18),
                ),
                const SizedBox(width: 10),
                Text('MindFeed',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: MFColors.textPrimary)),
              ]),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  _DrawerItem(
                    icon: Icons.dynamic_feed_outlined,
                    label: 'Alle Einträge',
                    color: MFColors.teal,
                    onTap: () {
                      context.go(AppRoutes.feed);
                      Navigator.pop(context);
                    },
                  ),
                  _SectionHeaderWithAdd('BEREICHE',
                      onAdd: () { context.push('${AppRoutes.containerNew}?kind=area'); Navigator.pop(context); }),
                  areasAsync.when(
                    loading: () => const _LoadingTile(),
                    error: (_, __) => const SizedBox.shrink(),
                    data: (tree) => _ContainerTree(
                        tree: tree, onTap: navigate),
                  ),
                  _SectionHeaderWithAdd('PROJEKTE',
                      onAdd: () { context.push('${AppRoutes.containerNew}?kind=project'); Navigator.pop(context); }),
                  projectsAsync.when(
                    loading: () => const _LoadingTile(),
                    error: (_, __) => const SizedBox.shrink(),
                    data: (tree) => tree.isEmpty
                        ? const _EmptyHint('Noch keine Projekte')
                        : _ContainerTree(tree: tree, onTap: navigate),
                  ),
                  _SectionHeaderWithAdd('SMART HUBS',
                      onAdd: () { context.push('${AppRoutes.containerNew}?kind=hub'); Navigator.pop(context); }),
                  hubsAsync.when(
                    loading: () => const _LoadingTile(),
                    error: (_, __) => const SizedBox.shrink(),
                    data: (tree) => _ContainerTree(
                        tree: tree, onTap: navigate),
                  ),
                ],
              ),
            ),
            const Divider(),
            _DrawerItem(
              icon: Icons.settings_outlined,
              label: 'Einstellungen',
              onTap: () {
                context.go(AppRoutes.settings);
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

// ─── Container-Baum ──────────────────────────────────────────────────────────

class _ContainerTree extends StatelessWidget {
  final List<ContainerWithChildren> tree;
  final void Function(String containerId) onTap;
  final int depth;

  const _ContainerTree({
    super.key,
    required this.tree,
    required this.onTap,
    this.depth = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (tree.isEmpty) return const SizedBox.shrink();
    return Column(
      children: tree
          .map((node) =>
              _ContainerTile(node: node, onTap: onTap, depth: depth))
          .toList(),
    );
  }
}

class _ContainerTile extends StatefulWidget {
  final ContainerWithChildren node;
  final void Function(String) onTap;
  final int depth;
  const _ContainerTile(
      {required this.node, required this.onTap, required this.depth});
  @override
  State<_ContainerTile> createState() => _ContainerTileState();
}

class _ContainerTileState extends State<_ContainerTile> {
  bool _expanded = true;

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
  Widget build(BuildContext context) {
    final c = widget.node.container;
    final hasChildren = widget.node.children.isNotEmpty;

    return Column(children: [
      Padding(
        padding: EdgeInsets.only(left: widget.depth * 12.0),
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(_iconFor(c.icon), size: 17,
              color: _parseColor(c.color)),
          title: Row(children: [
            Expanded(
              child: Text(c.name,
                  style: const TextStyle(
                      fontSize: 13, color: MFColors.textPrimary)),
            ),
            if (widget.node.entryCount > 0)
              Container(
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: MFColors.border,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '${widget.node.entryCount}',
                  style: const TextStyle(
                      fontSize: 10,
                      color: MFColors.textMuted,
                      fontFamily: 'monospace'),
                ),
              ),
          ]),
          trailing: hasChildren
              ? GestureDetector(
                  onTap: () =>
                      setState(() => _expanded = !_expanded),
                  child: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: MFColors.textMuted,
                  ))
              : null,
          onTap: () => widget.onTap(c.id),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8)),
        ),
      ),
      if (hasChildren && _expanded)
        _ContainerTree(
          tree: widget.node.children,
          onTap: widget.onTap,
          depth: widget.depth + 1,
        ),
    ]);
  }
}

// ─── Hilfswidgets ─────────────────────────────────────────────────────────────

class _SectionHeaderWithAdd extends StatelessWidget {
  final String label;
  final VoidCallback onAdd;
  const _SectionHeaderWithAdd(this.label, {required this.onAdd});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 4, 2),
        child: Row(children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.bold,
                    color: MFColors.textMuted, letterSpacing: 1.2)),
          ),
          InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(99),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.add_rounded,
                  size: 15, color: MFColors.textMuted),
            ),
          ),
        ]),
      );
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;
  const _DrawerItem({
    required this.icon, required this.label,
    required this.onTap, this.color = MFColors.textSecondary,
  });
  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        leading: Icon(icon, size: 18, color: color),
        title: Text(label,
            style: const TextStyle(
                fontSize: 13, color: MFColors.textPrimary)),
        onTap: onTap,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8)),
      );
}

class _LoadingTile extends StatelessWidget {
  const _LoadingTile();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: LinearProgressIndicator(
            color: MFColors.teal,
            backgroundColor: MFColors.border,
            minHeight: 1),
      );
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12, color: MFColors.textMuted,
                fontStyle: FontStyle.italic)),
      );
}

// ── Desktop: Neuer Eintrag inline ─────────────────────────────────────────────

class _DesktopCaptureView extends StatelessWidget {
  final _CaptureArgs args;
  final VoidCallback onClose;

  const _DesktopCaptureView({
    required this.args,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return CaptureScreen(
      initialText: args.initialText,
      sharedFilePaths: args.sharedFilePaths,
      initialContainerId: args.initialContainerId,
      parentEntryId: args.parentEntryId,
      onBack: onClose,
    );
  }
}

// ── Desktop: Task inline anzeigen ────────────────────────────────────────────

class _DesktopTaskView extends StatelessWidget {
  final String taskId;
  final VoidCallback onClose;

  const _DesktopTaskView({required this.taskId, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return TaskDetailScreen(taskId: taskId, onBack: onClose);
  }
}

// ── Desktop: Container-Inhalt inline anzeigen (Explorer-Stil) ─────────────────

class _DesktopContainerView extends StatelessWidget {
  final String containerId;
  final VoidCallback onClose;

  const _DesktopContainerView({
    required this.containerId,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return ContainerDetailScreen(
      containerId: containerId,
      onBack: onClose,
    );
  }
}

// ── Desktop: Eintrag inline anzeigen ──────────────────────────────────────────

class _DesktopEntryView extends StatelessWidget {
  final String entryId;
  final VoidCallback onClose;

  const _DesktopEntryView({
    required this.entryId,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return EntryDetailScreen(
      entryId: entryId,
      onBack: onClose,
    );
  }
}
