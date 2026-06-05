import 'dart:convert';
import 'package:http/http.dart' as http;
import '../dto/sync_dto.dart';
import '../server/sync_auth.dart';

class SyncApiClient {
  final String baseUrl;

  SyncApiClient(this.baseUrl);

  // ── Token management ───────────────────────────────────────────────────────

  Future<Map<String, String>> _authHeaders() async {
    var token = await SyncAuth.loadClientAccessToken();
    if (token == null) throw SyncException('Nicht gepaart. Bitte zuerst mit einem Server verbinden.');
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  Future<http.Response> _get(String path, {Map<String, String>? queryParams}) async {
    final headers = await _authHeaders();
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: queryParams);
    final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 30));
    if (resp.statusCode == 401) await _tryRefresh();
    return resp;
  }

  Future<http.Response> _post(String path, Object body) async {
    final headers = await _authHeaders();
    final uri = Uri.parse('$baseUrl$path');
    return http.post(uri, headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 60));
  }

  Future<void> _tryRefresh() async {
    final refresh = await SyncAuth.loadClientRefreshToken();
    if (refresh == null) return;
    try {
      final uri = Uri.parse('$baseUrl/sync/pairing/refresh');
      final resp = await http.post(uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refreshToken': refresh}));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        await SyncAuth.saveClientTokens(
          data['accessToken'] as String,
          data['refreshToken'] as String,
        );
      }
    } catch (_) {}
  }

  // ── Health check ───────────────────────────────────────────────────────────

  Future<SyncPeer> health() async {
    final uri = Uri.parse('$baseUrl/health');
    final resp = await http.get(uri).timeout(const Duration(seconds: 5));
    _checkStatus(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return SyncPeer(
      deviceId: data['deviceId'] as String,
      deviceName: data['deviceName'] as String? ?? '',
      host: uri.host,
      port: uri.port,
      paired: true,
    );
  }

  // ── Pairing ────────────────────────────────────────────────────────────────

  Future<({String serverDeviceId, String serverName})> claimPairingCode(
    String code,
    String myDeviceName,
  ) async {
    final uri = Uri.parse('$baseUrl/sync/pairing/claim');
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'pairingCode': code, 'deviceName': myDeviceName}),
    ).timeout(const Duration(seconds: 10));
    _checkStatus(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    await SyncAuth.saveClientTokens(
      data['accessToken'] as String,
      data['refreshToken'] as String,
    );
    return (
      serverDeviceId: data['serverDeviceId'] as String,
      serverName: data['serverName'] as String? ?? '',
    );
  }

  // ── Pull ───────────────────────────────────────────────────────────────────

  Future<SyncPullResponse> pull({DateTime? since}) async {
    final queryParams = since != null
        ? {'since': since.toUtc().toIso8601String()}
        : null;
    final resp = await _get('/sync/pull', queryParams: queryParams);
    _checkStatus(resp);
    return SyncPullResponse.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  // ── Push ───────────────────────────────────────────────────────────────────

  Future<SyncPushResponse> push(SyncPushRequest request) async {
    final resp = await _post('/sync/push',
        jsonDecode(request.toJsonString()) as Map<String, dynamic>);
    _checkStatus(resp);
    return SyncPushResponse.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  // ── Attachment download ────────────────────────────────────────────────────

  Future<List<int>> downloadAttachment(String attachmentId) async {
    final headers = await _authHeaders();
    final uri = Uri.parse('$baseUrl/sync/attachments/$attachmentId');
    final resp = await http.get(uri, headers: headers)
        .timeout(const Duration(minutes: 5));
    _checkStatus(resp);
    return resp.bodyBytes;
  }

  Future<void> uploadAttachment(String attachmentId, List<int> bytes, String mimeType) async {
    final tokenHeaders = await _authHeaders();
    final uploadHeaders = {...tokenHeaders, 'Content-Type': mimeType};
    final uri = Uri.parse('$baseUrl/sync/attachments/$attachmentId');
    final resp = await http.post(uri, headers: uploadHeaders, body: bytes)
        .timeout(const Duration(minutes: 10));
    _checkStatus(resp);
  }

  /// Pollt ob der Server einen Sync ausgelöst hat.
  Future<DateTime?> getServerSyncNotification() async {
    try {
      final headers = await _authHeaders();
      final uri = Uri.parse('$baseUrl/sync/notification');
      final resp = await http.get(uri, headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final ts = data['requestedAt'] as String?;
        return ts != null ? DateTime.tryParse(ts) : null;
      }
    } catch (_) {}
    return null;
  }

  void _checkStatus(http.Response resp) {
    if (resp.statusCode >= 400) {
      String msg;
      try {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        msg = data['error'] as String? ?? 'Unbekannter Fehler';
      } catch (_) {
        msg = 'HTTP ${resp.statusCode}';
      }
      throw SyncException(msg, statusCode: resp.statusCode);
    }
  }
}

class SyncException implements Exception {
  final String message;
  final int? statusCode;
  const SyncException(this.message, {this.statusCode});

  @override
  String toString() => 'SyncException: $message';
}
