import 'dart:convert';
import 'package:http/http.dart' as http;

/// Ein einzelner SearXNG-Suchtreffer.
class SearxResult {
  final String title;
  final String url;
  final String content; // Snippet/Beschreibung
  const SearxResult({
    required this.title,
    required this.url,
    required this.content,
  });
}

/// Anbindung an eine selbst gehostete SearXNG-Instanz über deren JSON-API.
/// Voraussetzung: in der `settings.yml` der Instanz muss das JSON-Format
/// aktiviert sein:
///   search:
///     formats:
///       - html
///       - json
///
/// Dient als (kostenlose, eigene) Recherche-Schicht für die KI-Anreicherung:
/// Treffer-Snippets werden als Kontext ins LLM gegeben, damit es nicht
/// halluziniert.
class SearxngService {
  /// Basis-URL der Instanz, z.B. `http://<host>:8080`.
  final String baseUrl;
  const SearxngService({required this.baseUrl});

  Uri _searchUri(String query, {String? language, String? categories}) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/search').replace(queryParameters: {
      'q': query,
      'format': 'json',
      if (language != null && language.isNotEmpty) 'language': language,
      if (categories != null && categories.isNotEmpty) 'categories': categories,
    });
  }

  /// Führt eine Suche aus und liefert bis zu [limit] Treffer.
  Future<List<SearxResult>> search(
    String query, {
    String language = 'de',
    String? categories,
    int limit = 8,
  }) async {
    if (baseUrl.trim().isEmpty) {
      throw Exception('Keine SearXNG-URL konfiguriert');
    }
    final res = await http.get(
      _searchUri(query, language: language, categories: categories),
      headers: {'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('SearXNG HTTP ${res.statusCode}');
    }
    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    final dynamic data;
    try {
      data = jsonDecode(body);
    } catch (_) {
      throw Exception(
          'Keine JSON-Antwort – in settings.yml "search.formats: [html, json]" aktivieren');
    }
    final results = (data is Map ? data['results'] : null) as List? ?? [];
    return results
        .whereType<Map<String, dynamic>>()
        .map((m) => SearxResult(
              title: (m['title'] as String?)?.trim() ?? '',
              url: (m['url'] as String?)?.trim() ?? '',
              content: (m['content'] as String?)?.trim() ?? '',
            ))
        .where((r) => r.url.isNotEmpty)
        .take(limit)
        .toList();
  }

  /// Prüft die Verbindung. Liefert `null` bei Erfolg, sonst eine
  /// menschenlesbare Fehlermeldung.
  Future<String?> testConnection() async {
    if (baseUrl.trim().isEmpty) return 'Keine URL eingegeben';
    try {
      final res = await http.get(
        _searchUri('mindfeed test', language: 'de'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 'HTTP ${res.statusCode}';
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      try {
        final data = jsonDecode(body);
        if (data is Map && data.containsKey('results')) return null;
        return 'Antwort ohne "results" – JSON-Format aktiviert?';
      } catch (_) {
        return 'Keine JSON-Antwort – in settings.yml "search.formats: [html, json]" aktivieren';
      }
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  /// Verdichtet Treffer zu einem nummerierten Kontextblock fürs LLM.
  static String resultsToContext(List<SearxResult> results) {
    final sb = StringBuffer();
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      sb.writeln('[${i + 1}] ${r.title}');
      if (r.content.isNotEmpty) sb.writeln(r.content);
      sb.writeln(r.url);
      sb.writeln();
    }
    return sb.toString().trim();
  }
}
