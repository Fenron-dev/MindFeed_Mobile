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

class _WikilinkTextFieldState extends ConsumerState<WikilinkTextField> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  Timer? _debounce;
  List<EntryWithDetails> _suggestions = [];
  bool _loading = false;
  String? _partial;
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  /// Findet die aktive `[[`-Eingabe vor dem Cursor. Gibt null zurück, wenn
  /// keine offene Wikilink-Eingabe vorliegt.
  ({int openIdx, String partial})? _activeContext() {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    final cursor = sel.baseOffset < 0 ? text.length : sel.baseOffset;
    final before = text.substring(0, cursor.clamp(0, text.length));
    final openIdx = before.lastIndexOf('[[');
    if (openIdx == -1) return null;
    final between = before.substring(openIdx + 2);
    // Abbruch wenn die Klammer schon geschlossen ist oder ein Zeilenumbruch kam
    if (between.contains(']]') || between.contains('\n')) return null;
    return (openIdx: openIdx, partial: between.trim());
  }

  void _onChanged() {
    widget.onChanged?.call(widget.controller.text);
    final ctx = _activeContext();
    if (ctx == null) {
      _hide();
      return;
    }
    if (ctx.partial == _partial && _portal.isShowing) return;
    _partial = ctx.partial;
    _highlight = 0;
    setState(() => _loading = true);
    if (!_portal.isShowing) _portal.show();

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () async {
      final results =
          await ref.read(entryRepositoryProvider).search(ctx.partial);
      if (!mounted) return;
      setState(() {
        _suggestions = results.take(8).toList();
        _loading = false;
      });
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

  void _insert(EntryWithDetails item) {
    final title = item.entry.title ?? item.entry.body;
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    final cursor = sel.baseOffset < 0 ? text.length : sel.baseOffset;
    final ctx = _activeContext();
    if (ctx == null) return;
    final newText =
        text.replaceRange(ctx.openIdx, cursor, '[[$title]]');
    final newCursor = ctx.openIdx + '[[$title]]'.length;
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
    _hide();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        return CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 4),
          child: Align(
            alignment: Alignment.topLeft,
            child: _SuggestionList(
              loading: _loading,
              suggestions: _suggestions,
              highlight: _highlight,
              onPick: _insert,
            ),
          ),
        );
      },
      child: CompositedTransformTarget(
        link: _link,
        child: TextField(
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
  final List<EntryWithDetails> suggestions;
  final int highlight;
  final void Function(EntryWithDetails) onPick;

  const _SuggestionList({
    required this.loading,
    required this.suggestions,
    required this.highlight,
    required this.onPick,
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
                    final item = suggestions[i];
                    final isTask = item.entry.type == 'task';
                    return InkWell(
                      onTap: () => onPick(item),
                      child: Container(
                        color: i == highlight
                            ? MFColors.tealBg
                            : Colors.transparent,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(children: [
                          Icon(
                            isTask
                                ? Icons.task_alt_rounded
                                : Icons.notes_rounded,
                            size: 14,
                            color: isTask ? MFColors.teal : MFColors.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.entry.title ?? item.entry.body,
                              style: const TextStyle(
                                  fontSize: 13, color: MFColors.textPrimary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
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
