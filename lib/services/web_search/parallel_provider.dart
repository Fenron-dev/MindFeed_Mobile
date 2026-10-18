import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'web_search_provider.dart';

/// Anonyme Web-Recherche über Parallel Search MCP (Fast-Modus).
/// Nutzt das bestehende HTTP-Paket für den Streamable-HTTP-Transport.
class ParallelProvider implements WebSearchProvider {
  const ParallelProvider({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;
  static final endpoint = Uri.parse('https://search.parallel.ai/mcp');
  static const userAgent =
      'MindFeed-Mobile/1.5.0 (+https://github.com/Fenron-dev/MindFeed_Mobile)';

  Future<T> _connected<T>(Future<T> Function(_McpConnection) action) async {
    final client = http.Client();
    try {
      return await (() async {
        final connection = _McpConnection(client);
        await connection.initialize();
        return action(connection);
      })().timeout(timeout);
    } finally {
      // Auch bei Timeout/Abbruch keine weiterlaufende Verbindung behalten.
      client.close();
    }
  }

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    String language = 'de',
    int limit = 8,
  }) async {
    if (limit <= 0) return [];
    final text = query.trim();
    if (text.isEmpty) throw ArgumentError('Suchbegriff fehlt');
    return _connected((connection) async {
      final result = await connection.request('tools/call', {
        'name': 'web_search',
        'arguments': {
          'objective':
              'Recherchiere zuverlässige Quellen zu: $text.'
              '${language.isEmpty ? '' : ' Bevorzugte Sprache: $language.'}',
          'search_queries': [text],
          // Eine Recherche ist ein eigenständiger Vorgang, kein neuer Wert
          // bei einem Retry. Es gibt hier bewusst keine automatischen Retries.
          'session_id': const Uuid().v4(),
        },
      });
      if (result['isError'] == true) {
        throw Exception('Parallel: Recherche fehlgeschlagen');
      }
      dynamic data = result['structuredContent'];
      if (data == null) {
        final content = result['content'];
        if (content is List) {
          for (final block in content) {
            if (block is Map && block['type'] == 'text') {
              try {
                data = jsonDecode(block['text'] as String);
              } on FormatException {
                continue;
              }
              if (data is Map && data['results'] is List) break;
            }
          }
        }
      }
      if (data is! Map || data['results'] is! List) {
        throw const FormatException('Parallel: ungültige Suchantwort');
      }
      final results = <WebSearchResult>[];
      for (final item in data['results'] as List) {
        if (item is! Map || item['url'] is! String) continue;
        final url = (item['url'] as String).trim();
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !uri.hasAuthority ||
            uri.host.isEmpty ||
            !const ['http', 'https'].contains(uri.scheme)) {
          continue;
        }
        results.add(
          WebSearchResult(
            title: item['title'] is String ? item['title'] as String : url,
            url: url,
            content: item['excerpts'] is List
                ? (item['excerpts'] as List).whereType<String>().join('\n')
                : '',
          ),
        );
        if (results.length >= limit) break;
      }
      return results;
    });
  }

  @override
  Future<String?> testConnection() async {
    try {
      await _connected((connection) async {
        final result = await connection.request('tools/list', {});
        final tools = result['tools'];
        if (tools is! List ||
            !tools.any((t) => t is Map && t['name'] == 'web_search')) {
          throw const FormatException('Parallel: Suchwerkzeug fehlt');
        }
      });
      return null;
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }
}

/// Schmaler MCP-Client für die fest eingebauten Recherche-Aufrufe.
/// JSON und SSE sind beide zulässige Streamable-HTTP-Antworten.
class _McpConnection {
  _McpConnection(this.client);
  final http.Client client;
  static const _protocolVersion = '2025-03-26';
  int _nextId = 0;
  String? _session;
  bool _initialized = false;

  Future<void> initialize() async {
    final result = await request('initialize', {
      'protocolVersion': _protocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'mindfeed-mobile', 'version': '1.5.0'},
    });
    if (result['protocolVersion'] != _protocolVersion) {
      throw const FormatException('Parallel: nicht unterstützte MCP-Version');
    }
    _initialized = true;
    final response = await _send({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    await response.stream.drain<void>();
  }

  Future<http.StreamedResponse> _send(Map<String, dynamic> body) async {
    final request = http.Request('POST', ParallelProvider.endpoint)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'User-Agent': ParallelProvider.userAgent,
        if (_initialized) 'MCP-Protocol-Version': _protocolVersion,
        'Mcp-Session-Id': ?_session,
      })
      ..body = jsonEncode(body);
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw Exception(
        response.statusCode == 429
            ? 'Parallel: Rate-Limit erreicht. Bitte später erneut versuchen.'
            : 'Parallel HTTP ${response.statusCode}',
      );
    }
    _session = response.headers['mcp-session-id'] ?? _session;
    return response;
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = ++_nextId;
    final response = await _send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    if (response.headers['content-type']?.contains('text/event-stream') ==
        true) {
      var data = <String>[];
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty && data.isNotEmpty) {
          final message = jsonDecode(data.join('\n'));
          data = [];
          if (message is Map && message['id'] == id) {
            return _result(message, id);
          }
        } else if (line.startsWith('data:')) {
          data.add(line.substring(5).trimLeft());
        }
      }
      if (data.isNotEmpty) return _result(jsonDecode(data.join('\n')), id);
      throw const FormatException('Parallel: unvollständige MCP-Antwort');
    }
    final body = await response.stream.transform(utf8.decoder).join();
    return _result(jsonDecode(body), id);
  }

  Map<String, dynamic> _result(dynamic message, int id) {
    if (message is! Map || message['jsonrpc'] != '2.0' || message['id'] != id) {
      throw const FormatException('Parallel: ungültige MCP-Antwort');
    }
    if (message['error'] != null) {
      throw Exception('Parallel: MCP-Aufruf abgelehnt');
    }
    final result = message['result'];
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Parallel: MCP-Ergebnis fehlt');
    }
    return result;
  }
}
