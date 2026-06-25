import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../../core/folder_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/secure_storage.dart';
import 'package:intl/intl.dart';
import '../../core/di.dart';
import '../../data/db/app_database.dart' hide Container;
import '../../core/theme.dart';
import '../../core/vault_manager.dart';
import '../../domain/prop_type.dart';
import '../../main.dart' show onRestartApp;
import '../../services/app_settings.dart';
import '../../services/enrichment/api_field_catalog.dart';
import '../../services/enrichment/api_field_prefs.dart';
import '../../services/enrichment/api_keys.dart';
import '../../services/enrichment/api_source.dart';
import '../../services/backup_service.dart';
import '../../services/openrouter_service.dart';
import '../../services/searxng_service.dart';
import '../settings/sync_settings_screen.dart';
import '../../core/constants.dart';
import '../../sync/sync_provider.dart';
import 'package:go_router/go_router.dart';

const _keyApiKey = 'openrouter_api_key';
const _keyAiModel = 'openrouter_model';
const _keyTemperature = 'openrouter_temperature';
const _keyMaxTokens = 'openrouter_max_tokens';
const _keyMaxInputChars = 'openrouter_max_input_chars';
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

  // AI Settings
  final _apiKeyCtrl = TextEditingController();
  bool _apiKeySaved = false;
  bool _apiKeyVisible = false;
  String _selectedModel = '';
  double _temperature = 0.3;
  int _maxTokens = 400;
  int _maxInputChars = 1500;

  // Modell-Picker
  List<Map<String, dynamic>> _models = [];
  bool _loadingModels = false;
  bool _freeOnly = true;
  String _modelSearch = '';

  // API-Feld-Präferenzen (katalog-getrieben)
  ApiFieldPrefs _apiPrefs = const ApiFieldPrefs({});

  // Quellen-API-Keys (YouTube Data API v3)
  final _youtubeKeyCtrl = TextEditingController();

  // Verbindungstest
  String _testState = 'idle'; // idle | loading | ok | error
  String _testError = '';

  // SearXNG (eigene Recherche-Schicht)
  final _searxngUrlCtrl = TextEditingController();
  String _searxTestState = 'idle'; // idle | loading | ok | error
  String _searxTestError = '';

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
    _apiKeyCtrl.dispose();
    _searxngUrlCtrl.dispose();
    _youtubeKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAiSettings() async {
    final key = await secureRead(_keyApiKey) ?? '';
    final model = await secureRead(_keyAiModel) ?? '';
    final tempStr = await secureRead(_keyTemperature);
    final tokStr = await secureRead(_keyMaxTokens);
    final charStr = await secureRead(_keyMaxInputChars);
    final searx = await secureRead(_keySearxngUrl) ?? '';
    final youtubeKey = await secureRead(ApiKeyStore.youtube) ?? '';
    if (mounted) {
      setState(() {
        _apiKeyCtrl.text = key;
        _apiKeySaved = key.isNotEmpty;
        _selectedModel = model;
        _temperature = double.tryParse(tempStr ?? '') ?? 0.3;
        _maxTokens = int.tryParse(tokStr ?? '') ?? 400;
        _maxInputChars = int.tryParse(charStr ?? '') ?? 1500;
        _searxngUrlCtrl.text = searx;
        _youtubeKeyCtrl.text = youtubeKey;
      });
    }
  }

  Future<void> _saveYoutubeKey() async {
    await secureWrite(ApiKeyStore.youtube, _youtubeKeyCtrl.text.trim());
    if (mounted) _showSnack('YouTube-API-Key gespeichert', success: true);
  }

  Future<void> _saveAiSettings() async {
    await secureWrite(_keyApiKey, _apiKeyCtrl.text.trim());
    await secureWrite(_keyAiModel, _selectedModel);
    await secureWrite(_keyTemperature, _temperature.toString());
    await secureWrite(_keyMaxTokens, _maxTokens.toString());
    await secureWrite(_keyMaxInputChars, _maxInputChars.toString());
    await secureWrite(_keySearxngUrl, _searxngUrlCtrl.text.trim());
    if (mounted) {
      setState(() => _apiKeySaved = _apiKeyCtrl.text.trim().isNotEmpty);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('AI-Einstellungen gespeichert.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _loadModels() async {
    final key = _apiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('Bitte zuerst API-Key eingeben.', success: false);
      return;
    }
    setState(() => _loadingModels = true);
    try {
      final models = await OpenRouterService.getModels(key);
      if (mounted) setState(() { _models = models; _loadingModels = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingModels = false);
        _showSnack('Modelle konnten nicht geladen werden: $e', success: false);
      }
    }
  }

  Future<void> _testConnection() async {
    final key = _apiKeyCtrl.text.trim();
    if (key.isEmpty) {
      setState(() { _testState = 'error'; _testError = 'Kein API-Key eingegeben'; });
      return;
    }
    setState(() { _testState = 'loading'; _testError = ''; });
    try {
      final svc = OpenRouterService(
        apiKey: key,
        model: _selectedModel.isNotEmpty ? _selectedModel : OpenRouterService.defaultModel,
      );
      await svc.testConnection();
      if (mounted) setState(() => _testState = 'ok');
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        setState(() {
          _testState = 'error';
          _testError = msg.length > 150 ? '${msg.substring(0, 150)}…' : msg;
        });
      }
    }
  }

  Future<void> _testSearxng() async {
    final url = _searxngUrlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() { _searxTestState = 'error'; _searxTestError = 'Keine URL eingegeben'; });
      return;
    }
    setState(() { _searxTestState = 'loading'; _searxTestError = ''; });
    final err = await SearxngService(baseUrl: url).testConnection();
    if (!mounted) return;
    setState(() {
      _searxTestState = err == null ? 'ok' : 'error';
      _searxTestError = err == null
          ? ''
          : (err.length > 150 ? '${err.substring(0, 150)}…' : err);
    });
  }

  List<Map<String, dynamic>> get _filteredModels {
    return _models.where((m) {
      final id = (m['id'] as String? ?? '').toLowerCase();
      final name = (m['name'] as String? ?? '').toLowerCase();
      final isFree = id.endsWith(':free') ||
          ((m['pricing'] as Map?)?.entries.every(
                (e) => e.value == '0' || e.value == null,
              ) ??
              false);
      if (_freeOnly && !isFree) return false;
      if (_modelSearch.isNotEmpty) {
        final q = _modelSearch.toLowerCase();
        if (!id.contains(q) && !name.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  String _priceLabel(Map<String, dynamic> m) {
    final id = (m['id'] as String? ?? '');
    final pricing = m['pricing'] as Map?;
    final isFree = id.endsWith(':free') ||
        (pricing?.entries.every((e) => e.value == '0' || e.value == null) ?? false);
    if (isFree) return 'Free';
    final p = double.tryParse(pricing?['prompt']?.toString() ?? '') ?? 0;
    if (p > 0) return '\$${(p * 1000000).toStringAsFixed(2)}/M';
    return '—';
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
          _SectionHeader('KI-ANREICHERUNG (OPENROUTER)'),
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
                // Header
                Row(children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withAlpha(25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.auto_awesome_outlined,
                        size: 18, color: Color(0xFF8B5CF6)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('OpenRouter API',
                            style: TextStyle(fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: MFColors.textPrimary)),
                        Text(
                            _apiKeySaved ? 'API-Key gespeichert ✓' : 'API-Key nicht gesetzt',
                            style: TextStyle(fontSize: 11,
                                color: _apiKeySaved ? MFColors.teal : MFColors.textMuted)),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 14),

                // API-Key
                TextField(
                  controller: _apiKeyCtrl,
                  obscureText: !_apiKeyVisible,
                  style: const TextStyle(fontSize: 13,
                      color: MFColors.textPrimary, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'API-Key (openrouter.ai)',
                    labelStyle: const TextStyle(color: MFColors.textMuted, fontSize: 12),
                    hintText: 'sk-or-...',
                    hintStyle: const TextStyle(color: MFColors.textMuted, fontSize: 12),
                    filled: true, fillColor: MFColors.bg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.teal)),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _apiKeyVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          size: 18, color: MFColors.textMuted),
                      onPressed: () => setState(() => _apiKeyVisible = !_apiKeyVisible),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Modell-Picker ──────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Modell', style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600,
                        color: MFColors.textSecondary)),
                    Row(children: [
                      Checkbox(
                        value: _freeOnly,
                        onChanged: (v) => setState(() => _freeOnly = v ?? true),
                        visualDensity: VisualDensity.compact,
                        activeColor: MFColors.teal,
                      ),
                      const Text('Nur Free',
                          style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
                      const SizedBox(width: 8),
                      _SmallBtn(
                        label: _loadingModels ? 'Lädt…' : 'Laden',
                        onTap: _loadingModels ? null : _loadModels,
                        icon: _loadingModels
                            ? const SizedBox(width: 10, height: 10,
                                child: CircularProgressIndicator(
                                    strokeWidth: 1.5, color: MFColors.teal))
                            : const Icon(Icons.refresh, size: 12, color: MFColors.teal),
                      ),
                    ]),
                  ],
                ),
                const SizedBox(height: 6),
                if (_models.isNotEmpty) ...[
                  TextField(
                    onChanged: (v) => setState(() => _modelSearch = v),
                    style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Filter…',
                      hintStyle: const TextStyle(fontSize: 12, color: MFColors.textMuted),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      filled: true, fillColor: MFColors.bg,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: MFColors.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: MFColors.border)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: MFColors.teal)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 180,
                    decoration: BoxDecoration(
                      border: Border.all(color: MFColors.border),
                      borderRadius: BorderRadius.circular(8),
                      color: MFColors.bg,
                    ),
                    child: _filteredModels.isEmpty
                        ? const Center(child: Text('Keine Modelle gefunden',
                            style: TextStyle(fontSize: 11, color: MFColors.textMuted)))
                        : ListView.builder(
                            itemCount: _filteredModels.length,
                            itemBuilder: (ctx, i) {
                              final m = _filteredModels[i];
                              final id = m['id'] as String? ?? '';
                              final name = m['name'] as String? ?? id;
                              final isFree = id.endsWith(':free') ||
                                  ((m['pricing'] as Map?)?.entries.every(
                                        (e) => e.value == '0' || e.value == null) ?? false);
                              final selected = id == _selectedModel;
                              return InkWell(
                                onTap: () => setState(() => _selectedModel = id),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? MFColors.teal.withAlpha(25)
                                        : Colors.transparent,
                                    border: selected
                                        ? const Border(
                                            left: BorderSide(
                                                color: MFColors.teal, width: 2))
                                        : null,
                                  ),
                                  child: Row(children: [
                                    Expanded(child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(name,
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: selected
                                                    ? MFColors.teal
                                                    : MFColors.textPrimary),
                                            overflow: TextOverflow.ellipsis),
                                        Text(id,
                                            style: const TextStyle(
                                                fontSize: 10,
                                                color: MFColors.textMuted,
                                                fontFamily: 'monospace'),
                                            overflow: TextOverflow.ellipsis),
                                      ],
                                    )),
                                    Text(
                                      _priceLabel(m),
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: isFree
                                              ? MFColors.teal
                                              : MFColors.textMuted),
                                    ),
                                  ]),
                                ),
                              );
                            },
                          ),
                  ),
                  if (_selectedModel.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('✓ $_selectedModel',
                        style: const TextStyle(
                            fontSize: 10, color: MFColors.teal,
                            fontFamily: 'monospace'),
                        overflow: TextOverflow.ellipsis),
                  ],
                ] else ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: MFColors.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: MFColors.border),
                    ),
                    child: Text(
                      _selectedModel.isNotEmpty
                          ? _selectedModel
                          : 'meta-llama/llama-3.1-8b-instruct:free',
                      style: const TextStyle(
                          fontSize: 12, color: MFColors.textSecondary,
                          fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '← „Laden" drücken um Modelle von OpenRouter abzurufen',
                    style: TextStyle(fontSize: 10, color: MFColors.textMuted),
                  ),
                ],
                const SizedBox(height: 16),

                // ── Temperature ────────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Temperature',
                        style: TextStyle(fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: MFColors.textSecondary)),
                    Text(_temperature.toStringAsFixed(2),
                        style: const TextStyle(
                            fontSize: 11, color: MFColors.teal,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _temperature,
                  min: 0.0, max: 2.0, divisions: 40,
                  activeColor: MFColors.teal,
                  inactiveColor: MFColors.border,
                  onChanged: (v) => setState(() => _temperature = v),
                ),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Präzise (0.0)',
                        style: TextStyle(fontSize: 10, color: MFColors.textMuted)),
                    Text('Kreativ (2.0)',
                        style: TextStyle(fontSize: 10, color: MFColors.textMuted)),
                  ],
                ),
                const SizedBox(height: 14),

                // ── Max Output-Tokens ──────────────────────────────────────
                const Text('Max Output-Tokens',
                    style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: MFColors.textSecondary)),
                const SizedBox(height: 6),
                TextFormField(
                  initialValue: _maxTokens.toString(),
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13,
                      color: MFColors.textPrimary, fontFamily: 'monospace'),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 64) setState(() => _maxTokens = n);
                  },
                  decoration: InputDecoration(
                    hintText: '400',
                    helperText: 'Erhöhen wenn Antworten abgeschnitten werden',
                    helperStyle: const TextStyle(
                        fontSize: 10, color: MFColors.textMuted),
                    filled: true, fillColor: MFColors.bg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.teal)),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Max Input-Zeichen (übertragener Kontext) ───────────────
                const Text('Max Input-Zeichen',
                    style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: MFColors.textSecondary)),
                const SizedBox(height: 6),
                TextFormField(
                  initialValue: _maxInputChars.toString(),
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13,
                      color: MFColors.textPrimary, fontFamily: 'monospace'),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 200) setState(() => _maxInputChars = n);
                  },
                  decoration: InputDecoration(
                    hintText: '1500',
                    helperText: 'Wie viel Inhalt an die KI geht. Größere Modelle '
                        'verstehen mit mehr Zeichen oft besser (z.B. 4000–8000).',
                    helperMaxLines: 2,
                    helperStyle: const TextStyle(
                        fontSize: 10, color: MFColors.textMuted),
                    filled: true, fillColor: MFColors.bg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: MFColors.teal)),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Verbindungstest + Speichern ────────────────────────────
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _testState == 'loading' ? null : _testConnection,
                      icon: _testState == 'loading'
                          ? const SizedBox(width: 14, height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: MFColors.teal))
                          : Icon(
                              _testState == 'ok'
                                  ? Icons.check_circle_outline
                                  : _testState == 'error'
                                      ? Icons.error_outline
                                      : Icons.wifi_tethering,
                              size: 15),
                      label: Text(
                        _testState == 'loading'
                            ? 'Teste…'
                            : _testState == 'ok'
                                ? 'Verbunden'
                                : _testState == 'error'
                                    ? 'Fehler'
                                    : 'Verbindung testen',
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _testState == 'ok'
                            ? MFColors.teal
                            : _testState == 'error'
                                ? Colors.redAccent
                                : MFColors.textSecondary,
                        side: BorderSide(
                          color: _testState == 'ok'
                              ? MFColors.teal
                              : _testState == 'error'
                                  ? Colors.redAccent
                                  : MFColors.border,
                        ),
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
                if (_testState == 'error' && _testError.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(_testError,
                      style: const TextStyle(
                          fontSize: 10, color: Colors.redAccent)),
                ],
                const SizedBox(height: 6),
                const Text(
                  'Kostenloser Account auf openrouter.ai reicht aus. '
                  'Free-Tier Modelle haben ein Rate-Limit.',
                  style: TextStyle(fontSize: 10, color: MFColors.textMuted),
                ),
              ],
            ),
          ),

          // ─── SearXNG (Recherche) ───────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('WEB-RECHERCHE (SEARXNG)'),
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
                    child: Text('Eigene SearXNG-Instanz',
                        style: TextStyle(fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: MFColors.textPrimary)),
                  ),
                ]),
                const SizedBox(height: 14),
                TextField(
                  controller: _searxngUrlCtrl,
                  style: const TextStyle(fontSize: 13,
                      color: MFColors.textPrimary, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'Basis-URL',
                    labelStyle: const TextStyle(color: MFColors.textMuted, fontSize: 12),
                    hintText: 'http://192.168.x.x:8080',
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
                      onPressed: _searxTestState == 'loading' ? null : _testSearxng,
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
                const Text(
                  'Selbst gehostete SearXNG-Instanz für Web-Recherche bei der '
                  'KI-Anreicherung. JSON-Format muss aktiv sein '
                  '(settings.yml: search.formats: [html, json]). HTTP-Adressen '
                  'im LAN sind nur im Heimnetz erreichbar.',
                  style: TextStyle(fontSize: 10, color: MFColors.textMuted),
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
            subtitle: 'Version 1.2.0 · Offline-First PKM',
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

class _SmallBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Widget? icon;
  const _SmallBtn({required this.label, this.onTap, this.icon});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: MFColors.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[icon!, const SizedBox(width: 4)],
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: MFColors.textSecondary)),
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
