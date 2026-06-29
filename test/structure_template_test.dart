import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/services/ai/structure_template.dart';
import 'package:mindfeed_mobile/services/openrouter_service.dart';

void main() {
  group('StructureTemplate', () {
    test('JSON-Roundtrip', () {
      const t = StructureTemplate(
        id: 'st-x',
        name: 'REZEPT',
        hint: 'Koch-/Backvideo',
        skeleton: '## Überblick\n## Zutaten',
      );
      final back = StructureTemplate.fromJson(t.toJson());
      expect(back.id, 'st-x');
      expect(back.name, 'REZEPT');
      expect(back.hint, 'Koch-/Backvideo');
      expect(back.skeleton, '## Überblick\n## Zutaten');
    });

    test('fromJson toleriert fehlenden hint', () {
      final back = StructureTemplate.fromJson({
        'id': 'st-y',
        'name': 'NEWS',
        'skeleton': '## Überblick',
      });
      expect(back.hint, '');
    });

    test('defaults enthalten die 7 bekannten Typen', () {
      final names = StructureTemplate.defaults.map((t) => t.name).toList();
      expect(names, [
        'TUTORIAL',
        'NEWS',
        'REVIEW',
        'INTERVIEW',
        'ENTERTAINMENT',
        'REZEPT',
        'GENERISCH',
      ]);
    });

    test('typeListLine baut die SCHRITT-1-Liste mit ", oder" vor dem letzten',
        () {
      final line = StructureTemplate.typeListLine(StructureTemplate.defaults);
      expect(line.startsWith('TUTORIAL (Anleitung/How-To/Erklärung)'), isTrue);
      expect(line.contains(', oder GENERISCH (Artikel/Tool/sonstiges)'), isTrue);
      // kein "oder" doppelt / nicht am Anfang
      expect(line.indexOf('oder'), line.lastIndexOf('oder'));
    });

    test('typeListLine ohne hint nutzt nur den Namen', () {
      const ts = [
        StructureTemplate(id: 'a', name: 'A', skeleton: '## x'),
        StructureTemplate(id: 'b', name: 'B', skeleton: '## y'),
      ];
      expect(StructureTemplate.typeListLine(ts), 'A, oder B');
    });

    test('skeletonBlock listet jeden Typ mit "NAME:" + Gerüst', () {
      const ts = [
        StructureTemplate(id: 'a', name: 'A', skeleton: '## x\n## y'),
        StructureTemplate(id: 'b', name: 'B', skeleton: '## z'),
      ];
      expect(StructureTemplate.skeletonBlock(ts), 'A:\n## x\n## y\n\nB:\n## z');
    });

    test('byName ist case-insensitiv und liefert null bei Unbekanntem', () {
      final ts = StructureTemplate.defaults;
      expect(StructureTemplate.byName(ts, 'rezept')?.name, 'REZEPT');
      expect(StructureTemplate.byName(ts, '  REZEPT ')?.name, 'REZEPT');
      expect(StructureTemplate.byName(ts, 'gibtsnicht'), isNull);
      expect(StructureTemplate.byName(ts, null), isNull);
      expect(StructureTemplate.byName(ts, ''), isNull);
    });
  });

  group('buildStructuredNotePrompt', () {
    test('Auto-Modus enthält SCHRITT 1 + 2 und alle Default-Gerüste', () {
      final p = OpenRouterService.buildStructuredNotePrompt(
        body: 'Mein Inhalt',
        metaLines: 'Bekannter Titel: Foo',
        templates: StructureTemplate.defaults,
      );
      expect(p.contains('SCHRITT 1 — TYP ERKENNEN'), isTrue);
      expect(p.contains('SCHRITT 2 — NOTIZ SCHREIBEN'), isTrue);
      expect(p.contains('Bekannter Titel: Foo'), isTrue);
      expect(p.contains('INHALT:\nMein Inhalt'), isTrue);
      expect(p.contains('REZEPT:\n## Überblick'), isTrue);
      expect(
          p.contains('Gib NUR die fertige Markdown-Notiz aus'), isTrue);
    });

    test('forcedType überspringt SCHRITT 1 und erzwingt das Gerüst', () {
      final p = OpenRouterService.buildStructuredNotePrompt(
        body: 'X',
        metaLines: '',
        templates: StructureTemplate.defaults,
        forcedType: 'rezept',
      );
      expect(p.contains('SCHRITT 1'), isFalse);
      expect(p.contains('Strukturiere den INHALT als Typ REZEPT'), isTrue);
      // andere Typen tauchen nicht auf
      expect(p.contains('TUTORIAL:'), isFalse);
      expect(p.contains('## Zutaten'), isTrue);
    });

    test('unbekannter forcedType fällt auf Auto zurück', () {
      final p = OpenRouterService.buildStructuredNotePrompt(
        body: 'X',
        metaLines: '',
        templates: StructureTemplate.defaults,
        forcedType: 'gibtsnicht',
      );
      expect(p.contains('SCHRITT 1 — TYP ERKENNEN'), isTrue);
    });
  });

  group('buildResearchedNotePrompt', () {
    test('setzt Default-Struktur und Meta/Recherche ein', () {
      final p = OpenRouterService.buildResearchedNotePrompt(
        meta: 'Titel: Foo',
        research: '1. Treffer A',
        structure: StructureTemplate.defaultResearchStructure,
      );
      expect(p.contains('Titel: Foo'), isTrue);
      expect(p.contains('1. Treffer A'), isTrue);
      expect(p.contains('## Beschreibung'), isTrue);
      expect(p.contains('## Mögliche Alternativen'), isTrue);
    });

    test('leere Recherche zeigt Platzhalter', () {
      final p = OpenRouterService.buildResearchedNotePrompt(
        meta: 'Titel: Foo',
        research: '',
        structure: '## Eigene Sektion',
      );
      expect(p.contains('(keine Recherche-Treffer verfügbar)'), isTrue);
      expect(p.contains('## Eigene Sektion'), isTrue);
    });
  });
}
