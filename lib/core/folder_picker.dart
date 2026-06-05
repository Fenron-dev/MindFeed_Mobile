import 'dart:io';
import 'package:file_picker/file_picker.dart';

/// Zeigt einen Ordner-Auswahl-Dialog.
/// Auf macOS: AppleScript `choose folder` (sandbox-sicher).
/// Auf anderen Plattformen: file_picker.
Future<String?> pickFolder({String prompt = 'Ordner wählen'}) async {
  if (Platform.isMacOS) {
    try {
      final escaped = prompt.replaceAll('"', '\\"');
      final result = await Process.run('osascript', [
        '-e',
        'POSIX path of (choose folder with prompt "$escaped")',
      ]);
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        return path.isEmpty ? null : path;
      }
    } catch (_) {}
    return null;
  }
  return FilePicker.platform.getDirectoryPath(dialogTitle: prompt);
}
