import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/offline/offline_model_client.dart';

const messages = [
  OfflineModelMessage(
    role: 'system',
    content: 'Return a JSON reply/actions envelope.',
  ),
  OfflineModelMessage(role: 'user', content: 'Make a tiny game.'),
];
const envelope = '{"reply":"Ready","actions":[]}';

OfflineProviderConfig config(
  String id, {
  String? baseUrl,
  bool enabled = true,
}) {
  final provider = OfflineModelProvider.fromId(id);
  return OfflineProviderConfig(
    providerId: id,
    enabled: enabled,
    baseUrl: baseUrl ?? provider.baseUrl,
    model: provider.defaultModel.isEmpty
        ? 'fixture-model'
        : provider.defaultModel,
  );
}

Matcher failure(String code) =>
    isA<OfflineModelException>().having((e) => e.code, 'code', code);

http.Response openAiReply([String text = envelope]) => http.Response(
  jsonEncode({
    'choices': [
      {
        'finish_reason': 'stop',
        'message': {'content': text},
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test(
    'disabled, missing credentials, and invalid destinations never send',
    () async {
      var requests = 0;
      final client = OfflineModelClient(
        client: MockClient((_) async {
          requests++;
          return openAiReply();
        }),
      );
      addTearDown(client.close);
      expect(requests, 0);
      await expectLater(
        client.complete(
          config: config('openai', enabled: false),
          apiKey: '',
          messages: messages,
        ),
        throwsA(failure('disabled')),
      );
      await expectLater(
        client.complete(
          config: config('openai'),
          apiKey: '',
          messages: messages,
        ),
        throwsA(failure('missing_api_key')),
      );
      for (final url in [
        'http://example.com/v1',
        'ftp://localhost/v1',
        'https://user:password@example.com/v1',
        'https://example.com/v1?key=fixture',
        'https://example.com/v1#fragment',
        'https://example.com/v1/../secret',
        'https://example.com/v1/%2Fsecret',
        'https://exa mple.com/v1',
      ]) {
        await expectLater(
          client.complete(
            config: config('custom', baseUrl: url),
            apiKey: 'fixture-key',
            messages: messages,
          ),
          throwsA(failure('invalid_endpoint')),
          reason: url,
        );
      }
      await expectLater(
        client.complete(
          config: config('openai'),
          apiKey: 'bad\nheader',
          messages: messages,
        ),
        throwsA(failure('invalid_api_key')),
      );
      expect(requests, 0);
    },
  );

  test(
    'OpenAI request has one explicit destination and preserves model output',
    () async {
      late http.Request captured;
      final client = OfflineModelClient(
        client: MockClient((r) async {
          captured = r;
          return openAiReply('{"reply":"你好","actions":[]}');
        }),
      );
      addTearDown(client.close);
      final text = await client.complete(
        config: config('openai'),
        apiKey: 'fixture-key',
        messages: messages,
      );
      expect(text, '{"reply":"你好","actions":[]}');
      expect(
        captured.url.toString(),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(captured.followRedirects, isFalse);
      expect(captured.maxRedirects, 0);
      expect(captured.headers['authorization'], 'Bearer fixture-key');
      final body = jsonDecode(captured.body) as Map;
      expect(body['stream'], isFalse);
      expect(body['max_completion_tokens'], 8192);
      expect(body['messages'], [
        {'role': 'system', 'content': messages[0].content},
        {'role': 'user', 'content': messages[1].content},
      ]);
      expect(captured.body, isNot(contains('fixture-key')));
    },
  );

  test('compatible providers retain their region and base path', () async {
    final urls = <String>[];
    final client = OfflineModelClient(
      client: MockClient((r) async {
        urls.add(r.url.toString());
        expect(jsonDecode(r.body)['max_tokens'], 8192);
        return openAiReply();
      }),
    );
    addTearDown(client.close);
    for (final id in [
      'deepseek',
      'qwen',
      'doubao',
      'moonshot',
      'zhipu',
      'siliconflow',
      'groq',
    ]) {
      await client.complete(
        config: config(id),
        apiKey: 'fixture-key',
        messages: messages,
      );
    }
    expect(urls, [
      'https://api.deepseek.com/chat/completions',
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
      'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
      'https://api.moonshot.cn/v1/chat/completions',
      'https://open.bigmodel.cn/api/paas/v4/chat/completions',
      'https://api.siliconflow.cn/v1/chat/completions',
      'https://api.groq.com/openai/v1/chat/completions',
    ]);
  });

  test(
    'loopback inference can omit credentials; external HTTP cannot',
    () async {
      final client = OfflineModelClient(
        client: MockClient((r) async {
          expect(r.headers.containsKey('authorization'), isFalse);
          return openAiReply();
        }),
      );
      addTearDown(client.close);
      for (final host in ['127.0.0.1', 'localhost', '[::1]']) {
        await client.complete(
          config: config(
            'custom',
            baseUrl: 'http://$host:11434/v1/chat/completions',
          ),
          apiKey: '',
          messages: messages,
        );
      }
      await expectLater(
        client.complete(
          config: config('custom', baseUrl: 'http://127.0.0.1.evil.example/v1'),
          apiKey: '',
          messages: messages,
        ),
        throwsA(failure('invalid_endpoint')),
      );
    },
  );

  test(
    'Anthropic uses native messages, system field and text-only response',
    () async {
      final client = OfflineModelClient(
        client: MockClient((r) async {
          expect(r.url.toString(), 'https://api.anthropic.com/v1/messages');
          expect(r.headers['x-api-key'], 'fixture-key');
          expect(r.headers['anthropic-version'], '2026-10-21');
          final body = jsonDecode(r.body);
          expect(body['system'], messages.first.content);
          expect(body['messages'], [
            {'role': 'user', 'content': messages.last.content},
          ]);
          expect(body['max_tokens'], 8192);
          return http.Response(
            jsonEncode({
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'thinking', 'thinking': 'not a user-facing reply'},
                {'type': 'text', 'text': envelope},
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      expect(
        await client.complete(
          config: config('anthropic'),
          apiKey: 'fixture-key',
          messages: messages,
        ),
        envelope,
      );
    },
  );

  test('Gemini uses native roles, systemInstruction and key header', () async {
    final client = OfflineModelClient(
      client: MockClient((r) async {
        expect(
          r.url.toString(),
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent',
        );
        expect(r.url.hasQuery, isFalse);
        expect(r.headers['x-goog-api-key'], 'fixture-key');
        final body = jsonDecode(r.body);
        expect(
          body['systemInstruction']['parts'][0]['text'],
          messages.first.content,
        );
        expect(body['contents'][1]['role'], 'model');
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'finishReason': 'STOP',
                'content': {
                  'parts': [
                    {'thought': true, 'text': 'internal analysis'},
                    {'text': envelope},
                  ],
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);
    expect(
      await client.complete(
        config: config('gemini'),
        apiKey: 'fixture-key',
        messages: [
          ...messages,
          const OfflineModelMessage(
            role: 'assistant',
            content: 'Earlier reply',
          ),
          const OfflineModelMessage(role: 'user', content: 'Continue'),
        ],
      ),
      envelope,
    );
    await expectLater(
      client.complete(
        config: config('gemini').copyWith(model: '../other-model'),
        apiKey: 'fixture-key',
        messages: messages,
      ),
      throwsA(failure('invalid_model')),
    );
  });

  test(
    'redirects and provider errors never expose response body credentials',
    () async {
      var count = 0;
      final client = OfflineModelClient(
        client: MockClient((r) async {
          count++;
          return http.Response(
            'private echo fixture-key',
            count == 1 ? 307 : 401,
            headers: {'location': 'https://untrusted.example/collect'},
          );
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.complete(
          config: config('openai'),
          apiKey: 'fixture-key',
          messages: messages,
        ),
        throwsA(failure('redirect_rejected')),
      );
      try {
        await client.complete(
          config: config('openai'),
          apiKey: 'fixture-key',
          messages: messages,
        );
        fail('Expected HTTP failure');
      } on OfflineModelException catch (error) {
        expect(error.code, 'http_error');
        expect(error.statusCode, 401);
        expect(error.toString(), isNot(contains('fixture-key')));
        expect(error.toString(), isNot(contains('private echo')));
      }
      expect(count, 2);
    },
  );

  test(
    'malformed, missing and truncated responses fail before execution',
    () async {
      for (final sample in <(String, String)>[
        ('not json', 'invalid_response'),
        ('{}', 'empty_response'),
        ('{"choices":[{"message":{"content":""}}]}', 'empty_response'),
        (
          '{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}',
          'truncated_response',
        ),
      ]) {
        final client = OfflineModelClient(
          client: MockClient((_) async => http.Response(sample.$1, 200)),
        );
        await expectLater(
          client.complete(
            config: config('openai'),
            apiKey: 'fixture-key',
            messages: messages,
          ),
          throwsA(failure(sample.$2)),
        );
        client.close();
      }
    },
  );

  test('streamed size limit is enforced without content-length', () async {
    final client = OfflineModelClient(
      client: _StreamClient(
        (_) async => http.StreamedResponse(
          Stream.fromIterable([List.filled(30, 65), List.filled(30, 65)]),
          200,
        ),
      ),
      maxResponseBytes: 40,
    );
    addTearDown(client.close);
    await expectLater(
      client.complete(
        config: config('openai'),
        apiKey: 'fixture-key',
        messages: messages,
      ),
      throwsA(failure('response_too_large')),
    );
  });

  test(
    'cancellation aborts transport and fences a late old response',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      late http.AbortableRequest request;
      var sends = 0;
      final client = OfflineModelClient(
        client: _StreamClient((r) async {
          sends++;
          if (sends == 1) {
            request = r as http.AbortableRequest;
            started.complete();
            await release.future;
          }
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'choices': [
                    {
                      'finish_reason': 'stop',
                      'message': {'content': envelope},
                    },
                  ],
                }),
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final old = client.complete(
        config: config('openai'),
        apiKey: 'fixture-key',
        messages: messages,
      );
      await started.future;
      await expectLater(
        client.complete(
          config: config('openai'),
          apiKey: 'fixture-key',
          messages: messages,
        ),
        throwsA(failure('busy')),
      );
      client.cancel();
      await request.abortTrigger;
      expect(
        await client.complete(
          config: config('openai'),
          apiKey: 'fixture-key',
          messages: messages,
        ),
        envelope,
      );
      release.complete();
      await expectLater(old, throwsA(failure('cancelled')));
      expect(sends, 2);
    },
  );

  test(
    'timeout aborts a stalled transport and close blocks new requests',
    () async {
      final release = Completer<http.StreamedResponse>();
      late http.AbortableRequest request;
      final client = OfflineModelClient(
        timeout: const Duration(milliseconds: 20),
        client: _StreamClient((r) {
          request = r as http.AbortableRequest;
          return release.future;
        }),
      );
      await expectLater(
        client.complete(
          config: config('openai'),
          apiKey: 'fixture-key',
          messages: messages,
        ),
        throwsA(failure('timeout')),
      );
      await request.abortTrigger;
      client.close();
      release.complete(http.StreamedResponse(const Stream.empty(), 200));
      await expectLater(
        client.complete(
          config: config('openai'),
          apiKey: 'fixture-key',
          messages: messages,
        ),
        throwsA(failure('closed')),
      );
    },
  );
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
