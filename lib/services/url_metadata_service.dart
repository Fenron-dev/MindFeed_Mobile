import 'dart:convert';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'bgg_service.dart';

class UrlMetadata {
  final String title;
  final String description;
  final String? image;
  final String domain;
  // AniList-Felder
  final List<String> genres;
  final int? score;
  final String? mediaType;  // 'ANIME' | 'MANGA' | 'TTRPG' | 'BOARDGAME'
  final String? anilistFormat; // TV, MOVIE, OVA, ONA, MANGA, NOVEL …
  final int? anilistEpisodes;
  final int? anilistChapters;
  final String? anilistStudio;
  final int? anilistYear;
  final String? anilistStatus; // FINISHED, RELEASING, NOT_YET_RELEASED …
  final int? anilistSeason;
  final int? anilistTotalSeasons;
  // YouTube-Felder
  final String? authorName; // Kanal-Name

  const UrlMetadata({
    required this.title,
    required this.description,
    this.image,
    required this.domain,
    this.genres = const [],
    this.score,
    this.mediaType,
    this.anilistFormat,
    this.anilistEpisodes,
    this.anilistChapters,
    this.anilistStudio,
    this.anilistYear,
    this.anilistStatus,
    this.anilistSeason,
    this.anilistTotalSeasons,
    this.authorName,
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
      if (host.contains('anilist.co')) {
        return _fetchAniList(uri);
      }
      if (host.contains('boardgamegeek.com')) {
        return _fetchBgg(url);
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

  // ─── AniList GraphQL ───────────────────────────────────────────────────────
  // URL-Muster: /anime/<id>/, /manga/<id>/, /anime/<id>/title-slug/

  static Future<UrlMetadata?> _fetchAniList(Uri uri) async {
    try {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      // segments[0] = 'anime'|'manga', segments[1] = id
      if (segments.length < 2) return _domainFallback(uri);

      final typeStr = segments[0].toUpperCase(); // ANIME | MANGA
      final id = int.tryParse(segments[1]);
      if (id == null) return _domainFallback(uri);

      const query = r'''
        query ($id: Int, $type: MediaType) {
          Media(id: $id, type: $type) {
            title { romaji english native }
            description(asHtml: false)
            coverImage { extraLarge large }
            bannerImage
            genres
            averageScore
            type
            format
            status
            episodes
            chapters
            startDate { year }
            studios(isMain: true) { nodes { name } }
            relations {
              edges { relationType }
              nodes { id }
            }
          }
        }
      ''';

      final res = await http
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'query': query,
              'variables': {'id': id, 'type': typeStr},
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) return _domainFallback(uri);

      final data = jsonDecode(res.body);
      final media = data['data']?['Media'];
      if (media == null) return _domainFallback(uri);

      final titleObj = media['title'] as Map<String, dynamic>?;
      final title = (titleObj?['english'] as String?)?.isNotEmpty == true
          ? titleObj!['english'] as String
          : (titleObj?['romaji'] as String?) ?? 'AniList';

      final rawDesc = (media['description'] as String?) ?? '';
      // HTML-Tags aus Beschreibung entfernen
      final desc = rawDesc
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#039;', "'")
          .trim();

      final coverImg = (media['coverImage'] as Map<String, dynamic>?);
      final image = (coverImg?['extraLarge'] as String?) ??
          (coverImg?['large'] as String?) ??
          (media['bannerImage'] as String?);

      final genres = (media['genres'] as List<dynamic>?)
              ?.map((g) => g.toString())
              .toList() ??
          [];

      final score = media['averageScore'] as int?;
      final mediaType = media['type'] as String?;
      final format = media['format'] as String?;
      final status = media['status'] as String?;

      final year = (media['startDate'] as Map?)?['year'] as int?;
      final episodes = media['episodes'] as int?;
      final chapters = media['chapters'] as int?;

      final studioNodes = (media['studios']?['nodes'] as List<dynamic>?);
      final studioName = studioNodes?.isNotEmpty == true
          ? (studioNodes!.first as Map<String, dynamic>)['name'] as String?
          : null;

      // Staffel-Info aus Relations ermitteln
      final relEdges = (media['relations']?['edges'] as List?) ?? [];
      final relNodes = (media['relations']?['nodes'] as List?) ?? [];
      int? prequelId;
      int? sequelId;
      for (int i = 0; i < relEdges.length && i < relNodes.length; i++) {
        final relType = (relEdges[i] as Map)['relationType'] as String?;
        final nodeId = (relNodes[i] as Map)['id'] as int?;
        if (nodeId == null) continue;
        if (relType == 'PREQUEL' && prequelId == null) prequelId = nodeId;
        if (relType == 'SEQUEL' && sequelId == null) sequelId = nodeId;
      }

      int? season;
      int? totalSeasons;
      if (prequelId != null || sequelId != null) {
        try {
          final chain = await _computeSeasonChain(id, prequelId, sequelId);
          season = chain.$1;
          totalSeasons = chain.$2;
        } catch (_) {
          // Staffel-Info ist optional
        }
      }

      return UrlMetadata(
        title: title,
        // Nur der reine Beschreibungstext — Metadaten stehen in separaten Properties
        description: desc.length > 600 ? '${desc.substring(0, 600)}…' : desc,
        image: image,
        domain: 'anilist.co',
        genres: genres,
        score: score,
        mediaType: mediaType,
        anilistFormat: format,
        anilistEpisodes: episodes,
        anilistChapters: chapters,
        anilistStudio: studioName,
        anilistYear: year,
        anilistStatus: status,
        anilistSeason: season,
        anilistTotalSeasons: totalSeasons,
      );
    } catch (_) {
      return _domainFallback(uri);
    }
  }

  // ─── Staffel-Kette traversieren ────────────────────────────────────────────

  static Future<int?> _fetchDirectRelationId(
      int mediaId, String relationType) async {
    const q = r'''
      query ($id: Int) {
        Media(id: $id) {
          relations {
            edges { relationType }
            nodes { id }
          }
        }
      }
    ''';
    try {
      final res = await http
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'query': q, 'variables': {'id': mediaId}}),
          )
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      final edges =
          (data['data']?['Media']?['relations']?['edges'] as List?) ?? [];
      final nodes =
          (data['data']?['Media']?['relations']?['nodes'] as List?) ?? [];
      for (int i = 0; i < edges.length && i < nodes.length; i++) {
        if ((edges[i] as Map)['relationType'] == relationType) {
          return (nodes[i] as Map)['id'] as int?;
        }
      }
    } catch (_) {}
    return null;
  }

  // Gibt (aktuelle Staffel, Gesamtstaffeln) zurück
  static Future<(int, int)> _computeSeasonChain(
      int currentId, int? prequelId, int? sequelId) async {
    const maxHops = 5;
    final visited = <int>{currentId};

    // Rückwärts zählen (wie viele Vorgänger = aktuelle Staffel - 1)
    int season = 1;
    int? nextId = prequelId;
    while (nextId != null && season < maxHops + 1) {
      if (visited.contains(nextId)) break;
      visited.add(nextId);
      season++;
      nextId = await _fetchDirectRelationId(nextId, 'PREQUEL');
    }

    // Vorwärts zählen (wie viele Nachfolger)
    int sequelCount = 0;
    nextId = sequelId;
    while (nextId != null && sequelCount < maxHops) {
      if (visited.contains(nextId)) break;
      visited.add(nextId);
      sequelCount++;
      nextId = await _fetchDirectRelationId(nextId, 'SEQUEL');
    }

    return (season, season + sequelCount);
  }

  // ─── BoardGameGeek XML API ────────────────────────────────────────────────

  static Future<UrlMetadata?> _fetchBgg(String url) async {
    try {
      final id = BggService.extractBggId(url);
      if (id == null) return _domainFallback(Uri.parse(url));
      final game = await BggService.fetchById(id);
      if (game == null) return _domainFallback(Uri.parse(url));

      final details = [
        if (game.year.isNotEmpty) game.year,
        if (game.playersLabel.isNotEmpty) game.playersLabel,
        if (game.avgRating != null)
          '⭐ ${game.avgRating!.toStringAsFixed(1)}/10',
        if (game.categories.isNotEmpty) game.categories.take(3).join(', '),
      ].join(' · ');

      final desc = game.description.length > 400
          ? '${game.description.substring(0, 400)}…'
          : game.description;

      return UrlMetadata(
        title: game.name,
        description: details.isNotEmpty ? '$details\n\n$desc' : desc,
        image: game.image ?? game.thumbnail,
        domain: 'boardgamegeek.com',
        genres: game.categories,
        score: game.avgRating != null ? (game.avgRating! * 10).round() : null,
        mediaType: game.type == 'rpgitem' ? 'TTRPG' : 'BOARDGAME',
      );
    } catch (_) {
      return _domainFallback(Uri.parse(url));
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
        authorName: author,
        mediaType: 'YOUTUBE',
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
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      final last = segments.last.replaceAll(RegExp(r'[-_]'), ' ');
      if (last.length > 3 && !last.contains('.')) {
        final readable = last
            .split(' ')
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
