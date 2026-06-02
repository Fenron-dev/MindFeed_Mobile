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

  // Standard Free-Tier Modell (kein API-Key nötig für Rate-Limited Free)
  static const defaultModel =
      'meta-llama/llama-3.1-8b-instruct:free';

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
    final needed_tokens = (maxTokens < 200) ? 200 : maxTokens;

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
              {'role': 'user', 'content': prompt},
            ],
            'max_tokens': needed_tokens,
            'temperature': temperature,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode != 200) {
      // Kurze, lesbare Fehlermeldung aus dem OpenRouter-JSON extrahieren
      String errMsg;
      try {
        final errJson = jsonDecode(res.body) as Map<String, dynamic>;
        errMsg = (errJson['error']?['message'] as String?) ??
            errJson['error']?.toString() ??
            res.body.substring(0, res.body.length.clamp(0, 200));
      } catch (_) {
        errMsg = res.body.substring(0, res.body.length.clamp(0, 200));
      }
      throw Exception('OpenRouter ${res.statusCode}: $errMsg');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final responseText =
        data['choices']?[0]?['message']?['content'] as String? ?? '';

    // JSON aus der Antwort extrahieren (auch wenn Modell trotzdem Markdown schreibt)
    final jsonMatch =
        RegExp(r'\{[\s\S]*\}', multiLine: true).firstMatch(responseText);
    if (jsonMatch == null) {
      throw Exception('Ungültige KI-Antwort: kein JSON gefunden');
    }

    final parsed = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;

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
