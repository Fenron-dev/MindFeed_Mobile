import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import '../../core/secure_storage.dart';
import '../../data/db/app_database.dart';
import 'routes/health_routes.dart';
import 'routes/pairing_routes.dart';
import 'routes/sync_routes.dart';

const kSyncPort = 8766;

const _kServerJwtSecret    = 'sync_server_jwt_secret';
const _kServerRefreshTokens = 'sync_server_refresh_tokens';
const _kServerClients      = 'sync_server_clients';

class SyncClientInfo {
  final String deviceId;
  final String deviceName;
  final String remoteIp;
  final DateTime connectedAt;
  const SyncClientInfo({
    required this.deviceId,
    required this.deviceName,
    required this.remoteIp,
    required this.connectedAt,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'connectedAt': connectedAt.toIso8601String(),
      };
}

/// In-memory Pairing-Code Eintrag (5 Minuten gültig)
class PairingCode {
  final String code;
  final DateTime expiresAt;
  PairingCode(this.code) : expiresAt = DateTime.now().add(const Duration(minutes: 5));
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class SyncServer {
  // ── Singleton — überlebt ProviderScope-Rebuilds nach onRestartApp ────────
  // Verhindert doppeltes Port-Binding und stellt sicher, dass pairingCodes
  // immer in derselben Instanz liegen wie der HTTP-Handler.
  static SyncServer? _singleton;

  static SyncServer getInstance({
    required AppDatabase db,
    required String deviceId,
    required String deviceName,
  }) {
    if (_singleton == null) {
      _singleton = SyncServer._(db: db, deviceId: deviceId, deviceName: deviceName);
    } else {
      // DB-Referenz nach Vault-Wechsel aktualisieren
      _singleton!._db = db;
    }
    return _singleton!;
  }

  AppDatabase _db;
  AppDatabase get db => _db;
  final String deviceId;
  final String deviceName;

  HttpServer? _server;

  // In-memory Auth — wird beim start() aus SecureStorage geladen,
  // damit HTTP-Handler nie Platform-Channels aufrufen
  String _jwtSecret = '';
  final pairingCodes  = <PairingCode>[];
  final refreshTokens = <String, String>{};
  final connectedClients = <SyncClientInfo>[];

  SyncServer._({
    required AppDatabase db,
    required this.deviceId,
    required this.deviceName,
  }) : _db = db;

  bool get isRunning => _server != null;

  // ── Auth laden/speichern (vor HTTP-Start, sicher auf Main-Isolate) ─────────

  Future<void> _loadPersistedAuth() async {
    // JWT-Secret laden oder erstellen
    var secret = await secureRead(_kServerJwtSecret);
    if (secret == null || secret.isEmpty) {
      secret = base64Url.encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
      await secureWrite(_kServerJwtSecret, secret);
    }
    _jwtSecret = secret;

    // Refresh-Tokens wiederherstellen
    final tokensJson = await secureRead(_kServerRefreshTokens);
    if (tokensJson != null) {
      try {
        final map = jsonDecode(tokensJson) as Map<String, dynamic>;
        refreshTokens.addAll(map.cast<String, String>());
      } catch (_) {}
    }

    // Bekannte Clients wiederherstellen (IPs ändern sich, werden als 'gespeichert' markiert)
    final clientsJson = await secureRead(_kServerClients);
    if (clientsJson != null) {
      try {
        final list = jsonDecode(clientsJson) as List<dynamic>;
        for (final item in list) {
          connectedClients.add(SyncClientInfo(
            deviceId:   item['deviceId'] as String,
            deviceName: item['deviceName'] as String,
            remoteIp:   '(gespeichert)',
            connectedAt: DateTime.parse(item['connectedAt'] as String),
          ));
        }
      } catch (_) {}
    }
  }

  Future<void> _persistRefreshTokens() async {
    await secureWrite(_kServerRefreshTokens, jsonEncode(refreshTokens));
  }

  Future<void> _persistClients() async {
    await secureWrite(
      _kServerClients,
      jsonEncode(connectedClients.map((c) => c.toJson()).toList()),
    );
  }

  // ── Token-Operationen ──────────────────────────────────────────────────────

  ({String access, String refresh}) issueTokens(String clientDeviceId, String clientDeviceName) {
    final access = JWT({
      'sub': clientDeviceId,
      'name': clientDeviceName,
      'type': 'access',
    }).sign(SecretKey(_jwtSecret), expiresIn: const Duration(hours: 24));

    final refresh = JWT({
      'sub': clientDeviceId,
      'name': clientDeviceName,
      'type': 'refresh',
    }).sign(SecretKey(_jwtSecret), expiresIn: const Duration(days: 30));

    refreshTokens[clientDeviceId] = refresh;
    _persistRefreshTokens(); // fire-and-forget
    return (access: access, refresh: refresh);
  }

  ({String access, String refresh})? refreshTokensFor(String refreshToken) {
    try {
      final jwt = JWT.verify(refreshToken, SecretKey(_jwtSecret));
      if (jwt.payload['type'] != 'refresh') return null;
      final clientDeviceId = jwt.payload['sub'] as String;
      if (refreshTokens[clientDeviceId] != refreshToken) return null;
      return issueTokens(clientDeviceId, jwt.payload['name'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  String? verifyAccessToken(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(_jwtSecret));
      if (jwt.payload['type'] != 'access') return null;
      return jwt.payload['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Client-Verwaltung ──────────────────────────────────────────────────────

  void registerClient(String deviceId, String deviceName, String remoteIp) {
    connectedClients.removeWhere((c) => c.deviceId == deviceId);
    connectedClients.add(SyncClientInfo(
      deviceId: deviceId,
      deviceName: deviceName,
      remoteIp: remoteIp,
      connectedAt: DateTime.now(),
    ));
    _persistClients(); // fire-and-forget
  }

  // ── Pairing-Code Verwaltung ────────────────────────────────────────────────

  String generatePairingCode() {
    pairingCodes.removeWhere((c) => c.isExpired);
    final code = (Random.secure().nextInt(1000000)).toString().padLeft(6, '0');
    pairingCodes.add(PairingCode(code));
    return code;
  }

  // ── Server Start/Stop ──────────────────────────────────────────────────────

  Future<void> start() async {
    if (_server != null) return;

    // Auth aus SecureStorage laden BEVOR der HTTP-Server startet
    await _loadPersistedAuth();

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
