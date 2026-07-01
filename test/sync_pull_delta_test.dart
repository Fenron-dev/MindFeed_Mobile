import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/sync/server/routes/sync_routes.dart';

void main() {
  group('isInPullDelta (#25)', () {
    final since = DateTime.utc(2026, 6, 20, 12, 0, 0);

    test('Erstsync (since == null) liefert alles', () {
      expect(
        isInPullDelta(DateTime.utc(2020), DateTime.utc(2020), null),
        isTrue,
      );
    });

    test('spät gepushte Notiz mit altem updatedAt, aber neuem '
        'syncUpdatedAt landet im Delta (Kernfall des Bugs)', () {
      final altesUpdatedAt = DateTime.utc(2026, 6, 1); // vor dem Cursor
      final serverEmpfang = DateTime.utc(2026, 6, 25); // nach dem Cursor
      // Filterte man nach updatedAt, würde die Notiz übersprungen.
      expect(altesUpdatedAt.isAfter(since), isFalse);
      // Mit syncUpdatedAt erscheint sie korrekt.
      expect(isInPullDelta(serverEmpfang, altesUpdatedAt, since), isTrue);
    });

    test('frisch geänderte Notiz (beide nach Cursor) ist im Delta', () {
      final ts = DateTime.utc(2026, 6, 25);
      expect(isInPullDelta(ts, ts, since), isTrue);
    });

    test('unveränderte Notiz vor dem Cursor ist nicht im Delta', () {
      final ts = DateTime.utc(2026, 6, 10);
      expect(isInPullDelta(ts, ts, since), isFalse);
    });

    test('Altbestand ohne syncUpdatedAt fällt auf updatedAt zurück', () {
      expect(
        isInPullDelta(null, DateTime.utc(2026, 6, 25), since),
        isTrue,
        reason: 'neues updatedAt → im Delta',
      );
      expect(
        isInPullDelta(null, DateTime.utc(2026, 6, 10), since),
        isFalse,
        reason: 'altes updatedAt → nicht im Delta',
      );
    });
  });
}
