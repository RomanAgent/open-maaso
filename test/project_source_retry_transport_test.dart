import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/gemini_provider.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/llm/openai_provider.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _private = 'PRIVATE_PROVIDER_BODY_OR_REASONING';
const _headers = {
  'content-type': 'text/event-stream',
  'x-maaso-output-format': 'json_object',
  'x-maaso-generation-mode': 'project_source',
};
final _messages = [Message.system('Return JSON'), Message.user('Build a game')];
String _event(String name, Object payload) =>
    'event: $name\ndata: ${jsonEncode(payload)}\n\n';
String get _partial => _event('reply.delta', {'delta': '{"append":"partial'});
String get _incomplete =>
    _event('completion', {'finishReason': 'unknown', 'status': 'incomplete'});
MaasoThinProxyLLMClient _thin(http.Client transport) => MaasoThinProxyLLMClient(
  baseUri: Uri.parse('https://api.example.test'),
  model: 'model',
  accessTokenProvider: () async => 'synthetic',
  httpClient: transport,
);
Matcher _failure(
  String code, {
  required bool retryable,
  Duration? retryAfter,
}) => throwsA(
  isA<LLMResponseIntegrityException>()
      .having(
        (error) => error.runtimeReason,
        'code',
        'generated_task_failure:$code',
      )
      .having((error) => error.retryable, 'retryable', retryable)
      .having((error) => error.retryAfter, 'retryAfter', retryAfter)
      .having(
        (error) => error.toString(),
        'sanitized',
        isNot(contains(_private)),
      ),
);

class _StreamClient extends http.BaseClient {
  _StreamClient(this.body, {this.status = 200});
  final Stream<List<int>> Function() body;
  final int status;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body(), status, headers: _headers);
}

void main() {
  for (final entry in [
    (503, 'MODEL_PROVIDER_ERROR', 'modelUnavailable'),
    (503, 'MODEL_TRANSPORT_ERROR', 'modelStreamInterrupted'),
    (503, 'MODEL_STREAM_INCOMPLETE', 'modelStreamInterrupted'),
    (429, 'MODEL_RATE_LIMITED', 'modelRateLimited'),
  ]) {
    test(
      'source HTTP ${entry.$2} exposes a bounded retry hint without replay',
      () async {
        var calls = 0;
        final client = _thin(
          MockClient((_) async {
            calls++;
            return http.Response(
              jsonEncode({'code': entry.$2, 'message': _private}),
              entry.$1,
              headers: {'retry-after': '3'},
            );
          }),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          _failure(
            entry.$3,
            retryable: true,
            retryAfter: const Duration(seconds: 3),
          ),
        );
        expect(calls, 1);
      },
    );
  }

  for (final entry in [
    (503, 'MODEL_AUTHENTICATION', 'modelAuthentication'),
    (429, 'MODEL_QUOTA_EXCEEDED', 'modelQuotaExceeded'),
    (429, 'GENERATION_CREDIT_INSUFFICIENT', 'generationCreditInsufficient'),
    (503, 'GENERATION_PROFILE_UNAVAILABLE', 'generationProfileUnavailable'),
    (400, 'MODEL_CONTEXT_LIMIT', 'modelContextLimit'),
    (400, 'OUTPUT_FORMAT_UNSUPPORTED', 'structuredOutputUnsupported'),
  ]) {
    test(
      'source HTTP ${entry.$2} does not authorize automatic retry',
      () async {
        final client = _thin(
          MockClient(
            (_) async => http.Response(
              jsonEncode({
                'code': entry.$2,
                'message': _private,
                'retryable': true,
              }),
              entry.$1,
              headers: {'retry-after': '1'},
            ),
          ),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          _failure(entry.$3, retryable: false),
        );
      },
    );
  }

  for (final entry in [
    (400, 'INVALID_REQUEST'),
    (404, 'NOT_FOUND'),
    (403, 'MEMBERSHIP_REQUIRED'),
    (429, 'MEMBERSHIP_QUOTA_EXHAUSTED'),
    (503, 'UNKNOWN_UNAVAILABLE'),
  ]) {
    test(
      'unclassified HTTP ${entry.$1}/${entry.$2} is not promoted to transient',
      () async {
        final client = _thin(
          MockClient(
            (_) async =>
                http.Response(jsonEncode({'code': entry.$2}), entry.$1),
          ),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          throwsA(isA<HostedLLMFailure>()),
        );
      },
    );
  }

  test('incomplete source waits for its following non-retryable error', () async {
    final client = _thin(
      MockClient(
        (_) async => http.Response(
          '$_partial$_incomplete${_event('error', {'code': 'MODEL_AUTHENTICATION', 'retryable': false, 'message': _private})}',
          200,
          headers: _headers,
        ),
      ),
    );
    await expectLater(
      client.generateProjectSource(_messages),
      _failure('modelAuthentication', retryable: false),
    );
  });

  for (final retryable in [true, false]) {
    test(
      'source preserves explicit SSE retryable=$retryable after incomplete',
      () async {
        final client = _thin(
          MockClient(
            (_) async => http.Response(
              '$_partial$_incomplete${_event('error', {'code': 'MODEL_TRANSPORT_ERROR', 'retryable': retryable, 'message': _private})}',
              200,
              headers: _headers,
            ),
          ),
        );
        await expectLater(
          client.generateProjectSource(_messages),
          _failure('modelStreamInterrupted', retryable: retryable),
        );
      },
    );
  }

  test('unknown SSE code cannot grant retry even with retryable=true', () async {
    final client = _thin(
      MockClient(
        (_) async => http.Response(
          '$_partial$_incomplete${_event('error', {'code': 'UNKNOWN', 'retryable': true})}',
          200,
          headers: _headers,
        ),
      ),
    );
    await expectLater(
      client.generateProjectSource(_messages),
      _failure('responseInvalid', retryable: false),
    );
  });

  test(
    'source EOF rejects the prefix and exposes transient interruption',
    () async {
      final client = _thin(
        MockClient(
          (_) async => http.Response(_partial, 200, headers: _headers),
        ),
      );
      await expectLater(
        client.generateProjectSource(_messages),
        _failure('modelStreamInterrupted', retryable: true),
      );
    },
  );

  test(
    'ordinary JSON request does not inherit source retry classification',
    () async {
      final client = _thin(
        MockClient(
          (_) async => http.Response(
            '$_partial$_incomplete${_event('error', {'code': 'MODEL_TRANSPORT_ERROR', 'retryable': true})}',
            200,
            headers: _headers,
          ),
        ),
      );
      await expectLater(
        client.chatJsonObject(_messages),
        _failure('modelStreamInterrupted', retryable: false),
      );
    },
  );

  for (final bad in ['-1', 'garbage', '999999999999999999999']) {
    test('unbounded Retry-After $bad is not retained', () async {
      final client = _thin(
        MockClient(
          (_) async => http.Response(
            '{"code":"MODEL_RATE_LIMITED"}',
            429,
            headers: {'retry-after': bad},
          ),
        ),
      );
      await expectLater(
        client.generateProjectSource(_messages),
        _failure('modelRateLimited', retryable: true),
      );
    });
  }

  for (final mode in ['thin', 'openai', 'gemini']) {
    ProjectSourceLLMClient client(http.Client transport) => switch (mode) {
      'openai' => OpenAIProvider(apiKey: 'synthetic', httpClient: transport),
      'gemini' => GeminiProvider(apiKey: 'synthetic', httpClient: transport),
      _ => _thin(transport),
    };
    test(
      '$mode source network failures are transient without visible prefixes',
      () async {
        await expectLater(
          client(
            MockClient((_) async => throw http.ClientException(_private)),
          ).generateProjectSource(_messages),
          _failure('modelStreamInterrupted', retryable: true),
        );
      },
    );
    test('$mode source idle timeouts are transient', () async {
      final input = StreamController<List<int>>();
      final transport = _StreamClient(() => input.stream);
      await expectLater(
        client(transport).generateProjectSource(
          _messages,
          timeout: const Duration(milliseconds: 5),
        ),
        _failure('modelTimeout', retryable: true),
      );
      await input.close();
    });
  }

  test(
    'direct provider quota remains terminal and service errors become retryable only for source',
    () async {
      final provider = OpenAIProvider(
        apiKey: 'synthetic',
        httpClient: MockClient(
          (_) async =>
              http.Response('{"error":{"code":"insufficient_quota"}}', 429),
        ),
      );
      await expectLater(
        provider.generateProjectSource(_messages),
        _failure('modelQuotaExceeded', retryable: false),
      );
      final service = OpenAIProvider(
        apiKey: 'synthetic',
        httpClient: MockClient((_) async => http.Response('{}', 503)),
      );
      await expectLater(
        service.generateProjectSource(_messages),
        _failure('modelUnavailable', retryable: true),
      );
      await expectLater(
        service.chatJsonObject(_messages),
        _failure('modelUnavailable', retryable: false),
      );
    },
  );

  test(
    'Gemini ambiguous quota rejection does not automatically retry',
    () async {
      final provider = GeminiProvider(
        apiKey: 'synthetic',
        httpClient: MockClient((_) async => http.Response('{}', 429)),
      );
      await expectLater(
        provider.generateProjectSource(_messages),
        _failure('modelRateLimited', retryable: false),
      );
    },
  );

  for (final status in [401, 403, 429, 503]) {
    test(
      'broken HTTP $status rejection body cannot authorize source retry',
      () async {
        final input = StreamController<List<int>>();
        final client = _thin(_StreamClient(() => input.stream, status: status));
        await expectLater(
          client.generateProjectSource(
            _messages,
            timeout: const Duration(milliseconds: 5),
          ),
          throwsA(isA<HostedLLMFailure>()),
        );
        await input.close();
        final directInput = StreamController<List<int>>();
        final provider = OpenAIProvider(
          apiKey: 'synthetic',
          httpClient: _StreamClient(() => directInput.stream, status: status),
        );
        await expectLater(
          provider.generateProjectSource(
            _messages,
            timeout: const Duration(milliseconds: 5),
          ),
          throwsA(
            isA<LLMResponseIntegrityException>().having(
              (e) => e.retryable,
              'retryable',
              false,
            ),
          ),
        );
        await directInput.close();
      },
    );
  }

  for (final status in [502, 503, 504]) {
    for (final body in ['<html>temporary gateway error</html>', '{}']) {
      test(
        'bare HTTP $status gateway failure is transient without changing ordinary JSON behavior: $body',
        () async {
          final client = _thin(
            MockClient((_) async => http.Response(body, status)),
          );
          await expectLater(
            client.generateProjectSource(_messages),
            _failure('modelUnavailable', retryable: true),
          );
          await expectLater(
            client.chatJsonObject(_messages),
            throwsA(isA<HostedLLMFailure>()),
          );
        },
      );
    }
  }
  test(
    'a gateway code or explicit rejection never enters the bare gateway fallback',
    () async {
      for (final body in [
        '{"code":"UNKNOWN","retryable":true}',
        '{"data":{"code":"DENIED"}}',
        '{"code":0}',
        '{"retryable":false}',
      ]) {
        final client = _thin(MockClient((_) async => http.Response(body, 503)));
        await expectLater(
          client.generateProjectSource(_messages),
          throwsA(isA<HostedLLMFailure>()),
        );
      }
    },
  );
}
