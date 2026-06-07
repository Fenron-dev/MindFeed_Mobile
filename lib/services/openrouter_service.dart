import 'dart:convert';
import 'package:http/http.dart' as http;

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

class OpenRouterService {
  static const _endpoint =
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

  /// Max. Zeichen des übertragenen Inhalts (Body). Bei größeren Modellen höher
  /// setzen für besseren Kontext. Der Zusatzkontext bekommt anteilig ein Drittel.
  final int maxInputChars;

  const OpenRouterService({
    required this.apiKey,
    this.model = defaultModel,
    this.temperature = 0.3,
    this.maxTokens = 400,
    this.maxInputChars = defaultMaxInputChars,
  });

  /// Reichert einen Eintrag mit Tags, Titel und Zusammenfassung an.
  /// [extraContext] kann zusätzliche Metadaten enthalten (z.B. URL-Beschreibung, Genres).
  Future<AiEnrichment> enrichEntry(String body,
      {String? existingTitle, String? extraContext}) async {
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

    final prompt = '''Du bist ein präziser Wissensassistent. Analysiere den INHALT unten und gib AUSSCHLIESSLICH ein JSON-Objekt zurück (kein Markdown, kein Code-Block, kein Text davor/danach).

INHALT:
$content

Erzeuge ein JSON-Objekt mit GENAU diesen Schlüsseln. Befülle jeden Wert mit deiner EIGENEN Analyse des INHALTS — gib NIEMALS die Feldbeschreibung oder einen Beispieltext wörtlich zurück:

- "title": Verbesserter, konkreter Titel des Themas/Tools/Projekts (max 70 Zeichen). null, wenn der vorhandene Titel bereits gut ist.
- "summary": 2-4 vollständige, eigene Sätze, die konkret beschreiben, worum es geht, was es kann/macht und für wen es nützlich ist. Bezieh dich auf konkrete Inhalte, keine Floskeln.
- "tags": 3-6 echte thematische Schlagwörter (Technologien, Konzepte, Domänen). Kleingeschrieben, nur Buchstaben/Zahlen/Bindestriche.
- "lang": ISO-639-1-Sprachcode des Hauptinhalts (z.B. "de", "en").

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
        .post(Uri.parse(_endpoint), headers: reqHeaders, body: reqBody)
        .timeout(const Duration(seconds: 30));

    // Bei Rate-Limit (429) einmal nach kurzer Pause wiederholen
    if (res.statusCode == 429) {
      await Future.delayed(const Duration(seconds: 6));
      res = await http
          .post(Uri.parse(_endpoint), headers: reqHeaders, body: reqBody)
          .timeout(const Duration(seconds: 30));
    }

    if (res.statusCode != 200) {
      String errMsg;
      if (res.statusCode == 429) {
        errMsg = 'Rate-Limit des Free-Modells erreicht. Warte kurz oder wähle ein anderes Modell in den Einstellungen.';
      } else if (res.statusCode == 404) {
        errMsg = 'Modell "$model" nicht gefunden. Bitte in den Einstellungen ein verfügbares Modell auswählen.';
      } else {
        try {
          final errJson = jsonDecode(res.body) as Map<String, dynamic>;
          errMsg = (errJson['error']?['message'] as String?) ??
              errJson['error']?.toString() ??
              res.body.substring(0, res.body.length.clamp(0, 200));
        } catch (_) {
          errMsg = res.body.substring(0, res.body.length.clamp(0, 200));
        }
      }
      throw Exception('OpenRouter ${res.statusCode}: $errMsg');
    }

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
      {String? existingTitle, String? sourceUrl}) async {
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

    final prompt =
        '''Du bist ein Notiz-Assistent für ein persönliches Wissenssystem. Aus dem INHALT (z.B. einem Video-Transkript, Artikel oder Doku) erstellst du eine strukturierte, sachliche Notiz in deutschem Markdown.

${metaLines.isEmpty ? '' : '$metaLines\n'}INHALT:
$body

SCHRITT 1 — TYP ERKENNEN. Bestimme genau einen Typ:
TUTORIAL (Anleitung/How-To/Erklärung), NEWS (News/Roundup/Liste), REVIEW (Test/Vergleich), INTERVIEW (Gespräch/Podcast), ENTERTAINMENT (Let's Play/Reaction), REZEPT (Koch-/Backvideo), oder GENERISCH (Artikel/Tool/sonstiges).

SCHRITT 2 — NOTIZ SCHREIBEN nach dem zum Typ passenden Gerüst (nur sinnvolle Abschnitte; leere weglassen). Allgemeine Regeln: sachlich und konkret zum INHALT, keine Emojis, keine Marketing-Sprache, keine Quellen-Hinweise wie [web:1]. Zitate nur 3-5 wirklich prägnante, als Blockquote mit Zeitstempel falls vorhanden. Verwende echte Markdown-Überschriften (##), Listen und Tabellen.

Beginne IMMER mit einer 2-4-Sätze-Zusammenfassung (ohne Überschrift), dann folgt das Gerüst:

TUTORIAL:
## Überblick
## Voraussetzungen
## Schritt-für-Schritt
## Wichtige Aussagen
## Hinweise & Risiken
## Weiterführende Ressourcen

NEWS:
## Überblick
## Themen & Neuigkeiten  (je Thema ### mit Zeitstempel + 3-6 Sätze)
## Fazit
## Weiterführende Ressourcen

REVIEW:
## Überblick
## Getestetes / Verglichenes
## Stärken
## Schwächen
## Fazit
## Alternativen

INTERVIEW:
## Überblick
## Personen
## Besprochene Themen  (je Thema ### + Zusammenfassung)
## Wichtige Aussagen
## Kernaussagen & Erkenntnisse

ENTERTAINMENT:
## Überblick
## Inhalt & Verlauf
## Besondere Momente
## Medieninfo

REZEPT:
## Überblick
## Rahmendaten  (Markdown-Tabelle: Portionen, Zubereitungszeit, Kochzeit, Schwierigkeitsgrad, Küche)
## Zutaten  (gruppiert, mit Mengen)
## Zubereitung  (nummerierte Schritte, Zeitstempel falls vorhanden)
## Tipps & Tricks
## Wichtige Aussagen
## Varianten & Alternativen

GENERISCH:
## Überblick
## Wichtigste Inhalte  (Stichpunkte)
## Details
## Weiterführende Ressourcen

Gib NUR die fertige Markdown-Notiz aus, ohne Vorrede, ohne Code-Fences.''';

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
        .post(Uri.parse(_endpoint), headers: reqHeaders, body: reqBody)
        .timeout(const Duration(seconds: 90));
    if (res.statusCode == 429) {
      await Future.delayed(const Duration(seconds: 6));
      res = await http
          .post(Uri.parse(_endpoint), headers: reqHeaders, body: reqBody)
          .timeout(const Duration(seconds: 90));
    }
    if (res.statusCode != 200) {
      throw Exception('OpenRouter ${res.statusCode}');
    }

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

    final prompt =
        '''Du erstellst eine sachliche, gut strukturierte deutsche Markdown-Notiz zu einem Link/Thema für ein persönliches Wissenssystem (Obsidian-kompatibel).

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
## Beschreibung
(10-30 Sätze: worum geht es, was kann/macht es, was hebt es hervor. Bei Medien: spoilerfreie Inhaltsangabe.)
## Systemvoraussetzungen   (nur bei Software, wenn sinnvoll)
## Installation             (nur bei Software, wenn sinnvoll)
## Mögliche Risiken         (nur wenn relevant)
## Mögliche Alternativen
(3-10 Alternativen als Markdown-Tabelle: Name als Link, kurze Beschreibung, ggf. Preis in Euro / Vor- & Nachteile.)
## Referenzen & weiterführende Informationen
(Nummerierte Liste: **Titel** in Fett, darunter kurze Beschreibung und Link.)
## Video & Audio            (passende YouTube-/Podcast-Treffer, falls vorhanden, max 10)
## FAQ                       (häufige Fragen, nummeriert: **Frage** + Antwort darunter)
## Begriffe                  (nur falls Fachbegriffe erklärt werden müssen)

Gib NUR die fertige Markdown-Notiz aus, ohne Vorrede, ohne Code-Fences.''';

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
        .post(Uri.parse(_endpoint), headers: reqHeaders, body: reqBody)
        .timeout(const Duration(seconds: 90));
    if (res.statusCode == 429) {
      await Future.delayed(const Duration(seconds: 6));
      res = await http
          .post(Uri.parse(_endpoint), headers: reqHeaders, body: reqBody)
          .timeout(const Duration(seconds: 90));
    }
    if (res.statusCode != 200) {
      throw Exception('OpenRouter ${res.statusCode}');
    }

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
          Uri.parse(_endpoint),
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

  /// Holt verfügbare Modelle von OpenRouter
  static Future<List<Map<String, dynamic>>> getModels(String apiKey) async {
    final res = await http
        .get(
          Uri.parse('https://openrouter.ai/api/v1/models'),
          headers: {'Authorization': 'Bearer $apiKey'},
        )
        .timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['data'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }
}
