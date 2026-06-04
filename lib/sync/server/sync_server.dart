import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import '../../../data/db/app_database.dart';
import 'routes/health_routes.dart';
import 'routes/pairing_routes.dart';
import 'routes/sync_routes.dart';

const kSyncPort = 8766;

class SyncServer {
  final AppDatabase db;
  final String deviceId;
  final String deviceName;

  HttpServer? _server;

  SyncServer({
    required this.db,
    required this.deviceId,
    required this.deviceName,
  });

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;

    final router = Router()
      ..mount('/', healthRouter(deviceId, deviceName))
      ..mount('/', pairingRouter(deviceId, deviceName))
      ..mount('/', syncRouter(db));

    final handler = Pipeline()
        .addMiddleware(_corsMiddleware())
        .addMiddleware(logRequests())
        .addHandler(router.call);

    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, kSyncPort);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Returns the current pairing code (generate a new one each call)
  String generatePairingCode() => generateAndStorePairingCode();

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
