import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/db/app_database.dart' hide Container;
import '../../domain/prop_type.dart';

/// Obsidian-artiger Eigenschaften-Block: kompakte, volle-Breite Liste von
/// Schlüssel:Wert-Zeilen inkl. einer Tags-Zeile (technisch im Tag-System).
/// Im Lese-Modus nur Toggle/Rating/Links interaktiv; im Bearbeiten-Modus
/// volle Bearbeitung mit großen mobiltauglichen Feldern + Autovervollständigung.
class PropertiesBlock extends ConsumerStatefulWidget {
  final String entryId;
  final List<EntryProperty> properties;
  final List<String> tags;
  final bool editable;

  /// Wenn gesetzt, wird Tag-Hinzufügen/-Entfernen über diese Callbacks
  /// abgewickelt (z.B. direkt im Body-Editor), statt über das Repository.
  /// So bleibt der Tag erhalten, wenn beim Speichern die Tags aus dem Body
  /// neu geparst werden. Null → bisheriges Repository-Verhalten.
  final void Function(String tag)? onAddTag;
  final void Function(String tag)? onRemoveTag;

  const PropertiesBlock({
    super.key,
    required this.entryId,
    required this.properties,
    required this.tags,
    this.editable = true,
    this.onAddTag,
    this.onRemoveTag,
  });

  @override
  ConsumerState<PropertiesBlock> createState() => _PropertiesBlockState();
}

class _PropertiesBlockState extends ConsumerState<PropertiesBlock> {
  bool _collapsed = false;

  // Technische/intern gerenderte Keys ausblenden
  static const _hidden = {
    'og_image', 'og_title', 'og_description', 'domain', 'genres',
    'media_type', 'url_author', 'score', '_template', 'parent_entry_id',
    'cover', 'cover_image', 'bild', '_transcript',
  };
  static const _hiddenPrefixes = ['bgg_', 'github_', 'youtube_', 'anilist_',
    'vgg_', 'rpg_', 'task_'];

  static bool _isHidden(String key) {
    final k = key.toLowerCase();
    if (_hidden.contains(k)) return true;
    return _hiddenPrefixes.any(k.startsWith);
  }

  @override
  Widget build(BuildContext context) {
    final visible =
        widget.properties.where((p) => !_isHidden(p.key)).toList();
    final count = visible.length + (widget.tags.isNotEmpty ? 1 : 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _collapsed = !_collapsed),
          behavior: HitTestBehavior.opaque,
          child: Row(children: [
            const Text('EIGENSCHAFTEN',
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.bold,
                    color: MFColors.textMuted, letterSpacing: 1.2)),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: MFColors.tealBg, borderRadius: BorderRadius.circular(99)),
                child: Text('$count',
                    style: const TextStyle(
                        fontSize: 9, color: MFColors.teal, fontWeight: FontWeight.bold)),
              ),
            ],
            const Spacer(),
            Icon(_collapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded,
                size: 16, color: MFColors.textMuted),
          ]),
        ),
        if (!_collapsed) ...[
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MFColors.border),
            ),
            child: Column(
              children: [
                // Tags-Zeile (immer zuerst)
                _TagsRow(
                    entryId: widget.entryId,
                    tags: widget.tags,
                    editable: widget.editable,
                    onAddTag: widget.onAddTag,
                    onRemoveTag: widget.onRemoveTag),
                for (final p in visible) ...[
                  const Divider(height: 1, color: MFColors.border),
                  _PropRow(
                      key: ValueKey(p.id),
                      prop: p,
                      entryId: widget.entryId,
                      editable: widget.editable),
                ],
              ],
            ),
          ),
          if (widget.editable) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _showAddProperty(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    decoration: BoxDecoration(
                      color: MFColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: MFColors.border),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.add, size: 14, color: MFColors.teal),
                      SizedBox(width: 6),
                      Text('Eigenschaft hinzufügen',
                          style: TextStyle(
                              fontSize: 12, color: MFColors.teal,
                              fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
              ),
            ]),
          ],
        ],
      ],
    );
  }

  Future<void> _showAddProperty(BuildContext context) async {
    final keys = await ref.read(propertyDaoProvider).getUniqueKeys();
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: MFColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _AddPropertySheet(
        entryId: widget.entryId,
        existingKeys: keys,
      ),
    );
  }
}

// ── Tags-Zeile ────────────────────────────────────────────────────────────────

class _TagsRow extends ConsumerWidget {
  final String entryId;
  final List<String> tags;
  final bool editable;
  final void Function(String tag)? onAddTag;
  final void Function(String tag)? onRemoveTag;
  const _TagsRow({
    required this.entryId,
    required this.tags,
    required this.editable,
    this.onAddTag,
    this.onRemoveTag,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tags.isEmpty && !editable) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 96,
            child: Row(children: [
              Icon(Icons.label_outlined, size: 13, color: Color(0xFF14B8A6)),
              SizedBox(width: 6),
              Text('Tags', style: TextStyle(fontSize: 12, color: MFColors.textMuted)),
            ]),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 6, runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...tags.map((t) => _TagChip(
                      tag: t,
                      onLongPress: () => _showRenameTag(context, ref, t),
                      onRemove: editable
                          ? () => onRemoveTag != null
                              ? onRemoveTag!(t)
                              : ref.read(entryRepositoryProvider)
                                  .removeTag(entryId, t)
                          : null,
                    )),
                if (editable)
                  _AddTagButton(
                      entryId: entryId, existing: tags, onAdd: onAddTag),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String tag;
  final VoidCallback? onRemove;
  final VoidCallback? onLongPress;
  const _TagChip({required this.tag, this.onRemove, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onLongPress,
      child: _chip(),
    );
  }

  Widget _chip() {
    return Container(
      padding: EdgeInsets.fromLTRB(8, 3, onRemove != null ? 4 : 8, 3),
      decoration: BoxDecoration(
        color: MFColors.tealBg,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: const Color(0xFF0F766E), width: 0.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('#$tag',
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: MFColors.teal, fontFamily: 'monospace')),
        if (onRemove != null) ...[
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(Icons.close, size: 12, color: MFColors.teal),
          ),
        ],
      ]),
    );
  }
}

/// Tag in allen Einträgen umbenennen (z.B. `ai_x` → `ai/x` für Hierarchie).
Future<void> _showRenameTag(
    BuildContext context, WidgetRef ref, String oldTag) async {
  final ctrl = TextEditingController(text: oldTag);
  final newName = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: MFColors.surface,
      title: const Text('Tag umbenennen',
          style: TextStyle(color: MFColors.textPrimary, fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: MFColors.textPrimary),
          decoration: const InputDecoration(
            prefixText: '#',
            labelText: 'Neuer Name',
            helperText: '„/" erzeugt Unter-Tags, z.B. ai/bildgeneration',
            helperStyle: TextStyle(color: MFColors.textMuted, fontSize: 11),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Gilt für alle Einträge mit diesem Tag.',
            style: TextStyle(color: MFColors.textMuted, fontSize: 11)),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Umbenennen'),
        ),
      ],
    ),
  );
  if (newName == null || newName.isEmpty || newName == oldTag) return;
  final n = await ref.read(entryRepositoryProvider).renameTag(oldTag, newName);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Tag in $n Eintrag/Einträgen umbenannt.'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

class _AddTagButton extends ConsumerStatefulWidget {
  final String entryId;
  final List<String> existing;
  final void Function(String tag)? onAdd;
  const _AddTagButton(
      {required this.entryId, required this.existing, this.onAdd});
  @override
  ConsumerState<_AddTagButton> createState() => _AddTagButtonState();
}

class _AddTagButtonState extends ConsumerState<_AddTagButton> {
  Future<void> _open() async {
    final all = await ref.read(tagDaoProvider).getAllTagNames();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MFColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ValuePickerSheet(
        title: 'Tag hinzufügen',
        suggestions: all.where((t) => !widget.existing.contains(t)).toList(),
        hint: 'Tag (z.B. buch/sachbuch)',
        prefix: '#',
      ),
    );
    if (picked != null && picked.trim().isNotEmpty) {
      if (widget.onAdd != null) {
        widget.onAdd!(picked);
      } else {
        await ref.read(entryRepositoryProvider).addTag(widget.entryId, picked);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _open,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: MFColors.border),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add, size: 12, color: MFColors.textMuted),
          SizedBox(width: 2),
          Text('Tag', style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
        ]),
      ),
    );
  }
}

// ── Property-Zeile ────────────────────────────────────────────────────────────

class _PropRow extends ConsumerWidget {
  final EntryProperty prop;
  final String entryId;
  final bool editable;
  const _PropRow({super.key, required this.prop, required this.entryId, required this.editable});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = PropType.fromString(prop.type);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            child: Row(children: [
              Icon(type.icon, size: 13, color: type.color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(prop.key,
                    style: const TextStyle(fontSize: 12, color: MFColors.textMuted),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _PropValue(prop: prop, entryId: entryId, editable: editable),
          ),
          if (editable)
            GestureDetector(
              onTap: () => ref.read(entryRepositoryProvider)
                  .deletePropertyById(entryId, prop.id),
              child: const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.close, size: 13, color: MFColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _PropValue extends ConsumerStatefulWidget {
  final EntryProperty prop;
  final String entryId;
  final bool editable;
  const _PropValue({required this.prop, required this.entryId, required this.editable});
  @override
  ConsumerState<_PropValue> createState() => _PropValueState();
}

class _PropValueState extends ConsumerState<_PropValue> {
  Future<void> _save(String? v) =>
      ref.read(entryRepositoryProvider)
          .setPropertyValue(widget.entryId, widget.prop.id, v);

  @override
  Widget build(BuildContext context) {
    final type = PropType.fromString(widget.prop.type);
    final val = widget.prop.value ?? '';
    switch (type) {
      case PropType.boolean:
        return Align(
          alignment: Alignment.centerLeft,
          child: Switch(
            value: val == 'true',
            activeThumbColor: MFColors.teal,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => _save(v ? 'true' : 'false'),
          ),
        );
      case PropType.rating:
        final current = int.tryParse(val) ?? 0;
        return Row(mainAxisSize: MainAxisSize.min, children: List.generate(5, (i) {
          final filled = i < current;
          return GestureDetector(
            onTap: () => _save((i + 1).toString()),
            child: Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(filled ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 22, color: filled ? const Color(0xFFF59E0B) : MFColors.textMuted),
            ),
          );
        }));
      case PropType.url:
        return Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final uri = Uri.tryParse(val);
                if (uri != null && val.isNotEmpty) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: Text(val.isEmpty ? '—' : val,
                  style: TextStyle(
                      fontSize: 13,
                      color: val.isEmpty ? MFColors.textMuted : const Color(0xFF60A5FA),
                      decoration: val.isEmpty ? null : TextDecoration.underline,
                      decorationColor: const Color(0xFF60A5FA)),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          if (widget.editable)
            _EditIcon(onTap: () => _openEditor(type)),
        ]);
      case PropType.date:
        final parsed = DateTime.tryParse(val);
        final label = parsed != null
            ? '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year}'
            : '—';
        return GestureDetector(
          onTap: widget.editable
              ? () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: parsed ?? DateTime.now(),
                    firstDate: DateTime(2000), lastDate: DateTime(2100),
                    builder: (_, c) => Theme(
                        data: ThemeData.dark().copyWith(
                            colorScheme: const ColorScheme.dark(primary: MFColors.teal)),
                        child: c!),
                  );
                  if (picked != null) {
                    await _save(picked.toIso8601String().substring(0, 10));
                  }
                }
              : null,
          child: Row(children: [
            Text(label, style: const TextStyle(fontSize: 13, color: MFColors.textPrimary)),
            if (widget.editable) ...[
              const SizedBox(width: 6),
              const Icon(Icons.edit_calendar_outlined, size: 13, color: MFColors.textMuted),
            ],
          ]),
        );
      default:
        // text / number / select / tags-string
        // Lange Werte gekürzt anzeigen (max. 5 Zeilen) → Antippen öffnet die
        // Vollansicht. Gespeichert wird immer der volle Text.
        final isLong = val.length > 140 || '\n'.allMatches(val).length >= 4;
        return Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: isLong
                  ? () => _showFullValue(context, widget.prop.key, val)
                  : null,
              child: Text(val.isEmpty ? '—' : val,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: val.isEmpty
                          ? MFColors.textMuted
                          : MFColors.textPrimary)),
            ),
          ),
          if (isLong)
            IconButton(
              icon: const Icon(Icons.open_in_full_rounded,
                  size: 15, color: MFColors.textMuted),
              tooltip: 'Voll anzeigen',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showFullValue(context, widget.prop.key, val),
            ),
          if (widget.editable) _EditIcon(onTap: () => _openEditor(type)),
        ]);
    }
  }

  /// Zeigt einen langen Property-Wert formatiert in voller Länge.
  void _showFullValue(BuildContext context, String title, String value) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: MFColors.surface,
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.82,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(children: [
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            color: MFColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: MFColors.textMuted),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ]),
              ),
              const Divider(height: 1, color: MFColors.border),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    value,
                    style: const TextStyle(
                        color: MFColors.textSecondary,
                        fontSize: 14,
                        height: 1.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openEditor(PropType type) async {
    final suggestions =
        await ref.read(propertyDaoProvider).getDistinctValues(widget.prop.key);
    if (!mounted) return;
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MFColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ValuePickerSheet(
        title: widget.prop.key,
        suggestions: suggestions,
        initial: widget.prop.value ?? '',
        hint: 'Wert eingeben…',
        numeric: type == PropType.number,
      ),
    );
    if (result != null) await _save(result);
  }
}

class _EditIcon extends StatelessWidget {
  final VoidCallback onTap;
  const _EditIcon({required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.only(left: 6),
          child: Icon(Icons.edit_outlined, size: 13, color: MFColors.textMuted),
        ),
      );
}

// ── Wert-Eingabe-Sheet (groß, mobiltauglich, mit Vorschlägen) ─────────────────

class _ValuePickerSheet extends StatefulWidget {
  final String title;
  final List<String> suggestions;
  final String initial;
  final String hint;
  final bool numeric;
  final String prefix;
  const _ValuePickerSheet({
    required this.title,
    required this.suggestions,
    this.initial = '',
    this.hint = '',
    this.numeric = false,
    this.prefix = '',
  });
  @override
  State<_ValuePickerSheet> createState() => _ValuePickerSheetState();
}

class _ValuePickerSheetState extends State<_ValuePickerSheet> {
  late final TextEditingController _ctrl;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
    _query = widget.initial;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.suggestions
        .where((s) => _query.isEmpty || s.toLowerCase().contains(_query.toLowerCase()))
        .take(20)
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: MFColors.textPrimary)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: widget.numeric
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            style: const TextStyle(fontSize: 16, color: MFColors.textPrimary),
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: const TextStyle(color: MFColors.textMuted),
              prefixText: widget.prefix.isEmpty ? null : widget.prefix,
              prefixStyle: const TextStyle(color: MFColors.teal, fontSize: 16),
              filled: true, fillColor: MFColors.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: MFColors.border)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: MFColors.border)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: MFColors.teal)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
            onChanged: (v) => setState(() => _query = v),
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
          if (filtered.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text('Vorschläge',
                style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: filtered.map((s) => GestureDetector(
                onTap: () => Navigator.of(context).pop(s),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: MFColors.bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: MFColors.border),
                  ),
                  child: Text(s,
                      style: const TextStyle(fontSize: 13, color: MFColors.textPrimary)),
                ),
              )).toList(),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
              style: FilledButton.styleFrom(
                  backgroundColor: MFColors.teal, foregroundColor: MFColors.bg,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: const Text('Übernehmen'),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

// ── Eigenschaft-hinzufügen-Sheet ──────────────────────────────────────────────

class _AddPropertySheet extends ConsumerStatefulWidget {
  final String entryId;
  final List<String> existingKeys;
  const _AddPropertySheet({required this.entryId, required this.existingKeys});
  @override
  ConsumerState<_AddPropertySheet> createState() => _AddPropertySheetState();
}

class _AddPropertySheetState extends ConsumerState<_AddPropertySheet> {
  final _keyCtrl = TextEditingController();
  final _valCtrl = TextEditingController();
  PropType _type = PropType.text;
  String _keyQuery = '';
  bool _typeManuallySet = false;

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valCtrl.dispose();
    super.dispose();
  }

  /// Wenn der eingegebene Key bereits existiert, dessen Typ automatisch
  /// vorbelegen (sofern der Nutzer den Typ nicht selbst geändert hat).
  Future<void> _prefillTypeForKey(String key) async {
    if (_typeManuallySet || key.trim().isEmpty) return;
    final existing = await ref.read(propertyDaoProvider).getTypeForKey(key.trim());
    if (!mounted || existing == null) return;
    final t = PropType.fromString(existing);
    if (t != _type) setState(() => _type = t);
  }

  Future<void> _submit() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) return;
    String? value = _valCtrl.text.trim();
    if (_type == PropType.boolean) value = 'false';
    if (_type == PropType.rating && value.isEmpty) value = '0';
    await ref.read(entryRepositoryProvider)
        .addProperty(widget.entryId, key, value.isEmpty ? null : value, _type.value);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Mobile: weniger Vorschläge, damit die Tastatur nicht zu viel verdrängt
    final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    final keySuggestions = widget.existingKeys
        .where((k) => _keyQuery.isEmpty || k.toLowerCase().contains(_keyQuery.toLowerCase()))
        .take(isDesktop ? 12 : 6)
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Eigenschaft hinzufügen',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: MFColors.textPrimary)),
          const SizedBox(height: 14),
          // Typ-Auswahl
          Wrap(
            spacing: 6, runSpacing: 6,
            children: PropType.values.where((t) => t != PropType.tags).map((t) {
              final sel = _type == t;
              return GestureDetector(
                onTap: () => setState(() { _type = t; _typeManuallySet = true; }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? t.color.withValues(alpha: 0.2) : MFColors.bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: sel ? t.color : MFColors.border),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(t.icon, size: 13, color: sel ? t.color : MFColors.textMuted),
                    const SizedBox(width: 5),
                    Text(t.label,
                        style: TextStyle(
                            fontSize: 12,
                            color: sel ? t.color : MFColors.textSecondary,
                            fontWeight: sel ? FontWeight.w600 : FontWeight.normal)),
                  ]),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          // Schlüssel mit Vorschlägen
          TextField(
            controller: _keyCtrl,
            autofocus: true,
            style: const TextStyle(fontSize: 16, color: MFColors.textPrimary),
            decoration: _inputDeco('Schlüssel (z.B. Autor, Jahr…)'),
            onChanged: (v) { setState(() => _keyQuery = v); _prefillTypeForKey(v); },
          ),
          if (keySuggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: keySuggestions.map((k) => GestureDetector(
                onTap: () {
                  setState(() { _keyCtrl.text = k; _keyQuery = k; });
                  _prefillTypeForKey(k);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: MFColors.bg, borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: MFColors.border)),
                  child: Text(k, style: const TextStyle(fontSize: 12, color: MFColors.textSecondary)),
                ),
              )).toList(),
            ),
          ],
          // Wert (für Text/Zahl/URL/Select)
          if (_type != PropType.boolean &&
              _type != PropType.rating &&
              _type != PropType.date) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _valCtrl,
              keyboardType: _type == PropType.number
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
              style: const TextStyle(fontSize: 16, color: MFColors.textPrimary),
              decoration: _inputDeco('Wert (optional)'),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                  backgroundColor: MFColors.teal, foregroundColor: MFColors.bg,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: const Text('Hinzufügen'),
            ),
          ),
        ],
      ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: MFColors.textMuted),
        filled: true, fillColor: MFColors.bg,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: MFColors.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: MFColors.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: MFColors.teal)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      );
}
