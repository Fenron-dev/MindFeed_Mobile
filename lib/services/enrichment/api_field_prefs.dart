import 'api_field_catalog.dart';
import 'api_source.dart';

/// Welche Felder pro [ApiSource] standardmäßig importiert werden.
///
/// Ersetzt die frühere `ApiFieldSettings`-Bool-Explosion durch eine generische
/// Map `Quelle → Set<Feld-Key>`. Neue Quellen/Felder erfordern keine Änderung
/// an diesem Modell — nur am [ApiFieldCatalog].
class ApiFieldPrefs {
  final Map<ApiSource, Set<String>> enabled;

  const ApiFieldPrefs(this.enabled);

  /// Default-Auswahl aller im Katalog beschriebenen Quellen.
  factory ApiFieldPrefs.defaults() {
    final map = <ApiSource, Set<String>>{};
    for (final source in ApiFieldCatalog.describedSources) {
      map[source] = ApiFieldCatalog.defaultEnabledKeys(source);
    }
    return ApiFieldPrefs(map);
  }

  /// Ob ein Feld importiert werden soll. Quellen ohne gespeicherten Eintrag
  /// fallen auf die Katalog-Defaults zurück (z.B. neu hinzugekommene Quellen).
  bool isEnabled(ApiSource source, String fieldKey) {
    final set = enabled[source];
    if (set == null) {
      return ApiFieldCatalog.findField(source, fieldKey)?.defaultEnabled ?? false;
    }
    return set.contains(fieldKey);
  }

  ApiFieldPrefs withField(ApiSource source, String fieldKey, bool value) {
    final next = {
      for (final e in enabled.entries) e.key: {...e.value},
    };
    final set = next.putIfAbsent(
        source, () => {...ApiFieldCatalog.defaultEnabledKeys(source)});
    if (value) {
      set.add(fieldKey);
    } else {
      set.remove(fieldKey);
    }
    return ApiFieldPrefs(next);
  }

  Map<String, dynamic> toJson() => {
        for (final e in enabled.entries) e.key.id: e.value.toList(),
      };

  factory ApiFieldPrefs.fromJson(Map<String, dynamic> j) {
    final map = <ApiSource, Set<String>>{};
    j.forEach((sourceId, value) {
      final source = ApiSource.fromId(sourceId);
      if (source != null && value is List) {
        map[source] = value.map((e) => '$e').toSet();
      }
    });
    return ApiFieldPrefs(map);
  }

  /// Migriert die alte `ApiFieldSettings`-Bool-Map auf das neue Modell.
  /// Unbekannte Keys werden ignoriert; fehlende Quellen erhalten Katalog-
  /// Defaults beim Zugriff.
  factory ApiFieldPrefs.fromLegacy(Map<String, dynamic> legacy) {
    // Legacy-Bool-Key → (Quelle, Feld-Keys). `aniEpisodes` steuerte sowohl
    // Folgen als auch Kapitel.
    const mapping = <String, (ApiSource, List<String>)>{
      'aniDescription': (ApiSource.anilist, ['description']),
      'aniImage': (ApiSource.anilist, ['image']),
      'aniGenres': (ApiSource.anilist, ['genres']),
      'aniScore': (ApiSource.anilist, ['score']),
      'aniFormat': (ApiSource.anilist, ['format']),
      'aniStatus': (ApiSource.anilist, ['status']),
      'aniEpisodes': (ApiSource.anilist, ['episodes', 'chapters']),
      'aniStudio': (ApiSource.anilist, ['studio']),
      'aniYear': (ApiSource.anilist, ['year']),
      'bggDescription': (ApiSource.bgg, ['description']),
      'bggImage': (ApiSource.bgg, ['image']),
      'bggCategories': (ApiSource.bgg, ['categories']),
      'bggScore': (ApiSource.bgg, ['score']),
      'bggPlayers': (ApiSource.bgg, ['players']),
      'bggPlayTime': (ApiSource.bgg, ['playtime']),
      'bggYear': (ApiSource.bgg, ['year']),
      'bggDesigners': (ApiSource.bgg, ['designers']),
      'bggPublishers': (ApiSource.bgg, ['publishers']),
      'bggMechanics': (ApiSource.bgg, ['mechanics']),
      'vggImage': (ApiSource.vgg, ['image']),
      'vggCategories': (ApiSource.vgg, ['categories']),
      'vggPlatforms': (ApiSource.vgg, ['platforms']),
      'vggDescription': (ApiSource.vgg, ['description']),
      'rpggImage': (ApiSource.rpgg, ['image']),
      'rpggCategories': (ApiSource.rpgg, ['categories']),
      'rpggMechanics': (ApiSource.rpgg, ['mechanics']),
      'rpggDescription': (ApiSource.rpgg, ['description']),
      'ghImage': (ApiSource.github, ['image']),
      'ghTopics': (ApiSource.github, ['topics']),
      'ghStars': (ApiSource.github, ['stars']),
      'ghLicense': (ApiSource.github, ['license']),
      'ghWebsite': (ApiSource.github, ['website']),
      'ghDescription': (ApiSource.github, ['description']),
    };

    // Mit Defaults starten, damit nicht-migrierte Felder (z.B. github default_branch)
    // ihren Katalog-Default behalten.
    final map = <ApiSource, Set<String>>{
      for (final s in ApiFieldCatalog.describedSources)
        s: {...ApiFieldCatalog.defaultEnabledKeys(s)},
    };

    mapping.forEach((legacyKey, target) {
      if (!legacy.containsKey(legacyKey)) return;
      final on = legacy[legacyKey] == true;
      final set = map.putIfAbsent(target.$1, () => <String>{});
      for (final fieldKey in target.$2) {
        if (on) {
          set.add(fieldKey);
        } else {
          set.remove(fieldKey);
        }
      }
    });

    return ApiFieldPrefs(map);
  }
}
