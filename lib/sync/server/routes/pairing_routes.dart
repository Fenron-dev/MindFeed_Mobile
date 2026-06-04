import 'dart:convert';
import 'dart:math';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import '../sync_auth.dart';

class _PairingCode {
  final String code;
  final DateTime expiresAt;
  _PairingCode(this.code, this.expiresAt);
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

// Active pairing codes managed in-memory (short-lived, no persistence needed)
final _activeCodes = <_PairingCode>[];

String generateAndStorePairingCode() {
  // Expire old codes
  _activeCodes.removeWhere((c) => c.isExpired);
  final code = SyncAuth.generate6DigitCode();
  _activeCodes.add(_PairingCode(code, DateTime.now().add(const Duration(minutes: 5))));
  return code;
}

Router pairingRouter(String serverDeviceId, String serverDeviceName) {
  final router = Router();

  // POST /sync/pairing/claim — exchange 6-digit code for access + refresh tokens
  router.post('/sync/pairing/claim', (Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return Response(400,
          body: jsonEncode({'error': 'invalid_json'}),
          headers: {'content-type': 'application/json'});
    }

    final code = body['pairingCode'] as String?;
    final deviceName = body['deviceName'] as String? ?? 'Unbekanntes Gerät';

    _activeCodes.removeWhere((c) => c.isExpired);
    final match = _activeCodes.where((c) => c.code == code).firstOrNull;
    if (match == null) {
      return Response(403,
          body: jsonEncode({'error': 'invalid_or_expired_code'}),
          headers: {'content-type': 'application/json'});
    }
    _activeCodes.remove(match);

    final deviceId = 'dev-${_randomHex(8)}';
    final tokens = await SyncAuth.issueTokens(deviceId, deviceName);

    return Response.ok(
      jsonEncode({
        'accessToken': tokens.access,
        'refreshToken': tokens.refresh,
        'serverDeviceId': serverDeviceId,
        'serverName': serverDeviceName,
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  // POST /sync/pairing/refresh — renew access token using refresh token
  router.post('/sync/pairing/refresh', (Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return Response(400,
          body: jsonEncode({'error': 'invalid_json'}),
          headers: {'content-type': 'application/json'});
    }

    final refreshToken = body['refreshToken'] as String?;
    if (refreshToken == null) {
      return Response(400,
          body: jsonEncode({'error': 'missing_refresh_token'}),
          headers: {'content-type': 'application/json'});
    }

    final tokens = await SyncAuth.refreshTokens(refreshToken);
    if (tokens == null) {
      return Response(401,
          body: jsonEncode({'error': 'invalid_refresh_token'}),
          headers: {'content-type': 'application/json'});
    }

    return Response.ok(
      jsonEncode({'accessToken': tokens.access, 'refreshToken': tokens.refresh}),
      headers: {'content-type': 'application/json'},
    );
  });

  return router;
}

String _randomHex(int bytes) {
  final rng = Random.secure();
  final buf = List<int>.generate(bytes, (_) => rng.nextInt(256));
  return buf.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
