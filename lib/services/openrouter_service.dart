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
  Future<AiEnrichment> enrichEntry(String body, {String? existingTitle}) async {
    final prompt = '''Analysiere diesen Text und antworte NUR mit einem JSON-Objekt (kein Markdown, kein Code-Block):

Text:
${body.length > 2000 ? body.substring(0, 2000) : body}

JSON-Format:
{
  "tags": ["tag1", "tag2", "tag3"],
  "title": "Kurzer aussagekräftiger Titel (max 60 Zeichen)",
  "summary": "1-2 Satz Zusammenfassung",
  "lang": "de"
}

Regeln:
- tags: 2-5 Tags, lowercase, keine Sonderzeichen außer Bindestrich
- title: nur wenn kein Titel vorgegeben oder Titel verbessert werden kann, sonst null
- lang: 2-Buchstaben-Sprachcode (de, en, ja, etc.)''';

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
            'max_tokens': maxTokens,
            'temperature': temperature,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode != 200) {
      throw Exception(
          'OpenRouter-Fehler ${res.statusCode}: ${res.body}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final content =
        data['choices']?[0]?['message']?['content'] as String? ?? '';

    // JSON aus der Antwort extrahieren (auch wenn Modell trotzdem Markdown schreibt)
    final jsonMatch =
        RegExp(r'\{[\s\S]*\}', multiLine: true).firstMatch(content);
    if (jsonMatch == null) {
      throw Exception('Ungültige KI-Antwort: kein JSON gefunden');
    }

    final parsed = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;

    final tags = (parsed['tags'] as List<dynamic>?)
            ?.map((t) => t.toString()
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9\-]'), ''))
            .where((t) => t.isNotEmpty)
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
