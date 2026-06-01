import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../main.dart' show onRestartApp;
import '../../services/backup_service.dart';

const _storage = FlutterSecureStorage();
const _keyApiKey = 'openrouter_api_key';
const _keyAiModel = 'openrouter_model';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _backupLoading = false;
  bool _restoreLoading = false;
  List<BackupResult> _localBackups = [];
  bool _backupsLoaded = false;

  // AI Settings
  final _apiKeyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  bool _apiKeySaved = false;
  bool _apiKeyVisible = false;

  @override
  void initState() {
    super.initState();
    _loadBackups();
    _loadAiSettings();
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAiSettings() async {
    final key = await _storage.read(key: _keyApiKey) ?? '';
    final model = await _storage.read(key: _keyAiModel) ?? '';
    if (mounted) {
      setState(() {
        _apiKeyCtrl.text = key;
        _modelCtrl.text = model;
        _apiKeySaved = key.isNotEmpty;
      });
    }
  }

  Future<void> _saveAiSettings() async {
    await _storage.write(key: _keyApiKey, value: _apiKeyCtrl.text.trim());
    await _storage.write(key: _keyAiModel, value: _modelCtrl.text.trim());
    if (mounted) {
      setState(() => _apiKeySaved = _apiKeyCtrl.text.trim().isNotEmpty);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('AI-Einstellungen gespeichert.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
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

  // ─── Backup erstellen ──────────────────────────────────────────────────────

  Future<void> _createBackup() async {
    setState(() => _backupLoading = true);
    try {
      final result = await BackupService.createBackup(ref.read(databaseProvider));
      await BackupService.shareBackup(result);
      await _loadBackups();
      if (mounted) {
        _showSnack('Backup erstellt: ${result.filename}', success: true);
      }
    } catch (e) {
      if (mounted) _showSnack('Fehler beim Backup: $e', success: false);
    } finally {
      if (mounted) setState(() => _backupLoading = false);
    }
  }

  // ─── Backup wiederherstellen ──────────────────────────────────────────────

  Future<void> _restoreFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      dialogTitle: 'MindFeed Backup wählen',
    );
    if (result == null || result.files.single.path == null) return;
    await _doRestore(result.files.single.path!);
  }

  Future<void> _doRestore(String zipPath) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Backup wiederherstellen?',
            style: TextStyle(color: MFColors.textPrimary)),
        content: const Text(
            'Alle aktuellen Daten werden durch das Backup ersetzt. '
            'Die App startet danach automatisch neu.',
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
    if (ok != true) return;

    setState(() => _restoreLoading = true);
    try {
      final db = ref.read(databaseProvider);
      // restore() schreibt zuerst in Temp, schließt dann DB, benennt atomar um
      await BackupService.restore(zipPath, db);
      if (mounted) {
        _showSnack('Backup wiederhergestellt. App startet neu…',
            success: true);
        await Future.delayed(const Duration(milliseconds: 800));
        // Awaited: onRestartApp ist Future<void> Function() — kein fire-and-forget
        await onRestartApp?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _restoreLoading = false);
        _showSnack('Fehler: $e', success: false);
      }
    }
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
          // ─── Datensicherung ────────────────────────────────────────────
          _SectionHeader('DATENSICHERUNG'),
          const SizedBox(height: 8),

          _SettingsTile(
            icon: Icons.cloud_upload_outlined,
            iconColor: MFColors.teal,
            title: 'Backup erstellen',
            subtitle:
                'ZIP-Datei mit allen Einträgen und Anhängen exportieren',
            trailing: _backupLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: MFColors.teal))
                : const Icon(Icons.chevron_right,
                    color: MFColors.textMuted, size: 18),
            onTap: _backupLoading ? null : _createBackup,
          ),

          const SizedBox(height: 8),

          _SettingsTile(
            icon: Icons.cloud_download_outlined,
            iconColor: const Color(0xFFF59E0B),
            title: 'Backup wiederherstellen',
            subtitle: 'ZIP-Backup-Datei auswählen und importieren',
            trailing: _restoreLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFFF59E0B)))
                : const Icon(Icons.chevron_right,
                    color: MFColors.textMuted, size: 18),
            onTap: _restoreLoading ? null : _restoreFromFile,
          ),

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
                Text('Noch keine lokalen Backups vorhanden.',
                    style: TextStyle(
                        fontSize: 13, color: MFColors.textMuted)),
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
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: MFColors.textPrimary)),
                        Text(
                            _apiKeySaved
                                ? 'API-Key gespeichert ✓'
                                : 'API-Key nicht gesetzt',
                            style: TextStyle(
                                fontSize: 11,
                                color: _apiKeySaved
                                    ? MFColors.teal
                                    : MFColors.textMuted)),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
                TextField(
                  controller: _apiKeyCtrl,
                  obscureText: !_apiKeyVisible,
                  style: const TextStyle(
                      fontSize: 13,
                      color: MFColors.textPrimary,
                      fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'API-Key (openrouter.ai)',
                    labelStyle: const TextStyle(
                        color: MFColors.textMuted, fontSize: 12),
                    hintText: 'sk-or-...',
                    hintStyle: const TextStyle(
                        color: MFColors.textMuted, fontSize: 12),
                    filled: true,
                    fillColor: MFColors.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: MFColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: MFColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: MFColors.teal),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _apiKeyVisible
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 18,
                          color: MFColors.textMuted),
                      onPressed: () => setState(
                          () => _apiKeyVisible = !_apiKeyVisible),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _modelCtrl,
                  style: const TextStyle(
                      fontSize: 13,
                      color: MFColors.textPrimary,
                      fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'Modell (leer = kostenlos)',
                    labelStyle: const TextStyle(
                        color: MFColors.textMuted, fontSize: 12),
                    hintText: 'meta-llama/llama-3.1-8b-instruct:free',
                    hintStyle: const TextStyle(
                        color: MFColors.textMuted, fontSize: 11),
                    filled: true,
                    fillColor: MFColors.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: MFColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: MFColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: MFColors.teal),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saveAiSettings,
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: const Text('Speichern',
                        style: TextStyle(fontSize: 13)),
                    style: FilledButton.styleFrom(
                      backgroundColor: MFColors.teal,
                      foregroundColor: MFColors.bg,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Kostenloser Account auf openrouter.ai reicht aus. '
                  'Free-Tier Modelle haben ein Rate-Limit.',
                  style: TextStyle(fontSize: 10, color: MFColors.textMuted),
                ),
              ],
            ),
          ),

          // ─── Info ──────────────────────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionHeader('APP'),
          const SizedBox(height: 8),
          _SettingsTile(
            icon: Icons.info_outline_rounded,
            iconColor: MFColors.textMuted,
            title: 'MindFeed Mobile',
            subtitle: 'Version 1.0.0 · Offline-First PKM',
            onTap: null,
          ),
        ],
      ),
    );
  }
}

// ─── Sub-Widgets ──────────────────────────────────────────────────────────────

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
