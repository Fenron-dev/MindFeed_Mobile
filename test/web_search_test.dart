import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/services/web_search/web_search.dart';

void main() {
  group('WebSearchProviderKind (#32)', () {
    test('fromId fällt bei Unbekanntem/null auf SearXNG zurück', () {
      expect(WebSearchProviderKind.fromId(null), WebSearchProviderKind.searxng);
      expect(WebSearchProviderKind.fromId('xxx'), WebSearchProviderKind.searxng);
      expect(WebSearchProviderKind.fromId('brave'), WebSearchProviderKind.brave);
    });

    test('Brave ist Geheimnis, SearXNG nicht', () {
      expect(WebSearchProviderKind.brave.isSecret, isTrue);
      expect(WebSearchProviderKind.searxng.isSecret, isFalse);
    });

    test('IDs sind stabil', () {
      expect(WebSearchProviderKind.searxng.id, 'searxng');
      expect(WebSearchProviderKind.brave.id, 'brave');
    });
  });

  group('buildWebSearchProvider', () {
    test('leere Konfiguration → null', () {
      expect(buildWebSearchProvider(WebSearchProviderKind.searxng, '  '), isNull);
      expect(buildWebSearchProvider(WebSearchProviderKind.brave, ''), isNull);
    });

    test('liefert den passenden Provider-Typ', () {
      expect(
        buildWebSearchProvider(WebSearchProviderKind.searxng, 'http://x:8080'),
        isA<SearxngProvider>(),
      );
      expect(
        buildWebSearchProvider(WebSearchProviderKind.brave, 'BSA-key'),
        isA<BraveProvider>(),
      );
    });
  });

  group('BraveProvider.parseResults', () {
    test('mappt description→content, filtert URL-lose Treffer, kappt auf limit',
        () {
      final data = {
        'web': {
          'results': [
            {'title': 'A', 'url': 'https://a.example', 'description': 'snippet a'},
            {'title': 'Ohne URL', 'url': '', 'description': 'x'},
            {'title': 'B', 'url': 'https://b.example', 'description': 'snippet b'},
            {'title': 'C', 'url': 'https://c.example', 'description': 'snippet c'},
          ],
        },
      };
      final results = BraveProvider.parseResults(data, limit: 2);
      expect(results.length, 2);
      expect(results[0].title, 'A');
      expect(results[0].content, 'snippet a');
      expect(results[1].url, 'https://b.example');
    });

    test('fehlendes web/results → leere Liste', () {
      expect(BraveProvider.parseResults({}), isEmpty);
      expect(BraveProvider.parseResults({'web': {}}), isEmpty);
      expect(BraveProvider.parseResults('kaputt'), isEmpty);
    });
  });

  group('webResultsToContext', () {
    test('nummeriert Treffer mit Titel, Snippet und URL', () {
      final ctx = webResultsToContext(const [
        WebSearchResult(title: 'Titel 1', url: 'https://u1', content: 'Snippet 1'),
        WebSearchResult(title: 'Titel 2', url: 'https://u2', content: ''),
      ]);
      expect(ctx, contains('[1] Titel 1'));
      expect(ctx, contains('Snippet 1'));
      expect(ctx, contains('https://u1'));
      expect(ctx, contains('[2] Titel 2'));
      expect(ctx, contains('https://u2'));
    });
  });
}
