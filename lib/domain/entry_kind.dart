import 'package:flutter/material.dart';

import '../services/enrichment/api_source.dart';

/// Semantischer Typ eines Eintrags — First-Class-Konzept (Phase 1).
///
/// Getrennt vom strukturellen `Entries.type` (`text|link|image|…`). Der Kind
/// wird als versteckte Property `kind` gespeichert (sync-frei) und steuert
/// Anreicherungs-Quelle, Struktur-Template, Karten-Icon/-Farbe.
///
/// [legacyAliases] deckt alle bisher verstreuten `media_type`-Schreibweisen ab
/// (AniList `ANIME`, TMDB `movie`/`tv`, BGG `BOARDGAME`, Vision-lowercase …),
/// damit der v8-Backfill sie eindeutig auf einen Kind abbilden kann.
enum EntryKind {
  movie(
    id: 'movie',
    label: 'Film',
    icon: Icons.movie_outlined,
    color: Color(0xFFEF4444),
    apiSources: [ApiSource.tmdbMovie, ApiSource.omdb],
    structureTemplateId: 'tpl-anime',
    legacyAliases: ['movie'],
  ),
  series(
    id: 'series',
    label: 'Serie',
    icon: Icons.live_tv_outlined,
    color: Color(0xFFF97316),
    apiSources: [ApiSource.tmdbTv, ApiSource.omdb],
    structureTemplateId: 'tpl-anime',
    legacyAliases: ['series', 'tv'],
  ),
  anime(
    id: 'anime',
    label: 'Anime',
    icon: Icons.animation_outlined,
    color: Color(0xFF8B5CF6),
    apiSources: [ApiSource.anilist],
    structureTemplateId: 'tpl-anime',
    legacyAliases: ['anime'],
  ),
  manga(
    id: 'manga',
    label: 'Manga',
    icon: Icons.menu_book_outlined,
    color: Color(0xFFA855F7),
    apiSources: [ApiSource.anilist],
    structureTemplateId: 'tpl-book',
    legacyAliases: ['manga'],
  ),
  book(
    id: 'book',
    label: 'Buch',
    icon: Icons.book_outlined,
    color: Color(0xFF6366F1),
    apiSources: [ApiSource.openLibrary],
    structureTemplateId: 'tpl-book',
    legacyAliases: ['book'],
  ),
  boardgame(
    id: 'boardgame',
    label: 'Brettspiel',
    icon: Icons.casino_outlined,
    color: Color(0xFF14B8A6),
    apiSources: [ApiSource.bgg],
    structureTemplateId: 'tpl-boardgame',
    legacyAliases: ['boardgame'],
  ),
  videogame(
    id: 'videogame',
    label: 'Videospiel',
    icon: Icons.sports_esports_outlined,
    color: Color(0xFF06B6D4),
    apiSources: [ApiSource.vgg],
    structureTemplateId: 'tpl-videogame',
    legacyAliases: ['videogame', 'game'],
  ),
  ttrpg(
    id: 'ttrpg',
    label: 'Pen & Paper',
    icon: Icons.shield_outlined,
    color: Color(0xFFDC2626),
    apiSources: [ApiSource.rpgg],
    structureTemplateId: 'tpl-ttrpg',
    legacyAliases: ['ttrpg'],
  ),
  youtube(
    id: 'youtube',
    label: 'YouTube',
    icon: Icons.play_circle_outline,
    color: Color(0xFFFF0000),
    apiSources: [ApiSource.youtube],
    structureTemplateId: 'tpl-youtube',
    legacyAliases: ['youtube'],
  ),
  snippet(
    id: 'snippet',
    label: 'Code / Repo',
    icon: Icons.code_outlined,
    color: Color(0xFF10B981),
    apiSources: [ApiSource.github],
    structureTemplateId: 'tpl-github',
    legacyAliases: ['github', 'snippet'],
  ),
  bookmark(
    id: 'bookmark',
    label: 'Lesezeichen',
    icon: Icons.bookmark_outline,
    color: Color(0xFF3B82F6),
    apiSources: [ApiSource.genericWeb],
    structureTemplateId: null,
    legacyAliases: ['web', 'shop', 'amazon'],
  ),
  idea(
    id: 'idea',
    label: 'Idee',
    icon: Icons.lightbulb_outline,
    color: Color(0xFFF59E0B),
    apiSources: [],
    structureTemplateId: null,
    legacyAliases: [],
  ),
  problem(
    id: 'problem',
    label: 'Problem/Lösung',
    icon: Icons.bug_report_outlined,
    color: Color(0xFFE11D48),
    apiSources: [],
    structureTemplateId: null,
    legacyAliases: [],
  ),
  note(
    id: 'note',
    label: 'Notiz',
    icon: Icons.notes_rounded,
    color: Color(0xFF6B7280),
    apiSources: [],
    structureTemplateId: null,
    legacyAliases: [],
  ),
  other(
    id: 'other',
    label: 'Sonstiges',
    icon: Icons.category_outlined,
    color: Color(0xFF71717A),
    apiSources: [],
    structureTemplateId: null,
    legacyAliases: ['other'],
  );

  const EntryKind({
    required this.id,
    required this.label,
    required this.icon,
    required this.color,
    required this.apiSources,
    required this.structureTemplateId,
    required this.legacyAliases,
  });

  /// Stabiler Schlüssel — Wert der `kind`-Property.
  final String id;

  final String label;
  final IconData icon;
  final Color color;

  /// Anreicherungs-Quellen in Präferenz-Reihenfolge (primär zuerst).
  final List<ApiSource> apiSources;

  /// Auto-anzuwendendes Struktur-Template (`tpl-…`) oder `null`.
  final String? structureTemplateId;

  /// Frühere `media_type`-Schreibweisen (lowercase), die auf diesen Kind
  /// abbilden. Für den v8-Backfill und die Vision-Analyse.
  final List<String> legacyAliases;

  /// Primäre Anreicherungs-Quelle (oder `null`, wenn der Kind keine hat).
  ApiSource? get primarySource =>
      apiSources.isEmpty ? null : apiSources.first;

  static EntryKind? fromId(String? id) {
    if (id == null) return null;
    for (final k in EntryKind.values) {
      if (k.id == id) return k;
    }
    return null;
  }

  /// Bildet einen Legacy-`media_type` (beliebige Schreibweise) auf einen Kind
  /// ab; `null`, wenn keiner passt.
  static EntryKind? fromLegacyMediaType(String? mediaType) {
    if (mediaType == null) return null;
    final m = mediaType.trim().toLowerCase();
    if (m.isEmpty) return null;
    for (final k in EntryKind.values) {
      if (k.id == m || k.legacyAliases.contains(m)) return k;
    }
    return null;
  }
}
