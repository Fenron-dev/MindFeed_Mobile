/// Editierbare Struktur-Vorlage für die KI-„strukturierte Notiz" (#38).
///
/// Jede Vorlage beschreibt einen Inhaltstyp (z.B. REZEPT): [name] ist der
/// Typname (auch Überschrift im Gerüst), [hint] die Kurzbeschreibung für die
/// Typ-Erkennung (SCHRITT 1) und [skeleton] das Markdown-`##`-Gerüst (SCHRITT 2).
///
/// Die [defaults] entsprechen 1:1 den bisher fest verdrahteten Gerüsten —
/// ohne Änderung verhält sich die Strukturierung also exakt wie zuvor.
class StructureTemplate {
  final String id;
  final String name;

  /// Kurzbeschreibung für die Typ-Erkennung, z.B. „Koch-/Backvideo".
  /// Wird in SCHRITT 1 als `NAME (hint)` aufgelistet. Optional.
  final String hint;

  /// Das Markdown-Gerüst (mehrzeilig, `##`-Überschriften ggf. mit Hinweisen).
  final String skeleton;

  const StructureTemplate({
    required this.id,
    required this.name,
    this.hint = '',
    required this.skeleton,
  });

  StructureTemplate copyWith({
    String? id,
    String? name,
    String? hint,
    String? skeleton,
  }) =>
      StructureTemplate(
        id: id ?? this.id,
        name: name ?? this.name,
        hint: hint ?? this.hint,
        skeleton: skeleton ?? this.skeleton,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hint': hint,
        'skeleton': skeleton,
      };

  factory StructureTemplate.fromJson(Map<String, dynamic> j) =>
      StructureTemplate(
        id: j['id'] as String,
        name: j['name'] as String,
        hint: (j['hint'] as String?) ?? '',
        skeleton: (j['skeleton'] as String?) ?? '',
      );

  // ── Prompt-Bausteine ────────────────────────────────────────────────────────

  /// SCHRITT-1-Typliste, z.B.
  /// „TUTORIAL (Anleitung/How-To/Erklärung), NEWS (…), oder GENERISCH (…)".
  /// (Ohne abschließenden Punkt — den setzt der Prompt.)
  static String typeListLine(List<StructureTemplate> templates) {
    final parts = templates
        .map((t) => t.hint.trim().isEmpty ? t.name : '${t.name} (${t.hint})')
        .toList();
    if (parts.length <= 1) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')}, oder ${parts.last}';
  }

  /// SCHRITT-2-Gerüstblock: je Vorlage `NAME:` mit folgendem Gerüst, durch
  /// Leerzeilen getrennt.
  static String skeletonBlock(List<StructureTemplate> templates) {
    return templates
        .map((t) => '${t.name}:\n${t.skeleton.trim()}')
        .join('\n\n');
  }

  /// Findet die Vorlage zum erzwungenen Typ (Name, Groß-/Kleinschreibung egal).
  static StructureTemplate? byName(
      List<StructureTemplate> templates, String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final n = name.trim().toLowerCase();
    for (final t in templates) {
      if (t.name.trim().toLowerCase() == n) return t;
    }
    return null;
  }

  // ── Auslieferungs-Defaults (= bisheriges Verhalten) ─────────────────────────

  static List<StructureTemplate> get defaults => const [
        StructureTemplate(
          id: 'st-tutorial',
          name: 'TUTORIAL',
          hint: 'Anleitung/How-To/Erklärung',
          skeleton: '## Überblick\n'
              '## Voraussetzungen\n'
              '## Schritt-für-Schritt\n'
              '## Wichtige Aussagen\n'
              '## Hinweise & Risiken\n'
              '## Weiterführende Ressourcen',
        ),
        StructureTemplate(
          id: 'st-news',
          name: 'NEWS',
          hint: 'News/Roundup/Liste',
          skeleton: '## Überblick\n'
              '## Themen & Neuigkeiten  (je Thema ### mit Zeitstempel + 3-6 Sätze)\n'
              '## Fazit\n'
              '## Weiterführende Ressourcen',
        ),
        StructureTemplate(
          id: 'st-review',
          name: 'REVIEW',
          hint: 'Test/Vergleich',
          skeleton: '## Überblick\n'
              '## Getestetes / Verglichenes\n'
              '## Stärken\n'
              '## Schwächen\n'
              '## Fazit\n'
              '## Alternativen',
        ),
        StructureTemplate(
          id: 'st-interview',
          name: 'INTERVIEW',
          hint: 'Gespräch/Podcast',
          skeleton: '## Überblick\n'
              '## Personen\n'
              '## Besprochene Themen  (je Thema ### + Zusammenfassung)\n'
              '## Wichtige Aussagen\n'
              '## Kernaussagen & Erkenntnisse',
        ),
        StructureTemplate(
          id: 'st-entertainment',
          name: 'ENTERTAINMENT',
          hint: "Let's Play/Reaction",
          skeleton: '## Überblick\n'
              '## Inhalt & Verlauf\n'
              '## Besondere Momente\n'
              '## Medieninfo',
        ),
        StructureTemplate(
          id: 'st-rezept',
          name: 'REZEPT',
          hint: 'Koch-/Backvideo',
          skeleton: '## Überblick\n'
              '## Rahmendaten  (Markdown-Tabelle: Portionen, Zubereitungszeit, Kochzeit, Schwierigkeitsgrad, Küche)\n'
              '## Zutaten  (gruppiert, mit Mengen)\n'
              '## Zubereitung  (nummerierte Schritte, Zeitstempel falls vorhanden)\n'
              '## Tipps & Tricks\n'
              '## Wichtige Aussagen\n'
              '## Varianten & Alternativen',
        ),
        StructureTemplate(
          id: 'st-generisch',
          name: 'GENERISCH',
          hint: 'Artikel/Tool/sonstiges',
          skeleton: '## Überblick\n'
              '## Wichtigste Inhalte  (Stichpunkte)\n'
              '## Details\n'
              '## Weiterführende Ressourcen',
        ),
      ];

  /// Default-Struktur der „recherchierten Notiz" (`generateResearchedNote`).
  /// Editierbar in den Einstellungen; entspricht 1:1 dem bisherigen Prompt.
  static const String defaultResearchStructure = '## Beschreibung\n'
      '(10-30 Sätze: worum geht es, was kann/macht es, was hebt es hervor. Bei Medien: spoilerfreie Inhaltsangabe.)\n'
      '## Systemvoraussetzungen   (nur bei Software, wenn sinnvoll)\n'
      '## Installation             (nur bei Software, wenn sinnvoll)\n'
      '## Mögliche Risiken         (nur wenn relevant)\n'
      '## Mögliche Alternativen\n'
      '(3-10 Alternativen als Markdown-Tabelle: Name als Link, kurze Beschreibung, ggf. Preis in Euro / Vor- & Nachteile.)\n'
      '## Referenzen & weiterführende Informationen\n'
      '(Nummerierte Liste: **Titel** in Fett, darunter kurze Beschreibung und Link.)\n'
      '## Video & Audio            (passende YouTube-/Podcast-Treffer, falls vorhanden, max 10)\n'
      '## FAQ                       (häufige Fragen, nummeriert: **Frage** + Antwort darunter)\n'
      '## Begriffe                  (nur falls Fachbegriffe erklärt werden müssen)';
}
