import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/services/enrichment/sources/youtube_api_source.dart';

/// Deckt das Parsing der YouTube-Data-API-Felder ab (Phase 3): ISO-8601-Dauer
/// und Veröffentlichungsdatum.
void main() {
  group('formatDuration', () {
    test('Stunden:Minuten:Sekunden', () {
      expect(YoutubeApiSource.formatDuration('PT1H2M3S'), '1:02:03');
    });
    test('nur Minuten:Sekunden', () {
      expect(YoutubeApiSource.formatDuration('PT12M5S'), '12:05');
    });
    test('nur Sekunden → mm:ss mit führender Null', () {
      expect(YoutubeApiSource.formatDuration('PT45S'), '00:45');
    });
    test('exakte Stunde ohne Minuten/Sekunden', () {
      expect(YoutubeApiSource.formatDuration('PT2H'), '2:00:00');
    });
    test('leer/ungültig → null', () {
      expect(YoutubeApiSource.formatDuration(null), isNull);
      expect(YoutubeApiSource.formatDuration(''), isNull);
      expect(YoutubeApiSource.formatDuration('PT0S'), isNull);
    });
  });

  group('formatDate', () {
    test('ISO-Zeitstempel → dd.mm.yyyy', () {
      expect(YoutubeApiSource.formatDate('2024-01-05T12:34:56Z'), '05.01.2024');
    });
    test('zu kurz/ungültig → null', () {
      expect(YoutubeApiSource.formatDate(null), isNull);
      expect(YoutubeApiSource.formatDate('2024'), isNull);
    });
  });
}
