import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../url_metadata_service.dart';

/// Ruft Video-Metadaten über die offizielle YouTube Data API v3 ab.
///
/// Liefert deutlich mehr als der oEmbed-Pfad: Kanal, Dauer, Aufrufe, Likes,
/// Veröffentlichungsdatum, Tags, Beschreibung, Thumbnail. Die Zusatzfelder
/// werden in [UrlMetadata.extraProps] unter den kanonischen Property-Keys des
/// Katalogs abgelegt, damit sie über den MetadataRecord-Bridge im Review-Sheet
/// erscheinen.
class YoutubeApiSource {
  const YoutubeApiSource._();

  /// `null` bei fehlendem Key, Netzwerkfehler oder leerem Ergebnis → Aufrufer
  /// fällt dann auf den oEmbed-Pfad zurück.
  static Future<UrlMetadata?> fetch(String videoId, String apiKey) async {
    if (apiKey.isEmpty) return null;
    try {
      final uri = Uri.parse(
          'https://www.googleapis.com/youtube/v3/videos'
          '?part=snippet,contentDetails,statistics'
          '&id=$videoId&key=$apiKey');
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final items = json['items'] as List?;
      if (items == null || items.isEmpty) return null;

      final item = items.first as Map<String, dynamic>;
      final snippet = (item['snippet'] as Map<String, dynamic>?) ?? {};
      final content = (item['contentDetails'] as Map<String, dynamic>?) ?? {};
      final stats = (item['statistics'] as Map<String, dynamic>?) ?? {};

      final title = (snippet['title'] as String?)?.trim() ?? 'YouTube Video';
      final channel = (snippet['channelTitle'] as String?)?.trim() ?? 'YouTube';
      var description = (snippet['description'] as String?)?.trim() ?? '';
      if (description.length > 500) {
        description = '${description.substring(0, 500)}…';
      }
      final thumb = _bestThumbnail(snippet['thumbnails']) ??
          'https://img.youtube.com/vi/$videoId/hqdefault.jpg';

      final extra = <String, String>{'youtube_channel': channel};

      final duration = formatDuration(content['duration'] as String?);
      if (duration != null) extra['youtube_laufzeit'] = duration;

      final published = formatDate(snippet['publishedAt'] as String?);
      if (published != null) extra['youtube_hochgeladen'] = published;

      final views = stats['viewCount'] as String?;
      if (views != null && views.isNotEmpty) extra['youtube_views'] = views;

      final likes = stats['likeCount'] as String?;
      if (likes != null && likes.isNotEmpty) extra['youtube_likes'] = likes;

      final tags = (snippet['tags'] as List?)?.cast<String>();
      if (tags != null && tags.isNotEmpty) {
        extra['youtube_tags'] = tags.take(15).join(', ');
      }

      return UrlMetadata(
        title: title,
        description: description,
        image: thumb,
        domain: 'youtube.com',
        authorName: channel,
        mediaType: 'YOUTUBE',
        extraProps: extra,
      );
    } catch (_) {
      return null;
    }
  }

  /// Wählt das höchstauflösende verfügbare Thumbnail.
  static String? _bestThumbnail(dynamic thumbnails) {
    if (thumbnails is! Map) return null;
    for (final key in ['maxres', 'standard', 'high', 'medium', 'default']) {
      final t = thumbnails[key];
      if (t is Map && t['url'] is String) return t['url'] as String;
    }
    return null;
  }

  /// ISO-8601-Dauer (z.B. PT1H2M3S) → "1:02:03" bzw. "02:03".
  static String? formatDuration(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final m = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?').firstMatch(iso);
    if (m == null) return null;
    final h = int.tryParse(m.group(1) ?? '') ?? 0;
    final min = int.tryParse(m.group(2) ?? '') ?? 0;
    final s = int.tryParse(m.group(3) ?? '') ?? 0;
    if (h == 0 && min == 0 && s == 0) return null;
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) {
      final mm = min.toString().padLeft(2, '0');
      return '$h:$mm:$ss';
    }
    return '${min.toString().padLeft(2, '0')}:$ss';
  }

  /// ISO-Zeitstempel → "dd.mm.yyyy".
  static String? formatDate(String? iso) {
    if (iso == null || iso.length < 10) return null;
    final d = DateTime.tryParse(iso);
    if (d == null) return null;
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd.$mm.${d.year}';
  }
}
