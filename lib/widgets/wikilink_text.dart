import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/theme.dart';

/// Rendert Text mit klickbaren [[Wikilinks]] (intern), #Tags, **Fett** und
/// externen URLs. Interne und externe Links werden unterschiedlich formatiert
/// und sind beide anklickbar.
class WikilinkText extends StatefulWidget {
  final String text;
  final TextStyle? baseStyle;
  final void Function(String title)? onWikilink;
  final void Function(String tag)? onTag;

  const WikilinkText({
    super.key,
    required this.text,
    this.baseStyle,
    this.onWikilink,
    this.onTag,
  });

  @override
  State<WikilinkText> createState() => _WikilinkTextState();
}

class _WikilinkTextState extends State<WikilinkText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Alte Recognizer freigeben und neu aufbauen
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    return RichText(
      text: TextSpan(
        style: widget.baseStyle ??
            const TextStyle(
                fontSize: 14, color: MFColors.textPrimary, height: 1.6),
        children: _parse(widget.text),
      ),
    );
  }

  List<InlineSpan> _parse(String input) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(
        r'\[\[([^\]]+)\]\]'   // [[Wikilink]] (intern)
        r'|\*\*([^*]+)\*\*'   // **bold**
        r'|#([a-zA-Z][a-zA-Z0-9_\-/äöüÄÖÜß]*)' // #tag (inkl. Bindestrich)
        r'|(https?://\S+)',   // URL (extern)
    );

    int cursor = 0;
    for (final match in pattern.allMatches(input)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: input.substring(cursor, match.start)));
      }

      if (match.group(1) != null) {
        // ── Interner Link: [[Wikilink]] → lila, mit Link-Icon ──
        final title = match.group(1)!.trim();
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            onTap: () => widget.onWikilink?.call(title),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1B4B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF4338CA), width: 0.5),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.link_rounded, size: 11, color: Color(0xFFA78BFA)),
                const SizedBox(width: 3),
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFFA78BFA),
                        fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ));
      } else if (match.group(2) != null) {
        spans.add(TextSpan(
          text: match.group(2),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(3) != null) {
        final tag = match.group(3)!;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            onTap: () => widget.onTag?.call(tag),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: MFColors.tealBg,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: const Color(0xFF0F766E), width: 0.5),
              ),
              child: Text('#$tag',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      color: MFColors.teal, fontFamily: 'monospace')),
            ),
          ),
        ));
      } else if (match.group(4) != null) {
        // ── Externer Link: URL → blau, unterstrichen, klickbar ──
        final url = match.group(4)!;
        final short = url.length > 48 ? '${url.substring(0, 48)}…' : url;
        final rec = TapGestureRecognizer()
          ..onTap = () async {
            final uri = Uri.tryParse(url);
            if (uri != null) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          };
        _recognizers.add(rec);
        spans.add(TextSpan(
          text: short,
          recognizer: rec,
          style: const TextStyle(
              color: Color(0xFF60A5FA),
              decoration: TextDecoration.underline,
              decorationColor: Color(0xFF60A5FA)),
        ));
      }

      cursor = match.end;
    }

    if (cursor < input.length) {
      spans.add(TextSpan(text: input.substring(cursor)));
    }
    return spans;
  }
}
