import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Unterstützte Wiederholungsfrequenzen.
enum RecurrenceFrequency { daily, weekly, monthly, yearly }

/// Einfache RRULE-ähnliche Wiederholungsregel.
/// Intern als kompakter String gespeichert, z.B.:
///   DAILY           → täglich
///   WEEKLY;BYDAY=MO,WE,FR → jeden Mo, Mi, Fr
///   MONTHLY;BYMONTHDAY=15 → jeden 15. des Monats
///   YEARLY          → jährlich
class RecurrenceRule {
  final RecurrenceFrequency frequency;

  /// Für WEEKLY: Wochentage (0=Mo, 1=Di, ..., 6=So). Leer = gleicher Wochentag.
  final List<int> weekdays;

  /// Für MONTHLY: Tag des Monats (1-31). Null = gleicher Tag wie Fälligkeitsdatum.
  final int? monthDay;

  const RecurrenceRule({
    required this.frequency,
    this.weekdays = const [],
    this.monthDay,
  });

  /// Gibt eine menschenlesbare Beschreibung zurück.
  String get label {
    switch (frequency) {
      case RecurrenceFrequency.daily:
        return 'Täglich';
      case RecurrenceFrequency.weekly:
        if (weekdays.isEmpty) return 'Wöchentlich';
        final names = weekdays.map(_dayName).join(', ');
        return 'Wöchentlich ($names)';
      case RecurrenceFrequency.monthly:
        if (monthDay != null) return 'Monatlich (am $monthDay.)';
        return 'Monatlich';
      case RecurrenceFrequency.yearly:
        return 'Jährlich';
    }
  }

  /// Serialisiert in einen kompakten String (z.B. für task_recurrence Property).
  String toRrule() {
    final parts = <String>[];
    switch (frequency) {
      case RecurrenceFrequency.daily:
        parts.add('DAILY');
      case RecurrenceFrequency.weekly:
        parts.add('WEEKLY');
        if (weekdays.isNotEmpty) {
          final days = weekdays.map(_dayCode).join(',');
          parts.add('BYDAY=$days');
        }
      case RecurrenceFrequency.monthly:
        parts.add('MONTHLY');
        if (monthDay != null) parts.add('BYMONTHDAY=$monthDay');
      case RecurrenceFrequency.yearly:
        parts.add('YEARLY');
    }
    return parts.join(';');
  }

  /// Parst einen RRULE-String zurück in eine RecurrenceRule.
  static RecurrenceRule? fromRrule(String? rrule) {
    if (rrule == null || rrule.isEmpty) return null;
    final parts = rrule.split(';');
    final freq = parts.first.trim().toUpperCase();

    RecurrenceFrequency? frequency;
    List<int> weekdays = [];
    int? monthDay;

    switch (freq) {
      case 'DAILY':
        frequency = RecurrenceFrequency.daily;
      case 'WEEKLY':
        frequency = RecurrenceFrequency.weekly;
        final byday = parts
            .where((p) => p.startsWith('BYDAY='))
            .map((p) => p.substring(6))
            .firstOrNull;
        if (byday != null) {
          weekdays = byday
              .split(',')
              .map(_dayCodeToIndex)
              .where((d) => d >= 0)
              .toList();
        }
      case 'MONTHLY':
        frequency = RecurrenceFrequency.monthly;
        final bymonthday = parts
            .where((p) => p.startsWith('BYMONTHDAY='))
            .map((p) => int.tryParse(p.substring(11)))
            .where((d) => d != null)
            .firstOrNull;
        monthDay = bymonthday;
      case 'YEARLY':
        frequency = RecurrenceFrequency.yearly;
      default:
        // Obsidian-Kurzformen
        switch (freq.toLowerCase()) {
          case 'daily' || 'täglich':
            frequency = RecurrenceFrequency.daily;
          case 'weekly' || 'wöchentlich':
            frequency = RecurrenceFrequency.weekly;
          case 'monthly' || 'monatlich':
            frequency = RecurrenceFrequency.monthly;
          case 'yearly' || 'jährlich':
            frequency = RecurrenceFrequency.yearly;
        }
    }
    if (frequency == null) return null;
    return RecurrenceRule(
        frequency: frequency, weekdays: weekdays, monthDay: monthDay);
  }

  /// Berechnet das nächste Fälligkeitsdatum ausgehend von [from].
  DateTime nextDate(DateTime from) {
    switch (frequency) {
      case RecurrenceFrequency.daily:
        return from.add(const Duration(days: 1));

      case RecurrenceFrequency.weekly:
        if (weekdays.isEmpty) {
          return from.add(const Duration(days: 7));
        }
        // Nächsten passenden Wochentag finden
        for (var i = 1; i <= 7; i++) {
          final candidate = from.add(Duration(days: i));
          // weekday: DateTime.monday=1, ..., DateTime.sunday=7
          // unsere Kodierung: 0=Mo, ..., 6=So
          final wd = candidate.weekday - 1;
          if (weekdays.contains(wd)) return candidate;
        }
        return from.add(const Duration(days: 7));

      case RecurrenceFrequency.monthly:
        final targetDay = monthDay ?? from.day;
        var year = from.year;
        var month = from.month + 1;
        if (month > 12) {
          month = 1;
          year++;
        }
        final lastDay = DateTime(year, month + 1, 0).day;
        final day = targetDay.clamp(1, lastDay);
        return DateTime(year, month, day);

      case RecurrenceFrequency.yearly:
        return DateTime(from.year + 1, from.month, from.day);
    }
  }

  // ── Hilfsmethoden ────────────────────────────────────────────────────────────

  static String _dayName(int d) =>
      const ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'][d.clamp(0, 6)];

  static String _dayCode(int d) =>
      const ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'][d.clamp(0, 6)];

  static int _dayCodeToIndex(String code) =>
      const {'MO': 0, 'TU': 1, 'WE': 2, 'TH': 3, 'FR': 4, 'SA': 5, 'SU': 6}[code.toUpperCase()] ?? -1;
}

/// Erstellt die nächste Instanz eines wiederkehrenden Tasks.
/// Gibt die neuen Companion-Daten zurück (ID ist neu generiert).
class RecurrenceHelper {
  /// Berechnet das nächste Fälligkeitsdatum für [taskId] anhand der gespeicherten
  /// Wiederholungsregel. Gibt null zurück wenn keine Regel vorhanden.
  static DateTime? nextDueDate(DateTime currentDue, String? rrule) {
    final rule = RecurrenceRule.fromRrule(rrule);
    if (rule == null) return null;
    return rule.nextDate(currentDue);
  }

  /// Generiert eine neue Series-ID (UUID).
  static String generateSeriesId() => 'series-${_uuid.v4()}';
}
