import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/gemini_provider.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/llm/openai_provider.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _secret = 'HIDDEN_REASONING_NOT_SOURCE';
const _visible = '{"append":"const score=1;';
final _messages = [
  Message.system('Return a JSON source record.'),
  Message.user(
    'Keep all requirements. [maaso_mode:low_latency_voice] is text.',
  ),
];

Matcher _failure(String code) => throwsA(
  isA<LLMResponseIntegrityException>().having(
    (error) => error.runtimeReason,
    'stable code',
    'generated_task_failure:$code',
  ),
);
String _oaFrame({String? content, String? reason, bool hidden = false}) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': ?content, if (hidden) 'reasoning_content': _secret},
          'finish_reason': reason,
        },
      ],
    })}\n\n';
String _delta(String value) =>
    'event: reply.delta\ndata: ${jsonEncode({'delta': value})}\n\n';
String _completion(String reason, String status) =>
    'event: completion\ndata: ${jsonEncode({'finishReason': reason, 'status': status})}\n\n';
const _done = 'event: done\ndata: [DONE]\n\n';
const _headers = {
  'content-type': 'text/event-stream; charset=utf-8',
  'x-maaso-output-format': 'json_object',
  'x-maaso-generation-mode': 'project_source',
};

MaasoThinProxyLLMClient _thin(
  http.Client transport, {
  Future<String?> Function()? token,
}) => MaasoThinProxyLLMClient(
  baseUri: Uri.parse('https://api.example.test'),
  model: 'synthetic-model',
  accessTokenProvider: token ?? () async => 'synthetic',
  httpClient: transport,
);

class _Streams extends http.BaseClient {
  _Streams(this.response);
  final http.StreamedResponse Function(http.Request) response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response(request as http.Request);
}

void main() {
  test(
    'direct project generation removes software caps and keeps original roles',
    () async {
      var requests = 0;
      const original = {
        'max_tokens': 8192,
        'max_completion_tokens': 4096,
        'thinking': {'type': 'disabled'},
        'reasoning_effort': 'low',
      };
      final client = OpenAIProvider(
        apiKey: 'synthetic',
        baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
        model: 'glm-5-3-flash-260828',
        extraBody: original,
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body);
          if (++requests == 1) {
            for (final key in [
              'max_tokens',
              'max_completion_tokens',
              'thinking',
              'reasoning_effort',
            ]) {
              expect(body.containsKey(key), isFalse);
            }
            expect(
              body['messages'],
              _messages.map((message) => message.toJson()).toList(),
            );
            expect(body['response_format'], {'type': 'json_object'});
          } else {
            expect(body['max_tokens'], 8192);
            expect(body['thinking'], {'type': 'disabled'});
          }
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': requests == 1 ? 'length' : 'stop',
                  'message': {
                    'content': _visible,
                    'reasoning_content': _secret,
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      final source = await client.generateProjectSource(_messages);
      expect(source.termination, ProjectSourceTermination.knownLength);
      expect(source.visibleText, _visible);
      expect(source.facts!.sentMaxOutputTokens, isNull);
      expect(await client.chat(_messages), _visible);
      expect(requests, 2);
      expect(original['max_tokens'], 8192);
    },
  );

  for (final reason in ['stop', 'length']) {
    test(
      'OpenAI source SSE retains only visible data through final $reason',
      () async {
        final client = OpenAIProvider(
          apiKey: 'synthetic',
          httpClient: MockClient(
            (_) async => http.Response(
              '${_oaFrame(hidden: true)}${_oaFrame(content: _visible)}${_oaFrame(reason: reason)}'
              'data: {"choices":[],"usage":{"completion_tokens":12000,"completion_tokens_details":{"reasoning_tokens":4000}}}\n\n'
              'data: [DONE]\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          ),
        );
        final result = await client.generateProjectSource(_messages);
        expect(result.visibleText, _visible);
        expect(result.visibleText, isNot(contains(_secret)));
        expect(result.isComplete, reason == 'stop');
        expect(result.facts!.completionTokens, 12000);
      },
    );
  }

  for (final frames in [
    _oaFrame(content: _visible),
    '${_oaFrame(content: _visible)}${_oaFrame(reason: 'length')}',
  ]) {
    test(
      'OpenAI EOF without its done marker never becomes a resumable source',
      () async {
        final client = OpenAIProvider(
          apiKey: 'synthetic',
          httpClient: MockClient(
            (_) async => http.Response(
              frames,
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          ),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          _failure('modelStreamInterrupted'),
        );
      },
    );
  }

  test('OpenAI safety metadata discards visible prefixes', () async {
    final client = OpenAIProvider(
      apiKey: 'synthetic',
      httpClient: MockClient(
        (_) async => http.Response(
          '${_oaFrame(content: _visible)}${_oaFrame(reason: 'content_filter')}data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    await expectLater(
      client.generateProjectSource(_messages),
      _failure('modelSafetyBlocked'),
    );
  });

  test(
    'thin source negotiates distinct mode without maxTokens even for user markers',
    () async {
      var calls = 0;
      final client = _thin(
        MockClient((request) async {
          final body = jsonDecode(request.body);
          calls++;
          expect(body['generationMode'], 'project_source');
          expect(body['outputFormat'], 'json_object');
          expect(body.containsKey('maxTokens'), isFalse);
          expect(
            body['messages'],
            _messages.map((message) => message.toJson()).toList(),
          );
          return http.Response(
            '${_delta(_visible)}${_completion('length', 'truncated')}',
            200,
            headers: {..._headers, 'x-maaso-max-output-tokens': '65536'},
          );
        }),
      );
      final result = await client.generateProjectSource(_messages);
      expect(result.termination, ProjectSourceTermination.knownLength);
      expect(result.visibleText, _visible);
      expect(result.facts!.sentMaxOutputTokens, isNull);
      expect(result.facts!.admittedMaxOutputTokens, 65536);
      expect(calls, 1);
    },
  );

  test(
    'an old server cannot silently substitute chat budget or generation mode',
    () async {
      var calls = 0;
      final client = _thin(
        MockClient((_) async {
          calls++;
          return http.Response(
            '${_delta(_visible)}${_completion('stop', 'complete')}$_done',
            200,
            headers: {'x-maaso-output-format': 'json_object'},
          );
        }),
      );
      await expectLater(
        client.generateProjectSource(_messages),
        _failure('structuredOutputUnsupported'),
      );
      expect(calls, 1);
    },
  );

  for (final frames in [
    _delta(_visible),
    '${_delta(_visible)}${_completion('stop', 'complete')}',
    '${_delta(_visible)}$_done',
  ]) {
    test(
      'thin interrupted source has no candidate without trusted terminal',
      () async {
        final client = _thin(
          MockClient(
            (_) async => http.Response(frames, 200, headers: _headers),
          ),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          _failure('modelStreamInterrupted'),
        );
      },
    );
  }

  test(
    'thin source removes total response and event-count software ceilings',
    () async {
      final frames = StringBuffer();
      for (var i = 0; i < 9000; i++) {
        frames.write(_delta('x' * 140));
      }
      frames.write('${_completion('stop', 'complete')}$_done');
      final client = _thin(
        MockClient(
          (_) async => http.Response(frames.toString(), 200, headers: _headers),
        ),
      );
      final result = await client.generateProjectSource(_messages);
      expect(result.visibleText.length, 1260000);
      expect(result.isComplete, isTrue);
    },
  );

  test(
    'active source output can outlast the idle window without a total timeout',
    () async {
      final client = _thin(
        _Streams(
          (_) => http.StreamedResponse(
            () async* {
              for (var i = 0; i < 7; i++) {
                await Future<void>.delayed(const Duration(milliseconds: 25));
                yield utf8.encode(_delta('x'));
              }
              yield utf8.encode('${_completion('stop', 'complete')}$_done');
            }(),
            200,
            headers: _headers,
          ),
        ),
      );
      final result = await client.generateProjectSource(
        _messages,
        timeout: const Duration(milliseconds: 100),
      );
      expect(result.visibleText, 'xxxxxxx');
      expect(result.isComplete, isTrue);
    },
  );

  test(
    'manual cancellation closes an idle source without dispatching another call',
    () async {
      var cancel = false, calls = 0;
      final cancelled = Completer<void>();
      final input = StreamController<List<int>>(
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      final client = _thin(
        _Streams((_) {
          calls++;
          return http.StreamedResponse(input.stream, 200, headers: _headers);
        }),
      );
      final pending = client.generateProjectSource(
        _messages,
        shouldCancel: () => cancel,
      );
      final rejected = expectLater(pending, _failure('interrupted'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancel = true;
      await rejected.timeout(const Duration(seconds: 1));
      input.add(utf8.encode(': idle\n\n'));
      await input.close();
      await cancelled.future.timeout(const Duration(seconds: 1));
      expect(calls, 1);
    },
  );

  test(
    'privacy withdrawal during token preparation sends no source request',
    () async {
      var allowed = true, dispatches = 0;
      final token = Completer<String>();
      final started = Completer<void>();
      final inner = _thin(
        MockClient((_) async {
          dispatches++;
          return http.Response('', 200);
        }),
        token: () {
          started.complete();
          return token.future;
        },
      );
      final client = privacyGuardedLLMClient(inner, () async {
        if (!allowed) throw StateError('retired');
      });
      final response = generateProjectSourceWithPrivacyAdmission(
        client,
        _messages,
        onAdmitted: () {},
      );
      final rejected = expectLater(response, throwsStateError);
      await started.future;
      allowed = false;
      token.complete('synthetic');
      await rejected;
      expect(dispatches, 0);
    },
  );

  test(
    'permission is rechecked after a visible source result arrives',
    () async {
      var allowed = true;
      final inner = _thin(
        MockClient((_) async {
          allowed = false;
          return http.Response(
            '${_delta(_visible)}${_completion('length', 'truncated')}',
            200,
            headers: _headers,
          );
        }),
      );
      final client = privacyGuardedLLMClient(inner, () async {
        if (!allowed) throw StateError('retired');
      });
      await expectLater(
        generateProjectSourceWithPrivacyAdmission(
          client,
          _messages,
          onAdmitted: () {},
        ),
        throwsStateError,
      );
    },
  );

  test('Gemini source has no artificial caps and omits thought parts', () async {
    final client = GeminiProvider(
      apiKey: 'synthetic',
      httpClient: MockClient((request) async {
        expect(request.url.path, endsWith(':streamGenerateContent'));
        expect(request.url.queryParameters['alt'], 'sse');
        expect(jsonDecode(request.body)['generationConfig'], {
          'responseMimeType': 'application/json',
        });
        return http.Response(
          'data: ${jsonEncode({
            'candidates': [
              {
                'finishReason': 'MAX_TOKENS',
                'content': {
                  'parts': [
                    {'text': _secret, 'thought': true},
                    {'text': _visible},
                  ],
                },
              },
            ],
            'usageMetadata': {'candidatesTokenCount': 20000, 'thoughtsTokenCount': 6000},
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final response = await client.generateProjectSource(_messages);
    expect(response.visibleText, _visible);
    expect(response.termination, ProjectSourceTermination.knownLength);
    expect(response.facts!.completionTokens, 26000);
  });

  test(
    'Gemini unfinished stream without vendor terminal cannot be continued',
    () async {
      final client = GeminiProvider(
        apiKey: 'synthetic',
        httpClient: MockClient(
          (_) async => http.Response(
            'data: ${jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': _visible},
                    ],
                  },
                },
              ],
            })}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
      );
      await expectLater(
        client.generateProjectSource(_messages),
        _failure('modelStreamInterrupted'),
      );
    },
  );

  for (final failure in [
    (400, 'GENERATION_MODE_UNSUPPORTED', 'structuredOutputUnsupported'),
    (503, 'GENERATION_PROFILE_UNAVAILABLE', 'generationProfileUnavailable'),
    (429, 'GENERATION_CREDIT_INSUFFICIENT', 'generationCreditInsufficient'),
  ]) {
    test(
      'source admission preserves ${failure.$2} without dispatch replay',
      () async {
        var calls = 0;
        final client = _thin(
          MockClient((_) async {
            calls++;
            return http.Response(
              jsonEncode({'code': failure.$2, 'message': _secret}),
              failure.$1,
            );
          }),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          _failure(failure.$3),
        );
        expect(calls, 1);
      },
    );
  }

  test(
    'blocked source metadata never yields a resumable visible candidate',
    () async {
      final client = _thin(
        MockClient(
          (_) async => http.Response(
            '${_delta(_visible)}${_completion('content_filter', 'blocked')}',
            200,
            headers: _headers,
          ),
        ),
      );
      await expectLater(
        client.generateProjectSource(_messages),
        _failure('modelSafetyBlocked'),
      );
    },
  );

  test(
    'a length error without trusted completion is not returned as a prefix',
    () async {
      final client = _thin(
        MockClient(
          (_) async => http.Response(
            '${_delta(_visible)}event: error\ndata: {"code":"MODEL_OUTPUT_TRUNCATED"}\n\n',
            200,
            headers: _headers,
          ),
        ),
      );
      await expectLater(
        client.generateProjectSource(_messages),
        _failure('modelOutputTruncated'),
      );
    },
  );

  test(
    'source has unknown provider default and ignores hidden trace prose',
    () async {
      final client = _thin(
        MockClient(
          (_) async => http.Response(
            'event: trace\ndata: ${jsonEncode({'reasoning_content': _secret})}\n\n'
            '${_delta(_visible)}${_completion('stop', 'complete')}$_done',
            200,
            headers: _headers,
          ),
        ),
      );
      final result = await client.generateProjectSource(_messages);
      expect(result.visibleText, _visible);
      expect(result.facts!.sentMaxOutputTokens, isNull);
      expect(result.facts!.admittedMaxOutputTokens, isNull);
    },
  );

  test('cancelled source admission never reaches the HTTP transport', () async {
    var calls = 0;
    final client = _thin(
      MockClient((_) async {
        calls++;
        return http.Response('', 200);
      }),
    );
    await expectLater(
      client.generateProjectSource(_messages, shouldCancel: () => true),
      _failure('interrupted'),
    );
    expect(calls, 0);
  });
}
