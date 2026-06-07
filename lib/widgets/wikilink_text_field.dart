import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/di.dart';
import '../core/theme.dart';
import '../data/repositories/entry_repository.dart';

/// TextField mit Obsidian-artigem `[[`-Autocomplete: sobald `[[` getippt wird,
/// erscheint ein verankertes Dropdown direkt unter dem Eingabefeld mit
/// passenden Notizen/Aufgaben. Auswahl fügt `[[Titel]]` ein.
///
/// Wiederverwendbar in Capture, Entry-Detail, Task-Detail und Property-Feldern.
class WikilinkTextField extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextStyle? style;
  final int? maxLines;
  final int? minLines;
  final bool autofocus;
  final bool expands;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;

  const WikilinkTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.decoration,
    this.style,
    this.maxLines,
    this.minLines,
    this.autofocus = false,
    this.expands = false,
    this.textInputAction,
    this.onChanged,
  });

  @override
  ConsumerState<WikilinkTextField> createState() => _WikilinkTextFieldState();
}

/// Ein Vorschlagseintrag im Dropdown (Notiz/Aufgabe oder Tag).
class _Sugg {
  final IconData icon;
  final String label;
  final VoidCallback onPick;
  const _Sugg({required this.icon, required this.label, required this.onPick});
}

class _WikilinkTextFieldState extends ConsumerState<WikilinkTextField> {
  final _link = LayerLink();
  final _fieldKey = GlobalKey();
  final _portal = OverlayPortalController();
  Timer? _debounce;
  List<_Sugg> _suggestions = [];
  bool _loading = false;
  String? _partial;
  String _mode = 'wiki'; // 'wiki' | 'tag'
  int _highlight = 0;
  Offset _caretOffset = Offset.zero;
  String _lastText = '';

  /// Sauberer Anzeigetitel eines Eintrags (ohne Klammern/Blockrefs/Markdown).
  static String _entryLabel(EntryWithDetails e) {
    final t = e.entry.title;
    if (t != null && t.trim().isNotEmpty) {
      return t.trim().replaceAll(RegExp(r'[\[\]]'), '');
    }
    return e.entry.body
        .replaceAll(RegExp(r'\[\[|\]\]'), '')
        .replaceAll(RegExp(r'\^[a-zA-Z0-9_-]+'), '')
        .replaceAll(RegExp(r'[#*`_>]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Berechnet die Cursor-Position (relativ zur Feld-Oberkante) via TextPainter,
  /// damit das Dropdown direkt unter der Eingabestelle erscheint statt am Rand.
  void _updateCaretOffset() {
    final rb = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final width = rb?.size.width ?? 300.0;
    final text = widget.controller.text;
    final cursor = widget.controller.selection.baseOffset;
    final upto = cursor < 0 ? text : text.substring(0, cursor.clamp(0, text.length));
    final style = widget.style ?? const TextStyle(fontSize: 15);
    final tp = TextPainter(
      text: TextSpan(text: upto, style: style),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: width);
    final caret = tp.getOffsetForCaret(
        TextPosition(offset: upto.length), Rect.zero);
    final lineH = (style.fontSize ?? 15) * (style.height ?? 1.4);
    // dy auf Feldhöhe begrenzen, damit das Popup im Feldbereich bleibt
    final maxDy = (rb?.size.height ?? 400) - 8;
    _caretOffset = Offset(
      caret.dx.clamp(0, width - 40),
      (caret.dy + lineH + 4).clamp(0, maxDy),
    );
  }

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  /// Findet die aktive Eingabe (`[[` oder `#`) vor dem Cursor.
  ({String kind, int openIdx, String partial})? _activeContext() {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    final cursor = sel.baseOffset < 0 ? text.length : sel.baseOffset;
    final before = text.substring(0, cursor.clamp(0, text.length));

    // Wikilink: letztes [[ ohne ]] / Zeilenumbruch danach
    int wikiIdx = before.lastIndexOf('[[');
    if (wikiIdx != -1) {
      final between = before.substring(wikiIdx + 2);
      if (between.contains(']]') || between.contains('\n')) wikiIdx = -1;
    }

    // Tag: # das einen Token beginnt (Start oder Whitespace davor)
    int tagIdx = -1;
    String tagPartial = '';
    final tagMatch =
        RegExp(r'(?:^|\s)#([a-zA-Z0-9_/äöüÄÖÜß-]*)$').firstMatch(before);
    if (tagMatch != null) {
      tagPartial = tagMatch.group(1) ?? '';
      tagIdx = before.length - tagPartial.length - 1; // Position des '#'
    }

    // Näherer Trigger gewinnt
    if (wikiIdx == -1 && tagIdx == -1) return null;
    if (wikiIdx >= tagIdx) {
      return (kind: 'wiki', openIdx: wikiIdx,
          partial: before.substring(wikiIdx + 2).trim());
    }
    return (kind: 'tag', openIdx: tagIdx, partial: tagPartial);
  }

  void _onChanged() {
    final text = widget.controller.text;
    // Nur bei echter Textänderung reagieren — reine Cursor-/Auswahl-Bewegung
    // (z.B. Klick in einen bestehenden [[Link]]) soll das Popup NICHT öffnen.
    final textChanged = text != _lastText;
    _lastText = text;
    if (!textChanged) return;
    widget.onChanged?.call(text);
    final ctx = _activeContext();
    if (ctx == null) {
      _hide();
      return;
    }
    if (ctx.partial == _partial && ctx.kind == _mode && _portal.isShowing) return;
    _partial = ctx.partial;
    _mode = ctx.kind;
    _highlight = 0;
    _updateCaretOffset();
    setState(() => _loading = true);
    if (!_portal.isShowing) _portal.show();

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () async {
      List<_Sugg> sugg;
      if (ctx.kind == 'tag') {
        final all = await ref.read(tagDaoProvider).getAllTagNames();
        final q = ctx.partial.toLowerCase();
        sugg = all
            .where((t) => q.isEmpty || t.toLowerCase().contains(q))
            .take(8)
            .map((t) => _Sugg(
                icon: Icons.label_outline, label: '#$t',
                onPick: () => _insertTag(t)))
            .toList();
      } else {
        final results = await ref.read(entryRepositoryProvider).search(ctx.partial);
        sugg = results.take(8).map((e) {
          final label = _entryLabel(e);
          return _Sugg(
            icon: e.entry.type == 'task' ? Icons.task_alt_rounded : Icons.notes_rounded,
            label: label,
            onPick: () => _insertWiki(label),
          );
        }).toList();
      }
      if (!mounted) return;
      setState(() { _suggestions = sugg; _loading = false; });
    });
  }

  void _hide() {
    if (_portal.isShowing) _portal.hide();
    if (_partial != null || _suggestions.isNotEmpty) {
      _partial = null;
      _suggestions = [];
      _loading = false;
    }
  }

  void _replaceRangeFromOpener(String replacement) {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    final cursor = sel.baseOffset < 0 ? text.length : sel.baseOffset;
    final ctx = _activeContext();
    if (ctx == null) return;
    final newText = text.replaceRange(ctx.openIdx, cursor, replacement);
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: ctx.openIdx + replacement.length),
    );
    _hide();
    setState(() {});
  }

  void _insertWiki(String label) =>
      _replaceRangeFromOpener('[[${label.replaceAll(RegExp(r'[\[\]]'), '')}]]');

  void _insertTag(String name) => _replaceRangeFromOpener('#$name ');

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        return CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.topLeft,
          offset: _caretOffset,
          child: Align(
            alignment: Alignment.topLeft,
            child: _SuggestionList(
              loading: _loading,
              suggestions: _suggestions,
              highlight: _highlight,
            ),
          ),
        );
      },
      child: CompositedTransformTarget(
        link: _link,
        child: TextField(
          key: _fieldKey,
          controller: widget.controller,
          focusNode: widget.focusNode,
          decoration: widget.decoration,
          style: widget.style,
          maxLines: widget.expands ? null : widget.maxLines,
          minLines: widget.minLines,
          expands: widget.expands,
          textAlignVertical: widget.expands ? TextAlignVertical.top : null,
          autofocus: widget.autofocus,
          textInputAction: widget.textInputAction,
        ),
      ),
    );
  }
}

class _SuggestionList extends StatelessWidget {
  final bool loading;
  final List<_Sugg> suggestions;
  final int highlight;

  const _SuggestionList({
    required this.loading,
    required this.suggestions,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    if (!loading && suggestions.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 280),
        child: Container(
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: MFColors.borderLight),
            boxShadow: const [
              BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6)),
            ],
          ),
          child: loading && suggestions.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    height: 16, width: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: MFColors.teal),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: suggestions.length,
                  itemBuilder: (_, i) {
                    final s = suggestions[i];
                    return InkWell(
                      onTap: s.onPick,
                      child: Container(
                        color: i == highlight ? MFColors.tealBg : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(children: [
                          Icon(s.icon, size: 14, color: MFColors.textMuted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(s.label,
                                style: const TextStyle(fontSize: 13, color: MFColors.textPrimary),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
