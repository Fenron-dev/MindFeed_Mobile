import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
// receive_sharing_intent ist nur auf iOS/Android verfügbar
import 'package:receive_sharing_intent/receive_sharing_intent.dart'
    if (dart.library.html) 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'core/constants.dart';
import 'core/theme.dart';
import 'core/router.dart';
import 'core/di.dart';
import 'core/vault_manager.dart';
import 'data/db/app_database.dart' hide Container;
import 'services/backup_service.dart';
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

  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1200, 800),
        minimumSize: Size(900, 600),
        center: true,
        title: 'MindFeed',
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

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
  bool _needsSetup = false; // Erster Start → Vault-Setup anzeigen

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await NotificationService.init();
    await AppSettings.init();
    try {
      final saved = VaultManager.getSavedVaultPath();

      if (saved != null && VaultManager.isVault(saved)) {
        // Gespeicherten Custom-Vault öffnen
        final db = await VaultManager.openVaultFromPath(saved);
        if (mounted) setState(() { _db = db; _loading = false; });
      } else {
        // Prüfen ob Default-Vault bereits existiert (→ kein erster Start)
        final dir = await getApplicationDocumentsDirectory();
        final defaultDb = p.join(dir.path, 'MindFeed', 'default', 'mindfeed.db');
        if (File(defaultDb).existsSync()) {
          final db = await VaultManager.openDefaultVault();
          if (mounted) setState(() { _db = db; _loading = false; });
        } else {
          // Erster Start: Setup-Screen anzeigen
          if (mounted) setState(() { _loading = false; _needsSetup = true; });
        }
      }
    } catch (e, stack) {
      debugPrint('[Boot] $e\n$stack');
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
    onRestartApp = _restart;
  }

  Future<void> _finishSetup(String vaultPath) async {
    try {
      final db = await VaultManager.openVaultFromPath(vaultPath);
      await VaultManager.saveVaultPath(vaultPath);
      if (mounted) {
        setState(() { _db = db; _needsSetup = false; });
      }
    } catch (e) {
      debugPrint('[Setup] $e');
    }
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
          body: Center(child: CircularProgressIndicator(color: MFColors.teal)),
        ),
      );
    }
    if (_error != null) return _StartupErrorApp(message: _error!);
    if (_needsSetup) {
      return MaterialApp(
        theme: MFTheme.dark,
        debugShowCheckedModeBanner: false,
        home: _VaultSetupScreen(onSetupDone: _finishSetup),
      );
    }
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
    // receive_sharing_intent ist nur auf iOS/Android verfügbar
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      ReceiveSharingIntent.instance.getInitialMedia().then(_handleSharedMedia);
      ReceiveSharingIntent.instance.getMediaStream().listen(_handleSharedMedia);
    }
  }

  void _handleSharedMedia(List<SharedMediaFile> media) {
    if (media.isEmpty) return;

    // Text/URL → Capture-Screen mit vorausgefülltem Text
    final text = media
        .where((m) => m.type == SharedMediaType.text || m.type == SharedMediaType.url)
        .map((m) => m.path)
        .firstOrNull;
    if (text != null && text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(routerProvider).push(
            '${AppRoutes.capture}?sharedText=${Uri.encodeComponent(text)}');
      });
      return;
    }

    // Dateien (Bilder, Videos, Audio, Sonstige) → Capture-Screen
    final files = media.where((m) =>
        m.type == SharedMediaType.image ||
        m.type == SharedMediaType.video ||
        m.type == SharedMediaType.file).toList();
    if (files.isNotEmpty) {
      // Dateipfade als komma-getrennte Liste übergeben
      final paths = files.map((f) => Uri.encodeComponent(f.path)).join(',');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(routerProvider).push(
            '${AppRoutes.capture}?sharedFiles=${Uri.encodeComponent(paths)}');
      });
    }
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

// ─── Erster Start: Vault Setup ────────────────────────────────────────────────

class _VaultSetupScreen extends StatefulWidget {
  final Future<void> Function(String vaultPath) onSetupDone;
  const _VaultSetupScreen({required this.onSetupDone});

  @override
  State<_VaultSetupScreen> createState() => _VaultSetupScreenState();
}

class _VaultSetupScreenState extends State<_VaultSetupScreen> {
  final _nameCtrl = TextEditingController(text: 'MindFeed');
  String? _customLocation; // null = Standard (App-Dokumente)
  bool _creating = false;
  bool _importing = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLocation() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Vault-Speicherort wählen',
    );
    if (path != null && mounted) setState(() => _customLocation = path);
  }

  Future<String> _resolveVaultPath() async {
    final name = _nameCtrl.text.trim().isEmpty ? 'MindFeed' : _nameCtrl.text.trim();
    if (_customLocation != null) {
      return p.join(_customLocation!, name);
    }
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, name, 'default');
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final path = await _resolveVaultPath();
      await widget.onSetupDone(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Fehler: $e'),
          backgroundColor: Colors.red.shade900,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _importBackup() async {
    setState(() => _importing = true);
    AppDatabase? tempDb;
    try {
      // 1. Vault-Pfad bestimmen und leeren Vault anlegen
      final vaultPath = await _resolveVaultPath();
      await Directory(vaultPath).create(recursive: true);

      // 2. Backup importieren (Picker öffnen, kein Pre-Dialog)
      tempDb = AppDatabase(p.join(vaultPath, 'mindfeed.db'));
      final result = await BackupService.importFromPicker(tempDb);
      await tempDb.close();
      tempDb = null;

      if (!mounted) return;

      if (result.isSuccess) {
        // 3. Vault mit importierten Daten öffnen
        await widget.onSetupDone(vaultPath);
      } else if (!result.cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Import-Fehler: ${result.error}'),
          backgroundColor: Colors.red.shade900,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Fehler: $e'),
          backgroundColor: Colors.red.shade900,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      try { await tempDb?.close(); } catch (_) {}
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MFColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              // Logo / Titel
              Row(children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: MFColors.tealBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.psychology_outlined,
                      color: MFColors.teal, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text('MindFeed',
                          style: TextStyle(fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: MFColors.textPrimary)),
                      Text('Willkommen — richte deinen Vault ein',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: MFColors.textMuted)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 40),

              // Vault-Name
              const Text('Vault-Name',
                  style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: MFColors.textMuted,
                      letterSpacing: 1.1)),
              const SizedBox(height: 6),
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(fontSize: 15, color: MFColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'MindFeed',
                  hintStyle: const TextStyle(color: MFColors.textMuted),
                  filled: true, fillColor: MFColors.surface,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: MFColors.border)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: MFColors.border)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: MFColors.teal)),
                ),
              ),
              const SizedBox(height: 20),

              // Speicherort
              const Text('Speicherort',
                  style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: MFColors.textMuted,
                      letterSpacing: 1.1)),
              const SizedBox(height: 6),
              InkWell(
                onTap: _pickLocation,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: MFColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: MFColors.border),
                  ),
                  child: Row(children: [
                    const Icon(Icons.folder_outlined,
                        color: MFColors.teal, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _customLocation ?? 'App-Dokumente (empfohlen)',
                        style: const TextStyle(
                            fontSize: 13, color: MFColors.textSecondary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.chevron_right,
                        color: MFColors.textMuted, size: 16),
                  ]),
                ),
              ),
              if (_customLocation != null) ...[
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () => setState(() => _customLocation = null),
                  child: const Text('Zurücksetzen',
                      style: TextStyle(fontSize: 11, color: MFColors.teal)),
                ),
              ],

              const Spacer(),

              // Aktionen
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_creating || _importing) ? null : _create,
                  icon: _creating
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: MFColors.bg))
                      : const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Neuen Vault erstellen',
                      style: TextStyle(fontSize: 14)),
                  style: FilledButton.styleFrom(
                    backgroundColor: MFColors.teal,
                    foregroundColor: MFColors.bg,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_creating || _importing) ? null : _importBackup,
                  icon: _importing
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: MFColors.teal))
                      : const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('Aus Backup wiederherstellen',
                      style: TextStyle(fontSize: 14)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MFColors.teal,
                    side: const BorderSide(color: MFColors.teal),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
