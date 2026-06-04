import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'constants.dart';
import '../features/feed/feed_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/entry_detail/entry_detail_screen.dart';
import '../features/capture/capture_screen.dart';
import '../features/containers/container_detail_screen.dart';
import '../features/containers/container_form_screen.dart';
import '../features/vault/vault_switcher_screen.dart';
import '../widgets/app_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.feed,
    routes: [
      // Vollbild-Screens außerhalb der Shell
      GoRoute(
        path: AppRoutes.capture,
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          child: CaptureScreen(
            initialText: state.uri.queryParameters['sharedText'] != null
                ? Uri.decodeComponent(
                    state.uri.queryParameters['sharedText']!)
                : null,
            sharedFilePaths: state.uri.queryParameters['sharedFiles'] != null
                ? Uri.decodeComponent(
                        state.uri.queryParameters['sharedFiles']!)
                    .split(',')
                    .map(Uri.decodeComponent)
                    .where((s) => s.isNotEmpty)
                    .toList()
                : null,
            initialContainerId: state.uri.queryParameters['containerId'],
            parentEntryId: state.uri.queryParameters['parentEntryId'],
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Slide von rechts rein (Gmail-Compose Style)
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1.0, 0.0),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              )),
              child: child,
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.entryDetail,
        builder: (context, state) => EntryDetailScreen(
          entryId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: AppRoutes.containerDetail,
        builder: (context, state) => ContainerDetailScreen(
          containerId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: AppRoutes.containerNew,
        builder: (context, state) {
          final kind = state.uri.queryParameters['kind'] ?? 'project';
          final parentId = state.uri.queryParameters['parentId'];
          return ContainerFormScreen(
              initialKind: kind, initialParentId: parentId);
        },
      ),
      GoRoute(
        path: AppRoutes.containerEdit,
        builder: (context, state) => ContainerFormScreen(
          editId: state.pathParameters['id'],
        ),
      ),
      GoRoute(
        path: AppRoutes.vaultSwitcher,
        builder: (context, state) => const VaultSwitcherScreen(),
      ),

      // Haupt-Shell mit Bottom Nav
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.feed,
                builder: (context, state) => const FeedScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.search,
                builder: (context, state) => const SearchScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
