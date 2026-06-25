import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/widgets/format_toolbar.dart';

/// Deckt die reinen Markdown-Bearbeitungs-Helfer der FormatToolbar ab.
void main() {
  TextEditingValue val(String text, {int? start, int? end}) => TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: start ?? text.length,
          extentOffset: end ?? text.length,
        ),
      );

  group('wrap', () {
    test('umschließt Auswahl mit Markern', () {
      final r = MarkdownFormat.wrap(val('foo bar baz', start: 4, end: 7), '**', '**');
      expect(r.text, 'foo **bar** baz');
      expect(r.selection.baseOffset, 11); // hinter dem geschlossenen Marker
    });

    test('ohne Auswahl: Cursor zwischen die Marker', () {
      final r = MarkdownFormat.wrap(val('foo', start: 3, end: 3), '*', '*');
      expect(r.text, 'foo**');
      expect(r.selection.baseOffset, 4); // zwischen den Sternen
    });

    test('Durchgestrichen', () {
      final r = MarkdownFormat.wrap(val('x', start: 0, end: 1), '~~', '~~');
      expect(r.text, '~~x~~');
    });
  });

  group('linePrefix', () {
    test('fügt Aufzählungszeichen am Zeilenanfang ein', () {
      final r = MarkdownFormat.linePrefix(val('a\nb\nc', start: 2, end: 2), '- ');
      expect(r.text, 'a\n- b\nc');
    });

    test('erste Zeile (Cursor am Anfang)', () {
      final r = MarkdownFormat.linePrefix(val('hello', start: 0, end: 0), '- ');
      expect(r.text, '- hello');
    });
  });

  group('insert', () {
    test('ersetzt Auswahl durch Text', () {
      final r = MarkdownFormat.insert(val('ab', start: 0, end: 2), 'https://x');
      expect(r.text, 'https://x');
      expect(r.selection.baseOffset, 9);
    });

    test('fügt am Cursor ein', () {
      final r = MarkdownFormat.insert(val('ab', start: 1, end: 1), 'X');
      expect(r.text, 'aXb');
    });
  });
}
