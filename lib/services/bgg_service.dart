import 'dart:convert';
import 'package:http/http.dart' as http;

/// GeekDo / BGG / VGG / RPGG — öffentliche JSON-API (kein Auth nötig)
/// Endpunkt: https://api.geekdo.com/api/geekitems?objectid=X&objecttype=thing
class BggService {
  static const _apiBase = 'https://api.geekdo.com/api';

  // ─── ID aus URL extrahieren ───────────────────────────────────────────────
  // Unterstützt BGG, VGG und RPGGeek URLs:
  //   boardgamegeek.com/boardgame/<id>/slug
  //   videogamegeek.com/videogame/<id>/slug
  //   rpggeek.com/rpgitem/<id>/slug   oder  rpggeek.com/rpg/<id>/slug

  static String? extractBggId(String url) {
    final match = RegExp(
      r'(?:boardgame|videogame|rpg)geek\.com/(?:boardgame|videogame|rpgitem|rpg)/(\d+)',
    ).firstMatch(url);
    return match?.group(1);
  }

  // ─── Details zu einer Geekdo-ID ──────────────────────────────────────────

  static Future<BggGame?> fetchById(String id) async {
    final uri = Uri.parse('$_apiBase/geekitems?objectid=$id&objecttype=thing');
    try {
      final res = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return _parseItem(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // ─── Suche (für Settings-Screen) ─────────────────────────────────────────

  static Future<List<BggSearchResult>> search(String query) async {
    if (query.trim().isEmpty) return [];
    // GeekDo-Suche
    final uri = Uri.parse(
        '$_apiBase/search?q=${Uri.encodeComponent(query)}&objecttype=thing&nosession=1');
    try {
      final res = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? [];
      return items.map((i) {
        final m = i as Map<String, dynamic>;
        return BggSearchResult(
          id: m['objectid']?.toString() ?? '',
          name: m['name'] as String? ?? '',
          year: m['yearpublished']?.toString() ?? '',
          type: m['subtype'] as String? ?? 'boardgame',
        );
      }).where((r) => r.id.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  // ─── Item aus JSON-Antwort parsen ─────────────────────────────────────────

  static BggGame? _parseItem(Map<String, dynamic> data) {
    final item = data['item'] as Map<String, dynamic>?;
    if (item == null) return null;

    final id = item['objectid']?.toString() ?? '';
    final subtype = item['subtype'] as String? ?? 'boardgame';
    final name = item['name'] as String? ?? '';

    // Beschreibung: HTML bereinigen
    final rawDesc = item['description'] as String? ?? '';
    final desc = _cleanHtml(rawDesc);
    final shortDesc = item['short_description'] as String? ?? '';
    final finalDesc = desc.isNotEmpty ? desc : shortDesc;

    final year = item['yearpublished']?.toString() ?? '';
    final minP = item['minplayers']?.toString() ?? '';
    final maxP = item['maxplayers']?.toString() ?? '';
    final minTime = item['minplaytime']?.toString() ?? '';
    final maxTime = item['maxplaytime']?.toString() ?? '';

    // Bilder: imageurl (246×300 fit) oder images.original (full)
    final images = item['images'] as Map<String, dynamic>? ?? {};
    final imageurl = item['imageurl'] as String?;
    final originalUrl = images['original'] is String
        ? images['original'] as String
        : imageurl;

    // Links (Kategorien, Mechaniken, Designer, Publisher)
    final links = item['links'] as Map<String, dynamic>? ?? {};
    List<String> _names(String key) =>
        ((links[key] as List?) ?? [])
            .map((l) => (l as Map)['name'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .toList();

    final categories = [
      ..._names('boardgamecategory'),
      ..._names('videogamecategory'),
      ..._names('videogamegenre'),
      ..._names('rpgcategory'),
    ];
    final mechanics = [
      ..._names('boardgamemechanic'),
      ..._names('videogamemechanic'),
    ];
    final designers = [
      ..._names('boardgamedesigner'),
      ..._names('videogamedesigner'),
    ];
    final publishers = [
      ..._names('boardgamepublisher'),
      ..._names('videogamepublisher'),
    ];

    // MediaType aus subtype ableiten
    final mediaType = switch (subtype) {
      'boardgame' || 'boardgameexpansion' => 'BOARDGAME',
      'videogame' => 'VIDEOGAME',
      'rpgitem' => 'TTRPG',
      _ => 'BOARDGAME',
    };

    return BggGame(
      id: id,
      type: subtype,
      mediaType: mediaType,
      name: name,
      description: finalDesc,
      year: year,
      thumbnail: imageurl,
      image: originalUrl,
      minPlayers: minP,
      maxPlayers: maxP,
      minPlaytime: minTime,
      maxPlaytime: maxTime,
      avgRating: null, // Erfordert Auth → nicht verfügbar
      categories: categories,
      mechanics: mechanics,
      designers: designers,
      publishers: publishers,
    );
  }

  // ─── HTML-Bereinigung ─────────────────────────────────────────────────────

  static String _cleanHtml(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&mdash;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll('&rsquo;', "'")
      .replaceAll('&lsquo;', "'")
      .replaceAll('&rdquo;', '"')
      .replaceAll('&ldquo;', '"')
      .replaceAll('&hellip;', '…')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
    'Accept': 'application/json,*/*',
  };
}

// ─── Datenmodelle ─────────────────────────────────────────────────────────────

class BggSearchResult {
  final String id;
  final String name;
  final String year;
  final String type; // 'boardgame' | 'videogame' | 'rpgitem'

  const BggSearchResult({
    required this.id,
    required this.name,
    required this.year,
    required this.type,
  });
}

class BggGame {
  final String id;
  final String type;
  final String mediaType; // 'BOARDGAME' | 'VIDEOGAME' | 'TTRPG'
  final String name;
  final String description;
  final String year;
  final String? thumbnail;
  final String? image;
  final String minPlayers;
  final String maxPlayers;
  final String minPlaytime;
  final String maxPlaytime;
  final double? avgRating;
  final List<String> categories;
  final List<String> mechanics;
  final List<String> designers;
  final List<String> publishers;

  const BggGame({
    required this.id,
    required this.type,
    this.mediaType = 'BOARDGAME',
    required this.name,
    required this.description,
    required this.year,
    this.thumbnail,
    this.image,
    required this.minPlayers,
    required this.maxPlayers,
    this.minPlaytime = '',
    this.maxPlaytime = '',
    this.avgRating,
    required this.categories,
    required this.mechanics,
    required this.designers,
    required this.publishers,
  });

  String get bggUrl {
    final path = switch (type) {
      'rpgitem' => 'rpgitem',
      'videogame' => 'videogame',
      _ => 'boardgame',
    };
    return 'https://boardgamegeek.com/$path/$id';
  }

  String get playersLabel {
    if (minPlayers.isEmpty && maxPlayers.isEmpty) return '';
    if (minPlayers == maxPlayers) return '$minPlayers Spieler';
    return '$minPlayers–$maxPlayers Spieler';
  }

  String get playtimeLabel {
    if (minPlaytime.isEmpty && maxPlaytime.isEmpty) return '';
    if (minPlaytime == maxPlaytime) return '$minPlaytime Min';
    if (minPlaytime.isEmpty) return '$maxPlaytime Min';
    if (maxPlaytime.isEmpty) return '$minPlaytime Min';
    return '$minPlaytime–$maxPlaytime Min';
  }
}
