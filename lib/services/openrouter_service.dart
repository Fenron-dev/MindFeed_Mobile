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
