import 'package:html/parser.dart' as html_parser;
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

  static String? extractUrl(String text) =>
      _urlPattern.firstMatch(text)?.group(0);

  static Future<UrlMetadata?> fetch(String url) async {
    try {
      final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
      final host = uri.host.toLowerCase();

      if (host.contains('youtube.com') || host.contains('youtu.be')) {
        return _fetchYoutube(uri);
      }

      final response = await http
          .get(uri, headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml',
            'Accept-Language': 'de-DE,de;q=0.9,en;q=0.8',
          })
          .timeout(const Duration(seconds: 8));

      if (response.statusCode < 200 || response.statusCode >= 400) {
        return _domainFallback(uri);
      }

      final doc = html_parser.parse(response.body);

      String? og(String prop) =>
          doc.querySelector('meta[property="og:$prop"]')?.attributes['content'] ??
          doc.querySelector('meta[name="og:$prop"]')?.attributes['content'];

      final title = og('title') ??
          doc.querySelector('title')?.text.trim() ??
          doc.querySelector('meta[name="title"]')?.attributes['content'];

      final desc = og('description') ??
          doc.querySelector('meta[name="description"]')?.attributes['content'];

      final image = og('image');

      return UrlMetadata(
        title: (title?.isNotEmpty == true) ? title!.trim() : _hostLabel(uri),
        description: desc?.trim() ?? '',
        image: image,
        domain: host.replaceFirst('www.', ''),
      );
    } catch (_) {
      try {
        return _domainFallback(Uri.parse(url));
      } catch (_) {
        return null;
      }
    }
  }

  // ─── YouTube oEmbed ────────────────────────────────────────────────────────

  static Future<UrlMetadata?> _fetchYoutube(Uri uri) async {
    try {
      String? vid = uri.queryParameters['v'];
      if (vid == null && uri.host.contains('youtu.be')) {
        vid = uri.pathSegments.firstOrNull;
      }
      if (vid == null) return null;
      if (vid.contains('?')) vid = vid.split('?').first;

      final res = await http
          .get(Uri.parse(
              'https://www.youtube.com/oembed'
              '?url=https://www.youtube.com/watch?v=$vid&format=json'))
          .timeout(const Duration(seconds: 6));

      if (res.statusCode != 200) {
        return UrlMetadata(
          title: 'YouTube Video',
          description: '',
          image: 'https://img.youtube.com/vi/$vid/hqdefault.jpg',
          domain: 'youtube.com',
        );
      }

      final title = _jsonStr(res.body, 'title') ?? 'YouTube Video';
      final author = _jsonStr(res.body, 'author_name') ?? 'YouTube';
      final thumb = _jsonStr(res.body, 'thumbnail_url') ??
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

  // ─── Helpers ───────────────────────────────────────────────────────────────

  static UrlMetadata _domainFallback(Uri uri) => UrlMetadata(
        title: _hostLabel(uri),
        description: '',
        domain: uri.host.replaceFirst('www.', ''),
      );

  static String _hostLabel(Uri uri) {
    final host = uri.host.replaceFirst('www.', '');
    // Versuche einen lesbaren Titel aus dem Pfad zu bauen
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      final last = segments.last.replaceAll(RegExp(r'[-_]'), ' ');
      if (last.length > 3 && !last.contains('.')) {
        final readable = last.split(' ')
            .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
            .join(' ');
        return '$readable — $host';
      }
    }
    return host;
  }

  static String? _jsonStr(String json, String key) =>
      RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(json)?.group(1);
}
