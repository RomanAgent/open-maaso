import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/project_build/data/project_build_gateway.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';
import 'support/project_build_fixtures.dart';

http.Response _ok(Object data) => http.Response(
  jsonEncode({
    'code': 'OK',
    'message': 'ok',
    'traceId': 'trace-build',
    'data': data,
  }),
  200,
);

void main() {
  test(
    'uses independent endpoints, standard envelope and exact nonce',
    () async {
      final fixture = projectBuildWireFixture();
      final requests = <http.Request>[];
      final gateway = HttpProjectBuildGateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => projectBuildTestScope,
        accessToken: () async => 'synthetic-token',
        isCurrent: () => true,
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['authorization'], 'Bearer synthetic-token');
          expect(request.followRedirects, isFalse);
          if (request.method == 'POST') return _ok(fixture['createReceipt']!);
          return _ok(
            request.url.path.endsWith('/events')
                ? fixture['eventsPage']!
                : fixture['snapshot']!,
          );
        }),
      );
      final receipt = await gateway.create(
        request: projectBuildInput(),
        expectedContextKey: projectBuildTestScope,
      );
      await gateway.snapshot(
        taskId: receipt.taskId,
        expectedContextKey: projectBuildTestScope,
      );
      await gateway.events(
        taskId: receipt.taskId,
        afterTaskSequence: 0,
        expectedContextKey: projectBuildTestScope,
      );
      expect(requests.map((r) => r.url.path), [
        '/v1/project-builds',
        '/v1/project-builds/${receipt.taskId}',
        '/v1/project-builds/${receipt.taskId}/events',
      ]);
      expect(jsonDecode(requests.first.body), fixture['createRequest']);
      expect(requests.last.url.queryParameters, {
        'afterTaskSequence': '0',
        'limit': '100',
      });
      await gateway.deactivateAndDrain();
    },
  );

  test('late account or environment response is fenced out', () async {
    var scope = projectBuildTestScope;
    final response = Completer<http.Response>();
    final gateway = HttpProjectBuildGateway(
      baseUri: () => Uri.parse('https://example.invalid/'),
      contextKey: () => scope,
      accessToken: () async => 'synthetic',
      isCurrent: () => true,
      client: MockClient((_) => response.future),
    );
    final work = gateway.snapshot(
      taskId: projectBuildReceipt().taskId,
      expectedContextKey: projectBuildTestScope,
    );
    await pumpEventQueue();
    scope = 'production|other';
    response.complete(_ok(projectBuildWireFixture()['snapshot']!));
    await expectLater(
      work,
      throwsA(
        isA<ProjectBuildRequestException>().having(
          (e) => e.code,
          'code',
          'project_build_scope_changed',
        ),
      ),
    );
    await gateway.deactivateAndDrain();
  });

  test(
    'network ambiguity never dispatches fallback or another nonce',
    () async {
      var calls = 0;
      final gateway = HttpProjectBuildGateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => projectBuildTestScope,
        accessToken: () async => 'synthetic',
        isCurrent: () => true,
        client: MockClient((_) async {
          calls++;
          throw http.ClientException('offline');
        }),
      );
      await expectLater(
        gateway.create(
          request: projectBuildInput(),
          expectedContextKey: projectBuildTestScope,
        ),
        throwsA(
          isA<ProjectBuildRequestException>().having(
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

  test(
    'token lookup shares deadline and retirement cancels a never-ending lookup',
    () async {
      for (final retire in [false, true]) {
        var httpCalls = 0;
        final token = Completer<String>();
        final gateway = HttpProjectBuildGateway(
          baseUri: () => Uri.parse('https://example.invalid/'),
          contextKey: () => projectBuildTestScope,
          accessToken: () => token.future,
          isCurrent: () => true,
          timeout: retire
              ? const Duration(hours: 1)
              : const Duration(milliseconds: 30),
          client: MockClient((_) async {
            httpCalls++;
            return _ok(projectBuildWireFixture()['snapshot']!);
          }),
        );
        final request = gateway.snapshot(
          taskId: projectBuildReceipt().taskId,
          expectedContextKey: projectBuildTestScope,
        );
        final failed = expectLater(
          request,
          throwsA(
            isA<ProjectBuildRequestException>().having(
              (e) => e.code,
              'code',
              retire
                  ? 'project_build_scope_changed'
                  : 'project_build_request_timeout',
            ),
          ),
        );
        await pumpEventQueue();
        if (retire) {
          await gateway.deactivateAndDrain().timeout(
            const Duration(seconds: 1),
          );
        }
        await failed;
        await gateway.deactivateAndDrain();
        expect(httpCalls, 0);
      }
    },
  );

  test(
    'token, headers and body consume one deadline instead of restarting it',
    () async {
      final gateway = HttpProjectBuildGateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => projectBuildTestScope,
        accessToken: () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 'synthetic';
        },
        isCurrent: () => true,
        timeout: const Duration(milliseconds: 90),
        client: _PhasedClient(),
      );
      await expectLater(
        gateway.snapshot(
          taskId: projectBuildReceipt().taskId,
          expectedContextKey: projectBuildTestScope,
        ),
        throwsA(
          isA<ProjectBuildRequestException>().having(
            (e) => e.code,
            'code',
            'project_build_request_timeout',
          ),
        ),
      );
      await gateway.deactivateAndDrain();
    },
  );

  test('body size and absolute timeout bound malformed responses', () async {
    for (final oversized in [true, false]) {
      final body = StreamController<List<int>>();
      Timer? trickle;
      final gateway = HttpProjectBuildGateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => projectBuildTestScope,
        accessToken: () async => 'synthetic',
        isCurrent: () => true,
        client: _StreamingClient(body.stream),
        timeout: const Duration(milliseconds: 40),
      );
      final work = gateway.snapshot(
        taskId: projectBuildReceipt().taskId,
        expectedContextKey: projectBuildTestScope,
      );
      if (oversized) {
        body.add(List.filled(1024 * 1024 + 1, 32));
      } else {
        trickle = Timer.periodic(
          const Duration(milliseconds: 5),
          (_) => body.add([32]),
        );
      }
      await expectLater(
        work,
        throwsA(
          isA<ProjectBuildRequestException>().having(
            (e) => e.code,
            'code',
            oversized
                ? 'project_build_response_too_large'
                : 'project_build_request_timeout',
          ),
        ),
      );
      trickle?.cancel();
      await body.close();
      await gateway.deactivateAndDrain();
    }
  });

  test(
    'success without supported worker/result contract is rejected',
    () async {
      final gateway = HttpProjectBuildGateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => projectBuildTestScope,
        accessToken: () async => 'synthetic',
        isCurrent: () => true,
        client: MockClient(
          (_) async => _ok({
            ...projectBuildObject(projectBuildWireFixture()['snapshot']),
            'status': 'succeeded',
          }),
        ),
      );
      await expectLater(
        gateway.snapshot(
          taskId: projectBuildReceipt().taskId,
          expectedContextKey: projectBuildTestScope,
        ),
        throwsA(
          isA<ProjectBuildRequestException>().having(
            (e) => e.code,
            'code',
            'invalid_project_build_response',
          ),
        ),
      );
      await gateway.deactivateAndDrain();
    },
  );
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.body);
  final Stream<List<int>> body;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body, 200);
}

class _PhasedClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return http.StreamedResponse(
      Stream<List<int>>.fromFuture(
        Future<List<int>>.delayed(
          const Duration(milliseconds: 70),
          () => _ok(projectBuildWireFixture()['snapshot']!).bodyBytes,
        ),
      ),
      200,
    );
  }
}
