import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/prop_type.dart';
import '../domain/feed_filter.dart';
import 'ai/structure_template.dart';
import 'enrichment/api_field_prefs.dart';

// ─── Sync-Einstellungen ───────────────────────────────────────────────────────

enum SyncRole { server, client }

enum SyncAttachmentsDirection { both, downloadOnly, uploadOnly }

// ─── Tag-Stil ─────────────────────────────────────────────────────────────────

class TagStyle {
  final Color bgColor;
  final Color textColor;
  final Color borderColor;
  final double borderRadius; // 99 = Pill, 4 = Eckig
  final bool showHash;

  const TagStyle({
    this.bgColor    = const Color(0xFF042F2E),
    this.textColor  = const Color(0xFF14B8A6),
    this.borderColor = const Color(0xFF0F766E),
    this.borderRadius = 99,
    this.showHash   = true,
  });

  TagStyle copyWith({
    Color? bgColor, Color? textColor, Color? borderColor,
    double? borderRadius, bool? showHash,
  }) => TagStyle(
    bgColor: bgColor ?? this.bgColor,
    textColor: textColor ?? this.textColor,
    borderColor: borderColor ?? this.borderColor,
    borderRadius: borderRadius ?? this.borderRadius,
    showHash: showHash ?? this.showHash,
  );

  static const presets = [
    (label: 'Teal (Standard)', bg: Color(0xFF042F2E), text: Color(0xFF14B8A6), border: Color(0xFF0F766E)),
    (label: 'Indigo',          bg: Color(0xFF1E1B4B), text: Color(0xFFA78BFA), border: Color(0xFF4338CA)),
    (label: 'Rose',            bg: Color(0xFF4C0519), text: Color(0xFFFB7185), border: Color(0xFF9F1239)),
    (label: 'Amber',           bg: Color(0xFF451A03), text: Color(0xFFFBBF24), border: Color(0xFF92400E)),
    (label: 'Sky',             bg: Color(0xFF082F49), text: Color(0xFF38BDF8), border: Color(0xFF0369A1)),
    (label: 'Grau',            bg: Color(0xFF18181B), text: Color(0xFFA1A1AA), border: Color(0xFF3F3F46)),
  ];
}

// ─── Property-Templates ───────────────────────────────────────────────────────

class PropTemplate {
  final String id;
  final String name;
  final String emoji;
  final List<PropTemplateField> fields;
  /// Welche Felder (Keys) in der Feed-Karte angezeigt werden.
  /// Leer = die ersten 4 Nicht-System-Properties (bisheriges Verhalten).
  final List<String> cardFields;

  const PropTemplate({
    required this.id,
    required this.name,
    this.emoji = '📋',
    required this.fields,
    this.cardFields = const [],
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'emoji': emoji,
    'fields': fields.map((f) => f.toJson()).toList(),
    'cardFields': cardFields,
  };

  factory PropTemplate.fromJson(Map<String, dynamic> j) => PropTemplate(
    id: j['id'] as String,
    name: j['name'] as String,
    emoji: (j['emoji'] as String?) ?? '📋',
    fields: ((j['fields'] as List?) ?? [])
        .map((f) => PropTemplateField.fromJson(f as Map<String, dynamic>))
        .toList(),
    cardFields: ((j['cardFields'] as List?) ?? []).cast<String>(),
  );

  // Vordefinierte Starter-Templates
  static List<PropTemplate> get defaults => [
    PropTemplate(
      id: 'tpl-boardgame', name: 'Brettspiel', emoji: '🎲',
      fields: [
        PropTemplateField(key: 'Spieler', type: PropType.text.value),
        PropTemplateField(key: 'Spielzeit', type: PropType.text.value),
        PropTemplateField(key: 'Bewertung', type: PropType.rating.value),
        PropTemplateField(key: 'Verlag', type: PropType.text.value),
        PropTemplateField(key: 'Zuletzt gespielt', type: PropType.date.value),
        PropTemplateField(key: 'Besitzen', type: PropType.boolean.value, defaultValue: 'false'),
      ],
    ),
    PropTemplate(
      id: 'tpl-book', name: 'Buch', emoji: '📚',
      fields: [
        PropTemplateField(key: 'Autor', type: PropType.text.value),
        PropTemplateField(key: 'Seiten', type: PropType.number.value),
        PropTemplateField(key: 'Bewertung', type: PropType.rating.value),
        PropTemplateField(key: 'Genre', type: PropType.select.value),
        PropTemplateField(key: 'Gelesen am', type: PropType.date.value),
        PropTemplateField(key: 'Gelesen', type: PropType.boolean.value, defaultValue: 'false'),
      ],
    ),
    PropTemplate(
      id: 'tpl-anime', name: 'Anime / Serie', emoji: '🎬',
      fields: [
        PropTemplateField(key: 'Studio', type: PropType.text.value),
        PropTemplateField(key: 'Format', type: PropType.text.value),
        PropTemplateField(key: 'Jahr', type: PropType.text.value),
        PropTemplateField(key: 'Folgen gesamt', type: PropType.number.value),
        PropTemplateField(key: 'Aktuelle Folge', type: PropType.number.value),
        PropTemplateField(key: 'Bewertung', type: PropType.rating.value),
        PropTemplateField(key: 'Genre', type: PropType.tags.value),
        PropTemplateField(key: 'Status', type: PropType.select.value),
        PropTemplateField(key: 'Abgeschlossen', type: PropType.boolean.value, defaultValue: 'false'),
      ],
    ),
    PropTemplate(
      id: 'tpl-youtube', name: 'YouTube Video', emoji: '▶️',
      fields: [
        PropTemplateField(key: 'Kanal', type: PropType.text.value),
        PropTemplateField(key: 'Laufzeit', type: PropType.text.value),
        PropTemplateField(key: 'Hochgeladen', type: PropType.text.value),
        PropTemplateField(key: 'Geschaut', type: PropType.boolean.value, defaultValue: 'false'),
        PropTemplateField(key: 'Bewertung', type: PropType.rating.value),
        PropTemplateField(key: 'Notizen', type: PropType.text.value),
      ],
    ),
    PropTemplate(
      id: 'tpl-ttrpg', name: 'TTRPG / RPG', emoji: '🐉',
      fields: [
        PropTemplateField(key: 'System', type: PropType.text.value),
        PropTemplateField(key: 'Verlag', type: PropType.text.value),
        PropTemplateField(key: 'Genre', type: PropType.tags.value),
        PropTemplateField(key: 'Bewertung', type: PropType.rating.value),
        PropTemplateField(key: 'Besitzen', type: PropType.boolean.value, defaultValue: 'false'),
        PropTemplateField(key: 'Quelle', type: PropType.url.value),
      ],
    ),
    PropTemplate(
      id: 'tpl-videogame', name: 'Videospiel', emoji: '🎮',
      fields: [
        PropTemplateField(key: 'Entwickler', type: PropType.text.value),
        PropTemplateField(key: 'Publisher', type: PropType.text.value),
        PropTemplateField(key: 'Jahr', type: PropType.text.value),
        PropTemplateField(key: 'Genre', type: PropType.tags.value),
        PropTemplateField(key: 'Plattform', type: PropType.text.value),
        PropTemplateField(key: 'Bewertung', type: PropType.rating.value),
        PropTemplateField(key: 'Durchgespielt', type: PropType.boolean.value, defaultValue: 'false'),
        PropTemplateField(key: 'Spielzeit', type: PropType.text.value),
      ],
    ),
    PropTemplate(
      id: 'tpl-github', name: 'GitHub Repo', emoji: '💻',
      fields: [
        PropTemplateField(key: 'Sprache', type: PropType.text.value),
        PropTemplateField(key: 'Stars', type: PropType.number.value),
        PropTemplateField(key: 'Themen', type: PropType.tags.value),
        PropTemplateField(key: 'Lizenz', type: PropType.text.value),
        PropTemplateField(key: 'Status', type: PropType.select.value),
        PropTemplateField(key: 'Notizen', type: PropType.text.value),
      ],
    ),
  ];
}

class PropTemplateField {
  final String key;
  final String type;
  final String defaultValue;

  const PropTemplateField({
    required this.key,
    required this.type,
    this.defaultValue = '',
  });

  Map<String, dynamic> toJson() =>
      {'key': key, 'type': type, 'defaultValue': defaultValue};

  factory PropTemplateField.fromJson(Map<String, dynamic> j) => PropTemplateField(
    key: j['key'] as String,
    type: j['type'] as String,
    defaultValue: (j['defaultValue'] as String?) ?? '',
  );
}

// ─── API-Feld-Einstellungen ───────────────────────────────────────────────────

class ApiFieldSettings {
  // AniList: welche Felder als Entry-Properties gespeichert werden
  final bool aniDescription;
  final bool aniImage;
  final bool aniGenres;
  final bool aniScore;
  final bool aniFormat;
  final bool aniStatus;
  final bool aniEpisodes;
  final bool aniStudio;
  final bool aniYear;

  // BGG: welche Felder als Entry-Properties gespeichert werden
  final bool bggDescription;
  final bool bggImage;
  final bool bggCategories;
  final bool bggScore;
  final bool bggPlayers;
  final bool bggPlayTime;
  final bool bggYear;
  final bool bggDesigners;
  final bool bggPublishers;
  final bool bggMechanics;
  // VGG / RPGGeek (teilen BGG-Felder, aber mit eigenen Schaltern)
  final bool vggImage;
  final bool vggCategories;
  final bool vggPlatforms;
  final bool vggDescription;
  final bool rpggImage;
  final bool rpggCategories;
  final bool rpggMechanics;
  final bool rpggDescription;
  // GitHub
  final bool ghImage;
  final bool ghTopics;
  final bool ghStars;
  final bool ghLicense;
  final bool ghWebsite;
  final bool ghDescription;

  const ApiFieldSettings({
    this.aniDescription = true,
    this.aniImage = true,
    this.aniGenres = true,
    this.aniScore = true,
    this.aniFormat = true,
    this.aniStatus = false,
    this.aniEpisodes = true,
    this.aniStudio = true,
    this.aniYear = true,
    this.bggDescription = true,
    this.bggImage = true,
    this.bggCategories = true,
    this.bggScore = true,
    this.bggPlayers = true,
    this.bggPlayTime = false,
    this.bggYear = true,
    this.bggDesigners = false,
    this.bggPublishers = false,
    this.bggMechanics = false,
    this.vggImage = true,
    this.vggCategories = true,
    this.vggPlatforms = true,
    this.vggDescription = true,
    this.rpggImage = true,
    this.rpggCategories = true,
    this.rpggMechanics = true,
    this.rpggDescription = true,
    this.ghImage = true,
    this.ghTopics = true,
    this.ghStars = true,
    this.ghLicense = true,
    this.ghWebsite = true,
    this.ghDescription = true,
  });

  ApiFieldSettings copyWith({
    bool? aniDescription, bool? aniImage, bool? aniGenres, bool? aniScore,
    bool? aniFormat, bool? aniStatus, bool? aniEpisodes, bool? aniStudio,
    bool? aniYear,
    bool? bggDescription, bool? bggImage, bool? bggCategories, bool? bggScore,
    bool? bggPlayers, bool? bggPlayTime, bool? bggYear,
    bool? bggDesigners, bool? bggPublishers, bool? bggMechanics,
    bool? vggImage, bool? vggCategories, bool? vggPlatforms, bool? vggDescription,
    bool? rpggImage, bool? rpggCategories, bool? rpggMechanics, bool? rpggDescription,
    bool? ghImage, bool? ghTopics, bool? ghStars, bool? ghLicense,
    bool? ghWebsite, bool? ghDescription,
  }) => ApiFieldSettings(
    aniDescription: aniDescription ?? this.aniDescription,
    aniImage: aniImage ?? this.aniImage,
    aniGenres: aniGenres ?? this.aniGenres,
    aniScore: aniScore ?? this.aniScore,
    aniFormat: aniFormat ?? this.aniFormat,
    aniStatus: aniStatus ?? this.aniStatus,
    aniEpisodes: aniEpisodes ?? this.aniEpisodes,
    aniStudio: aniStudio ?? this.aniStudio,
    aniYear: aniYear ?? this.aniYear,
    bggDescription: bggDescription ?? this.bggDescription,
    bggImage: bggImage ?? this.bggImage,
    bggCategories: bggCategories ?? this.bggCategories,
    bggScore: bggScore ?? this.bggScore,
    bggPlayers: bggPlayers ?? this.bggPlayers,
    bggPlayTime: bggPlayTime ?? this.bggPlayTime,
    bggYear: bggYear ?? this.bggYear,
    bggDesigners: bggDesigners ?? this.bggDesigners,
    bggPublishers: bggPublishers ?? this.bggPublishers,
    bggMechanics: bggMechanics ?? this.bggMechanics,
    vggImage: vggImage ?? this.vggImage,
    vggCategories: vggCategories ?? this.vggCategories,
    vggPlatforms: vggPlatforms ?? this.vggPlatforms,
    vggDescription: vggDescription ?? this.vggDescription,
    rpggImage: rpggImage ?? this.rpggImage,
    rpggCategories: rpggCategories ?? this.rpggCategories,
    rpggMechanics: rpggMechanics ?? this.rpggMechanics,
    rpggDescription: rpggDescription ?? this.rpggDescription,
    ghImage: ghImage ?? this.ghImage,
    ghTopics: ghTopics ?? this.ghTopics,
    ghStars: ghStars ?? this.ghStars,
    ghLicense: ghLicense ?? this.ghLicense,
    ghWebsite: ghWebsite ?? this.ghWebsite,
    ghDescription: ghDescription ?? this.ghDescription,
  );

  Map<String, dynamic> toJson() => {
    'aniDescription': aniDescription, 'aniImage': aniImage,
    'aniGenres': aniGenres, 'aniScore': aniScore, 'aniFormat': aniFormat,
    'aniStatus': aniStatus, 'aniEpisodes': aniEpisodes,
    'aniStudio': aniStudio, 'aniYear': aniYear,
    'bggDescription': bggDescription, 'bggImage': bggImage,
    'bggCategories': bggCategories, 'bggScore': bggScore,
    'bggPlayers': bggPlayers, 'bggPlayTime': bggPlayTime,
    'bggYear': bggYear, 'bggDesigners': bggDesigners,
    'bggPublishers': bggPublishers, 'bggMechanics': bggMechanics,
    'vggImage': vggImage, 'vggCategories': vggCategories,
    'vggPlatforms': vggPlatforms, 'vggDescription': vggDescription,
    'rpggImage': rpggImage, 'rpggCategories': rpggCategories,
    'rpggMechanics': rpggMechanics, 'rpggDescription': rpggDescription,
    'ghImage': ghImage, 'ghTopics': ghTopics, 'ghStars': ghStars,
    'ghLicense': ghLicense, 'ghWebsite': ghWebsite, 'ghDescription': ghDescription,
  };

  factory ApiFieldSettings.fromJson(Map<String, dynamic> j) => ApiFieldSettings(
    aniDescription: j['aniDescription'] as bool? ?? true,
    aniImage: j['aniImage'] as bool? ?? true,
    aniGenres: j['aniGenres'] as bool? ?? true,
    aniScore: j['aniScore'] as bool? ?? true,
    aniFormat: j['aniFormat'] as bool? ?? true,
    aniStatus: j['aniStatus'] as bool? ?? false,
    aniEpisodes: j['aniEpisodes'] as bool? ?? true,
    aniStudio: j['aniStudio'] as bool? ?? true,
    aniYear: j['aniYear'] as bool? ?? true,
    bggDescription: j['bggDescription'] as bool? ?? true,
    bggImage: j['bggImage'] as bool? ?? true,
    bggCategories: j['bggCategories'] as bool? ?? true,
    bggScore: j['bggScore'] as bool? ?? true,
    bggPlayers: j['bggPlayers'] as bool? ?? true,
    bggPlayTime: j['bggPlayTime'] as bool? ?? false,
    bggYear: j['bggYear'] as bool? ?? true,
    bggDesigners: j['bggDesigners'] as bool? ?? false,
    bggPublishers: j['bggPublishers'] as bool? ?? false,
    bggMechanics: j['bggMechanics'] as bool? ?? false,
    vggImage: j['vggImage'] as bool? ?? true,
    vggCategories: j['vggCategories'] as bool? ?? true,
    vggPlatforms: j['vggPlatforms'] as bool? ?? true,
    vggDescription: j['vggDescription'] as bool? ?? true,
    rpggImage: j['rpggImage'] as bool? ?? true,
    rpggCategories: j['rpggCategories'] as bool? ?? true,
    rpggMechanics: j['rpggMechanics'] as bool? ?? true,
    rpggDescription: j['rpggDescription'] as bool? ?? true,
    ghImage: j['ghImage'] as bool? ?? true,
    ghTopics: j['ghTopics'] as bool? ?? true,
    ghStars: j['ghStars'] as bool? ?? true,
    ghLicense: j['ghLicense'] as bool? ?? true,
    ghWebsite: j['ghWebsite'] as bool? ?? true,
    ghDescription: j['ghDescription'] as bool? ?? true,
  );
}

// ─── AppSettings Singleton ────────────────────────────────────────────────────

class AppSettings {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ── Tag-Stil ───────────────────────────────────────────────────────────────

  static TagStyle loadTagStyle() {
    final p = _prefs;
    if (p == null) return const TagStyle();
    return TagStyle(
      bgColor:      Color(p.getInt('tag_bg')     ?? const Color(0xFF042F2E).toARGB32()),
      textColor:    Color(p.getInt('tag_text')   ?? const Color(0xFF14B8A6).toARGB32()),
      borderColor:  Color(p.getInt('tag_border') ?? const Color(0xFF0F766E).toARGB32()),
      borderRadius: p.getDouble('tag_radius')    ?? 99,
      showHash:     p.getBool('tag_hash')        ?? true,
    );
  }

  static Future<void> saveTagStyle(TagStyle s) async {
    final p = _prefs!;
    await p.setInt('tag_bg',       s.bgColor.toARGB32());
    await p.setInt('tag_text',     s.textColor.toARGB32());
    await p.setInt('tag_border',   s.borderColor.toARGB32());
    await p.setDouble('tag_radius', s.borderRadius);
    await p.setBool('tag_hash',    s.showHash);
  }

  // ── Vault-Pfad ────────────────────────────────────────────────────────────

  static String? getVaultPath() => _prefs?.getString('vault_path');

  static Future<void> saveVaultPath(String? path) async {
    if (path == null) {
      await _prefs?.remove('vault_path');
    } else {
      await _prefs?.setString('vault_path', path);
      await addRecentVault(path);
    }
  }

  // ── Zuletzt geöffnete Vaults ──────────────────────────────────────────────

  static List<String> getRecentVaults() =>
      _prefs?.getStringList('recent_vaults') ?? [];

  static Future<void> addRecentVault(String path) async {
    final list = getRecentVaults();
    list.remove(path); // Duplikat entfernen
    list.insert(0, path); // Neuesten vorne
    final trimmed = list.take(8).toList(); // Max. 8 einträge
    await _prefs?.setStringList('recent_vaults', trimmed);
  }

  static Future<void> removeRecentVault(String path) async {
    final list = getRecentVaults()..remove(path);
    await _prefs?.setStringList('recent_vaults', list);
  }

  // ── API-Feld-Einstellungen ─────────────────────────────────────────────────

  static ApiFieldSettings loadApiFieldSettings() {
    final raw = _prefs?.getString('api_field_settings');
    if (raw == null) return const ApiFieldSettings();
    try {
      return ApiFieldSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ApiFieldSettings();
    }
  }

  static Future<void> saveApiFieldSettings(ApiFieldSettings s) async {
    await _prefs?.setString('api_field_settings', jsonEncode(s.toJson()));
  }

  // ── API-Feld-Präferenzen (katalog-getrieben) ────────────────────────────────

  /// Lädt die katalog-getriebenen Feld-Präferenzen. Reihenfolge der Quellen:
  /// 1) neues `api_field_prefs`-JSON, 2) Migration aus dem alten
  /// `api_field_settings` (Bool-Modell), 3) Katalog-Defaults.
  static ApiFieldPrefs loadApiFieldPrefs() {
    final raw = _prefs?.getString('api_field_prefs');
    if (raw != null) {
      try {
        return ApiFieldPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {/* fällt unten auf Migration/Defaults zurück */}
    }
    final legacy = _prefs?.getString('api_field_settings');
    if (legacy != null) {
      try {
        return ApiFieldPrefs.fromLegacy(
            jsonDecode(legacy) as Map<String, dynamic>);
      } catch (_) {/* Defaults */}
    }
    return ApiFieldPrefs.defaults();
  }

  static Future<void> saveApiFieldPrefs(ApiFieldPrefs prefs) async {
    await _prefs?.setString('api_field_prefs', jsonEncode(prefs.toJson()));
  }

  // ── Templates ─────────────────────────────────────────────────────────────

  static List<PropTemplate> loadTemplates() {
    final raw = _prefs?.getStringList('prop_templates');
    if (raw == null) return PropTemplate.defaults;
    try {
      return raw
          .map((s) => PropTemplate.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return PropTemplate.defaults;
    }
  }

  static Future<void> saveTemplates(List<PropTemplate> templates) async {
    await _prefs!.setStringList(
      'prop_templates',
      templates.map((t) => jsonEncode(t.toJson())).toList(),
    );
  }

  // ── KI-Struktur-Vorlagen (#38) ──────────────────────────────────────────────

  /// Editierbare Typ-Gerüste der „strukturierten Notiz". Fallback = Defaults
  /// (= bisheriges, fest verdrahtetes Verhalten).
  static List<StructureTemplate> loadStructureTemplates() {
    final raw = _prefs?.getStringList('ai_structure_templates');
    if (raw == null || raw.isEmpty) return StructureTemplate.defaults;
    try {
      return raw
          .map((s) =>
              StructureTemplate.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return StructureTemplate.defaults;
    }
  }

  static Future<void> saveStructureTemplates(
      List<StructureTemplate> templates) async {
    await _prefs!.setStringList(
      'ai_structure_templates',
      templates.map((t) => jsonEncode(t.toJson())).toList(),
    );
  }

  /// Auf Auslieferungs-Defaults zurücksetzen (entfernt die Speicherung).
  static Future<void> resetStructureTemplates() async {
    await _prefs?.remove('ai_structure_templates');
  }

  /// Editierbare Struktur der „recherchierten Notiz". Fallback = Default.
  static String getResearchStructure() {
    final v = _prefs?.getString('ai_research_structure');
    return (v == null || v.trim().isEmpty)
        ? StructureTemplate.defaultResearchStructure
        : v;
  }

  static Future<void> saveResearchStructure(String text) async {
    if (text.trim().isEmpty) {
      await _prefs?.remove('ai_research_structure');
    } else {
      await _prefs?.setString('ai_research_structure', text);
    }
  }

  static Future<void> resetResearchStructure() async {
    await _prefs?.remove('ai_research_structure');
  }

  // ── Web-Recherche: aktiver Provider (SearXNG/Brave …) (#32) ────────────────

  /// Aktiver Recherche-Provider als stabile ID (Default: SearXNG für
  /// Bestandsnutzer). Siehe WebSearchProviderKind.id.
  static String getWebSearchProvider() =>
      _prefs?.getString('web_search_provider') ?? 'searxng';

  static Future<void> saveWebSearchProvider(String id) async {
    await _prefs?.setString('web_search_provider', id);
  }

  // ── Settings-Export für Backup ─────────────────────────────────────────────

  static Map<String, dynamic> exportSettings() {
    final p = _prefs;
    if (p == null) return {};
    final result = <String, dynamic>{};
    for (final key in [
      'tag_bg', 'tag_text', 'tag_border',
      'api_field_settings', 'api_field_prefs',
    ]) {
      final v = p.get(key);
      if (v != null) result[key] = v;
    }
    final radius = p.getDouble('tag_radius');
    if (radius != null) result['tag_radius'] = radius;
    final hash = p.getBool('tag_hash');
    if (hash != null) result['tag_hash'] = hash;
    final templates = p.getStringList('prop_templates');
    if (templates != null) result['prop_templates'] = templates;
    final structTemplates = p.getStringList('ai_structure_templates');
    if (structTemplates != null) result['ai_structure_templates'] = structTemplates;
    final researchStructure = p.getString('ai_research_structure');
    if (researchStructure != null) result['ai_research_structure'] = researchStructure;
    final vault = p.getString('vault_path');
    if (vault != null) result['vault_path'] = vault;
    return result;
  }

  static Future<void> importSettings(Map<String, dynamic> settings) async {
    final p = _prefs;
    if (p == null) return;
    for (final entry in settings.entries) {
      final k = entry.key;
      final v = entry.value;
      if (v is int) await p.setInt(k, v);
      else if (v is double) await p.setDouble(k, v);
      else if (v is bool) await p.setBool(k, v);
      else if (v is String) await p.setString(k, v);
      else if (v is List) await p.setStringList(k, v.cast<String>());
    }
  }

  // ── Sync-Einstellungen ────────────────────────────────────────────────────

  static String getDeviceId() {
    final id = _prefs?.getString('sync_device_id');
    if (id != null && id.isNotEmpty) return id;
    final newId = 'dev-${_randomHex(8)}';
    _prefs?.setString('sync_device_id', newId);
    return newId;
  }

  static String getDeviceName() {
    final saved = _prefs?.getString('sync_device_name');
    if (saved != null && saved.isNotEmpty) return saved;
    // Hostname als Fallback (z.B. "Dennis-MacBook" oder "iPhone von Dennis")
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'MindFeed';
    }
  }

  static Future<void> saveDeviceName(String name) async =>
      _prefs?.setString('sync_device_name', name);

  static SyncRole getSyncRole() {
    final raw = _prefs?.getString('sync_role') ?? 'client';
    return raw == 'server' ? SyncRole.server : SyncRole.client;
  }

  static Future<void> saveSyncRole(SyncRole role) async =>
      _prefs?.setString('sync_role', role == SyncRole.server ? 'server' : 'client');

  static bool getSyncEnabled() => _prefs?.getBool('sync_enabled') ?? false;

  static Future<void> saveSyncEnabled(bool v) async =>
      _prefs?.setBool('sync_enabled', v);

  /// Gespeicherte Feed-Filter (JSON-Liste in SharedPreferences).
  static List<SavedFilter> loadSavedFilters() {
    final raw = _prefs?.getStringList('saved_filters');
    if (raw == null) return [];
    try {
      return raw.map(SavedFilter.decode).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveSavedFilters(List<SavedFilter> filters) async {
    await _prefs?.setStringList(
        'saved_filters', filters.map((f) => f.encode()).toList());
  }

  /// Kachelgröße der Thumbnail-Ansicht (max. Spaltenbreite in px).
  static double getGridTileSize() =>
      _prefs?.getDouble('grid_tile_size') ?? 170;

  static Future<void> saveGridTileSize(double v) async =>
      _prefs?.setDouble('grid_tile_size', v);

  /// Aufgaben-Sektion in Notiz-Details anzeigen (verlinkte Tasks). Default: an.
  static bool getShowTasksInNotes() =>
      _prefs?.getBool('show_tasks_in_notes') ?? true;

  static Future<void> saveShowTasksInNotes(bool v) async =>
      _prefs?.setBool('show_tasks_in_notes', v);

  static String? getSyncServerUrl() => _prefs?.getString('sync_server_url');

  static Future<void> saveSyncServerUrl(String? url) async {
    if (url == null) {
      _prefs?.remove('sync_server_url');
    } else {
      _prefs?.setString('sync_server_url', url);
    }
  }

  static bool getSyncAutoEnabled() => _prefs?.getBool('sync_auto_enabled') ?? true;

  static Future<void> saveSyncAutoEnabled(bool v) async =>
      _prefs?.setBool('sync_auto_enabled', v);

  static int getSyncAutoIntervalMinutes() =>
      _prefs?.getInt('sync_auto_interval_minutes') ?? 5;

  static Future<void> saveSyncAutoIntervalMinutes(int v) async =>
      _prefs?.setInt('sync_auto_interval_minutes', v);

  static bool getSyncOnAppStart() => _prefs?.getBool('sync_on_app_start') ?? false;

  static Future<void> saveSyncOnAppStart(bool v) async =>
      _prefs?.setBool('sync_on_app_start', v);

  static bool getSyncOnResume() => _prefs?.getBool('sync_on_resume') ?? false;

  static Future<void> saveSyncOnResume(bool v) async =>
      _prefs?.setBool('sync_on_resume', v);

  static bool getSyncAttachments() => _prefs?.getBool('sync_attachments') ?? true;

  static Future<void> saveSyncAttachments(bool v) async =>
      _prefs?.setBool('sync_attachments', v);

  static SyncAttachmentsDirection getSyncAttachmentsDirection() {
    final raw = _prefs?.getString('sync_attachments_direction') ?? 'both';
    return SyncAttachmentsDirection.values.firstWhere(
      (d) => d.name == raw,
      orElse: () => SyncAttachmentsDirection.both,
    );
  }

  static Future<void> saveSyncAttachmentsDirection(SyncAttachmentsDirection d) async =>
      _prefs?.setString('sync_attachments_direction', d.name);

  static DateTime? getLastSyncAt() {
    final raw = _prefs?.getString('sync_last_sync_at');
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> saveLastSyncAt(DateTime dt) async =>
      _prefs?.setString('sync_last_sync_at', dt.toIso8601String());

  // ── Papierkorb ──────────────────────────────────────────────────────────────

  /// Aufbewahrungsdauer in Tagen; 0 = nie automatisch löschen.
  static int getTrashRetentionDays() =>
      _prefs?.getInt('trash_retention_days') ?? 30;

  static Future<void> saveTrashRetentionDays(int days) async =>
      _prefs?.setInt('trash_retention_days', days);

  // ── Automatisches Backup ──────────────────────────────────────────────────

  static bool getAutoBackupEnabled() =>
      _prefs?.getBool('auto_backup_enabled') ?? false;
  static Future<void> saveAutoBackupEnabled(bool v) async =>
      _prefs?.setBool('auto_backup_enabled', v);

  /// Zielordner für automatische Backups (null = Vault/backups).
  static String? getAutoBackupDir() => _prefs?.getString('auto_backup_dir');
  static Future<void> saveAutoBackupDir(String? dir) async {
    if (dir == null || dir.isEmpty) {
      await _prefs?.remove('auto_backup_dir');
    } else {
      await _prefs?.setString('auto_backup_dir', dir);
    }
  }

  /// Backup-Intervall in Stunden (z.B. 24 = täglich, 168 = wöchentlich).
  static int getAutoBackupIntervalHours() =>
      _prefs?.getInt('auto_backup_interval_hours') ?? 24;
  static Future<void> saveAutoBackupIntervalHours(int hours) async =>
      _prefs?.setInt('auto_backup_interval_hours', hours);

  static DateTime? getLastAutoBackupAt() {
    final raw = _prefs?.getString('auto_backup_last_at');
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<void> saveLastAutoBackupAt(DateTime dt) async =>
      _prefs?.setString('auto_backup_last_at', dt.toIso8601String());

  /// Wie viele Auto-Backups im Zielordner behalten werden (älteste löschen).
  static int getAutoBackupKeep() => _prefs?.getInt('auto_backup_keep') ?? 10;
  static Future<void> saveAutoBackupKeep(int n) async =>
      _prefs?.setInt('auto_backup_keep', n);

  static String _randomHex(int bytes) {
    final rng = Random.secure();
    final buf = List<int>.generate(bytes, (_) => rng.nextInt(256));
    return buf.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
