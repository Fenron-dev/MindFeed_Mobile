import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mindfeed_mobile/services/app_settings.dart';
import 'package:mindfeed_mobile/services/ai/it_note_template.dart';
import 'package:mindfeed_mobile/services/openrouter_service.dart';
import 'package:mindfeed_mobile/services/web_search/web_search.dart';

class TrackingClient extends MockClient {
  TrackingClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

const resultData = {
  'results': [
    {
      'title': 'Flutter offline',
      'url': 'https://docs.flutter.dev/offline?lang=de',
      'excerpts': ['Offline-first storage', 'SQLite on mobile'],
    },
    {
      'url': 'javascript:alert(1)',
      'excerpts': ['unsafe'],
    },
    {'url': 'https:///missing-host', 'excerpts': []},
    {'title': null, 'url': 'https://example.org/help', 'excerpts': []},
  ],
};

http.Response reply(
  Map<String, dynamic> request,
  Object result, {
  bool sse = false,
  Map<String, String> headers = const {},
}) => http.Response(
  sse
      ? ': keepalive\n\ndata: {"jsonrpc":"2.0","method":"notifications/progress"}\n\n'
            'data: ${jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result})}\n\n'
      : jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
  200,
  headers: {
    'content-type': sse ? 'text/event-stream' : 'application/json',
    ...headers,
  },
);

class McpFixture {
  final requests = <http.Request>[];
  final clients = <TrackingClient>[];
  bool sse = false;
  bool textContent = false;
  Future<http.Response> Function(Map<String, dynamic>)? toolReply;
  String? modelPrompt;

  http.Client client() {
    final client = TrackingClient((request) async {
      requests.add(request);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.host == 'model.example') {
        modelPrompt = body['messages'][0]['content'] as String;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content':
                      '## Quellen\n[Flutter](https://docs.flutter.dev/offline?lang=de)',
                },
              },
            ],
          }),
          200,
        );
      }
      expect(request.url, ParallelProvider.endpoint);
      expect(request.followRedirects, isFalse);
      expect(request.headers['User-Agent'], ParallelProvider.userAgent);
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(request.headers['Accept'], 'application/json, text/event-stream');
      switch (body['method']) {
        case 'initialize':
          expect(body['params']['clientInfo']['name'], 'mindfeed-mobile');
          return reply(
            body,
            {'protocolVersion': '2025-03-26'},
            sse: sse,
            headers: {'mcp-session-id': 'test-session'},
          );
        case 'notifications/initialized':
          expect(body.containsKey('id'), isFalse);
          expect(request.headers['Mcp-Session-Id'], 'test-session');
          return http.Response('', 202);
        case 'tools/list':
          expect(request.headers['MCP-Protocol-Version'], '2025-03-26');
          return reply(body, {
            'tools': [
              {'name': 'web_search'},
            ],
          }, sse: sse);
        case 'tools/call':
          expect(request.headers['Mcp-Session-Id'], 'test-session');
          expect(request.headers['MCP-Protocol-Version'], '2025-03-26');
          expect(body['params']['name'], 'web_search');
          expect(
            body['params']['arguments']['session_id'],
            matches(RegExp(r'^[a-f0-9-]{36}$')),
          );
          if (toolReply != null) return toolReply!(body);
          return reply(
            body,
            textContent
                ? {
                    'content': [
                      {'type': 'text', 'text': jsonEncode(resultData)},
                    ],
                  }
                : {'structuredContent': resultData},
            sse: sse,
          );
        default:
          throw StateError('Unexpected request: $body');
      }
    });
    clients.add(client);
    return client;
  }
}

Future<void> configure({
  String? provider,
  Map<String, String> secure = const {},
}) async {
  SharedPreferences.setMockInitialValues({'web_search_provider': ?provider});
  FlutterSecureStorage.setMockInitialValues(secure);
  await AppSettings.init();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => configure());

  group('active research provider', () {
    test('fresh no-key installation selects Parallel', () async {
      expect(AppSettings.getWebSearchProvider(), isNull);
      expect(
        await resolveActiveWebSearchProviderKind(),
        WebSearchProviderKind.parallel,
      );
      expect(await resolveActiveWebSearchProvider(), isA<ParallelProvider>());
    });

    test('saved selection wins over other stored credentials', () async {
      await configure(
        provider: 'brave',
        secure: {
          'brave_api_key': 'BSA-saved',
          'searxng_base_url': 'http://local:8080',
        },
      );
      final provider = await resolveActiveWebSearchProvider() as BraveProvider;
      expect(provider.apiKey, 'BSA-saved');
      await AppSettings.saveWebSearchProvider('parallel');
      expect(await resolveActiveWebSearchProvider(), isA<ParallelProvider>());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('web_search_provider'), 'parallel');
    });

    test(
      'explicit missing configuration and unknown IDs do not enable Parallel',
      () async {
        for (final id in ['searxng', 'brave', 'unknown', 'disabled']) {
          await configure(provider: id);
          expect(await resolveActiveWebSearchProvider(), isNull, reason: id);
        }
      },
    );

    test(
      'legacy SearXNG URL and Brave key survive without saved provider',
      () async {
        await configure(secure: {'searxng_base_url': ' http://local:8080 '});
        final searx = await resolveActiveWebSearchProvider() as SearxngProvider;
        expect(searx.baseUrl, 'http://local:8080');
        await configure(secure: {'brave_api_key': 'BSA-legacy'});
        expect(await resolveActiveWebSearchProvider(), isA<BraveProvider>());
      },
    );

    test('disabled AI returns before provider or network resolution', () async {
      final fixture = McpFixture();
      await http.runWithClient(() async {
        expect(await resolveActiveWebSearchProvider(enabled: false), isNull);
      }, fixture.client);
      expect(fixture.requests, isEmpty);
      expect(fixture.clients, isEmpty);
    });

    test('disabled search is explicit and credentials are retained', () async {
      await configure(provider: 'disabled', secure: {'brave_api_key': 'saved'});
      expect(await resolveActiveWebSearchProvider(), isNull);
      await AppSettings.saveWebSearchProvider('brave');
      expect(
        (await resolveActiveWebSearchProvider() as BraveProvider).apiKey,
        'saved',
      );
    });
  });

  group('Parallel MCP transport and result consumption', () {
    test(
      'normal resolver searches and passes excerpts/URLs to researched-note model',
      () async {
        final fixture = McpFixture();
        await http.runWithClient(() async {
          final provider = (await resolveActiveWebSearchProvider())!;
          final results = await provider.search(
            'Flutter offline storage',
            language: 'de',
          );
          expect(results, hasLength(2));
          expect(
            results.first.content,
            'Offline-first storage\nSQLite on mobile',
          );
          expect(results.last.title, 'https://example.org/help');
          final model = OpenRouterService(
            apiKey: 'fixture-only',
            chatUrl: 'https://model.example/chat',
          );
          final note = await model.generateResearchedNote(
            title: 'Flutter offline storage',
            searchContext: webResultsToContext(results),
          );
          expect(fixture.modelPrompt, contains('[1] Flutter offline'));
          expect(fixture.modelPrompt, contains('SQLite on mobile'));
          expect(
            fixture.modelPrompt,
            contains('https://docs.flutter.dev/offline?lang=de'),
          );
          expect(fixture.modelPrompt, isNot(contains('javascript:')));
          expect(
            note,
            contains('[Flutter](https://docs.flutter.dev/offline?lang=de)'),
          );
        }, fixture.client);
        expect(fixture.clients.every((c) => c.closed), isTrue);
        final call = fixture.requests.firstWhere(
          (r) => r.body.contains('tools/call'),
        );
        final args = jsonDecode(call.body)['params']['arguments'];
        expect(args['search_queries'], ['Flutter offline storage']);
        expect(args['objective'], contains('Bevorzugte Sprache: de'));
      },
    );

    test('SSE and text-content responses feed IT-problem research', () async {
      final fixture = McpFixture()
        ..sse = true
        ..textContent = true;
      await http.runWithClient(() async {
        final provider = (await resolveActiveWebSearchProvider())!;
        final results = await provider.search(
          'Flutter offline storage',
          limit: 1,
        );
        expect(results, hasLength(1));
        final model = OpenRouterService(
          apiKey: 'fixture-only',
          chatUrl: 'https://model.example/chat',
        );
        final note = await model.generateItNote(
          mode: ItNoteMode.research,
          problem: 'Offline data',
          searchContext: webResultsToContext(results),
        );
        expect(fixture.modelPrompt, contains('SQLite on mobile'));
        expect(
          fixture.modelPrompt,
          contains('https://docs.flutter.dev/offline?lang=de'),
        );
        expect(note, contains('## Quellen'));
      }, fixture.client);
    });

    test(
      'connection check discovers tools without spending a search',
      () async {
        final fixture = McpFixture();
        await http.runWithClient(() async {
          expect(await const ParallelProvider().testConnection(), isNull);
        }, fixture.client);
        expect(fixture.requests.map((r) => jsonDecode(r.body)['method']), [
          'initialize',
          'notifications/initialized',
          'tools/list',
        ]);
      },
    );

    test(
      'empty query rejected; zero limit performs no network request',
      () async {
        final fixture = McpFixture();
        await http.runWithClient(() async {
          expect(await const ParallelProvider().search('q', limit: 0), isEmpty);
          await expectLater(
            const ParallelProvider().search('  '),
            throwsArgumentError,
          );
        }, fixture.client);
        expect(fixture.requests, isEmpty);
      },
    );

    test(
      'HTTP/auth/quota, RPC, tool and malformed errors propagate without fallback',
      () async {
        final failures = <Future<http.Response> Function(Map<String, dynamic>)>[
          (_) async => http.Response('unauthorized', 401),
          (_) async => http.Response('quota', 429),
          (r) async => http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': r['id'],
              'error': {'code': -1},
            }),
            200,
          ),
          (r) async => reply(r, {'isError': true}),
          (r) async => reply(r, {'structuredContent': {}}),
          (_) async => http.Response('not json', 200),
          (_) async =>
              http.Response('{"jsonrpc":"2.0","id":999,"result":{}}', 200),
        ];
        for (final failure in failures) {
          final fixture = McpFixture()..toolReply = failure;
          await http.runWithClient(() async {
            final provider = (await resolveActiveWebSearchProvider())!;
            await expectLater(provider.search('query'), throwsA(anything));
          }, fixture.client);
          expect(fixture.requests, hasLength(3));
          expect(fixture.clients.every((c) => c.closed), isTrue);
        }
      },
    );

    test(
      'timeout closes the owned client; transport cancellation propagates',
      () async {
        final stalled = TrackingClient(
          (_) => Completer<http.Response>().future,
        );
        await http.runWithClient(() async {
          await expectLater(
            const ParallelProvider(
              timeout: Duration(milliseconds: 10),
            ).search('query'),
            throwsA(isA<TimeoutException>()),
          );
        }, () => stalled);
        expect(stalled.closed, isTrue);
        final fixture = McpFixture()
          ..toolReply = (_) async => throw http.RequestAbortedException();
        await http.runWithClient(() async {
          await expectLater(
            const ParallelProvider().search('query'),
            throwsA(isA<http.RequestAbortedException>()),
          );
        }, fixture.client);
        expect(fixture.clients.every((c) => c.closed), isTrue);
      },
    );
  });
}
