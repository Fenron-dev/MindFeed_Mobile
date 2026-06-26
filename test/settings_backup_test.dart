import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mindfeed_mobile/services/settings_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Export→Import stellt Einstellungen wieder her (richtiges Passwort)', () async {
    SharedPreferences.setMockInitialValues({
      'tag_radius': 12.0,
      'show_tasks_in_notes': false,
      'grid_tile_size': 200.0,
      'prop_templates': <String>['a', 'b'],
      'sync_auto_interval_minutes': 7,
    });

    final blob = await SettingsBackup.exportEncrypted('geheim');
    expect(blob, isNotEmpty);

    // Werte „zerstören"
    SharedPreferences.setMockInitialValues({});
    await SettingsBackup.importEncrypted(blob, 'geheim');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('tag_radius'), 12.0);
    expect(prefs.getBool('show_tasks_in_notes'), false);
    expect(prefs.getInt('sync_auto_interval_minutes'), 7);
    expect(prefs.getStringList('prop_templates'), ['a', 'b']);
  });

  test('falsches Passwort wirft', () async {
    SharedPreferences.setMockInitialValues({'grid_tile_size': 170.0});
    final blob = await SettingsBackup.exportEncrypted('richtig');
    expect(
      () => SettingsBackup.importEncrypted(blob, 'falsch'),
      throwsA(isA<Exception>()),
    );
  });

  test('geräte-spezifische Keys werden ausgeschlossen', () async {
    SharedPreferences.setMockInitialValues({
      'vault_path': '/Users/x/vault',
      'tag_radius': 9.0,
    });
    final blob = await SettingsBackup.exportEncrypted('pw');
    SharedPreferences.setMockInitialValues({});
    await SettingsBackup.importEncrypted(blob, 'pw');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('vault_path'), isNull); // ausgeschlossen
    expect(prefs.getDouble('tag_radius'), 9.0);
  });
}
