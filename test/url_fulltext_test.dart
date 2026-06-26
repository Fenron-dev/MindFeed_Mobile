import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:mindfeed_mobile/services/url_metadata_service.dart';

/// Deckt die readability-artige Haupttext-Extraktion ab (#27).
void main() {
  test('extrahiert Artikeltext, ignoriert Navigation/Skripte', () {
    const html = '''
      <html><head><title>T</title></head><body>
        <nav><a href="/">Start</a> <a href="/x">Menüpunkt</a></nav>
        <script>var x = 1; console.log("tracking");</script>
        <article>
          <h1>Die große Überschrift</h1>
          <p>Dies ist der erste echte Absatz mit ausreichend Inhalt für die Erkennung.</p>
          <p>kurz</p>
          <p>Und ein zweiter inhaltsreicher Absatz, der ebenfalls übernommen werden soll.</p>
        </article>
        <footer>Impressum Kontakt</footer>
      </body></html>
    ''';
    final doc = html_parser.parse(html);
    final text = UrlMetadataService.mainTextFromDocument(doc);

    expect(text, contains('Die große Überschrift'));
    expect(text, contains('erste echte Absatz'));
    expect(text, contains('zweiter inhaltsreicher Absatz'));
    // Navigation, Skript, Footer und zu kurze Absätze fließen nicht ein.
    expect(text, isNot(contains('Menüpunkt')));
    expect(text, isNot(contains('tracking')));
    expect(text, isNot(contains('Impressum')));
    expect(text, isNot(contains('kurz')));
  });

  test('leere/inhaltslose Seite → leerer String', () {
    final doc = html_parser.parse('<html><body></body></html>');
    expect(UrlMetadataService.mainTextFromDocument(doc), isEmpty);
  });
}
