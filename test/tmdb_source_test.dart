import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/services/url_metadata_service.dart';
import 'package:mindfeed_mobile/services/enrichment/api_source.dart';
import 'package:mindfeed_mobile/services/enrichment/api_field_catalog.dart';
import 'package:mindfeed_mobile/services/enrichment/api_field_prefs.dart';
import 'package:mindfeed_mobile/services/enrichment/metadata_record.dart';

void main() {
  group('parseTmdbDetails – Film (#28/#44)', () {
    final movie = {
      'title': 'Inception',
      'original_title': 'Inception',
      'overview': 'Ein Dieb, der Träume stiehlt.',
      'poster_path': '/abc.jpg',
      'vote_average': 8.4,
      'release_date': '2010-07-16',
      'runtime': 148,
      'tagline': 'Deine Gedanken sind der Tatort.',
      'genres': [
        {'id': 28, 'name': 'Action'},
        {'id': 878, 'name': 'Science Fiction'},
      ],
      'credits': {
        'crew': [
          {'job': 'Director', 'name': 'Christopher Nolan'},
          {'job': 'Writer', 'name': 'Christopher Nolan'},
        ],
        'cast': [
          {'name': 'Leonardo DiCaprio'},
          {'name': 'Joseph Gordon-Levitt'},
        ],
      },
    };

    test('mappt Basisfelder korrekt', () {
      final m = UrlMetadataService.parseTmdbDetails(movie)!;
      expect(m.title, 'Inception');
      expect(m.domain, 'themoviedb.org');
      expect(m.mediaType, 'movie');
      expect(m.image, 'https://image.tmdb.org/t/p/w500/abc.jpg');
      expect(m.genres, ['Action', 'Science Fiction']);
      expect(m.score, 84); // 8.4 * 10
    });

    test('füllt extraProps (Jahr/Laufzeit/Regie/Besetzung/Tagline)', () {
      final m = UrlMetadataService.parseTmdbDetails(movie)!;
      expect(m.extraProps['Jahr'], '2010');
      expect(m.extraProps['Laufzeit'], '148 min');
      expect(m.extraProps['Regie'], 'Christopher Nolan');
      expect(m.extraProps['Besetzung'], 'Leonardo DiCaprio, Joseph Gordon-Levitt');
      expect(m.extraProps['Tagline'], 'Deine Gedanken sind der Tatort.');
    });

    test('ohne Titel → null', () {
      expect(UrlMetadataService.parseTmdbDetails({'overview': 'x'}), isNull);
    });
  });

  group('parseTmdbDetails – Serie', () {
    final tv = {
      'name': 'Breaking Bad',
      'overview': 'Chemielehrer wird Drogenkoch.',
      'poster_path': '/bb.jpg',
      'vote_average': 8.9,
      'first_air_date': '2008-01-20',
      'number_of_seasons': 5,
      'number_of_episodes': 62,
      'status': 'Ended',
      'created_by': [
        {'name': 'Vince Gilligan'}
      ],
      'networks': [
        {'name': 'AMC'}
      ],
      'genres': [
        {'name': 'Drama'}
      ],
    };

    test('mappt Serien-Felder (Staffeln/Folgen/Status/Creator/Sender)', () {
      final m = UrlMetadataService.parseTmdbDetails(tv, tv: true)!;
      expect(m.title, 'Breaking Bad');
      expect(m.mediaType, 'tv');
      expect(m.extraProps['Jahr'], '2008');
      expect(m.extraProps['Staffeln'], '5');
      expect(m.extraProps['Folgen gesamt'], '62');
      expect(m.extraProps['Status'], 'Ended');
      expect(m.extraProps['Creator'], 'Vince Gilligan');
      expect(m.extraProps['Sender'], 'AMC');
    });
  });

  group('Katalog & Mapping', () {
    test('TMDB-Quellen sind im Katalog und in den Prefs-Defaults', () {
      expect(ApiFieldCatalog.fieldsFor(ApiSource.tmdbMovie), isNotEmpty);
      expect(ApiFieldCatalog.fieldsFor(ApiSource.tmdbTv), isNotEmpty);
      final defaults = ApiFieldPrefs.defaults();
      expect(defaults.isEnabled(ApiSource.tmdbMovie, 'year'), isTrue);
    });

    test('fromUrlMetadata erkennt TMDB (nicht genericWeb) und mappt extraProps '
        'auf Katalogfelder', () {
      final m = UrlMetadataService.parseTmdbDetails({
        'title': 'Dune',
        'overview': 'Wüstenplanet.',
        'poster_path': '/d.jpg',
        'vote_average': 8.0,
        'release_date': '2021-09-15',
        'runtime': 155,
        'genres': [
          {'name': 'Science Fiction'}
        ],
        'credits': {
          'crew': [
            {'job': 'Director', 'name': 'Denis Villeneuve'}
          ],
          'cast': [],
        },
      })!;
      final record = MetadataRecord.fromUrlMetadata(m, url: '');
      expect(record.source, ApiSource.tmdbMovie);
      final keys = record.describedFields().map((e) => e.key).toSet();
      expect(keys, contains('year'));
      expect(keys, contains('runtime'));
      expect(keys, contains('director'));
      expect(keys, contains('description'));
    });
  });
}
