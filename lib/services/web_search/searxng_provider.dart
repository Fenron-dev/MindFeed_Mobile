import 'dart:convert';
import 'package:http/http.dart' as http;
import 'web_search_provider.dart';

/// Anbindung an eine selbst gehostete SearXNG-Instanz über deren JSON-API.
/// Voraussetzung: in der `settings.yml` der Instanz muss das JSON-Format
/// aktiviert sein:
///   search:
///     formats:
///       - html
///       - json
class SearxngProvider implements WebSearchProvider {
  /// Basis-URL der Instanz, z.B. `http://<host>:8080`.
  final String baseUrl;
  const SearxngProvider({required this.baseUrl});

  Uri _searchUri(String query, {String? language, String? categories}) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/search').replace(queryParameters: {
      'q': query,
      'format': 'json',
      if (language != null && language.isNotEmpty) 'language': language,
      if (categories != null && categories.isNotEmpty) 'categories': categories,
    });
  }

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    String language = 'de',
    int limit = 8,
  }) async {
    if (baseUrl.trim().isEmpty) {
      throw Exception('Keine SearXNG-URL konfiguriert');
    }
    final res = await http.get(
      _searchUri(query, language: language),
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
        .map((m) => WebSearchResult(
              title: (m['title'] as String?)?.trim() ?? '',
              url: (m['url'] as String?)?.trim() ?? '',
              content: (m['content'] as String?)?.trim() ?? '',
            ))
        .where((r) => r.url.isNotEmpty)
        .take(limit)
        .toList();
  }

  @override
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
}
