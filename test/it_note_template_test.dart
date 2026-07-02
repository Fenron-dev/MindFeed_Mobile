import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/services/ai/it_note_template.dart';

void main() {
  group('buildItNotePrompt (#31)', () {
    test('Hybrid-Regeln in beiden Modi: kein Frontmatter, kein meta-bind', () {
      for (final mode in ItNoteMode.values) {
        final p = buildItNotePrompt(mode: mode, problem: 'X');
        expect(p, contains('KEIN YAML-Frontmatter'));
        expect(p, contains('KEINE meta-bind'));
        // Obsidian-Callouts bleiben (Hybrid)
        expect(p, contains('>[!info]+'));
        expect(p, contains('>[!success]+'));
        // Kern-Abschnitte
        expect(p, contains('## Problembeschreibung'));
        expect(p, contains('## Lösung'));
      }
    });

    test('Modus A recherchiert: Recherche-Block + Kennzeichnung + Treffer', () {
      final p = buildItNotePrompt(
        mode: ItNoteMode.research,
        problem: 'DNS schlägt fehl nach VPN',
        research: '[1] Foo\nBar\nhttps://x',
      );
      expect(p, contains('MODUS A'));
      expect(p, contains('WEB-RECHERCHE'));
      expect(p, contains('[1] Foo'));
      expect(p.toLowerCase(), contains('kennzeichne recherchierte'));
    });

    test('Modus A ohne Treffer zeigt Platzhalter', () {
      final p = buildItNotePrompt(mode: ItNoteMode.research, problem: 'X');
      expect(p, contains('(keine Recherche-Treffer verfügbar)'));
    });

    test('Modus B strukturiert nur: kein Recherche-Block, nichts erfinden', () {
      final p = buildItNotePrompt(
        mode: ItNoteMode.structure,
        problem: 'Drucker offline',
        solution: 'Spooler neu starten',
      );
      expect(p, contains('MODUS B'));
      expect(p, contains('Erfinde KEINE'));
      expect(p, isNot(contains('WEB-RECHERCHE')));
      expect(p, contains('GELIEFERTE LÖSUNG'));
      expect(p, contains('Spooler neu starten'));
    });

    test('Modus B ohne Lösung: kein Lösungs-Block', () {
      final p = buildItNotePrompt(mode: ItNoteMode.structure, problem: 'X');
      expect(p, isNot(contains('GELIEFERTE LÖSUNG')));
    });
  });
}
