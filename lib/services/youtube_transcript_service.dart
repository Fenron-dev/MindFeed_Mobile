import 'dart:convert';
import 'package:http/http.dart' as http;

/// Holt YouTube-Transkripte direkt (ohne API-Key) aus der Watch-Seite:
/// captionTracks → baseUrl → Transkript-XML. Schlägt der Abruf fehl (keine
/// Untertitel, Format-Änderung, Blockade), liefert er null → die UI bietet
/// dann den manuellen Einfüge-Fallback an.
class YoutubeTranscriptService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';

  /// Extrahiert die Video-ID aus einer YouTube-URL (oder gibt die Eingabe
  /// zurück, falls sie bereits wie eine ID aussieht).
  static String? videoId(String input) {
    final u = Uri.tryParse(input.trim());
    if (u == null || (!u.hasScheme)) {
      // Sieht es wie eine reine ID aus?
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
    try {
      final page = await http.get(
        // bpctr/has_verified umgehen die EU-Consent-Wall, die sonst eine
        // Zwischenseite ohne captionTracks liefert.
        Uri.parse(
            'https://www.youtube.com/watch?v=$vid&hl=en&bpctr=9999999999&has_verified=1'),
        headers: {
          'User-Agent': _ua,
          'Accept-Language': 'en-US,en;q=0.9',
          'Cookie': 'CONSENT=YES+cb.20210328-17-p0.en+FX+000',
        },
      );
      if (page.statusCode != 200) return null;
      final pageBody = utf8.decode(page.bodyBytes, allowMalformed: true);

      final arrJson = _extractBalanced(pageBody, '"captionTracks":');
      if (arrJson == null) return null;
      final tracks = (jsonDecode(arrJson) as List).cast<Map<String, dynamic>>();
      if (tracks.isEmpty) return null;

      // Bevorzugte Sprache, sonst erste Spur
      final track = tracks.firstWhere(
        (t) => (t['languageCode'] as String?)?.startsWith(langPref) == true,
        orElse: () => tracks.first,
      );
      final baseUrl = track['baseUrl'] as String?;
      if (baseUrl == null) return null;

      final tr = await http.get(Uri.parse(baseUrl),
          headers: {'User-Agent': _ua});
      if (tr.statusCode != 200) return null;
      final text = _parseTranscriptXml(
          utf8.decode(tr.bodyBytes, allowMalformed: true));
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
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
