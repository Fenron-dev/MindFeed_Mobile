import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/domain/entry_kind.dart';
import 'package:mindfeed_mobile/services/enrichment/api_source.dart';

void main() {
  group('EntryKind.fromLegacyMediaType', () {
    test('deckt alle verstreuten Schreibweisen ab', () {
      final cases = <String, EntryKind>{
        // AniList / Vision (UPPERCASE & lowercase)
        'ANIME': EntryKind.anime,
        'anime': EntryKind.anime,
        'MANGA': EntryKind.manga,
        // TMDB
        'movie': EntryKind.movie,
        'tv': EntryKind.series,
        'series': EntryKind.series,
        // BGG-Familie
        'BOARDGAME': EntryKind.boardgame,
        'VIDEOGAME': EntryKind.videogame,
        'game': EntryKind.videogame,
        'TTRPG': EntryKind.ttrpg,
        // Sonstige
        'YOUTUBE': EntryKind.youtube,
        'GITHUB': EntryKind.snippet,
        'AMAZON': EntryKind.bookmark,
        'shop': EntryKind.bookmark,
        'web': EntryKind.bookmark,
        'book': EntryKind.book,
        'other': EntryKind.other,
      };
      cases.forEach((input, expected) {
        expect(EntryKind.fromLegacyMediaType(input), expected, reason: input);
      });
    });

    test('null/leer/unbekannt → null', () {
      expect(EntryKind.fromLegacyMediaType(null), isNull);
      expect(EntryKind.fromLegacyMediaType(''), isNull);
      expect(EntryKind.fromLegacyMediaType('voelliger_unsinn'), isNull);
    });
  });

  group('EntryKind Registry-Integrität', () {
    test('ids sind eindeutig', () {
      final ids = EntryKind.values.map((k) => k.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('legacyAliases sind global eindeutig (kein Kind-Konflikt)', () {
      final seen = <String, EntryKind>{};
      for (final k in EntryKind.values) {
        for (final a in k.legacyAliases) {
          expect(seen.containsKey(a), isFalse,
              reason: 'Alias "$a" doppelt: ${seen[a]} vs $k');
          seen[a] = k;
        }
      }
    });

    test('primarySource entspricht erster apiSource', () {
      expect(EntryKind.movie.primarySource, ApiSource.tmdbMovie);
      expect(EntryKind.anime.primarySource, ApiSource.anilist);
      expect(EntryKind.note.primarySource, isNull);
    });

    test('fromId Round-Trip', () {
      for (final k in EntryKind.values) {
        expect(EntryKind.fromId(k.id), k);
      }
      expect(EntryKind.fromId(null), isNull);
      expect(EntryKind.fromId('nope'), isNull);
    });
  });
}
