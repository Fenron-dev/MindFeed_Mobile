import 'package:http/http.dart' as http;

/// BoardGameGeek XML API2 — öffentlich, kein Auth nötig (von Mobilgeräten)
class BggService {
  static const _base = 'https://boardgamegeek.com/xmlapi2';

  // ─── Suche ────────────────────────────────────────────────────────────────

  static Future<List<BggSearchResult>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final uri = Uri.parse(
        '$_base/search?query=${Uri.encodeComponent(query)}&type=boardgame,rpgitem');
    try {
      final res = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      return _parseSearch(res.body);
    } catch (_) {
      return [];
    }
  }

  // ─── Details zu einer BGG-ID ─────────────────────────────────────────────

  static Future<BggGame?> fetchById(String id) async {
    final uri = Uri.parse('$_base/thing?id=$id&stats=1');
    try {
      final res = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return _parseThing(res.body);
    } catch (_) {
      return null;
    }
  }

  // ─── URL-Erkennung (boardgamegeek.com/boardgame/<id>/...) ────────────────

  static String? extractBggId(String url) {
    final match =
        RegExp(r'boardgamegeek\.com/(?:boardgame|rpgitem)/(\d+)')
            .firstMatch(url);
    return match?.group(1);
  }

  // ─── XML-Parser (Regex-basiert, kein Zusatzpaket) ────────────────────────

  static List<BggSearchResult> _parseSearch(String xml) {
    final results = <BggSearchResult>[];
    final itemPattern = RegExp(
        r'<item\s+type="([^"]+)"\s+id="(\d+)"[^>]*>(.*?)</item>',
        dotAll: true);
    for (final m in itemPattern.allMatches(xml)) {
      final type = m.group(1) ?? '';
      final id = m.group(2) ?? '';
      final inner = m.group(3) ?? '';
      final name = _attrVal(inner, 'name', typeFilter: 'primary') ??
          _attrVal(inner, 'name') ?? '';
      final year = _attrVal(inner, 'yearpublished') ?? '';
      results.add(BggSearchResult(id: id, name: name, year: year, type: type));
    }
    return results;
  }

  static BggGame? _parseThing(String xml) {
    final itemMatch =
        RegExp(r'<item\s+type="([^"]+)"\s+id="(\d+)"[^>]*>(.*?)</item>',
                dotAll: true)
            .firstMatch(xml);
    if (itemMatch == null) return null;

    final type = itemMatch.group(1) ?? 'boardgame';
    final id = itemMatch.group(2) ?? '';
    final inner = itemMatch.group(3) ?? '';

    final thumbnail = _tagContent(inner, 'thumbnail');
    final image = _tagContent(inner, 'image');
    final name = _attrVal(inner, 'name', typeFilter: 'primary') ??
        _attrVal(inner, 'name') ?? '';
    final desc = _tagContent(inner, 'description') ?? '';
    final year = _attrVal(inner, 'yearpublished') ?? '';
    final minP = _attrVal(inner, 'minplayers') ?? '';
    final maxP = _attrVal(inner, 'maxplayers') ?? '';
    final avgStr = _nestedAttr(inner, 'average') ?? '';
    final avg = double.tryParse(avgStr);

    // Kategorien + Mechaniken
    final categories = _linkValues(inner, 'boardgamecategory');
    final mechanics = _linkValues(inner, 'boardgamemechanic');
    final designers = _linkValues(inner, 'boardgamedesigner');
    final publishers = _linkValues(inner, 'boardgamepublisher');

    return BggGame(
      id: id,
      type: type,
      name: name,
      description: _decodeHtml(desc),
      year: year,
      thumbnail: thumbnail,
      image: image,
      minPlayers: minP,
      maxPlayers: maxP,
      avgRating: avg,
      categories: categories,
      mechanics: mechanics,
      designers: designers,
      publishers: publishers,
    );
  }

  // ─── Regex-Helfer ─────────────────────────────────────────────────────────

  /// Liest value="..." von einem Tag, optional gefiltert nach type="primary"
  static String? _attrVal(String xml, String tag, {String? typeFilter}) {
    final pattern = typeFilter != null
        ? RegExp('<$tag\\s[^>]*?type="$typeFilter"[^>]*?value="([^"]*)"')
        : RegExp('<$tag\\s[^>]*?value="([^"]*)"');
    return pattern.firstMatch(xml)?.group(1);
  }

  /// Liest <tag>content</tag>
  static String? _tagContent(String xml, String tag) {
    final m = RegExp('<$tag>([\\s\\S]*?)</$tag>').firstMatch(xml);
    return m?.group(1)?.trim();
  }

  /// Liest verschachteltes value="..." (z.B. <average value="7.1">)
  static String? _nestedAttr(String xml, String tag) {
    final m = RegExp('<$tag\\s+[^>]*?value="([^"]*)"').firstMatch(xml);
    return m?.group(1);
  }

  /// Alle value="..." von <link type="linkType" ...>
  static List<String> _linkValues(String xml, String linkType) {
    final pattern =
        RegExp('<link\\s+type="$linkType"[^>]*?value="([^"]*)"');
    return pattern.allMatches(xml).map((m) => m.group(1) ?? '').toList();
  }

  /// Minimales HTML-Entity-Decoding
  static String _decodeHtml(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('<br/>', '\n')
      .replaceAll('<br>', '\n');

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
    'Accept': 'application/xml,text/xml,*/*',
  };
}

// ─── Datenmodelle ─────────────────────────────────────────────────────────────

class BggSearchResult {
  final String id;
  final String name;
  final String year;
  final String type; // 'boardgame' | 'rpgitem'

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
  final String name;
  final String description;
  final String year;
  final String? thumbnail;
  final String? image;
  final String minPlayers;
  final String maxPlayers;
  final double? avgRating;
  final List<String> categories;
  final List<String> mechanics;
  final List<String> designers;
  final List<String> publishers;

  const BggGame({
    required this.id,
    required this.type,
    required this.name,
    required this.description,
    required this.year,
    this.thumbnail,
    this.image,
    required this.minPlayers,
    required this.maxPlayers,
    this.avgRating,
    required this.categories,
    required this.mechanics,
    required this.designers,
    required this.publishers,
  });

  String get bggUrl =>
      'https://boardgamegeek.com/${type == 'rpgitem' ? 'rpgitem' : 'boardgame'}/$id';

  String get playersLabel {
    if (minPlayers.isEmpty && maxPlayers.isEmpty) return '';
    if (minPlayers == maxPlayers) return '$minPlayers Spieler';
    return '$minPlayers–$maxPlayers Spieler';
  }
}
