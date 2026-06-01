import 'dart:async';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/db/app_database.dart' hide Container;
import '../../data/repositories/entry_repository.dart';
import '../../features/containers/container_provider.dart';
import '../../services/notification_service.dart';
import '../../services/openrouter_service.dart';
import '../../widgets/entry_card.dart';
import '../../widgets/wikilink_text.dart';
import 'entry_detail_provider.dart';

const _storage = FlutterSecureStorage();
const _keyApiKey = 'openrouter_api_key';
const _keyAiModel = 'openrouter_model';

class EntryDetailScreen extends ConsumerStatefulWidget {
  final String entryId;
  const EntryDetailScreen({super.key, required this.entryId});

  @override
  ConsumerState<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends ConsumerState<EntryDetailScreen> {
  bool _isEditing = false;
  bool _showPreview = false; // Markdown-Preview im Edit-Modus
  bool _enriching = false;
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();

  // Wikilink-Autocomplete
  List<EntryWithDetails> _wikilinkSuggestions = [];
  bool _wikilinkLoading = false;
  String? _partialWikilink;
  Timer? _wikilinkDebounce;

  @override
  void initState() {
    super.initState();
    _bodyCtrl.addListener(_checkWikilinkContext);
  }

  @override
  void dispose() {
    _wikilinkDebounce?.cancel();
    _bodyCtrl.removeListener(_checkWikilinkContext);
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _checkWikilinkContext() {
    if (!_isEditing) return;
    final text = _bodyCtrl.text;
    final openIdx = text.lastIndexOf('[[');
    if (openIdx == -1) {
      if (_partialWikilink != null) {
        setState(() { _wikilinkSuggestions = []; _partialWikilink = null; _wikilinkLoading = false; });
      }
      return;
    }
    final afterOpen = text.substring(openIdx + 2);
    if (afterOpen.contains(']]')) {
      if (_partialWikilink != null) {
        setState(() { _wikilinkSuggestions = []; _partialWikilink = null; _wikilinkLoading = false; });
      }
      return;
    }
    final partial = afterOpen.trim();
    if (partial == _partialWikilink) return;
    _partialWikilink = partial;
    setState(() => _wikilinkLoading = true);

    _wikilinkDebounce?.cancel();
    _wikilinkDebounce = Timer(const Duration(milliseconds: 180), () async {
      final results = await ref
          .read(entryRepositoryProvider)
          .search(partial.isEmpty ? '' : partial);
      if (mounted) {
        setState(() {
          // Aktuellen Eintrag ausblenden
          _wikilinkSuggestions = results
              .where((e) => e.entry.id != widget.entryId)
              .take(8)
              .toList();
          _wikilinkLoading = false;
        });
      }
    });
  }

  void _insertWikilink(String title) {
    final text = _bodyCtrl.text;
    final openIdx = text.lastIndexOf('[[');
    if (openIdx == -1) return;
    final before = text.substring(0, openIdx);
    final newText = '$before[[$title]]';
    _bodyCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
    setState(() { _wikilinkSuggestions = []; _partialWikilink = null; });
  }

  String _fmtDate(DateTime dt) =>
      DateFormat('dd.MM.yy HH:mm').format(dt.toLocal());

  Future<void> _pickReminder(BuildContext ctx, String entryId,
      DateTime? current, String label) async {
    // Wenn bereits gesetzt → anbieten zu löschen oder zu ändern
    if (current != null) {
      final action = await showDialog<String>(
        context: ctx,
        builder: (_) => AlertDialog(
          backgroundColor: MFColors.surface,
          title: const Text('Erinnerung',
              style: TextStyle(color: MFColors.textPrimary)),
          content: Text('Gesetzt auf ${_fmtDate(current)}',
              style: const TextStyle(
                  color: MFColors.textSecondary, fontSize: 13)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('Löschen',
                    style: TextStyle(color: Colors.redAccent))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'change'),
                child: const Text('Ändern',
                    style: TextStyle(color: MFColors.teal))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Abbrechen',
                    style: TextStyle(color: MFColors.textMuted))),
          ],
        ),
      );
      if (action == 'delete') {
        await ref.read(entryRepositoryProvider)
            .updateEntry(entryId, clearReminder: true);
        await NotificationService.cancel(
            NotificationService.idFromEntryId(entryId));
        return;
      }
      if (action != 'change') return;
    }

    final now = DateTime.now();
    final date = await showDatePicker(
      context: ctx,
      initialDate: current?.toLocal() ?? now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 2)),
      builder: (_, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: MFColors.teal),
        ),
        child: child!,
      ),
    );
    if (date == null || !ctx.mounted) return;

    final time = await showTimePicker(
      context: ctx,
      initialTime: TimeOfDay.fromDateTime(
          current?.toLocal() ?? now.add(const Duration(hours: 1))),
      builder: (_, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: MFColors.teal),
        ),
        child: child!,
      ),
    );
    if (time == null) return;

    final reminder = DateTime(
        date.year, date.month, date.day, time.hour, time.minute);
    await ref.read(entryRepositoryProvider)
        .updateEntry(entryId, reminderAt: reminder);
    await NotificationService.schedule(
      id: NotificationService.idFromEntryId(entryId),
      title: 'MindFeed Erinnerung',
      body: label.length > 80 ? '${label.substring(0, 80)}…' : label,
      when: reminder,
    );
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Erinnerung gesetzt: ${_fmtDate(reminder)}'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFFF59E0B),
      ));
    }
  }

  Future<void> _enrichWithAi(String entryId, String body, String? title) async {
    final apiKey = await _storage.read(key: _keyApiKey) ?? '';
    if (apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Kein OpenRouter API-Key in Einstellungen gesetzt.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }
    setState(() => _enriching = true);
    try {
      final model = await _storage.read(key: _keyAiModel) ?? '';
      final svc = OpenRouterService(
        apiKey: apiKey,
        model: model.isNotEmpty ? model : OpenRouterService.defaultModel,
      );
      final result = await svc.enrichEntry(body, existingTitle: title);

      // Titel updaten falls KI einen besseren vorschlägt
      if (result.title != null) {
        await ref.read(entryRepositoryProvider).updateEntry(entryId, title: result.title);
      }

      // Tags in Body einfügen (werden auto-geparst)
      if (result.tags.isNotEmpty) {
        final current = (await ref.read(entryRepositoryProvider).getById(entryId))?.entry.body ?? body;
        final tagLine = result.tags.map((t) => '#$t').join(' ');
        await ref.read(entryRepositoryProvider).updateEntry(entryId, body: '$current\n$tagLine');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('KI fertig: ${result.tags.length} Tags${result.title != null ? ", Titel verbessert" : ""}'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: MFColors.teal,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('KI-Fehler: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade900,
        ));
      }
    } finally {
      if (mounted) setState(() => _enriching = false);
    }
  }

  Future<void> _save() async {
    await ref.read(entryRepositoryProvider).updateEntry(
          widget.entryId,
          title: _titleCtrl.text.trim(),
          body: _bodyCtrl.text,
        );
    if (mounted) {
      setState(() {
        _isEditing = false;
        _wikilinkSuggestions = [];
        _partialWikilink = null;
      });
    }
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
              // Home-Button: zurück zum Feed-Root
              IconButton(
                icon: const Icon(Icons.home_outlined,
                    color: MFColors.textSecondary, size: 20),
                tooltip: 'Zum Feed',
                onPressed: () => context.go(AppRoutes.feed),
              ),
              // Erinnerung
              IconButton(
                icon: Icon(
                  entry.reminderAt != null
                      ? Icons.alarm_on_rounded
                      : Icons.alarm_add_outlined,
                  color: entry.reminderAt != null
                      ? const Color(0xFFF59E0B)
                      : MFColors.textSecondary,
                  size: 20,
                ),
                tooltip: entry.reminderAt != null
                    ? 'Erinnerung: ${_fmtDate(entry.reminderAt!)}'
                    : 'Erinnerung setzen',
                onPressed: () => _pickReminder(context, entry.id,
                    entry.reminderAt, entry.title ?? entry.body),
              ),
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
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: Icon(
                          _showPreview
                              ? Icons.edit_outlined
                              : Icons.preview_outlined,
                          size: 20,
                          color: _showPreview
                              ? MFColors.teal
                              : MFColors.textSecondary,
                        ),
                        tooltip: _showPreview ? 'Bearbeiten' : 'Vorschau',
                        onPressed: () =>
                            setState(() => _showPreview = !_showPreview),
                      ),
                      TextButton(
                        onPressed: _save,
                        child: const Text('Speichern',
                            style: TextStyle(
                                color: MFColors.teal,
                                fontWeight: FontWeight.bold))),
                    ])
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
                  if (v == 'ai') await _enrichWithAi(entry.id, entry.body, entry.title);
                  if (v == 'done' || v == 'inbox' || v == 'archive') {
                    await ref.read(entryRepositoryProvider).updateEntry(
                        entry.id, status: v == 'archive' ? 'archived' : v);
                  }
                },
                itemBuilder: (_) => [
                  _popItem('ai',
                    _enriching ? Icons.hourglass_top_rounded : Icons.auto_awesome_outlined,
                    _enriching ? 'KI läuft…' : 'KI anreichern',
                    color: const Color(0xFF8B5CF6)),
                  const PopupMenuDivider(),
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
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Markdown-Vorschau oder Rohtext
                          if (_showPreview)
                            MarkdownBody(
                              data: _bodyCtrl.text.isEmpty
                                  ? '_Noch kein Inhalt_'
                                  : _bodyCtrl.text,
                              styleSheet: MarkdownStyleSheet(
                                p: const TextStyle(
                                    fontSize: 15,
                                    color: MFColors.textPrimary,
                                    height: 1.6),
                                code: const TextStyle(
                                    fontSize: 13,
                                    color: MFColors.teal,
                                    fontFamily: 'monospace',
                                    backgroundColor: MFColors.surfaceAlt),
                                blockquoteDecoration: BoxDecoration(
                                  color: MFColors.surfaceAlt,
                                  borderRadius: BorderRadius.circular(4),
                                  border: const Border(
                                      left: BorderSide(
                                          color: MFColors.teal, width: 3)),
                                ),
                                h1: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: MFColors.textPrimary),
                                h2: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.bold,
                                    color: MFColors.textPrimary),
                                h3: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: MFColors.textPrimary),
                                strong: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: MFColors.textPrimary),
                                em: const TextStyle(
                                    fontStyle: FontStyle.italic,
                                    color: MFColors.textSecondary),
                              ),
                            )
                          else
                            TextField(
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
                          ),
                          // Wikilink-Autocomplete
                          if (_wikilinkSuggestions.isNotEmpty || _wikilinkLoading)
                            Container(
                              margin: const EdgeInsets.only(top: 6),
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                              decoration: BoxDecoration(
                                color: MFColors.surfaceAlt,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: MFColors.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    const Text('Wikilink einfügen:',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: MFColors.textMuted,
                                            fontFamily: 'monospace')),
                                    if (_wikilinkLoading) ...[
                                      const SizedBox(width: 6),
                                      const SizedBox(
                                        width: 8, height: 8,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 1.5,
                                            color: MFColors.teal),
                                      ),
                                    ],
                                  ]),
                                  const SizedBox(height: 4),
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: _wikilinkSuggestions
                                          .map((s) {
                                        final t = s.entry.title ?? 'Unbenannt';
                                        return Padding(
                                          padding: const EdgeInsets.only(right: 6),
                                          child: GestureDetector(
                                            onTap: () => _insertWikilink(t),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 10, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF1E1B4B),
                                                borderRadius:
                                                    BorderRadius.circular(99),
                                                border: Border.all(
                                                    color: const Color(0xFF4338CA),
                                                    width: 0.5),
                                              ),
                                              child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    const Icon(
                                                        Icons.layers_outlined,
                                                        size: 11,
                                                        color: Color(0xFFA78BFA)),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      t.length > 24
                                                          ? '${t.substring(0, 24)}…'
                                                          : t,
                                                      style: const TextStyle(
                                                          fontSize: 11,
                                                          color: Color(0xFFA78BFA),
                                                          fontWeight:
                                                              FontWeight.w500),
                                                    ),
                                                  ]),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      )
                    : WikilinkText(
                        text: entry.body,
                        onTag: (_) {},
                        onWikilink: (title) async {
                          final results = await ref
                              .read(entryRepositoryProvider)
                              .search(title);
                          final found = results
                              .where((e) =>
                                  e.entry.title?.toLowerCase() ==
                                  title.toLowerCase())
                              .firstOrNull;
                          if (found != null && mounted) {
                            context.push(AppRoutes.entryDetailPath(
                                found.entry.id));
                          }
                        },
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

                // Properties — immer sichtbar + eigene hinzufügen
                const SizedBox(height: 16),
                _PropertiesTable(
                    properties: item.properties,
                    entryId: entry.id),

                // Container-Zuweisung
                const SizedBox(height: 16),
                _ContainerAssignment(
                    entryId: entry.id,
                    assignedIds: item.containerIds),

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

                // Backlinks
                _BacklinksSection(entryId: entry.id),
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

  // Nur technische interne Properties verstecken;
  // og_title / og_description werden im Link-Preview angezeigt
  static const _hidden = {'og_image', 'og_title', 'og_description'};

  const _PropertiesTable(
      {required this.properties, required this.entryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = properties
        .where((p) => !_hidden.contains(p.key.toLowerCase()))
        .toList();

    return _Section(
      label: 'Eigenschaften',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (visible.isNotEmpty)
            Container(
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
                      // Löschen-Button
                      GestureDetector(
                        onTap: () async {
                          final allProps = await ref
                              .read(propertyDaoProvider)
                              .watchByEntry(entryId)
                              .first;
                          final remaining = allProps
                              .where((x) => x.id != p.id)
                              .map((x) => EntryPropertiesCompanion(
                                    id: drift.Value(x.id),
                                    entryId: drift.Value(x.entryId),
                                    key: drift.Value(x.key),
                                    value: drift.Value(x.value),
                                    type: drift.Value(x.type),
                                  ))
                              .toList();
                          await ref
                              .read(propertyDaoProvider)
                              .setProperties(entryId, remaining);
                        },
                        child: const Icon(Icons.close,
                            size: 14, color: MFColors.textMuted),
                      ),
                    ]),
                  );
                }).toList(),
              ),
            ),
          const SizedBox(height: 6),
          // Property hinzufügen
          GestureDetector(
            onTap: () => _showAddPropertyDialog(context, ref),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: MFColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: MFColors.border),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 14, color: MFColors.teal),
                  SizedBox(width: 6),
                  Text('Eigenschaft hinzufügen',
                      style: TextStyle(
                          fontSize: 12,
                          color: MFColors.teal,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddPropertyDialog(
      BuildContext context, WidgetRef ref) async {
    final keyCtrl = TextEditingController();
    final valCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Eigenschaft hinzufügen',
            style: TextStyle(color: MFColors.textPrimary, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: keyCtrl,
            autofocus: true,
            style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Name (z.B. Bewertung, Status)',
              labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.border)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.teal)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: valCtrl,
            style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Wert',
              labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.border)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.teal)),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen',
                  style: TextStyle(color: MFColors.textMuted))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Hinzufügen',
                  style: TextStyle(color: MFColors.teal))),
        ],
      ),
    );
    if (ok != true) return;
    final key = keyCtrl.text.trim();
    final val = valCtrl.text.trim();
    if (key.isEmpty) return;

    final allProps =
        await ref.read(propertyDaoProvider).watchByEntry(entryId).first;
    final uuid = 'prop-${DateTime.now().millisecondsSinceEpoch}';
    final newProp = EntryPropertiesCompanion(
      id: drift.Value(uuid),
      entryId: drift.Value(entryId),
      key: drift.Value(key),
      value: drift.Value(val.isEmpty ? null : val),
      type: const drift.Value('string'),
    );
    await ref
        .read(propertyDaoProvider)
        .setProperties(entryId, [...allProps.map((p) => EntryPropertiesCompanion(
              id: drift.Value(p.id),
              entryId: drift.Value(p.entryId),
              key: drift.Value(p.key),
              value: drift.Value(p.value),
              type: drift.Value(p.type),
            )), newProp]);
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

// ─── Backlinks ────────────────────────────────────────────────────────────────
// ─── Container-Zuweisung ──────────────────────────────────────────────────────
class _ContainerAssignment extends ConsumerWidget {
  final String entryId;
  final List<String> assignedIds;
  const _ContainerAssignment(
      {required this.entryId, required this.assignedIds});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final containersAsync = ref.watch(allContainersProvider);

    return _Section(
      label: 'Container',
      child: containersAsync.when(
        loading: () => const SizedBox.shrink(),
        error: (_, __) => const SizedBox.shrink(),
        data: (all) {
          // Nur project/area (keine Smart Hubs)
          final available =
              all.where((c) => c.kind != 'hub').toList();
          final assigned =
              available.where((c) => assignedIds.contains(c.id)).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (assigned.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: assigned.map((c) {
                    Color color;
                    try {
                      color = Color(int.parse(
                          'FF${c.color.replaceFirst('#', '')}',
                          radix: 16));
                    } catch (_) {
                      color = MFColors.teal;
                    }
                    return Container(
                      padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
                      decoration: BoxDecoration(
                        color: color.withAlpha(25),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                            color: color.withAlpha(80), width: 0.5),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(c.name,
                            style: TextStyle(
                                fontSize: 11,
                                color: color,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(width: 2),
                        GestureDetector(
                          onTap: () async {
                            final newIds = assignedIds
                                .where((id) => id != c.id)
                                .toList();
                            await ref
                                .read(entryRepositoryProvider)
                                .updateEntry(entryId,
                                    containerIds: newIds);
                          },
                          child: Icon(Icons.close,
                              size: 13, color: color.withAlpha(160)),
                        ),
                      ]),
                    );
                  }).toList(),
                ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => _showPicker(context, ref, available, assignedIds),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: MFColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: MFColors.border),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 14, color: MFColors.teal),
                      SizedBox(width: 6),
                      Text('Container zuweisen',
                          style: TextStyle(
                              fontSize: 12,
                              color: MFColors.teal,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showPicker(BuildContext context, WidgetRef ref,
      List<dynamic> available, List<String> currentIds) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MFColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 12),
            decoration: BoxDecoration(
              color: MFColors.border,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Container wählen',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: MFColors.textPrimary)),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: available
                  .where((c) => !currentIds.contains(c.id))
                  .map((c) {
                Color color;
                try {
                  color = Color(int.parse(
                      'FF${(c.color as String).replaceFirst('#', '')}',
                      radix: 16));
                } catch (_) {
                  color = MFColors.teal;
                }
                return ListTile(
                  dense: true,
                  leading:
                      Icon(Icons.folder_outlined, size: 18, color: color),
                  title: Text(c.name as String,
                      style: const TextStyle(
                          fontSize: 13, color: MFColors.textPrimary)),
                  subtitle: Text((c.kind as String).toUpperCase(),
                      style: const TextStyle(
                          fontSize: 10, color: MFColors.textMuted)),
                  onTap: () =>
                      Navigator.of(context).pop(c.id as String),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(entryRepositoryProvider).updateEntry(entryId,
        containerIds: [...currentIds, picked]);
  }
}

// ─── Backlinks ────────────────────────────────────────────────────────────────
class _BacklinksSection extends ConsumerWidget {
  final String entryId;
  const _BacklinksSection({required this.entryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(backlinksProvider(entryId));
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (backlinks) {
        if (backlinks.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Row(children: [
              const Icon(Icons.link_rounded, size: 13, color: MFColors.textMuted),
              const SizedBox(width: 6),
              Text(
                'VERKNÜPFT MIT DIESEM EINTRAG'.toUpperCase(),
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: MFColors.textMuted,
                    letterSpacing: 1.2),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: MFColors.tealBg,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '${backlinks.length}',
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: MFColors.teal),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            ...backlinks.map((bl) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: EntryCard(
                    item: bl,
                    compact: true,
                    onTap: () => context.push(
                        AppRoutes.entryDetailPath(bl.entry.id)),
                  ),
                )),
          ],
        );
      },
    );
  }
}
