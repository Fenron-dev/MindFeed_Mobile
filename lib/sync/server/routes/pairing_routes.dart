import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import '../sync_server.dart';

Router pairingRouter(SyncServer server) {
  final router = Router();

  // POST /sync/pairing/claim — 6-stelligen Code gegen Access+Refresh-Token tauschen
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

    server.pairingCodes.removeWhere((c) => c.isExpired);
    final match = server.pairingCodes.where((c) => c.code == code).firstOrNull;
    if (match == null) {
      return Response(403,
          body: jsonEncode({'error': 'invalid_or_expired_code'}),
          headers: {'content-type': 'application/json'});
    }

    // Code erst nach erfolgreichem Token-Issue entfernen
    final deviceId = 'dev-${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';
    final tokens = server.issueTokens(deviceId, deviceName);
    server.pairingCodes.remove(match);

    return Response.ok(
      jsonEncode({
        'accessToken': tokens.access,
        'refreshToken': tokens.refresh,
        'serverDeviceId': server.deviceId,
        'serverName': server.deviceName,
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  // POST /sync/pairing/refresh — Access-Token erneuern
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

    final tokens = server.refreshTokensFor(refreshToken);
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
