import '../url_metadata_service.dart';
import 'api_field_catalog.dart';
import 'api_source.dart';

/// Ergebnis eines API-Abrufs in generischer, katalog-orientierter Form.
///
/// [fields] ist nach den Feld-Keys der jeweiligen [ApiSource] aus dem
/// [ApiFieldCatalog] benannt. Bilder/Cover sind gewöhnliche Felder (Typ url).
/// Der volle [fields]-Satz wird der KI als Kontext gegeben — unabhängig davon,
/// welche Felder der Nutzer importiert.
class MetadataRecord {
  final ApiSource source;
  final String url;
  final String title;
  final Map<String, dynamic> fields;

  /// Weitere Quellen, die denselben Eintrag liefern könnten (z.B. Film:
  /// [tmdbMovie, omdb]) — für den Quellen-Umschalter in der Vorschau.
  final List<ApiSource> alternativeSources;

  const MetadataRecord({
    required this.source,
    required this.url,
    required this.title,
    required this.fields,
    this.alternativeSources = const [],
  });

  /// Nicht-leere Felder, die im Katalog der Quelle beschrieben sind, in
  /// Katalog-Reihenfolge — Basis für die Abhol-Vorschau.
  List<MapEntry<String, dynamic>> describedFields() {
    final out = <MapEntry<String, dynamic>>[];
    for (final def in ApiFieldCatalog.fieldsFor(source)) {
      final v = fields[def.key];
      if (v != null && '$v'.isNotEmpty) out.add(MapEntry(def.key, v));
    }
    return out;
  }

  /// Formatiert den **vollen** Feld-Satz als Kontextblock für die KI —
  /// unabhängig davon, welche Felder der Nutzer importiert. So kann die KI auch
  /// nicht-importierte Felder in generierte Texte einweben.
  String aiContext() {
    final lines = <String>[];
    for (final e in describedFields()) {
      final def = ApiFieldCatalog.findField(source, e.key);
      final label = def?.label ?? e.key;
      final v = e.value is List ? (e.value as List).join(', ') : '${e.value}';
      lines.add('$label: $v');
    }
    if (lines.isEmpty) return '';
    return 'Verfügbare Quelldaten (${source.label}):\n${lines.join('\n')}';
  }

  /// Brücke aus dem bestehenden [UrlMetadata]. Die Quelle wird per Domain
  /// bestimmt; die typisierten UrlMetadata-Felder werden auf die Katalog-Keys
  /// der erkannten Quelle abgebildet. So liefern die heutigen Extraktoren ohne
  /// Umbau bereits einen Record.
  factory MetadataRecord.fromUrlMetadata(UrlMetadata m, {String? url}) {
    var source = ApiSource.fromDomain(m.domain);
    // Quellen ohne (bisher) beschriebene Felder (z.B. TMDB/OMDb/Amazon vor
    // ihrer Phase) als generischen Web-Treffer behandeln, damit Beschreibung/
    // Bild trotzdem reviewbar bleiben.
    if (ApiFieldCatalog.fieldsFor(source).isEmpty) {
      source = ApiSource.genericWeb;
    }
    final f = <String, dynamic>{};

    void put(String key, dynamic value) {
      if (value == null) return;
      if (value is String && value.isEmpty) return;
      if (value is List && value.isEmpty) return;
      f[key] = value;
    }

    // Gemeinsame Basisfelder
    put('description', m.description);
    put('image', m.image);
    put('genres', m.genres);
    put('score', m.score);
    if (source == ApiSource.bgg ||
        source == ApiSource.vgg ||
        source == ApiSource.rpgg) {
      put('categories', m.genres);
    }
    if (source == ApiSource.github) {
      put('topics', m.genres);
    }

    // AniList-spezifisch
    put('format', m.anilistFormat);
    put('status', m.anilistStatus);
    put('episodes', m.anilistEpisodes);
    put('chapters', m.anilistChapters);
    put('studio', m.anilistStudio);
    put('year', m.anilistYear);

    // YouTube
    put('channel', m.authorName);

    // GitHub
    put('language', m.githubLanguage);
    put('stars', m.githubStars);
    put('forks', m.githubForks);
    put('license', m.githubLicense);
    put('website', m.githubWebsite);
    put('default_branch', m.githubDefaultBranch);

    // BGG/VGG/RPGG-Zusatzfelder kommen als extraProps (Property-Key → Wert).
    // Auf Katalog-Keys zurückmappen, wo möglich.
    m.extraProps.forEach((propKey, value) {
      for (final def in ApiFieldCatalog.fieldsFor(source)) {
        if (def.propKey == propKey) {
          put(def.key, value);
          break;
        }
      }
    });

    return MetadataRecord(
      source: source,
      url: url ?? '',
      title: m.title,
      fields: f,
    );
  }
}
