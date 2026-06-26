import '../../domain/prop_type.dart';
import 'api_field_def.dart';
import 'api_source.dart';

/// Zentrale Quelle der Wahrheit: welche Felder jede [ApiSource] liefern kann.
///
/// `propKey` spiegelt die bisher in `entry_repository.createEntry` verwendeten
/// kanonischen Property-Keys, damit bestehende Feed-Karten/Detail-Ansichten
/// unverändert weiterfunktionieren. Neue Quellen/Felder werden hier ergänzt —
/// Einstellungen-UI, Abhol-Vorschau und Import leiten sich automatisch ab.
class ApiFieldCatalog {
  const ApiFieldCatalog._();

  static const Map<ApiSource, List<ApiFieldDef>> _fields = {
    ApiSource.anilist: [
      ApiFieldDef(key: 'description', label: 'Beschreibung', propKey: 'og_description'),
      ApiFieldDef(key: 'image', label: 'Cover', type: PropType.url, propKey: 'og_image'),
      ApiFieldDef(key: 'genres', label: 'Genres', type: PropType.tags, propKey: 'genres'),
      ApiFieldDef(key: 'score', label: 'Bewertung', type: PropType.rating, propKey: 'score'),
      ApiFieldDef(key: 'format', label: 'Format', propKey: 'anilist_format'),
      ApiFieldDef(key: 'status', label: 'Status', type: PropType.select, propKey: 'anilist_status', defaultEnabled: false),
      ApiFieldDef(key: 'episodes', label: 'Folgen gesamt', type: PropType.number, propKey: 'anilist_episodes'),
      ApiFieldDef(key: 'chapters', label: 'Kapitel', type: PropType.number, propKey: 'anilist_chapters'),
      ApiFieldDef(key: 'studio', label: 'Studio', propKey: 'anilist_studio'),
      ApiFieldDef(key: 'year', label: 'Jahr', propKey: 'anilist_year'),
    ],
    ApiSource.bgg: [
      ApiFieldDef(key: 'description', label: 'Beschreibung', propKey: 'og_description'),
      ApiFieldDef(key: 'image', label: 'Cover', type: PropType.url, propKey: 'og_image'),
      ApiFieldDef(key: 'categories', label: 'Kategorien', type: PropType.tags, propKey: 'genres'),
      ApiFieldDef(key: 'score', label: 'Bewertung', type: PropType.rating, propKey: 'score'),
      ApiFieldDef(key: 'players', label: 'Spieleranzahl', propKey: 'Spieler'),
      ApiFieldDef(key: 'playtime', label: 'Spielzeit', propKey: 'Spielzeit', defaultEnabled: false),
      ApiFieldDef(key: 'year', label: 'Jahr', propKey: 'Jahr'),
      ApiFieldDef(key: 'designers', label: 'Designer', propKey: 'Designer', defaultEnabled: false),
      ApiFieldDef(key: 'publishers', label: 'Verlag', propKey: 'Verlag', defaultEnabled: false),
      ApiFieldDef(key: 'mechanics', label: 'Mechaniken', type: PropType.tags, propKey: 'Mechaniken', defaultEnabled: false),
    ],
    ApiSource.vgg: [
      ApiFieldDef(key: 'description', label: 'Beschreibung', propKey: 'og_description'),
      ApiFieldDef(key: 'image', label: 'Cover', type: PropType.url, propKey: 'og_image'),
      ApiFieldDef(key: 'categories', label: 'Kategorien', type: PropType.tags, propKey: 'genres'),
      ApiFieldDef(key: 'platforms', label: 'Plattformen', propKey: 'Plattform'),
    ],
    ApiSource.rpgg: [
      ApiFieldDef(key: 'description', label: 'Beschreibung', propKey: 'og_description'),
      ApiFieldDef(key: 'image', label: 'Cover', type: PropType.url, propKey: 'og_image'),
      ApiFieldDef(key: 'categories', label: 'Kategorien', type: PropType.tags, propKey: 'genres'),
      ApiFieldDef(key: 'mechanics', label: 'Mechaniken', type: PropType.tags, propKey: 'Mechaniken'),
    ],
    ApiSource.github: [
      ApiFieldDef(key: 'description', label: 'Beschreibung', propKey: 'og_description'),
      ApiFieldDef(key: 'image', label: 'Vorschaubild', type: PropType.url, propKey: 'og_image'),
      ApiFieldDef(key: 'language', label: 'Sprache', propKey: 'github_language'),
      ApiFieldDef(key: 'stars', label: 'Stars', type: PropType.number, propKey: 'github_stars'),
      ApiFieldDef(key: 'forks', label: 'Forks', type: PropType.number, propKey: 'github_forks', defaultEnabled: false),
      ApiFieldDef(key: 'topics', label: 'Themen', type: PropType.tags, propKey: 'genres'),
      ApiFieldDef(key: 'license', label: 'Lizenz', propKey: 'github_license'),
      ApiFieldDef(key: 'website', label: 'Webseite', type: PropType.url, propKey: 'github_website'),
      ApiFieldDef(key: 'default_branch', label: 'Default-Branch', propKey: 'github_default_branch', defaultEnabled: false),
    ],
    ApiSource.youtube: [
      ApiFieldDef(key: 'channel', label: 'Kanal', propKey: 'youtube_channel'),
      ApiFieldDef(key: 'image', label: 'Thumbnail', type: PropType.url, propKey: 'og_image'),
      ApiFieldDef(key: 'description', label: 'Beschreibung', propKey: 'og_description'),
      ApiFieldDef(key: 'duration', label: 'Laufzeit', propKey: 'youtube_laufzeit'),
      ApiFieldDef(key: 'published', label: 'Hochgeladen', propKey: 'youtube_hochgeladen'),
      ApiFieldDef(key: 'views', label: 'Aufrufe', type: PropType.number, propKey: 'youtube_views'),
      ApiFieldDef(key: 'likes', label: 'Likes', type: PropType.number, propKey: 'youtube_likes', defaultEnabled: false),
      ApiFieldDef(key: 'tags', label: 'Tags', type: PropType.tags, propKey: 'youtube_tags', defaultEnabled: false),
    ],
    ApiSource.amazon: [
      ApiFieldDef(key: 'description', label: 'Beschreibung', propKey: 'og_description'),
      ApiFieldDef(key: 'image', label: 'Bild', type: PropType.url, propKey: 'og_image'),
      ApiFieldDef(key: 'price', label: 'Preis', propKey: 'Preis'),
    ],
    ApiSource.genericWeb: [
      ApiFieldDef(key: 'description', label: 'Beschreibung', propKey: 'og_description'),
      ApiFieldDef(key: 'image', label: 'Vorschaubild', type: PropType.url, propKey: 'og_image'),
    ],
  };

  /// Felder einer Quelle (leere Liste, wenn noch nicht im Katalog beschrieben).
  static List<ApiFieldDef> fieldsFor(ApiSource source) => _fields[source] ?? const [];

  /// Default-aktivierte Feld-Keys einer Quelle (Basis für die Erstauswahl).
  static Set<String> defaultEnabledKeys(ApiSource source) =>
      fieldsFor(source).where((f) => f.defaultEnabled).map((f) => f.key).toSet();

  /// Findet die Felddefinition per Quelle + Key.
  static ApiFieldDef? findField(ApiSource source, String key) {
    for (final f in fieldsFor(source)) {
      if (f.key == key) return f;
    }
    return null;
  }

  /// Alle Quellen, die bereits Feld-Definitionen besitzen.
  static List<ApiSource> get describedSources =>
      _fields.keys.toList(growable: false);
}
