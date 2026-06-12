import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/services/enrichment/api_field_catalog.dart';
import 'package:mindfeed_mobile/services/enrichment/api_field_prefs.dart';
import 'package:mindfeed_mobile/services/enrichment/api_source.dart';

/// Sichert das Fundament der katalog-getriebenen Anreicherung (Phase 0):
/// Defaults, JSON-Roundtrip und die Migration aus dem alten Bool-Modell
/// `ApiFieldSettings`.
void main() {
  group('ApiFieldPrefs.defaults', () {
    test('übernimmt die Katalog-Defaults pro Quelle', () {
      final prefs = ApiFieldPrefs.defaults();
      // AniList: status ist per Katalog default-aus, studio default-an.
      expect(prefs.isEnabled(ApiSource.anilist, 'studio'), isTrue);
      expect(prefs.isEnabled(ApiSource.anilist, 'status'), isFalse);
      expect(
        prefs.enabled[ApiSource.anilist],
        ApiFieldCatalog.defaultEnabledKeys(ApiSource.anilist),
      );
    });
  });

  group('JSON-Roundtrip', () {
    test('toJson/fromJson erhält die Auswahl', () {
      final prefs = ApiFieldPrefs.defaults()
          .withField(ApiSource.anilist, 'status', true)
          .withField(ApiSource.github, 'stars', false);
      final restored = ApiFieldPrefs.fromJson(prefs.toJson());
      expect(restored.isEnabled(ApiSource.anilist, 'status'), isTrue);
      expect(restored.isEnabled(ApiSource.github, 'stars'), isFalse);
      expect(restored.isEnabled(ApiSource.anilist, 'studio'), isTrue);
    });
  });

  group('Migration aus ApiFieldSettings (Legacy-Bools)', () {
    test('überträgt aktivierte und deaktivierte Felder korrekt', () {
      final legacy = <String, dynamic>{
        'aniStatus': true, // war default aus → jetzt an
        'aniStudio': false, // war default an → jetzt aus
        'aniEpisodes': true, // steuert episodes UND chapters
        'ghStars': false,
        'bggDescription': true,
      };
      final prefs = ApiFieldPrefs.fromLegacy(legacy);
      expect(prefs.isEnabled(ApiSource.anilist, 'status'), isTrue);
      expect(prefs.isEnabled(ApiSource.anilist, 'studio'), isFalse);
      expect(prefs.isEnabled(ApiSource.anilist, 'episodes'), isTrue);
      expect(prefs.isEnabled(ApiSource.anilist, 'chapters'), isTrue);
      expect(prefs.isEnabled(ApiSource.github, 'stars'), isFalse);
      expect(prefs.isEnabled(ApiSource.bgg, 'description'), isTrue);
    });

    test('nicht migrierte Felder behalten ihren Katalog-Default', () {
      // github default_branch hatte im alten Modell keinen Schalter.
      final prefs = ApiFieldPrefs.fromLegacy(const {});
      expect(
        prefs.isEnabled(ApiSource.github, 'default_branch'),
        ApiFieldCatalog.findField(ApiSource.github, 'default_branch')!
            .defaultEnabled,
      );
    });
  });

  group('Katalog-Integrität', () {
    test('jede propKey-Zuordnung ist eindeutig pro Quelle', () {
      for (final source in ApiFieldCatalog.describedSources) {
        final keys = ApiFieldCatalog.fieldsFor(source).map((f) => f.key);
        expect(keys.toSet().length, keys.length,
            reason: 'Doppelter Feld-Key in ${source.id}');
      }
    });
  });
}
