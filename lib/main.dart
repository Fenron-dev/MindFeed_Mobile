import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'core/theme.dart';
import 'core/router.dart';
import 'core/di.dart';
import 'core/vault_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final db = await VaultManager.openDefaultVault();

  runApp(ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MindFeedApp(),
  ));
}

class MindFeedApp extends ConsumerWidget {
  const MindFeedApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'MindFeed',
      theme: MFTheme.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
