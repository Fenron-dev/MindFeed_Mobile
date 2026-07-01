import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mindfeed_mobile/services/app_settings.dart';
import 'package:mindfeed_mobile/services/settings_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings Sync-Server-Cursor (#25)', () {
    test('Default null, wenn noch nie gesetzt', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      expect(AppSettings.getSyncServerCursor(), isNull);
    });

    test('Round-Trip: gespeichert wird als UTC-ISO, get liefert denselben '
        'Zeitpunkt', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      final dt = DateTime.utc(2026, 6, 30, 10, 15, 0);
      await AppSettings.saveSyncServerCursor(dt);
      expect(AppSettings.getSyncServerCursor(), dt);
    });

    test('ist unabhängig von lastSyncAt (getrennte Cursor)', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      final local = DateTime.utc(2026, 6, 30, 12, 0, 0);
      final server = DateTime.utc(2026, 6, 30, 9, 0, 0);
      await AppSettings.saveLastSyncAt(local);
      await AppSettings.saveSyncServerCursor(server);
      expect(AppSettings.getLastSyncAt(), local);
      expect(AppSettings.getSyncServerCursor(), server);
    });
  });

  group('Server-Cursor ist gerätespezifisch (#25)', () {
    test('nicht im Sync-Bundle (sync_-Präfix)', () async {
      SharedPreferences.setMockInitialValues({
        'sync_server_cursor': DateTime.utc(2026, 6, 30).toIso8601String(),
        'tag_radius': 8.0,
      });
      final bundle = await SettingsBackup.exportSyncBundle();
      final prefs =
          (jsonDecode(bundle) as Map<String, dynamic>)['prefs'] as Map;
      expect(prefs.containsKey('sync_server_cursor'), isFalse);
      expect(prefs.containsKey('tag_radius'), isTrue);
    });

    test('nicht im verschlüsselten Backup (in _prefsExclude)', () async {
      SharedPreferences.setMockInitialValues({
        'sync_server_cursor': DateTime.utc(2026, 6, 30).toIso8601String(),
        'tag_radius': 8.0,
      });
      final blob = await SettingsBackup.exportEncrypted('pw');
      SharedPreferences.setMockInitialValues({});
      await SettingsBackup.importEncrypted(blob, 'pw');
      final p = await SharedPreferences.getInstance();
      expect(p.getString('sync_server_cursor'), isNull);
      expect(p.getDouble('tag_radius'), 8.0);
    });
  });
}
