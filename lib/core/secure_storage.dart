import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// macOS data-protection Keychain erfordert keychain-access-groups-Entitlement
// mit gültigem Provisioning-Profil (Team-ID). Für lokale Desktop-Builds nutzen
// wir SharedPreferences — die App-Sandbox isoliert die Daten ausreichend.

const _secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

Future<String?> secureRead(String key) async {
  if (Platform.isMacOS) {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('_sec_$key');
  }
  return _secureStorage.read(key: key);
}

Future<void> secureWrite(String key, String value) async {
  if (Platform.isMacOS) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('_sec_$key', value);
    return;
  }
  await _secureStorage.write(key: key, value: value);
}

Future<void> secureDelete(String key) async {
  if (Platform.isMacOS) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('_sec_$key');
    return;
  }
  await _secureStorage.delete(key: key);
}
