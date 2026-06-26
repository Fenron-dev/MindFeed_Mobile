import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
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
import '../../data/db/app_database.dart' hide Container;
import '../../data/repositories/entry_repository.dart';
import '../../features/containers/container_provider.dart';
import '../../services/notification_service.dart';
import '../../services/ai/ai_service.dart';
import '../../services/ai/llm_profile.dart';
import '../../services/ai/llm_profiles_store.dart';
import '../../services/app_settings.dart';
import '../../services/url_metadata_service.dart';
import '../../services/enrichment/metadata_record.dart';
import '../capture/field_import_sheet.dart';
import '../capture/vision_flow.dart';
import '../../features/tasks/widgets/task_body_widget.dart';
import '../../features/tasks/task_provider.dart'
    show tasksBySourceNoteProvider, subtasksByParentProvider;
import '../../widgets/app_shell.dart' show navigateToCapture, navigateToEntry, navigateToTask;
import '../../widgets/entry_card.dart';
import '../../widgets/format_toolbar.dart';
import '../../widgets/linked_entries_section.dart';
import '../../widgets/wikilink_text_field.dart';
import 'entry_detail_provider.dart';
import 'properties_block.dart';
import '../../domain/tag_parser.dart';
import '../../services/searxng_service.dart';

const _keyApiKey = 'openrouter_api_key';
const _keyAiModel = 'openrouter_model';
const _keySearxngUrl = 'searxng_base_url';

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
  bool _researching = false;
  bool _refetching = false;
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  // ScrollController bleibt über Stream-Re-Emits hinweg erhalten → Position springt nicht
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      HardwareKeyboard.instance.addHandler(_onHwKey);
    }
  }

  bool _onHwKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final mod = Platform.isMacOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    if (!mod) return false;
    if (event.logicalKey == LogicalKeyboardKey.keyE) {
      setState(() => _isEditing = !_isEditing);
      return true;
    }
    // Cmd/Ctrl+Enter speichert im Bearbeiten-Modus
    if (event.logicalKey == LogicalKeyboardKey.enter && _isEditing) {
      _save();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      HardwareKeyboard.instance.removeHandler(_onHwKey);
    }
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
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

  /// Holt die Metadaten der Quell-URL erneut ab und zeigt dasselbe Review-Sheet
  /// wie beim Erfassen. Bestätigte Felder werden als Properties gemergt
  /// (bestehende Keys werden überschrieben).
  Future<void> _refetchMetadata(String entryId, String? sourceUrl) async {
    if (sourceUrl == null || sourceUrl.isEmpty || _refetching) return;
    setState(() => _refetching = true);
    try {
      final meta = await UrlMetadataService.fetch(sourceUrl);
      if (!mounted) return;
      if (meta == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Keine Metadaten gefunden.'),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      final record = MetadataRecord.fromUrlMetadata(meta, url: sourceUrl);
      final picked = await FieldImportSheet.show(
        context,
        record: record,
        prefs: AppSettings.loadApiFieldPrefs(),
      );
      if (picked == null || !mounted) return;

      final dao = ref.read(propertyDaoProvider);
      final existing = await dao.watchByEntry(entryId).first;
      final pickedKeys = picked.map((f) => f.storageKey).toSet();
      // Bestehende Properties behalten, außer sie werden neu gesetzt.
      final merged = <EntryPropertiesCompanion>[
        for (final p in existing)
          if (!pickedKeys.contains(p.key))
            EntryPropertiesCompanion(
              id: drift.Value(p.id),
              entryId: drift.Value(p.entryId),
              key: drift.Value(p.key),
              value: drift.Value(p.value),
              type: drift.Value(p.type),
            ),
      ];
      var i = 0;
      for (final f in picked) {
        merged.add(EntryPropertiesCompanion(
          id: drift.Value('prop-${DateTime.now().microsecondsSinceEpoch}-${i++}'),
          entryId: drift.Value(entryId),
          key: drift.Value(f.storageKey),
          value: drift.Value(f.value),
          type: drift.Value(f.propType),
        ));
      }
      await dao.setProperties(entryId, merged);
      // Eintrag touchen, damit Streams/Feed neu emittieren.
      await ref.read(entryRepositoryProvider).updateEntry(entryId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Metadaten aktualisiert.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Abruf fehlgeschlagen: $e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _refetching = false);
    }
  }

  /// Analysiert den ersten Bild-Anhang per Vision-Profil und ergänzt die Notiz
  /// (Titel/Body/Tags) (#34).
  Future<void> _analyzeImageNote(
      String entryId, List<Attachment> attachments) async {
    final att = attachments.where((a) => a.type == 'image').firstOrNull;
    if (att == null || (att.localPath ?? '').isEmpty) {
      _snack('Kein Bild-Anhang gefunden.');
      return;
    }
    Uint8List bytes;
    try {
      bytes = await File(att.localPath!).readAsBytes();
    } catch (e) {
      _snack('Bild nicht lesbar: $e');
      return;
    }
    if (!mounted) return;
    final existing = await ref.read(tagDaoProvider).getAllTagNames();
    if (!mounted) return;
    final outcome =
        await runVisionFlow(context, ref, bytes, existingTags: existing);
    if (outcome == null) return;
    final repo = ref.read(entryRepositoryProvider);
    final cur = (await repo.getById(entryId))?.entry;
    if ((outcome.title ?? '').isNotEmpty &&
        (cur?.title == null || cur!.title!.isEmpty)) {
      await repo.updateEntry(entryId, title: outcome.title);
    }
    final add = <String>[];
    if ((outcome.summary ?? '').isNotEmpty) add.add(outcome.summary!);
    if (outcome.tags.isNotEmpty) {
      add.add(outcome.tags.map((t) => '#$t').join(' '));
    }
    if (add.isNotEmpty) {
      final b = (await repo.getById(entryId))?.entry.body ?? '';
      await repo.updateEntry(entryId, body: '$b\n\n${add.join('\n\n')}'.trim());
    }
    if (mounted) _snack('Aus Bild ergänzt.', error: false);
  }

  Future<void> _enrichWithAi(String entryId, String body, String? title) async {
    if (ref.read(llmProfilesProvider).chainFor(LlmTask.enrichment).isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Kein KI-Profil zugewiesen. Bitte in den Einstellungen anlegen.'),
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

      // Reichster Inhalt für die (ausführliche) Auswertung: Transkript, sonst
      // der extrahierte Seiten-Haupttext (#27), sonst der übergebene Body.
      String? hiddenText(String key) => props
          .where((p) => p.key == key && (p.value?.trim().isNotEmpty == true))
          .firstOrNull
          ?.value;
      final detailContent =
          hiddenText('_transcript') ?? hiddenText('_pagetext') ?? body;

      final existingTagNames = await ref.read(tagDaoProvider).getAllTagNames();
      final result = await AiService.runForTask(
        ref,
        LlmTask.enrichment,
        (svc) => svc.enrichEntry(
          opts.enrichBody ? detailContent : '',
          existingTitle: title,
          extraContext: extraParts.isNotEmpty ? extraParts.join('\n') : null,
          existingTags: existingTagNames,
        ),
      );

      int changes = 0;

      // Strukturierte Notiz (typ-erkennend, volles Transkript) in den Body
      if (opts.enrichDetailedSummary && detailContent.trim().isNotEmpty) {
        final srcUrl =
            (await ref.read(entryRepositoryProvider).getById(entryId))
                ?.entry.sourceUrl;
        final structured = await AiService.runForTask(
            ref,
            LlmTask.structuredNote,
            (svc) => svc.generateStructuredNote(detailContent,
                existingTitle: title, sourceUrl: srcUrl));
        if (structured != null && structured.trim().isNotEmpty) {
          final cur = (await ref.read(entryRepositoryProvider).getById(entryId))
                  ?.entry.body ?? '';
          await ref
              .read(entryRepositoryProvider)
              .updateEntry(entryId, body: _mergeAuswertung(cur, structured));
          changes++;
        }
      }

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
          await ref.read(entryRepositoryProvider).setEntryProperties(entryId, [
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
        // Existiert ein Transkript? Dann nach der Auswertung das Löschen anbieten
        // (nicht automatisch — die Notiz soll vorher geprüft werden können).
        final hasTranscript = props.any((p) => p.key == '_transcript');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(changes > 0
              ? 'KI fertig: $changes Felder aktualisiert${hasTranscript ? ' — Transkript prüfen & ggf. löschen' : ''}'
              : 'Keine Änderungen nötig'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: MFColors.teal,
          duration: Duration(seconds: hasTranscript ? 7 : 4),
          action: hasTranscript
              ? SnackBarAction(
                  label: 'Transkript löschen',
                  textColor: Colors.white,
                  onPressed: () => _deleteTranscript(entryId),
                )
              : null,
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

  static const _rechercheStart = '<!-- mf:recherche:start -->';
  static const _rechercheEnd = '<!-- mf:recherche:end -->';

  static String _mergeRecherche(String current, String note) {
    final block = '$_rechercheStart\n$note\n$_rechercheEnd';
    final re = RegExp(
        '${RegExp.escape(_rechercheStart)}[\\s\\S]*?${RegExp.escape(_rechercheEnd)}');
    if (re.hasMatch(current)) return current.replaceFirst(re, block);
    final base = current.trim();
    return base.isEmpty ? block : '$base\n\n$block';
  }

  /// Recherchiert einen Link über SearXNG und erzeugt daraus per LLM eine
  /// strukturierte Notiz, die als eigener Block in den Body eingefügt wird.
  Future<void> _researchLink(String entryId, String? url, String? title) async {
    final searxUrl = (await secureRead(_keySearxngUrl) ?? '').trim();
    if (!mounted) return;
    if (ref.read(llmProfilesProvider).chainFor(LlmTask.researchedNote).isEmpty) {
      _snack('Kein KI-Profil zugewiesen. Bitte in den Einstellungen anlegen.');
      return;
    }
    if (searxUrl.isEmpty) {
      _snack('Keine SearXNG-URL gesetzt (Einstellungen → Web-Recherche).');
      return;
    }

    setState(() => _researching = true);
    try {
      // Suchbegriff: Titel, sonst Domain der Quelle.
      final query = (title?.trim().isNotEmpty == true)
          ? title!.trim()
          : (url != null ? Uri.tryParse(url)?.host ?? url : '');
      if (query.isEmpty) throw Exception('Kein Suchbegriff (Titel/URL fehlt)');

      // Recherche
      final results =
          await SearxngService(baseUrl: searxUrl).search(query, language: 'de');
      final context = SearxngService.resultsToContext(results);

      // Bekannte Beschreibung aus Properties (z.B. OG/AniList)
      final props = await ref.read(propertyDaoProvider).watchByEntry(entryId).first;
      final descProp = props
          .where((p) =>
              p.key.toLowerCase() == 'og_description' ||
              p.key.toLowerCase() == 'description')
          .firstOrNull;

      final note = await AiService.runForTask(
        ref,
        LlmTask.researchedNote,
        (svc) => svc.generateResearchedNote(
          title: query,
          sourceUrl: url,
          knownDescription: descProp?.value,
          searchContext: context,
        ),
      );
      if (note == null || note.trim().isEmpty) {
        throw Exception('Modell lieferte keine Notiz');
      }

      final cur =
          (await ref.read(entryRepositoryProvider).getById(entryId))?.entry.body ??
              '';
      await ref
          .read(entryRepositoryProvider)
          .updateEntry(entryId, body: _mergeRecherche(cur, note.trim()));

      if (mounted) {
        _snack('Recherche-Notiz erstellt (${results.length} Treffer).',
            error: false);
      }
    } catch (e) {
      if (mounted) {
        _snack(e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _researching = false);
    }
  }

  void _snack(String msg, {bool error = true}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg.length > 160 ? '${msg.substring(0, 160)}…' : msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? Colors.red.shade900 : MFColors.teal,
    ));
  }

  static bool _isYoutube(String? url) {
    if (url == null || url.isEmpty) return false;
    final u = url.toLowerCase();
    return u.contains('youtube.com/watch') ||
        u.contains('youtu.be/') ||
        u.contains('youtube.com/shorts/');
  }

  /// Öffnet den manuellen Einfüge-Dialog für ein YouTube-Transkript und
  /// speichert das Ergebnis als versteckte Property. Der frühere automatische
  /// Abruf ist entfernt: YouTube verlangt seit 2024/25 ein PO-Token für den
  /// timedtext-Endpoint, ein reiner HTTP-Abruf ist nicht mehr möglich
  /// (siehe GitHub-Issue #26).
  Future<void> _fetchTranscript(String entryId, String? url, String body) async {
    if (url == null) return;
    final pasted = await _showTranscriptPasteDialog(url);
    if (pasted == null || pasted.trim().isEmpty) return;
    await _storeTranscript(entryId, pasted.trim());
  }

  /// Tag im Edit-Modus als `#tag` in den Body schreiben. Tags werden beim
  /// Speichern aus dem Body geparst (TagParser), daher muss der Tag dort
  /// stehen, sonst geht er verloren. Spiegelt das Verhalten des Tippens.
  void _addTagToBody(String raw) {
    final clean =
        raw.trim().replaceAll(RegExp(r'^#'), '').toLowerCase();
    if (clean.isEmpty) return;
    if (TagParser.parse(_bodyCtrl.text).contains(clean)) return;
    final body = _bodyCtrl.text;
    final sep = body.isEmpty
        ? ''
        : (body.endsWith('\n') || body.endsWith(' ') ? '' : ' ');
    final next = '$body$sep#$clean';
    setState(() {
      _bodyCtrl.text = next;
      _bodyCtrl.selection =
          TextSelection.collapsed(offset: next.length);
    });
  }

  /// Entfernt genau diesen Tag aus dem Body, ohne hierarchische Geschwister
  /// (z.B. `#buch/sachbuch`) zu treffen.
  void _removeTagFromBody(String tag) {
    final clean = tag.toLowerCase();
    final re = RegExp(
        '#${RegExp.escape(clean)}(?![A-Za-z0-9_\\-/äöüÄÖÜß])',
        caseSensitive: false);
    var body = _bodyCtrl.text.replaceAll(re, '');
    // Doppelte Leerzeichen / Leerzeichen vor Zeilenumbruch aufräumen.
    body = body
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .trimRight();
    setState(() {
      _bodyCtrl.text = body;
      _bodyCtrl.selection = TextSelection.collapsed(offset: body.length);
    });
  }

  static const _auswStart = '<!-- mf:auswertung:start -->';
  static const _auswEnd = '<!-- mf:auswertung:end -->';

  /// Fügt die KI-Auswertung in den Body ein. Ein bereits vorhandener
  /// Auswertungs-Block (zwischen den Sentinel-Markern) wird ersetzt, sonst
  /// wird der Block unten angehängt. So entstehen bei Re-Runs keine Duplikate.
  static String _mergeAuswertung(String current, String structured) {
    final block = '$_auswStart\n$structured\n$_auswEnd';
    final re = RegExp(
        '${RegExp.escape(_auswStart)}[\\s\\S]*?${RegExp.escape(_auswEnd)}');
    if (re.hasMatch(current)) {
      return current.replaceFirst(re, block);
    }
    final base = current.trim();
    return base.isEmpty ? block : '$base\n\n$block';
  }

  /// Speichert das Transkript als (versteckte) Property '_transcript' statt im
  /// Body — so wird die Notiz nicht zugespammt und es ist leicht löschbar.
  Future<void> _storeTranscript(String entryId, String transcript) async {
    await ref
        .read(entryRepositoryProvider)
        .setPropertyByKey(entryId, '_transcript', transcript, 'text');
    if (!mounted) return;
    final title =
        (await ref.read(entryRepositoryProvider).getById(entryId))?.entry.title;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Transkript gespeichert (einklappbar unter der Notiz).'),
      behavior: SnackBarBehavior.floating,
      backgroundColor: MFColors.teal,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Mit KI auswerten',
        textColor: Colors.white,
        onPressed: () => _enrichWithAi(entryId, transcript, title),
      ),
    ));
  }

  Future<void> _deleteTranscript(String entryId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Transkript löschen?',
            style: TextStyle(color: MFColors.textPrimary, fontSize: 17)),
        content: const Text(
          'Das gespeicherte Transkript wird entfernt. Die ausgewerteten '
          'Inhalte (Titel, Tags, Zusammenfassung, Notiz) bleiben erhalten.',
          style: TextStyle(color: MFColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(entryRepositoryProvider).removePropertyByKey(entryId, '_transcript');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Transkript gelöscht.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<String?> _showTranscriptPasteDialog(String url) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: MFColors.border),
        ),
        title: const Text('Transkript einfügen',
            style: TextStyle(color: MFColors.textPrimary, fontSize: 17)),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Der automatische Abruf hat nicht geklappt (keine Untertitel '
                'verfügbar oder blockiert). Öffne das Transkript auf YouTube '
                '(„… mehr" → „Transkript anzeigen"), kopiere es und füge es hier ein.',
                style: TextStyle(color: MFColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(url);
                  if (uri != null && await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Video öffnen'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 10,
                minLines: 6,
                autofocus: true,
                style: const TextStyle(color: MFColors.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Transkript hier einfügen…',
                  hintStyle: const TextStyle(color: MFColors.textMuted),
                  filled: true,
                  fillColor: MFColors.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: MFColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: MFColors.border),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Hinzufügen'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    await ref.read(entryRepositoryProvider).updateEntry(
          widget.entryId,
          title: _titleCtrl.text.trim(),
          body: _bodyCtrl.text,
        );
    if (mounted) {
      setState(() => _isEditing = false);
    }
  }

  Future<void> _addAttachment(String entryId) async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return;
    final repo = ref.read(entryRepositoryProvider);
    for (final f in res.files) {
      if (f.path != null) {
        await repo.addAttachment(entryId, f.path!, fileName: f.name);
      }
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
      if (!mounted) return;
      // Desktop-Inline (onBack) vs. Mobile-Route (pop)
      if (widget.onBack != null) {
        widget.onBack!();
      } else if (context.canPop()) {
        context.pop();
      }
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
                  if (v == 'research') {
                    await _researchLink(entry.id, entry.sourceUrl, entry.title);
                  }
                  if (v == 'transcript') {
                    await _fetchTranscript(entry.id, entry.sourceUrl, entry.body);
                  }
                  if (v == 'refetch') {
                    await _refetchMetadata(entry.id, entry.sourceUrl);
                  }
                  if (v == 'vision') {
                    await _analyzeImageNote(entry.id, item.attachments);
                  }
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
                  if (entry.sourceUrl != null && entry.sourceUrl!.isNotEmpty)
                    _popItem('research',
                      _researching ? Icons.hourglass_top_rounded : Icons.travel_explore_outlined,
                      _researching ? 'Recherche läuft…' : 'Link recherchieren (Web)',
                      color: MFColors.teal),
                  if (_isYoutube(entry.sourceUrl))
                    _popItem('transcript', Icons.subtitles_outlined,
                      'Transkript einfügen',
                      color: const Color(0xFFEF4444)),
                  if (entry.sourceUrl != null && entry.sourceUrl!.isNotEmpty)
                    _popItem('refetch',
                      _refetching ? Icons.hourglass_top_rounded : Icons.download_outlined,
                      _refetching ? 'Wird abgerufen…' : 'Metadaten neu abholen',
                      color: const Color(0xFF38BDF8)),
                  if (item.attachments.any((a) => a.type == 'image'))
                    _popItem('vision', Icons.image_search_outlined,
                        'KI aus Bild',
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

                const SizedBox(height: 12),

                // Eigenschaften (Obsidian-Stil) — oben unter dem Titel, inkl. Tags
                PropertiesBlock(
                  entryId: entry.id,
                  properties: item.properties,
                  // Im Edit-Modus die Tags aus dem (ungespeicherten) Body
                  // ableiten, damit Hinzufügen/Entfernen sofort sichtbar ist
                  // und beim Speichern (Tags = parse(Body)) erhalten bleibt.
                  tags: _isEditing
                      ? TagParser.parse(_bodyCtrl.text)
                      : item.tags,
                  editable: _isEditing,
                  onAddTag: _addTagToBody,
                  onRemoveTag: _removeTagFromBody,
                ),

                const SizedBox(height: 14),

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
                            WikilinkTextField(
                              controller: _bodyCtrl,
                              maxLines: null,
                              style: const TextStyle(
                                  fontSize: 15,
                                  color: MFColors.textPrimary,
                                  height: 1.6),
                              decoration: const InputDecoration(
                                  hintText: '[[ für Verknüpfung…',
                                  hintStyle: TextStyle(color: MFColors.textMuted),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.zero,
                                  filled: false),
                            ),
                          if (!_showPreview)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: FormatToolbar(
                                controller: _bodyCtrl,
                                // Tag-Chips leiten sich aus dem Body ab → nach
                                // Formatierung/QR-Einfügen neu rendern.
                                onChanged: () => setState(() {}),
                              ),
                            ),
                        ],
                      )
                    : TaskBodyWidget(
                        body: entry.body,
                        noteId: entry.id,
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
                            if (found.entry.type == 'task') {
                              navigateToTask(context, ref, found.entry.id);
                            } else {
                              navigateToEntry(context, ref, found.entry.id);
                            }
                          }
                        },
                      ),

                // Transkript (einklappbar) — nur wenn vorhanden
                Builder(builder: (_) {
                  final t = item.properties
                      .where((p) => p.key == '_transcript')
                      .firstOrNull;
                  if (t == null || (t.value ?? '').trim().isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _TranscriptSection(
                      transcript: t.value!,
                      onDelete: () => _deleteTranscript(entry.id),
                      onEnrich: () => _enrichWithAi(
                          entry.id, t.value!, entry.title),
                    ),
                  );
                }),

                // Source-Link-Preview
                if (entry.sourceUrl != null) ...[
                  const SizedBox(height: 12),
                  _LinkPreview(
                      url: entry.sourceUrl!,
                      properties: item.properties),
                ],

                // (Tags + Eigenschaften jetzt oben im PropertiesBlock)

                // Container-Zuweisung
                const SizedBox(height: 16),
                _ContainerAssignment(
                    entryId: entry.id,
                    assignedIds: item.containerIds),

                // Anhänge — immer mit Hinzufügen-Button
                const SizedBox(height: 16),
                Row(children: [
                  const Text('ANHÄNGE',
                      style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.bold,
                          color: MFColors.textMuted, letterSpacing: 1.2)),
                  if (item.attachments.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: MFColors.tealBg, borderRadius: BorderRadius.circular(99)),
                      child: Text('${item.attachments.length}',
                          style: const TextStyle(fontSize: 9, color: MFColors.teal,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _addAttachment(entry.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: MFColors.tealBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF0F766E))),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.attach_file_rounded, size: 13, color: MFColors.teal),
                        SizedBox(width: 4),
                        Text('Anhang', style: TextStyle(fontSize: 11, color: MFColors.teal,
                            fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ]),
                if (item.attachments.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Builder(builder: (_) {
                      // Bild-Galerie für Fullscreen-Swipe vorbereiten
                      final imageAtts = item.attachments
                          .where((a) => a.type == 'image')
                          .toList();
                      final gallery = imageAtts
                          .map((a) => GalleryImage(a.localPath))
                          .toList();
                      // Bilder als kompakter Wrap (Thumbnails), andere Anhänge als Liste
                      final imageAttachments = item.attachments.where((a) => a.type == 'image').toList();
                      final otherAttachments = item.attachments.where((a) => a.type != 'image').toList();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (imageAttachments.isNotEmpty)
                            Wrap(
                              spacing: 0,
                              runSpacing: 8,
                              children: imageAttachments.map((a) {
                                final gi = imageAtts.indexWhere((x) => x.id == a.id);
                                return _AttachmentTile(a,
                                    gallery: gallery,
                                    galleryIndex: gi < 0 ? 0 : gi);
                              }).toList(),
                            ),
                          ...otherAttachments.map((a) => _AttachmentTile(a)),
                        ],
                      );
                    }),
                ],

                // Verlinkte Aufgaben (per Einstellung ein-/ausschaltbar)
                if (entry.type != 'task' &&
                    ref.watch(showTasksInNotesProvider))
                  _NoteTasksSection(noteId: entry.id),

                // Sub-Notizen zu diesem Eintrag
                _SubNotesSection(parentEntryId: entry.id),

                // Manuelle Verknüpfungen
                LinkedEntriesSection(entryId: entry.id),

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

class _AttachmentTile extends StatelessWidget {
  final Attachment att;
  final List<GalleryImage> gallery;
  final int galleryIndex;
  const _AttachmentTile(this.att,
      {this.gallery = const [], this.galleryIndex = 0});
  @override
  Widget build(BuildContext context) {
    if (att.type == 'audio') return _AudioTile(att);
    if (att.type == 'image') {
      return _ImageTile(att, gallery: gallery, galleryIndex: galleryIndex);
    }
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
  // Alle Bilder des Eintrags + Index dieses Bildes → Swipen im Fullscreen
  final List<GalleryImage> gallery;
  final int galleryIndex;
  const _ImageTile(this.att, {this.gallery = const [], this.galleryIndex = 0});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, right: 8),
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => gallery.isNotEmpty
                ? _FullscreenImageViewer(
                    images: gallery, initialIndex: galleryIndex)
                : _FullscreenImageViewer.single(att.localPath),
          )),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(att.localPath),
              height: 120,
              width: 120,
              fit: BoxFit.cover,
              cacheWidth: 240,
              errorBuilder: (_, __, ___) => Container(
                height: 60, width: 60,
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
                    onTap: () => bl.entry.type == 'task'
                        ? navigateToTask(context, ref, bl.entry.id)
                        : navigateToEntry(context, ref, bl.entry.id),
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
  final bool enrichDetailedSummary;
  final bool enrichBody;

  const _EnrichOptions({
    required this.enrichTitle,
    required this.enrichTags,
    required this.enrichSummary,
    required this.enrichDetailedSummary,
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
  bool _detailedSummary = true;
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
          _CheckTile('Kurz-Zusammenfassung (1-2 Sätze)', _summary, (v) => setState(() => _summary = v!)),
          _CheckTile('Strukturierte Notiz erstellen (typ-erkennend, in den Text)', _detailedSummary, (v) => setState(() => _detailedSummary = v!)),
          _CheckTile('Text des Eintrags einbeziehen', _body, (v) => setState(() => _body = v!)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen', style: TextStyle(color: MFColors.textMuted)),
        ),
        FilledButton(
          onPressed: (_tags || _title || _summary || _detailedSummary)
              ? () => Navigator.pop(
                    context,
                    _EnrichOptions(
                      enrichTitle: _title,
                      enrichTags: _tags,
                      enrichSummary: _summary,
                      enrichDetailedSummary: _detailedSummary,
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
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, color: MFColors.textPrimary)),
            ),
          ]),
        ),
      );
}

// ─── Verlinkte Aufgaben zu einer Notiz ───────────────────────────────────────

/// Eine Task-Zeile in der Notiz-Aufgaben-Sektion samt eingerückten Subtasks,
/// damit Unteraufgaben direkt aus der Notiz erreichbar sind.
class _NoteTaskTile extends ConsumerWidget {
  final EntryWithDetails task;
  const _NoteTaskTile({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtasks = ref.watch(subtasksByParentProvider(task.entry.id)).maybeWhen(
          data: (list) =>
              list.where((e) => e.entry.type == 'task').toList(),
          orElse: () => const <EntryWithDetails>[],
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _taskRow(context, ref, task, indent: 0),
        ...subtasks.map((s) => _taskRow(context, ref, s, indent: 28)),
      ],
    );
  }

  Widget _taskRow(BuildContext context, WidgetRef ref, EntryWithDetails t,
      {required double indent}) {
    final isDone = t.entry.status == 'done';
    final isSub = indent > 0;
    return Padding(
      padding: EdgeInsets.only(left: indent, bottom: 6),
      child: Row(children: [
        GestureDetector(
          onTap: () =>
              ref.read(entryRepositoryProvider).toggleTaskStatus(t.entry.id),
          child: Icon(
              isDone
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: isSub ? 16 : 18,
              color: isDone ? MFColors.teal : MFColors.textMuted),
        ),
        SizedBox(width: isSub ? 8 : 10),
        Expanded(
          child: GestureDetector(
            onTap: () => navigateToTask(context, ref, t.entry.id),
            child: Text(
              t.entry.title ?? t.entry.body,
              style: TextStyle(
                fontSize: isSub ? 13 : 14,
                color: isDone ? MFColors.textMuted : MFColors.textPrimary,
                decoration: isDone ? TextDecoration.lineThrough : null,
                decorationColor: MFColors.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ]),
    );
  }
}

class _NoteTasksSection extends ConsumerStatefulWidget {
  final String noteId;
  const _NoteTasksSection({required this.noteId});
  @override
  ConsumerState<_NoteTasksSection> createState() => _NoteTasksSectionState();
}

class _NoteTasksSectionState extends ConsumerState<_NoteTasksSection> {
  final _addCtrl = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final title = _addCtrl.text.trim();
    if (title.isEmpty) return;
    setState(() => _adding = true);
    try {
      await ref.read(entryRepositoryProvider)
          .createTask(title: title, sourceEntryId: widget.noteId);
      _addCtrl.clear();
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(tasksBySourceNoteProvider(widget.noteId));
    return tasksAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (tasks) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Row(children: [
              const Icon(Icons.task_alt_rounded, size: 13, color: MFColors.textMuted),
              const SizedBox(width: 6),
              const Text('AUFGABEN',
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold,
                      color: MFColors.textMuted, letterSpacing: 1.2)),
              if (tasks.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: MFColors.tealBg, borderRadius: BorderRadius.circular(99)),
                  child: Text('${tasks.length}',
                      style: const TextStyle(
                          fontSize: 10, fontWeight: FontWeight.bold, color: MFColors.teal)),
                ),
              ],
            ]),
            const SizedBox(height: 8),
            ...tasks.map((t) => _NoteTaskTile(task: t)),
            // Quick-Add
            Row(children: [
              const Icon(Icons.radio_button_unchecked_rounded,
                  size: 18, color: MFColors.border),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _addCtrl,
                  style: const TextStyle(fontSize: 14, color: MFColors.textPrimary),
                  decoration: const InputDecoration(
                    hintText: 'Aufgabe hinzufügen…',
                    hintStyle: TextStyle(fontSize: 14, color: MFColors.textMuted),
                    border: InputBorder.none, isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _add(),
                ),
              ),
              if (_adding)
                const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: MFColors.teal))
              else
                GestureDetector(
                  onTap: _add,
                  child: const Icon(Icons.add_circle_outline_rounded,
                      size: 18, color: MFColors.teal)),
            ]),
          ],
        );
      },
    );
  }
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

// Provider für Sub-Notizen (öffentlich für task_detail_screen)
final subNotesProvider =
    StreamProvider.autoDispose.family<List<EntryWithDetails>, String>(
  (ref, parentEntryId) {
    ref.keepAlive();
    return ref.watch(entryRepositoryProvider).watchSubNotes(parentEntryId);
  },
);

// Alias für interne Nutzung
final _subNotesProvider = subNotesProvider;

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
                onTap: () => _openGallery(
                    context,
                    images.map((a) => GalleryImage(a.localPath)).toList(),
                    i),
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
      builder: (_) => _FullscreenImageViewer.single(path, isLocal: isLocal),
    ));
  }

  void _openGallery(BuildContext context, List<GalleryImage> images, int index) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          _FullscreenImageViewer(images: images, initialIndex: index),
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

// ─── Fullscreen-Bild-Viewer (swipebare Galerie) ──────────────────────────────

/// Ein Bild in der Galerie: Pfad + ob lokal (Datei) oder Netzwerk-URL.
class GalleryImage {
  final String path;
  final bool isLocal;
  const GalleryImage(this.path, {this.isLocal = true});
}

class _FullscreenImageViewer extends StatefulWidget {
  final List<GalleryImage> images;
  final int initialIndex;

  const _FullscreenImageViewer({
    required this.images,
    this.initialIndex = 0,
  });

  /// Bequemer Konstruktor für ein einzelnes Bild.
  factory _FullscreenImageViewer.single(String path, {bool isLocal = true}) =>
      _FullscreenImageViewer(images: [GalleryImage(path, isLocal: isLocal)]);

  @override
  State<_FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<_FullscreenImageViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.images.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        title: total > 1
            ? Text('${_index + 1} / $total',
                style: const TextStyle(color: Colors.white, fontSize: 15))
            : null,
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: total,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) {
          final img = widget.images[i];
          return InteractiveViewer(
            maxScale: 5.0,
            child: Center(
              child: img.isLocal
                  ? Image.file(
                      File(img.path),
                      errorBuilder: (_, __, ___) => const _MissingAttachmentHint(),
                    )
                  : Image.network(
                      img.path,
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : const Center(
                              child: CircularProgressIndicator(color: Colors.white)),
                      errorBuilder: (_, __, ___) => const _MissingAttachmentHint(),
                    ),
            ),
          );
        },
      ),
    );
  }
}

// ── Einklappbare Transkript-Sektion ────────────────────────────────────────
class _TranscriptSection extends StatefulWidget {
  final String transcript;
  final VoidCallback onDelete;
  final VoidCallback onEnrich;

  const _TranscriptSection({
    required this.transcript,
    required this.onDelete,
    required this.onEnrich,
  });

  @override
  State<_TranscriptSection> createState() => _TranscriptSectionState();
}

class _TranscriptSectionState extends State<_TranscriptSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final chars = widget.transcript.length;
    return Container(
      decoration: BoxDecoration(
        color: MFColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MFColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Kopfzeile (klickbar = ein-/ausklappen)
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 20,
                    color: MFColors.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.subtitles_outlined,
                      size: 15, color: Color(0xFFEF4444)),
                  const SizedBox(width: 6),
                  const Text('Transkript',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: MFColors.textPrimary)),
                  const SizedBox(width: 6),
                  Text('${(chars / 1000).toStringAsFixed(chars < 1000 ? 1 : 0)}k Z.',
                      style: const TextStyle(
                          fontSize: 10, color: MFColors.textMuted)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Mit KI auswerten',
                    onPressed: widget.onEnrich,
                    icon: const Icon(Icons.auto_awesome_outlined,
                        size: 17, color: Color(0xFF8B5CF6)),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                  ),
                  IconButton(
                    tooltip: 'Transkript löschen',
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline,
                        size: 17, color: Colors.redAccent),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: SelectableText(
                    widget.transcript,
                    style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: MFColors.textSecondary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
