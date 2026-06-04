import 'dart:convert';
import 'dart:math';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import '../../core/secure_storage.dart';

const _kSecretKey = 'mindfeed_sync_jwt_secret';
const _kRefreshTokensKey = 'mindfeed_sync_refresh_tokens';
const _kClientAccessKey = 'mindfeed_sync_client_access';
const _kClientRefreshKey = 'mindfeed_sync_client_refresh';

const Duration _kAccessTtl = Duration(hours: 24);
const Duration _kRefreshTtl = Duration(days: 7);

class SyncAuth {
  // ── Server-side secret ────────────────────────────────────────────────────

  static Future<String> _getOrCreateSecret() async {
    String? secret = await secureRead(_kSecretKey);
    if (secret == null || secret.isEmpty) {
      final rng = Random.secure();
      final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
      secret = base64Url.encode(bytes);
      await secureWrite(_kSecretKey, secret);
    }
    return secret;
  }

  // ── Access / Refresh token pair ───────────────────────────────────────────

  static Future<({String access, String refresh})> issueTokens(
    String clientDeviceId,
    String clientDeviceName,
  ) async {
    final secret = await _getOrCreateSecret();

    final access = JWT({
      'sub': clientDeviceId,
      'name': clientDeviceName,
      'type': 'access',
    }).sign(SecretKey(secret), expiresIn: _kAccessTtl);

    final refresh = JWT({
      'sub': clientDeviceId,
      'name': clientDeviceName,
      'type': 'refresh',
    }).sign(SecretKey(secret), expiresIn: _kRefreshTtl);

    final stored = await _loadRefreshTokens();
    stored[clientDeviceId] = refresh;
    await _saveRefreshTokens(stored);

    return (access: access, refresh: refresh);
  }

  static Future<({String access, String refresh})?> refreshTokens(
    String refreshToken,
  ) async {
    try {
      final secret = await _getOrCreateSecret();
      final jwt = JWT.verify(refreshToken, SecretKey(secret));
      if (jwt.payload['type'] != 'refresh') return null;

      final deviceId = jwt.payload['sub'] as String;
      final stored = await _loadRefreshTokens();
      if (stored[deviceId] != refreshToken) return null;

      return issueTokens(deviceId, jwt.payload['name'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  // ── Access token verification ─────────────────────────────────────────────

  static Future<String?> verifyAccessToken(String token) async {
    try {
      final secret = await _getOrCreateSecret();
      final jwt = JWT.verify(token, SecretKey(secret));
      if (jwt.payload['type'] != 'access') return null;
      return jwt.payload['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Pairing code → 6-digit PIN ────────────────────────────────────────────

  static String generate6DigitCode() {
    final rng = Random.secure();
    return (rng.nextInt(1000000)).toString().padLeft(6, '0');
  }

  // ── Refresh token persistence (server-side) ───────────────────────────────

  static Future<Map<String, String>> _loadRefreshTokens() async {
    final raw = await secureRead(_kRefreshTokensKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveRefreshTokens(Map<String, String> tokens) async {
    await secureWrite(_kRefreshTokensKey, jsonEncode(tokens));
  }

  static Future<void> revokeClient(String clientDeviceId) async {
    final stored = await _loadRefreshTokens();
    stored.remove(clientDeviceId);
    await _saveRefreshTokens(stored);
  }

  // ── Client-side token storage ─────────────────────────────────────────────

  static Future<void> saveClientTokens(String access, String refresh) async {
    await secureWrite(_kClientAccessKey, access);
    await secureWrite(_kClientRefreshKey, refresh);
  }

  static Future<String?> loadClientAccessToken() =>
      secureRead(_kClientAccessKey);

  static Future<String?> loadClientRefreshToken() =>
      secureRead(_kClientRefreshKey);

  static Future<void> clearClientTokens() async {
    await secureDelete(_kClientAccessKey);
    await secureDelete(_kClientRefreshKey);
  }
}
