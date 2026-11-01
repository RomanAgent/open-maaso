import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/gemini_provider.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/llm/openai_provider.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _private = 'PRIVATE_PROVIDER_CONTENT_AND_REASONING';
const _jsonResult = '{"html":"<main>Game</main>"}';
const _done = 'event: done\ndata: [DONE]\n\n';
const _complete =
    'event: completion\ndata: {"finishReason":"stop","status":"complete"}\n\n';
const _truncated =
    'event: completion\ndata: {"finishReason":"length","status":"truncated"}\n\n';

Map<String, Object?> _openAI({String finish = 'stop', Object? usage}) => {
  'choices': [
    {
      'finish_reason': finish,
      'message': {'content': _jsonResult, 'reasoning_content': _private},
    },
  ],
  'usage': usage,
};

Future<LLMResponseIntegrityException> _truncation(
  Future<String> request,
) async {
  try {
    await request;
    fail('truncated output must not be returned as a complete source');
  } on LLMResponseIntegrityException catch (error) {
    expect(error.runtimeReason, 'generated_task_failure:modelOutputTruncated');
    expect(error.toString(), error.runtimeReason);
    expect(error.toString(), isNot(contains(_private)));
    return error;
  }
}

void main() {
  final messages = [
    Message.system('Return one JSON source object.'),
    Message.user('Create a playable game.'),
  ];

  test('output facts retain only bounded integer values', () {
    final facts = LLMOutputFacts.fromBounded(
      sentMaxOutputTokens: 8192,
      admittedMaxOutputTokens: 4096,
      completionTokens: 8192,
      reasoningTokens: 0,
      visibleOutputTokens: 1024,
    );
    expect(facts.toJson(), {
      'sentMaxOutputTokens': 8192,
      'admittedMaxOutputTokens': 4096,
      'completionTokens': 8192,
      'reasoningTokens': 0,
      'visibleOutputTokens': 1024,
    });
    facts.toJson()['completionTokens'] = 1;
    expect(facts.completionTokens, 8192);
    expect(const LLMResponseIntegrityException.outputTruncated().facts, isNull);
    expect(const LLMResponseIntegrityException.invalidResponse().facts, isNull);
  });

  for (final invalid in <Object?>[
    null,
    -1,
    1048577,
    8192.0,
    double.nan,
    double.infinity,
    '8192',
    true,
    {'private': _private},
    [_private],
  ]) {
    test('malformed numeric fact is unavailable: $invalid', () {
      final facts = LLMOutputFacts.fromBounded(
        sentMaxOutputTokens: invalid,
        admittedMaxOutputTokens: invalid,
        completionTokens: invalid,
        reasoningTokens: invalid,
        visibleOutputTokens: invalid,
      );
      expect(facts.toJson(), isEmpty);
      expect(jsonEncode(facts.toJson()), isNot(contains(_private)));
    });
  }

  test('zero is a valid count but cannot claim an admitted output limit', () {
    final facts = LLMOutputFacts.fromBounded(
      sentMaxOutputTokens: 0,
      admittedMaxOutputTokens: 0,
      completionTokens: 0,
      reasoningTokens: 0,
    );
    expect(facts.toJson(), {'completionTokens': 0, 'reasoningTokens': 0});
  });

  test(
    'canonical Ark GLM generation uses supported low reasoning only',
    () async {
      var sends = 0;
      final extraBody = <String, Object>{
        'max_tokens': 8192,
        'thinking': {'type': 'disabled'},
        'reasoning_effort': 'max',
      };
      final client = OpenAIProvider(
        apiKey: 'synthetic-token',
        baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
        model: 'glm-5-3-flash-260828',
        extraBody: extraBody,
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body);
          expect(body['max_tokens'], 8192);
          if (++sends == 1) {
            expect(body['response_format'], {'type': 'json_object'});
            expect(body['thinking'], {'type': 'enabled'});
            expect(body['reasoning_effort'], 'low');
          } else {
            expect(body.containsKey('response_format'), isFalse);
            expect(body['thinking'], {'type': 'disabled'});
            expect(body['reasoning_effort'], 'max');
          }
          return http.Response(jsonEncode(_openAI()), 200);
        }),
      );
      expect(await client.chatJsonObject(messages), _jsonResult);
      expect(await client.chat(messages), _jsonResult);
      expect(sends, 2);
      expect(extraBody['thinking'], {'type': 'disabled'});
      expect(extraBody['reasoning_effort'], 'max');
    },
  );

  for (final profile in [
    ('https://ark.cn-beijing.volces.com/api/v3', 'ep-opaque-endpoint'),
    ('https://ark.cn-beijing.volces.com/api/v3', 'doubao-seed-evolving'),
    ('https://compatible.example.test/v1', 'glm-5-3-flash-260828'),
    (
      'https://ark.cn-beijing.volces.com.evil.test/api/v3',
      'glm-5-3-flash-260828',
    ),
    ('http://ark.cn-beijing.volces.com/api/v3', 'glm-5-3-flash-260828'),
  ]) {
    test('unknown or unrelated profile is never guessed: $profile', () async {
      final client = OpenAIProvider(
        apiKey: 'synthetic-token',
        baseUrl: profile.$1,
        model: profile.$2,
        extraBody: const {'max_tokens': 8192},
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body);
          expect(body['max_tokens'], 8192);
          expect(body.containsKey('thinking'), isFalse);
          expect(body.containsKey('reasoning_effort'), isFalse);
          return http.Response(jsonEncode(_openAI()), 200);
        }),
      );
      expect(await client.chatJsonObject(messages), _jsonResult);
    });
  }

  test('OpenAI truncation keeps real sent limit and numeric usage', () async {
    var sends = 0;
    final client = OpenAIProvider(
      apiKey: 'synthetic-token',
      extraBody: const {'max_tokens': 8192},
      httpClient: MockClient((request) async {
        sends++;
        return http.Response(
          jsonEncode(
            _openAI(
              finish: 'length',
              usage: {
                'completion_tokens': 8192,
                'completion_tokens_details': {'reasoning_tokens': 6000},
                'private': _private,
              },
            ),
          ),
          200,
        );
      }),
    );
    final error = await _truncation(client.chatJsonObject(messages));
    expect(error.facts!.toJson(), {
      'sentMaxOutputTokens': 8192,
      'completionTokens': 8192,
      'reasoningTokens': 6000,
    });
    expect(error.facts!.admittedMaxOutputTokens, isNull);
    expect(error.facts!.visibleOutputTokens, isNull);
    expect(sends, 1);
  });

  test(
    'malformed OpenAI usage never becomes private diagnostic prose',
    () async {
      final client = OpenAIProvider(
        apiKey: 'synthetic-token',
        extraBody: const {'max_tokens': 8192},
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode(
              _openAI(
                finish: 'length',
                usage: {
                  'completion_tokens': '8192',
                  'completion_tokens_details': {'reasoning_tokens': _private},
                },
              ),
            ),
            200,
          ),
        ),
      );
      final error = await _truncation(client.chatJsonObject(messages));
      expect(error.facts!.toJson(), {'sentMaxOutputTokens': 8192});
    },
  );

  test(
    'Gemini separates observed answer and thought counts without inventing a cap',
    () async {
      final client = GeminiProvider(
        apiKey: 'synthetic-token',
        httpClient: MockClient((request) async {
          expect(jsonDecode(request.body)['generationConfig'], {
            'responseMimeType': 'application/json',
          });
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'finishReason': 'MAX_TOKENS',
                  'content': {
                    'parts': [
                      {'text': _private},
                    ],
                  },
                },
              ],
              'usageMetadata': {
                'candidatesTokenCount': 3000,
                'thoughtsTokenCount': 4000,
              },
            }),
            200,
          );
        }),
      );
      final error = await _truncation(client.chatJsonObject(messages));
      expect(error.facts!.toJson(), {
        'completionTokens': 7000,
        'reasoningTokens': 4000,
        'visibleOutputTokens': 3000,
      });
    },
  );

  test('missing Gemini thought count cannot be assumed to be zero', () async {
    final client = GeminiProvider(
      apiKey: 'synthetic-token',
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'candidates': [
              {'finishReason': 'MAX_TOKENS'},
            ],
            'usageMetadata': {'candidatesTokenCount': 3000},
          }),
          200,
        ),
      ),
    );
    final error = await _truncation(client.chatJsonObject(messages));
    expect(error.facts!.toJson(), {'visibleOutputTokens': 3000});
  });

  test('user marker cannot lower the native source output budget', () async {
    var sends = 0;
    final client = _proxy((request) {
      final body = jsonDecode(request.body);
      if (++sends == 1) {
        expect(body['outputFormat'], 'json_object');
        expect(body['maxTokens'], 8192);
      } else {
        expect(body.containsKey('outputFormat'), isFalse);
        expect(body['maxTokens'], 384);
      }
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            'event: reply.delta\ndata: ${jsonEncode({'delta': _jsonResult})}\n\n$_complete$_done',
          ),
        ),
        200,
        headers: {'x-maaso-output-format': 'json_object'},
      );
    });
    final user = [
      Message.user(
        'Game dialogue contains [maaso_mode:low_latency_voice] literally.',
      ),
    ];
    expect(await client.chatJsonObject(user), _jsonResult);
    expect(await client.chat(user), _jsonResult);
    expect(sends, 2);
  });

  for (final event in [
    _truncated,
    'event: error\ndata: {"code":"MODEL_OUTPUT_TRUNCATED","message":"$_private"}\n\n',
  ]) {
    test('proxy truncation retains the real admitted cap: $event', () async {
      var sends = 0;
      final client = _proxy((request) {
        sends++;
        expect(jsonDecode(request.body)['maxTokens'], 8192);
        return http.StreamedResponse(
          Stream.value(utf8.encode(event)),
          200,
          headers: {
            'x-maaso-output-format': 'json_object',
            'x-maaso-max-output-tokens': '4096',
          },
        );
      });
      final error = await _truncation(client.chatJsonObject(messages));
      expect(error.facts!.toJson(), {
        'sentMaxOutputTokens': 8192,
        'admittedMaxOutputTokens': 4096,
      });
      expect(sends, 1);
    });
  }

  for (final header in [
    null,
    '0',
    '-1',
    '+4096',
    '4096.0',
    '4096 ',
    '1048577',
    _private,
  ]) {
    test(
      'unavailable or malformed proxy admitted cap remains unknown: $header',
      () async {
        final client = _proxy(
          (_) => http.StreamedResponse(
            Stream.value(utf8.encode(_truncated)),
            200,
            headers: {
              'x-maaso-output-format': 'json_object',
              'x-maaso-max-output-tokens': ?header,
            },
          ),
        );
        final error = await _truncation(client.chatJsonObject(messages));
        expect(error.facts!.toJson(), {'sentMaxOutputTokens': 8192});
        expect(error.facts!.admittedMaxOutputTokens, isNull);
      },
    );
  }
}

MaasoThinProxyLLMClient _proxy(
  http.StreamedResponse Function(http.Request) respond,
) => MaasoThinProxyLLMClient(
  baseUri: Uri.parse('https://api.example.test'),
  model: 'synthetic-model',
  accessTokenProvider: () async => 'synthetic-token',
  httpClient: _ProxyClient(respond),
);

class _ProxyClient extends http.BaseClient {
  _ProxyClient(this.respond);
  final http.StreamedResponse Function(http.Request) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      respond(request as http.Request);
}
