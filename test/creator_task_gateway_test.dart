import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/creator/data/creator_task_gateway.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'support/creator_task_fixtures.dart';

http.Response ok(Object data) => http.Response(
  jsonEncode({
    'code': 'OK',
    'message': 'ok',
    'traceId': 'trace-test',
    'data': data,
  }),
  200,
);
void main() {
  test(
    'uses durable endpoints exact request IDs and standard owner token',
    () async {
      final paths = <String>[];
      final gateway = HttpCreatorTaskGateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => testCreatorScope,
        accessToken: () async => 'synthetic-token',
        isCurrent: () => true,
        available: true,
        client: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers['authorization'], 'Bearer synthetic-token');
          if (request.method == 'POST') {
            final body = jsonDecode(request.body) as Map;
            expect(body.containsKey('accountUuid'), isFalse);
            expect(body['requestId'], createRequestId);
            expect(body['kind'], 'creator_image');
            expect(body['image'], taskImageInput.toJson());
            return ok(taskReceipt().toJson());
          }
          if (request.url.path.endsWith('/events'))
            return ok({
              'events': [
                {
                  'sequence': 1,
                  'task': taskSnapshot(1, CreatorTaskStatus.queued).toJson(),
                },
              ],
              'nextSequence': 1,
              'hasMore': false,
            });
          return ok(taskSnapshot(1, CreatorTaskStatus.queued).toJson());
        }),
      );
      expect(
        (await gateway.create(
          requestId: createRequestId,
          agentId: 'self',
          input: taskImageInput,
          expectedContextKey: testCreatorScope,
        )).taskId,
        taskId,
      );
      await gateway.snapshot(
        taskId: taskId,
        expectedContextKey: testCreatorScope,
      );
      final page = await gateway.events(
        taskId: taskId,
        agentId: 'self',
        afterSequence: 0,
        expectedContextKey: testCreatorScope,
      );
      expect(page.nextSequence, 1);
      expect(paths, [
        '/v1/tasks',
        '/v1/tasks/$taskId',
        '/v1/tasks/$taskId/events',
      ]);
      expect(
        paths.any((p) => p.contains('/creator/images/generations')),
        isFalse,
      );
      await gateway.deactivateAndDrain();
    },
  );
  test('late response after account change is refused', () async {
    var scope = testCreatorScope;
    final response = Completer<http.Response>();
    final gateway = HttpCreatorTaskGateway(
      baseUri: () => Uri.parse('https://example.invalid/'),
      contextKey: () => scope,
      accessToken: () async => 'synthetic',
      isCurrent: () => true,
      available: true,
      client: MockClient((_) => response.future),
    );
    final request = gateway.snapshot(
      taskId: taskId,
      expectedContextKey: testCreatorScope,
    );
    await pumpEventQueue();
    scope = 'test|other';
    response.complete(ok(taskSnapshot(1, CreatorTaskStatus.queued).toJson()));
    await expectLater(
      request,
      throwsA(
        isA<CreatorTaskRequestException>().having(
          (e) => e.code,
          'code',
          'task_scope_changed',
        ),
      ),
    );
    await gateway.deactivateAndDrain();
  });
  test(
    'rejects gaps foreign task events and malformed signed result',
    () async {
      for (final data in [
        {
          'events': [
            {
              'sequence': 2,
              'task': taskSnapshot(2, CreatorTaskStatus.running).toJson(),
            },
          ],
          'nextSequence': 2,
          'hasMore': false,
        },
        {'events': [], 'nextSequence': 0, 'hasMore': true},
      ]) {
        final gateway = HttpCreatorTaskGateway(
          baseUri: () => Uri.parse('https://example.invalid/'),
          contextKey: () => testCreatorScope,
          accessToken: () async => 'synthetic',
          isCurrent: () => true,
          available: true,
          client: MockClient((_) async => ok(data)),
        );
        await expectLater(
          gateway.events(
            taskId: taskId,
            agentId: 'self',
            afterSequence: 0,
            expectedContextKey: testCreatorScope,
          ),
          throwsA(isA<CreatorTaskRequestException>()),
        );
        await gateway.deactivateAndDrain();
      }
    },
  );
  test(
    'network failure remains ambiguous and never dispatches legacy fallback',
    () async {
      var calls = 0;
      final gateway = HttpCreatorTaskGateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => testCreatorScope,
        accessToken: () async => 'synthetic',
        isCurrent: () => true,
        available: true,
        client: MockClient((request) async {
          calls++;
          expect(request.url.path, '/v1/tasks');
          throw http.ClientException('synthetic offline');
        }),
      );
      await expectLater(
        gateway.create(
          requestId: createRequestId,
          agentId: 'self',
          input: taskImageInput,
          expectedContextKey: testCreatorScope,
        ),
        throwsA(
          isA<CreatorTaskRequestException>().having(
            (e) => e.ambiguous,
            'ambiguous',
            isTrue,
          ),
        ),
      );
      expect(calls, 1);
      await gateway.deactivateAndDrain();
    },
  );
}
