import 'dart:convert';
import 'package:http/http.dart' as http;

/// Holt YouTube-Transkripte ohne API-Key. Zwei Strategien:
///  1. InnerTube-Player-API (Android-Client) — zuverlässig, umgeht die
///     Consent-Wall und Signatur-Anforderungen der Web-Seite.
///  2. Fallback: captionTracks aus der Watch-HTML scrapen.
/// Aus den captionTracks wird die baseUrl geholt und das Transkript-XML
/// (bzw. json3) zu reinem Text geparst. Bei Fehlschlag → null (UI bietet dann
/// den manuellen Einfüge-Dialog an).
class YoutubeTranscriptService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';

  // Öffentlicher InnerTube-Android-Key (wie von yt-dlp u.a. genutzt).
  static const _androidKey = 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w';

  /// Extrahiert die Video-ID aus einer YouTube-URL (oder gibt die Eingabe
  /// zurück, falls sie bereits wie eine ID aussieht).
  static String? videoId(String input) {
    final u = Uri.tryParse(input.trim());
    if (u == null || !u.hasScheme) {
      return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(input.trim())
          ? input.trim() : null;
    }
    if (u.host.contains('youtu.be')) {
      return u.pathSegments.isNotEmpty ? u.pathSegments.first : null;
    }
    if (u.host.contains('youtube.com')) {
      return u.queryParameters['v'] ??
          (u.pathSegments.length >= 2 && u.pathSegments.first == 'shorts'
              ? u.pathSegments[1] : null);
    }
    return null;
  }

  /// Versucht das Transkript zu holen. [langPref] = bevorzugte Sprache.
  /// Gibt den reinen Text zurück oder null bei Fehlschlag.
  static Future<String?> fetch(String videoOrUrl, {String langPref = 'de'}) async {
    final vid = videoId(videoOrUrl);
    if (vid == null) return null;

    List<Map<String, dynamic>>? tracks;
    try {
      tracks = await _tracksFromInnerTube(vid);
    } catch (_) {
      tracks = null;
    }
    if (tracks == null || tracks.isEmpty) {
      try {
        tracks = await _tracksFromWatchPage(vid);
      } catch (_) {
        tracks = null;
      }
    }
    if (tracks == null || tracks.isEmpty) return null;

    // Bevorzugt manuelle Untertitel in der Wunschsprache, dann Wunschsprache
    // (auch auto-generiert), sonst erste Spur.
    Map<String, dynamic>? pick(bool Function(Map<String, dynamic>) test) {
      for (final t in tracks!) {
        if (test(t)) return t;
      }
      return null;
    }
    final track = pick((t) =>
            (t['languageCode'] as String?)?.startsWith(langPref) == true &&
            t['kind'] != 'asr') ??
        pick((t) =>
            (t['languageCode'] as String?)?.startsWith(langPref) == true) ??
        pick((t) => (t['languageCode'] as String?)?.startsWith('en') == true) ??
        tracks.first;

    final baseUrl = track['baseUrl'] as String?;
    if (baseUrl == null) return null;

    try {
      final tr = await http.get(Uri.parse(baseUrl), headers: {'User-Agent': _ua});
      if (tr.statusCode != 200) return null;
      final text =
          _parseTranscriptXml(utf8.decode(tr.bodyBytes, allowMalformed: true));
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// Strategie 1: InnerTube-Player-API (Android-Client).
  static Future<List<Map<String, dynamic>>?> _tracksFromInnerTube(
      String vid) async {
    final res = await http.post(
      Uri.parse('https://www.youtube.com/youtubei/v1/player?key=$_androidKey'),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent':
            'com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip',
        'X-YouTube-Client-Name': '3',
        'X-YouTube-Client-Version': '19.09.37',
      },
      body: jsonEncode({
        'context': {
          'client': {
            'clientName': 'ANDROID',
            'clientVersion': '19.09.37',
            'androidSdkVersion': 30,
            'hl': 'de',
            'gl': 'DE',
          },
        },
        'videoId': vid,
      }),
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;

    final data = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true))
        as Map<String, dynamic>;
    final tracks = data['captions']?['playerCaptionsTracklistRenderer']
        ?['captionTracks'] as List<dynamic>?;
    return tracks?.cast<Map<String, dynamic>>();
  }

  /// Strategie 2: captionTracks aus der Watch-HTML scrapen.
  static Future<List<Map<String, dynamic>>?> _tracksFromWatchPage(
      String vid) async {
    final page = await http.get(
      Uri.parse(
          'https://www.youtube.com/watch?v=$vid&hl=en&bpctr=9999999999&has_verified=1'),
      headers: {
        'User-Agent': _ua,
        'Accept-Language': 'en-US,en;q=0.9',
        'Cookie': 'CONSENT=YES+cb.20210328-17-p0.en+FX+000',
      },
    ).timeout(const Duration(seconds: 10));
    if (page.statusCode != 200) return null;

    final body = utf8.decode(page.bodyBytes, allowMalformed: true);
    final arrJson = _extractBalanced(body, '"captionTracks":');
    if (arrJson == null) return null;
    return (jsonDecode(arrJson) as List).cast<Map<String, dynamic>>();
  }

  /// Extrahiert ein balanciertes JSON-Array, das nach [key] beginnt.
  static String? _extractBalanced(String body, String key) {
    final start = body.indexOf(key);
    if (start == -1) return null;
    int i = body.indexOf('[', start);
    if (i == -1) return null;
    int depth = 0;
    bool inStr = false;
    bool esc = false;
    for (int j = i; j < body.length; j++) {
      final c = body[j];
      if (inStr) {
        if (esc) { esc = false; }
        else if (c == '\\') { esc = true; }
        else if (c == '"') { inStr = false; }
        continue;
      }
      if (c == '"') { inStr = true; }
      else if (c == '[') { depth++; }
      else if (c == ']') {
        depth--;
        if (depth == 0) return body.substring(i, j + 1);
      }
    }
    return null;
  }

  static String _parseTranscriptXml(String xml) {
    final matches =
        RegExp(r'<text[^>]*>(.*?)</text>', dotAll: true).allMatches(xml);
    final sb = StringBuffer();
    for (final m in matches) {
      final line = _unescape(m.group(1) ?? '');
      if (line.trim().isNotEmpty) sb.writeln(line.trim());
    }
    return sb.toString().trim();
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#160;', ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
}
