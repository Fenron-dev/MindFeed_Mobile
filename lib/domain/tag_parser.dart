/// Extrahiert #hashtags inkl. hierarchischer Subtags im Obsidian-Stil:
///   #emulation/handheld/R36-Max
/// Erlaubt Buchstaben, Zahlen, Unterstrich, Bindestrich und Schrägstrich
/// (für Hierarchie). Erstes Zeichen muss ein Buchstabe sein.
abstract class TagParser {
  static final _regex =
      RegExp(r'#([a-zA-Z][a-zA-Z0-9_\-/äöüÄÖÜß]*)');

  static List<String> parse(String text) {
    return _regex
        .allMatches(text)
        .map((m) => m.group(1)!.toLowerCase())
        // mögliche Trennzeichen am Ende entfernen (#tag/ → #tag)
        .map((t) => t.replaceAll(RegExp(r'[-/]+$'), ''))
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList();
  }
}
