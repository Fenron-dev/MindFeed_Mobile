import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../features/capture/qr_scan_screen.dart';

/// Reine, testbare Markdown-Bearbeitungs-Helfer für ein [TextEditingValue].
class MarkdownFormat {
  const MarkdownFormat._();

  /// Umschließt die aktuelle Auswahl mit [prefix]/[suffix]. Ohne Auswahl werden
  /// die Marker am Cursor eingefügt und der Cursor dazwischen platziert.
  static TextEditingValue wrap(
      TextEditingValue value, String prefix, String suffix) {
    final text = value.text;
    final sel = value.selection;
    if (!sel.isValid) {
      final newText = '$text$prefix$suffix';
      return TextEditingValue(
        text: newText,
        selection:
            TextSelection.collapsed(offset: text.length + prefix.length),
      );
    }
    final start = sel.start;
    final end = sel.end;
    final selected = text.substring(start, end);
    final newText = text.replaceRange(start, end, '$prefix$selected$suffix');
    final cursor = selected.isEmpty
        ? start + prefix.length
        : end + prefix.length + suffix.length;
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  /// Fügt [prefix] am Anfang der Zeile ein, in der der Cursor steht
  /// (z.B. "- " für Aufzählung).
  static TextEditingValue linePrefix(TextEditingValue value, String prefix) {
    final text = value.text;
    final sel = value.selection;
    final pos = sel.isValid ? sel.start : text.length;
    final lineStart = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
    final newText = text.replaceRange(lineStart, lineStart, prefix);
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: pos + prefix.length),
    );
  }

  /// Fügt [insertText] an der Cursor-/Auswahlposition ein.
  static TextEditingValue insert(TextEditingValue value, String insertText) {
    final text = value.text;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final newText = text.replaceRange(start, end, insertText);
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + insertText.length),
    );
  }
}

/// Horizontale, scrollbare Formatierungs-Leiste: Fett, Kursiv, Durchgestrichen,
/// Aufzählung, Link und QR-Code-Scan. Arbeitet direkt auf [controller]; nach
/// jeder Aktion wird [onChanged] aufgerufen (z.B. um URL-Vorschau/Tag-Parsing
/// anzustoßen). Optionale [extraActions] werden rechts angehängt.
class FormatToolbar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback? onChanged;
  final List<Widget> extraActions;

  const FormatToolbar({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.extraActions = const [],
  });

  void _apply(TextEditingValue newValue) {
    controller.value = newValue;
    focusNode?.requestFocus();
    onChanged?.call();
  }

  Future<void> _scanQr(BuildContext context) async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (raw == null || raw.trim().isEmpty) return;
    // Trennzeichen einfügen, damit der Link nicht an bestehenden Text klebt.
    final needsSpace = controller.text.isNotEmpty &&
        !controller.text.endsWith('\n') &&
        !controller.text.endsWith(' ');
    _apply(MarkdownFormat.insert(
        controller.value, '${needsSpace ? ' ' : ''}${raw.trim()}'));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      decoration: const BoxDecoration(
        color: MFColors.surface,
        border: Border(top: BorderSide(color: MFColors.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _btn(Icons.format_bold_rounded, 'Fett',
              () => _apply(MarkdownFormat.wrap(controller.value, '**', '**'))),
          _btn(Icons.format_italic_rounded, 'Kursiv',
              () => _apply(MarkdownFormat.wrap(controller.value, '*', '*'))),
          _btn(Icons.format_strikethrough_rounded, 'Durchgestrichen',
              () => _apply(MarkdownFormat.wrap(controller.value, '~~', '~~'))),
          _btn(Icons.format_list_bulleted_rounded, 'Aufzählung',
              () => _apply(MarkdownFormat.linePrefix(controller.value, '- '))),
          _btn(Icons.link_rounded, 'Link',
              () => _apply(
                  MarkdownFormat.wrap(controller.value, '[', '](https://)'))),
          _btn(Icons.qr_code_scanner_rounded, 'QR-Code scannen',
              () => _scanQr(context)),
          ...extraActions,
        ]),
      ),
    );
  }

  Widget _btn(IconData icon, String tooltip, VoidCallback onTap) => IconButton(
        icon: Icon(icon, size: 20, color: MFColors.textSecondary),
        tooltip: tooltip,
        onPressed: onTap,
        splashRadius: 20,
      );
}
