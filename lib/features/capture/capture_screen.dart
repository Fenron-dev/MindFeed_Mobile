import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../core/vault_manager.dart';
import '../../data/db/app_database.dart' hide Container;
import '../../domain/tag_parser.dart';
import '../../services/app_settings.dart';
import '../../services/ai/ai_service.dart';
import '../../services/ai/llm_profile.dart';
import '../../services/enrichment/metadata_record.dart';
import '../../services/openrouter_service.dart';
import '../../services/url_metadata_service.dart';
import 'field_import_sheet.dart';
import '../../sync/sync_provider.dart';
import '../../widgets/app_shell.dart' show navigateToEntry;
import '../../widgets/format_toolbar.dart';
import '../../widgets/wikilink_text_field.dart';
import 'vision_flow.dart';

const _storage = FlutterSecureStorage();
const _keyApiKey = 'openrouter_api_key';
const _keyAiModel = 'openrouter_model';

class CaptureScreen extends ConsumerStatefulWidget {
  final String? initialText;
  final List<String>? sharedFilePaths;
  final String? initialContainerId;
  final String? parentEntryId; // für Sub-Notizen
  /// Desktop inline: Callback statt Navigator.pop() beim Schließen/Speichern.
  final VoidCallback? onBack;
  const CaptureScreen({
    super.key,
    this.initialText,
    this.sharedFilePaths,
    this.initialContainerId,
    this.parentEntryId,
    this.onBack,
  });

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> {
  final _bodyCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _bodyFocus = FocusNode();
  bool _isSaving = false;
  List<String> _parsedTags = [];
  bool _showTitle = false;

  // URL-Preview
  UrlMetadata? _urlPreview;
  bool _loadingPreview = false;
  String? _lastCheckedUrl;
  Timer? _urlDebounce;

  // Bild-Anhänge
  final List<XFile> _pendingImages = [];

  // Audio-Aufnahme
  // Lazy: Recorder erst bei der ersten Aufnahme erzeugen. Verhindert, dass das
  // native `record`-Plugin schon beim Öffnen/Schließen des Capture-Screens
  // initialisiert/disposed wird (führte auf Windows zum Absturz nach dem
  // Speichern, wenn der Screen geschlossen wird).
  AudioRecorder? _recorder;
  bool _isRecording = false;
  String? _recordedAudioPath;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;

  // Sonstige Datei-Anhänge (Video, PDF, etc.)
  final List<PlatformFile> _pendingFiles = [];

  // Capture-Optionen
  bool _autoSave = false;
  bool _autoAi = false;

  @override
  void initState() {
    super.initState();
    _bodyCtrl.addListener(_onBodyChanged);
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      HardwareKeyboard.instance.addHandler(_onKeyEvent);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialText != null && widget.initialText!.isNotEmpty) {
        _bodyCtrl.text = widget.initialText!;
        _onBodyChanged();
      }
      if (widget.sharedFilePaths != null) {
        _importSharedFiles(widget.sharedFilePaths!);
      }
      _bodyFocus.requestFocus();
    });
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // ESC: Schließen ohne Speichern
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (widget.onBack != null) { widget.onBack!(); return true; }
      if (mounted) { Navigator.maybePop(context); return true; }
    }
    final modifier = Platform.isMacOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    if (!modifier) return false;
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      final canSave = (_bodyCtrl.text.trim().isNotEmpty ||
              _pendingImages.isNotEmpty ||
              _recordedAudioPath != null) &&
          !_isSaving;
      if (canSave) { _save(); return true; }
    }
    return false;
  }

  Timer? _autoSaveDebounce;

  @override
  void dispose() {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    }
    _urlDebounce?.cancel();
    _autoSaveDebounce?.cancel();
    _recordingTimer?.cancel();
    try { _recorder?.dispose(); } catch (_) {}
    _bodyCtrl.removeListener(_onBodyChanged);
    _bodyCtrl.dispose();
    _titleCtrl.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  // Fügt Text an der aktuellen Cursor-Position ein
  void _insertAtCursor(String text) {
    final ctrl = _bodyCtrl;
    final sel = ctrl.selection;
    final current = ctrl.text;
    final start = sel.isValid ? sel.start : current.length;
    final end = sel.isValid ? sel.end : current.length;
    final newText = current.replaceRange(start, end, text);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _bodyFocus.requestFocus();
  }

  void _insertTaskLine() {
    final ctrl = _bodyCtrl;
    final text = ctrl.text;
    final sel = ctrl.selection;
    final pos = sel.isValid ? sel.start : text.length;

    // Zeilenumbruch nur wenn nicht bereits am Anfang einer neuen Zeile
    final prefix = (pos > 0 && text[pos - 1] != '\n') ? '\n' : '';
    final insert = '${prefix}- [ ] ';

    final newText = text.replaceRange(pos, pos, insert);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: pos + insert.length),
    );
    _bodyFocus.requestFocus();
  }

  void _onBodyChanged() {
    setState(() {
      _parsedTags = TagParser.parse(_bodyCtrl.text);
    });
    if (_autoSave && (_bodyCtrl.text.trim().isNotEmpty || _pendingImages.isNotEmpty)) {
      _autoSaveDebounce?.cancel();
      _autoSaveDebounce = Timer(const Duration(seconds: 3), () {
        if (mounted && !_isSaving) _save();
      });
    }
    _scheduleUrlCheck();
    // [[-Autocomplete läuft jetzt im WikilinkTextField selbst
  }

  void _scheduleUrlCheck() {
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 600), _checkUrl);
  }

  void _importSharedFiles(List<String> paths) {
    final imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'};
    for (final path in paths) {
      final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
      if (imageExts.contains(ext)) {
        _pendingImages.add(XFile(path));
      } else {
        final file = File(path);
        if (file.existsSync()) {
          _pendingFiles.add(PlatformFile(
            name: p.basename(path),
            path: path,
            size: file.lengthSync(),
          ));
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final nonImages = result.files.where((f) {
      final ext = (f.extension ?? '').toLowerCase();
      return !['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(ext);
    }).toList();
    final images = result.files.where((f) {
      final ext = (f.extension ?? '').toLowerCase();
      return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(ext);
    }).toList();
    if (mounted) {
      setState(() {
        _pendingFiles.addAll(nonImages);
        _pendingImages.addAll(images.map((f) => XFile(f.path!)));
      });
    }
  }

  /// Analysiert das erste angehängte Bild per Vision-Profil und füllt
  /// Titel/Body/Tags der Notiz (#34).
  Future<void> _analyzeImage() async {
    if (_pendingImages.isEmpty) return;
    final bytes = await _pendingImages.first.readAsBytes();
    if (!mounted) return;
    final existing = await ref.read(tagDaoProvider).getAllTagNames();
    if (!mounted) return;
    final outcome =
        await runVisionFlow(context, ref, bytes, existingTags: existing);
    if (outcome == null || !mounted) return;
    setState(() {
      if ((outcome.title ?? '').isNotEmpty) {
        _titleCtrl.text = outcome.title!;
        _showTitle = true;
      }
      final parts = <String>[];
      if ((outcome.summary ?? '').isNotEmpty) parts.add(outcome.summary!);
      if (outcome.tags.isNotEmpty) {
        parts.add(outcome.tags.map((t) => '#$t').join(' '));
      }
      if (parts.isNotEmpty) {
        final cur = _bodyCtrl.text.trim();
        _bodyCtrl.text =
            cur.isEmpty ? parts.join('\n\n') : '$cur\n\n${parts.join('\n\n')}';
      }
    });
  }

  Future<void> _pickImage() async {
    final choice = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: MFColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 12),
            decoration: BoxDecoration(
                color: MFColors.border,
                borderRadius: BorderRadius.circular(99)),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined,
                color: MFColors.teal),
            title: const Text('Kamera',
                style: TextStyle(color: MFColors.textPrimary)),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined,
                color: MFColors.teal),
            title: const Text('Galerie',
                style: TextStyle(color: MFColors.textPrimary)),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
    if (choice == null) return;
    final picker = ImagePicker();
    final image = await picker.pickImage(
        source: choice, imageQuality: 85, maxWidth: 1920);
    if (image != null && mounted) {
      setState(() => _pendingImages.add(image));
    }
  }

  Future<void> _toggleRecording() async {
    final rec = _recorder ??= AudioRecorder();
    if (_isRecording) {
      // Aufnahme stoppen
      _recordingTimer?.cancel();
      final path = await rec.stop();
      setState(() {
        _isRecording = false;
        _recordedAudioPath = path;
      });
    } else {
      // Aufnahme starten
      final hasPermission = await rec.hasPermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Mikrofon-Berechtigung fehlt.'),
            behavior: SnackBarBehavior.floating,
          ));
        }
        return;
      }
      final attachmentsBase = await VaultManager.getAttachmentsPath();
      final now = DateTime.now();
      final subDir = Directory(
          p.join(attachmentsBase, '${now.year}', now.month.toString().padLeft(2, '0')));
      await subDir.create(recursive: true);
      final audioPath = p.join(subDir.path, '${now.millisecondsSinceEpoch}.m4a');

      await rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
        path: audioPath,
      );
      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
      });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingDuration += const Duration(seconds: 1));
      });
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Wendet automatisch das passende Template an und befüllt bekannte Felder.
  Future<void> _autoApplyTemplate(String entryId, String mediaType) async {
    final templates = AppSettings.loadTemplates();
    PropTemplate? _find(String id, String fallback) =>
        templates.where((t) => t.id == id).firstOrNull ??
        templates.where((t) => t.name.toLowerCase().contains(fallback)).firstOrNull;

    PropTemplate? tpl;
    switch (mediaType) {
      case 'ANIME':    tpl = _find('tpl-anime',      'anime');      break;
      case 'MANGA':    tpl = _find('tpl-book',        'buch');       break;
      case 'YOUTUBE':  tpl = _find('tpl-youtube',     'youtube');    break;
      case 'BOARDGAME':tpl = _find('tpl-boardgame',   'brettspiel'); break;
      case 'VIDEOGAME':tpl = _find('tpl-videogame',   'videospiel'); break;
      case 'TTRPG':    tpl = _find('tpl-ttrpg',       'rpg');        break;
      case 'GITHUB':   tpl = _find('tpl-github',      'github');     break;
      default:         return; // kein passendes Template
    }
    if (tpl == null) return;

    final dao = ref.read(propertyDaoProvider);
    final existing = await dao.watchByEntry(entryId).first;
    final existingKeys = existing.map((p) => p.key.toLowerCase()).toSet();

    // Pre-fill-Werte aus Metadaten
    final prefill = <String, String>{};
    final extra = _urlPreview?.extraProps ?? {};

    if (mediaType == 'ANIME' || mediaType == 'MANGA') {
      if (_urlPreview?.anilistStudio != null) prefill['studio'] = _urlPreview!.anilistStudio!;
      if (_urlPreview?.anilistFormat != null) prefill['format'] = _urlPreview!.anilistFormat!;
      if (_urlPreview?.anilistYear != null) prefill['jahr'] = _urlPreview!.anilistYear.toString();
      if (_urlPreview?.anilistEpisodes != null) prefill['folgen gesamt'] = _urlPreview!.anilistEpisodes.toString();
      if (_urlPreview?.anilistChapters != null) prefill['kapitel'] = _urlPreview!.anilistChapters.toString();
      if (_urlPreview?.genres.isNotEmpty == true) prefill['genre'] = _urlPreview!.genres.join(', ');
      if (_urlPreview?.score != null) prefill['bewertung'] = (_urlPreview!.score! / 10).toStringAsFixed(1);
    }
    if (mediaType == 'BOARDGAME') {
      if (extra['bgg_year']?.isNotEmpty == true) prefill['jahr'] = extra['bgg_year']!;
      if (extra['bgg_players']?.isNotEmpty == true) prefill['spieler'] = extra['bgg_players']!;
      if (extra['bgg_playtime']?.isNotEmpty == true) prefill['spielzeit'] = extra['bgg_playtime']!;
      if (extra['bgg_publisher']?.isNotEmpty == true) prefill['verlag'] = extra['bgg_publisher']!;
      if (extra['bgg_designer']?.isNotEmpty == true) prefill['designer'] = extra['bgg_designer']!;
      if (_urlPreview?.genres.isNotEmpty == true) prefill['genre'] = _urlPreview!.genres.take(5).join(', ');
    }
    if (mediaType == 'VIDEOGAME') {
      if (extra['bgg_year']?.isNotEmpty == true) prefill['jahr'] = extra['bgg_year']!;
      if (extra['bgg_designer']?.isNotEmpty == true) prefill['entwickler'] = extra['bgg_designer']!;
      if (extra['bgg_publisher']?.isNotEmpty == true) prefill['publisher'] = extra['bgg_publisher']!;
      if (extra['bgg_platform']?.isNotEmpty == true) prefill['plattform'] = extra['bgg_platform']!;
      if (extra['bgg_playtime']?.isNotEmpty == true) prefill['spielzeit'] = extra['bgg_playtime']!;
      if (_urlPreview?.genres.isNotEmpty == true) prefill['genre'] = _urlPreview!.genres.take(5).join(', ');
    }
    if (mediaType == 'TTRPG') {
      if (extra['bgg_publisher']?.isNotEmpty == true) prefill['verlag'] = extra['bgg_publisher']!;
      if (_urlPreview?.genres.isNotEmpty == true) prefill['genre'] = _urlPreview!.genres.take(5).join(', ');
    }
    if (mediaType == 'YOUTUBE') {
      if (_urlPreview?.authorName != null) prefill['kanal'] = _urlPreview!.authorName!;
      if (extra['youtube_laufzeit']?.isNotEmpty == true) prefill['laufzeit'] = extra['youtube_laufzeit']!;
      if (extra['youtube_hochgeladen']?.isNotEmpty == true) prefill['hochgeladen'] = extra['youtube_hochgeladen']!;
    }
    if (mediaType == 'GITHUB') {
      if (_urlPreview?.githubLanguage != null) prefill['sprache'] = _urlPreview!.githubLanguage!;
      if (_urlPreview?.githubStars != null) prefill['stars'] = _urlPreview!.githubStars.toString();
      if (_urlPreview?.githubLicense != null) prefill['lizenz'] = _urlPreview!.githubLicense!;
      if (_urlPreview?.genres.isNotEmpty == true) prefill['themen'] = _urlPreview!.genres.join(', ');
    }

    final toAdd = tpl.fields
        .where((f) => !existingKeys.contains(f.key.toLowerCase()))
        .map((f) {
          final pre = prefill[f.key.toLowerCase()];
          final val = pre ?? (f.defaultValue.isNotEmpty ? f.defaultValue : null);
          return EntryPropertiesCompanion(
            id: drift.Value('prop-${DateTime.now().microsecondsSinceEpoch}-${f.key}'),
            entryId: drift.Value(entryId),
            key: drift.Value(f.key),
            value: drift.Value(val),
            type: drift.Value(f.type),
          );
        })
        .toList();

    // Template-ID als _template-Property speichern (für Feed-Karte)
    final templateProp = EntryPropertiesCompanion(
      id: drift.Value('prop-tpl-${DateTime.now().microsecondsSinceEpoch}'),
      entryId: drift.Value(entryId),
      key: const drift.Value('_template'),
      value: drift.Value(tpl.id),
      type: const drift.Value('string'),
    );

    final baseProps = existing.map((p) => EntryPropertiesCompanion(
          id: drift.Value(p.id),
          entryId: drift.Value(p.entryId),
          key: drift.Value(p.key),
          value: drift.Value(p.value),
          type: drift.Value(p.type),
        ));

    final all = [
      ...baseProps,
      if (!existingKeys.contains('_template')) templateProp,
      ...toAdd,
    ];
    if (all.length > baseProps.length) {
      await dao.setProperties(entryId, all);
    }
  }

  Future<void> _saveAttachments(String entryId) async {
    // Audio-Anhang speichern
    if (_recordedAudioPath != null && File(_recordedAudioPath!).existsSync()) {
      final f = File(_recordedAudioPath!);
      await ref.read(attachmentDaoProvider).upsert(AttachmentsCompanion(
        id: drift.Value('att-audio-${DateTime.now().millisecondsSinceEpoch}'),
        entryId: drift.Value(entryId),
        type: const drift.Value('audio'),
        mimeType: const drift.Value('audio/mp4'),
        localPath: drift.Value(_recordedAudioPath!),
        fileName: drift.Value(p.basename(_recordedAudioPath!)),
        fileSize: drift.Value(await f.length()),
        durationMs: drift.Value(_recordingDuration.inMilliseconds),
      ));
    }

    // Sonstige Dateien (Video, PDF, etc.)
    if (_pendingFiles.isNotEmpty) {
      final attachmentsBase = await VaultManager.getAttachmentsPath();
      final now = DateTime.now();
      final subDir = Directory(
          p.join(attachmentsBase, '${now.year}', now.month.toString().padLeft(2, '0')));
      await subDir.create(recursive: true);
      for (final pf in _pendingFiles) {
        if (pf.path == null) continue;
        final src = File(pf.path!);
        if (!src.existsSync()) continue;
        final ext = pf.extension?.isNotEmpty == true ? '.${pf.extension}' : '';
        final destPath = p.join(subDir.path, '${DateTime.now().millisecondsSinceEpoch}$ext');
        await src.copy(destPath);
        final mime = _mimeForExt(pf.extension ?? '');
        final attType = _typeForMime(mime);
        await ref.read(attachmentDaoProvider).upsert(AttachmentsCompanion(
          id: drift.Value('att-${DateTime.now().millisecondsSinceEpoch}'),
          entryId: drift.Value(entryId),
          type: drift.Value(attType),
          mimeType: drift.Value(mime),
          localPath: drift.Value(destPath),
          fileName: drift.Value(pf.name),
          fileSize: drift.Value(await File(destPath).length()),
        ));
      }
    }

    if (_pendingImages.isEmpty) return;
    final attachmentsBase = await VaultManager.getAttachmentsPath();
    final now = DateTime.now();
    final subDir = Directory(
        p.join(attachmentsBase, '${now.year}', now.month.toString().padLeft(2, '0')));
    await subDir.create(recursive: true);

    for (final img in _pendingImages) {
      final ext = p.extension(img.path).toLowerCase().isEmpty
          ? '.jpg'
          : p.extension(img.path).toLowerCase();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}$ext';
      final destPath = p.join(subDir.path, fileName);
      await File(img.path).copy(destPath);

      // Absoluter Pfad — auf Mobile ändert sich der App-Pfad nicht
      await ref.read(attachmentDaoProvider).upsert(AttachmentsCompanion(
        id: drift.Value('att-${DateTime.now().millisecondsSinceEpoch}'),
        entryId: drift.Value(entryId),
        type: const drift.Value('image'),
        mimeType: drift.Value(ext == '.png' ? 'image/png' : 'image/jpeg'),
        localPath: drift.Value(destPath),
        fileName: drift.Value(fileName),
        fileSize: drift.Value(await File(destPath).length()),
      ));
    }
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _mimeForExt(String ext) => switch (ext.toLowerCase()) {
    'mp4' || 'mov' || 'avi' || 'mkv' || 'm4v' => 'video/mp4',
    'mp3' || 'm4a' || 'aac' || 'wav' || 'ogg' => 'audio/mpeg',
    'pdf' => 'application/pdf',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    _ => 'application/octet-stream',
  };

  static String _typeForMime(String mime) {
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('audio/')) return 'audio';
    if (mime.startsWith('image/')) return 'image';
    return 'file';
  }

  Future<void> _checkUrl() async {
    final url = UrlMetadataService.extractUrl(_bodyCtrl.text);
    if (url == null || url == _lastCheckedUrl) return;
    _lastCheckedUrl = url;
    setState(() => _loadingPreview = true);
    final meta = await UrlMetadataService.fetch(url);
    if (!mounted) return;
    setState(() {
      _urlPreview = meta;
      _loadingPreview = false;
      // Titel automatisch vorausfüllen wenn noch leer
      if (meta != null &&
          _titleCtrl.text.trim().isEmpty &&
          meta.title.isNotEmpty) {
        _titleCtrl.text = meta.title;
        _showTitle = true;
      }
    });
  }

  /// Schreibt die im Review-Sheet bestätigten Felder als Entry-Properties.
  /// Mergt mit bereits gesetzten Properties (z.B. og_title/domain aus
  /// createEntry) und überspringt bereits vorhandene Keys, um Dubletten zu
  /// vermeiden.
  Future<void> _writeResolvedFields(
      String entryId, List<ResolvedField> fields) async {
    if (fields.isEmpty) return;
    final dao = ref.read(propertyDaoProvider);
    final existing = await dao.watchByEntry(entryId).first;
    final existingKeys = existing.map((p) => p.key).toSet();
    final merged = <EntryPropertiesCompanion>[
      ...existing.map((p) => EntryPropertiesCompanion(
            id: drift.Value(p.id),
            entryId: drift.Value(p.entryId),
            key: drift.Value(p.key),
            value: drift.Value(p.value),
            type: drift.Value(p.type),
          )),
    ];
    var i = 0;
    for (final f in fields) {
      if (existingKeys.contains(f.storageKey)) continue;
      merged.add(EntryPropertiesCompanion(
        id: drift.Value(
            'prop-${DateTime.now().microsecondsSinceEpoch}-${i++}'),
        entryId: drift.Value(entryId),
        key: drift.Value(f.storageKey),
        value: drift.Value(f.value),
        type: drift.Value(f.propType),
      ));
    }
    await dao.setProperties(entryId, merged);
  }

  Future<void> _save() async {
    final rawBody = _bodyCtrl.text.trim();
    if (rawBody.isEmpty && _pendingImages.isEmpty && _recordedAudioPath == null) return;

    setState(() => _isSaving = true);

    // Falls die URL-Preview noch lädt, kurz warten (max 3s)
    if (_loadingPreview) {
      for (var i = 0; i < 30 && _loadingPreview; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    // URL aus Body entfernen (wird als sourceUrl gespeichert)
    final detectedUrl = UrlMetadataService.extractUrl(rawBody);
    final cleanBody = detectedUrl != null
        ? rawBody.replaceAll(detectedUrl, '').trim()
        : rawBody;
    final finalBody = cleanBody;

    // Titel: explizit > URL-Vorschau-Titel > Sprachnotiz-Auto-Titel > null
    final explicitTitle = _titleCtrl.text.trim();
    String? resolvedTitle = explicitTitle.isNotEmpty
        ? explicitTitle
        : (_urlPreview?.title.isNotEmpty == true ? _urlPreview!.title : null);
    // Auto-Titel für reine Sprachaufnahmen ohne Text
    if (resolvedTitle == null &&
        _recordedAudioPath != null &&
        rawBody.isEmpty &&
        _pendingImages.isEmpty) {
      resolvedTitle =
          'Sprachnotiz – ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}';
    }
    // Auto-Titel für Bild-Notizen ohne eigenen Text/Titel
    if (resolvedTitle == null && _pendingImages.isNotEmpty && rawBody.isEmpty) {
      resolvedTitle =
          'Bild – ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}';
    }

    // Abgerufene Metadaten vor dem finalen Speichern bestätigen lassen:
    // an-/abwählen, überschreiben, eigene Felder ergänzen.
    List<ResolvedField> resolvedFields = const [];
    if (_urlPreview != null) {
      final record = MetadataRecord.fromUrlMetadata(_urlPreview!,
          url: detectedUrl ?? '');
      if (record.describedFields().isNotEmpty) {
        if (!mounted) return;
        final picked = await FieldImportSheet.show(
          context,
          record: record,
          prefs: AppSettings.loadApiFieldPrefs(),
        );
        if (!mounted) return;
        if (picked == null) {
          // Abgebrochen → Speichern abbrechen, zurück zum Bearbeiten.
          setState(() => _isSaving = false);
          return;
        }
        resolvedFields = picked;
      }
    }

    try {
      final createdEntry = await ref.read(entryRepositoryProvider).createEntry(
            body: finalBody,
            title: resolvedTitle,
            status: widget.parentEntryId != null ? 'sub_note' : 'inbox',
            containerIds: widget.initialContainerId != null
                ? [widget.initialContainerId!]
                : [],
            sourceUrl: detectedUrl,
            urlTitle: _urlPreview?.title,
            urlDomain: _urlPreview?.domain,
            urlMediaType: _urlPreview?.mediaType,
            // Saison-Kette ist nicht nutzer-wählbar (interne Verkettung).
            anilistSeason: _urlPreview?.anilistSeason,
            anilistTotalSeasons: _urlPreview?.anilistTotalSeasons,
          );
      // Vom Nutzer bestätigte Felder generisch als Properties schreiben.
      await _writeResolvedFields(createdEntry.entry.id, resolvedFields);
      // Seiten-Haupttext versteckt ablegen → spätere KI-Anreicherung nutzt ihn
      // als Treibstoff (#27).
      final pageText = _urlPreview?.pageText ?? '';
      if (pageText.isNotEmpty) {
        await _writeResolvedFields(createdEntry.entry.id,
            [ResolvedField('_pagetext', pageText, 'string')]);
      }
      // Parent-Entry-Verknüpfung als Property speichern
      if (widget.parentEntryId != null) {
        final dao = ref.read(propertyDaoProvider);
        final existing = await dao.watchByEntry(createdEntry.entry.id).first;
        await dao.setProperties(createdEntry.entry.id, [
          ...existing.map((p) => EntryPropertiesCompanion(
                id: drift.Value(p.id), entryId: drift.Value(p.entryId),
                key: drift.Value(p.key), value: drift.Value(p.value),
                type: drift.Value(p.type),
              )),
          EntryPropertiesCompanion(
            id: drift.Value('prop-parent-${DateTime.now().microsecondsSinceEpoch}'),
            entryId: drift.Value(createdEntry.entry.id),
            key: const drift.Value('parent_entry_id'),
            value: drift.Value(widget.parentEntryId),
            type: const drift.Value('string'),
          ),
        ]);
      }

      await _saveAttachments(createdEntry.entry.id);

      // Anhänge gespeichert → Entry touchen damit der Feed-Stream neu emittiert
      // (Stream hört nur auf entries-Tabelle, nicht auf attachments)
      if (_pendingImages.isNotEmpty || _recordedAudioPath != null) {
        await ref.read(entryRepositoryProvider).updateEntry(createdEntry.entry.id);
      }

      // ── Inline-Tasks verarbeiten ─────────────────────────────────────────
      final updatedBody = await ref
          .read(entryRepositoryProvider)
          .processInlineTasks(createdEntry.entry.id, finalBody);
      if (updatedBody != finalBody) {
        await ref.read(entryRepositoryProvider).updateEntry(
              createdEntry.entry.id,
              body: updatedBody,
            );
      }

      // ── Auto-Template für AniList & YouTube ─────────────────────────────
      final mediaType = _urlPreview?.mediaType;
      if (mediaType != null) {
        await _autoApplyTemplate(createdEntry.entry.id, mediaType);
      }

      // Auto-KI Anreicherung wenn Toggle aktiv (über die Profil-Kette).
      if (_autoAi) {
        try {
          // Der KI den vollen Feld-Satz + Seiten-Haupttext als Kontext geben.
          final ctxParts = <String>[];
          if (_urlPreview != null) {
            final fields = MetadataRecord.fromUrlMetadata(_urlPreview!,
                    url: detectedUrl ?? '')
                .aiContext();
            if (fields.isNotEmpty) ctxParts.add(fields);
          }
          if (pageText.isNotEmpty) ctxParts.add('SEITENINHALT:\n$pageText');
          final aiCtx = ctxParts.join('\n\n');
          final existingTagNames =
              await ref.read(tagDaoProvider).getAllTagNames();
          final result = await AiService.runForTask(
            ref,
            LlmTask.enrichment,
            (svc) => svc.enrichEntry(
              createdEntry.entry.body,
              existingTitle: createdEntry.entry.title,
              extraContext: aiCtx.isNotEmpty ? aiCtx : null,
              existingTags: existingTagNames,
            ),
          );
          if (result.tags.isNotEmpty || result.title != null) {
            await ref.read(entryRepositoryProvider).updateEntry(
                  createdEntry.entry.id,
                  title: result.title ?? createdEntry.entry.title,
                );
            if (result.tags.isNotEmpty) {
              final existingTags = await ref
                  .read(tagDaoProvider)
                  .getTagNamesForEntry(createdEntry.entry.id);
              final merged = {...existingTags, ...result.tags}.toList();
              await ref
                  .read(tagDaoProvider)
                  .setEntryTags(createdEntry.entry.id, merged);
            }
          }
        } catch (_) {
          // KI-Fehler still ignorieren — Eintrag ist gespeichert
        }
      }

      // Auto-Sync wenn Sync aktiviert ist
      if (AppSettings.getSyncEnabled()) {
        ref.read(syncStateProvider.notifier).triggerSync();
      }

      if (mounted) {
        // Bei Link-Einträgen (angereichert) direkt das Detail öffnen, damit
        // Container/Tags ohne erneutes Suchen+Anklicken gesetzt werden können.
        final openDetail = detectedUrl != null && widget.parentEntryId == null;
        if (widget.onBack != null) {
          if (openDetail) navigateToEntry(context, ref, createdEntry.entry.id);
          widget.onBack!();
        } else {
          Navigator.pop(context);
          if (openDetail) navigateToEntry(context, ref, createdEntry.entry.id);
        }
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fehler beim Speichern: $e'),
            backgroundColor: Colors.red.shade900,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = (_bodyCtrl.text.trim().isNotEmpty || _pendingImages.isNotEmpty || _recordedAudioPath != null) && !_isSaving;

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        leading: IconButton(
          icon: const Icon(Icons.close, color: MFColors.textSecondary),
          onPressed: () {
            if (widget.onBack != null) widget.onBack!();
            else Navigator.pop(context);
          },
        ),
        title: const Text(
          'Neuer Eintrag',
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: MFColors.textPrimary),
        ),
        actions: [
          _OptionsToggle(
            autoSave: _autoSave,
            autoAi: _autoAi,
            onChanged: (save, ai) =>
                setState(() { _autoSave = save; _autoAi = ai; }),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: canSave ? _save : null,
              child: _isSaving
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: MFColors.teal))
                  : Text(
                      'Speichern',
                      style: TextStyle(
                        color: canSave ? MFColors.teal : MFColors.textMuted,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const Divider(height: 1),

          // Titel (eingeblendet wenn Toggle aktiv)
          if (_showTitle)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _titleCtrl,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: MFColors.textPrimary,
                ),
                decoration: const InputDecoration(
                  hintText: 'Titel (optional)',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  filled: false,
                ),
              ),
            ),

          // Body
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: WikilinkTextField(
                controller: _bodyCtrl,
                focusNode: _bodyFocus,
                expands: true,
                style: const TextStyle(
                  fontSize: 15,
                  color: MFColors.textPrimary,
                  height: 1.6,
                ),
                decoration: const InputDecoration(
                  hintText:
                      'Gedanke, Link, #tag, [[Wikilink]]…\n\n'
                      'Tippe #tag für automatische Kategorisierung.\n'
                      'Verknüpfe Notizen mit [[Titel der Notiz]].',
                  hintStyle: TextStyle(
                      color: MFColors.textMuted, fontSize: 14, height: 1.6),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  filled: false,
                ),
              ),
            ),
          ),

          // URL-Preview (lädt automatisch beim Eintippen)
          if (_loadingPreview)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: MFColors.border))),
              child: const Row(children: [
                SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: MFColors.teal),
                ),
                SizedBox(width: 10),
                Text('Link wird geladen…',
                    style: TextStyle(
                        fontSize: 12, color: MFColors.textMuted)),
              ]),
            )
          else if (_urlPreview != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              decoration: BoxDecoration(
                color: MFColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: MFColors.border),
              ),
              child: Row(children: [
                if (_urlPreview!.image != null)
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(9),
                      bottomLeft: Radius.circular(9),
                    ),
                    child: Image.network(
                      _urlPreview!.image!,
                      width: 56, height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_urlPreview!.title,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: MFColors.textPrimary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        if (_urlPreview!.description.isNotEmpty)
                          Text(_urlPreview!.description,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: MFColors.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        Text(_urlPreview!.domain,
                            style: const TextStyle(
                                fontSize: 10, color: MFColors.textMuted)),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 14, color: MFColors.textMuted),
                  onPressed: () =>
                      setState(() { _urlPreview = null; _lastCheckedUrl = null; }),
                ),
              ]),
            ),

          // Tag-Preview
          if (_parsedTags.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: MFColors.border))),
              child: Wrap(
                spacing: 6, runSpacing: 4,
                children: _parsedTags
                    .map((t) => _TagPreviewChip(t))
                    .toList(),
              ),
            ),

          // Bild-Thumbnails
          if (_pendingImages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: _analyzeImage,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF8B5CF6)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_awesome, size: 14, color: Color(0xFF8B5CF6)),
                      SizedBox(width: 6),
                      Text('KI aus Bild',
                          style: TextStyle(color: Color(0xFF8B5CF6), fontSize: 12)),
                    ]),
                  ),
                ),
              ),
            ),
          if (_pendingImages.isNotEmpty)
            Container(
              height: 72,
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: MFColors.border))),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                itemCount: _pendingImages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(_pendingImages[i].path),
                      width: 56, height: 56, fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 0, right: 0,
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _pendingImages.removeAt(i)),
                      child: Container(
                        width: 18, height: 18,
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: const Icon(Icons.close,
                            size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ]),
              ),
            ),

          // Sonstige Datei-Anhänge (Video/PDF/etc.)
          if (_pendingFiles.isNotEmpty)
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: MFColors.border))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _pendingFiles.asMap().entries.map((e) {
                  final f = e.value;
                  final ext = (f.extension ?? '').toLowerCase();
                  final isVideo = ['mp4','mov','avi','mkv','m4v'].contains(ext);
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isVideo ? Icons.videocam_outlined : Icons.attach_file_rounded,
                      color: isVideo ? const Color(0xFFF59E0B) : MFColors.teal,
                      size: 18,
                    ),
                    title: Text(f.name,
                        style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
                        overflow: TextOverflow.ellipsis),
                    subtitle: f.size > 0
                        ? Text(_fmtBytes(f.size),
                            style: const TextStyle(fontSize: 10, color: MFColors.textMuted))
                        : null,
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 14, color: MFColors.textMuted),
                      onPressed: () => setState(() => _pendingFiles.removeAt(e.key)),
                    ),
                  );
                }).toList(),
              ),
            ),

          // Toolbar
          // Audio-Aufnahme-Anzeige
          if (_isRecording || _recordedAudioPath != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: MFColors.border))),
              child: Row(children: [
                Icon(
                  _isRecording ? Icons.fiber_manual_record : Icons.mic_rounded,
                  size: 16,
                  color: _isRecording ? Colors.redAccent : MFColors.teal,
                ),
                const SizedBox(width: 8),
                Text(
                  _isRecording
                      ? 'Aufnahme: ${_formatDuration(_recordingDuration)}'
                      : 'Aufnahme: ${_formatDuration(_recordingDuration)} ✓',
                  style: TextStyle(
                    fontSize: 13,
                    color: _isRecording ? Colors.redAccent : MFColors.teal,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                if (_recordedAudioPath != null && !_isRecording)
                  GestureDetector(
                    onTap: () => setState(() {
                      _recordedAudioPath = null;
                      _recordingDuration = Duration.zero;
                    }),
                    child: const Icon(Icons.close, size: 16, color: MFColors.textMuted),
                  ),
                if (_isRecording)
                  GestureDetector(
                    onTap: _toggleRecording,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: const Text('Stopp',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
              ]),
            ),

          // Formatierungs-Leiste (Fett/Kursiv/Strike/Liste/Link + QR-Scan).
          // Der _bodyCtrl-Listener (_onBodyChanged) stößt URL-Vorschau und
          // Tag-Parsing nach jeder Änderung selbst an.
          FormatToolbar(controller: _bodyCtrl, focusNode: _bodyFocus),
          _CaptureToolbar(
            onTitleToggle: () =>
                setState(() => _showTitle = !_showTitle),
            onImagePick: _pickImage,
            onFilePick: _pickFile,
            onTagInsert: () => _insertAtCursor('#'),
            onLinkInsert: () => _insertAtCursor('https://'),
            onMicTap: _toggleRecording,
            onTaskInsert: _insertTaskLine,
            isRecording: _isRecording,
            hasAudio: _recordedAudioPath != null,
          ),
        ],
      ),
    );
  }
}

// ─── Widgets ──────────────────────────────────────────────────────────────────

class _TagPreviewChip extends StatelessWidget {
  final String tag;
  const _TagPreviewChip(this.tag);
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
              fontSize: 11, fontWeight: FontWeight.w600,
              color: MFColors.teal, fontFamily: 'monospace')),
      );
}

class _CaptureToolbar extends StatelessWidget {
  final VoidCallback onTitleToggle;
  final VoidCallback onImagePick;
  final VoidCallback onFilePick;
  final VoidCallback onTagInsert;
  final VoidCallback onLinkInsert;
  final VoidCallback onMicTap;
  final VoidCallback? onTaskInsert;
  final bool isRecording;
  final bool hasAudio;
  const _CaptureToolbar({
    required this.onTitleToggle,
    required this.onImagePick,
    required this.onFilePick,
    required this.onTagInsert,
    required this.onLinkInsert,
    required this.onMicTap,
    this.onTaskInsert,
    this.isRecording = false,
    this.hasAudio = false,
  });

  @override
  Widget build(BuildContext context) => Container(
        height: 48,
        decoration: const BoxDecoration(
          color: MFColors.surface,
          border: Border(top: BorderSide(color: MFColors.border))),
        child: Row(children: [
          _TBtn(Icons.title_rounded, 'Titel', onTitleToggle),
          _TBtn(Icons.image_outlined, 'Bild', onImagePick),
          _TBtn(Icons.attach_file_rounded, 'Datei', onFilePick),
          _TBtn(Icons.link_rounded, 'Link', onLinkInsert),
          if (onTaskInsert != null)
            _TBtn(Icons.add_task_rounded, 'Aufgabe', onTaskInsert!),
          IconButton(
            icon: Icon(
              isRecording
                  ? Icons.stop_rounded
                  : hasAudio
                      ? Icons.mic_rounded
                      : Icons.mic_outlined,
              size: 20,
              color: isRecording
                  ? Colors.redAccent
                  : hasAudio
                      ? MFColors.teal
                      : MFColors.textSecondary,
            ),
            tooltip: isRecording ? 'Aufnahme stoppen' : 'Sprachaufnahme',
            onPressed: onMicTap,
          ),
          const Spacer(),
          _TBtn(Icons.tag_rounded, '#Tag', onTagInsert),
        ]),
      );
}

class _TBtn extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const _TBtn(this.icon, this.tip, this.onTap);
  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: 20, color: MFColors.textSecondary),
        tooltip: tip,
        onPressed: onTap,
      );
}

class _OptionsToggle extends StatelessWidget {
  final bool autoSave, autoAi;
  final void Function(bool, bool) onChanged;
  const _OptionsToggle(
      {required this.autoSave,
      required this.autoAi,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(Icons.tune_rounded,
            size: 20,
            color: (autoSave || autoAi)
                ? MFColors.teal
                : MFColors.textSecondary),
        tooltip: 'Optionen',
        onPressed: () => _show(context),
      );

  void _show(BuildContext context) => showModalBottomSheet(
        context: context,
        backgroundColor: MFColors.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('SPEICHER-OPTIONEN',
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold,
                      color: MFColors.textMuted, letterSpacing: 1.2)),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: autoSave,
              onChanged: (v) {
                onChanged(v, autoAi);
                Navigator.pop(context);
              },
              activeThumbColor: MFColors.teal,
              title: const Text('Sofort speichern',
                  style: TextStyle(
                      color: MFColors.textPrimary, fontSize: 14)),
              subtitle: const Text('Ohne Vorschau direkt in den Feed',
                  style: TextStyle(
                      color: MFColors.textMuted, fontSize: 12)),
            ),
            SwitchListTile(
              value: autoAi,
              onChanged: (v) {
                onChanged(autoSave, v);
                Navigator.pop(context);
              },
              activeThumbColor: MFColors.teal,
              title: const Text('AI-Anreicherung automatisch',
                  style: TextStyle(
                      color: MFColors.textPrimary, fontSize: 14)),
              subtitle: const Text(
                  'Tags & Properties nach dem Speichern generieren',
                  style: TextStyle(
                      color: MFColors.textMuted, fontSize: 12)),
            ),
          ]),
        ),
      );
}
