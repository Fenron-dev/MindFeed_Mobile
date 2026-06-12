/// Externe Datenquellen, aus denen Einträge angereichert werden können.
///
/// Jede Quelle besitzt im [ApiFieldCatalog] eine Liste verfügbarer Felder.
/// Neue Quellen werden hier ergänzt und im Katalog beschrieben — der Rest
/// (Einstellungen-UI, Abhol-Vorschau, Import) leitet sich daraus ab.
enum ApiSource {
  anilist('anilist', 'AniList'),
  bgg('bgg', 'BoardGameGeek'),
  vgg('vgg', 'VideoGameGeek'),
  rpgg('rpgg', 'RPGGeek'),
  github('github', 'GitHub'),
  youtube('youtube', 'YouTube'),
  tmdbMovie('tmdb_movie', 'TMDB (Film)'),
  tmdbTv('tmdb_tv', 'TMDB (Serie)'),
  omdb('omdb', 'OMDb'),
  openLibrary('open_library', 'OpenLibrary'),
  amazon('amazon', 'Amazon'),
  genericWeb('generic_web', 'Web');

  const ApiSource(this.id, this.label);

  /// Stabiler Schlüssel für Persistenz (SharedPreferences, JSON).
  final String id;

  /// Menschlich lesbarer Name für die UI.
  final String label;

  static ApiSource? fromId(String id) {
    for (final s in ApiSource.values) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Bestimmt die Quelle anhand der Domain eines Links. Liefert [genericWeb],
  /// wenn keine spezialisierte Quelle greift.
  static ApiSource fromDomain(String? domain) {
    final d = (domain ?? '').toLowerCase().replaceFirst('www.', '');
    if (d.contains('anilist.co')) return ApiSource.anilist;
    if (d.contains('boardgamegeek.com')) return ApiSource.bgg;
    if (d.contains('videogamegeek.com')) return ApiSource.vgg;
    if (d.contains('rpggeek.com')) return ApiSource.rpgg;
    if (d.contains('github.com')) return ApiSource.github;
    if (d.contains('youtube.com') || d.contains('youtu.be')) {
      return ApiSource.youtube;
    }
    if (d.contains('themoviedb.org')) return ApiSource.tmdbMovie;
    if (d.contains('imdb.com')) return ApiSource.omdb;
    if (d.contains('openlibrary.org')) return ApiSource.openLibrary;
    if (d.contains('amazon.')) return ApiSource.amazon;
    return ApiSource.genericWeb;
  }
}
