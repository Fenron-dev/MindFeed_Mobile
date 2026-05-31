/// Extrahiert [[Wikilinks]] aus Freitext
abstract class WikilinkParser {
  static final _regex = RegExp(r'\[\[([^\[\]\n]+)\]\]');

  static List<String> parse(String text) {
    return _regex
        .allMatches(text)
        .map((m) => m.group(1)!.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }
}
