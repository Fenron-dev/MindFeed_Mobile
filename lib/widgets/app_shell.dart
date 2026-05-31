import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
import '../core/theme.dart';

class AppShell extends StatelessWidget {
  final StatefulNavigationShell shell;
  const AppShell({super.key, required this.shell});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      drawer: const _MindFeedDrawer(),
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

// ─── Drawer: Container-Baum (Gmail-Labels-Style) ──────────────────────────────
class _MindFeedDrawer extends StatelessWidget {
  const _MindFeedDrawer();

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: MFColors.tealBg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.psychology_outlined,
                        color: MFColors.teal, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'MindFeed',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: MFColors.textPrimary,
                        ),
                  ),
                ],
              ),
            ),
            const Divider(),

            // Haupt-Feed
            _DrawerItem(
              icon: Icons.dynamic_feed_outlined,
              label: 'Alle Einträge',
              onTap: () {
                context.go(AppRoutes.feed);
                Navigator.pop(context);
              },
            ),

            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'PROJEKTE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: MFColors.textMuted,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            // TODO: Container-Liste aus Riverpod laden
            _DrawerItem(
              icon: Icons.folder_outlined,
              label: 'Projekte laden...',
              onTap: () {},
              muted: true,
            ),

            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'BEREICHE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: MFColors.textMuted,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            _DrawerItem(
              icon: Icons.compass_calibration_outlined,
              label: 'Bereiche laden...',
              onTap: () {},
              muted: true,
            ),

            const Spacer(),
            const Divider(),
            _DrawerItem(
              icon: Icons.settings_outlined,
              label: 'Einstellungen',
              onTap: () {
                context.go(AppRoutes.settings);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool muted;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon,
          size: 18,
          color: muted ? MFColors.textMuted : MFColors.textSecondary),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: muted ? MFColors.textMuted : MFColors.textPrimary,
        ),
      ),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
  }
}
