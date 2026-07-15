import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/domain/prop_type.dart';
import 'package:mindfeed_mobile/domain/property_registry.dart';
import 'package:mindfeed_mobile/widgets/prop_value_view.dart';

void main() {
  group('PropertyRegistry.isHidden', () {
    test('interne Keys sind versteckt', () {
      for (final k in [
        '_template', 'parent_entry_id', '_transcript', 'kind', 'media_type',
        'domain', 'url_author', 'score', 'genres', 'cover', 'cover_image',
        'bild',
      ]) {
        expect(PropertyRegistry.isHidden(k), isTrue, reason: k);
      }
    });

    test('quell-spezifische Präfixe sind versteckt (inkl. og_)', () {
      for (final k in [
        'og_image', 'og_title', 'og_description', 'bgg_rank', 'github_stars',
        'youtube_channel', 'anilist_studio', 'vgg_x', 'rpg_y', 'task_due',
      ]) {
        expect(PropertyRegistry.isHidden(k), isTrue, reason: k);
      }
    });

    test('groß/klein-unabhängig', () {
      expect(PropertyRegistry.isHidden('Media_Type'), isTrue);
      expect(PropertyRegistry.isHidden('OG_Image'), isTrue);
    });

    test('normale Nutzer-Keys bleiben sichtbar', () {
      for (final k in ['Regie', 'Jahr', 'Laufzeit', 'Notiz', 'Preis']) {
        expect(PropertyRegistry.isHidden(k), isFalse, reason: k);
      }
    });
  });

  group('PropertyRegistry.defFor (aus Katalog abgeleitet)', () {
    test('Katalog-Feld liefert Label + Typ', () {
      final def = PropertyRegistry.defFor('Regie');
      expect(def, isNotNull);
      expect(def!.label, 'Regie');
      expect(def.type, PropType.text);
    });

    test('manueller interner Key überschreibt Typ', () {
      final def = PropertyRegistry.defFor('score');
      expect(def!.type, PropType.rating);
      expect(def.hidden, isTrue);
    });

    test('unbekannter Key → null', () {
      expect(PropertyRegistry.defFor('voellig_unbekannt'), isNull);
    });
  });

  group('PropValueFormat', () {
    test('asDate ISO → dd.mm.yyyy, sonst null', () {
      expect(PropValueFormat.asDate('2026-07-15'), '15.07.2026');
      expect(PropValueFormat.asDate('kein datum'), isNull);
    });

    test('urlHost strippt www.', () {
      expect(PropValueFormat.urlHost('https://www.github.com/x'), 'github.com');
    });

    test('asList trimmt und filtert leere', () {
      expect(PropValueFormat.asList('a, b ,, c'), ['a', 'b', 'c']);
    });

    test('rating clampt auf 0..5', () {
      expect(PropValueFormat.rating('9'), 5);
      expect(PropValueFormat.rating('x'), 0);
    });

    test('infer erkennt bool/number/date/text', () {
      expect(PropValueFormat.infer('true'), PropType.boolean);
      expect(PropValueFormat.infer('42'), PropType.number);
      expect(PropValueFormat.infer('2026-07-15'), PropType.date);
      expect(PropValueFormat.infer('hallo'), PropType.text);
    });
  });
}
