import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/folder_picker.dart';
import '../../core/theme.dart';
import '../../core/vault_manager.dart';
import '../../main.dart' show onRestartApp;
import '../../services/app_settings.dart';
import '../../services/backup_service.dart';
import '../../data/db/app_database.dart' hide Container;

/// Vault-Übersichtsseite: zuletzt geöffnete Vaults, Erstellen, Öffnen, Server-Sync.
/// Wird beim ersten Start angezeigt UND ist über die Seitenleiste erreichbar.
class VaultSwitcherScreen extends StatefulWidget {
  /// Nur beim ersten Start (kein Vault vorhanden): Callback um Vault zu öffnen.
  final Future<void> Function(String vaultPath)? onFirstSetup;

  const VaultSwitcherScreen({super.key, this.onFirstSetup});

  bool get isFirstSetup => onFirstSetup != null;

  @override
  State<VaultSwitcherScreen> createState() => _VaultSwitcherScreenState();
}

class _VaultSwitcherScreenState extends State<VaultSwitcherScreen> {
  List<String> _recentVaults = [];
  String? _activeVaultPath;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _recentVaults = AppSettings.getRecentVaults();
    _activeVaultPath = AppSettings.getVaultPath();
  }

  // ── Vault öffnen ──────────────────────────────────────────────────────────

  Future<void> _openVault(String path) async {
    if (!VaultManager.isVault(path)) {
      _showSnack('Kein gültiger MindFeed-Vault (mindfeed.db fehlt).', ok: false);
      return;
    }
    setState(() => _loading = true);
    try {
      if (widget.isFirstSetup) {
        await widget.onFirstSetup!(path);
      } else {
        await VaultManager.saveVaultPath(path);
        await onRestartApp?.call();
      }
    } catch (e) {
      if (mounted) _showSnack('Fehler: $e', ok: false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Neuen Vault erstellen ─────────────────────────────────────────────────

  Future<void> _createVault() async {
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

    setState(() => _loading = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = chosenDir ?? p.join(dir.path, 'MindFeed');
      final vaultPath = p.join(base, vaultName);
      await VaultManager.createVault(vaultPath);
      await VaultManager.saveVaultPath(vaultPath);

      if (!mounted) return;
      if (widget.isFirstSetup) {
        await widget.onFirstSetup!(vaultPath);
      } else {
        await onRestartApp?.call();
      }
    } catch (e) {
      if (mounted) _showSnack('Fehler: $e', ok: false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Vorhandenen Vault öffnen ───────────────────────────────────────────────

  Future<void> _pickVault() async {
    final pathCtrl = TextEditingController();

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
              onPressed: () async {
                try {
                  final path = await pickFolder(prompt: 'Vault-Ordner wählen');
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
    await _openVault(path);
  }

  // ── Aus Backup wiederherstellen (Erststart) ───────────────────────────────

  Future<void> _importBackup() async {
    setState(() => _loading = true);
    AppDatabase? tempDb;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final vaultPath = p.join(dir.path, 'MindFeed', 'default');
      await Directory(vaultPath).create(recursive: true);

      tempDb = AppDatabase(p.join(vaultPath, 'mindfeed.db'));
      final result = await BackupService.importFromPicker(tempDb);
      await tempDb.close();
      tempDb = null;

      if (!mounted) return;

      if (result.isSuccess) {
        if (widget.isFirstSetup) {
          await widget.onFirstSetup!(vaultPath);
        } else {
          await VaultManager.saveVaultPath(vaultPath);
          await onRestartApp?.call();
        }
      } else if (!result.cancelled) {
        _showSnack('Import-Fehler: ${result.error}', ok: false);
      }
    } catch (e) {
      if (mounted) _showSnack('Fehler: $e', ok: false);
    } finally {
      try { await tempDb?.close(); } catch (_) {}
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Von Server verbinden (Sync-Vault klonen) ───────────────────────────────

  Future<void> _connectServer() async {
    final urlCtrl = TextEditingController();
    final codeCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Von Server synchronisieren',
            style: TextStyle(color: MFColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Verbinde zuerst deinen Vault über Einstellungen → Sync & Geräte, '
              'nachdem du einen lokalen Vault erstellt hast.',
              style: TextStyle(fontSize: 12, color: MFColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlCtrl,
              style: const TextStyle(color: MFColors.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Server-URL',
                labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
                hintText: 'http://192.168.x.x:8766',
                hintStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: MFColors.border)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: MFColors.teal)),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: codeCtrl,
              style: const TextStyle(color: MFColors.textPrimary, fontSize: 13),
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Pairing-Code (6 Stellen)',
                labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
                hintText: '123456',
                hintStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: MFColors.border)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: MFColors.teal)),
                counterText: '',
              ),
            ),
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
            child: const Text('Verbinden'),
          ),
        ],
      ),
    );

    final url = urlCtrl.text.trim();
    final code = codeCtrl.text.trim();
    urlCtrl.dispose();
    codeCtrl.dispose();
    if (confirmed != true || !mounted) return;
    if (url.isEmpty || code.length != 6) {
      _showSnack('URL und 6-stelliger Code erforderlich.', ok: false);
      return;
    }

    // Erst lokalen Vault erstellen, dann Sync-Verbindung herstellen
    setState(() => _loading = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final vaultPath = p.join(dir.path, 'MindFeed', 'synced');
      await VaultManager.createVault(vaultPath);
      await VaultManager.saveVaultPath(vaultPath);
      await AppSettings.saveSyncServerUrl(url);
      await AppSettings.saveSyncEnabled(true);

      if (!mounted) return;
      if (widget.isFirstSetup) {
        await widget.onFirstSetup!(vaultPath);
      } else {
        await onRestartApp?.call();
      }
    } catch (e) {
      if (mounted) _showSnack('Fehler: $e', ok: false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSnack(String msg, {required bool ok}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? MFColors.teal : Colors.red.shade900,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: widget.isFirstSetup
          ? null
          : AppBar(
              backgroundColor: MFColors.bg,
              title: const Text('Vault wechseln',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold,
                      color: MFColors.textPrimary)),
              leading: BackButton(color: MFColors.textSecondary),
            ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: MFColors.teal))
            : SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isDesktop ? 120 : 24,
                  vertical: 24,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.isFirstSetup) ...[
                        const SizedBox(height: 16),
                        // Logo
                        Row(children: [
                          Container(
                            width: 52, height: 52,
                            decoration: BoxDecoration(
                              color: MFColors.tealBg,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.psychology_outlined,
                                color: MFColors.teal, size: 30),
                          ),
                          const SizedBox(width: 16),
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('MindFeed',
                                  style: TextStyle(fontSize: 26,
                                      fontWeight: FontWeight.bold,
                                      color: MFColors.textPrimary)),
                              Text('Dein persönliches Wissens-System',
                                  style: TextStyle(fontSize: 12,
                                      color: MFColors.textMuted)),
                            ],
                          ),
                        ]),
                        const SizedBox(height: 32),
                      ],

                      // ── Zuletzt geöffnet ─────────────────────────────────
                      if (_recentVaults.isNotEmpty) ...[
                        _SectionLabel('ZULETZT GEÖFFNET'),
                        const SizedBox(height: 8),
                        ..._recentVaults.map((path) => _VaultTile(
                          path: path,
                          isActive: path == _activeVaultPath,
                          onTap: () => _openVault(path),
                          onRemove: () async {
                            await AppSettings.removeRecentVault(path);
                            setState(() => _recentVaults = AppSettings.getRecentVaults());
                          },
                        )),
                        const SizedBox(height: 24),
                      ],

                      // ── Aktionen ─────────────────────────────────────────
                      _SectionLabel('VAULT'),
                      const SizedBox(height: 8),

                      _ActionTile(
                        icon: Icons.add_circle_outline,
                        iconColor: MFColors.teal,
                        title: 'Neuen Vault erstellen',
                        subtitle: 'Leeren Vault an einem wählbaren Speicherort anlegen',
                        onTap: _createVault,
                      ),
                      const SizedBox(height: 8),
                      _ActionTile(
                        icon: Icons.folder_open_outlined,
                        iconColor: MFColors.teal,
                        title: 'Vorhandenen Vault öffnen',
                        subtitle: 'Pfad zu einem bestehenden MindFeed-Vault eingeben',
                        onTap: _pickVault,
                      ),
                      const SizedBox(height: 8),
                      _ActionTile(
                        icon: Icons.cloud_download_outlined,
                        iconColor: const Color(0xFFF59E0B),
                        title: 'Aus Backup wiederherstellen',
                        subtitle: 'JSON oder ZIP — Daten aus einem Backup importieren',
                        onTap: _importBackup,
                      ),
                      const SizedBox(height: 8),
                      _ActionTile(
                        icon: Icons.sync_outlined,
                        iconColor: const Color(0xFF6366F1),
                        title: 'Von Server synchronisieren',
                        subtitle: 'Vault mit einem laufenden MindFeed-Server verbinden',
                        onTap: _connectServer,
                      ),

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

// ── Hilfwidgets ───────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
        fontSize: 10, fontWeight: FontWeight.bold,
        color: MFColors.textMuted, letterSpacing: 1.2),
  );
}

class _VaultTile extends StatelessWidget {
  final String path;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _VaultTile({
    required this.path,
    required this.isActive,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final name = p.basename(path).isEmpty ? path : p.basename(path);
    final exists = VaultManager.isVault(path);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? MFColors.teal : MFColors.border,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        dense: true,
        onTap: exists ? onTap : null,
        leading: Icon(
          isActive ? Icons.folder : Icons.folder_outlined,
          color: isActive ? MFColors.teal : (exists ? MFColors.textSecondary : MFColors.textMuted),
          size: 20,
        ),
        title: Row(children: [
          Expanded(
            child: Text(name,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                    color: exists ? MFColors.textPrimary : MFColors.textMuted)),
          ),
          if (isActive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: MFColors.tealBg,
                borderRadius: BorderRadius.circular(99),
              ),
              child: const Text('Aktiv',
                  style: TextStyle(fontSize: 9, color: MFColors.teal,
                      fontWeight: FontWeight.bold)),
            ),
        ]),
        subtitle: Text(
          exists ? path : '$path (nicht gefunden)',
          style: TextStyle(
              fontSize: 10, fontFamily: 'monospace',
              color: exists ? MFColors.textMuted : Colors.redAccent),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close, size: 14, color: MFColors.textMuted),
          onPressed: onRemove,
          tooltip: 'Aus Liste entfernen',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
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
            width: 36, height: 36,
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
                    style: const TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: MFColors.textPrimary)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(fontSize: 11, color: MFColors.textMuted)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, size: 16, color: MFColors.textMuted),
        ]),
      ),
    );
  }
}
