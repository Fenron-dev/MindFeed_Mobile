import 'dart:io';
import '../../core/folder_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/secure_storage.dart';
import 'package:intl/intl.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../core/vault_manager.dart';
import '../../domain/prop_type.dart';
import '../../main.dart' show onRestartApp;
import '../../services/app_settings.dart';
import '../../services/ai/structure_template.dart';
import '../../services/enrichment/api_field_catalog.dart';
import '../../services/enrichment/api_field_prefs.dart';
import '../../services/enrichment/api_keys.dart';
import '../../services/enrichment/api_source.dart';
import '../../services/backup_service.dart';
import '../../services/web_search/web_search.dart';
import '../../services/url_metadata_service.dart';
import '../settings/sync_settings_screen.dart';
import 'ai_profiles_screen.dart';
import 'settings_backup_tiles.dart';
import '../../core/constants.dart';
import '../../sync/sync_provider.dart';
import 'package:go_router/go_router.dart';

const _keySearxngUrl = 'searxng_base_url';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _backupLoading = false;
  bool _importLoading = false;
  List<BackupResult> _localBackups = [];
  bool _backupsLoaded = false;
  String? _activeVaultPath; // null = Default-Vault

  // API-Feld-Präferenzen (katalog-getrieben)
  ApiFieldPrefs _apiPrefs = const ApiFieldPrefs({});

  // Quellen-API-Keys (YouTube Data API v3)
  final _youtubeKeyCtrl = TextEditingController();
  String _ytTestState = 'idle'; // idle | loading | ok | error
  String _ytTestMsg = '';

  // Web-Recherche (Provider-Auswahl: SearXNG / Brave …)
  WebSearchProviderKind _webProvider = WebSearchProviderKind.searxng;
  final _searxngUrlCtrl = TextEditingController();
  final _braveKeyCtrl = TextEditingController();
  String _searxTestState = 'idle'; // idle | loading | ok | error
  String _searxTestError = '';

  /// Controller des Konfig-Felds des aktuell gewählten Providers.
  TextEditingController get _webConfigCtrl =>
      _webProvider == WebSearchProviderKind.brave
          ? _braveKeyCtrl
          : _searxngUrlCtrl;

  @override
  void initState() {
    super.initState();
    _loadBackups();
    _loadAiSettings();
    _activeVaultPath = VaultManager.getSavedVaultPath();
    _apiPrefs = AppSettings.loadApiFieldPrefs();
  }

  @override
  void dispose() {
    _searxngUrlCtrl.dispose();
    _braveKeyCtrl.dispose();
    _youtubeKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAiSettings() async {
    final searx = await secureRead(_keySearxngUrl) ?? '';
    final brave = await secureRead(WebSearchProviderKind.brave.secureKey) ?? '';
    final youtubeKey = await secureRead(ApiKeyStore.youtube) ?? '';
    if (mounted) {
      setState(() {
        _webProvider =
            WebSearchProviderKind.fromId(AppSettings.getWebSearchProvider());
        _searxngUrlCtrl.text = searx;
        _braveKeyCtrl.text = brave;
        _youtubeKeyCtrl.text = youtubeKey;
      });
    }
  }

  Future<void> _saveYoutubeKey() async {
    await secureWrite(ApiKeyStore.youtube, _youtubeKeyCtrl.text.trim());
    if (mounted) _showSnack('YouTube-API-Key gespeichert', success: true);
  }

  Future<void> _testYoutubeKey() async {
    await secureWrite(ApiKeyStore.youtube, _youtubeKeyCtrl.text.trim());
    setState(() {
      _ytTestState = 'loading';
      _ytTestMsg = '';
    });
    final err =
        await UrlMetadataService.testYoutubeKey(_youtubeKeyCtrl.text.trim());
    if (!mounted) return;
    setState(() {
      _ytTestState = err == null ? 'ok' : 'error';
      _ytTestMsg = err ?? '';
    });
  }

  Future<void> _saveAiSettings() async {
    await AppSettings.saveWebSearchProvider(_webProvider.id);
    // Beide Konfigurationen erhalten, damit ein Provider-Wechsel den jeweils
    // anderen Wert nicht verliert.
    await secureWrite(_keySearxngUrl, _searxngUrlCtrl.text.trim());
    await secureWrite(
        WebSearchProviderKind.brave.secureKey, _braveKeyCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Gespeichert.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _testWebSearch() async {
    final provider =
        buildWebSearchProvider(_webProvider, _webConfigCtrl.text);
    if (provider == null) {
      setState(() {
        _searxTestState = 'error';
        _searxTestError = '${_webProvider.configLabel} fehlt';
      });
      return;
    }
    setState(() { _searxTestState = 'loading'; _searxTestError = ''; });
    final err = await provider.testConnection();
    if (!mounted) return;
    setState(() {
      _searxTestState = err == null ? 'ok' : 'error';
      _searxTestError = err == null
          ? ''
          : (err.length > 150 ? '${err.substring(0, 150)}…' : err);
    });
  }

  Future<void> _loadBackups() async {
    final list = await BackupService.listLocalBackups();
    if (mounted) {
      setState(() {
        _localBackups = list;
        _backupsLoaded = true;
      });
    }
  }

  // ─── ZIP-Backup erstellen & teilen ────────────────────────────────────────

  Future<void> _createZipBackup() async {
    setState(() => _backupLoading = true);
    try {
      final result =
          await BackupService.createZipBackup(ref.read(databaseProvider));
      await BackupService.shareBackup(result);
      await _loadBackups();
      if (mounted) _showSnack('Backup erstellt: ${result.filename}', success: true);
    } catch (e) {
      if (mounted) _showSnack('Backup-Fehler: $e', success: false);
    } finally {
      if (mounted) setState(() => _backupLoading = false);
    }
  }

  // ─── JSON exportieren & teilen ────────────────────────────────────────────

  Future<void> _shareJson() async {
    setState(() => _backupLoading = true);
    try {
      await BackupService.shareJson(ref.read(databaseProvider));
    } catch (e) {
      if (mounted) _showSnack('Export-Fehler: $e', success: false);
    } finally {
      if (mounted) setState(() => _backupLoading = false);
    }
  }

  // ─── Import (JSON oder ZIP) — kein Neustart! ──────────────────────────────

  Future<void> _importFromFile() async {
    // Kein Pre-Dialog: FilePicker direkt öffnen.
    // Ein Dialog VOR dem Picker kann auf iOS einen schwarzen Bildschirm
    // verursachen (UIViewController-Konflikt beim Dismiss→Present).
    setState(() => _importLoading = true);
    try {
      final result =
          await BackupService.importFromPicker(ref.read(databaseProvider));
      if (!mounted) return;

      if (result.isSuccess) {
        // Bestätigungsdialog NACH erfolgreichem Import zeigen
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: MFColors.surface,
            title: const Text('Import erfolgreich',
                style: TextStyle(color: MFColors.textPrimary)),
            content: Text(
                '${result.entryCount} Einträge wurden wiederhergestellt.\n'
                'App wird jetzt neu geladen.',
                style: const TextStyle(
                    color: MFColors.textSecondary, fontSize: 13)),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                    backgroundColor: MFColors.teal,
                    foregroundColor: MFColors.bg),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (confirmed == true) await onRestartApp?.call();
      } else if (!result.cancelled) {
        _showSnack('Fehler: ${result.error}', success: false);
      }
    } catch (e) {
      if (mounted) _showSnack('Fehler: $e', success: false);
    } finally {
      if (mounted) setState(() => _importLoading = false);
    }
  }

  // ─── Lokales Backup wiederherstellen ──────────────────────────────────────

  Future<void> _doRestore(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Backup wiederherstellen?',
            style: TextStyle(color: MFColors.textPrimary)),
        content: const Text(
            'Alle aktuellen Daten werden durch dieses Backup ersetzt.',
            style: TextStyle(color: MFColors.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen',
                  style: TextStyle(color: MFColors.textMuted))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Wiederherstellen',
                  style: TextStyle(color: Colors.orange))),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _importLoading = true);
    try {
      final db = ref.read(databaseProvider);
      final ImportResult result;
      if (path.endsWith('.zip')) {
        result = await BackupService.restoreFromZip(path, db);
      } else {
        final raw = await File(path).readAsString();
        result = await BackupService.importFromJsonString(db, raw);
      }
      if (!mounted) return;
      if (result.isSuccess) {
        _showSnack('✓ ${result.entryCount} Einträge wiederhergestellt',
            success: true);
        await onRestartApp?.call();
      } else if (!result.cancelled) {
        _showSnack('Fehler: ${result.error}', success: false);
      }
    } catch (e) {
      if (mounted) _showSnack('Fehler: $e', success: false);
    } finally {
      if (mounted) setState(() => _importLoading = false);
    }
  }

  // ─── Neuen Vault erstellen ─────────────────────────────────────────────────

  Future<void> _createNewVault() async {
    final nameCtrl = TextEditingController(text: 'MindFeed');
    final dirCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: MFColors.surface,
          title: const Text('Neuen Vault erstellen',
              style: TextStyle(color: MFColors.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(color: MFColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Vault-Name',
                  labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
                  border: OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.border)),
                  focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.teal)),
                ),
              ),
              const SizedBox(height: 12),
              // Ordner-Pfad — Textfeld + optionaler Picker
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: dirCtrl,
                    style: const TextStyle(
                        color: MFColors.textPrimary, fontSize: 12,
                        fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: 'Speicherort (leer = Standard)',
                      labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 11),
                      hintText: '/Users/…',
                      hintStyle: TextStyle(color: MFColors.textMuted, fontSize: 11),
                      isDense: true,
                      border: OutlineInputBorder(),
                      enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: MFColors.border)),
                      focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: MFColors.teal)),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.folder_outlined,
                      color: MFColors.teal, size: 20),
                  tooltip: 'Ordner wählen',
                  onPressed: () async {
                    try {
                      final path = await pickFolder(prompt: 'Speicherort wählen');
                      if (path != null) setS(() => dirCtrl.text = path);
                    } catch (_) {}
                  },
                ),
              ]),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen',
                  style: TextStyle(color: MFColors.textMuted)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: MFColors.teal, foregroundColor: MFColors.bg),
              child: const Text('Erstellen'),
            ),
          ],
        ),
      ),
    );

    final vaultName = nameCtrl.text.trim().isEmpty ? 'MindFeed' : nameCtrl.text.trim();
    final chosenDir = dirCtrl.text.trim().isEmpty ? null : dirCtrl.text.trim();
    nameCtrl.dispose();
    dirCtrl.dispose();
    if (confirmed != true || !mounted) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = chosenDir ?? p.join(dir.path, 'MindFeed');
      final vaultPath = p.join(base, vaultName);

      // createVault legt Ordner an, erstellt mindfeed.db und seeded Basis-Container
      await VaultManager.createVault(vaultPath);
      await VaultManager.saveVaultPath(vaultPath);

      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: MFColors.surface,
          title: const Text('Vault erstellt',
              style: TextStyle(color: MFColors.textPrimary)),
          content: Text(
            'Vault "$vaultName" wurde angelegt.\nDie App wird jetzt neu geladen.',
            style: const TextStyle(color: MFColors.textSecondary, fontSize: 13),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(
                  backgroundColor: MFColors.teal, foregroundColor: MFColors.bg),
              child: const Text('OK'),
            ),
          ],
        ),
      );

      await onRestartApp?.call();
    } catch (e) {
      if (mounted) _showSnack('Fehler: $e', success: false);
    }
  }

  // ─── Vault-Ordner wählen (Pfad-Eingabe + optionaler Picker) ───────────────

  Future<void> _pickVaultFolder() async {
    final pathCtrl = TextEditingController(
        text: _activeVaultPath ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: MFColors.surface,
          title: const Text('Vault öffnen',
              style: TextStyle(color: MFColors.textPrimary)),
          content: Row(children: [
            Expanded(
              child: TextField(
                controller: pathCtrl,
                autofocus: true,
                style: const TextStyle(
                    color: MFColors.textPrimary, fontSize: 12,
                    fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Pfad zum Vault-Ordner',
                  labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 11),
                  hintText: '/Users/…/MindFeed',
                  hintStyle: TextStyle(color: MFColors.textMuted, fontSize: 11),
                  isDense: true,
                  border: OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.border)),
                  focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.teal)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.folder_outlined,
                  color: MFColors.teal, size: 20),
              tooltip: 'Ordner wählen',
              onPressed: () async {
                try {
                  final path = await pickFolder(prompt: 'MindFeed-Vault-Ordner wählen');
                  if (path != null) setS(() => pathCtrl.text = path);
                } catch (_) {}
              },
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen',
                  style: TextStyle(color: MFColors.textMuted)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: MFColors.teal, foregroundColor: MFColors.bg),
              child: const Text('Öffnen'),
            ),
          ],
        ),
      ),
    );

    final path = pathCtrl.text.trim();
    pathCtrl.dispose();
    if (confirmed != true || path.isEmpty || !mounted) return;

    if (!VaultManager.isVault(path)) {
      _showSnack(
        'Kein gültiger MindFeed-Vault (mindfeed.db nicht gefunden).',
        success: false,
      );
      return;
    }

    await VaultManager.saveVaultPath(path);
    setState(() => _activeVaultPath = path);
    await onRestartApp?.call();
  }

  Future<void> _resetToDefaultVault() async {
    await VaultManager.saveVaultPath(null);
    setState(() => _activeVaultPath = null);
    await onRestartApp?.call();
    if (mounted) _showSnack('Standard-Vault wiederhergestellt', success: true);
  }

  void _showSnack(String msg, {required bool success}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          success ? const Color(0xFF14B8A6) : Colors.red.shade900,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ─── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        title: const Text('Einstellungen',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: MFColors.textPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // ─── Vault ────────────────────────────────────────────────────
          _SectionHeader('VAULT'),
          const SizedBox(height: 8),

          // Aktiver Vault-Pfad
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MFColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.folder_outlined, size: 16, color: MFColors.teal),
                  const SizedBox(width: 8),
                  const Text('Aktiver Vault',
                      style: TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: MFColors.textPrimary)),
                ]),
                const SizedBox(height: 6),
                Text(
                  _activeVaultPath ?? 'Standard (App-Dokumente)',
                  style: const TextStyle(
                      fontSize: 11,
                      color: MFColors.textMuted,
                      fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          _SettingsTile(
            icon: Icons.create_new_folder_outlined,
            iconColor: MFColors.teal,
            title: 'Neuen Vault erstellen',
            subtitle: 'Leeren Vault an einem neuen Speicherort anlegen',
            onTap: _createNewVault,
          ),
          const SizedBox(height: 8),
          _SettingsTile(
            icon: Icons.folder_open_outlined,
            iconColor: MFColors.teal,
            title: 'Vorhandenen Vault öffnen',
            subtitle: 'Bestehenden MindFeed-Vault-Ordner wählen',
            onTap: _pickVaultFolder,
          ),

          if (_activeVaultPath != null) ...[
            const SizedBox(height: 8),
            _SettingsTile(
              icon: Icons.home_outlined,
              iconColor: MFColors.textMuted,
              title: 'Standard-Vault verwenden',
              subtitle: 'Zurück zum App-eigenen Vault-Ordner',
              onTap: _resetToDefaultVault,
            ),
          ],

          const SizedBox(height: 24),
          // ─── Sync ──────────────────────────────────────────────────────
          _SectionHeader('SYNC & GERÄTE'),
          const SizedBox(height: 8),
          _SettingsTile(
            icon: Icons.sync,
            iconColor: MFColors.teal,
            title: 'Sync & Geräte',
            subtitle: 'P2P-Sync mit anderen Geräten konfigurieren',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const SyncSettingsScreen(),
              ),
            ),
          ),

          const SizedBox(height: 24),
          // ─── Datensicherung ────────────────────────────────────────────
          _SectionHeader('DATENSICHERUNG'),
          const SizedBox(height: 8),

          const SettingsBackupTiles(),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.cloud_upload_outlined,
            iconColor: MFColors.teal,
            title: 'ZIP-Backup erstellen',
            subtitle: 'Alle Einträge + Anhänge als ZIP exportieren',
            trailing: _backupLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: MFColors.teal))
                : const Icon(Icons.chevron_right,
                    color: MFColors.textMuted, size: 18),
            onTap: _backupLoading ? null : _createZipBackup,
          ),

          const SizedBox(height: 8),

          _SettingsTile(
            icon: Icons.data_object_outlined,
            iconColor: const Color(0xFF6366F1),
            title: 'JSON exportieren',
            subtitle: 'Nur Textdaten — schnell, universell, klein',
            trailing: _backupLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF6366F1)))
                : const Icon(Icons.chevron_right,
                    color: MFColors.textMuted, size: 18),
            onTap: _backupLoading ? null : _shareJson,
          ),

          const SizedBox(height: 8),

          _SettingsTile(
            icon: Icons.cloud_download_outlined,
            iconColor: const Color(0xFFF59E0B),
            title: 'Backup importieren',
            subtitle: 'JSON oder ZIP — kein App-Neustart nötig',
            trailing: _importLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFFF59E0B)))
                : const Icon(Icons.chevron_right,
                    color: MFColors.textMuted, size: 18),
            onTap: _importLoading ? null : _importFromFile,
          ),

          const SizedBox(height: 16),
          _AutoBackupSection(),

          // Lokale Backups
          if (_backupsLoaded && _localBackups.isNotEmpty) ...[
            const SizedBox(height: 24),
            _SectionHeader('GESPEICHERTE BACKUPS'),
            const SizedBox(height: 8),
            ..._localBackups.map((b) => _BackupTile(
                  backup: b,
                  onShare: () => BackupService.shareBackup(b),
                  onRestore: () => _doRestore(b.path),
                  onDelete: () async {
                    final del = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        backgroundColor: MFColors.surface,
                        title: const Text('Backup löschen?',
                            style: TextStyle(
                                color: MFColors.textPrimary)),
                        content: Text(b.filename,
                            style: const TextStyle(
                                color: MFColors.textSecondary,
                                fontSize: 12,
                                fontFamily: 'monospace')),
                        actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(context, false),
                              child: const Text('Abbrechen',
                                  style: TextStyle(
                                      color: MFColors.textMuted))),
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(context, true),
                              child: const Text('Löschen',
                                  style: TextStyle(
                                      color: Colors.redAccent))),
                        ],
                      ),
                    );
                    if (del == true) {
                      await BackupService.deleteBackup(b.path);
                      await _loadBackups();
                    }
                  },
                )),
          ],

          if (_backupsLoaded && _localBackups.isEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: MFColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: MFColors.border),
              ),
              child: const Row(children: [
                Icon(Icons.folder_open_outlined,
                    size: 18, color: MFColors.textMuted),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Noch keine lokalen Backups vorhanden.',
                      style: TextStyle(
                          fontSize: 13, color: MFColors.textMuted)),
                ),
              ]),
            ),
          ],

          // ─── AI ───────────────────────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('KI-PROFILE & MODELLE'),
          const SizedBox(height: 8),
          _SettingsTile(
            icon: Icons.smart_toy_outlined,
            iconColor: const Color(0xFF8B5CF6),
            title: 'KI-Profile & Modelle',
            subtitle: 'Anbieter, Fallback-Ketten je Vorgang, Vision, Test',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const AiProfilesScreen())),
          ),

          // ─── Web-Recherche (Provider-Auswahl) ──────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('WEB-RECHERCHE'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MFColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: MFColors.teal.withAlpha(25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.travel_explore_outlined,
                        size: 18, color: MFColors.teal),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Recherche-Provider',
                        style: TextStyle(fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: MFColors.textPrimary)),
                  ),
                ]),
                const SizedBox(height: 14),
                DropdownButtonFormField<WebSearchProviderKind>(
                  initialValue: _webProvider,
                  isExpanded: true,
                  dropdownColor: MFColors.surface,
                  style: const TextStyle(fontSize: 13,
                      color: MFColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Anbieter',
                    labelStyle: const TextStyle(color: MFColors.textMuted, fontSize: 12),
                    filled: true, fillColor: MFColors.bg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.teal)),
                  ),
                  items: [
                    for (final k in WebSearchProviderKind.values)
                      DropdownMenuItem(value: k, child: Text(k.label)),
                  ],
                  onChanged: (k) {
                    if (k == null) return;
                    setState(() {
                      _webProvider = k;
                      _searxTestState = 'idle';
                      _searxTestError = '';
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  key: ValueKey(_webProvider.id),
                  controller: _webConfigCtrl,
                  obscureText: _webProvider.isSecret,
                  style: const TextStyle(fontSize: 13,
                      color: MFColors.textPrimary, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: _webProvider.configLabel,
                    labelStyle: const TextStyle(color: MFColors.textMuted, fontSize: 12),
                    hintText: _webProvider.configHint,
                    hintStyle: const TextStyle(color: MFColors.textMuted, fontSize: 12),
                    filled: true, fillColor: MFColors.bg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.teal)),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _searxTestState == 'loading' ? null : _testWebSearch,
                      icon: _searxTestState == 'loading'
                          ? const SizedBox(width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 1.5))
                          : Icon(
                              _searxTestState == 'ok'
                                  ? Icons.check_circle_outline
                                  : _searxTestState == 'error'
                                      ? Icons.error_outline
                                      : Icons.wifi_tethering,
                              size: 15),
                      label: Text(
                        _searxTestState == 'loading'
                            ? 'Teste…'
                            : _searxTestState == 'ok'
                                ? 'Verbunden ✓'
                                : _searxTestState == 'error'
                                    ? 'Fehlgeschlagen'
                                    : 'Verbindung testen',
                        style: const TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _searxTestState == 'ok'
                            ? MFColors.teal
                            : _searxTestState == 'error'
                                ? Colors.redAccent
                                : MFColors.textSecondary,
                        side: BorderSide(
                          color: _searxTestState == 'ok'
                              ? MFColors.teal
                              : _searxTestState == 'error'
                                  ? Colors.redAccent
                                  : MFColors.border),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saveAiSettings,
                      icon: const Icon(Icons.save_outlined, size: 15),
                      label: const Text('Speichern',
                          style: TextStyle(fontSize: 12)),
                      style: FilledButton.styleFrom(
                        backgroundColor: MFColors.teal,
                        foregroundColor: MFColors.bg,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ]),
                if (_searxTestState == 'error' && _searxTestError.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(_searxTestError,
                      style: const TextStyle(fontSize: 10, color: Colors.redAccent)),
                ],
                const SizedBox(height: 6),
                Text(
                  _webProvider == WebSearchProviderKind.brave
                      ? 'Brave Search API für Web-Recherche bei der KI-Anreicherung. '
                          'API-Key unter api.search.brave.com anlegen. Der Key '
                          'bleibt lokal und wird NICHT mit anderen Geräten gesynct.'
                      : 'Selbst gehostete SearXNG-Instanz für Web-Recherche bei der '
                          'KI-Anreicherung. JSON-Format muss aktiv sein '
                          '(settings.yml: search.formats: [html, json]). HTTP-Adressen '
                          'im LAN sind nur im Heimnetz erreichbar.',
                  style: const TextStyle(fontSize: 10, color: MFColors.textMuted),
                ),
              ],
            ),
          ),

          // ─── Tag-Stil ──────────────────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('TAG-DARSTELLUNG'),
          const SizedBox(height: 8),
          _TagStyleSection(),

          // ─── Aufgaben ──────────────────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('AUFGABEN'),
          const SizedBox(height: 8),
          _ShowTasksInNotesToggle(),

          // ─── Templates ─────────────────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('PROPERTY-TEMPLATES'),
          const SizedBox(height: 8),
          _TemplatesSection(),

          // ─── KI-Struktur-Vorlagen (#38) ───────────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('KI-STRUKTUR-VORLAGEN'),
          const SizedBox(height: 8),
          _StructureTemplatesSection(),

          // ─── Info-APIs ────────────────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('INFO-APIS'),
          const SizedBox(height: 8),
          // YouTube Data API-Key (optional). Ohne Key nutzt MindFeed den
          // oEmbed-Pfad; mit Key kommen Aufrufe, Likes, Tags etc. dazu.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MFColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: const [
                  Icon(Icons.smart_display_outlined,
                      size: 16, color: Color(0xFFFF0000)),
                  SizedBox(width: 8),
                  Text('YouTube Data API',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600,
                          color: MFColors.textPrimary)),
                ]),
                const SizedBox(height: 4),
                const Text(
                  'Optionaler Key (Google Cloud → YouTube Data API v3). '
                  'Ohne Key: oEmbed-Fallback.',
                  style: TextStyle(fontSize: 11, color: MFColors.textMuted),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _youtubeKeyCtrl,
                  obscureText: true,
                  style: const TextStyle(
                      fontSize: 13, color: MFColors.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'API-Key einfügen…',
                    hintStyle: const TextStyle(
                        fontSize: 13, color: MFColors.textMuted),
                    filled: true,
                    fillColor: MFColors.surfaceAlt,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: MFColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: MFColors.border),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.save_outlined,
                          size: 18, color: MFColors.teal),
                      tooltip: 'Speichern',
                      onPressed: _saveYoutubeKey,
                    ),
                  ),
                  onSubmitted: (_) => _saveYoutubeKey(),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  TextButton.icon(
                    onPressed:
                        _ytTestState == 'loading' ? null : _testYoutubeKey,
                    icon: Icon(
                      switch (_ytTestState) {
                        'ok' => Icons.check_circle_outline,
                        'error' => Icons.error_outline,
                        _ => Icons.wifi_tethering,
                      },
                      size: 16,
                      color: _ytTestState == 'ok'
                          ? const Color(0xFF22C55E)
                          : _ytTestState == 'error'
                              ? Colors.redAccent
                              : MFColors.teal,
                    ),
                    label: Text(
                      switch (_ytTestState) {
                        'loading' => 'Teste…',
                        'ok' => 'Key gültig',
                        'error' => 'Fehler',
                        _ => 'Speichern & testen',
                      },
                      style: TextStyle(
                          fontSize: 12,
                          color: _ytTestState == 'error'
                              ? Colors.redAccent
                              : MFColors.teal),
                    ),
                  ),
                  if (_ytTestState == 'error' && _ytTestMsg.isNotEmpty)
                    Expanded(
                      child: Text(_ytTestMsg,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.redAccent)),
                    ),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _ApiFieldSection(
            prefs: _apiPrefs,
            onChanged: (p) async {
              setState(() => _apiPrefs = p);
              await AppSettings.saveApiFieldPrefs(p);
            },
          ),

          // ─── Info ──────────────────────────────────────────────────────────
          const SizedBox(height: 28),
          // ── Verlauf & Papierkorb ──────────────────────────────────────────
          _SectionHeader('VERLAUF & PAPIERKORB'),
          const SizedBox(height: 8),
          _SettingsTile(
            icon: Icons.history,
            iconColor: const Color(0xFF6366F1),
            title: 'Änderungsverlauf',
            subtitle: 'Bearbeitungen & Konflikt-Entscheidungen rückgängig machen',
            onTap: () => context.push(AppRoutes.history),
          ),
          const SizedBox(height: 8),
          _TrashSection(),

          const SizedBox(height: 24),

          _SectionHeader('APP'),
          const SizedBox(height: 8),
          _SettingsTile(
            icon: Icons.info_outline_rounded,
            iconColor: MFColors.textMuted,
            title: 'MindFeed Mobile',
            subtitle: 'Version 1.5.0 · Offline-First PKM',
            onTap: null,
          ),
        ],
      ),
    );
  }
}

// ─── Automatisches Backup ─────────────────────────────────────────────────────

class _AutoBackupSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AutoBackupSection> createState() => _AutoBackupSectionState();
}

class _AutoBackupSectionState extends ConsumerState<_AutoBackupSection> {
  late bool _enabled;
  late int _intervalHours;
  late int _keep;
  String? _dir;

  @override
  void initState() {
    super.initState();
    _enabled = AppSettings.getAutoBackupEnabled();
    _intervalHours = AppSettings.getAutoBackupIntervalHours();
    _keep = AppSettings.getAutoBackupKeep();
    _dir = AppSettings.getAutoBackupDir();
  }

  @override
  Widget build(BuildContext context) {
    final last = AppSettings.getLastAutoBackupAt();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MFColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.backup_outlined, size: 18, color: MFColors.teal),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Automatisches Backup',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                      color: MFColors.textPrimary)),
            ),
            Switch(
              value: _enabled,
              onChanged: (v) async {
                setState(() => _enabled = v);
                await AppSettings.saveAutoBackupEnabled(v);
                ref.read(syncSchedulerProvider).reconfigure();
              },
            ),
          ]),
          if (_enabled) ...[
            const SizedBox(height: 8),
            // Zielordner
            InkWell(
              onTap: _pickDir,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                decoration: BoxDecoration(
                  color: MFColors.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: MFColors.border),
                ),
                child: Row(children: [
                  const Icon(Icons.folder_outlined, size: 16, color: MFColors.teal),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _dir ?? 'Standard (Vault/backups) — tippen zum Ändern',
                      style: const TextStyle(fontSize: 12, color: MFColors.textPrimary,
                          fontFamily: 'monospace'),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_dir != null)
                    GestureDetector(
                      onTap: () async {
                        setState(() => _dir = null);
                        await AppSettings.saveAutoBackupDir(null);
                      },
                      child: const Icon(Icons.close, size: 14, color: MFColors.textMuted),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            // Intervall
            Row(children: [
              const Text('Intervall', style: TextStyle(fontSize: 13, color: MFColors.textPrimary)),
              const Spacer(),
              DropdownButton<int>(
                value: _intervalHours,
                items: const [
                  DropdownMenuItem(value: 6, child: Text('Alle 6 Std')),
                  DropdownMenuItem(value: 12, child: Text('Alle 12 Std')),
                  DropdownMenuItem(value: 24, child: Text('Täglich')),
                  DropdownMenuItem(value: 72, child: Text('Alle 3 Tage')),
                  DropdownMenuItem(value: 168, child: Text('Wöchentlich')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => _intervalHours = v);
                  await AppSettings.saveAutoBackupIntervalHours(v);
                },
              ),
            ]),
            // Aufbewahrung
            Row(children: [
              const Text('Behalten', style: TextStyle(fontSize: 13, color: MFColors.textPrimary)),
              const Spacer(),
              DropdownButton<int>(
                value: _keep,
                items: const [
                  DropdownMenuItem(value: 5, child: Text('5 Backups')),
                  DropdownMenuItem(value: 10, child: Text('10 Backups')),
                  DropdownMenuItem(value: 30, child: Text('30 Backups')),
                  DropdownMenuItem(value: 0, child: Text('Alle')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => _keep = v);
                  await AppSettings.saveAutoBackupKeep(v);
                },
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              last != null
                  ? 'Letztes Auto-Backup: ${DateFormat('dd.MM.yy HH:mm').format(last.toLocal())}'
                  : 'Noch kein automatisches Backup erstellt',
              style: const TextStyle(fontSize: 11, color: MFColors.textMuted),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _runNow,
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: const Text('Jetzt sichern'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickDir() async {
    try {
      final path = await pickFolder(prompt: 'Backup-Zielordner wählen');
      if (path != null) {
        setState(() => _dir = path);
        await AppSettings.saveAutoBackupDir(path);
      }
    } catch (_) {}
  }

  Future<void> _runNow() async {
    final db = ref.read(databaseProvider);
    try {
      await BackupService.createZipBackup(db, targetDir: _dir);
      await AppSettings.saveLastAutoBackupAt(DateTime.now());
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Backup erstellt'), behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Backup fehlgeschlagen: $e'),
          backgroundColor: Colors.red.shade900));
      }
    }
  }
}

// ─── Sub-Widgets ──────────────────────────────────────────────────────────────

class _ShowTasksInNotesToggle extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(showTasksInNotesProvider);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MFColors.border),
      ),
      child: Row(children: [
        const Icon(Icons.task_alt_rounded, size: 18, color: MFColors.teal),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Aufgaben-Sektion in Notizen anzeigen',
              style: TextStyle(fontSize: 14, color: MFColors.textPrimary)),
        ),
        Switch(
          value: enabled,
          activeThumbColor: MFColors.teal,
          onChanged: (v) async {
            ref.read(showTasksInNotesProvider.notifier).state = v;
            await AppSettings.saveShowTasksInNotes(v);
          },
        ),
      ]),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 0),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: MFColors.textMuted,
            letterSpacing: 1.2,
          ),
        ),
      );
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: MFColors.border),
          ),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: MFColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 11, color: MFColors.textMuted)),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ]),
        ),
      );
}

// ─── Tag-Stil Sektion ─────────────────────────────────────────────────────────

class _TagStyleSection extends ConsumerWidget {
  const _TagStyleSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(tagStyleProvider);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MFColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Vorschau
        const Text('Vorschau', style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: style.bgColor,
            borderRadius: BorderRadius.circular(style.borderRadius),
            border: Border.all(color: style.borderColor, width: 0.5),
          ),
          child: Text(
            style.showHash ? '#beispiel' : 'beispiel',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: style.textColor, fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 16),

        // Farb-Presets
        const Text('Farbschema', style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6,
          children: TagStyle.presets.map((p) {
            final isActive = style.bgColor == p.bg;
            return GestureDetector(
              onTap: () async {
                final newStyle = style.copyWith(
                    bgColor: p.bg, textColor: p.text, borderColor: p.border);
                ref.read(tagStyleProvider.notifier).state = newStyle;
                await AppSettings.saveTagStyle(newStyle);
              },
              child: Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: p.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isActive ? p.text : MFColors.border,
                    width: isActive ? 2 : 1,
                  ),
                ),
                child: isActive
                    ? Icon(Icons.check, size: 14, color: p.text)
                    : null,
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),

        // Form
        const Text('Form', style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
        const SizedBox(height: 6),
        Row(children: [
          _FormBtn('Pill', style.borderRadius > 10, () async {
            final s = style.copyWith(borderRadius: 99);
            ref.read(tagStyleProvider.notifier).state = s;
            await AppSettings.saveTagStyle(s);
          }),
          const SizedBox(width: 8),
          _FormBtn('Eckig', style.borderRadius <= 10, () async {
            final s = style.copyWith(borderRadius: 4);
            ref.read(tagStyleProvider.notifier).state = s;
            await AppSettings.saveTagStyle(s);
          }),
        ]),
        const SizedBox(height: 12),

        // # anzeigen
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('# Zeichen anzeigen',
                  style: TextStyle(fontSize: 12, color: MFColors.textPrimary)),
              const Text('z.B. #tag vs. tag',
                  style: TextStyle(fontSize: 10, color: MFColors.textMuted)),
            ]),
          ),
          Switch(
            value: style.showHash,
            activeThumbColor: MFColors.teal,
            onChanged: (v) async {
              final s = style.copyWith(showHash: v);
              ref.read(tagStyleProvider.notifier).state = s;
              await AppSettings.saveTagStyle(s);
            },
          ),
        ]),
      ]),
    );
  }
}

class _FormBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FormBtn(this.label, this.active, this.onTap);

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: active ? MFColors.tealBg : MFColors.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? MFColors.teal : MFColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: active ? MFColors.teal : MFColors.textMuted,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
        ),
      );
}

// ─── Templates Sektion ────────────────────────────────────────────────────────

class _TemplatesSection extends ConsumerWidget {
  const _TemplatesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(templatesProvider);

    return Column(children: [
      ...templates.asMap().entries.map((e) {
        final t = e.value;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: MFColors.border),
          ),
          child: ListTile(
            leading: Text(t.emoji,
                style: const TextStyle(fontSize: 22)),
            title: Text(t.name,
                style: const TextStyle(fontSize: 13, color: MFColors.textPrimary)),
            subtitle: Text('${t.fields.length} Felder',
                style: const TextStyle(fontSize: 11, color: MFColors.textMuted)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 16, color: MFColors.textSecondary),
                onPressed: () => _editTemplate(context, ref, t),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                onPressed: () => _deleteTemplate(ref, t.id),
              ),
            ]),
          ),
        );
      }),
      const SizedBox(height: 4),
      GestureDetector(
        onTap: () => _addTemplate(context, ref),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: MFColors.border, style: BorderStyle.solid),
          ),
          child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.add, size: 16, color: MFColors.teal),
            SizedBox(width: 6),
            Text('Template hinzufügen',
                style: TextStyle(fontSize: 13, color: MFColors.teal, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    ]);
  }

  void _deleteTemplate(WidgetRef ref, String id) {
    final current = ref.read(templatesProvider);
    final updated = current.where((t) => t.id != id).toList();
    ref.read(templatesProvider.notifier).state = updated;
    AppSettings.saveTemplates(updated);
  }

  Future<void> _addTemplate(BuildContext ctx, WidgetRef ref) async {
    await showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TemplateEditSheet(
        onSave: (t) {
          final updated = [...ref.read(templatesProvider), t];
          ref.read(templatesProvider.notifier).state = updated;
          AppSettings.saveTemplates(updated);
        },
      ),
    );
  }

  Future<void> _editTemplate(
      BuildContext ctx, WidgetRef ref, PropTemplate template) async {
    await showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TemplateEditSheet(
        existing: template,
        onSave: (t) {
          final current = ref.read(templatesProvider);
          final updated = current.map((x) => x.id == t.id ? t : x).toList();
          ref.read(templatesProvider.notifier).state = updated;
          AppSettings.saveTemplates(updated);
        },
      ),
    );
  }
}

// ─── Template bearbeiten ──────────────────────────────────────────────────────

class _TemplateEditSheet extends StatefulWidget {
  final PropTemplate? existing;
  final ValueChanged<PropTemplate> onSave;
  const _TemplateEditSheet({this.existing, required this.onSave});

  @override
  State<_TemplateEditSheet> createState() => _TemplateEditSheetState();
}

class _TemplateEditSheetState extends State<_TemplateEditSheet> {
  late final TextEditingController _nameCtrl;
  late String _emoji;
  late List<PropTemplateField> _fields;
  late Set<String> _cardFields; // Felder die in der Feed-Karte erscheinen

  @override
  void initState() {
    super.initState();
    final t = widget.existing;
    _nameCtrl = TextEditingController(text: t?.name ?? '');
    _emoji = t?.emoji ?? '📋';
    _fields = List.from(t?.fields ?? []);
    _cardFields = Set.from(t?.cardFields ?? []);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _addField() async {
    final result = await showDialog<PropTemplateField>(
      context: context,
      builder: (_) => _FieldDialog(),
    );
    if (result != null) setState(() => _fields.add(result));
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final id = widget.existing?.id ?? 'tpl-${DateTime.now().millisecondsSinceEpoch}';
    widget.onSave(PropTemplate(
      id: id, name: name, emoji: _emoji, fields: _fields,
      cardFields: _cardFields.toList(),
    ));
    Navigator.pop(context);
  }

  static const _emojis = ['📋','🎲','📚','🎬','🐉','🎮','🎵','🏋️','✈️','💼','🔬','🍕'];

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.92;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(maxHeight: maxH),
      child: Column(
        children: [
          // Griff + Titel (nicht scrollbar)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(color: MFColors.border,
                      borderRadius: BorderRadius.circular(99)),
                )),
          Text(widget.existing != null ? 'Template bearbeiten' : 'Neues Template',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                  color: MFColors.textPrimary)),
              ],
            ),
          ),
          // Scrollbarer Inhalt
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
          // Emoji-Auswahl
          const Text('Emoji', style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6,
            children: _emojis.map((e) => GestureDetector(
              onTap: () => setState(() => _emoji = e),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _emoji == e ? MFColors.tealBg : MFColors.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: _emoji == e ? MFColors.teal : MFColors.border),
                ),
                child: Text(e, style: const TextStyle(fontSize: 18)),
              ),
            )).toList(),
          ),
          const SizedBox(height: 14),

          // Name
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Name (z.B. Brettspiel, Buch)',
              labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.border)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.teal)),
            ),
          ),
          const SizedBox(height: 16),

          // Felder
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Felder', style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
            GestureDetector(
              onTap: _addField,
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add, size: 14, color: MFColors.teal),
                SizedBox(width: 3),
                Text('Feld hinzufügen', style: TextStyle(fontSize: 11, color: MFColors.teal)),
              ]),
            ),
          ]),
          const SizedBox(height: 6),
          if (_fields.isEmpty)
            const Text('Noch keine Felder.',
                style: TextStyle(fontSize: 12, color: MFColors.textMuted))
          else
            ...List.generate(_fields.length, (i) {
              final f = _fields[i];
              final pt = PropType.fromString(f.type);
              return Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: MFColors.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: MFColors.border),
                ),
                child: Row(children: [
                  Icon(pt.icon, size: 13, color: pt.color),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f.key,
                      style: const TextStyle(fontSize: 12, color: MFColors.textPrimary))),
                  Text(pt.label,
                      style: const TextStyle(fontSize: 10, color: MFColors.textMuted)),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => setState(() => _fields.removeAt(i)),
                    child: const Icon(Icons.close, size: 14, color: MFColors.textMuted),
                  ),
                ]),
              );
            }),

          // Feed-Karten-Felder
          if (_fields.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Karten-Vorschau im Feed',
                style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
            const SizedBox(height: 4),
            const Text('Welche Felder sollen in der Feed-Karte angezeigt werden?',
                style: TextStyle(fontSize: 10, color: MFColors.textMuted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: _fields.map((f) {
                final active = _cardFields.contains(f.key);
                return GestureDetector(
                  onTap: () => setState(() {
                    if (active) _cardFields.remove(f.key);
                    else _cardFields.add(f.key);
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: active ? MFColors.tealBg : MFColors.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? MFColors.teal : MFColors.border,
                        width: active ? 1.5 : 1,
                      ),
                    ),
                    child: Text(f.key,
                        style: TextStyle(
                            fontSize: 11,
                            color: active ? MFColors.teal : MFColors.textSecondary,
                            fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
                  ),
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
              child: const Text('Speichern',
                  style: TextStyle(color: MFColors.bg, fontWeight: FontWeight.bold)),
            ),
          ),
                ],  // Column-children Ende (scrollbar)
              ),   // Column Ende
            ),     // SingleChildScrollView Ende
          ),       // Flexible Ende
        ],         // äußere Column-children Ende
      ),           // äußere Column Ende
    );             // Container Ende
  }
}

// ─── KI-Struktur-Vorlagen (#38) ──────────────────────────────────────────────

/// Zeigt die editierbaren Typ-Gerüste der „strukturierten Notiz" und die
/// Struktur der „recherchierten Notiz" — Add/Edit/Delete + Reset.
class _StructureTemplatesSection extends ConsumerWidget {
  const _StructureTemplatesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(structureTemplatesProvider);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text(
        'Die KI erkennt beim „strukturierte Notiz erstellen" automatisch den Typ '
        'und formatiert nach dem passenden Gerüst. Hier kannst du diese Gerüste '
        'ansehen und anpassen.',
        style: TextStyle(fontSize: 11, color: MFColors.textMuted),
      ),
      const SizedBox(height: 10),
      ...templates.map((t) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MFColors.border),
            ),
            child: ListTile(
              title: Text(t.name,
                  style: const TextStyle(
                      fontSize: 13, color: MFColors.textPrimary)),
              subtitle: Text(
                t.hint.isEmpty ? '${_sectionCount(t.skeleton)} Abschnitte'
                    : '${t.hint} · ${_sectionCount(t.skeleton)} Abschnitte',
                style: const TextStyle(fontSize: 11, color: MFColors.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined,
                      size: 16, color: MFColors.textSecondary),
                  onPressed: () => _edit(context, ref, t),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 16, color: Colors.redAccent),
                  onPressed: () => _delete(ref, t.id),
                ),
              ]),
            ),
          )),
      const SizedBox(height: 4),
      GestureDetector(
        onTap: () => _add(context, ref),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: MFColors.border),
          ),
          child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 16, color: MFColors.teal),
                SizedBox(width: 6),
                Text('Typ hinzufügen',
                    style: TextStyle(
                        fontSize: 13,
                        color: MFColors.teal,
                        fontWeight: FontWeight.w500)),
              ]),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => _resetTemplates(ref),
          icon: const Icon(Icons.restart_alt, size: 14, color: MFColors.textMuted),
          label: const Text('Auf Standard zurücksetzen',
              style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
        ),
      ),

      // ── Recherchierte Notiz ──────────────────────────────────────────────
      const SizedBox(height: 14),
      const Text('Recherchierte Notiz',
          style: TextStyle(
              fontSize: 12,
              color: MFColors.textSecondary,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      const Text(
        'Struktur für die KI-Web-Recherche (Beschreibung, Alternativen, FAQ …).',
        style: TextStyle(fontSize: 11, color: MFColors.textMuted),
      ),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MFColors.border),
        ),
        child: ListTile(
          title: const Text('Struktur bearbeiten',
              style: TextStyle(fontSize: 13, color: MFColors.textPrimary)),
          trailing: const Icon(Icons.edit_outlined,
              size: 16, color: MFColors.textSecondary),
          onTap: () => _editResearch(context, ref),
        ),
      ),
    ]);
  }

  static int _sectionCount(String skeleton) =>
      RegExp(r'^##\s', multiLine: true).allMatches(skeleton).length;

  void _delete(WidgetRef ref, String id) {
    final updated =
        ref.read(structureTemplatesProvider).where((t) => t.id != id).toList();
    ref.read(structureTemplatesProvider.notifier).state = updated;
    AppSettings.saveStructureTemplates(updated);
  }

  Future<void> _resetTemplates(WidgetRef ref) async {
    await AppSettings.resetStructureTemplates();
    ref.read(structureTemplatesProvider.notifier).state =
        StructureTemplate.defaults;
  }

  Future<void> _add(BuildContext ctx, WidgetRef ref) async {
    await showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _StructureTemplateEditSheet(
        onSave: (t) {
          final updated = [...ref.read(structureTemplatesProvider), t];
          ref.read(structureTemplatesProvider.notifier).state = updated;
          AppSettings.saveStructureTemplates(updated);
        },
      ),
    );
  }

  Future<void> _edit(
      BuildContext ctx, WidgetRef ref, StructureTemplate template) async {
    await showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _StructureTemplateEditSheet(
        existing: template,
        onSave: (t) {
          final updated = ref
              .read(structureTemplatesProvider)
              .map((x) => x.id == t.id ? t : x)
              .toList();
          ref.read(structureTemplatesProvider.notifier).state = updated;
          AppSettings.saveStructureTemplates(updated);
        },
      ),
    );
  }

  Future<void> _editResearch(BuildContext ctx, WidgetRef ref) async {
    await showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ResearchStructureEditSheet(
        initial: ref.read(researchStructureProvider),
        onSave: (text) {
          ref.read(researchStructureProvider.notifier).state = text.trim().isEmpty
              ? StructureTemplate.defaultResearchStructure
              : text;
          AppSettings.saveResearchStructure(text);
        },
        onReset: () {
          AppSettings.resetResearchStructure();
          ref.read(researchStructureProvider.notifier).state =
              StructureTemplate.defaultResearchStructure;
        },
      ),
    );
  }
}

/// Bottom-Sheet zum Bearbeiten einer Struktur-Vorlage (Name + Hinweis + Gerüst).
class _StructureTemplateEditSheet extends StatefulWidget {
  final StructureTemplate? existing;
  final ValueChanged<StructureTemplate> onSave;
  const _StructureTemplateEditSheet({this.existing, required this.onSave});

  @override
  State<_StructureTemplateEditSheet> createState() =>
      _StructureTemplateEditSheetState();
}

class _StructureTemplateEditSheetState
    extends State<_StructureTemplateEditSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hintCtrl;
  late final TextEditingController _skeletonCtrl;

  @override
  void initState() {
    super.initState();
    final t = widget.existing;
    _nameCtrl = TextEditingController(text: t?.name ?? '');
    _hintCtrl = TextEditingController(text: t?.hint ?? '');
    _skeletonCtrl = TextEditingController(text: t?.skeleton ?? '## ');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hintCtrl.dispose();
    _skeletonCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final id = widget.existing?.id ??
        'st-${DateTime.now().millisecondsSinceEpoch}';
    widget.onSave(StructureTemplate(
      id: id,
      name: name,
      hint: _hintCtrl.text.trim(),
      skeleton: _skeletonCtrl.text.trim(),
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.92;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(maxHeight: maxH),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
                child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: MFColors.border,
                  borderRadius: BorderRadius.circular(99)),
            )),
            Text(widget.existing != null ? 'Typ bearbeiten' : 'Neuer Typ',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: MFColors.textPrimary)),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: _nameCtrl,
                autofocus: widget.existing == null,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Typname (z.B. REZEPT, TUTORIAL)',
                  labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: MFColors.border)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: MFColors.teal)),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _hintCtrl,
                style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Erkennungs-Hinweis (z.B. Koch-/Backvideo)',
                  helperText: 'Hilft der KI, diesen Typ zu erkennen.',
                  helperStyle: TextStyle(color: MFColors.textMuted, fontSize: 10),
                  labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: MFColors.border)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: MFColors.teal)),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Gerüst (Markdown-Überschriften ##)',
                  style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
              const SizedBox(height: 6),
              Container(
                decoration: BoxDecoration(
                  color: MFColors.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: MFColors.border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: TextField(
                  controller: _skeletonCtrl,
                  maxLines: null,
                  minLines: 8,
                  style: const TextStyle(
                      color: MFColors.textPrimary,
                      fontSize: 13,
                      height: 1.4,
                      fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: '## Überblick\n## Details\n…',
                    hintStyle: TextStyle(color: MFColors.textMuted, fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
                  child: const Text('Speichern',
                      style: TextStyle(
                          color: MFColors.bg, fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Bottom-Sheet zum Bearbeiten der Recherche-Struktur (ein großes Textfeld).
class _ResearchStructureEditSheet extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onSave;
  final VoidCallback onReset;
  const _ResearchStructureEditSheet({
    required this.initial,
    required this.onSave,
    required this.onReset,
  });

  @override
  State<_ResearchStructureEditSheet> createState() =>
      _ResearchStructureEditSheetState();
}

class _ResearchStructureEditSheetState
    extends State<_ResearchStructureEditSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.92;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(maxHeight: maxH),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
                child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: MFColors.border,
                  borderRadius: BorderRadius.circular(99)),
            )),
            const Text('Recherche-Struktur',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: MFColors.textPrimary)),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                  'Die Abschnitte, nach denen die recherchierte Notiz aufgebaut wird. '
                  'Markdown-Überschriften (##) mit optionalen Hinweisen in Klammern.',
                  style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: MFColors.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: MFColors.border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: TextField(
                  controller: _ctrl,
                  maxLines: null,
                  minLines: 12,
                  autofocus: true,
                  style: const TextStyle(
                      color: MFColors.textPrimary,
                      fontSize: 13,
                      height: 1.4,
                      fontFamily: 'monospace'),
                  decoration: const InputDecoration(border: InputBorder.none),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                TextButton.icon(
                  onPressed: () {
                    widget.onReset();
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.restart_alt,
                      size: 14, color: MFColors.textMuted),
                  label: const Text('Standard',
                      style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () {
                    widget.onSave(_ctrl.text);
                    Navigator.pop(context);
                  },
                  style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
                  child: const Text('Speichern',
                      style: TextStyle(
                          color: MFColors.bg, fontWeight: FontWeight.bold)),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─── Dialog: Neues Template-Feld ─────────────────────────────────────────────

class _FieldDialog extends StatefulWidget {
  const _FieldDialog();

  @override
  State<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends State<_FieldDialog> {
  final _keyCtrl = TextEditingController();
  PropType _type = PropType.text;
  final _defaultCtrl = TextEditingController();

  @override
  void dispose() {
    _keyCtrl.dispose();
    _defaultCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Feld hinzufügen',
            style: TextStyle(color: MFColors.textPrimary, fontSize: 15)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _keyCtrl,
            autofocus: true,
            style: const TextStyle(color: MFColors.textPrimary, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Feldname',
              labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.border)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.teal)),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<PropType>(
            value: _type,
            dropdownColor: MFColors.surface,
            style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Typ',
              labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.border)),
            ),
            items: PropType.values.map((t) => DropdownMenuItem(
              value: t,
              child: Row(children: [
                Icon(t.icon, size: 14, color: t.color),
                const SizedBox(width: 8),
                Text(t.label),
              ]),
            )).toList(),
            onChanged: (v) => setState(() => _type = v ?? PropType.text),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _defaultCtrl,
            style: const TextStyle(color: MFColors.textPrimary, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Standardwert (optional)',
              labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.border)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.teal)),
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen',
                style: TextStyle(color: MFColors.textMuted)),
          ),
          TextButton(
            onPressed: () {
              final key = _keyCtrl.text.trim();
              if (key.isEmpty) return;
              Navigator.pop(context, PropTemplateField(
                key: key,
                type: _type.value,
                defaultValue: _defaultCtrl.text.trim(),
              ));
            },
            child: const Text('Hinzufügen',
                style: TextStyle(color: MFColors.teal)),
          ),
        ],
      );
}

// ─── API-Feld-Einstellungen Widget ────────────────────────────────────────────

class _ApiFieldSection extends StatelessWidget {
  final ApiFieldPrefs prefs;
  final ValueChanged<ApiFieldPrefs> onChanged;

  const _ApiFieldSection({required this.prefs, required this.onChanged});

  // Anzeige-Metadaten pro Quelle (Titel/Icon/Farbe). Die Felder selbst kommen
  // aus dem ApiFieldCatalog — neue Quellen erscheinen automatisch, sobald sie
  // hier eine Darstellung erhalten.
  static const _display = <ApiSource, (String, IconData, Color)>{
    ApiSource.anilist: ('AniList (Anime & Manga)', Icons.animation_outlined, Color(0xFF02A9FF)),
    ApiSource.bgg: ('BoardGameGeek (Brettspiele)', Icons.casino_outlined, Color(0xFFFF5100)),
    ApiSource.vgg: ('VideoGameGeek (Videospiele)', Icons.videogame_asset_outlined, Color(0xFF7C3AED)),
    ApiSource.rpgg: ('RPGGeek (Rollenspiele)', Icons.auto_fix_high_outlined, Color(0xFF059669)),
    ApiSource.github: ('GitHub (Repositories)', Icons.code_outlined, Color(0xFF6366F1)),
    ApiSource.youtube: ('YouTube (Videos)', Icons.smart_display_outlined, Color(0xFFFF0000)),
    ApiSource.genericWeb: ('Web (allgemeine Links)', Icons.public_outlined, Color(0xFF38BDF8)),
  };

  @override
  Widget build(BuildContext context) {
    final groups = <Widget>[];
    for (final entry in _display.entries) {
      final source = entry.key;
      final fields = ApiFieldCatalog.fieldsFor(source);
      if (fields.isEmpty) continue;
      final (title, icon, color) = entry.value;
      if (groups.isNotEmpty) groups.add(const SizedBox(height: 10));
      groups.add(_ApiGroup(
        title: title,
        icon: icon,
        color: color,
        children: [
          for (final def in fields)
            _ApiToggle(
              def.label,
              prefs.isEnabled(source, def.key),
              (v) => onChanged(prefs.withField(source, def.key, v)),
            ),
        ],
      ));
    }
    return Column(children: groups);
  }
}

class _ApiGroup extends StatefulWidget {
  final String title;
  final IconData icon;
  final Color color;
  final List<Widget> children;

  const _ApiGroup({
    required this.title,
    required this.icon,
    required this.color,
    required this.children,
  });

  @override
  State<_ApiGroup> createState() => _ApiGroupState();
}

class _ApiGroupState extends State<_ApiGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MFColors.border),
      ),
      child: Column(children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(widget.icon, size: 16, color: widget.color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: MFColors.textPrimary)),
              ),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 18, color: MFColors.textMuted,
              ),
            ]),
          ),
        ),
        if (_expanded) ...[
          const Divider(height: 1, color: MFColors.border),
          ...widget.children,
        ],
      ]),
    );
  }
}

class _ApiToggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ApiToggle(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: MFColors.textSecondary)),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: MFColors.teal,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ]),
        ),
      );
}

class _BackupTile extends StatelessWidget {
  final BackupResult backup;
  final VoidCallback onShare;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  const _BackupTile({
    required this.backup,
    required this.onShare,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr =
        DateFormat('dd.MM.yyyy HH:mm').format(backup.createdAt.toLocal());
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MFColors.border),
      ),
      child: Row(children: [
        const Icon(Icons.folder_zip_outlined,
            size: 20, color: MFColors.teal),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(backup.filename,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: MFColors.textPrimary,
                      fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('$dateStr · ${backup.sizeLabel}',
                  style: const TextStyle(
                      fontSize: 10, color: MFColors.textMuted)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.ios_share_outlined,
              size: 16, color: MFColors.textSecondary),
          tooltip: 'Teilen',
          onPressed: onShare,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          icon: const Icon(Icons.restore_outlined,
              size: 16, color: Color(0xFFF59E0B)),
          tooltip: 'Wiederherstellen',
          onPressed: onRestore,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline,
              size: 16, color: Colors.redAccent),
          tooltip: 'Löschen',
          onPressed: onDelete,
          visualDensity: VisualDensity.compact,
        ),
      ]),
    );
  }
}

// ── Papierkorb-Einstellungen ──────────────────────────────────────────────────

class _TrashSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_TrashSection> createState() => _TrashSectionState();
}

class _TrashSectionState extends ConsumerState<_TrashSection> {
  late int _retentionDays;

  @override
  void initState() {
    super.initState();
    _retentionDays = AppSettings.getTrashRetentionDays();
  }

  @override
  Widget build(BuildContext context) {
    final trashed = ref.watch(trashedEntriesProvider);
    final count = trashed.maybeWhen(data: (l) => l.length, orElse: () => 0);

    return Column(
      children: [
        _SettingsTile(
          icon: Icons.delete_outline,
          iconColor: Colors.redAccent,
          title: 'Papierkorb öffnen',
          subtitle: count > 0
              ? '$count Eintrag${count != 1 ? 'e' : ''} im Papierkorb'
              : 'Papierkorb ist leer',
          onTap: () => context.push(AppRoutes.trash),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: MFColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Aufbewahrungsdauer',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                      color: MFColors.textPrimary)),
              const SizedBox(height: 4),
              Text(
                _retentionDays == 0
                    ? 'Einträge werden nie automatisch gelöscht'
                    : 'Einträge werden nach $_retentionDays Tagen gelöscht',
                style: const TextStyle(fontSize: 12, color: MFColors.textMuted),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                value: _retentionDays,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: const [
                  DropdownMenuItem(value: 7, child: Text('7 Tage')),
                  DropdownMenuItem(value: 30, child: Text('30 Tage')),
                  DropdownMenuItem(value: 90, child: Text('90 Tage')),
                  DropdownMenuItem(value: 0, child: Text('Nie')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => _retentionDays = v);
                  await AppSettings.saveTrashRetentionDays(v);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
