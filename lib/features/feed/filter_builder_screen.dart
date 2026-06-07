import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../domain/feed_filter.dart';

/// Visueller DNF-Filter-Builder: Gruppen (ODER) mit Bedingungen (UND).
/// Gibt beim Speichern einen FeedFilter zurück (Navigator.pop / Dialog).
class FilterBuilderScreen extends ConsumerStatefulWidget {
  final FeedFilter initial;
  const FilterBuilderScreen({super.key, required this.initial});

  @override
  ConsumerState<FilterBuilderScreen> createState() => _FilterBuilderScreenState();
}

class _FilterBuilderScreenState extends ConsumerState<FilterBuilderScreen> {
  // Arbeitskopie als veränderbare Listen
  late List<List<FilterCondition>> _groups;
  late String _sortField;
  late bool _sortAsc;

  @override
  void initState() {
    super.initState();
    _groups = widget.initial.groups.isEmpty
        ? [<FilterCondition>[]]
        : widget.initial.groups
            .map((g) => List<FilterCondition>.from(g.conditions))
            .toList();
    _sortField = widget.initial.sortField;
    _sortAsc = widget.initial.sortAsc;
  }

  FeedFilter _build() => FeedFilter(
        groups: _groups
            .where((g) => g.isNotEmpty)
            .map((g) => FilterGroup(conditions: g))
            .toList(),
        sortField: _sortField,
        sortAsc: _sortAsc,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        title: const Text('Filter', style: TextStyle(color: MFColors.textPrimary)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: MFColors.textSecondary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_build()),
            child: const Text('Anwenden',
                style: TextStyle(color: MFColors.teal, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          for (int gi = 0; gi < _groups.length; gi++) ...[
            if (gi > 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Text('— ODER —',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold,
                          color: MFColors.teal, letterSpacing: 1.5)),
                ),
              ),
            _groupCard(gi),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => setState(() => _groups.add(<FilterCondition>[])),
            icon: const Icon(Icons.add, size: 16),
            style: OutlinedButton.styleFrom(
              foregroundColor: MFColors.teal,
              side: const BorderSide(color: MFColors.border),
            ),
            label: const Text('ODER-Gruppe hinzufügen'),
          ),
          const SizedBox(height: 24),
          _sortSection(),
        ],
      ),
    );
  }

  Widget _groupCard(int gi) {
    final conds = _groups[gi];
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MFColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int ci = 0; ci < conds.length; ci++) ...[
            if (ci > 0)
              const Padding(
                padding: EdgeInsets.only(left: 4, top: 2, bottom: 2),
                child: Text('UND',
                    style: TextStyle(fontSize: 10, color: MFColors.textMuted,
                        fontWeight: FontWeight.bold)),
              ),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _editCondition(gi, ci),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    decoration: BoxDecoration(
                      color: MFColors.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: MFColors.border),
                    ),
                    child: Text(conditionLabel(conds[ci]),
                        style: const TextStyle(fontSize: 13, color: MFColors.textPrimary)),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: MFColors.textMuted),
                onPressed: () => setState(() {
                  conds.removeAt(ci);
                  if (conds.isEmpty && _groups.length > 1) _groups.removeAt(gi);
                }),
              ),
            ]),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _editCondition(gi, null),
              icon: const Icon(Icons.add, size: 15, color: MFColors.teal),
              label: const Text('Bedingung',
                  style: TextStyle(fontSize: 12, color: MFColors.teal)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editCondition(int gi, int? ci) async {
    final existing = ci != null ? _groups[gi][ci] : null;
    final result = await showModalBottomSheet<FilterCondition>(
      context: context,
      backgroundColor: MFColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _ConditionEditor(initial: existing),
    );
    if (result == null) return;
    setState(() {
      if (ci != null) {
        _groups[gi][ci] = result;
      } else {
        _groups[gi].add(result);
      }
    });
  }

  Widget _sortSection() {
    const fields = [
      ('created', 'Erstellt'),
      ('updated', 'Geändert'),
      ('due', 'Fällig'),
      ('title', 'Titel'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('SORTIERUNG', style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.bold,
            color: MFColors.textMuted, letterSpacing: 1.2)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          ...fields.map((f) => _sortChip(f.$1, f.$2)),
          // Property-Sortierung
          _propSortChip(),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _dirChip('Aufsteigend', true),
          const SizedBox(width: 6),
          _dirChip('Absteigend', false),
        ]),
      ],
    );
  }

  Widget _sortChip(String field, String label) {
    final sel = _sortField == field;
    return GestureDetector(
      onTap: () => setState(() => _sortField = field),
      child: _chip(label, sel),
    );
  }

  Widget _propSortChip() {
    final sel = _sortField.startsWith('prop:');
    final label = sel ? 'Eigenschaft: ${_sortField.substring(5)}' : 'Eigenschaft…';
    return GestureDetector(
      onTap: () async {
        final keys = await ref.read(propertyDaoProvider).getUniqueKeys();
        if (!mounted) return;
        final key = await showModalBottomSheet<String>(
          context: context,
          backgroundColor: MFColors.surface,
          builder: (_) => ListView(
            shrinkWrap: true,
            children: keys.map((k) => ListTile(
              title: Text(k, style: const TextStyle(color: MFColors.textPrimary)),
              onTap: () => Navigator.of(context).pop(k),
            )).toList(),
          ),
        );
        if (key != null) setState(() => _sortField = 'prop:$key');
      },
      child: _chip(label, sel),
    );
  }

  Widget _dirChip(String label, bool asc) {
    final sel = _sortAsc == asc;
    return GestureDetector(
      onTap: () => setState(() => _sortAsc = asc),
      child: _chip(label, sel),
    );
  }

  Widget _chip(String label, bool sel) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? MFColors.tealBg : MFColors.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? MFColors.teal : MFColors.border),
        ),
        child: Text(label, style: TextStyle(
            fontSize: 12,
            color: sel ? MFColors.teal : MFColors.textSecondary,
            fontWeight: sel ? FontWeight.w600 : FontWeight.normal)),
      );
}

// ── Bedingungs-Editor (Bottom-Sheet) ─────────────────────────────────────────

class _ConditionEditor extends ConsumerStatefulWidget {
  final FilterCondition? initial;
  const _ConditionEditor({this.initial});
  @override
  ConsumerState<_ConditionEditor> createState() => _ConditionEditorState();
}

class _ConditionEditorState extends ConsumerState<_ConditionEditor> {
  late FilterField _field;
  late FilterOp _op;
  final _valueCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  DateTime? _date1, _date2;
  List<String> _suggestions = [];

  static const _fieldLabels = {
    FilterField.tag: 'Tag', FilterField.status: 'Status', FilterField.type: 'Typ',
    FilterField.property: 'Eigenschaft', FilterField.pinned: 'Angeheftet',
    FilterField.createdDate: 'Erstellt am', FilterField.dueDate: 'Fällig am',
  };

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _field = i?.field ?? FilterField.tag;
    _op = i?.op ?? FilterOp.is_;
    _valueCtrl.text = i?.value ?? '';
    _keyCtrl.text = i?.key ?? '';
    _date1 = i?.date1;
    _date2 = i?.date2;
    _loadSuggestions();
  }

  @override
  void dispose() {
    _valueCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSuggestions() async {
    List<String> s = [];
    if (_field == FilterField.tag) {
      s = await ref.read(tagDaoProvider).getAllTagNames();
    } else if (_field == FilterField.property && _keyCtrl.text.trim().isNotEmpty) {
      s = await ref.read(propertyDaoProvider).getDistinctValues(_keyCtrl.text.trim());
    } else if (_field == FilterField.status) {
      s = ['inbox', 'active', 'done', 'archived'];
    } else if (_field == FilterField.type) {
      s = ['text', 'link', 'image', 'audio', 'video', 'task'];
    }
    if (mounted) setState(() => _suggestions = s);
  }

  List<FilterOp> get _opsForField {
    switch (_field) {
      case FilterField.tag:
      case FilterField.container:
        return [FilterOp.is_, FilterOp.isNot];
      case FilterField.status:
      case FilterField.type:
        return [FilterOp.is_, FilterOp.isNot];
      case FilterField.pinned:
        return [FilterOp.is_, FilterOp.isNot];
      case FilterField.property:
        return [FilterOp.is_, FilterOp.isNot, FilterOp.contains, FilterOp.notContains,
                FilterOp.exists, FilterOp.notExists];
      case FilterField.createdDate:
      case FilterField.dueDate:
        return [FilterOp.before, FilterOp.after, FilterOp.between];
    }
  }

  static String _opLabel(FilterOp o) => switch (o) {
        FilterOp.is_ => 'ist',
        FilterOp.isNot => 'ist nicht',
        FilterOp.contains => 'enthält',
        FilterOp.notContains => 'enthält nicht',
        FilterOp.exists => 'vorhanden',
        FilterOp.notExists => 'nicht vorhanden',
        FilterOp.before => 'vor',
        FilterOp.after => 'nach',
        FilterOp.between => 'zwischen',
      };

  bool get _isDate => _field == FilterField.createdDate || _field == FilterField.dueDate;
  bool get _needsValue => !_isDate &&
      _field != FilterField.pinned &&
      _op != FilterOp.exists && _op != FilterOp.notExists;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Bedingung', style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: MFColors.textPrimary)),
            const SizedBox(height: 12),
            // Feldauswahl
            Wrap(spacing: 6, runSpacing: 6, children: _fieldLabels.entries.map((e) {
              final sel = _field == e.key;
              return GestureDetector(
                onTap: () => setState(() {
                  _field = e.key;
                  _op = _opsForField.first;
                  _loadSuggestions();
                }),
                child: _miniChip(e.value, sel),
              );
            }).toList()),
            const SizedBox(height: 12),
            // Property-Key
            if (_field == FilterField.property) ...[
              TextField(
                controller: _keyCtrl,
                style: const TextStyle(color: MFColors.textPrimary),
                decoration: _deco('Schlüssel (z.B. Jahr)'),
                onChanged: (_) => _loadSuggestions(),
              ),
              const SizedBox(height: 10),
            ],
            // Operator
            Wrap(spacing: 6, runSpacing: 6, children: _opsForField.map((o) {
              final sel = _op == o;
              return GestureDetector(
                onTap: () => setState(() => _op = o),
                child: _miniChip(_opLabel(o), sel),
              );
            }).toList()),
            const SizedBox(height: 12),
            // Wert / Datum
            if (_isDate) ..._dateInputs() else if (_needsValue) ..._valueInput(),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submit,
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

  List<Widget> _valueInput() => [
        TextField(
          controller: _valueCtrl,
          style: const TextStyle(color: MFColors.textPrimary),
          decoration: _deco('Wert'),
        ),
        if (_suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: _suggestions.take(20).map((s) =>
            GestureDetector(
              onTap: () => setState(() => _valueCtrl.text = s),
              child: _miniChip(s, _valueCtrl.text == s),
            )).toList()),
        ],
      ];

  List<Widget> _dateInputs() {
    Widget dateBtn(String label, DateTime? val, ValueChanged<DateTime> onPick) =>
        GestureDetector(
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: val ?? DateTime.now(),
              firstDate: DateTime(2000), lastDate: DateTime(2100),
              builder: (_, c) => Theme(
                data: ThemeData.dark().copyWith(
                    colorScheme: const ColorScheme.dark(primary: MFColors.teal)),
                child: c!),
            );
            if (d != null) onPick(d);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: MFColors.bg, borderRadius: BorderRadius.circular(8),
              border: Border.all(color: MFColors.border)),
            child: Text(
              val != null ? '$label: ${val.day}.${val.month}.${val.year}' : label,
              style: const TextStyle(fontSize: 13, color: MFColors.textPrimary)),
          ),
        );
    return [
      dateBtn(_op == FilterOp.between ? 'Von' : 'Datum', _date1,
          (d) => setState(() => _date1 = d)),
      if (_op == FilterOp.between) ...[
        const SizedBox(height: 8),
        dateBtn('Bis', _date2, (d) => setState(() => _date2 = d)),
      ],
    ];
  }

  void _submit() {
    Navigator.of(context).pop(FilterCondition(
      field: _field,
      op: _op,
      key: _field == FilterField.property ? _keyCtrl.text.trim() : null,
      value: _needsValue ? _valueCtrl.text.trim() : null,
      date1: _date1,
      date2: _date2,
    ));
  }

  Widget _miniChip(String label, bool sel) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? MFColors.tealBg : MFColors.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? MFColors.teal : MFColors.border),
        ),
        child: Text(label, style: TextStyle(
            fontSize: 12,
            color: sel ? MFColors.teal : MFColors.textSecondary,
            fontWeight: sel ? FontWeight.w600 : FontWeight.normal)),
      );

  InputDecoration _deco(String hint) => InputDecoration(
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
        isDense: true,
      );
}
