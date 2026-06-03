import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../core/vault_manager.dart';
import '../../data/db/app_database.dart' hide Container;
import '../../data/repositories/entry_repository.dart';
import '../../domain/tag_parser.dart';
import '../../services/app_settings.dart';
import '../../services/openrouter_service.dart';
import '../../services/url_metadata_service.dart';

const _storage = FlutterSecureStorage();
const _keyApiKey = 'openrouter_api_key';
const _keyAiModel = 'openrouter_model';

class CaptureScreen extends ConsumerStatefulWidget {
  final String? initialText;
  final List<String>? sharedFilePaths;
  const CaptureScreen({super.key, this.initialText, this.sharedFilePaths});

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

  // Wikilink-Autocomplete
  List<EntryWithDetails> _wikilinkSuggestions = [];
  bool _wikilinkLoading = false;
  Timer? _wikilinkDebounce;
  String? _partialWikilink; // Text nach [[

  // Bild-Anhänge
  final List<XFile> _pendingImages = [];

  // Audio-Aufnahme
  final _recorder = AudioRecorder();
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialText != null && widget.initialText!.isNotEmpty) {
        _bodyCtrl.text = widget.initialText!;
        _onBodyChanged();
      }
      // Geteilte Dateien aus anderen Apps übernehmen
      if (widget.sharedFilePaths != null) {
        _importSharedFiles(widget.sharedFilePaths!);
      }
      _bodyFocus.requestFocus();
    });
  }

  Timer? _autoSaveDebounce;

  @override
  void dispose() {
    _urlDebounce?.cancel();
    _wikilinkDebounce?.cancel();
    _autoSaveDebounce?.cancel();
    _recordingTimer?.cancel();
    _recorder.dispose();
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
    _checkWikilinkContext();
  }

  void _checkWikilinkContext() {
    final text = _bodyCtrl.text;
    // Letztes [[ das kein ]] danach hat → aktive Wikilink-Eingabe
    final openIdx = text.lastIndexOf('[[');
    if (openIdx == -1) {
      if (_partialWikilink != null) setState(() { _wikilinkSuggestions = []; _partialWikilink = null; _wikilinkLoading = false; });
      return;
    }
    final afterOpen = text.substring(openIdx + 2);
    if (afterOpen.contains(']]')) {
      if (_partialWikilink != null) setState(() { _wikilinkSuggestions = []; _partialWikilink = null; _wikilinkLoading = false; });
      return;
    }

    final partial = afterOpen.trim();
    if (partial == _partialWikilink) return;
    _partialWikilink = partial;
    setState(() => _wikilinkLoading = true); // sofort Ladeindikator zeigen

    _wikilinkDebounce?.cancel();
    _wikilinkDebounce = Timer(const Duration(milliseconds: 180), () async {
      final results = await ref
          .read(entryRepositoryProvider)
          .search(partial.isEmpty ? '' : partial);
      if (mounted) {
        setState(() {
          _wikilinkSuggestions = results.take(8).toList();
          _wikilinkLoading = false;
        });
      }
    });
  }

  void _insertWikilink(String title) {
    final text = _bodyCtrl.text;
    final openIdx = text.lastIndexOf('[[');
    if (openIdx == -1) return;

    // Alles ab [[ ersetzen mit [[Title]]
    final before = text.substring(0, openIdx);
    final newText = '$before[[$title]]';
    _bodyCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
    setState(() { _wikilinkSuggestions = []; _partialWikilink = null; });
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
    if (_isRecording) {
      // Aufnahme stoppen
      _recordingTimer?.cancel();
      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _recordedAudioPath = path;
      });
    } else {
      // Aufnahme starten
      final hasPermission = await _recorder.hasPermission();
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

      await _recorder.start(
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

    if (toAdd.isNotEmpty) {
      final all = [
        ...existing.map((p) => EntryPropertiesCompanion(
              id: drift.Value(p.id),
              entryId: drift.Value(p.entryId),
              key: drift.Value(p.key),
              value: drift.Value(p.value),
              type: drift.Value(p.type),
            )),
        ...toAdd,
      ];
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

    // Titel: explizit > URL-Vorschau-Titel > aus Body
    final explicitTitle = _titleCtrl.text.trim();
    final resolvedTitle = explicitTitle.isNotEmpty
        ? explicitTitle
        : (_urlPreview?.title.isNotEmpty == true ? _urlPreview!.title : null);

    // API-Feld-Einstellungen laden und anwenden
    final apiFields = AppSettings.loadApiFieldSettings();
    final isAniList = _urlPreview?.domain == 'anilist.co';
    final isBgg = _urlPreview?.domain == 'boardgamegeek.com';

    try {
      final createdEntry = await ref.read(entryRepositoryProvider).createEntry(
            body: finalBody,
            title: resolvedTitle,
            sourceUrl: detectedUrl,
            urlTitle: _urlPreview?.title,
            // Beschreibung je nach API-Settings
            urlDescription: (isAniList && !apiFields.aniDescription) ||
                    (isBgg && !apiFields.bggDescription)
                ? null
                : _urlPreview?.description,
            urlImage: (isAniList && !apiFields.aniImage) ||
                    (isBgg && !apiFields.bggImage)
                ? null
                : _urlPreview?.image,
            urlDomain: _urlPreview?.domain,
            urlGenres: (isAniList && !apiFields.aniGenres) ||
                    (isBgg && !apiFields.bggCategories)
                ? []
                : _urlPreview?.genres ?? [],
            urlScore: (isAniList && !apiFields.aniScore) ||
                    (isBgg && !apiFields.bggScore)
                ? null
                : _urlPreview?.score,
            urlMediaType: _urlPreview?.mediaType,
            anilistFormat: (isAniList && apiFields.aniFormat)
                ? _urlPreview?.anilistFormat
                : null,
            anilistEpisodes: (isAniList && apiFields.aniEpisodes)
                ? _urlPreview?.anilistEpisodes
                : null,
            anilistChapters: (isAniList && apiFields.aniEpisodes)
                ? _urlPreview?.anilistChapters
                : null,
            anilistStudio: (isAniList && apiFields.aniStudio)
                ? _urlPreview?.anilistStudio
                : null,
            anilistYear: (isAniList && apiFields.aniYear)
                ? _urlPreview?.anilistYear
                : null,
            anilistStatus: (isAniList && apiFields.aniStatus)
                ? _urlPreview?.anilistStatus
                : null,
            anilistSeason: isAniList ? _urlPreview?.anilistSeason : null,
            anilistTotalSeasons:
                isAniList ? _urlPreview?.anilistTotalSeasons : null,
            urlAuthor: _urlPreview?.authorName,
            githubStars: _urlPreview?.githubStars,
            githubForks: _urlPreview?.githubForks,
            githubLicense: _urlPreview?.githubLicense,
            githubWebsite: _urlPreview?.githubWebsite,
            githubLanguage: _urlPreview?.githubLanguage,
            githubDefaultBranch: _urlPreview?.githubDefaultBranch,
            extraProps: _urlPreview?.extraProps ?? {},
          );
      await _saveAttachments(createdEntry.entry.id);

      // Anhänge gespeichert → Entry touchen damit der Feed-Stream neu emittiert
      // (Stream hört nur auf entries-Tabelle, nicht auf attachments)
      if (_pendingImages.isNotEmpty || _recordedAudioPath != null) {
        await ref.read(entryRepositoryProvider).updateEntry(createdEntry.entry.id);
      }

      // ── Auto-Template für AniList & YouTube ─────────────────────────────
      final mediaType = _urlPreview?.mediaType;
      if (mediaType != null) {
        await _autoApplyTemplate(createdEntry.entry.id, mediaType);
      }

      // Auto-KI Anreicherung wenn Toggle aktiv
      if (_autoAi) {
        final apiKey = await _storage.read(key: _keyApiKey) ?? '';
        if (apiKey.isNotEmpty) {
          try {
            final model = await _storage.read(key: _keyAiModel) ?? '';
            final tempStr = await _storage.read(key: 'openrouter_temperature');
            final tokStr = await _storage.read(key: 'openrouter_max_tokens');
            final svc = OpenRouterService(
              apiKey: apiKey,
              model: model.isNotEmpty ? model : OpenRouterService.defaultModel,
              temperature: double.tryParse(tempStr ?? '') ?? 0.3,
              maxTokens: int.tryParse(tokStr ?? '') ?? 400,
            );
            // Zusätzlichen Kontext aus URL-Metadaten aufbauen
            final extraParts = <String>[];
            if (_urlPreview?.description?.isNotEmpty == true) {
              extraParts.add(_urlPreview!.description!);
            }
            if ((_urlPreview?.genres ?? []).isNotEmpty) {
              extraParts.add('Genres: ${_urlPreview!.genres!.join(', ')}');
            }
            final result = await svc.enrichEntry(
              createdEntry.entry.body,
              existingTitle: createdEntry.entry.title,
              extraContext: extraParts.isNotEmpty ? extraParts.join('\n') : null,
            );
            if (result.tags.isNotEmpty || result.title != null) {
              final tagLine = result.tags.map((t) => '#$t').join(' ');
              await ref.read(entryRepositoryProvider).updateEntry(
                    createdEntry.entry.id,
                    title: result.title ?? createdEntry.entry.title,
                    body: result.tags.isNotEmpty
                        ? '${createdEntry.entry.body}\n$tagLine'
                        : createdEntry.entry.body,
                  );
            }
          } catch (_) {
            // KI-Fehler still ignorieren — Eintrag ist gespeichert
          }
        }
      }

      if (mounted) Navigator.pop(context);
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
          onPressed: () => Navigator.pop(context),
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
              child: TextField(
                controller: _bodyCtrl,
                focusNode: _bodyFocus,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
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

          // Wikilink-Autocomplete Suggestion Bar
          if (_wikilinkSuggestions.isNotEmpty || _wikilinkLoading)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              decoration: const BoxDecoration(
                color: MFColors.surfaceAlt,
                border: Border(top: BorderSide(color: MFColors.border))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 3),
                    child: Row(children: [
                      const Text('Wikilink einfügen:',
                          style: TextStyle(
                              fontSize: 10, color: MFColors.textMuted,
                              fontFamily: 'monospace')),
                      if (_wikilinkLoading) ...[
                        const SizedBox(width: 6),
                        const SizedBox(
                          width: 8, height: 8,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: MFColors.teal),
                        ),
                      ],
                    ]),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _wikilinkSuggestions.map((item) {
                        final title = item.entry.title ?? 'Unbenannt';
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onTap: () => _insertWikilink(title),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1B4B),
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(
                                    color: const Color(0xFF4338CA),
                                    width: 0.5),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.layers_outlined,
                                    size: 11, color: Color(0xFFA78BFA)),
                                const SizedBox(width: 4),
                                Text(
                                  title.length > 24
                                      ? '${title.substring(0, 24)}…'
                                      : title,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFFA78BFA),
                                      fontWeight: FontWeight.w500),
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

          _CaptureToolbar(
            onTitleToggle: () =>
                setState(() => _showTitle = !_showTitle),
            onImagePick: _pickImage,
            onFilePick: _pickFile,
            onTagInsert: () => _insertAtCursor('#'),
            onLinkInsert: () => _insertAtCursor('https://'),
            onMicTap: _toggleRecording,
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
  final bool isRecording;
  final bool hasAudio;
  const _CaptureToolbar({
    required this.onTitleToggle,
    required this.onImagePick,
    required this.onFilePick,
    required this.onTagInsert,
    required this.onLinkInsert,
    required this.onMicTap,
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
