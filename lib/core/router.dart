import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'constants.dart';
import '../features/feed/feed_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/entry_detail/entry_detail_screen.dart';
import '../features/capture/capture_screen.dart';
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
          child: const CaptureScreen(),
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
