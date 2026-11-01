import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/features/widgets_hub/application/game_frame_processor.dart';
import 'package:maaso/src/features/widgets_hub/data/game_perception_gateway.dart';

ProcessedGameFrame fixtureFrame() {
  final bytes = Uint8List.fromList([255, 216, 255, 217]);
  return ProcessedGameFrame(
    jpegBytes: bytes,
    contentHash: sha256.convert(bytes).toString(),
    width: 16,
    height: 16,
    fingerprint: Uint8List(1024),
  );
}

Object errorCode(String code) =>
    isA<GamePerceptionException>().having((e) => e.code, 'code', code);
void main() {
  test(
    'authenticated transient frame uses canonical UUID and source binding',
    () async {
      var authorized = false;
      final frame = fixtureFrame();
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {
          authorized = true;
        },
        isCurrent: () => true,
        client: MockClient((request) async {
          expect(authorized, isTrue);
          expect(request.url.path, '/v1/proxy/game-perception/analyze');
          expect(request.headers['Authorization'], 'Bearer synthetic');
          final body = jsonDecode(request.body) as Map;
          expect(body.keys.toSet(), {
            'requestId',
            'question',
            'locale',
            'media',
          });
          expect(
            body['requestId'],
            matches(
              RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              ),
            ),
          );
          expect(body['media'][0]['data'], base64Encode(frame.jpegBytes));
          expect(body['media'][0]['durationMs'], 0);
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'data': {
                'description': 'A piece moved.',
                'modelId': 'vision',
                'sourceMediaIds': [frame.contentHash],
              },
            }),
            200,
          );
        }),
      );
      final result = await gateway.analyze(
        frame: frame,
        question: 'What changed?',
        locale: 'en',
        cancelled: Completer<void>().future,
        requestIsCurrent: () => true,
      );
      expect(result.description, 'A piece moved.');
      expect(result.sourceMediaId, frame.contentHash);
      await gateway.shutdown();
    },
  );
  test(
    'revocation while token refresh is pending never sends a frame',
    () async {
      final token = Completer<String>(), cancel = Completer<void>();
      var tokenStarted = false, calls = 0;
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () {
          tokenStarted = true;
          return token.future;
        },
        authorize: () async {},
        isCurrent: () => true,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      final pending = gateway.analyze(
        frame: fixtureFrame(),
        question: '',
        locale: 'en',
        cancelled: cancel.future,
        requestIsCurrent: () => true,
      );
      while (!tokenStarted) {
        await Future<void>.delayed(Duration.zero);
      }
      final expectation = expectLater(
        pending,
        throwsA(errorCode('GAME_PERCEPTION_CANCELLED')),
      );
      cancel.complete();
      await expectation;
      token.complete('synthetic');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
      await gateway.shutdown();
    },
  );
  test(
    'privacy refusal and last-boundary retirement do not dispatch',
    () async {
      for (final deny in [true, false]) {
        var current = true, calls = 0;
        final gateway = GamePerceptionGateway(
          baseUri: Uri.parse('https://synthetic.invalid/'),
          accessToken: () async {
            current = false;
            return 'synthetic';
          },
          authorize: () async {
            if (deny) throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
          },
          isCurrent: () => current,
          client: MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }),
        );
        await expectLater(
          gateway.analyze(
            frame: fixtureFrame(),
            question: '',
            locale: 'en',
            cancelled: Completer<void>().future,
            requestIsCurrent: () => true,
          ),
          throwsA(
            errorCode(
              deny ? 'PRIVACY_CONSENT_REQUIRED' : 'GAME_PERCEPTION_CANCELLED',
            ),
          ),
        );
        expect(calls, 0);
        await gateway.shutdown();
      }
    },
  );
  test(
    'deadline aborts the request and awaits actual transport completion',
    () async {
      final client = _DrainControlledClient();
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
        client: client,
      );
      var completed = false;
      final pending = gateway.analyze(
        frame: fixtureFrame(),
        question: '',
        locale: 'en',
        cancelled: Completer<void>().future,
        requestIsCurrent: () => true,
        deadline: const Duration(milliseconds: 20),
      );
      final expectation = expectLater(
        pending.whenComplete(() => completed = true),
        throwsA(errorCode('GAME_PERCEPTION_TIMEOUT')),
      );
      await client.aborted.future;
      expect(completed, isFalse);
      client.response.completeError(http.RequestAbortedException(client.uri));
      await expectation;
      await gateway.shutdown();
      expect(client.closed, isFalse);
    },
  );
  test(
    'one account gateway cannot overlap transports across replacement sessions',
    () async {
      final client = _DrainControlledClient();
      final cancellation = Completer<void>();
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
        client: client,
      );
      final first = gateway.analyze(
        frame: fixtureFrame(),
        question: '',
        locale: 'en',
        cancelled: cancellation.future,
        requestIsCurrent: () => true,
      );
      final done = expectLater(
        first,
        throwsA(errorCode('GAME_PERCEPTION_CANCELLED')),
      );
      await expectLater(
        gateway.analyze(
          frame: fixtureFrame(),
          question: '',
          locale: 'en',
          cancelled: Completer<void>().future,
          requestIsCurrent: () => true,
        ),
        throwsA(errorCode('GAME_PERCEPTION_BUSY')),
      );
      while (client.uri == null) {
        await Future<void>.delayed(Duration.zero);
      }
      cancellation.complete();
      await client.aborted.future;
      client.response.completeError(http.RequestAbortedException(client.uri));
      await done;
      await gateway.shutdown();
    },
  );
  test('bounded response and wrong source IDs are rejected', () async {
    for (final body in [
      List.filled(32769, 'x').join(),
      jsonEncode({
        'code': 'OK',
        'data': {
          'description': 'Wrong frame',
          'modelId': 'vision',
          'sourceMediaIds': ['other'],
        },
      }),
    ]) {
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        gateway.analyze(
          frame: fixtureFrame(),
          question: '',
          locale: 'en',
          cancelled: Completer<void>().future,
          requestIsCurrent: () => true,
        ),
        throwsA(errorCode('GAME_PERCEPTION_INVALID_RESPONSE')),
      );
      await gateway.shutdown();
    }
  });
  test(
    'server backpressure carries a bounded retry and never retries automatically',
    () async {
      var calls = 0;
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
        client: MockClient((_) async {
          calls++;
          return http.Response(
            '{"code":"GAME_PERCEPTION_BUSY","message":"private diagnostics ignored"}',
            429,
            headers: {'retry-after': '5'},
          );
        }),
      );
      await expectLater(
        gateway.analyze(
          frame: fixtureFrame(),
          question: '',
          locale: 'en',
          cancelled: Completer<void>().future,
          requestIsCurrent: () => true,
        ),
        throwsA(
          isA<GamePerceptionException>()
              .having((e) => e.code, 'code', 'GAME_PERCEPTION_BUSY')
              .having((e) => e.retryAfter, 'retry', const Duration(seconds: 5)),
        ),
      );
      expect(calls, 1);
      await gateway.shutdown();
    },
  );
  test(
    'scheduled uploads have no account call-count or byte allowance',
    () async {
      final start = DateTime.utc(2026);
      var now = start, calls = 0;
      final bytes = Uint8List(gameFrameMaximumBytes);
      final frame = ProcessedGameFrame(
        jpegBytes: bytes,
        contentHash: sha256.convert(bytes).toString(),
        width: 640,
        height: 640,
        fingerprint: Uint8List(1024),
      );
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
        now: () => now,
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'data': {
                'description': 'frame',
                'modelId': 'vision',
                'sourceMediaIds': [frame.contentHash],
              },
            }),
            200,
          );
        }),
      );
      for (var i = 0; i < 15; i++) {
        final result = await gateway.analyze(
          frame: frame,
          question: 'game-$i',
          locale: 'en',
          cancelled: Completer<void>().future,
          requestIsCurrent: () => true,
        );
        expect(result.sourceMediaId, frame.contentHash);
        now = now.add(const Duration(seconds: 3));
      }
      expect(calls, 15);
      expect(frame.jpegBytes.length * calls, greaterThan(3 * 1024 * 1024));
      expect(now.difference(start), lessThan(const Duration(minutes: 1)));
      await gateway.shutdown();
    },
  );
  for (final code in [
    'GAME_PERCEPTION_MEMBERSHIP_REQUIRED',
    'GAME_PERCEPTION_PREMIUM_REQUIRED',
  ]) {
    test(
      'server $code is preserved and access can be revalidated later',
      () async {
        var now = DateTime.utc(2026), allowed = false, calls = 0;
        final frame = fixtureFrame();
        final gateway = GamePerceptionGateway(
          baseUri: Uri.parse('https://synthetic.invalid/'),
          accessToken: () async => 'synthetic',
          authorize: () async {},
          isCurrent: () => true,
          now: () => now,
          client: MockClient((_) async {
            calls++;
            return allowed
                ? http.Response(
                    jsonEncode({
                      'code': 'OK',
                      'data': {
                        'description':
                            'Available after the server grants access.',
                        'modelId': 'vision',
                        'sourceMediaIds': [frame.contentHash],
                      },
                    }),
                    200,
                  )
                : http.Response(
                    jsonEncode({'code': code, 'message': 'not copied into UI'}),
                    403,
                  );
          }),
        );
        Future<GamePerceptionResult> send() => gateway.analyze(
          frame: frame,
          question: '',
          locale: 'en',
          cancelled: Completer<void>().future,
          requestIsCurrent: () => true,
        );
        await expectLater(
          send(),
          throwsA(
            isA<GamePerceptionException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.statusCode, 'status', 403),
          ),
        );
        expect(calls, 1);
        allowed = true;
        now = now.add(const Duration(seconds: 3));
        expect((await send()).sourceMediaId, frame.contentHash);
        expect(calls, 2);
        await gateway.shutdown();
      },
    );
  }
  test(
    'technical spacing applies to refusals and uncertain transports without spending credits',
    () async {
      final frame = fixtureFrame();
      var calls = 0;
      var now = DateTime.utc(2026);
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
        now: () => now,
        client: MockClient((_) async {
          calls++;
          if (calls == 1) {
            return http.Response('{"code":"GAME_PERCEPTION_DISABLED"}', 503);
          }
          throw http.ClientException('PRIVATE network diagnostics');
        }),
      );
      Future<GamePerceptionResult> send() => gateway.analyze(
        frame: frame,
        question: '',
        locale: 'en',
        cancelled: Completer<void>().future,
        requestIsCurrent: () => true,
      );
      await expectLater(send(), throwsA(errorCode('GAME_PERCEPTION_DISABLED')));
      await expectLater(send(), throwsA(errorCode('GAME_PERCEPTION_BUSY')));
      expect(calls, 1);
      now = now.add(const Duration(seconds: 3));
      await expectLater(
        send(),
        throwsA(errorCode('GAME_PERCEPTION_UNAVAILABLE')),
      );
      await expectLater(send(), throwsA(errorCode('GAME_PERCEPTION_BUSY')));
      expect(calls, 2);
      await gateway.shutdown();
    },
  );
  test(
    'performance dispatch interval remains in force across replacement pages',
    () async {
      var now = DateTime.utc(2026), calls = 0;
      final frame = fixtureFrame();
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
        now: () => now,
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'data': {
                'description': 'frame',
                'modelId': 'vision',
                'sourceMediaIds': [frame.contentHash],
              },
            }),
            200,
          );
        }),
      );
      Future<GamePerceptionResult> send() => gateway.analyze(
        frame: frame,
        question: '',
        locale: 'en',
        cancelled: Completer<void>().future,
        requestIsCurrent: () => true,
      );
      await send();
      now = now.add(const Duration(seconds: 1));
      await expectLater(
        send(),
        throwsA(
          isA<GamePerceptionException>()
              .having((e) => e.code, 'code', 'GAME_PERCEPTION_BUSY')
              .having((e) => e.retryAfter, 'retry', const Duration(seconds: 2)),
        ),
      );
      expect(calls, 1);
      now = now.add(const Duration(seconds: 2));
      await send();
      expect(calls, 2);
      await gateway.shutdown();
    },
  );
}

class _DrainControlledClient extends http.BaseClient {
  final aborted = Completer<void>();
  final response = Completer<http.StreamedResponse>();
  Uri? uri;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    uri = request.url;
    expect(request, isA<http.AbortableRequest>());
    (request as http.AbortableRequest).abortTrigger!.then(
      (_) => aborted.complete(),
    );
    return response.future;
  }

  @override
  void close() {
    closed = true;
  }
}
