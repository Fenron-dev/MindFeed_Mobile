/// Eingabe-Modi des IT-Notiz-Generators (#31).
enum ItNoteMode {
  /// Modus A – nur Problem: die KI recherchiert Ursachen/Lösungen (braucht
  /// Web-Recherche) und kennzeichnet recherchierte Ansätze als solche.
  research,

  /// Modus B – Problem + Lösung: die KI strukturiert nur, erfindet nichts.
  structure,
}

/// Baut den Prompt für eine strukturierte IT-Problem-/Lösungs-Notiz (#31).
///
/// Hybrid-Format: KEIN YAML-Frontmatter und KEINE meta-bind-Direktiven
/// (`INPUT[...]`/`VIEW[...]`) — MindFeed verwaltet Metadaten als Properties und
/// rendert kein Frontmatter. Obsidian-Callouts (`>[!info]+`, `>[!success]+`)
/// bleiben erhalten (portabel und in MindFeed lesbar). Deutsch, sachlich.
String buildItNotePrompt({
  required ItNoteMode mode,
  required String problem,
  String solution = '',
  String research = '',
}) {
  final modeBlock = mode == ItNoteMode.research
      ? '''MODUS A – NUR PROBLEM:
Es liegt nur eine Problembeschreibung vor, keine Lösung. Ermittle aus der
WEB-RECHERCHE (unten) die wahrscheinlichsten Ursachen und Lösungsansätze und
erstelle daraus eine vollständige Notiz. Kennzeichne recherchierte
Lösungsansätze klar als solche und verlinke die Quelle. Erfinde keine URLs.'''
      : '''MODUS B – PROBLEM + LÖSUNG:
Problem und Lösung sind gegeben. Strukturiere alles sauber in die Vorlage.
Erfinde KEINE eigenen Lösungen und keine zusätzlichen Fakten.''';

  final researchBlock = mode == ItNoteMode.research
      ? '\nWEB-RECHERCHE (nummerierte Treffer — nur diese und allgemein bekannten '
          'Kontext als Quelle verwenden; keine URLs erfinden):\n'
          '${research.trim().isEmpty ? '(keine Recherche-Treffer verfügbar)' : research.trim()}\n'
      : '';

  final solutionBlock = (mode == ItNoteMode.structure && solution.trim().isNotEmpty)
      ? '\nGELIEFERTE LÖSUNG:\n${solution.trim()}\n'
      : '';

  return '''Du bist ein IT-Dokumentationsassistent. Aus der folgenden Eingabe erstellst du eine sachliche, strukturierte deutsche Markdown-Notiz zu einem IT-Problem und seiner Lösung.

$modeBlock

PROBLEM (Eingabe des Nutzers):
${problem.trim()}
$solutionBlock$researchBlock
REGELN:
- Sachlich, neutral, präzise. Keine Marketing-Sprache, keine Emojis.
- Keine Referenz-Hinweise wie [web:1] o.ä.
- KEIN YAML-Frontmatter ausgeben (Metadaten verwaltet MindFeed als Properties).
- KEINE meta-bind-Direktiven (`INPUT[...]`, `VIEW[...]`) ausgeben.
- Lösungsschritte bevorzugt als nummerierte Schritt-für-Schritt-Anleitung.
  Befehle IMMER in Code-Blöcken (```).
- Optionale Abschnitte nur, wenn inhaltlich sinnvoll; sonst weglassen.
- Links als Markdown [Name](https://…); nur URLs aus der Recherche/Eingabe.

STRUKTUR (in dieser Reihenfolge, passende Abschnitte wählen):
Beginne mit einem prägnanten Titel als H1 (# …), der das Problem benennt.
Danach ein Überblicks-Callout:
>[!info]+ Schneller Überblick
>1–3 sachliche Sätze: Problem, Ursache, Lösung.

## Problembeschreibung
### Symptome
### Mögliche Ursachen
## Lösung
>[!success]+ Lösung
>Nummerierte Schritt-für-Schritt-Anleitung; Befehle in Code-Blöcken.${mode == ItNoteMode.research ? ' Recherchierte Lösung mit Quellenangabe.' : ''}
### Varianten / Alternativer Lösungsweg (optional)
## Betroffene Umgebung (optional)
## Mögliche Risiken & Nebenwirkungen (optional)
## Mögliche Alternativen & Workarounds (optional)
# Referenzen und weiterführende Informationen (optional)
## Video & Audio (optional)
# FAQs (optional)
## Spezial-Begriffe erklärt (optional)

Gib NUR die fertige Markdown-Notiz aus, ohne Vorrede, ohne umschließende Code-Fences.''';
}
