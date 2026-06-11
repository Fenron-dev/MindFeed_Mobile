import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Regressionstest für NotificationService Fix C (#3):
/// Vor dem Fix wurde `tz.setLocalLocation(...)` nie aufgerufen, also blieb
/// `tz.local = UTC`. `schedule()` baut die Triggerzeit per
/// `tz.TZDateTime.from(when, tz.local)`. Auf der Darwin-Plattform (iOS/macOS)
/// werden daraus die Wall-Clock-Komponenten (Stunde/Minute) extrahiert und an
/// den Kalender-Trigger übergeben — d.h. eine falsche `tz.local`-Zone lässt die
/// Erinnerung um den UTC-Offset (hier Sommerzeit +2h) zu früh feuern.
void main() {
  tzdata.initializeTimeZones();

  final berlin = tz.getLocation('Europe/Berlin');
  // Nutzer plant Erinnerung auf 1. Juli 2026, 15:00 Berliner Wandzeit (CEST).
  final reminderInstant = tz.TZDateTime(berlin, 2026, 7, 1, 15, 0).toUtc();

  test('Bug: tz.local=UTC verschiebt die geplante Stunde (2h zu früh)', () {
    tz.setLocalLocation(tz.UTC);
    final scheduled = tz.TZDateTime.from(reminderInstant, tz.local);
    expect(scheduled.hour, 13, reason: '13:00 UTC statt geplanter 15:00');
  });

  test('Fix: tz.local=Geräte-Zone erhält die geplante Stunde', () {
    tz.setLocalLocation(berlin);
    final scheduled = tz.TZDateTime.from(reminderInstant, tz.local);
    expect(scheduled.hour, 15);
    expect(scheduled.timeZoneOffset, const Duration(hours: 2)); // CEST
  });
}
