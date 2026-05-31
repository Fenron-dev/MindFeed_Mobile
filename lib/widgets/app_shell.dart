import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
import '../core/theme.dart';
import '../data/repositories/container_repository.dart';
import '../features/containers/container_provider.dart';

/// GlobalKey damit FeedScreen (verschachtelter Scaffold) den Drawer öffnen kann.
final appScaffoldKey = GlobalKey<ScaffoldState>();

class AppShell extends StatelessWidget {
  final StatefulNavigationShell shell;
  const AppShell({super.key, required this.shell});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: appScaffoldKey,
      body: shell,
      drawer: const MindFeedDrawer(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: shell.goBranch,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dynamic_feed_outlined),
            selectedIcon: Icon(Icons.dynamic_feed),
            label: 'Feed',
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
                  _SectionHeader('BEREICHE'),
                  areasAsync.when(
                    loading: () => const _LoadingTile(),
                    error: (_, __) => const SizedBox.shrink(),
                    data: (tree) => _ContainerTree(
                        tree: tree, onTap: navigate),
                  ),
                  _SectionHeader('PROJEKTE'),
                  projectsAsync.when(
                    loading: () => const _LoadingTile(),
                    error: (_, __) => const SizedBox.shrink(),
                    data: (tree) => tree.isEmpty
                        ? const _EmptyHint('Noch keine Projekte')
                        : _ContainerTree(tree: tree, onTap: navigate),
                  ),
                  _SectionHeader('SMART HUBS'),
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
          title: Text(c.name,
              style: const TextStyle(
                  fontSize: 13, color: MFColors.textPrimary)),
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

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
        child: Text(label,
            style: const TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold,
                color: MFColors.textMuted, letterSpacing: 1.2)),
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
