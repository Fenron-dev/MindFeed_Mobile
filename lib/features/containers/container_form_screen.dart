import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import 'container_provider.dart';

// ─── Auswahl-Konstanten ────────────────────────────────────────────────────────

const _icons = [
  ('folder',   Icons.folder_outlined,         'Ordner'),
  ('compass',  Icons.explore_outlined,         'Bereich'),
  ('layers',   Icons.layers_outlined,          'Ebenen'),
  ('book',     Icons.menu_book_outlined,       'Buch'),
  ('link',     Icons.link_rounded,             'Links'),
  ('inbox',    Icons.inbox_outlined,           'Inbox'),
  ('star',     Icons.star_outline_rounded,     'Stern'),
  ('code',     Icons.code_rounded,             'Code'),
  ('work',     Icons.work_outline_rounded,     'Arbeit'),
  ('home',     Icons.home_outlined,            'Zuhause'),
  ('health',   Icons.favorite_outline_rounded, 'Gesundheit'),
  ('learn',    Icons.school_outlined,          'Lernen'),
];

const _colors = [
  '#14B8A6', // Teal
  '#3B82F6', // Blau
  '#6366F1', // Indigo
  '#8B5CF6', // Violet
  '#EC4899', // Pink
  '#EF4444', // Rot
  '#F59E0B', // Amber
  '#10B981', // Grün
  '#6B7280', // Grau
  '#F97316', // Orange
];

const _filterStatuses = [
  ('', 'Alle'),
  ('inbox', 'Inbox'),
  ('active', 'Aktiv'),
  ('done', 'Erledigt'),
  ('archived', 'Archiviert'),
];

const _filterTypes = [
  ('', 'Alle'),
  ('text', 'Text'),
  ('link', 'Link'),
  ('image', 'Bild'),
  ('audio', 'Audio'),
];

// ─── Screen ───────────────────────────────────────────────────────────────────

class ContainerFormScreen extends ConsumerStatefulWidget {
  /// null = neu anlegen
  final String? editId;
  final String initialKind;

  const ContainerFormScreen({
    super.key,
    this.editId,
    this.initialKind = 'project',
  });

  bool get isEdit => editId != null;

  @override
  ConsumerState<ContainerFormScreen> createState() =>
      _ContainerFormScreenState();
}

class _ContainerFormScreenState
    extends ConsumerState<ContainerFormScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _filterTagCtrl = TextEditingController();

  late String _kind; // 'project' | 'area' | 'hub'

  @override
  void initState() {
    super.initState();
    _kind = widget.initialKind;
    if (widget.isEdit) _loadExisting();
  }
  String _icon = 'folder';
  String _color = '#14B8A6';
  String _filterStatus = '';
  String _filterType = '';
  bool _saving = false;
  bool _loaded = false;


  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _filterTagCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    final all = await ref.read(allContainersProvider.future);
    final c = all.where((x) => x.id == widget.editId).firstOrNull;
    if (c == null || !mounted) return;
    setState(() {
      _nameCtrl.text = c.name;
      _descCtrl.text = c.description ?? '';
      _kind = c.kind;
      _icon = c.icon;
      _color = c.color;
      _filterTagCtrl.text = c.filterTag ?? '';
      _filterStatus = c.filterStatus ?? '';
      _filterType = c.filterType ?? '';
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Name darf nicht leer sein.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(containerRepositoryProvider);
      if (widget.isEdit) {
        await repo.update(
          widget.editId!,
          name: name,
          description: _descCtrl.text.trim().isEmpty
              ? null
              : _descCtrl.text.trim(),
          icon: _icon,
          color: _color,
          filterTag: _filterTagCtrl.text.trim().isEmpty
              ? null
              : _filterTagCtrl.text.trim(),
          filterStatus: _filterStatus.isEmpty ? null : _filterStatus,
          filterType: _filterType.isEmpty ? null : _filterType,
        );
      } else {
        await repo.create(
          kind: _kind,
          name: name,
          description: _descCtrl.text.trim().isEmpty
              ? null
              : _descCtrl.text.trim(),
          icon: _icon,
          color: _color,
          filterTag: _filterTagCtrl.text.trim().isEmpty
              ? null
              : _filterTagCtrl.text.trim(),
          filterStatus: _filterStatus.isEmpty ? null : _filterStatus,
          filterType: _filterType.isEmpty ? null : _filterType,
        );
      }
      if (mounted) context.pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ─── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.isEdit && !_loaded) {
      return const Scaffold(
        backgroundColor: MFColors.bg,
        body: Center(
            child: CircularProgressIndicator(color: MFColors.teal)),
      );
    }

    final accentColor = _parseColor(_color);

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        leading: IconButton(
          icon: const Icon(Icons.close, color: MFColors.textSecondary),
          onPressed: () => context.pop(),
        ),
        title: Text(
          widget.isEdit ? 'Container bearbeiten' : 'Neuer Container',
          style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: MFColors.textPrimary),
        ),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: MFColors.teal),
                  ))
              : TextButton(
                  onPressed: _save,
                  child: const Text('Speichern',
                      style: TextStyle(
                          color: MFColors.teal,
                          fontWeight: FontWeight.bold)),
                ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Typ (nur beim Anlegen)
            if (!widget.isEdit) ...[
              _Label('Typ'),
              const SizedBox(height: 8),
              Row(children: [
                _KindBtn('project', 'Projekt', Icons.folder_outlined, _kind, (v) => setState(() { _kind = v; if (v == 'hub') _icon = 'layers'; else if (v == 'area') _icon = 'compass'; else _icon = 'folder'; })),
                const SizedBox(width: 8),
                _KindBtn('area', 'Bereich', Icons.explore_outlined, _kind, (v) => setState(() { _kind = v; if (v == 'hub') _icon = 'layers'; else if (v == 'area') _icon = 'compass'; else _icon = 'folder'; })),
                const SizedBox(width: 8),
                _KindBtn('hub', 'Smart Hub', Icons.bolt_outlined, _kind, (v) => setState(() { _kind = v; if (v == 'hub') _icon = 'layers'; else if (v == 'area') _icon = 'compass'; else _icon = 'folder'; })),
              ]),
              const SizedBox(height: 20),
            ],

            // Name
            _Label('Name'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              autofocus: !widget.isEdit,
              style: const TextStyle(
                  fontSize: 15, color: MFColors.textPrimary),
              decoration: InputDecoration(
                hintText: _kind == 'hub'
                    ? 'z.B. Inbox, Links, Anime'
                    : 'z.B. Arbeit, Persönlich',
                hintStyle: const TextStyle(color: MFColors.textMuted),
                filled: true,
                fillColor: MFColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: MFColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: MFColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: accentColor),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Beschreibung
            _Label('Beschreibung (optional)'),
            const SizedBox(height: 8),
            TextField(
              controller: _descCtrl,
              maxLines: 2,
              style: const TextStyle(
                  fontSize: 14, color: MFColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Wofür ist dieser Container?',
                hintStyle: const TextStyle(
                    color: MFColors.textMuted, fontSize: 13),
                filled: true,
                fillColor: MFColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: MFColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: MFColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: accentColor),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Icon
            _Label('Icon'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _icons.map((ic) {
                final selected = _icon == ic.$1;
                return GestureDetector(
                  onTap: () => setState(() => _icon = ic.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: selected
                          ? accentColor.withAlpha(40)
                          : MFColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected ? accentColor : MFColors.border,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Icon(ic.$2,
                        size: 20,
                        color: selected ? accentColor : MFColors.textMuted),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // Farbe
            _Label('Farbe'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _colors.map((hex) {
                final c = _parseColor(hex);
                final selected = _color == hex;
                return GestureDetector(
                  onTap: () => setState(() => _color = hex),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: selected
                          ? [BoxShadow(color: c.withAlpha(120), blurRadius: 6)]
                          : null,
                    ),
                    child: selected
                        ? const Icon(Icons.check_rounded,
                            size: 16, color: Colors.white)
                        : null,
                  ),
                );
              }).toList(),
            ),

            // Smart Hub Filter
            if (_kind == 'hub') ...[
              const SizedBox(height: 24),
              _Label('Automatischer Filter'),
              const SizedBox(height: 6),
              const Text(
                'Smart Hubs zeigen automatisch Einträge die einem '
                'oder mehreren Kriterien entsprechen.',
                style: TextStyle(fontSize: 12, color: MFColors.textMuted),
              ),
              const SizedBox(height: 12),

              // filterTag
              TextField(
                controller: _filterTagCtrl,
                style: const TextStyle(
                    fontSize: 14, color: MFColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Tag (z.B. arbeit)',
                  labelStyle: const TextStyle(
                      color: MFColors.textMuted, fontSize: 12),
                  prefixText: '#',
                  prefixStyle: const TextStyle(color: MFColors.teal),
                  filled: true,
                  fillColor: MFColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: MFColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: MFColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: accentColor),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // filterStatus
              _Label('Status'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _filterStatuses.map((s) {
                  final selected = _filterStatus == s.$1;
                  return GestureDetector(
                    onTap: () =>
                        setState(() => _filterStatus = s.$1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected
                            ? accentColor.withAlpha(35)
                            : MFColors.surface,
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color:
                              selected ? accentColor : MFColors.border,
                        ),
                      ),
                      child: Text(s.$2,
                          style: TextStyle(
                              fontSize: 12,
                              color: selected
                                  ? accentColor
                                  : MFColors.textSecondary,
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),

              // filterType
              _Label('Typ'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _filterTypes.map((t) {
                  final selected = _filterType == t.$1;
                  return GestureDetector(
                    onTap: () =>
                        setState(() => _filterType = t.$1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected
                            ? accentColor.withAlpha(35)
                            : MFColors.surface,
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color:
                              selected ? accentColor : MFColors.border,
                        ),
                      ),
                      child: Text(t.$2,
                          style: TextStyle(
                              fontSize: 12,
                              color: selected
                                  ? accentColor
                                  : MFColors.textSecondary,
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal)),
                    ),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

Color _parseColor(String hex) {
  try {
    return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));
  } catch (_) {
    return MFColors.teal;
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: MFColors.textMuted,
          letterSpacing: 1.1,
        ),
      );
}

class _KindBtn extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final String selected;
  final ValueChanged<String> onTap;

  const _KindBtn(
      this.value, this.label, this.icon, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) {
    final active = value == selected;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? MFColors.tealBg : MFColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: active ? MFColors.teal : MFColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 18,
                  color: active ? MFColors.teal : MFColors.textMuted),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: active
                          ? MFColors.teal
                          : MFColors.textSecondary,
                      fontWeight: active
                          ? FontWeight.bold
                          : FontWeight.normal)),
            ],
          ),
        ),
      ),
    );
  }
}
