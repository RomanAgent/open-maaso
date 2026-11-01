import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/llm/openai_provider.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

import 'support/project_source_fixture.dart';

const _source = 'const title="星✨";function restart(){return title;}';
final _dto = jsonEncode(boundSourceChunk('game.js', _source));
final _messages = [
  Message.system('Return exactly the JSON source DTO; no prose or markdown.'),
  Message.user('任意形态的小游戏和小程序，保留所有页面、原始需求和完整内容。'),
];

http.Response _rejected({
  String parameter = 'response_format',
  String code = 'unsupported_parameter',
  int status = 400,
  String? type = 'invalid_request_error',
}) => http.Response(
  jsonEncode({
    'error': {
      'param': parameter,
      'code': code,
      'type': ?type,
      'message': 'PRIVATE_PROVIDER_TEXT',
    },
  }),
  status,
);
http.Response _success({String? finish = 'stop', String? content}) =>
    http.Response(
      jsonEncode({
        'choices': [
          {
            'finish_reason': finish,
            'message': {'content': content ?? _dto},
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
Matcher _failure(String code) => throwsA(
  isA<LLMResponseIntegrityException>().having(
    (e) => e.runtimeReason,
    'fixed code',
    'generated_task_failure:$code',
  ),
);

OpenAIProvider _provider(
  http.Client transport, {
  Map<String, dynamic> extra = const {},
}) => OpenAIProvider(
  apiKey: 'synthetic-key',
  model: 'chosen-model',
  baseUrl: 'https://compatible.example.test/v1',
  httpClient: transport,
  extraBody: extra,
);

void main() {
  for (final parameter in ['response_format', 'response_format.type']) {
    for (final code in [
      'unsupported_parameter',
      'unsupported_value',
      'unknown_parameter',
    ]) {
      test(
        'source negotiates $parameter/$code once with identical frozen payload',
        () async {
          final requests = <http.Request>[], bodies = <Map>[];
          var admissions = 0;
          final extra = <String, dynamic>{
            'provider_option': {'value': 'original'},
            'max_tokens': 16,
          };
          final client = _provider(
            MockClient((request) async {
              requests.add(request);
              bodies.add(jsonDecode(request.body) as Map);
              if (requests.length == 1) {
                expect(admissions, 1);
                (extra['provider_option'] as Map)['value'] =
                    'changed-after-dispatch';
                return _rejected(parameter: parameter, code: code);
              }
              expect(admissions, 2);
              return _success();
            }),
            extra: extra,
          );
          final result = await client.generateProjectSource(
            _messages,
            onAdmitted: () => admissions++,
          );
          expect(requests, hasLength(2));
          expect(requests.map((r) => r.url).toSet(), {
            Uri.parse('https://compatible.example.test/v1/chat/completions'),
          });
          expect(requests.map((r) => r.headers['Authorization']).toSet(), {
            'Bearer synthetic-key',
          });
          expect(bodies.first['response_format'], {'type': 'json_object'});
          final expected = Map.from(bodies.first)..remove('response_format');
          expect(bodies.last, expected);
          expect(bodies.last['model'], 'chosen-model');
          expect(bodies.last['messages'], [
            for (final message in _messages) message.toJson(),
          ]);
          expect(bodies.last['provider_option'], {'value': 'original'});
          expect(bodies.last.containsKey('max_tokens'), isFalse);
          expect(result.visibleText, _dto);
          expect(result.isComplete, isTrue);
          final chunk = SourceChunk.decode(
            result.visibleText,
            knownLength: false,
            file: SourceFileSnapshot(
              plan: SourceFilePlan(
                id: 'game.js',
                kind: SourceFileKind.js,
                purpose: 'All requested functionality',
              ),
            ),
          );
          expect(chunk.append, _source);
        },
      );
    }
  }

  for (final response in [
    _rejected(parameter: 'messages'),
    _rejected(code: 'invalid_request_error'),
    _rejected(type: 'server_error'),
    _rejected(status: 422),
    _rejected(status: 401),
    _rejected(status: 429),
    _rejected(status: 503),
    http.Response(
      jsonEncode({
        'error': {'message': 'response_format json_object not supported'},
      }),
      400,
    ),
    http.Response('not a JSON error', 400),
  ]) {
    test(
      'uncertain or non-400 rejection never negotiates source: ${response.statusCode}/${response.body}',
      () async {
        var sends = 0;
        final client = _provider(
          MockClient((_) async {
            sends++;
            return response;
          }),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          throwsA(isA<LLMResponseIntegrityException>()),
        );
        expect(sends, 1);
      },
    );
  }

  test('a second format rejection stops at two sends', () async {
    var sends = 0;
    final client = _provider(
      MockClient((_) async {
        sends++;
        return _rejected();
      }),
    );
    await expectLater(
      client.generateProjectSource(_messages),
      _failure('structuredOutputUnsupported'),
    );
    expect(sends, 2);
  });

  for (final integrity in [
    ('content_filter', 'modelSafetyBlocked'),
    ('tool_calls', 'responseInvalid'),
  ]) {
    test(
      'fallback retains source terminal integrity: ${integrity.$1}',
      () async {
        var sends = 0;
        final client = _provider(
          MockClient(
            (_) async =>
                ++sends == 1 ? _rejected() : _success(finish: integrity.$1),
          ),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          _failure(integrity.$2),
        );
        expect(sends, 2);
      },
    );
  }

  test(
    'length in textual JSON remains a bounded source continuation',
    () async {
      var sends = 0;
      final client = _provider(
        MockClient(
          (_) async => ++sends == 1
              ? _rejected()
              : _success(
                  finish: 'length',
                  content: '{"fileId":"game.js","append":"const title=',
                ),
        ),
      );
      final response = await client.generateProjectSource(_messages);
      expect(response.isComplete, isFalse);
      expect(
        response.visibleText,
        '{"fileId":"game.js","append":"const title=',
      );
      expect(sends, 2);
    },
  );

  test('textual fallback does not make a non-JSON source DTO valid', () async {
    var sends = 0;
    final client = _provider(
      MockClient(
        (_) async => ++sends == 1
            ? _rejected()
            : _success(content: 'I will write a game later.'),
      ),
    );
    final response = await client.generateProjectSource(_messages);
    expect(
      () => SourceChunk.decode(
        response.visibleText,
        knownLength: false,
        file: SourceFileSnapshot(
          plan: SourceFilePlan(
            id: 'game.js',
            kind: SourceFileKind.js,
            purpose: 'Full source',
          ),
        ),
      ),
      throwsA(isA<SourceWorkspaceProtocolException>()),
    );
    expect(sends, 2);
  });

  test('network uncertainty does not dispatch a fallback', () async {
    var sends = 0;
    final failure = http.ClientException('PRIVATE_NETWORK_DETAILS');
    final client = _provider(
      MockClient((_) async {
        sends++;
        throw failure;
      }),
    );
    await expectLater(
      client.generateProjectSource(_messages),
      throwsA(same(failure)),
    );
    expect(sends, 1);
  });

  test(
    'accepted but interrupted stream never negotiates another request',
    () async {
      var sends = 0;
      final client = _provider(
        MockClient((_) async {
          sends++;
          return http.Response(
            'data: {"choices":[{"delta":{"content":"{"}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      await expectLater(
        client.generateProjectSource(_messages),
        _failure('modelStreamInterrupted'),
      );
      expect(sends, 1);
    },
  );

  test('fallback rechecks live privacy before dispatch', () async {
    var sends = 0, checks = 0;
    var allowed = true;
    final inner = _provider(
      MockClient((_) async {
        sends++;
        allowed = false;
        return _rejected();
      }),
    );
    final guarded = privacyGuardedLLMClient(inner, () async {
      checks++;
      if (!allowed) {
        throw const LLMResponseIntegrityException.publicFailure(
          'modelConsentRequired',
        );
      }
    });
    await expectLater(
      generateProjectSourceWithPrivacyAdmission(
        guarded,
        _messages,
        onAdmitted: () {},
      ),
      _failure('modelConsentRequired'),
    );
    expect(sends, 1);
    expect(checks, greaterThanOrEqualTo(3));
  });

  test('cancellation at second admission prevents the second send', () async {
    var sends = 0, admissions = 0;
    var cancelled = false;
    final client = _provider(
      MockClient((_) async {
        sends++;
        return _rejected();
      }),
    );
    await expectLater(
      client.generateProjectSource(
        _messages,
        shouldCancel: () => cancelled,
        onAdmitted: () {
          if (++admissions == 2) cancelled = true;
        },
      ),
      _failure('interrupted'),
    );
    expect(admissions, 2);
    expect(sends, 1);
  });

  for (final jsonMode in [false, true]) {
    test(
      '${jsonMode ? 'ordinary structured JSON' : 'chat/voice text'} rejection remains single dispatch',
      () async {
        var sends = 0;
        final client = _provider(
          MockClient((_) async {
            sends++;
            return _rejected();
          }),
        );
        await expectLater(
          jsonMode ? client.chatJsonObject(_messages) : client.chat(_messages),
          throwsA(isA<LLMResponseIntegrityException>()),
        );
        expect(sends, 1);
      },
    );
  }
}
