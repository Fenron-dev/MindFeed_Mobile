import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../core/theme.dart';

/// Rendert Text mit klickbaren [[Wikilinks]], #Tags, **Fett** und URLs.
class WikilinkText extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: baseStyle ??
            const TextStyle(
                fontSize: 14,
                color: MFColors.textPrimary,
                height: 1.6),
        children: _parse(text),
      ),
    );
  }

  List<InlineSpan> _parse(String input) {
    final spans = <InlineSpan>[];
    // Muster in Reihenfolge: [[Wikilink]], **bold**, #tag, URL
    final pattern = RegExp(
        r'\[\[([^\]]+)\]\]'   // [[Wikilink]]
        r'|\*\*([^*]+)\*\*'   // **bold**
        r'|#([a-zA-Z][a-zA-Z0-9_/äöüÄÖÜß]*)' // #tag
        r'|(https?://\S+)',   // URL
    );

    int cursor = 0;
    for (final match in pattern.allMatches(input)) {
      // Text vor dem Match
      if (match.start > cursor) {
        spans.add(TextSpan(text: input.substring(cursor, match.start)));
      }

      if (match.group(1) != null) {
        // [[Wikilink]] → nur Titel anzeigen, Klammern ausblenden
        final title = match.group(1)!.trim();
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            onTap: () => onWikilink?.call(title),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1B4B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: const Color(0xFF4338CA), width: 0.5),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.layers_outlined,
                    size: 11, color: Color(0xFFA78BFA)),
                const SizedBox(width: 3),
                Text(title,
                    style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFA78BFA),
                        fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ));
      } else if (match.group(2) != null) {
        // **bold**
        spans.add(TextSpan(
          text: match.group(2),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(3) != null) {
        // #tag
        final tag = match.group(3)!;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            onTap: () => onTag?.call(tag),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: MFColors.tealBg,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                    color: const Color(0xFF0F766E), width: 0.5),
              ),
              child: Text('#$tag',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: MFColors.teal,
                      fontFamily: 'monospace')),
            ),
          ),
        ));
      } else if (match.group(4) != null) {
        // URL
        final url = match.group(4)!;
        final short = url.length > 40 ? '${url.substring(0, 40)}…' : url;
        spans.add(TextSpan(
          text: short,
          style: const TextStyle(
              color: Color(0xFF60A5FA),
              decoration: TextDecoration.underline),
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
