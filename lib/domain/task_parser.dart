import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Ergebnis der Analyse einer einzelnen Task-Zeile.
class ParsedTaskLine {
  /// Position im Text (Zeichen-Offset vom Anfang des Strings).
  final int startOffset;
  final int endOffset;

  /// Vollständiger Zeilentext (inkl. `- [ ] ...`).
  final String rawLine;

  /// Ob der Task als erledigt markiert ist (`[x]`).
  final bool isDone;

  /// Titel der Aufgabe (ohne Syntax-Marker).
  final String title;

  /// Block-Referenz (z.B. `^e-abc123`). Null = noch keine Verknüpfung.
  final String? blockRef;

  /// Fälligkeitsdatum aus 📅 2025-01-15.
  final DateTime? dueDate;

  /// Wiederholungsregel aus 🔁 (z.B. `weekly`, `monthly`).
  final String? recurrence;

  /// Priorität: `low` / `medium` / `high` / `urgent`.
  final String? priority;

  const ParsedTaskLine({
    required this.startOffset,
    required this.endOffset,
    required this.rawLine,
    required this.isDone,
    required this.title,
    this.blockRef,
    this.dueDate,
    this.recurrence,
    this.priority,
  });
}

/// Parst Obsidian-kompatible Task-Zeilen aus einem Notiz-Body.
///
/// Unterstützte Syntax:
///   - [ ] Aufgabe
///   - [x] Erledigte Aufgabe
///   - [ ] Aufgabe 📅 2025-01-15 🔁 weekly ⬆️ ^e-abc123
///
/// Prioritäts-Emojis: ⬆️ = high, ⏫ = urgent, 🔽 = low, 🔼 = medium
class TaskParser {
  // Regex: findet `- [ ]` oder `- [x]` am Zeilenanfang (auch nach Leerzeichen)
  static final _lineRe = RegExp(
    r'^(\s*- \[([ xX])\] )(.*?)$',
    multiLine: true,
  );

  // Block-Referenz am Ende der Zeile: ^abc123 oder ^e-abc123
  static final _blockRefRe = RegExp(r'\^([a-zA-Z0-9_-]+)\s*$');

  // Datum: 📅 YYYY-MM-DD
  static final _dateRe = RegExp(r'📅\s*(\d{4}-\d{2}-\d{2})');

  // Wiederholung: 🔁 <rule>
  static final _recurrenceRe = RegExp(r'🔁\s*(\S+)');

  // Priorität: Emojis
  static final _priorityRe = RegExp(r'(⬆️|⏫|🔼|🔽|⬇️)');

  /// Gibt alle Task-Zeilen im [body] zurück.
  static List<ParsedTaskLine> parse(String body) {
    final results = <ParsedTaskLine>[];
    for (final match in _lineRe.allMatches(body)) {
      final isDone = match.group(2)!.trim().toLowerCase() == 'x';
      var content = match.group(3) ?? '';

      // Block-Ref extrahieren
      String? blockRef;
      final blockMatch = _blockRefRe.firstMatch(content);
      if (blockMatch != null) {
        blockRef = blockMatch.group(1);
        content = content.substring(0, blockMatch.start).trimRight();
      }

      // Datum extrahieren
      DateTime? dueDate;
      final dateMatch = _dateRe.firstMatch(content);
      if (dateMatch != null) {
        dueDate = DateTime.tryParse(dateMatch.group(1)!);
        content = content.replaceFirst(_dateRe, '').trim();
      }

      // Wiederholung extrahieren
      String? recurrence;
      final recMatch = _recurrenceRe.firstMatch(content);
      if (recMatch != null) {
        recurrence = recMatch.group(1);
        content = content.replaceFirst(_recurrenceRe, '').trim();
      }

      // Priorität extrahieren
      String? priority;
      final prioMatch = _priorityRe.firstMatch(content);
      if (prioMatch != null) {
        priority = _emojitoPriority(prioMatch.group(1)!);
        content = content.replaceFirst(_priorityRe, '').trim();
      }

      results.add(ParsedTaskLine(
        startOffset: match.start,
        endOffset: match.end,
        rawLine: match.group(0)!,
        isDone: isDone,
        title: content.trim(),
        blockRef: blockRef,
        dueDate: dueDate,
        recurrence: recurrence,
        priority: priority,
      ));
    }
    return results;
  }

  static String _emojitoPriority(String emoji) => switch (emoji) {
        '⬆️' => 'high',
        '⏫' => 'urgent',
        '🔼' => 'medium',
        '🔽' => 'low',
        '⬇️' => 'low',
        _ => 'medium',
      };

  /// Schreibt eine Block-Ref in die Task-Zeile, wenn noch keine vorhanden.
  /// Gibt den aktualisierten Body zurück.
  static String injectBlockRef(String body, ParsedTaskLine line, String entryId) {
    if (line.blockRef != null) return body; // bereits vorhanden
    final shortId = entryId.replaceFirst('e-', '');
    final newLine = '${line.rawLine} ^$shortId';
    return body.replaceRange(line.startOffset, line.endOffset, newLine);
  }

  /// Generiert eine neue Block-Ref-ID (UUID-Fragment).
  static String generateBlockRef() {
    return _uuid.v4().replaceAll('-', '').substring(0, 8);
  }

  /// Aktualisiert den Checkbox-Status in einer Task-Zeile.
  /// Gibt den aktualisierten Body zurück.
  static String setTaskDone(String body, ParsedTaskLine line, bool done) {
    final marker = done ? '- [x] ' : '- [ ] ';
    final prefixLen = line.rawLine.indexOf('- [') + 6; // '- [ ] '.length
    final lineWithoutPrefix = line.rawLine.substring(prefixLen);
    final newLine = marker + lineWithoutPrefix;
    return body.replaceRange(line.startOffset, line.endOffset, newLine);
  }

  /// Findet die Task-Zeile im Body anhand ihrer Block-Ref.
  static ParsedTaskLine? findByBlockRef(String body, String blockRef) {
    return parse(body)
        .where((l) => l.blockRef == blockRef)
        .firstOrNull;
  }

  /// Findet die Task-Zeile im Body anhand ihres Entry-IDs.
  static ParsedTaskLine? findByEntryId(String body, String entryId) {
    final shortId = entryId.replaceFirst('e-', '');
    return findByBlockRef(body, shortId);
  }
}
