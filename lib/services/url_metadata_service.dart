import 'package:http/http.dart' as http;

class UrlMetadata {
  final String title;
  final String description;
  final String? image;
  final String domain;

  const UrlMetadata({
    required this.title,
    required this.description,
    this.image,
    required this.domain,
  });
}

class UrlMetadataService {
  static final _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);

  /// Erkennt die erste URL im Text.
  static String? extractUrl(String text) =>
      _urlPattern.firstMatch(text)?.group(0);

  /// Holt OpenGraph-Metadaten für eine URL.
  /// Gibt null zurück bei Fehlern (keine Exception nach oben).
  static Future<UrlMetadata?> fetch(String url) async {
    try {
      final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
      final host = uri.host.toLowerCase();

      // YouTube: oEmbed statt HTML-Scraping (YouTube blockiert Scraping)
      if (host.contains('youtube.com') || host.contains('youtu.be')) {
        return _fetchYoutube(uri);
      }

      final response = await http
          .get(uri, headers: {
            'User-Agent':
                'Mozilla/5.0 (compatible; MindFeed/1.0; +https://github.com/Fenron-dev)',
            'Accept': 'text/html',
          })
          .timeout(const Duration(seconds: 6));

      if (!response.ok) return null;
      return _parseOg(response.body, host);
    } catch (_) {
      return null;
    }
  }

  static Future<UrlMetadata?> _fetchYoutube(Uri uri) async {
    try {
      // Video-ID extrahieren
      String? vid = uri.queryParameters['v'];
      if (vid == null && uri.host.contains('youtu.be')) {
        vid = uri.pathSegments.firstOrNull;
      }
      if (vid == null) return null;
      if (vid.contains('?')) vid = vid.split('?').first;

      final oembedUri = Uri.parse(
          'https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$vid&format=json');
      final res = await http.get(oembedUri)
          .timeout(const Duration(seconds: 5));
      if (!res.ok) return null;

      // Manuelles JSON-Parsing (kein dart:convert nötig für diesen kleinen Fall)
      final body = res.body;
      final title = _jsonStr(body, 'title') ?? 'YouTube Video';
      final author = _jsonStr(body, 'author_name') ?? 'YouTube';
      final thumb = _jsonStr(body, 'thumbnail_url') ??
          'https://img.youtube.com/vi/$vid/hqdefault.jpg';

      return UrlMetadata(
        title: title,
        description: 'YouTube-Video von $author',
        image: thumb,
        domain: 'youtube.com',
      );
    } catch (_) {
      return null;
    }
  }

  static UrlMetadata _parseOg(String html, String domain) {
    String? og(String prop) {
      final patterns = [
        RegExp(
            '<meta[^>]*property=["\']og:$prop["\'][^>]*content=["\']([^"\']+)["\']',
            caseSensitive: false),
        RegExp(
            '<meta[^>]*content=["\']([^"\']+)["\'][^>]*property=["\']og:$prop["\']',
            caseSensitive: false),
      ];
      for (final p in patterns) {
        final m = p.firstMatch(html);
        if (m != null) return _decodeHtml(m.group(1)!.trim());
      }
      return null;
    }

    final titleMeta = RegExp(r'<title>([^<]+)</title>', caseSensitive: false)
        .firstMatch(html)
        ?.group(1)
        ?.trim();

    final descMeta = RegExp(
            r'''<meta[^>]*name=["']description["'][^>]*content=["']([^"']+)["']''',
            caseSensitive: false)
        .firstMatch(html)
        ?.group(1)
        ?.trim();

    return UrlMetadata(
      title: og('title') ?? titleMeta ?? 'Link: $domain',
      description: og('description') ?? descMeta ?? '',
      image: og('image'),
      domain: domain,
    );
  }

  static String? _jsonStr(String json, String key) {
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(json);
    return m?.group(1);
  }

  static String _decodeHtml(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}

extension on http.Response {
  bool get ok => statusCode >= 200 && statusCode < 300;
}
