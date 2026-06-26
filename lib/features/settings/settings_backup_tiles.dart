import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/theme.dart';
import '../../services/settings_backup.dart';

/// Zwei Tiles: Einstellungen (inkl. Keys) passwortgeschützt exportieren /
/// importieren — ohne Notiz-Inhalte.
class SettingsBackupTiles extends StatelessWidget {
  const SettingsBackupTiles({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _tile(context,
          icon: Icons.lock_outline_rounded,
          color: const Color(0xFF8B5CF6),
          title: 'Einstellungen exportieren (verschlüsselt)',
          subtitle: 'Profile, Keys, Einstellungen – passwortgeschützt, ohne Inhalte',
          onTap: () => _export(context)),
      const SizedBox(height: 8),
      _tile(context,
          icon: Icons.settings_backup_restore_rounded,
          color: const Color(0xFF38BDF8),
          title: 'Einstellungen importieren',
          subtitle: 'Verschlüsselte .mfbak-Datei einspielen',
          onTap: () => _import(context)),
    ]);
  }

  Widget _tile(BuildContext context,
          {required IconData icon,
          required Color color,
          required String title,
          required String subtitle,
          required VoidCallback onTap}) =>
      InkWell(
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
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: const TextStyle(
                        color: MFColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(color: MFColors.textMuted, fontSize: 11)),
              ]),
            ),
            const Icon(Icons.chevron_right, color: MFColors.textMuted, size: 18),
          ]),
        ),
      );

  Future<String?> _askPassword(BuildContext context,
      {required String title, bool confirm = false}) async {
    final pw = TextEditingController();
    final pw2 = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: Text(title, style: const TextStyle(color: MFColors.textPrimary, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: pw,
            obscureText: true,
            autofocus: true,
            style: const TextStyle(color: MFColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Passwort'),
          ),
          if (confirm)
            TextField(
              controller: pw2,
              obscureText: true,
              style: const TextStyle(color: MFColors.textPrimary),
              decoration: const InputDecoration(labelText: 'Passwort wiederholen'),
            ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen')),
          TextButton(
            onPressed: () {
              if (pw.text.isEmpty) return;
              if (confirm && pw.text != pw2.text) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('Passwörter stimmen nicht überein.')));
                return;
              }
              Navigator.pop(ctx, pw.text);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _export(BuildContext context) async {
    final pw = await _askPassword(context,
        title: 'Passwort für Sicherung', confirm: true);
    if (pw == null || !context.mounted) return;
    try {
      final blob = await SettingsBackup.exportEncrypted(pw);
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final file = File(p.join(dir.path, 'mindfeed-einstellungen-$ts.mfbak'));
      await file.writeAsString(blob);
      await Share.shareXFiles([XFile(file.path)],
          subject: 'MindFeed Einstellungen');
    } catch (e) {
      if (context.mounted) _snack(context, 'Export fehlgeschlagen: $e');
    }
  }

  Future<void> _import(BuildContext context) async {
    final res =
        await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    if (res == null || res.files.isEmpty || !context.mounted) return;
    final f = res.files.single;
    String content;
    try {
      content = f.bytes != null
          ? String.fromCharCodes(f.bytes!)
          : await File(f.path!).readAsString();
    } catch (e) {
      _snack(context, 'Datei konnte nicht gelesen werden: $e');
      return;
    }
    if (!context.mounted) return;
    final pw = await _askPassword(context, title: 'Passwort der Sicherung');
    if (pw == null || !context.mounted) return;
    try {
      await SettingsBackup.importEncrypted(content, pw);
      if (context.mounted) {
        _snack(context,
            'Einstellungen wiederhergestellt. App neu starten, damit alles greift.');
      }
    } catch (e) {
      if (context.mounted) _snack(context, '$e');
    }
  }
}
