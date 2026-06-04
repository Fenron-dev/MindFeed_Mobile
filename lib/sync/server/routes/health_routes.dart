import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Router healthRouter(String deviceId, String deviceName) {
  final router = Router();

  router.get('/health', (_) => Response.ok(
    jsonEncode({
      'status': 'ok',
      'deviceId': deviceId,
      'deviceName': deviceName,
      'app': 'mindfeed',
      'version': '1.0.0',
    }),
    headers: {'content-type': 'application/json'},
  ));

  return router;
}
