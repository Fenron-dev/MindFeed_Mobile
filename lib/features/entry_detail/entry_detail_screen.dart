import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/db/app_database.dart' hide Container;
import '../../widgets/wikilink_text.dart';
import 'entry_detail_provider.dart';

class EntryDetailScreen extends ConsumerStatefulWidget {
  final String entryId;
  const EntryDetailScreen({super.key, required this.entryId});

  @override
  ConsumerState<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends ConsumerState<EntryDetailScreen> {
  bool _isEditing = false;
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(entryRepositoryProvider).updateEntry(
          widget.entryId,
          title: _titleCtrl.text.trim(),
          body: _bodyCtrl.text,
        );
    if (mounted) setState(() => _isEditing = false);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Löschen?',
            style: TextStyle(color: MFColors.textPrimary)),
        content: const Text('Dieser Eintrag wird unwiderruflich gelöscht.',
            style: TextStyle(color: MFColors.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(entryRepositoryProvider).deleteEntry(widget.entryId);
      if (mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(entryDetailProvider(widget.entryId));

    return async.when(
      loading: () => const Scaffold(
        backgroundColor: MFColors.bg,
        body: Center(child: CircularProgressIndicator(color: MFColors.teal)),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: MFColors.bg,
        appBar: AppBar(),
        body: Center(child: Text('$e')),
      ),
      data: (item) {
        if (item == null) {
          return Scaffold(
            backgroundColor: MFColors.bg,
            appBar: AppBar(),
            body: const Center(
                child: Text('Eintrag nicht gefunden',
                    style: TextStyle(color: MFColors.textSecondary))),
          );
        }
        final entry = item.entry;

        // Beim ersten Öffnen des Edit-Modus Felder befüllen
        if (_isEditing &&
            _titleCtrl.text.isEmpty &&
            _bodyCtrl.text.isEmpty) {
          _titleCtrl.text = entry.title ?? '';
          _bodyCtrl.text = entry.body;
        }

        return Scaffold(
          backgroundColor: MFColors.bg,
          appBar: AppBar(
            backgroundColor: MFColors.bg,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back,
                  color: MFColors.textSecondary),
              onPressed: () => context.pop(),
            ),
            actions: [
              // Pin-Toggle
              IconButton(
                icon: Icon(
                  entry.pinned
                      ? Icons.push_pin_rounded
                      : Icons.push_pin_outlined,
                  color: entry.pinned
                      ? MFColors.pinned
                      : MFColors.textSecondary,
                  size: 20,
                ),
                onPressed: () => ref
                    .read(entryRepositoryProvider)
                    .updateEntry(entry.id, pinned: !entry.pinned),
              ),
              // Edit / Save
              _isEditing
                  ? TextButton(
                      onPressed: _save,
                      child: const Text('Speichern',
                          style: TextStyle(
                              color: MFColors.teal,
                              fontWeight: FontWeight.bold)))
                  : IconButton(
                      icon: const Icon(Icons.edit_outlined,
                          color: MFColors.textSecondary, size: 20),
                      onPressed: () => setState(() {
                        _isEditing = true;
                        _titleCtrl.text = entry.title ?? '';
                        _bodyCtrl.text = entry.body;
                      }),
                    ),
              // Mehr-Menü
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert,
                    color: MFColors.textSecondary, size: 20),
                color: MFColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: MFColors.border),
                ),
                onSelected: (v) async {
                  if (v == 'delete') await _delete();
                  if (v == 'done' || v == 'inbox' || v == 'archive') {
                    await ref.read(entryRepositoryProvider).updateEntry(
                        entry.id, status: v == 'archive' ? 'archived' : v);
                  }
                },
                itemBuilder: (_) => [
                  if (entry.status != 'done')
                    _popItem('done', Icons.check_circle_outline, 'Erledigt'),
                  if (entry.status != 'inbox')
                    _popItem('inbox', Icons.inbox_outlined, 'In Inbox'),
                  if (entry.status != 'archived')
                    _popItem('archive', Icons.archive_outlined, 'Archivieren'),
                  const PopupMenuDivider(),
                  _popItem('delete', Icons.delete_outline, 'Löschen',
                      color: Colors.redAccent),
                ],
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Meta-Zeile
                Row(children: [
                  _TypeChip(entry.type),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('dd.MM.yyyy HH:mm')
                        .format(entry.createdAt.toLocal()),
                    style: const TextStyle(
                        fontSize: 11,
                        color: MFColors.textMuted,
                        fontFamily: 'monospace'),
                  ),
                  if (entry.status != 'inbox') ...[
                    const SizedBox(width: 8),
                    _StatusChip(entry.status),
                  ],
                ]),
                const SizedBox(height: 12),

                // Titel
                _isEditing
                    ? TextField(
                        controller: _titleCtrl,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: MFColors.textPrimary),
                        decoration: const InputDecoration(
                            hintText: 'Titel',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            filled: false),
                      )
                    : (entry.title?.isNotEmpty == true
                        ? Text(entry.title!,
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: MFColors.textPrimary))
                        : const SizedBox.shrink()),

                const SizedBox(height: 10),

                // Body
                _isEditing
                    ? TextField(
                        controller: _bodyCtrl,
                        maxLines: null,
                        style: const TextStyle(
                            fontSize: 15,
                            color: MFColors.textPrimary,
                            height: 1.6),
                        decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            filled: false),
                      )
                    : WikilinkText(
                        text: entry.body,
                        onTag: (_) {},
                        onWikilink: (_) {},
                      ),

                // Source-Link-Preview
                if (entry.sourceUrl != null) ...[
                  const SizedBox(height: 12),
                  _LinkPreview(
                      url: entry.sourceUrl!,
                      properties: item.properties),
                ],

                // Tags
                if (item.tags.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _Section(
                    label: 'Tags',
                    child: Wrap(
                      spacing: 6, runSpacing: 4,
                      children:
                          item.tags.map((t) => _TagChip(t)).toList(),
                    ),
                  ),
                ],

                // Properties
                if (item.properties
                    .where((p) => !_PropertiesTable._hidden
                        .contains(p.key.toLowerCase()))
                    .isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _PropertiesTable(
                      properties: item.properties,
                      entryId: entry.id),
                ],

                // Anhänge
                if (item.attachments.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _Section(
                    label: 'Anhänge',
                    child: Column(
                      children: item.attachments
                          .map((a) => _AttachmentTile(a))
                          .toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  PopupMenuItem<String> _popItem(String v, IconData icon, String label,
          {Color color = MFColors.textPrimary}) =>
      PopupMenuItem(
        value: v,
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color, fontSize: 13)),
        ]),
      );
}

// ─── Sub-Widgets ──────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String label;
  final Widget child;
  const _Section({required this.label, required this.child});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: MFColors.textMuted,
                  letterSpacing: 1.2)),
          const SizedBox(height: 8),
          child,
        ],
      );
}

class _TypeChip extends StatelessWidget {
  final String type;
  const _TypeChip(this.type);
  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (type) {
      'link' => (Icons.link_rounded, const Color(0xFF60A5FA), 'Link'),
      'image' =>
        (Icons.image_outlined, const Color(0xFFA78BFA), 'Bild'),
      'audio' => (Icons.mic_outlined, const Color(0xFFC084FC), 'Audio'),
      _ => (Icons.notes_rounded, MFColors.textMuted, 'Text'),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: color),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(
              fontSize: 11, color: color, fontFamily: 'monospace')),
    ]);
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip(this.status);
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'done' => ('Erledigt', MFColors.done),
      'archived' => ('Archiviert', MFColors.archived),
      'active' => ('Aktiv', MFColors.active),
      _ => ('Inbox', MFColors.inbox),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10, color: color, fontWeight: FontWeight.bold)),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String tag;
  const _TagChip(this.tag);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
      );
}

class _LinkPreview extends StatelessWidget {
  final String url;
  final List<EntryProperty> properties;
  const _LinkPreview({required this.url, required this.properties});

  String? _get(String key) =>
      properties.where((p) => p.key.toLowerCase() == key).firstOrNull?.value;

  @override
  Widget build(BuildContext context) {
    final title =
        _get('og_title') ?? Uri.tryParse(url)?.host ?? url;
    final desc = _get('og_description');
    final image = _get('og_image');
    final domain = _get('domain') ?? Uri.tryParse(url)?.host ?? '';

    return GestureDetector(
      onTap: () async {
        final uri = Uri.tryParse(url);
        if (uri != null) await launchUrl(uri);
      },
      child: Container(
        decoration: BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MFColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(children: [
          if (image != null)
            Image.network(image,
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: MFColors.textPrimary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  if (desc != null) ...[
                    const SizedBox(height: 2),
                    Text(desc,
                        style: const TextStyle(
                            fontSize: 11,
                            color: MFColors.textSecondary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.link, size: 11, color: MFColors.textMuted),
                    const SizedBox(width: 4),
                    Text(domain,
                        style: const TextStyle(
                            fontSize: 10, color: MFColors.textMuted)),
                  ]),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PropertiesTable extends ConsumerWidget {
  final List<EntryProperty> properties;
  final String entryId;

  static const _hidden = {
    'og_image', 'og_title', 'og_description', 'domain'
  };

  const _PropertiesTable(
      {required this.properties, required this.entryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = properties
        .where((p) => !_hidden.contains(p.key.toLowerCase()))
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return _Section(
      label: 'Eigenschaften',
      child: Container(
        decoration: BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MFColors.border),
        ),
        child: Column(
          children: visible.asMap().entries.map((e) {
            final last = e.key == visible.length - 1;
            final p = e.value;
            return Container(
              decoration: BoxDecoration(
                border: last
                    ? null
                    : const Border(
                        bottom: BorderSide(color: MFColors.border)),
              ),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 9),
              child: Row(children: [
                SizedBox(
                  width: 110,
                  child: Text(p.key,
                      style: const TextStyle(
                          fontSize: 12,
                          color: MFColors.textMuted,
                          fontFamily: 'monospace')),
                ),
                Expanded(
                  child: _EditablePropValue(
                      prop: p, entryId: entryId),
                ),
              ]),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _EditablePropValue extends ConsumerStatefulWidget {
  final EntryProperty prop;
  final String entryId;
  const _EditablePropValue({required this.prop, required this.entryId});
  @override
  ConsumerState<_EditablePropValue> createState() =>
      _EditablePropValueState();
}

class _EditablePropValueState
    extends ConsumerState<_EditablePropValue> {
  bool _editing = false;
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.prop.value ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final allProps =
        await ref.read(propertyDaoProvider).watchByEntry(widget.entryId).first;
    final updated = allProps
        .map((p) => EntryPropertiesCompanion(
              id: drift.Value(p.id),
              entryId: drift.Value(p.entryId),
              key: drift.Value(p.key),
              value: drift.Value(
                  p.id == widget.prop.id ? _ctrl.text : p.value),
              type: drift.Value(p.type),
            ))
        .toList();
    await ref
        .read(propertyDaoProvider)
        .setProperties(widget.entryId, updated);
    if (mounted) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return Row(children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            style: const TextStyle(
                fontSize: 12, color: MFColors.textPrimary),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              filled: false,
              isDense: true,
            ),
            onSubmitted: (_) => _save(),
          ),
        ),
        GestureDetector(
          onTap: _save,
          child: const Icon(Icons.check, size: 16, color: MFColors.teal),
        ),
      ]);
    }
    return GestureDetector(
      onTap: () => setState(() => _editing = true),
      child: Text(
        widget.prop.value ?? '—',
        style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  final Attachment att;
  const _AttachmentTile(this.att);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(
            att.type == 'image'
                ? Icons.image_outlined
                : att.type == 'audio'
                    ? Icons.mic_outlined
                    : Icons.attach_file,
            size: 18, color: MFColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(att.fileName,
                    style: const TextStyle(
                        fontSize: 13, color: MFColors.textPrimary)),
                if (att.ocrText != null)
                  Text('OCR: ${att.ocrText}',
                      style: const TextStyle(
                          fontSize: 11, color: MFColors.teal),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ]),
      );
}
