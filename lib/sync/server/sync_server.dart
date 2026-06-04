import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import '../../data/db/app_database.dart';
import 'routes/health_routes.dart';
import 'routes/pairing_routes.dart';
import 'routes/sync_routes.dart';

const kSyncPort = 8766;

/// In-memory Pairing-Code Eintrag (5 Minuten gültig)
class PairingCode {
  final String code;
  final DateTime expiresAt;
  PairingCode(this.code) : expiresAt = DateTime.now().add(const Duration(minutes: 5));
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class SyncServer {
  final AppDatabase db;
  final String deviceId;
  final String deviceName;

  HttpServer? _server;

  // ── In-memory Auth-Zustand (kein FlutterSecureStorage in HTTP-Handlern) ──
  late final String jwtSecret;
  final pairingCodes = <PairingCode>[];
  final refreshTokens = <String, String>{}; // clientDeviceId → refreshToken

  SyncServer({
    required this.db,
    required this.deviceId,
    required this.deviceName,
  }) {
    // JWT-Secret einmalig beim Erstellen generieren
    final rng = Random.secure();
    jwtSecret = base64Url.encode(List<int>.generate(32, (_) => rng.nextInt(256)));
  }

  bool get isRunning => _server != null;

  // ── Token-Operationen (in-memory, kein Platform-Channel) ─────────────────

  ({String access, String refresh}) issueTokens(String clientDeviceId, String clientDeviceName) {
    final access = JWT({
      'sub': clientDeviceId,
      'name': clientDeviceName,
      'type': 'access',
    }).sign(SecretKey(jwtSecret), expiresIn: const Duration(hours: 24));

    final refresh = JWT({
      'sub': clientDeviceId,
      'name': clientDeviceName,
      'type': 'refresh',
    }).sign(SecretKey(jwtSecret), expiresIn: const Duration(days: 7));

    refreshTokens[clientDeviceId] = refresh;
    return (access: access, refresh: refresh);
  }

  ({String access, String refresh})? refreshTokensFor(String refreshToken) {
    try {
      final jwt = JWT.verify(refreshToken, SecretKey(jwtSecret));
      if (jwt.payload['type'] != 'refresh') return null;
      final clientDeviceId = jwt.payload['sub'] as String;
      if (refreshTokens[clientDeviceId] != refreshToken) return null;
      return issueTokens(clientDeviceId, jwt.payload['name'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Validiert Bearer-Token und gibt clientDeviceId zurück, sonst null.
  String? verifyAccessToken(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(jwtSecret));
      if (jwt.payload['type'] != 'access') return null;
      return jwt.payload['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Pairing-Code Verwaltung ───────────────────────────────────────────────

  String generatePairingCode() {
    pairingCodes.removeWhere((c) => c.isExpired);
    final code = (Random.secure().nextInt(1000000)).toString().padLeft(6, '0');
    pairingCodes.add(PairingCode(code));
    return code;
  }

  // ── Server Start/Stop ─────────────────────────────────────────────────────

  Future<void> start() async {
    if (_server != null) return;

    final router = Router()
      ..mount('/', healthRouter(deviceId, deviceName))
      ..mount('/', pairingRouter(this))
      ..mount('/', syncRouter(db, this));

    final handler = Pipeline()
        .addMiddleware(_corsMiddleware())
        .addHandler(router.call);

    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, kSyncPort);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Middleware _corsMiddleware() {
    return (Handler inner) {
      return (Request req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders);
        }
        final resp = await inner(req);
        return resp.change(headers: _corsHeaders);
      };
    };
  }

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
  };
}
