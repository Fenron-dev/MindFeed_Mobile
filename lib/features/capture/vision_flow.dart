import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../services/ai/ai_service.dart';
import '../../services/ai/image_vision.dart';
import '../../services/ai/llm_profile.dart';
import '../../services/ai/llm_profiles_store.dart';
import '../../services/openrouter_service.dart';
import '../../services/url_metadata_service.dart';

/// Vom Nutzer bestätigtes Ergebnis der Bild-Analyse, das in eine Notiz fließt.
class VisionOutcome {
  final String? title;
  final String? summary;
  final List<String> tags;

  /// Echte Quell-Metadaten (per Link-Fetch oder AniList-Titelsuche). Ist dies
  /// gesetzt, wird die Notiz **wie ein eingegebener Link** aufgebaut
  /// (Cover/Properties); das aufgenommene Foto bleibt nur Anhang.
  final UrlMetadata? metadata;

  const VisionOutcome(
      {this.title, this.summary, this.tags = const [], this.metadata});
}

/// Führt die komplette Bild→Notiz-Analyse aus: Vision-Modell (Profil-Kette) →
/// Bestätigungs-/Korrektur-Dialog → optional echte Metadaten (AniList).
/// Gibt `null` zurück, wenn abgebrochen oder kein Ergebnis.
Future<VisionOutcome?> runVisionFlow(
  BuildContext context,
  WidgetRef ref,
  Uint8List bytes, {
  List<String> existingTags = const [],
}) async {
  // Vision-Profil vorhanden?
  if (ref.read(llmProfilesProvider).chainFor(LlmTask.vision).isEmpty) {
    _snack(context,
        'Kein Vision-Profil zugewiesen. Einstellungen → KI-Profile → Vorgang „Bild-Analyse".');
    return null;
  }

  // Datenschutz-Hinweis bei Cloud-Profil (einmal pro Aufruf).
  final visionChain = ref.read(llmProfilesProvider).chainFor(LlmTask.vision);
  if (visionChain.any((p) => !p.isLocal)) {
    final ok = await _confirm(context,
        'Das Bild wird zur Analyse an einen Cloud-KI-Dienst gesendet. Fortfahren?');
    if (ok != true) return null;
  }

  // Analyse mit Ladeanzeige.
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
        child: CircularProgressIndicator(color: MFColors.teal)),
  );
  VisionResult result;
  try {
    final dataUrl = ImageVision.toDataUrl(bytes);
    result = await AiService.runForTask(
      ref,
      LlmTask.vision,
      (svc) => svc.analyzeImage(dataUrl, existingTags: existingTags),
    );
  } catch (e) {
    if (context.mounted) Navigator.pop(context); // Ladeanzeige
    if (context.mounted) _snack(context, 'Bild-Analyse fehlgeschlagen: $e');
    return null;
  }
  if (context.mounted) Navigator.pop(context); // Ladeanzeige
  if (!context.mounted) return null;

  // Bestätigungs-/Korrektur-Dialog.
  final confirmed = await _confirmDialog(context, result);
  if (confirmed == null) return null;

  // Echte Quell-Metadaten beschaffen, damit die Notiz wie ein Link-Eintrag
  // aussieht (Cover + Properties), statt das Foto als Hauptbild zu nutzen.
  UrlMetadata? meta;
  // 1) Im Bild sichtbare URL → exakt wie ein eingegebener Link behandeln
  //    (YouTube-Thumbnail/Metadaten, AniList, GitHub, …).
  final url = result.url;
  if (url != null && url.startsWith('http')) {
    meta = await UrlMetadataService.fetch(url);
  }
  // 2) Sonst: Anime/Manga per erkanntem Titel auf AniList nachschlagen.
  final mt = result.mediaType;
  final recog = confirmed.title;
  if (meta == null &&
      recog != null &&
      recog.isNotEmpty &&
      (mt == 'anime' || mt == 'manga')) {
    meta = await UrlMetadataService.searchAniList(recog, kind: mt!);
  }

  return VisionOutcome(
    title: (confirmed.title?.isNotEmpty == true) ? confirmed.title : result.title,
    summary: result.summary,
    tags: result.tags,
    metadata: meta,
  );
}

class _Confirmed {
  final String? title;
  const _Confirmed(this.title);
}

Future<_Confirmed?> _confirmDialog(BuildContext context, VisionResult r) {
  final titleCtrl = TextEditingController(text: r.recognizedTitle ?? r.title ?? '');
  return showDialog<_Confirmed>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: MFColors.surface,
      title: const Text('Erkanntes Werk', style: TextStyle(color: MFColors.textPrimary, fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (r.mediaType != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Typ: ${r.mediaType}',
                style: const TextStyle(color: MFColors.textMuted, fontSize: 12)),
          ),
        TextField(
          controller: titleCtrl,
          style: const TextStyle(color: MFColors.textPrimary),
          decoration: const InputDecoration(labelText: 'Titel (korrigierbar)'),
        ),
        if (r.summary != null) ...[
          const SizedBox(height: 10),
          Text(r.summary!, style: const TextStyle(color: MFColors.textSecondary, fontSize: 12)),
        ],
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Verwerfen')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
          onPressed: () => Navigator.pop(ctx, _Confirmed(titleCtrl.text.trim())),
          child: const Text('Übernehmen'),
        ),
      ],
    ),
  );
}

Future<bool?> _confirm(BuildContext context, String msg) => showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.surface,
        content: Text(msg, style: const TextStyle(color: MFColors.textPrimary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );

void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }
}
