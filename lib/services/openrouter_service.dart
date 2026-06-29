import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ai/structure_template.dart';

class AiEnrichment {
  final List<String> tags;
  final String? title;
  final String? summary;
  final String? lang;

  const AiEnrichment({
    required this.tags,
    this.title,
    this.summary,
    this.lang,
  });
}

/// Ergebnis der Bild-Analyse (#34).
class VisionResult {
  final String? title;
  final String? summary;
  final List<String> tags;
  final String? lang;
  final String? mediaType; // z.B. 'anime', 'movie', 'series', 'youtube', 'shop'
  final String? recognizedTitle; // erkannter Werk-/Seitentitel für die Suche
  final String? url; // im Bild sichtbare URL (z.B. Adressleiste), falls erkannt

  const VisionResult({
    this.title,
    this.summary,
    this.tags = const [],
    this.lang,
    this.mediaType,
    this.recognizedTitle,
    this.url,
  });
}

/// Signalisiert, dass das aktuelle Profil/Modell nicht verfügbar ist
/// (Rate-Limit/Guthaben/Modell weg/Server/Netz) → `AiService` wechselt auf das
/// nächste Kettenglied und legt das Profil ggf. in Cooldown.
class AiUnavailableException implements Exception {
  final int status; // HTTP-Status (0 = Netz/Timeout)
  final String message;
  final Duration? retryAfter; // aus Retry-After/Reset-Header, falls vorhanden
  const AiUnavailableException(this.status, this.message, {this.retryAfter});

  /// Quota-/Limit-Fehler, die einen Cooldown auslösen.
  bool get isLimit => status == 429 || status == 402;

  @override
  String toString() => 'AiUnavailable($status): $message';

  static bool isRetryableStatus(int s) =>
      s == 429 || s == 402 || s == 404 || s >= 500;

  /// Liest `Retry-After` (Sekunden) bzw. `x-ratelimit-reset` (Sekunden/Epoch-ms).
  static Duration? retryAfterFrom(Map<String, String> headers) {
    final ra = headers['retry-after'];
    if (ra != null) {
      final secs = int.tryParse(ra.trim());
      if (secs != null && secs > 0) return Duration(seconds: secs);
    }
    final reset = headers['x-ratelimit-reset'];
    if (reset != null) {
      final n = int.tryParse(reset.trim());
      if (n != null) {
        // > 10^12 ⇒ Epoch-Millis, sonst Sekunden bis Reset.
        if (n > 1000000000000) {
          final d = DateTime.fromMillisecondsSinceEpoch(n)
              .difference(DateTime.now());
          if (d > Duration.zero) return d;
        } else if (n > 0 && n < 86400) {
          return Duration(seconds: n);
        }
      }
    }
    return null;
  }
}

class OpenRouterService {
  static const _defaultEndpoint =
      'https://openrouter.ai/api/v1/chat/completions';

  // Standard Free-Tier Modell
  static const defaultModel =
      'meta-llama/llama-3.2-3b-instruct:free';

  /// Standard-Zeichenlimit für den an das Modell übertragenen Inhalt.
  static const defaultMaxInputChars = 1500;

  final String apiKey;
  final String model;
  final double temperature;
  final int maxTokens;

  /// OpenAI-kompatibler `/chat/completions`-Endpoint. Default = OpenRouter;
  /// für andere Profile (Groq, lokal …) wird die Profil-`chatUrl` übergeben.
  final String chatUrl;

  /// Max. Zeichen des übertragenen Inhalts (Body). Bei größeren Modellen höher
  /// setzen für besseren Kontext. Der Zusatzkontext bekommt anteilig ein Drittel.
  final int maxInputChars;

  const OpenRouterService({
    required this.apiKey,
    this.model = defaultModel,
    this.temperature = 0.3,
    this.maxTokens = 400,
    this.maxInputChars = defaultMaxInputChars,
    this.chatUrl = _defaultEndpoint,
  });

  /// Wirft bei verfügbarkeitsbedingten HTTP-Fehlern eine [AiUnavailableException]
  /// (für den Fallback), sonst eine normale Exception.
  static void _checkStatus(http.Response res) {
    if (res.statusCode == 200) return;
    String errMsg;
    if (res.statusCode == 429) {
      errMsg = 'Rate-Limit erreicht.';
    } else if (res.statusCode == 402) {
      errMsg = 'Kein Guthaben / Limit erreicht.';
    } else if (res.statusCode == 404) {
      errMsg = 'Modell nicht gefunden.';
    } else {
      try {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        errMsg = (j['error']?['message'] as String?) ??
            res.body.substring(0, res.body.length.clamp(0, 200));
      } catch (_) {
        errMsg = res.body.substring(0, res.body.length.clamp(0, 200));
      }
    }
    if (AiUnavailableException.isRetryableStatus(res.statusCode)) {
      throw AiUnavailableException(res.statusCode, errMsg,
          retryAfter: AiUnavailableException.retryAfterFrom(res.headers));
    }
    throw Exception('AI ${res.statusCode}: $errMsg');
  }

  /// Analysiert ein Bild (multimodal) und erzeugt daraus eine Notiz-Vorlage:
  /// erkennt Quelle/Medium + Titel + Inhalt. [imageDataUrl] ist eine
  /// `data:image/...;base64,…`-URL (via ImageVision.toDataUrl). Braucht ein
  /// vision-fähiges Modell.
  Future<VisionResult> analyzeImage(String imageDataUrl,
      {String? userHint, List<String> existingTags = const []}) async {
    final tagPool =
        existingTags.where((t) => t.trim().isNotEmpty).take(200).toList();
    final tagHint = tagPool.isEmpty
        ? ''
        : '\nBevorzuge passende Tags aus: ${tagPool.join(', ')}';
    final prompt =
        '''Analysiere das Bild (oft ein Screenshot). Erkenne, um welche Quelle/Plattform und welches Werk es geht (z.B. YouTube-Video, Crunchyroll/Anime, Film, Serie, Buch, Shop-Produkt) und worum es inhaltlich geht.${userHint != null && userHint.isNotEmpty ? '\nHinweis des Nutzers: $userHint' : ''}

Gib AUSSCHLIESSLICH ein JSON-Objekt zurück mit diesen Schlüsseln:
- "title": prägnanter Titel für die Notiz (max 70 Zeichen)
- "summary": 2-3 Sätze NUR auf Basis dessen, was im Bild sichtbar ist (Titel, Beschreibung, Thumbnail). Erfinde KEINEN Inhalt, den du nicht siehst
- "tags": 3-6 kleingeschriebene Schlagwörter
- "lang": ISO-639-1 Sprachcode
- "media_type": eines von "anime","manga","movie","series","youtube","book","game","shop","web","other"
- "recognized_title": der konkrete Werk-/Seitentitel zur Nachschlage-Suche (oder null)
- "url": die im Bild sichtbare URL (z.B. Browser-Adressleiste, YouTube-Link) exakt abgetippt, sonst null
- Tags klein, einzelne Wörter mit Bindestrich verbinden (z.B. "slice-of-life")$tagHint''';

    final reqBody = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {'url': imageDataUrl},
            },
          ],
        },
      ],
      'max_tokens': maxTokens < 800 ? 800 : maxTokens,
      'temperature': temperature,
    });
    final reqHeaders = {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://mindfeed.app',
      'X-Title': 'MindFeed Mobile',
    };

    final res = await http
        .post(Uri.parse(chatUrl), headers: reqHeaders, body: reqBody)
        .timeout(const Duration(seconds: 45));
    _checkStatus(res);

    final data = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true))
        as Map<String, dynamic>;
    final msg = data['choices']?[0]?['message'] as Map<String, dynamic>?;
    final responseText = (msg?['content'] as String?) ?? '';
    final jsonStr = _extractJson(responseText);
    if (jsonStr == null) {
      throw Exception('Bild-Analyse: keine verwertbare Antwort.');
    }
    final p = jsonDecode(jsonStr) as Map<String, dynamic>;
    final tags = (p['tags'] as List?)
            ?.map((t) => '$t'
                .trim()
                .toLowerCase()
                .replaceAll(RegExp(r'\s+'), '-')
                .replaceAll(RegExp(r'[^a-z0-9\-äöüß]'), '')
                .replaceAll(RegExp(r'-+'), '-')
                .replaceAll(RegExp(r'^-|-$'), ''))
            .where((t) => t.length > 1)
            .toList() ??
        [];
    String? str(dynamic v) =>
        (v is String && v.trim().isNotEmpty && v != 'null') ? v.trim() : null;
    return VisionResult(
      title: str(p['title']),
      summary: str(p['summary']),
      tags: tags,
      lang: str(p['lang']),
      mediaType: str(p['media_type'])?.toLowerCase(),
      recognizedTitle: str(p['recognized_title']),
      url: str(p['url']),
    );
  }

  /// Reichert einen Eintrag mit Tags, Titel und Zusammenfassung an.
  /// [extraContext] kann zusätzliche Metadaten enthalten (z.B. URL-Beschreibung, Genres).
  Future<AiEnrichment> enrichEntry(String body,
      {String? existingTitle,
      String? extraContext,
      List<String> existingTags = const []}) async {
    // Gesamtinhalt aus allen verfügbaren Quellen zusammensetzen
    final bodyLimit = maxInputChars < 200 ? 200 : maxInputChars;
    final ctxLimit = (bodyLimit ~/ 3).clamp(200, 4000);
    final parts = <String>[];
    if (existingTitle?.isNotEmpty == true) parts.add('Titel: $existingTitle');
    if (body.trim().isNotEmpty) {
      parts.add(body.length > bodyLimit ? body.substring(0, bodyLimit) : body);
    }
    if (extraContext?.trim().isNotEmpty == true) {
      final ctx = extraContext!.trim();
      parts.add(ctx.length > ctxLimit ? ctx.substring(0, ctxLimit) : ctx);
    }

    if (parts.isEmpty) throw Exception('Kein Inhalt für KI-Anreicherung vorhanden');

    final content = parts.join('\n\n');

    // Vorhandene Tags (gekappt) der KI mitgeben, damit sie passende
    // wiederverwendet statt Quasi-Duplikate zu erzeugen. Tag-Namen sind kurz →
    // moderater Token-Aufschlag.
    final tagPool =
        existingTags.where((t) => t.trim().isNotEmpty).take(200).toList();
    final tagHint = tagPool.isEmpty
        ? ''
        : '\n\nVORHANDENE TAGS — bevorzuge inhaltlich passende daraus (exakte '
            'Schreibweise übernehmen) und erstelle nur dann einen neuen Tag, '
            'wenn wirklich keiner passt:\n${tagPool.join(', ')}';

    final prompt = '''Du bist ein präziser Wissensassistent. Analysiere den INHALT unten und gib AUSSCHLIESSLICH ein JSON-Objekt zurück (kein Markdown, kein Code-Block, kein Text davor/danach).

INHALT:
$content

Erzeuge ein JSON-Objekt mit GENAU diesen Schlüsseln. Befülle jeden Wert mit deiner EIGENEN Analyse des INHALTS — gib NIEMALS die Feldbeschreibung oder einen Beispieltext wörtlich zurück:

- "title": Verbesserter, konkreter Titel des Themas/Tools/Projekts (max 70 Zeichen). null, wenn der vorhandene Titel bereits gut ist.
- "summary": 2-4 vollständige, eigene Sätze, die konkret beschreiben, worum es geht, was es kann/macht und für wen es nützlich ist. Bezieh dich auf konkrete Inhalte, keine Floskeln.
- "tags": IMMER 3-6 echte thematische Schlagwörter (Technologien, Konzepte, Domänen), niemals leer — notfalls aus Titel/Kontext ableiten. Kleingeschrieben, Wörter mit Bindestrich verbinden (z.B. "open-source"), nur Buchstaben/Zahlen/Bindestriche.
- "lang": ISO-639-1-Sprachcode des Hauptinhalts (z.B. "de", "en").$tagHint

Beispiel für das FORMAT (Inhalt ignorieren, nur Struktur):
{"title": null, "summary": "…", "tags": ["…","…"], "lang": "de"}

Regeln:
- summary niemals leer und niemals dieser Beschreibungstext; bei dünnem INHALT aus Titel/Kontext ableiten.
- tags niemals Platzhalter wie "tag1", "leer", "kein", "unknown", "n-a".''';

    final prompt_tokens = prompt.length ~/ 3; // Grobe Schätzung
    // Reasoning-Modelle verbrauchen viele Tokens fürs "Denken", bevor das JSON
    // kommt → großzügiger Boden, sonst wird die Antwort abgeschnitten.
    final needed_tokens = (maxTokens < 800) ? 800 : maxTokens;

    final reqBody = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'max_tokens': needed_tokens,
      'temperature': temperature,
    });
    final reqHeaders = {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://mindfeed.app',
      'X-Title': 'MindFeed Mobile',
    };

    var res = await http
        .post(Uri.parse(chatUrl), headers: reqHeaders, body: reqBody)
        .timeout(const Duration(seconds: 30));

    // Bei Rate-Limit (429) einmal nach kurzer Pause wiederholen
    if (res.statusCode == 429) {
      await Future.delayed(const Duration(seconds: 6));
      res = await http
          .post(Uri.parse(chatUrl), headers: reqHeaders, body: reqBody)
          .timeout(const Duration(seconds: 30));
    }

    _checkStatus(res);

    final data = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true))
        as Map<String, dynamic>;
    final msg = data['choices']?[0]?['message'] as Map<String, dynamic>?;
    // Manche (Reasoning-)Modelle liefern leeren content und schreiben in
    // 'reasoning'; dann dort nach dem JSON suchen.
    var responseText = (msg?['content'] as String?) ?? '';
    if (_extractJson(responseText) == null) {
      final reasoning = (msg?['reasoning'] as String?) ?? '';
      if (reasoning.isNotEmpty) responseText = '$responseText\n$reasoning';
    }

    final jsonStr = _extractJson(responseText);
    if (jsonStr == null) {
      final snippet = responseText.trim().isEmpty
          ? '(leere Antwort – evtl. max_tokens zu niedrig oder Modell ungeeignet)'
          : responseText.trim().substring(
              0, responseText.trim().length.clamp(0, 200));
      throw Exception('Ungültige KI-Antwort: kein JSON gefunden. $snippet');
    }

    final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;

    const _blockedTags = {
      'leer', 'fehler', 'kein', 'keine', 'kein-inhalt', 'keine-tags',
      'unknown', 'n-a', 'na', 'null', 'undefined', 'error', 'empty',
      'no-content', 'no-tags', 'tag1', 'tag2', 'tag3',
    };
    final tags = (parsed['tags'] as List<dynamic>?)
            ?.map((t) => t.toString()
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9\-äöüß]'), ''))
            .where((t) => t.length > 1 && !_blockedTags.contains(t))
            .toList() ??
        [];

    final rawTitle = parsed['title'] as String?;
    final title = (rawTitle?.isNotEmpty == true &&
            rawTitle != 'null' &&
            !_looksLikePlaceholder(rawTitle!) &&
            (existingTitle == null || existingTitle.isEmpty))
        ? rawTitle
        : null;

    final rawSummary = parsed['summary'] as String?;
    final summary = (rawSummary != null && !_looksLikePlaceholder(rawSummary))
        ? rawSummary
        : null;

    return AiEnrichment(
      tags: tags,
      title: title,
      summary: summary,
      lang: parsed['lang'] as String?,
    );
  }

  /// Erkennt, ob das Modell statt echtem Inhalt den Platzhalter-/Beschreibungs-
  /// text aus dem Prompt zurückgegeben hat (typisch für schwache Modelle).
  static bool _looksLikePlaceholder(String s) {
    final t = s.trim().toLowerCase();
    if (t.isEmpty) return true;
    const markers = [
      'satz zusammenfassung', '1-2 satz', '2-4 vollständige',
      'aussagekräftiger titel', 'max 60 zeichen', 'max 70 zeichen',
      'iso-639', 'feldbeschreibung', 'beispieltext', 'worum es geht',
    ];
    return markers.any(t.contains);
  }

  /// Baut den Prompt der „strukturierten Notiz" aus editierbaren [templates]
  /// (#38). Feste Präambel/Regeln/Schluss bleiben hier; nur SCHRITT 1
  /// (Typliste) und SCHRITT 2 (Gerüste) kommen aus den Vorlagen.
  ///
  /// Ist [forcedType] gesetzt und passt zu einer Vorlage, wird die
  /// Typ-Erkennung übersprungen und direkt deren Gerüst erzwungen.
  /// Statisch + ohne Netzwerk → unit-testbar.
  static String buildStructuredNotePrompt({
    required String body,
    required String metaLines,
    required List<StructureTemplate> templates,
    String? forcedType,
  }) {
    const intro =
        'Du bist ein Notiz-Assistent für ein persönliches Wissenssystem. Aus dem INHALT (z.B. einem Video-Transkript, Artikel oder Doku) erstellst du eine strukturierte, sachliche Notiz in deutschem Markdown.';
    const rules =
        'Allgemeine Regeln: sachlich und konkret zum INHALT, keine Emojis, keine Marketing-Sprache, keine Quellen-Hinweise wie [web:1]. Zitate nur 3-5 wirklich prägnante, als Blockquote mit Zeitstempel falls vorhanden. Verwende echte Markdown-Überschriften (##), Listen und Tabellen.';
    const summaryLine =
        'Beginne IMMER mit einer 2-4-Sätze-Zusammenfassung (ohne Überschrift), dann folgt das Gerüst:';
    const closing =
        'Gib NUR die fertige Markdown-Notiz aus, ohne Vorrede, ohne Code-Fences.';

    final header = '$intro\n\n'
        '${metaLines.isEmpty ? '' : '$metaLines\n'}INHALT:\n$body';

    final forced = StructureTemplate.byName(templates, forcedType);

    final String middle;
    if (forced != null) {
      middle = 'Strukturiere den INHALT als Typ ${forced.name} (nur sinnvolle '
          'Abschnitte; leere weglassen). $rules\n\n'
          '$summaryLine\n\n'
          '${forced.name}:\n${forced.skeleton.trim()}';
    } else {
      middle = 'SCHRITT 1 — TYP ERKENNEN. Bestimme genau einen Typ:\n'
          '${StructureTemplate.typeListLine(templates)}.\n\n'
          'SCHRITT 2 — NOTIZ SCHREIBEN nach dem zum Typ passenden Gerüst (nur '
          'sinnvolle Abschnitte; leere weglassen). $rules\n\n'
          '$summaryLine\n\n'
          '${StructureTemplate.skeletonBlock(templates)}';
    }

    return '$header\n\n$middle\n\n$closing';
  }

  /// Baut den Prompt der „recherchierten Notiz" mit editierbarer
  /// [structure]-Sektion (#38). Regeln/Meta/Recherche-Scaffold bleiben fest.
  static String buildResearchedNotePrompt({
    required String meta,
    required String research,
    required String structure,
  }) {
    return '''Du erstellst eine sachliche, gut strukturierte deutsche Markdown-Notiz zu einem Link/Thema für ein persönliches Wissenssystem (Obsidian-kompatibel).

$meta

WEB-RECHERCHE (nummerierte Treffer — NUR diese und allgemein bekannten Kontext als Quelle verwenden; keine URLs erfinden):
${research.isEmpty ? '(keine Recherche-Treffer verfügbar)' : research}

REGELN:
- Sachlich, neutral, präzise. Keine Marketing-Sprache, keine Emojis.
- Keine Referenz-Hinweise wie [web:1] o.ä.
- Echte Markdown-Überschriften (##), Listen und Tabellen.
- Optionale Abschnitte nur, wenn inhaltlich sinnvoll; sonst weglassen.
- Links als Markdown: [Name](https://…). Nur URLs aus der Recherche oder der Quelle verwenden.
- KEIN YAML-Frontmatter ausgeben (Metadaten verwaltet das System separat).

STRUKTUR (passende Abschnitte wählen):
Beginne mit 2-4 Sätzen Zusammenfassung (ohne Überschrift), dann:
$structure

Gib NUR die fertige Markdown-Notiz aus, ohne Vorrede, ohne Code-Fences.''';
  }

  /// Erstellt aus dem (vollständigen) INHALT eine strukturierte Markdown-Notiz.
  /// Das Modell erkennt selbst den Typ (Tutorial/News/Review/Interview/
  /// Entertainment/Rezept bzw. generisch für Artikel/Tool) und nutzt das
  /// passende Gerüst. Bewusst KEIN JSON — robuster für lange, mehrzeilige
  /// Markdown-Ausgaben.
  ///
  /// Wichtig: Hier wird NICHT auf das kleine `maxInputChars` (für Tags/Kurz-
  /// Summary gedacht) gekürzt, sondern ein großzügiges Limit genutzt, damit
  /// das komplette Transkript ausgewertet wird.
  Future<String?> generateStructuredNote(String content,
      {String? existingTitle,
      String? sourceUrl,
      List<StructureTemplate>? templates,
      String? forcedType}) async {
    // Großzügiges Eingabelimit: mindestens 16k, höchstens 48k Zeichen.
    final cap = maxInputChars > 16000
        ? (maxInputChars > 48000 ? 48000 : maxInputChars)
        : 16000;
    final body = content.trim().length > cap
        ? content.trim().substring(0, cap)
        : content.trim();
    if (body.isEmpty) return null;

    final metaLines = [
      if (existingTitle?.isNotEmpty == true) 'Bekannter Titel: $existingTitle',
      if (sourceUrl?.isNotEmpty == true) 'Quelle: $sourceUrl',
    ].join('\n');

    final prompt = buildStructuredNotePrompt(
      body: body,
      metaLines: metaLines,
      templates: templates ?? StructureTemplate.defaults,
      forcedType: forcedType,
    );

    final needed = maxTokens < 2500 ? 2500 : maxTokens;
    final reqHeaders = {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://mindfeed.app',
      'X-Title': 'MindFeed Mobile',
    };
    final reqBody = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'max_tokens': needed,
      'temperature': temperature,
    });

    var res = await http
        .post(Uri.parse(chatUrl), headers: reqHeaders, body: reqBody)
        .timeout(const Duration(seconds: 90));
    if (res.statusCode == 429) {
      await Future.delayed(const Duration(seconds: 6));
      res = await http
          .post(Uri.parse(chatUrl), headers: reqHeaders, body: reqBody)
          .timeout(const Duration(seconds: 90));
    }
    _checkStatus(res);

    final data = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true))
        as Map<String, dynamic>;
    final msg = data['choices']?[0]?['message'] as Map<String, dynamic>?;
    var text = (msg?['content'] as String?) ?? '';
    if (text.trim().isEmpty) text = (msg?['reasoning'] as String?) ?? '';
    // <think>-Blöcke und umschließende Code-Fences entfernen
    text = text
        .replaceAll(
            RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
        .replaceAll(RegExp(r'^\s*```(?:markdown|md)?\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*```\s*$'), '')
        .trim();
    return text.isEmpty ? null : text;
  }

  /// Erzeugt eine recherchierte, strukturierte Markdown-Notiz zu einem Link.
  ///
  /// [searchContext] sind verdichtete Web-Treffer (z.B. aus SearXNG) und
  /// dienen als faktische Basis für Alternativen, Referenzen, Videos und FAQ
  /// — so halluziniert das Modell keine URLs. Liefert portables Markdown
  /// (OHNE YAML-Frontmatter, da MindFeed Metadaten als Properties verwaltet).
  Future<String?> generateResearchedNote({
    required String title,
    String? sourceUrl,
    String? knownDescription,
    String searchContext = '',
    String? structure,
  }) async {
    final research = searchContext.trim().length > 9000
        ? searchContext.trim().substring(0, 9000)
        : searchContext.trim();
    final desc = (knownDescription ?? '').trim();

    final meta = [
      'Titel: $title',
      if (sourceUrl?.isNotEmpty == true) 'Quelle: $sourceUrl',
      if (desc.isNotEmpty) 'Bekannte Beschreibung: ${desc.length > 1200 ? desc.substring(0, 1200) : desc}',
    ].join('\n');

    final prompt = buildResearchedNotePrompt(
      meta: meta,
      research: research,
      structure: (structure == null || structure.trim().isEmpty)
          ? StructureTemplate.defaultResearchStructure
          : structure,
    );

    final needed = maxTokens < 2500 ? 2500 : maxTokens;
    final reqHeaders = {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://mindfeed.app',
      'X-Title': 'MindFeed Mobile',
    };
    final reqBody = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'max_tokens': needed,
      'temperature': temperature,
    });

    var res = await http
        .post(Uri.parse(chatUrl), headers: reqHeaders, body: reqBody)
        .timeout(const Duration(seconds: 90));
    if (res.statusCode == 429) {
      await Future.delayed(const Duration(seconds: 6));
      res = await http
          .post(Uri.parse(chatUrl), headers: reqHeaders, body: reqBody)
          .timeout(const Duration(seconds: 90));
    }
    _checkStatus(res);

    final data = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true))
        as Map<String, dynamic>;
    final msg = data['choices']?[0]?['message'] as Map<String, dynamic>?;
    var text = (msg?['content'] as String?) ?? '';
    if (text.trim().isEmpty) text = (msg?['reasoning'] as String?) ?? '';
    text = text
        .replaceAll(
            RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
        .replaceAll(RegExp(r'^\s*```(?:markdown|md)?\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*```\s*$'), '')
        .trim();
    return text.isEmpty ? null : text;
  }

  /// Extrahiert ein JSON-Objekt aus der Modell-Antwort. Entfernt
  /// `<think>`-Blöcke und ```-Fences, findet das erste balancierte `{…}` und
  /// repariert ein durch max_tokens abgeschnittenes Objekt (fehlende `}`).
  static String? _extractJson(String text) {
    if (text.trim().isEmpty) return null;
    var t = text
        .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
        .replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), '');

    final start = t.indexOf('{');
    if (start == -1) return null;

    int depth = 0;
    bool inStr = false, esc = false;
    int end = -1;
    for (int i = start; i < t.length; i++) {
      final c = t[i];
      if (inStr) {
        if (esc) { esc = false; }
        else if (c == '\\') { esc = true; }
        else if (c == '"') { inStr = false; }
        continue;
      }
      if (c == '"') { inStr = true; }
      else if (c == '{') { depth++; }
      else if (c == '}') { depth--; if (depth == 0) { end = i; break; } }
    }

    if (end != -1) {
      final candidate = t.substring(start, end + 1);
      try { jsonDecode(candidate); return candidate; } catch (_) {}
    }

    // Abgeschnitten: fehlende schließende Klammern ergänzen und versuchen
    var partial = t.substring(start).trimRight();
    if (inStr) partial += '"';
    // dangling Komma/Doppelpunkt entfernen
    partial = partial.replaceFirst(RegExp(r'[,:]\s*$'), '');
    for (int i = 0; i < depth + 1 && i < 5; i++) {
      try { jsonDecode(partial); return partial; } catch (_) {}
      partial += '}';
    }
    return null;
  }

  /// Testet die Verbindung mit einem einfachen Ping (kein JSON-Parsing).
  /// Wirft eine Exception mit lesbarer Fehlermeldung wenn es nicht klappt.
  Future<void> testConnection() async {
    final res = await http
        .post(
          Uri.parse(chatUrl),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'HTTP-Referer': 'https://mindfeed.app',
            'X-Title': 'MindFeed Mobile',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': 'Antworte nur mit: OK'},
            ],
            'max_tokens': 10,
            'temperature': 0.0,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      String errMsg;
      try {
        final errJson = jsonDecode(res.body) as Map<String, dynamic>;
        errMsg = (errJson['error']?['message'] as String?) ??
            res.body.substring(0, res.body.length.clamp(0, 200));
      } catch (_) {
        errMsg = res.body.substring(0, res.body.length.clamp(0, 200));
      }
      throw Exception('OpenRouter ${res.statusCode}: $errMsg');
    }
    // Nur prüfen ob choices vorhanden — kein JSON-Parsing der Antwort nötig
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if ((data['choices'] as List?)?.isEmpty != false) {
      throw Exception('Keine Antwort vom Modell erhalten');
    }
  }

  /// Holt verfügbare Modelle vom (OpenAI-kompatiblen) Endpoint.
  static Future<List<Map<String, dynamic>>> getModels(String apiKey,
      {String modelsUrl = 'https://openrouter.ai/api/v1/models'}) async {
    final res = await http
        .get(
          Uri.parse(modelsUrl),
          headers: {
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
        )
        .timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['data'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }
}
