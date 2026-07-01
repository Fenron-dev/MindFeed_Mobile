import 'dart:convert';
import 'package:http/http.dart' as http;
import 'web_search_provider.dart';

/// Anbindung an die [Brave Search API](https://api.search.brave.com).
/// Cloud-Web-Suche ohne Self-Hosting, authentifiziert per API-Key
/// (Header `X-Subscription-Token`). Alternative zu SearXNG (#32).
class BraveProvider implements WebSearchProvider {
  final String apiKey;
  const BraveProvider({required this.apiKey});

  static const _endpoint = 'https://api.search.brave.com/res/v1/web/search';

  Uri _searchUri(String query, {String? language, int count = 8}) {
    return Uri.parse(_endpoint).replace(queryParameters: {
      'q': query,
      // Brave erlaubt max. 20 Treffer pro Anfrage.
      'count': count.clamp(1, 20).toString(),
      'result_filter': 'web',
      if (language != null && language.isNotEmpty) ...{
        'search_lang': language,
        'country': language,
      },
    });
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'X-Subscription-Token': apiKey.trim(),
      };

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    String language = 'de',
    int limit = 8,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('Kein Brave-API-Key konfiguriert');
    }
    final res = await http
        .get(_searchUri(query, language: language, count: limit),
            headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception(_httpError(res.statusCode));
    }
    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    final dynamic data;
    try {
      data = jsonDecode(body);
    } catch (_) {
      throw Exception('Brave: ungültige JSON-Antwort');
    }
    return parseResults(data, limit: limit);
  }

  /// Extrahiert die Web-Treffer aus einer Brave-API-Antwort. Ausgelagert für
  /// die Testbarkeit (keine HTTP-Abhängigkeit).
  static List<WebSearchResult> parseResults(dynamic data, {int limit = 8}) {
    final web = (data is Map ? data['web'] : null);
    final results = (web is Map ? web['results'] : null) as List? ?? [];
    return results
        .whereType<Map<String, dynamic>>()
        .map((m) => WebSearchResult(
              title: (m['title'] as String?)?.trim() ?? '',
              url: (m['url'] as String?)?.trim() ?? '',
              // Brave nennt das Snippet "description".
              content: (m['description'] as String?)?.trim() ?? '',
            ))
        .where((r) => r.url.isNotEmpty)
        .take(limit)
        .toList();
  }

  @override
  Future<String?> testConnection() async {
    if (apiKey.trim().isEmpty) return 'Kein API-Key eingegeben';
    try {
      final res = await http
          .get(_searchUri('mindfeed test', language: 'de', count: 1),
              headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return _httpError(res.statusCode);
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      try {
        final data = jsonDecode(body);
        if (data is Map && data.containsKey('web')) return null;
        return 'Antwort ohne Web-Treffer';
      } catch (_) {
        return 'Ungültige JSON-Antwort';
      }
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  static String _httpError(int code) {
    switch (code) {
      case 401:
        return 'HTTP 401 – API-Key ungültig';
      case 422:
        return 'HTTP 422 – Anfrage abgelehnt (Plan/Parameter prüfen)';
      case 429:
        return 'HTTP 429 – Rate-Limit erreicht';
      default:
        return 'Brave HTTP $code';
    }
  }
}
