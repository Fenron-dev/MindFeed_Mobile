import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../core/vault_manager.dart';
import '../../data/db/app_database.dart' hide Container;
import '../../data/repositories/entry_repository.dart';
import '../../domain/tag_parser.dart';
import '../../services/url_metadata_service.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  final String? initialText;
  const CaptureScreen({super.key, this.initialText});

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
      _bodyFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _urlDebounce?.cancel();
    _wikilinkDebounce?.cancel();
    _bodyCtrl.removeListener(_onBodyChanged);
    _bodyCtrl.dispose();
    _titleCtrl.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _onBodyChanged() {
    setState(() {
      _parsedTags = TagParser.parse(_bodyCtrl.text);
    });
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

  Future<void> _saveAttachments(String entryId) async {
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

      final relPath = p.relative(destPath,
          from: p.dirname(p.dirname(attachmentsBase)));
      await ref.read(attachmentDaoProvider).upsert(AttachmentsCompanion(
        id: drift.Value('att-${DateTime.now().millisecondsSinceEpoch}'),
        entryId: drift.Value(entryId),
        type: const drift.Value('image'),
        mimeType: drift.Value(ext == '.png' ? 'image/png' : 'image/jpeg'),
        localPath: drift.Value(relPath),
        fileName: drift.Value(fileName),
        fileSize: drift.Value(await File(destPath).length()),
      ));
    }
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
    if (rawBody.isEmpty) return;

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
    final finalBody = cleanBody.isEmpty ? 'Link-Verweis' : cleanBody;

    // Titel: explizit > URL-Vorschau-Titel > aus Body
    final explicitTitle = _titleCtrl.text.trim();
    final resolvedTitle = explicitTitle.isNotEmpty
        ? explicitTitle
        : (_urlPreview?.title.isNotEmpty == true ? _urlPreview!.title : null);

    try {
      final createdEntry = await ref.read(entryRepositoryProvider).createEntry(
            body: finalBody,
            title: resolvedTitle,
            sourceUrl: detectedUrl,
            urlTitle: _urlPreview?.title,
            urlDescription: _urlPreview?.description,
            urlImage: _urlPreview?.image,
            urlDomain: _urlPreview?.domain,
            urlGenres: _urlPreview?.genres ?? [],
            urlScore: _urlPreview?.score,
            urlMediaType: _urlPreview?.mediaType,
          );
      await _saveAttachments(createdEntry.entry.id);
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
    final canSave = _bodyCtrl.text.trim().isNotEmpty && !_isSaving;

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

          // Toolbar
          _CaptureToolbar(
            onTitleToggle: () =>
                setState(() => _showTitle = !_showTitle),
            onImagePick: _pickImage,
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
  const _CaptureToolbar({
    required this.onTitleToggle,
    required this.onImagePick,
  });

  @override
  Widget build(BuildContext context) => Container(
        height: 48,
        decoration: const BoxDecoration(
          color: MFColors.surface,
          border: Border(top: BorderSide(color: MFColors.border))),
        child: Row(children: [
          _TBtn(Icons.title_rounded, 'Titel', onTitleToggle),
          _TBtn(Icons.image_outlined, 'Bild anhängen', onImagePick),
          _TBtn(Icons.mic_outlined, 'Sprachaufnahme', () {}),
          const Spacer(),
          _TBtn(Icons.tag_rounded, 'Tag', () {}),
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
