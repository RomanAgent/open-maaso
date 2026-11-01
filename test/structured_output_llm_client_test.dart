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

const _privateText = 'PRIVATE_PROVIDER_REASONING_OR_SECRET';
const _result = '{"title":"game","js":"function restart(){}"}';
const _completion =
    'event: completion\ndata: {"finishReason":"stop","status":"complete"}\n\n';
const _done = 'event: done\ndata: [DONE]\n\n';

Matcher _failure(String code) => throwsA(
  isA<LLMResponseIntegrityException>().having(
    (error) => error.toString(),
    'fixed diagnostic',
    'generated_task_failure:$code',
  ),
);

String _delta(String text) =>
    'event: reply.delta\ndata: ${jsonEncode({'delta': text})}\n\n';

Map<String, Object?> _openAIResult({
  String? finishReason = 'stop',
  String? refusal,
}) => {
  'choices': [
    {
      'finish_reason': finishReason,
      'message': {
        'content': _result,
        'reasoning_content': _privateText,
        'refusal': refusal,
      },
    },
  ],
};

MaasoThinProxyLLMClient _thin(
  String events, {
  String? outputFormat = 'json_object',
  void Function(http.Request)? inspect,
}) => MaasoThinProxyLLMClient(
  baseUri: Uri.parse('https://api.example.test'),
  model: 'synthetic-model',
  accessTokenProvider: () async => 'synthetic-token',
  httpClient: _StreamingClient((request) {
    inspect?.call(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(events)),
      200,
      headers: {'x-maaso-output-format': ?outputFormat},
    );
  }),
);

void main() {
  final messages = [
    Message.system('Output a JSON game object.'),
    Message.user('Play with butterflies'),
    Message.assistant('A local game draft.'),
    Message.system('Keep the original game editable.'),
    Message.user('Fix the local restart control.'),
  ];

  test(
    'OpenAI JSON operation preserves roles and activates native mode',
    () async {
      var admitted = false;
      final client = OpenAIProvider(
        apiKey: 'synthetic-token',
        extraBody: const {
          'response_format': {'type': 'text'},
          'max_tokens': 8192,
        },
        httpClient: MockClient((request) async {
          expect(admitted, isTrue);
          final body = jsonDecode(request.body) as Map;
          expect(body['response_format'], {'type': 'json_object'});
          expect(body['messages'], [
            for (final message in messages)
              {'role': message.role, 'content': message.content},
          ]);
          expect(body['max_tokens'], 8192);
          return http.Response(jsonEncode(_openAIResult()), 200);
        }),
      );
      expect(
        await client.chatJsonObject(
          messages,
          onAdmitted: () async => admitted = true,
        ),
        _result,
      );
    },
  );

  test('ordinary OpenAI chat does not opt into JSON mode', () async {
    final client = OpenAIProvider(
      apiKey: 'synthetic-token',
      httpClient: MockClient((request) async {
        expect(jsonDecode(request.body), isNot(contains('response_format')));
        return http.Response(jsonEncode(_openAIResult()), 200);
      }),
    );
    expect(await client.chat(messages), _result);
  });

  for (final error in [
    {
      'param': 'response_format',
      'code': 'unsupported_parameter',
      'message': _privateText,
    },
    {
      'code': 'invalid_request_error',
      'message': 'response_format json_object not supported $_privateText',
    },
  ]) {
    test(
      'unsupported compatible API does not silently replay: $error',
      () async {
        var sends = 0;
        final client = OpenAIProvider(
          apiKey: 'synthetic-token',
          baseUrl: 'https://compatible.example.test/v1',
          httpClient: MockClient((request) async {
            sends++;
            expect(jsonDecode(request.body)['response_format'], {
              'type': 'json_object',
            });
            return http.Response(jsonEncode({'error': error}), 400);
          }),
        );
        await expectLater(
          client.chatJsonObject(messages),
          _failure('structuredOutputUnsupported'),
        );
        expect(sends, 1);
      },
    );
  }

  for (final entry in [
    ('length', null, 'modelOutputTruncated'),
    ('content_filter', null, 'modelSafetyBlocked'),
    ('stop', _privateText, 'modelSafetyBlocked'),
    ('tool_calls', null, 'responseInvalid'),
    (null, null, 'responseInvalid'),
  ]) {
    test('native OpenAI finish diagnostics: ${entry.$1}/${entry.$2}', () async {
      final client = OpenAIProvider(
        apiKey: 'synthetic-token',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode(
              _openAIResult(finishReason: entry.$1, refusal: entry.$2),
            ),
            200,
          ),
        ),
      );
      await expectLater(client.chatJsonObject(messages), _failure(entry.$3));
    });
  }

  test(
    'native Gemini retains all system instructions and public parts',
    () async {
      final client = GeminiProvider(
        apiKey: 'synthetic-token',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['generationConfig'], {
            'responseMimeType': 'application/json',
          });
          expect((body['contents'] as List).map((value) => value['role']), [
            'user',
            'model',
            'user',
          ]);
          expect(body['systemInstruction'], {
            'parts': [
              {'text': '${messages.first.content}\n\n${messages[3].content}'},
            ],
          });
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'finishReason': 'STOP',
                  'content': {
                    'parts': [
                      {'thought': true, 'text': _privateText},
                      {'text': _result.substring(0, 15)},
                      {'text': _result.substring(15)},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(await client.chatJsonObject(messages), _result);
    },
  );

  for (final entry in [
    ('MAX_TOKENS', 'modelOutputTruncated'),
    ('SAFETY', 'modelSafetyBlocked'),
    ('RECITATION', 'modelSafetyBlocked'),
    ('OTHER', 'responseInvalid'),
  ]) {
    test('native Gemini finish diagnostic: ${entry.$1}', () async {
      final client = GeminiProvider(
        apiKey: 'synthetic-token',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'candidates': [
                {
                  'finishReason': entry.$1,
                  'content': {
                    'parts': [
                      {'text': _result},
                    ],
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      await expectLater(client.chatJsonObject(messages), _failure(entry.$2));
    });
  }

  test(
    'Gemini prompt safety block is distinct from malformed output',
    () async {
      final client = GeminiProvider(
        apiKey: 'synthetic-token',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'promptFeedback': {
                'blockReason': 'SAFETY',
                'blockReasonMessage': _privateText,
              },
            }),
            200,
          ),
        ),
      );
      await expectLater(
        client.chatJsonObject(messages),
        _failure('modelSafetyBlocked'),
      );
    },
  );

  test('privacy wrapper preserves the optional native capability', () async {
    final native = _NativeClient();
    var allowed = true;
    var checks = 0;
    final client = privacyGuardedLLMClient(native, () async {
      checks++;
      if (!allowed) throw StateError('retired');
    });
    expect(client, isA<StructuredOutputLLMClient>());
    expect(client, isNot(isA<PresentationStreamingLLMClient>()));
    expect(
      await chatJsonObjectWithPrivacyAdmission(
        client,
        messages,
        onAdmitted: () {},
      ),
      _result,
    );
    expect(checks, 2);
    expect(native.jsonSends, 1);
    allowed = false;
    await expectLater(
      chatJsonObjectWithPrivacyAdmission(client, messages, onAdmitted: () {}),
      throwsStateError,
    );
    expect(native.jsonSends, 1);
  });

  test(
    'privacy keeps both presentation and native JSON capabilities',
    () async {
      final client = privacyGuardedLLMClient(
        _NativePresentationClient(),
        () async {},
      );
      expect(client, isA<StructuredOutputLLMClient>());
      expect(client, isA<PresentationStreamingLLMClient>());
      expect(
        await (client as PresentationStreamingLLMClient)
            .streamPresentationChatEvents(messages)
            .single,
        isA<LLMStreamEvent>(),
      );
      expect(
        await (client as StructuredOutputLLMClient).chatJsonObject(messages),
        _result,
      );
    },
  );

  test(
    'local compatibility preserves roles without inventing native support',
    () async {
      final local = _LocalClient();
      final client = privacyGuardedLLMClient(local, () async {});
      final pinned = await resolveStructuredOutputClientForTask(client);
      expect(pinned, isNot(isA<StructuredOutputLLMClient>()));
      var admissions = 0;
      expect(
        await chatJsonObjectWithPrivacyAdmission(
          pinned,
          messages,
          onAdmitted: () => admissions++,
        ),
        _result,
      );
      expect(admissions, 1);
      expect(local.messages, same(messages));
      expect(local.chatSends, 1);
      expect(local.legacyJsonSends, 0);
    },
  );

  test(
    'task resolution unwraps resolver once but retains live privacy',
    () async {
      final native = _NativeClient();
      final resolver = _Resolver(native);
      var allowed = true;
      final wrapped = privacyGuardedLLMClient(resolver, () async {
        if (!allowed) throw StateError('retired');
      });
      final pinned = await resolveStructuredOutputClientForTask(wrapped);
      expect(resolver.resolutions, 1);
      expect(pinned, isA<StructuredOutputLLMClient>());
      expect(
        await (pinned as StructuredOutputLLMClient).chatJsonObject(messages),
        _result,
      );
      expect(
        await (pinned as StructuredOutputLLMClient).chatJsonObject(messages),
        _result,
      );
      expect(resolver.resolutions, 1);
      allowed = false;
      await expectLater(
        (pinned as StructuredOutputLLMClient).chatJsonObject(messages),
        throwsStateError,
      );
      expect(native.jsonSends, 2);
    },
  );

  test(
    'JSON proxy request preserves messages and negotiates native output',
    () async {
      var admissions = 0;
      final ids = <String>{};
      final client = _thin(
        '${_delta(_result)}$_completion$_done',
        inspect: (request) {
          expect(admissions, ids.length + 1);
          final body = jsonDecode(request.body);
          expect(body['outputFormat'], 'json_object');
          expect(body['streamProtocol'], 'maaso.sse.v1');
          expect(
            body['messages'],
            messages.map((message) => message.toJson()).toList(),
          );
          expect(ids.add(body['turnId']), isTrue);
        },
      );
      expect(
        await client.chatJsonObject(messages, onAdmitted: () => admissions++),
        _result,
      );
      expect(
        await client.chatJsonObject(messages, onAdmitted: () => admissions++),
        _result,
      );
      expect(ids, hasLength(2));
    },
  );

  test('ordinary proxy chat never sends output-format negotiation', () async {
    final client = _thin(
      '${_delta(_result)}$_done',
      inspect: (request) {
        expect(jsonDecode(request.body), isNot(contains('outputFormat')));
      },
    );
    expect(await client.chat(messages), _result);
  });

  test('old proxy cannot silently claim native JSON support', () async {
    final client = _thin(
      '${_delta(_result)}$_completion$_done',
      outputFormat: null,
    );
    await expectLater(
      client.chatJsonObject(messages),
      _failure('structuredOutputUnsupported'),
    );
  });

  for (final events in [
    _delta(_result),
    '${_delta(_result)}$_completion',
    '${_delta(_result)}$_done',
    'event: completion\ndata: {"finishReason":"unknown","status":"incomplete"}\n\n$_done',
  ]) {
    test(
      'proxy JSON EOF/done cannot hide incomplete output: $events',
      () async {
        await expectLater(
          _thin(events).chatJsonObject(messages),
          _failure('modelStreamInterrupted'),
        );
      },
    );
  }

  for (final entry in [
    ('length', 'truncated', 'modelOutputTruncated'),
    ('content_filter', 'blocked', 'modelSafetyBlocked'),
  ]) {
    test('proxy completion retains ${entry.$3} before protocol done', () async {
      final events =
          '${_delta(_result)}event: completion\ndata: '
          '${jsonEncode({'finishReason': entry.$1, 'status': entry.$2})}\n\n';
      await expectLater(
        _thin(events).chatJsonObject(messages),
        _failure(entry.$3),
      );
    });
  }

  for (final entry in [
    ('MODEL_OUTPUT_TRUNCATED', 'modelOutputTruncated'),
    ('MODEL_SAFETY_BLOCKED', 'modelSafetyBlocked'),
    ('MODEL_STREAM_INCOMPLETE', 'modelStreamInterrupted'),
    ('MODEL_TRANSPORT_ERROR', 'modelStreamInterrupted'),
    ('MODEL_STREAM_INVALID', 'responseInvalid'),
    ('MODEL_PROVIDER_ERROR', 'modelUnavailable'),
    ('UNKNOWN_SECRET_ERROR', 'responseInvalid'),
  ]) {
    test('proxy structured error is a closed diagnostic: ${entry.$1}', () async {
      final events =
          'event: error\ndata: ${jsonEncode({'code': entry.$1, 'message': _privateText})}\n\n';
      await expectLater(
        _thin(events).chatJsonObject(messages),
        _failure(entry.$2),
      );
    });
  }

  test('proxy format rejection remains one dispatch and a safe code', () async {
    var sends = 0;
    final client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test'),
      model: 'model',
      accessTokenProvider: () async => 'synthetic-token',
      httpClient: MockClient((request) async {
        sends++;
        return http.Response(
          jsonEncode({
            'code': 'OUTPUT_FORMAT_UNSUPPORTED',
            'message': _privateText,
          }),
          400,
        );
      }),
    );
    await expectLater(
      client.chatJsonObject(messages),
      _failure('structuredOutputUnsupported'),
    );
    expect(sends, 1);
  });

  for (final entry in [
    (503, 'MODEL_AUTHENTICATION', 'modelAuthentication'),
    (429, 'MODEL_RATE_LIMITED', 'modelRateLimited'),
    (400, 'MODEL_CONTEXT_LIMIT', 'modelContextLimit'),
    (429, 'MODEL_QUOTA_EXCEEDED', 'modelQuotaExceeded'),
  ]) {
    test(
      'proxy initial rejection keeps the closed code: ${entry.$2}',
      () async {
        final client = MaasoThinProxyLLMClient(
          baseUri: Uri.parse('https://api.example.test'),
          model: 'model',
          accessTokenProvider: () async => 'synthetic-token',
          httpClient: MockClient(
            (_) async => http.Response(
              jsonEncode({'code': entry.$2, 'message': _privateText}),
              entry.$1,
            ),
          ),
        );
        await expectLater(client.chatJsonObject(messages), _failure(entry.$3));
      },
    );
  }

  for (final events in [
    '${_delta(_result)}$_completion'
        'event: done\ndata: not-done\n\n',
    '${_delta(_result)}$_completion${_delta('late')}$_done',
    '${_delta(_result)}$_completion$_completion$_done',
    'event: reply.delta\ndata: {"content":"wrong-field"}\n\n$_completion$_done',
    '${_delta(_result)}event: body.intent\ndata: {"mood":"secret"}\n\n$_completion$_done',
  ]) {
    test(
      'structured proxy rejects malformed or out-of-order events: $events',
      () async {
        await expectLater(
          _thin(events).chatJsonObject(messages),
          _failure('responseInvalid'),
        );
      },
    );
  }

  test(
    'consent revocation during token refresh blocks JSON dispatch',
    () async {
      var allowed = true;
      var sends = 0;
      var admissions = 0;
      final token = Completer<String>();
      final tokenStarted = Completer<void>();
      final inner = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://api.example.test'),
        model: 'model',
        accessTokenProvider: () {
          tokenStarted.complete();
          return token.future;
        },
        httpClient: _StreamingClient((request) {
          sends++;
          throw StateError('must not dispatch');
        }),
      );
      final client = privacyGuardedLLMClient(inner, () async {
        if (!allowed) throw StateError('consent revoked');
      });
      final result = chatJsonObjectWithPrivacyAdmission(
        client,
        messages,
        onAdmitted: () => admissions++,
      );
      final rejected = expectLater(result, throwsStateError);
      await tokenStarted.future;
      allowed = false;
      token.complete('synthetic-token');
      await rejected;
      expect(sends, 0);
      expect(admissions, 0);
    },
  );
}

class _LocalClient extends LLMClient {
  List<Message>? messages;
  int chatSends = 0;
  int legacyJsonSends = 0;

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    this.messages = messages;
    chatSends++;
    return _result;
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    legacyJsonSends++;
    return _result;
  }
}

class _NativeClient extends _LocalClient implements StructuredOutputLLMClient {
  int jsonSends = 0;

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) async {
    await onAdmitted?.call();
    jsonSends++;
    return _result;
  }
}

class _NativePresentationClient extends _NativeClient
    implements PresentationStreamingLLMClient {
  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield const LLMStreamEvent(event: 'reply.delta', data: 'presentation');
  }
}

class _Resolver extends _LocalClient implements StructuredOutputClientResolver {
  _Resolver(this.client);
  final LLMClient client;
  int resolutions = 0;

  @override
  Future<LLMClient> resolveStructuredOutputClient() async {
    resolutions++;
    return client;
  }
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.respond);
  final http.StreamedResponse Function(http.Request) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      respond(request as http.Request);
}
