import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mindfeed_mobile/services/settings_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Sync-Bundle: Profile ohne Key, sync_-Keys ausgeschlossen', () async {
    SharedPreferences.setMockInitialValues({
      'llm_profiles': <String>[
        '{"id":"a","name":"OR","kind":"openrouter","base_url":"https://x","model":"m","has_api_key":true}'
      ],
      'llm_task_assignment': '{"enrichment":["a"]}',
      'sync_server_url': 'http://1.2.3.4:8765',
      'tag_radius': 8.0,
    });
    final bundle = await SettingsBackup.exportSyncBundle();
    final map = jsonDecode(bundle) as Map<String, dynamic>;
    final prefs = map['prefs'] as Map<String, dynamic>;

    // sync_-Keys sind ausgeschlossen
    expect(prefs.containsKey('sync_server_url'), isFalse);
    // Profil ist drin, aber has_api_key=false
    final profilesEnc = prefs['llm_profiles']['v'] as List;
    final p0 = jsonDecode('${profilesEnc.first}') as Map<String, dynamic>;
    expect(p0['has_api_key'], isFalse);
    expect(prefs.containsKey('llm_task_assignment'), isTrue);
    expect(prefs.containsKey('tag_radius'), isTrue);

    // Import in leere Prefs
    SharedPreferences.setMockInitialValues({});
    await SettingsBackup.importSyncBundle(bundle);
    final p = await SharedPreferences.getInstance();
    expect(p.getStringList('llm_profiles')?.length, 1);
    expect(p.getString('sync_server_url'), isNull);
  });
}
