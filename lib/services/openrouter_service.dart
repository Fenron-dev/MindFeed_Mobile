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

  final String apiKey;
  final String model;
  final double temperature;
  final int maxTokens;

  const OpenRouterService({
    required this.apiKey,
    this.model = defaultModel,
    this.temperature = 0.3,
    this.maxTokens = 400,
  });

  /// Reichert einen Eintrag mit Tags, Titel und Zusammenfassung an.
  /// [extraContext] kann zusätzliche Metadaten enthalten (z.B. URL-Beschreibung, Genres).
  Future<AiEnrichment> enrichEntry(String body,
      {String? existingTitle, String? extraContext}) async {
    // Gesamtinhalt aus allen verfügbaren Quellen zusammensetzen
    final parts = <String>[];
    if (existingTitle?.isNotEmpty == true) parts.add('Titel: $existingTitle');
    if (body.trim().isNotEmpty) {
      parts.add(body.length > 1500 ? body.substring(0, 1500) : body);
    }
    if (extraContext?.trim().isNotEmpty == true) {
      final ctx = extraContext!.trim();
      parts.add(ctx.length > 500 ? ctx.substring(0, 500) : ctx);
    }

    if (parts.isEmpty) throw Exception('Kein Inhalt für KI-Anreicherung vorhanden');

    final content = parts.join('\n\n');

    final prompt = '''Du bist ein persönlicher Wissensassistent. Analysiere den folgenden Inhalt und antworte NUR mit einem JSON-Objekt (kein Markdown, kein Code-Block).

Inhalt:
$content

Antworte AUSSCHLIESSLICH mit diesem JSON-Format:
{
  "tags": ["tag1", "tag2", "tag3"],
  "title": "Kurzer aussagekräftiger Titel (max 60 Zeichen) oder null",
  "summary": "1-2 Satz Zusammenfassung",
  "lang": "de"
}

Wichtige Regeln:
- tags: 2-5 sinnvolle thematische Tags, lowercase, nur Buchstaben, Zahlen und Bindestriche
- tags NIEMALS: "leer", "fehler", "kein", "kein-inhalt", "keine-tags", "unknown", "n-a" o.ä.
- Falls wenig Inhalt: leite Tags aus Titel und Kontext ab
- title: null wenn Titel bereits gut ist, sonst verbesserten Titel
- lang: 2-Buchstaben ISO-Code der Hauptsprache''';

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
            (existingTitle == null || existingTitle.isEmpty))
        ? rawTitle
        : null;

    return AiEnrichment(
      tags: tags,
      title: title,
      summary: parsed['summary'] as String?,
      lang: parsed['lang'] as String?,
    );
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
