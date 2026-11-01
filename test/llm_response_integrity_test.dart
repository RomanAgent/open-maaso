import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/data/llm/gemini_provider.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/llm/openai_provider.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

void main() {
  const envelope = '{"reply":"Use Canvas with local controls","actions":[]}';
  const privateText = 'PRIVATE_PROVIDER_REASONING_OR_SECRET';
  final messages = [Message.user('Build an offline game')];
  MockClient response(Object body, {int status = 200}) =>
      MockClient((_) async => http.Response(jsonEncode(body), status));
  Map<String, Object?> openai({String? finish = 'stop'}) => {
    'choices': [
      {
        'finish_reason': ?finish,
        'message': {'content': envelope, 'reasoning_content': privateText},
      },
    ],
  };

  test(
    'a syntactically valid but length-limited completion is not executed',
    () async {
      final provider = OpenAIProvider(
        apiKey: 'synthetic',
        httpClient: response(openai(finish: 'length')),
      );
      await expectLater(
        provider.chat(messages),
        throwsA(
          isA<LLMResponseIntegrityException>().having(
            (e) => GeneratedTaskFailureCode.fromLegacyError(e.toString()),
            'public diagnostic',
            GeneratedTaskFailureCode.modelOutputTruncated,
          ),
        ),
      );
    },
  );

  for (final finish in ['stop', null]) {
    test(
      'complete compatible responses preserve only public text: $finish',
      () async {
        final provider = OpenAIProvider(
          apiKey: 'synthetic',
          httpClient: response(openai(finish: finish)),
        );
        expect(await provider.chat(messages), envelope);
      },
    );
  }

  test(
    'truncated native tool arguments are rejected before invocation',
    () async {
      final provider = OpenAIProvider(
        apiKey: 'synthetic',
        httpClient: response({
          'choices': [
            {
              'finish_reason': 'length',
              'message': {
                'content': null,
                'tool_calls': [
                  {
                    'id': 'partial',
                    'function': {'name': 'surface.show', 'arguments': '{'},
                  },
                ],
              },
            },
          ],
        }),
      );
      await expectLater(
        provider.chatWithTools(messages, []),
        throwsA(isA<LLMResponseIntegrityException>()),
      );
    },
  );

  test(
    'provider authentication prose never enters a task diagnostic',
    () async {
      final provider = OpenAIProvider(
        apiKey: 'synthetic',
        httpClient: response({
          'error': {'message': privateText},
        }, status: 401),
      );
      await expectLater(
        provider.chat(messages),
        throwsA(
          isA<LLMResponseIntegrityException>().having(
            (e) => e.toString(),
            'safe code',
            'generated_task_failure:modelAuthentication',
          ),
        ),
      );
    },
  );

  test(
    'provider quota code is distinguished from generic rate limiting',
    () async {
      final provider = OpenAIProvider(
        apiKey: 'synthetic',
        httpClient: response({
          'error': {'code': 'insufficient_quota', 'message': privateText},
        }, status: 429),
      );
      await expectLater(
        provider.chat(messages),
        throwsA(
          isA<LLMResponseIntegrityException>().having(
            (e) => e.toString(),
            'safe code',
            'generated_task_failure:modelQuotaExceeded',
          ),
        ),
      );
    },
  );

  Map<String, Object?> gemini(String finish, List<Object?> parts) => {
    'candidates': [
      {
        'finishReason': finish,
        'content': {'parts': parts},
      },
    ],
  };
  test('Gemini MAX_TOKENS cannot be mistaken for a complete game', () async {
    final provider = GeminiProvider(
      apiKey: 'synthetic',
      httpClient: response(
        gemini('MAX_TOKENS', [
          {'text': envelope},
        ]),
      ),
    );
    await expectLater(
      provider.chat(messages),
      throwsA(
        isA<LLMResponseIntegrityException>().having(
          (e) => e.toString(),
          'safe code',
          'generated_task_failure:modelOutputTruncated',
        ),
      ),
    );
  });

  test(
    'Gemini skips thought parts and joins the actual visible response',
    () async {
      final provider = GeminiProvider(
        apiKey: 'synthetic',
        httpClient: response(
          gemini('STOP', [
            {'thought': true, 'text': privateText},
            {'text': envelope.substring(0, 12)},
            {'text': envelope.substring(12)},
          ]),
        ),
      );
      expect(await provider.chat(messages), envelope);
    },
  );

  test(
    'a thought-only Gemini response never becomes user-visible progress',
    () async {
      final provider = GeminiProvider(
        apiKey: 'synthetic',
        httpClient: response(
          gemini('STOP', [
            {'thought': true, 'text': privateText},
          ]),
        ),
      );
      await expectLater(
        provider.chat(messages),
        throwsA(
          isA<LLMResponseIntegrityException>().having(
            (e) => e.toString(),
            'safe code',
            'generated_task_failure:responseInvalid',
          ),
        ),
      );
    },
  );
}
