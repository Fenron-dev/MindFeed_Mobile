/// Extrahiert #hashtags und #hierarchische/tags aus Freitext
abstract class TagParser {
  static final _regex = RegExp(r'#([a-zA-Z][a-zA-Z0-9_/äöüÄÖÜß]*)');

  static List<String> parse(String text) {
    return _regex
        .allMatches(text)
        .map((m) => m.group(1)!.toLowerCase())
        .toSet()
        .toList();
  }
}
