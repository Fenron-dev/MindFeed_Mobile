import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../domain/prop_type.dart';
import '../../services/app_settings.dart';
import '../../data/db/app_database.dart' hide Container;
import '../../data/repositories/entry_repository.dart';
import '../../features/containers/container_provider.dart';
import '../../services/notification_service.dart';
import '../../services/openrouter_service.dart';
import '../../widgets/app_shell.dart' show navigateToCapture, navigateToEntry;
import '../../widgets/entry_card.dart';
import '../../widgets/wikilink_text.dart';
import 'entry_detail_provider.dart';

const _keyApiKey = 'openrouter_api_key';
const _keyAiModel = 'openrouter_model';

class EntryDetailScreen extends ConsumerStatefulWidget {
  final String entryId;
  /// Desktop: Callback statt context.pop() für den Zurück-Pfeil.
  final VoidCallback? onBack;
  const EntryDetailScreen({super.key, required this.entryId, this.onBack});

  @override
  ConsumerState<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends ConsumerState<EntryDetailScreen> {
  bool _isEditing = false;
  bool _showPreview = false;
  bool _enriching = false;
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  // ScrollController bleibt über Stream-Re-Emits hinweg erhalten → Position springt nicht
  final _scrollCtrl = ScrollController();

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
    _scrollCtrl.dispose();
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
    final apiKey = await secureRead(_keyApiKey) ?? '';
    if (apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Kein OpenRouter API-Key in Einstellungen gesetzt.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }

    // ── Feld-Auswahl-Dialog ───────────────────────────────────────────────
    if (!mounted) return;
    final opts = await showDialog<_EnrichOptions>(
      context: context,
      builder: (_) => const _EnrichOptionsDialog(),
    );
    if (opts == null || !mounted) return; // Abgebrochen

    setState(() => _enriching = true);
    try {
      // Zusatzkontext aus gespeicherten Properties (z.B. AniList-Genres)
      final props = await ref.read(propertyDaoProvider).watchByEntry(entryId).first;
      final genresProp = props.where((p) => p.key.toLowerCase() == 'genres' ||
          p.key.toLowerCase() == 'genre').firstOrNull;
      final genresText = genresProp?.value;

      // AniList-Beschreibung als Kontext
      final descProp = props.where((p) => p.key.toLowerCase() == 'og_description').firstOrNull;
      final extraParts = <String>[
        if (genresText?.isNotEmpty == true) 'Genres: $genresText',
        if (descProp?.value?.isNotEmpty == true) descProp!.value!,
      ];

      final model = await secureRead(_keyAiModel) ?? '';
      final tempStr = await secureRead('openrouter_temperature');
      final tokStr = await secureRead('openrouter_max_tokens');
      final svc = OpenRouterService(
        apiKey: apiKey,
        model: model.isNotEmpty ? model : OpenRouterService.defaultModel,
        temperature: double.tryParse(tempStr ?? '') ?? 0.3,
        maxTokens: int.tryParse(tokStr ?? '') ?? 400,
      );

      final result = await svc.enrichEntry(
        opts.enrichBody ? body : '',
        existingTitle: title,
        extraContext: extraParts.isNotEmpty ? extraParts.join('\n') : null,
      );

      int changes = 0;

      // Titel verbessern
      if (opts.enrichTitle && result.title != null) {
        await ref.read(entryRepositoryProvider).updateEntry(entryId, title: result.title);
        changes++;
      }

      // Tags hinzufügen
      if (opts.enrichTags && result.tags.isNotEmpty) {
        // Wenn Genres vorhanden: Genres als Tags verwenden statt KI-Tags
        final tagsToAdd = (genresText?.isNotEmpty == true && body.trim().isEmpty)
            ? genresText!.split(',').map((g) => g.trim().toLowerCase().replaceAll(' ', '-')).where((g) => g.isNotEmpty).toList()
            : result.tags;
        if (tagsToAdd.isNotEmpty) {
          final current = (await ref.read(entryRepositoryProvider).getById(entryId))?.entry.body ?? body;
          final tagLine = tagsToAdd.map((t) => '#$t').join(' ');
          // Bestehende Tag-Zeile nicht doppeln
          if (!current.contains(tagLine)) {
            await ref.read(entryRepositoryProvider).updateEntry(entryId, body: '$current\n$tagLine');
            changes++;
          }
        }
      }

      // Zusammenfassung als Property speichern
      if (opts.enrichSummary && result.summary?.isNotEmpty == true) {
        final existing = await ref.read(propertyDaoProvider).watchByEntry(entryId).first;
        final existingKeys = existing.map((p) => p.key.toLowerCase()).toSet();
        if (!existingKeys.contains('zusammenfassung') && !existingKeys.contains('summary')) {
          await ref.read(propertyDaoProvider).setProperties(entryId, [
            ...existing.map((p) => EntryPropertiesCompanion(
              id: drift.Value(p.id), entryId: drift.Value(p.entryId),
              key: drift.Value(p.key), value: drift.Value(p.value), type: drift.Value(p.type),
            )),
            EntryPropertiesCompanion(
              id: drift.Value('prop-${DateTime.now().microsecondsSinceEpoch}-summary'),
              entryId: drift.Value(entryId),
              key: const drift.Value('Zusammenfassung'),
              value: drift.Value(result.summary),
              type: const drift.Value('text'),
            ),
          ]);
          await ref.read(entryRepositoryProvider).updateEntry(entryId);
          changes++;
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(changes > 0 ? 'KI fertig: $changes Felder aktualisiert' : 'Keine Änderungen nötig'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: MFColors.teal,
        ));
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg.length > 150 ? '${msg.substring(0, 150)}…' : msg),
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

    final item = async.valueOrNull;

    // Nur bei initialem Laden (kein vorheriger Wert) Spinner/Fehler zeigen.
    // Bei Daten-Updates (Stream re-emits) bleibt der ScrollController im
    // Widget-Baum → Scroll-Position springt nicht.
    if (item == null) {
      if (async.isLoading) {
        return const Scaffold(
          backgroundColor: MFColors.bg,
          body: Center(child: CircularProgressIndicator(color: MFColors.teal)),
        );
      }
      if (async.hasError) {
        return Scaffold(
          backgroundColor: MFColors.bg,
          appBar: AppBar(),
          body: Center(child: Text('${async.error}')),
        );
      }
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
              onPressed: widget.onBack ?? () => context.pop(),
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
            controller: _scrollCtrl,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Cover-Bild / Medien-Header
                _MediaHeader(
                    properties: item.properties,
                    attachments: item.attachments),

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
                            navigateToEntry(context, ref, found.entry.id);
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

                // Sub-Notizen zu diesem Eintrag
                _SubNotesSection(parentEntryId: entry.id),

                // Backlinks
                _BacklinksSection(entryId: entry.id),
              ],
            ),
          ),
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
                  if (desc != null && desc.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(desc,
                        style: const TextStyle(
                            fontSize: 12,
                            color: MFColors.textSecondary,
                            height: 1.4),
                        maxLines: 5,
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

class _PropertiesTable extends ConsumerStatefulWidget {
  final List<EntryProperty> properties;
  final String entryId;

  const _PropertiesTable({required this.properties, required this.entryId});

  @override
  ConsumerState<_PropertiesTable> createState() => _PropertiesTableState();
}

class _PropertiesTableState extends ConsumerState<_PropertiesTable> {
  bool _collapsed = false;

  // Technische interne Properties verstecken
  static const _hidden = {
    'og_image', 'og_title', 'og_description',
    'anilist_season', 'anilist_total_seasons',
    'genres', 'media_type', 'domain', 'url_author', '_template', 'parent_entry_id',
  };
  static const _hiddenPrefixes = [
    'bgg_', 'github_', 'youtube_',
  ];

  static bool _isHidden(String key) {
    final k = key.toLowerCase();
    if (_hidden.contains(k)) return true;
    for (final p in _hiddenPrefixes) {
      if (k.startsWith(p)) return true;
    }
    return false;
  }

  String get entryId => widget.entryId;
  List<EntryProperty> get properties => widget.properties;

  @override
  Widget build(BuildContext context) {
    final visible = properties
        .where((p) => !_isHidden(p.key.toLowerCase()))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Kopfzeile mit Collapse-Toggle
        GestureDetector(
          onTap: () => setState(() => _collapsed = !_collapsed),
          child: Row(children: [
            const Text('EIGENSCHAFTEN',
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.bold,
                    color: MFColors.textMuted, letterSpacing: 1.2)),
            if (visible.isNotEmpty) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: MFColors.tealBg,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text('${visible.length}',
                    style: const TextStyle(
                        fontSize: 9, color: MFColors.teal, fontWeight: FontWeight.bold)),
              ),
            ],
            const Spacer(),
            Icon(
              _collapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded,
              size: 16, color: MFColors.textMuted,
            ),
          ]),
        ),
        const SizedBox(height: 8),
        if (!_collapsed)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          if (visible.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: MFColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: MFColors.border),
              ),
              // Vertikales Layout: Label oben, Wert darunter — 2-spaltig per Wrap
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Wrap(
                  children: visible.map((p) {
                    final propType = PropType.fromString(p.type);
                    return Stack(
                      children: [
                        Container(
                          width: (MediaQuery.sizeOf(context).width - 72) / 2,
                          padding: const EdgeInsets.fromLTRB(10, 8, 28, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Label mit Icon
                              Row(children: [
                                Icon(propType.icon, size: 10, color: propType.color),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    p.key.toUpperCase(),
                                    style: const TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: MFColors.textMuted,
                                        letterSpacing: 0.8),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 3),
                              // Wert
                              _EditablePropValue(prop: p, entryId: entryId),
                            ],
                          ),
                        ),
                        // Löschen-Button (oben rechts)
                        Positioned(
                          top: 4, right: 4,
                          child: GestureDetector(
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
                                size: 12, color: MFColors.textMuted),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          const SizedBox(height: 6),
          Row(children: [
            // Eigenschaft hinzufügen
            Expanded(
              child: GestureDetector(
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
            ),
            const SizedBox(width: 8),
            // Template anwenden
            _TemplateApplyButton(entryId: entryId, existingProps: properties),
          ]),
        ],
        ),  // Ende if (!_collapsed)
      ],
    );
  }

  Future<void> _showAddPropertyDialog(
      BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<_NewPropData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddPropertySheet(entryId: entryId),
    );
    if (result == null) return;

    final allProps =
        await ref.read(propertyDaoProvider).watchByEntry(entryId).first;
    final uuid = 'prop-${DateTime.now().millisecondsSinceEpoch}';
    final newProp = EntryPropertiesCompanion(
      id: drift.Value(uuid),
      entryId: drift.Value(entryId),
      key: drift.Value(result.key),
      value: drift.Value(result.value.isEmpty ? null : result.value),
      type: drift.Value(result.type),
    );
    await ref.read(propertyDaoProvider).setProperties(entryId, [
      ...allProps.map((p) => EntryPropertiesCompanion(
            id: drift.Value(p.id),
            entryId: drift.Value(p.entryId),
            key: drift.Value(p.key),
            value: drift.Value(p.value),
            type: drift.Value(p.type),
          )),
      newProp,
    ]);
  }
}

class _EditablePropValue extends ConsumerStatefulWidget {
  final EntryProperty prop;
  final String entryId;
  const _EditablePropValue({required this.prop, required this.entryId});
  @override
  ConsumerState<_EditablePropValue> createState() => _EditablePropValueState();
}

class _EditablePropValueState extends ConsumerState<_EditablePropValue> {
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

  Future<void> _saveValue(String newValue) async {
    final allProps =
        await ref.read(propertyDaoProvider).watchByEntry(widget.entryId).first;
    final updated = allProps
        .map((p) => EntryPropertiesCompanion(
              id: drift.Value(p.id),
              entryId: drift.Value(p.entryId),
              key: drift.Value(p.key),
              value: drift.Value(p.id == widget.prop.id ? newValue : p.value),
              type: drift.Value(p.type),
            ))
        .toList();
    await ref.read(propertyDaoProvider).setProperties(widget.entryId, updated);
    if (mounted) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final type = PropType.fromString(widget.prop.type);
    return switch (type) {
      PropType.boolean  => _buildBoolean(),
      PropType.date     => _buildDate(context),
      PropType.rating   => _buildRating(),
      PropType.url      => _buildUrl(context),
      PropType.tags     => _buildTags(),
      _                 => _buildText(type),
    };
  }

  // ── boolean ────────────────────────────────────────────────────────────────
  Widget _buildBoolean() {
    final isOn = widget.prop.value == 'true';
    return Switch(
      value: isOn,
      activeThumbColor: MFColors.teal,
      onChanged: (v) => _saveValue(v ? 'true' : 'false'),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  // ── date ───────────────────────────────────────────────────────────────────
  Widget _buildDate(BuildContext context) {
    DateTime? parsed;
    if (widget.prop.value != null && widget.prop.value!.isNotEmpty) {
      parsed = DateTime.tryParse(widget.prop.value!);
    }
    final label = parsed != null
        ? '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year}'
        : '—';
    return GestureDetector(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: parsed?.toLocal() ?? now,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
          builder: (_, child) => Theme(
            data: ThemeData.dark().copyWith(
              colorScheme: const ColorScheme.dark(primary: MFColors.teal),
            ),
            child: child!,
          ),
        );
        if (picked != null) {
          await _saveValue(picked.toIso8601String().substring(0, 10));
        }
      },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: MFColors.textPrimary)),
        const SizedBox(width: 4),
        const Icon(Icons.edit_calendar_outlined, size: 12, color: MFColors.textMuted),
      ]),
    );
  }

  // ── rating (1–5 Sterne) ────────────────────────────────────────────────────
  Widget _buildRating() {
    final current = int.tryParse(widget.prop.value ?? '') ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final filled = i < current;
        return GestureDetector(
          onTap: () => _saveValue((i + 1).toString()),
          child: Icon(
            filled ? Icons.star_rounded : Icons.star_outline_rounded,
            size: 18,
            color: filled ? const Color(0xFFF59E0B) : MFColors.textMuted,
          ),
        );
      }),
    );
  }

  // ── url ────────────────────────────────────────────────────────────────────
  Widget _buildUrl(BuildContext context) {
    if (_editing) {
      return Row(children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
            decoration: const InputDecoration(
              border: InputBorder.none, contentPadding: EdgeInsets.zero,
              filled: false, isDense: true,
            ),
            onSubmitted: (v) => _saveValue(v),
          ),
        ),
        GestureDetector(
          onTap: () => _saveValue(_ctrl.text),
          child: const Icon(Icons.check, size: 16, color: MFColors.teal),
        ),
      ]);
    }
    final url = widget.prop.value ?? '';
    return Row(children: [
      Expanded(
        child: GestureDetector(
          onTap: () async {
            final uri = Uri.tryParse(url);
            if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
          },
          child: Text(
            url.isEmpty ? '—' : url,
            style: TextStyle(
              fontSize: 12,
              color: url.isEmpty ? MFColors.textMuted : const Color(0xFF60A5FA),
              decoration: url.isEmpty ? null : TextDecoration.underline,
              decorationColor: const Color(0xFF60A5FA),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      GestureDetector(
        onTap: () => setState(() { _ctrl.text = url; _editing = true; }),
        child: const Icon(Icons.edit_outlined, size: 13, color: MFColors.textMuted),
      ),
    ]);
  }

  // ── tags (komma-getrennte Liste als Chips) ─────────────────────────────────
  Widget _buildTags() {
    if (_editing) {
      return Row(children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'tag1, tag2, tag3',
              hintStyle: TextStyle(color: MFColors.textMuted, fontSize: 11),
              border: InputBorder.none, contentPadding: EdgeInsets.zero,
              filled: false, isDense: true,
            ),
            onSubmitted: (v) => _saveValue(v),
          ),
        ),
        GestureDetector(
          onTap: () => _saveValue(_ctrl.text),
          child: const Icon(Icons.check, size: 16, color: MFColors.teal),
        ),
      ]);
    }
    final raw = widget.prop.value ?? '';
    final chips = raw.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    if (chips.isEmpty) {
      return GestureDetector(
        onTap: () => setState(() { _ctrl.text = raw; _editing = true; }),
        child: const Text('—', style: TextStyle(fontSize: 12, color: MFColors.textMuted)),
      );
    }
    return GestureDetector(
      onTap: () => setState(() { _ctrl.text = raw; _editing = true; }),
      child: Wrap(
        spacing: 4, runSpacing: 2,
        children: chips.map((t) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: MFColors.tealBg,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: const Color(0xFF0F766E), width: 0.5),
          ),
          child: Text(t, style: const TextStyle(fontSize: 10, color: MFColors.teal, fontFamily: 'monospace')),
        )).toList(),
      ),
    );
  }

  // ── text / number / select ─────────────────────────────────────────────────
  Widget _buildText(PropType type) {
    if (_editing) {
      return Row(children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: type == PropType.number
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
            decoration: const InputDecoration(
              border: InputBorder.none, contentPadding: EdgeInsets.zero,
              filled: false, isDense: true,
            ),
            onSubmitted: (v) => _saveValue(v),
          ),
        ),
        GestureDetector(
          onTap: () => _saveValue(_ctrl.text),
          child: const Icon(Icons.check, size: 16, color: MFColors.teal),
        ),
      ]);
    }
    return GestureDetector(
      onTap: () => setState(() { _ctrl.text = widget.prop.value ?? ''; _editing = true; }),
      child: Text(
        widget.prop.value ?? '—',
        style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
      ),
    );
  }
}

// ─── Template anwenden ────────────────────────────────────────────────────────

class _TemplateApplyButton extends ConsumerWidget {
  final String entryId;
  final List<EntryProperty> existingProps;
  const _TemplateApplyButton({required this.entryId, required this.existingProps});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(templatesProvider);
    if (templates.isEmpty) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => _showApplySheet(context, ref, templates),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: MFColors.border),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_awesome_outlined, size: 13, color: Color(0xFF8B5CF6)),
          SizedBox(width: 5),
          Text('Template', style: TextStyle(
              fontSize: 12, color: Color(0xFF8B5CF6), fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }

  Future<void> _showApplySheet(
      BuildContext ctx, WidgetRef ref, List<PropTemplate> templates) async {
    final result = await showModalBottomSheet<(PropTemplate, bool)>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TemplatePickSheet(templates: templates),
    );
    if (result == null || !ctx.mounted) return;
    final (template, overwrite) = result;
    await _apply(ref, template, overwrite);
  }

  Future<void> _apply(WidgetRef ref, PropTemplate template, bool overwrite) async {
    final dao = ref.read(propertyDaoProvider);
    final current = await dao.watchByEntry(entryId).first;

    final List<EntryPropertiesCompanion> newProps;
    if (overwrite) {
      // Nur nicht-interne Properties behalten, dann Template-Felder hinzufügen
      final systemKeys = {'og_image', 'og_title', 'og_description', 'domain',
          'genres', 'score', 'media_type'};
      final kept = current
          .where((p) => systemKeys.contains(p.key.toLowerCase()))
          .map((p) => EntryPropertiesCompanion(
                id: drift.Value(p.id), entryId: drift.Value(p.entryId),
                key: drift.Value(p.key), value: drift.Value(p.value),
                type: drift.Value(p.type),
              ))
          .toList();
      newProps = [
        ...kept,
        EntryPropertiesCompanion(
          id: drift.Value('prop-${DateTime.now().microsecondsSinceEpoch}-_tpl'),
          entryId: drift.Value(entryId),
          key: const drift.Value('_template'),
          value: drift.Value(template.id),
          type: const drift.Value('text'),
        ),
        ...template.fields.map((f) => EntryPropertiesCompanion(
              id: drift.Value('prop-${DateTime.now().microsecondsSinceEpoch}-${f.key}'),
              entryId: drift.Value(entryId),
              key: drift.Value(f.key),
              value: drift.Value(f.defaultValue.isEmpty ? null : f.defaultValue),
              type: drift.Value(f.type),
            )),
      ];
    } else {
      // Ergänzen: nur Felder hinzufügen die noch nicht existieren
      final existingKeys = current.map((p) => p.key.toLowerCase()).toSet();
      final toAdd = template.fields
          .where((f) => !existingKeys.contains(f.key.toLowerCase()))
          .map((f) => EntryPropertiesCompanion(
                id: drift.Value('prop-${DateTime.now().microsecondsSinceEpoch}-${f.key}'),
                entryId: drift.Value(entryId),
                key: drift.Value(f.key),
                value: drift.Value(f.defaultValue.isEmpty ? null : f.defaultValue),
                type: drift.Value(f.type),
              ))
          .toList();
      newProps = [
        // Bestehende Props behalten, altes _template-Marker entfernen
        ...current
            .where((p) => p.key != '_template')
            .map((p) => EntryPropertiesCompanion(
                  id: drift.Value(p.id), entryId: drift.Value(p.entryId),
                  key: drift.Value(p.key), value: drift.Value(p.value),
                  type: drift.Value(p.type),
                )),
        EntryPropertiesCompanion(
          id: drift.Value('prop-${DateTime.now().microsecondsSinceEpoch}-_tpl'),
          entryId: drift.Value(entryId),
          key: const drift.Value('_template'),
          value: drift.Value(template.id),
          type: const drift.Value('text'),
        ),
        ...toAdd,
      ];
    }
    await dao.setProperties(entryId, newProps);
    // watchById hört nur auf entries-Tabelle → Entry berühren um Stream zu triggern
    await ref.read(entryRepositoryProvider).updateEntry(entryId);
  }
}

class _TemplatePickSheet extends StatefulWidget {
  final List<PropTemplate> templates;
  const _TemplatePickSheet({required this.templates});

  @override
  State<_TemplatePickSheet> createState() => _TemplatePickSheetState();
}

class _TemplatePickSheetState extends State<_TemplatePickSheet> {
  PropTemplate? _selected;
  bool _overwrite = false;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: const BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: MFColors.border,
                borderRadius: BorderRadius.circular(99)),
          )),
          const Align(alignment: Alignment.centerLeft,
            child: Text('TEMPLATE ANWENDEN', style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold,
                color: MFColors.textMuted, letterSpacing: 1.2))),
          const SizedBox(height: 12),

          // Template-Liste
          ...widget.templates.map((t) {
            final active = _selected?.id == t.id;
            return GestureDetector(
              onTap: () => setState(() => _selected = t),
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: active ? MFColors.tealBg : MFColors.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: active ? MFColors.teal : MFColors.border),
                ),
                child: Row(children: [
                  Text(t.emoji, style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.name, style: TextStyle(
                        fontSize: 13, color: active ? MFColors.teal : MFColors.textPrimary,
                        fontWeight: FontWeight.w600)),
                    Text('${t.fields.map((f) => f.key).join(', ')}',
                        style: const TextStyle(fontSize: 10, color: MFColors.textMuted),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ])),
                  if (active)
                    const Icon(Icons.check_circle, size: 18, color: MFColors.teal),
                ]),
              ),
            );
          }),

          const SizedBox(height: 12),

          // Modus
          Container(
            decoration: BoxDecoration(
              color: MFColors.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: MFColors.border),
            ),
            child: Column(children: [
              _ModeRow(
                label: 'Ergänzen',
                sub: 'Nur fehlende Felder hinzufügen',
                active: !_overwrite,
                onTap: () => setState(() => _overwrite = false),
              ),
              const Divider(height: 1, color: MFColors.border),
              _ModeRow(
                label: 'Überschreiben',
                sub: 'Bestehende Felder ersetzen',
                active: _overwrite,
                onTap: () => setState(() => _overwrite = true),
              ),
            ]),
          ),

          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: FilledButton(
            onPressed: _selected == null ? null : () =>
                Navigator.pop(context, (_selected!, _overwrite)),
            style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
            child: const Text('Anwenden',
                style: TextStyle(color: MFColors.bg, fontWeight: FontWeight.bold)),
          )),
        ]),
      );
}

class _ModeRow extends StatelessWidget {
  final String label, sub;
  final bool active;
  final VoidCallback onTap;
  const _ModeRow({required this.label, required this.sub,
      required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Icon(active ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 16, color: active ? MFColors.teal : MFColors.textMuted),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(
                  fontSize: 12, color: active ? MFColors.teal : MFColors.textPrimary,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
              Text(sub, style: const TextStyle(fontSize: 10, color: MFColors.textMuted)),
            ])),
          ]),
        ),
      );
}

// ─── Result-Datenklasse für das Add-Sheet ─────────────────────────────────────

class _NewPropData {
  final String key;
  final String value;
  final String type;
  const _NewPropData({required this.key, required this.value, required this.type});
}

// ─── Bottom Sheet: Eigenschaft hinzufügen ─────────────────────────────────────

class _AddPropertySheet extends StatefulWidget {
  final String entryId;
  const _AddPropertySheet({required this.entryId});

  @override
  State<_AddPropertySheet> createState() => _AddPropertySheetState();
}

class _AddPropertySheetState extends State<_AddPropertySheet> {
  PropType _selectedType = PropType.text;
  final _keyCtrl = TextEditingController();
  final _valCtrl = TextEditingController();
  bool _boolValue = false;
  DateTime? _dateValue;
  int _ratingValue = 0;

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valCtrl.dispose();
    super.dispose();
  }

  String _getEncodedValue() {
    return switch (_selectedType) {
      PropType.boolean => _boolValue ? 'true' : 'false',
      PropType.date    => _dateValue?.toIso8601String().substring(0, 10) ?? '',
      PropType.rating  => _ratingValue > 0 ? _ratingValue.toString() : '',
      _                => _valCtrl.text.trim(),
    };
  }

  void _submit() {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) return;
    Navigator.pop(context, _NewPropData(
      key: key,
      value: _getEncodedValue(),
      type: _selectedType.value,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 24 + bottom),
      decoration: const BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Griff
          Center(
            child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: MFColors.border,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          const Text('EIGENSCHAFT HINZUFÜGEN',
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.bold,
                  color: MFColors.textMuted, letterSpacing: 1.2)),
          const SizedBox(height: 14),

          // Typ-Auswahl
          const Text('Typ', style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6, runSpacing: 6,
            children: PropType.values.map((t) {
              final active = t == _selectedType;
              return GestureDetector(
                onTap: () => setState(() => _selectedType = t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: active ? t.color.withAlpha(38) : MFColors.bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: active ? t.color : MFColors.border,
                      width: active ? 1.5 : 1,
                    ),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(t.icon, size: 13, color: active ? t.color : MFColors.textMuted),
                    const SizedBox(width: 5),
                    Text(t.label,
                        style: TextStyle(
                            fontSize: 11,
                            color: active ? t.color : MFColors.textMuted,
                            fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
                  ]),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // Name
          TextField(
            controller: _keyCtrl,
            autofocus: true,
            style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Name der Eigenschaft',
              labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.border)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: MFColors.teal)),
            ),
          ),
          const SizedBox(height: 14),

          // Wert je nach Typ
          _buildValueInput(),
          const SizedBox(height: 20),

          // Speichern
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
              child: const Text('Hinzufügen',
                  style: TextStyle(color: MFColors.bg, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildValueInput() {
    switch (_selectedType) {
      case PropType.boolean:
        return Row(children: [
          const Text('Wert:', style: TextStyle(fontSize: 12, color: MFColors.textMuted)),
          const Spacer(),
          Switch(
            value: _boolValue,
            activeThumbColor: MFColors.teal,
            onChanged: (v) => setState(() => _boolValue = v),
          ),
        ]);

      case PropType.date:
        final label = _dateValue != null
            ? '${_dateValue!.day.toString().padLeft(2,'0')}.${_dateValue!.month.toString().padLeft(2,'0')}.${_dateValue!.year}'
            : 'Datum wählen…';
        return OutlinedButton.icon(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _dateValue ?? DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              builder: (_, child) => Theme(
                data: ThemeData.dark().copyWith(
                  colorScheme: const ColorScheme.dark(primary: MFColors.teal),
                ),
                child: child!,
              ),
            );
            if (picked != null) setState(() => _dateValue = picked);
          },
          icon: const Icon(Icons.calendar_today_outlined, size: 15),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: _dateValue != null ? MFColors.teal : MFColors.textMuted,
            side: const BorderSide(color: MFColors.border),
          ),
        );

      case PropType.rating:
        return Row(children: [
          const Text('Bewertung:', style: TextStyle(fontSize: 12, color: MFColors.textMuted)),
          const SizedBox(width: 12),
          ...List.generate(5, (i) => GestureDetector(
            onTap: () => setState(() => _ratingValue = i + 1),
            child: Icon(
              i < _ratingValue ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 24,
              color: i < _ratingValue ? const Color(0xFFF59E0B) : MFColors.textMuted,
            ),
          )),
          if (_ratingValue > 0) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _ratingValue = 0),
              child: const Icon(Icons.close, size: 14, color: MFColors.textMuted),
            ),
          ],
        ]);

      case PropType.url:
        return TextField(
          controller: _valCtrl,
          keyboardType: TextInputType.url,
          style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
          decoration: const InputDecoration(
            labelText: 'https://…',
            labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.border)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.teal)),
          ),
        );

      case PropType.number:
        return TextField(
          controller: _valCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
          decoration: const InputDecoration(
            labelText: 'Zahl',
            labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.border)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.teal)),
          ),
        );

      case PropType.tags:
        return TextField(
          controller: _valCtrl,
          style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
          decoration: const InputDecoration(
            labelText: 'tag1, tag2, tag3 (komma-getrennt)',
            labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.border)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.teal)),
          ),
        );

      case PropType.select:
        return TextField(
          controller: _valCtrl,
          style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
          decoration: const InputDecoration(
            labelText: 'Ausgewählter Wert',
            labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.border)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.teal)),
          ),
        );

      default: // text
        return TextField(
          controller: _valCtrl,
          style: const TextStyle(color: MFColors.textPrimary, fontSize: 14),
          decoration: const InputDecoration(
            labelText: 'Wert',
            labelStyle: TextStyle(color: MFColors.textMuted, fontSize: 12),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.border)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: MFColors.teal)),
          ),
        );
    }
  }
}

class _AttachmentTile extends StatelessWidget {
  final Attachment att;
  const _AttachmentTile(this.att);
  @override
  Widget build(BuildContext context) {
    if (att.type == 'audio') return _AudioTile(att);
    if (att.type == 'image') return _ImageTile(att);
    if (att.type == 'video') return _VideoTile(att);
    return _FileTile(att);
  }
}

// ─── Video-Vorschau ───────────────────────────────────────────────────────────
class _VideoTile extends StatelessWidget {
  final Attachment att;
  const _VideoTile(this.att);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GestureDetector(
          onTap: () async {
            final uri = Uri.file(att.localPath);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: MFColors.border),
            ),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.play_circle_outline_rounded,
                    color: Color(0xFFF59E0B), size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(att.fileName,
                      style: const TextStyle(fontSize: 13, color: MFColors.textPrimary),
                      overflow: TextOverflow.ellipsis),
                  Text('Video · Zum Abspielen tippen',
                      style: const TextStyle(fontSize: 10, color: MFColors.textMuted)),
                ],
              )),
              const Icon(Icons.open_in_new_rounded, size: 14, color: MFColors.textMuted),
            ]),
          ),
        ),
      );
}

// ─── Sonstige Datei ───────────────────────────────────────────────────────────
class _FileTile extends StatelessWidget {
  final Attachment att;
  const _FileTile(this.att);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: GestureDetector(
          onTap: () async {
            final uri = Uri.file(att.localPath);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: MFColors.border),
            ),
            child: Row(children: [
              const Icon(Icons.insert_drive_file_outlined,
                  size: 20, color: MFColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(child: Text(att.fileName,
                  style: const TextStyle(fontSize: 13, color: MFColors.textPrimary),
                  overflow: TextOverflow.ellipsis)),
              const Icon(Icons.open_in_new_rounded, size: 13, color: MFColors.textMuted),
            ]),
          ),
        ),
      );
}

// ─── Bild-Vorschau ────────────────────────────────────────────────────────────
class _ImageTile extends StatelessWidget {
  final Attachment att;
  const _ImageTile(this.att);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _FullscreenImageViewer(
                path: att.localPath, isLocal: true),
          )),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(att.localPath),
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                height: 60,
                color: MFColors.surface,
                child: const Icon(Icons.broken_image_outlined,
                    color: MFColors.textMuted),
              ),
            ),
          ),
        ),
      );
}

// ─── Audio-Player ─────────────────────────────────────────────────────────────
class _AudioTile extends StatefulWidget {
  final Attachment att;
  const _AudioTile(this.att);
  @override
  State<_AudioTile> createState() => _AudioTileState();
}

class _AudioTileState extends State<_AudioTile> {
  final _player = AudioPlayer();
  PlayerState _state = PlayerState.stopped;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    });
    // Initiale Dauer aus DB
    if (widget.att.durationMs != null) {
      _dur = Duration(milliseconds: widget.att.durationMs!);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = _state == PlayerState.playing;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MFColors.border),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () async {
            if (isPlaying) {
              await _player.pause();
            } else {
              await _player.play(DeviceFileSource(widget.att.localPath));
            }
          },
          child: Container(
            width: 36, height: 36,
            decoration: const BoxDecoration(
              color: MFColors.teal, shape: BoxShape.circle),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white, size: 22,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.att.fileName,
                  style: const TextStyle(
                      fontSize: 12, color: MFColors.textPrimary),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                  activeTrackColor: MFColors.teal,
                  inactiveTrackColor: MFColors.border,
                  thumbColor: MFColors.teal,
                ),
                child: Slider(
                  value: _dur.inSeconds > 0
                      ? _pos.inSeconds.toDouble().clamp(0, _dur.inSeconds.toDouble())
                      : 0,
                  min: 0,
                  max: _dur.inSeconds > 0 ? _dur.inSeconds.toDouble() : 1,
                  onChanged: (v) =>
                      _player.seek(Duration(seconds: v.toInt())),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Text('${_fmt(_pos)} / ${_fmt(_dur)}',
            style: const TextStyle(
                fontSize: 10, color: MFColors.textMuted, fontFamily: 'monospace')),
      ]),
    );
  }
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
                    onTap: () => navigateToEntry(context, ref, bl.entry.id),
                  ),
                )),
          ],
        );
      },
    );
  }
}

// ─── Enrichment-Optionen ──────────────────────────────────────────────────────

class _EnrichOptions {
  final bool enrichTitle;
  final bool enrichTags;
  final bool enrichSummary;
  final bool enrichBody;

  const _EnrichOptions({
    required this.enrichTitle,
    required this.enrichTags,
    required this.enrichSummary,
    required this.enrichBody,
  });
}

class _EnrichOptionsDialog extends StatefulWidget {
  const _EnrichOptionsDialog();

  @override
  State<_EnrichOptionsDialog> createState() => _EnrichOptionsDialogState();
}

class _EnrichOptionsDialogState extends State<_EnrichOptionsDialog> {
  bool _title = false;
  bool _tags = true;
  bool _summary = false;
  bool _body = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: MFColors.surface,
      title: const Text('KI-Anreicherung',
          style: TextStyle(color: MFColors.textPrimary, fontSize: 15)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Welche Felder soll die KI bearbeiten?',
            style: TextStyle(fontSize: 12, color: MFColors.textSecondary),
          ),
          const SizedBox(height: 12),
          _CheckTile('Tags generieren', _tags, (v) => setState(() => _tags = v!)),
          _CheckTile('Titel verbessern', _title, (v) => setState(() => _title = v!)),
          _CheckTile('Zusammenfassung als Property', _summary, (v) => setState(() => _summary = v!)),
          _CheckTile('Text des Eintrags einbeziehen', _body, (v) => setState(() => _body = v!)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen', style: TextStyle(color: MFColors.textMuted)),
        ),
        FilledButton(
          onPressed: (_tags || _title || _summary)
              ? () => Navigator.pop(
                    context,
                    _EnrichOptions(
                      enrichTitle: _title,
                      enrichTags: _tags,
                      enrichSummary: _summary,
                      enrichBody: _body,
                    ),
                  )
              : null,
          style: FilledButton.styleFrom(
              backgroundColor: MFColors.teal, foregroundColor: MFColors.bg),
          child: const Text('Anreichern'),
        ),
      ],
    );
  }
}

class _CheckTile extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool?> onChanged;

  const _CheckTile(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: MFColors.teal,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 13, color: MFColors.textPrimary)),
          ]),
        ),
      );
}

// ─── Sub-Notizen zu einem Eintrag ────────────────────────────────────────────

class _SubNotesSection extends ConsumerWidget {
  final String parentEntryId;
  const _SubNotesSection({required this.parentEntryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subNotesAsync = ref.watch(_subNotesProvider(parentEntryId));
    return subNotesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (notes) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          // Header
          Row(children: [
            const Icon(Icons.sticky_note_2_outlined,
                size: 13, color: MFColors.textMuted),
            const SizedBox(width: 6),
            const Text('NOTIZEN',
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.bold,
                    color: MFColors.textMuted, letterSpacing: 1.2)),
            if (notes.isNotEmpty) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: MFColors.tealBg,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text('${notes.length}',
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.bold,
                        color: MFColors.teal)),
              ),
            ],
            const Spacer(),
            GestureDetector(
              onTap: () => navigateToCapture(
                  context, ref, parentEntryId: parentEntryId),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: MFColors.tealBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF0F766E)),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_rounded, size: 13, color: MFColors.teal),
                  SizedBox(width: 4),
                  Text('Notiz',
                      style: TextStyle(
                          fontSize: 11, color: MFColors.teal,
                          fontWeight: FontWeight.w500)),
                ]),
              ),
            ),
          ]),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...notes.map((note) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: EntryCard(
                    item: note,
                    compact: true,
                    onTap: () => navigateToEntry(context, ref, note.entry.id),
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

// Provider für Sub-Notizen
final _subNotesProvider =
    StreamProvider.autoDispose.family<List<EntryWithDetails>, String>(
  (ref, parentEntryId) {
    ref.keepAlive();
    return ref.watch(entryRepositoryProvider).watchSubNotes(parentEntryId);
  },
);

// ─── Medien-Header (Cover/Bild oben) ─────────────────────────────────────────

class _MediaHeader extends StatelessWidget {
  final List<EntryProperty> properties;
  final List<Attachment> attachments;

  const _MediaHeader({required this.properties, required this.attachments});

  String? get _coverUrl => properties
      .where((p) => const {
            'og_image',
            'cover_image',
            'cover',
            'bild',
          }.contains(p.key.toLowerCase()))
      .firstOrNull
      ?.value;

  String? get _season => properties
      .where((p) => p.key.toLowerCase() == 'anilist_season')
      .firstOrNull
      ?.value;

  String? get _totalSeasons => properties
      .where((p) => p.key.toLowerCase() == 'anilist_total_seasons')
      .firstOrNull
      ?.value;

  List<Attachment> get _imageAttachments =>
      attachments.where((a) => a.type == 'image').toList();

  @override
  Widget build(BuildContext context) {
    final coverUrl = _coverUrl;
    final images = _imageAttachments;
    final season = _season;
    final total = _totalSeasons;

    if (coverUrl == null && images.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (coverUrl != null)
          GestureDetector(
            onTap: () => _openFullscreen(context, coverUrl),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    coverUrl,
                    width: double.infinity,
                    height: 150,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
                // Staffel-Badge
                if (season != null)
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        total != null
                            ? 'Staffel $season/$total'
                            : 'Staffel $season',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                // Vollbild-Hinweis
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.open_in_full_rounded,
                        size: 14, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        if (images.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 80,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () =>
                    _openFullscreen(context, images[i].localPath, isLocal: true),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(images[i].localPath),
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 80,
                      height: 80,
                      color: MFColors.surfaceAlt,
                      child: const Icon(Icons.broken_image_outlined,
                          color: MFColors.textMuted),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  void _openFullscreen(BuildContext context, String path,
      {bool isLocal = false}) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FullscreenImageViewer(path: path, isLocal: isLocal),
    ));
  }
}

// ─── Platzhalter für noch nicht synchronisierte Anhänge ───────────────────────

class _MissingAttachmentHint extends StatelessWidget {
  const _MissingAttachmentHint();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_sync_outlined, color: Colors.white54, size: 56),
            SizedBox(height: 16),
            Text('Anhang noch nicht synchronisiert',
                style: TextStyle(color: Colors.white70, fontSize: 15),
                textAlign: TextAlign.center),
            SizedBox(height: 6),
            Text('Die Datei liegt noch auf dem anderen Gerät. '
                'Starte dort einen Sync, damit sie übertragen wird.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center),
          ],
        ),
      );
}

// ─── Fullscreen-Bild-Viewer ───────────────────────────────────────────────────

class _FullscreenImageViewer extends StatelessWidget {
  final String path;
  final bool isLocal;
  const _FullscreenImageViewer({required this.path, required this.isLocal});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: InteractiveViewer(
          maxScale: 5.0,
          child: Center(
            child: isLocal
                ? Image.file(
                    File(path),
                    errorBuilder: (_, __, ___) => const _MissingAttachmentHint(),
                  )
                : Image.network(
                    path,
                    loadingBuilder: (_, child, progress) => progress == null
                        ? child
                        : const Center(
                            child: CircularProgressIndicator(
                                color: Colors.white)),
                    errorBuilder: (_, __, ___) => const _MissingAttachmentHint(),
                  ),
          ),
        ),
      );
}
