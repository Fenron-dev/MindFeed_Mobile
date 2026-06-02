import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/prop_type.dart';

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

  const PropTemplate({
    required this.id,
    required this.name,
    this.emoji = '📋',
    required this.fields,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'emoji': emoji,
    'fields': fields.map((f) => f.toJson()).toList(),
  };

  factory PropTemplate.fromJson(Map<String, dynamic> j) => PropTemplate(
    id: j['id'] as String,
    name: j['name'] as String,
    emoji: (j['emoji'] as String?) ?? '📋',
    fields: ((j['fields'] as List?) ?? [])
        .map((f) => PropTemplateField.fromJson(f as Map<String, dynamic>))
        .toList(),
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
        PropTemplateField(key: 'Hochgeladen', type: PropType.date.value),
        PropTemplateField(key: 'Geschaut', type: PropType.boolean.value, defaultValue: 'false'),
        PropTemplateField(key: 'Bewertung', type: PropType.rating.value),
        PropTemplateField(key: 'Notizen', type: PropType.text.value),
      ],
    ),
    PropTemplate(
      id: 'tpl-ttrpg', name: 'TTRPG', emoji: '🐉',
      fields: [
        PropTemplateField(key: 'System', type: PropType.text.value),
        PropTemplateField(key: 'Verlag', type: PropType.text.value),
        PropTemplateField(key: 'Genre', type: PropType.tags.value),
        PropTemplateField(key: 'Bewertung', type: PropType.rating.value),
        PropTemplateField(key: 'Besitzen', type: PropType.boolean.value, defaultValue: 'false'),
        PropTemplateField(key: 'Quelle', type: PropType.url.value),
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
}
