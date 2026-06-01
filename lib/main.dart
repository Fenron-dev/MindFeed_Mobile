import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'core/router.dart';
import 'core/di.dart';
import 'core/vault_manager.dart';
import 'data/db/app_database.dart' hide Container;

/// Globaler Callback — wird von BackupService nach einem Restore aufgerufen
/// um die App mit der neuen Datenbank neu zu starten.
void Function()? onRestartApp;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
  };

  await _launchApp();
}

Future<void> _launchApp() async {
  AppDatabase? db;
  String? startupError;

  try {
    db = await VaultManager.openDefaultVault();
  } catch (e, stack) {
    startupError = 'Vault konnte nicht geöffnet werden:\n$e';
    debugPrint('[Startup] FEHLER: $e\n$stack');
  }

  // Restart-Callback registrieren
  onRestartApp = _launchApp;

  runApp(
    db != null
        ? ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: const MindFeedApp(),
          )
        : _StartupErrorApp(message: startupError ?? 'Unbekannter Fehler'),
  );
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

/// Wird angezeigt wenn der Vault-Init fehlschlägt — zeigt den Fehler
/// statt schweigend schwarz zu bleiben.
class _StartupErrorApp extends StatelessWidget {
  final String message;
  const _StartupErrorApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: MFTheme.dark,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: MFColors.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'MindFeed konnte nicht starten',
                  style: TextStyle(
                    color: MFColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: MFColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: MFColors.border),
                  ),
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: MFColors.textSecondary,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.left,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
