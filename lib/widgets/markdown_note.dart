import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../core/theme.dart';

/// Rendert Notiz-Text als vollwertiges Markdown (Überschriften, Listen,
/// Tabellen, Code, Blockquotes — GitHub-Flavored) und behält dabei die
/// app-eigenen klickbaren Elemente bei:
///  - `[[Wikilink]]`  → interner Link (lila Chip)
///  - `#tag`          → Tag-Chip
///  - bare URLs / [text](url) → extern öffnen
class MarkdownNote extends StatelessWidget {
  final String data;
  final void Function(String title)? onWikilink;
  final void Function(String tag)? onTag;

  const MarkdownNote({
    super.key,
    required this.data,
    this.onWikilink,
    this.onTag,
  });

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: true,
      shrinkWrap: true,
      fitContent: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: [_WikilinkSyntax(), _TagSyntax()],
      builders: {
        'wikilink': _WikilinkBuilder(onWikilink),
        'hashtag': _TagBuilder(onTag),
      },
      onTapLink: (text, href, title) async {
        if (href == null) return;
        final uri = Uri.tryParse(href);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(
            fontSize: 15, color: MFColors.textPrimary, height: 1.6),
        a: const TextStyle(
            color: Color(0xFF60A5FA),
            decoration: TextDecoration.underline,
            decorationColor: Color(0xFF60A5FA)),
        code: const TextStyle(
            fontSize: 13,
            color: MFColors.teal,
            fontFamily: 'monospace',
            backgroundColor: MFColors.surfaceAlt),
        codeblockDecoration: BoxDecoration(
          color: MFColors.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: MFColors.border),
        ),
        blockquoteDecoration: BoxDecoration(
          color: MFColors.surfaceAlt,
          borderRadius: BorderRadius.circular(4),
          border: const Border(
              left: BorderSide(color: MFColors.teal, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        h1: const TextStyle(
            fontSize: 21, fontWeight: FontWeight.bold, color: MFColors.textPrimary),
        h2: const TextStyle(
            fontSize: 18, fontWeight: FontWeight.bold, color: MFColors.textPrimary),
        h3: const TextStyle(
            fontSize: 15.5, fontWeight: FontWeight.w600, color: MFColors.textPrimary),
        strong: const TextStyle(
            fontWeight: FontWeight.bold, color: MFColors.textPrimary),
        em: const TextStyle(
            fontStyle: FontStyle.italic, color: MFColors.textSecondary),
        listBullet: const TextStyle(fontSize: 15, color: MFColors.textPrimary),
        tableHead: const TextStyle(
            fontWeight: FontWeight.bold, color: MFColors.textPrimary, fontSize: 13.5),
        tableBody: const TextStyle(color: MFColors.textSecondary, fontSize: 13.5),
        tableBorder: TableBorder.all(color: MFColors.border, width: 0.8),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: MFColors.border, width: 1)),
        ),
      ),
    );
  }
}

// ── Inline-Syntaxen ────────────────────────────────────────────────────────
class _WikilinkSyntax extends md.InlineSyntax {
  _WikilinkSyntax() : super(r'\[\[([^\]\[]+)\]\]');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('wikilink', match[1]!.trim()));
    return true;
  }
}

class _TagSyntax extends md.InlineSyntax {
  _TagSyntax() : super(r'#([a-zA-Z][a-zA-Z0-9_\-/äöüÄÖÜß]*)');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('hashtag', match[1]!));
    return true;
  }
}

// ── Element-Builder (rendern als klickbare Chips) ──────────────────────────
class _WikilinkBuilder extends MarkdownElementBuilder {
  final void Function(String title)? onWikilink;
  _WikilinkBuilder(this.onWikilink);

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final title = element.textContent;
    return GestureDetector(
      onTap: () => onWikilink?.call(title),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF4C1D95),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFA78BFA), width: 0.8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.link_rounded, size: 12, color: Color(0xFFC4B5FD)),
          const SizedBox(width: 3),
          Text(title,
              style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFFC4B5FD),
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _TagBuilder extends MarkdownElementBuilder {
  final void Function(String tag)? onTag;
  _TagBuilder(this.onTag);

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final tag = element.textContent;
    return GestureDetector(
      onTap: () => onTag?.call(tag),
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
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: MFColors.teal,
                fontFamily: 'monospace')),
      ),
    );
  }
}
