import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/secure_storage.dart';

/// Passwortgeschützter Export/Import **nur der Einstellungen + Keys** (keine
/// Notiz-Inhalte). Inhalte liegen in der Vault-DB und werden separat gesichert.
///
/// Verschlüsselung: AES-256-GCM, Schlüssel via PBKDF2-HMAC-SHA256 aus dem
/// Passwort. Format (Base64): magic(4) | ver(1) | salt(16) | iv(12) | ciphertext.
class SettingsBackup {
  static const _magic = [0x4D, 0x46, 0x53, 0x42]; // "MFSB"
  static const _version = 1;
  static const _pbkdf2Iterations = 120000;

  /// Bekannte Secure-Storage-Keys (zusätzlich kommen die Profil-Keys dynamisch).
  static const _secureKeys = [
    'openrouter_api_key',
    'openrouter_model',
    'openrouter_temperature',
    'openrouter_max_tokens',
    'openrouter_max_input_chars',
    'groq_api_key',
    'tmdb_api_key',
    'omdb_api_key',
    'youtube_api_key',
    'searxng_base_url',
    'brave_api_key',
  ];

  /// SharedPreferences-Keys, die geräte-/inhaltsspezifisch sind und NICHT
  /// exportiert werden (Pfade, Sync-IDs, Zeitstempel).
  static const _prefsExclude = {
    'vault_path',
    'recent_vaults',
    'sync_device_id',
    'sync_last_sync_at',
    'sync_server_cursor',
    'auto_backup_last_at',
    'auto_backup_dir',
  };

  // ── Export ─────────────────────────────────────────────────────────────────

  static Future<String> exportEncrypted(String password) async {
    final prefs = await SharedPreferences.getInstance();
    final prefsMap = <String, dynamic>{};
    for (final k in prefs.getKeys()) {
      if (k.startsWith('_sec_')) continue; // macOS-Secure-Spiegel
      if (_prefsExclude.contains(k)) continue;
      final v = prefs.get(k);
      prefsMap[k] = _encodePref(v);
    }

    final secureMap = <String, String>{};
    for (final k in [..._secureKeys, ..._profileKeyRefs(prefs)]) {
      try {
        final v = await secureRead(k);
        if (v != null && v.isNotEmpty) secureMap[k] = v;
      } catch (_) {/* Secure-Storage nicht verfügbar → überspringen */}
    }

    final payload = utf8.encode(jsonEncode({
      'prefs': prefsMap,
      'secure': secureMap,
    }));

    final salt = _randomBytes(16);
    final iv = _randomBytes(12);
    final key = _deriveKey(password, salt);
    final cipherText = _gcm(true, key, iv, Uint8List.fromList(payload));

    final out = BytesBuilder()
      ..add(_magic)
      ..addByte(_version)
      ..add(salt)
      ..add(iv)
      ..add(cipherText);
    return base64Encode(out.toBytes());
  }

  // ── Import ─────────────────────────────────────────────────────────────────

  /// Wirft bei falschem Passwort/kaputter Datei eine Exception.
  static Future<void> importEncrypted(String data, String password) async {
    final trimmed = data.trim();
    // ZIP-Inhalts-Backup („PK"-Signatur) ist KEINE Einstellungssicherung.
    if (trimmed.startsWith('PK')) {
      throw Exception(
          'Das ist ein ZIP-Inhalts-Backup, keine Einstellungssicherung. Bitte die .mfbak-Datei wählen.');
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(trimmed);
    } catch (_) {
      throw Exception('Keine gültige Einstellungssicherung (.mfbak).');
    }
    if (bytes.length < 4 + 1 + 16 + 12 + 16) {
      throw Exception('Datei zu kurz/ungültig.');
    }
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) {
        throw const FormatException('Keine MindFeed-Einstellungsdatei.');
      }
    }
    final salt = bytes.sublist(5, 21);
    final iv = bytes.sublist(21, 33);
    final cipherText = bytes.sublist(33);
    final key = _deriveKey(password, salt);

    final Uint8List plain;
    try {
      plain = _gcm(false, key, iv, Uint8List.fromList(cipherText));
    } catch (_) {
      throw Exception('Falsches Passwort oder beschädigte Datei.');
    }
    final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;

    final prefs = await SharedPreferences.getInstance();
    final prefsMap = (map['prefs'] as Map<String, dynamic>? ?? {});
    for (final e in prefsMap.entries) {
      await _writePref(prefs, e.key, e.value);
    }
    final secureMap = (map['secure'] as Map<String, dynamic>? ?? {});
    for (final e in secureMap.entries) {
      try {
        await secureWrite(e.key, '${e.value}');
      } catch (_) {/* Secure-Storage nicht verfügbar */}
    }
  }

  // ── Sync-Bundle (ohne API-Keys, unverschlüsselt) ────────────────────────────

  /// Baut ein Einstellungs-Bundle für die Geräte-Synchronisation: LLM-Profile
  /// (ohne Keys), Ketten, SearXNG-URL und sonstige Nicht-Geheim-Einstellungen.
  /// **Enthält keine API-Keys** und keine geräte-/sync-spezifischen Werte.
  static Future<String> exportSyncBundle() async {
    final prefs = await SharedPreferences.getInstance();
    final prefsMap = <String, dynamic>{};
    for (final k in prefs.getKeys()) {
      if (k.startsWith('_sec_')) continue;
      if (k.startsWith('sync_')) continue; // geräte-spezifische Sync-Config
      if (_prefsExclude.contains(k)) continue;
      if (k == 'llm_migrated_from_openrouter') continue;
      var v = prefs.get(k);
      // Profile mit übertragen, aber has_api_key=false (Keys bleiben lokal).
      if (k == 'llm_profiles' && v is List) {
        v = v.map((s) {
          try {
            final m = jsonDecode('$s') as Map<String, dynamic>;
            m['has_api_key'] = false;
            return jsonEncode(m);
          } catch (_) {
            return s;
          }
        }).toList();
      }
      prefsMap[k] = _encodePref(v);
    }
    String? searx;
    try {
      searx = await secureRead('searxng_base_url');
    } catch (_) {}
    return jsonEncode({'prefs': prefsMap, if (searx != null) 'searxng': searx});
  }

  /// Wendet ein Sync-Bundle an (keine Keys). SearXNG-URL wird übernommen.
  static Future<void> importSyncBundle(String json) async {
    final map = jsonDecode(json) as Map<String, dynamic>;
    final prefs = await SharedPreferences.getInstance();
    for (final e in (map['prefs'] as Map<String, dynamic>? ?? {}).entries) {
      await _writePref(prefs, e.key, e.value);
    }
    final searx = map['searxng'];
    if (searx is String && searx.isNotEmpty) {
      try {
        await secureWrite('searxng_base_url', searx);
      } catch (_) {}
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static List<String> _profileKeyRefs(SharedPreferences prefs) {
    final raw = prefs.getStringList('llm_profiles') ?? [];
    final refs = <String>[];
    for (final s in raw) {
      try {
        final id = (jsonDecode(s) as Map<String, dynamic>)['id'];
        if (id is String) refs.add('llm_profile_${id}_apikey');
      } catch (_) {}
    }
    return refs;
  }

  static Map<String, dynamic> _encodePref(dynamic v) {
    if (v is bool) return {'t': 'b', 'v': v};
    if (v is int) return {'t': 'i', 'v': v};
    if (v is double) return {'t': 'd', 'v': v};
    if (v is List) return {'t': 'ls', 'v': v.map((e) => '$e').toList()};
    return {'t': 's', 'v': '$v'};
  }

  static Future<void> _writePref(
      SharedPreferences prefs, String key, dynamic enc) async {
    if (enc is! Map) return;
    final t = enc['t'];
    final v = enc['v'];
    switch (t) {
      case 'b':
        await prefs.setBool(key, v == true);
        break;
      case 'i':
        await prefs.setInt(key, (v as num).toInt());
        break;
      case 'd':
        await prefs.setDouble(key, (v as num).toDouble());
        break;
      case 'ls':
        await prefs.setStringList(key, (v as List).map((e) => '$e').toList());
        break;
      default:
        await prefs.setString(key, '$v');
    }
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static Uint8List _deriveKey(String password, Uint8List salt) {
    final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _pbkdf2Iterations, 32));
    return d.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Uint8List _gcm(
      bool encrypt, Uint8List key, Uint8List iv, Uint8List input) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(encrypt, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    return cipher.process(input);
  }
}
