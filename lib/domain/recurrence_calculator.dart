import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Unterstützte Wiederholungsfrequenzen.
enum RecurrenceFrequency { minutely, hourly, daily, weekly, monthly, yearly }

/// RRULE-kompatible Wiederholungsregel mit Intervall, Tageszeit und Wochentags-Muster.
/// Intern als kompakter String gespeichert, z.B.:
///   DAILY                           → täglich
///   WEEKLY;INTERVAL=2;BYDAY=MO,WE   → jeden 2. Montag und Mittwoch
///   MONTHLY;BYMONTHDAY=15           → jeden 15. des Monats
///   MONTHLY;BYDAY=1MO               → erster Montag im Monat
///   HOURLY;INTERVAL=2               → alle 2 Stunden
///   MINUTELY;INTERVAL=30            → alle 30 Minuten
class RecurrenceRule {
  final RecurrenceFrequency frequency;

  /// Intervall: 1=jede, 2=jede zweite, usw.
  final int interval;

  /// Für WEEKLY: Wochentage (0=Mo, 1=Di, ..., 6=So). Leer = gleicher Wochentag.
  final List<int> weekdays;

  /// Für MONTHLY: Tag des Monats (1-31). Null = gleicher Tag wie Fälligkeitsdatum.
  final int? monthDay;

  /// Für MONTHLY: Nth weekday (z.B. 1=erster, -1=letzter). Kombiniert mit [nthWeekday].
  final int? nthOccurrence;

  /// Für MONTHLY: Wochentag (0=Mo, ..., 6=So) des nth-Patterns.
  final int? nthWeekday;

  /// Uhrzeit (Stunde 0-23, Minute 0-59). Null = keine Uhrzeit.
  final int? timeHour;
  final int? timeMinute;

  const RecurrenceRule({
    required this.frequency,
    this.interval = 1,
    this.weekdays = const [],
    this.monthDay,
    this.nthOccurrence,
    this.nthWeekday,
    this.timeHour,
    this.timeMinute,
  });

  String get label {
    final ivLabel = interval > 1 ? 'Alle $interval ' : '';
    switch (frequency) {
      case RecurrenceFrequency.minutely:
        return interval == 1 ? 'Jede Minute' : 'Alle $interval Minuten';
      case RecurrenceFrequency.hourly:
        return interval == 1 ? 'Stündlich' : 'Alle $interval Stunden';
      case RecurrenceFrequency.daily:
        return interval == 1 ? 'Täglich' : '${ivLabel}Tage';
      case RecurrenceFrequency.weekly:
        final days = weekdays.isEmpty ? '' : ' (${weekdays.map(_dayName).join(', ')})';
        return interval == 1 ? 'Wöchentlich$days' : '${ivLabel}Wochen$days';
      case RecurrenceFrequency.monthly:
        if (nthOccurrence != null && nthWeekday != null) {
          final nth = _nthLabel(nthOccurrence!);
          return '${interval == 1 ? 'Monatlich' : '${ivLabel}Monate'} ($nth ${_dayName(nthWeekday!)})';
        }
        if (monthDay != null) return '${interval == 1 ? 'Monatlich' : '${ivLabel}Monate'} (am $monthDay.)';
        return interval == 1 ? 'Monatlich' : '${ivLabel}Monate';
      case RecurrenceFrequency.yearly:
        return interval == 1 ? 'Jährlich' : '${ivLabel}Jahre';
    }
  }

  static String _nthLabel(int n) => switch (n) {
        1 => '1.',
        2 => '2.',
        3 => '3.',
        4 => '4.',
        -1 => 'letzten',
        _ => '$n.',
      };

  String toRrule() {
    final parts = <String>[];
    switch (frequency) {
      case RecurrenceFrequency.minutely: parts.add('MINUTELY');
      case RecurrenceFrequency.hourly:   parts.add('HOURLY');
      case RecurrenceFrequency.daily:    parts.add('DAILY');
      case RecurrenceFrequency.weekly:
        parts.add('WEEKLY');
        if (weekdays.isNotEmpty) parts.add('BYDAY=${weekdays.map(_dayCode).join(',')}');
      case RecurrenceFrequency.monthly:
        parts.add('MONTHLY');
        if (nthOccurrence != null && nthWeekday != null) {
          parts.add('BYDAY=$nthOccurrence${_dayCode(nthWeekday!)}');
        } else if (monthDay != null) {
          parts.add('BYMONTHDAY=$monthDay');
        }
      case RecurrenceFrequency.yearly: parts.add('YEARLY');
    }
    if (interval > 1) parts.add('INTERVAL=$interval');
    if (timeHour != null && timeMinute != null) {
      parts.add('BYHOUR=$timeHour');
      parts.add('BYMINUTE=$timeMinute');
    }
    return parts.join(';');
  }

  static RecurrenceRule? fromRrule(String? rrule) {
    if (rrule == null || rrule.isEmpty) return null;
    final parts = rrule.split(';');
    final freqStr = parts.first.trim().toUpperCase();

    RecurrenceFrequency? frequency;
    switch (freqStr) {
      case 'MINUTELY': frequency = RecurrenceFrequency.minutely;
      case 'HOURLY':   frequency = RecurrenceFrequency.hourly;
      case 'DAILY':    frequency = RecurrenceFrequency.daily;
      case 'WEEKLY':   frequency = RecurrenceFrequency.weekly;
      case 'MONTHLY':  frequency = RecurrenceFrequency.monthly;
      case 'YEARLY':   frequency = RecurrenceFrequency.yearly;
      default:
        switch (freqStr.toLowerCase()) {
          case 'daily'   || 'täglich':    frequency = RecurrenceFrequency.daily;
          case 'weekly'  || 'wöchentlich': frequency = RecurrenceFrequency.weekly;
          case 'monthly' || 'monatlich':  frequency = RecurrenceFrequency.monthly;
          case 'yearly'  || 'jährlich':   frequency = RecurrenceFrequency.yearly;
        }
    }
    if (frequency == null) return null;

    int interval = 1;
    List<int> weekdays = [];
    int? monthDay;
    int? nthOccurrence;
    int? nthWeekday;
    int? timeHour;
    int? timeMinute;

    for (final part in parts.skip(1)) {
      if (part.startsWith('INTERVAL=')) {
        interval = int.tryParse(part.substring(9)) ?? 1;
      } else if (part.startsWith('BYMONTHDAY=')) {
        monthDay = int.tryParse(part.substring(11));
      } else if (part.startsWith('BYHOUR=')) {
        timeHour = int.tryParse(part.substring(7));
      } else if (part.startsWith('BYMINUTE=')) {
        timeMinute = int.tryParse(part.substring(9));
      } else if (part.startsWith('BYDAY=')) {
        final byday = part.substring(6);
        // Nth weekday: e.g., '1MO' or '-1FR'
        final nthRe = RegExp(r'^(-?\d+)([A-Z]{2})$');
        if (byday.split(',').length == 1 && nthRe.hasMatch(byday)) {
          final m = nthRe.firstMatch(byday)!;
          nthOccurrence = int.tryParse(m.group(1)!);
          nthWeekday = _dayCodeToIndex(m.group(2)!);
        } else {
          weekdays = byday.split(',').map(_dayCodeToIndex)
              .where((d) => d >= 0).toList();
        }
      }
    }

    return RecurrenceRule(
      frequency: frequency,
      interval: interval,
      weekdays: weekdays,
      monthDay: monthDay,
      nthOccurrence: nthOccurrence,
      nthWeekday: nthWeekday,
      timeHour: timeHour,
      timeMinute: timeMinute,
    );
  }

  DateTime nextDate(DateTime from) {
    final eff = interval < 1 ? 1 : interval;
    switch (frequency) {
      case RecurrenceFrequency.minutely:
        return from.add(Duration(minutes: eff));
      case RecurrenceFrequency.hourly:
        return from.add(Duration(hours: eff));
      case RecurrenceFrequency.daily:
        return from.add(Duration(days: eff));

      case RecurrenceFrequency.weekly:
        if (weekdays.isEmpty) {
          return from.add(Duration(days: 7 * eff));
        }
        // Nächsten passenden Wochentag finden (innerhalb eff Wochen)
        for (var i = 1; i <= 7 * eff; i++) {
          final candidate = from.add(Duration(days: i));
          final wd = candidate.weekday - 1; // 0=Mo..6=So
          if (weekdays.contains(wd)) return candidate;
        }
        return from.add(Duration(days: 7 * eff));

      case RecurrenceFrequency.monthly:
        var year = from.year;
        var month = from.month + eff;
        while (month > 12) { month -= 12; year++; }
        if (nthOccurrence != null && nthWeekday != null) {
          return _nthWeekdayOfMonth(year, month, nthOccurrence!, nthWeekday!);
        }
        final targetDay = monthDay ?? from.day;
        final lastDay = DateTime(year, month + 1, 0).day;
        return DateTime(year, month, targetDay.clamp(1, lastDay));

      case RecurrenceFrequency.yearly:
        return DateTime(from.year + eff, from.month, from.day);
    }
  }

  /// Berechnet den nth Wochentag eines Monats (z.B. 1. Montag, -1. Freitag).
  static DateTime _nthWeekdayOfMonth(int year, int month, int nth, int wd) {
    if (nth > 0) {
      // nth >= 1: vorwärts suchen
      var day = DateTime(year, month, 1);
      int count = 0;
      while (day.month == month) {
        if (day.weekday - 1 == wd) {
          count++;
          if (count == nth) return day;
        }
        day = day.add(const Duration(days: 1));
      }
    } else {
      // nth < 0: rückwärts suchen (-1 = letzter)
      var day = DateTime(year, month + 1, 0); // letzter Tag
      int count = 0;
      while (day.month == month) {
        if (day.weekday - 1 == wd) {
          count--;
          if (count == nth) return day;
        }
        day = day.subtract(const Duration(days: 1));
      }
    }
    return DateTime(year, month, 1);
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
