import 'package:flutter/material.dart';

import '../services/enrichment/api_field_catalog.dart';
import 'prop_type.dart';

/// Beschreibt einen *bekannten* Property-Key app-weit: Label, Werttyp, ob er
/// technisch/versteckt gerendert wird, optionale Gruppe/Auswahlwerte/Icon.
///
/// Speist sich automatisch aus dem [ApiFieldCatalog] (jedes `ApiFieldDef` →
/// registrierte Property) plus manuellen Einträgen für interne Keys
/// (`_template`, `parent_entry_id`, `kind`, …).
class PropertyDef {
  /// Kanonischer Property-Key (z. B. `og_image`, `Regie`, `genres`).
  final String key;

  /// Anzeige-Label.
  final String label;

  /// Werttyp (steuert Icon/Farbe/Default-Rendering).
  final PropType type;

  /// Ob der Key in Karten/Detail technisch ausgeblendet wird.
  final bool hidden;

  /// Optionale Gruppierung (aus dem Katalog, für UI-Sektionen).
  final String? group;

  /// Definierte Auswahlwerte für `select` (Defaults; nutzererweiterbar in P2).
  final List<String>? choices;

  /// Optionales Icon-Override (fällt sonst auf das PropType-Icon zurück).
  final IconData? icon;

  const PropertyDef({
    required this.key,
    required this.label,
    this.type = PropType.text,
    this.hidden = false,
    this.group,
    this.choices,
    this.icon,
  });

  IconData get effectiveIcon => icon ?? type.icon;
  Color get color => type.color;
}

/// Zentrale Quelle der Wahrheit für Property-Wissen. Ersetzt die früher an
/// mehreren Stellen duplizierten Hide-Listen (`properties_block.dart`,
/// `entry_card.dart`) und liefert Label/Typ/Icon aus einer Hand.
class PropertyRegistry {
  const PropertyRegistry._();

  /// Interne bzw. anderweitig gerenderte Keys, die nicht als Eigenschaft
  /// erscheinen (Union der bisherigen zwei Hide-Listen).
  static const _internalHidden = <String>{
    'domain', 'genres', 'media_type', 'kind', 'url_author', 'score',
    '_template', 'parent_entry_id', 'cover', 'cover_image', 'bild',
    '_transcript',
  };

  /// Präfixe, deren Keys quell-spezifisch woanders gerendert werden.
  static const _hiddenPrefixes = <String>[
    'og_', 'bgg_', 'github_', 'youtube_', 'anilist_', 'vgg_', 'rpg_', 'task_',
  ];

  /// Manuelle Einträge für Keys, die nicht aus dem API-Katalog stammen.
  static const _manual = <PropertyDef>[
    PropertyDef(key: '_template', label: 'Vorlage', hidden: true),
    PropertyDef(key: 'parent_entry_id', label: 'Übergeordnet', hidden: true),
    PropertyDef(key: '_transcript', label: 'Transkript', hidden: true),
    PropertyDef(
        key: 'kind', label: 'Typ', type: PropType.select, hidden: true),
    PropertyDef(
        key: 'media_type', label: 'Medientyp', type: PropType.select,
        hidden: true),
    PropertyDef(key: 'domain', label: 'Domain', hidden: true),
    PropertyDef(key: 'url_author', label: 'Autor', hidden: true),
    PropertyDef(
        key: 'genres', label: 'Genres', type: PropType.tags, hidden: true),
    PropertyDef(
        key: 'score', label: 'Bewertung', type: PropType.rating, hidden: true),
  ];

  static final Map<String, PropertyDef> _byKey = _build();

  static Map<String, PropertyDef> _build() {
    final map = <String, PropertyDef>{};
    // 1) Aus dem API-Katalog ableiten (mehrere Quellen können denselben
    //    storageKey liefern → erster gewinnt; Typen sind dort konsistent).
    for (final source in ApiFieldCatalog.describedSources) {
      for (final f in ApiFieldCatalog.fieldsFor(source)) {
        final key = f.storageKey;
        map.putIfAbsent(
          key.toLowerCase(),
          () => PropertyDef(
            key: key,
            label: f.label,
            type: f.type,
            hidden: _hiddenByRule(key),
            group: f.group,
          ),
        );
      }
    }
    // 2) Manuelle interne Keys überschreiben (autoritativ).
    for (final def in _manual) {
      map[def.key.toLowerCase()] = def;
    }
    return map;
  }

  static bool _hiddenByRule(String key) {
    final k = key.toLowerCase();
    if (_internalHidden.contains(k)) return true;
    return _hiddenPrefixes.any(k.startsWith);
  }

  /// Ob ein Property-Key technisch ausgeblendet wird (Karten & Detail).
  static bool isHidden(String key) {
    final def = _byKey[key.toLowerCase()];
    if (def != null) return def.hidden;
    return _hiddenByRule(key);
  }

  /// Bekannte Definition zu einem Key (oder `null`, wenn generisch/unbekannt).
  static PropertyDef? defFor(String key) => _byKey[key.toLowerCase()];

  /// Definierte Auswahlwerte eines `select`-Keys (leer, wenn keine bekannt).
  static List<String> choicesFor(String key) => defFor(key)?.choices ?? const [];

  /// Alle registrierten Definitionen (für künftige Settings-/Auswahl-UIs).
  static List<PropertyDef> get all => _byKey.values.toList(growable: false);
}
