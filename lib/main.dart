import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'core/constants.dart';
import 'core/theme.dart';
import 'core/router.dart';
import 'core/di.dart';
import 'core/vault_manager.dart';
import 'data/db/app_database.dart' hide Container;
import 'services/notification_service.dart';
import 'services/app_settings.dart';

/// Globaler Callback — nach einem Restore aufgerufen, um die App neu zu starten.
Future<void> Function()? onRestartApp;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
  };
  runApp(const _AppRoot());
}

// ─── App-Root mit Restart-Fähigkeit ──────────────────────────────────────────

class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  Key _scopeKey = UniqueKey();
  AppDatabase? _db;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await NotificationService.init();
    await AppSettings.init();
    try {
      // Custom-Vault-Pfad hat Vorrang (wie OracleVault-Ansatz)
      final saved = VaultManager.getSavedVaultPath();
      final db = (saved != null && VaultManager.isVault(saved))
          ? await VaultManager.openVaultFromPath(saved)
          : await VaultManager.openDefaultVault();
      if (mounted) setState(() { _db = db; _loading = false; });
    } catch (e, stack) {
      debugPrint('[Boot] $e\n$stack');
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
    // Restart-Callback registrieren: öffnet neue DB und tauscht ProviderScope
    onRestartApp = _restart;
  }

  Future<void> _restart() async {
    try {
      final saved = VaultManager.getSavedVaultPath();
      final newDb = (saved != null && VaultManager.isVault(saved))
          ? await VaultManager.openVaultFromPath(saved)
          : await VaultManager.openDefaultVault();
      if (mounted) {
        setState(() {
          _db = newDb;
          _scopeKey = UniqueKey();
        });
      }
    } catch (e, stack) {
      debugPrint('[Restart] $e\n$stack');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return MaterialApp(
        theme: MFTheme.dark,
        debugShowCheckedModeBanner: false,
        home: const Scaffold(
          backgroundColor: MFColors.bg,
          body: Center(
            child: CircularProgressIndicator(color: MFColors.teal),
          ),
        ),
      );
    }
    if (_error != null) return _StartupErrorApp(message: _error!);
    return KeyedSubtree(
      key: _scopeKey,
      child: ProviderScope(
        overrides: [databaseProvider.overrideWithValue(_db!)],
        child: const MindFeedApp(),
      ),
    );
  }
}

// ─── Haupt-App ────────────────────────────────────────────────────────────────

class MindFeedApp extends ConsumerStatefulWidget {
  const MindFeedApp({super.key});

  @override
  ConsumerState<MindFeedApp> createState() => _MindFeedAppState();
}

class _MindFeedAppState extends ConsumerState<MindFeedApp> {
  @override
  void initState() {
    super.initState();
    _initShareIntent();
  }

  void _initShareIntent() {
    ReceiveSharingIntent.instance.getInitialMedia().then((media) {
      final text = media
          .where((m) => m.type == SharedMediaType.text || m.type == SharedMediaType.url)
          .map((m) => m.path)
          .firstOrNull;
      if (text != null && text.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(routerProvider).push(
              '${AppRoutes.capture}?sharedText=${Uri.encodeComponent(text)}');
        });
      }
    });

    ReceiveSharingIntent.instance.getMediaStream().listen((media) {
      final text = media
          .where((m) => m.type == SharedMediaType.text || m.type == SharedMediaType.url)
          .map((m) => m.path)
          .firstOrNull;
      if (text != null && text.isNotEmpty) {
        ref.read(routerProvider).push(
            '${AppRoutes.capture}?sharedText=${Uri.encodeComponent(text)}');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'MindFeed',
      theme: MFTheme.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}

// ─── Fehler-Anzeige beim Start ────────────────────────────────────────────────

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
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
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
