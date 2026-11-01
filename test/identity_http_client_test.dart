import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/identity/data/identity_http_client.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';

http.Response _ok() => http.Response(
  jsonEncode({
    'code': 'OK',
    'data': {
      'playerActorId': 'player-1',
      'playerName': '星河',
      'agentActorId': 'agent-1',
      'agentName': 'Wheat',
      'version': 1,
    },
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Matcher failure(IdentityFailure value) =>
    isA<IdentityException>().having((error) => error.failure, 'failure', value);

void main() {
  test(
    'GET and CAS POST use authenticated exact contract without actor spoofing',
    () async {
      final requests = <http.Request>[];
      final client = IdentityHttpClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'account-a',
        accessToken: () async => 'token-a',
        client: MockClient((request) async {
          requests.add(request);
          return _ok();
        }),
      );
      final profile = await client.fetch(
        expectedContextKey: client.requestContextKey,
      );
      expect(profile.playerName, '星河');
      await client.update(
        expectedContextKey: client.requestContextKey,
        expectedVersion: 0,
        playerName: ' 星河 ',
        agentName: ' Wheat ',
      );
      expect(requests.first.method, 'GET');
      expect(requests.first.url.path, '/v1/identity/profile');
      expect(requests.last.url.path, '/v1/identity/profile/update');
      expect(requests.last.headers['authorization'], 'Bearer token-a');
      expect(jsonDecode(requests.last.body), {
        'expectedVersion': 0,
        'playerName': '星河',
        'agentName': 'Wheat',
      });
      client.close();
    },
  );

  test(
    'account change during token refresh prevents sending HTTP request',
    () async {
      var account = 'a';
      var requests = 0;
      final token = Completer<String>();
      final client = IdentityHttpClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => account,
        accessToken: () => token.future,
        client: MockClient((_) async {
          requests++;
          return _ok();
        }),
      );
      final result = client.fetch(expectedContextKey: client.requestContextKey);
      final check = expectLater(
        result,
        throwsA(failure(IdentityFailure.contextChanged)),
      );
      account = 'b';
      token.complete('a-token');
      await check;
      expect(requests, 0);
    },
  );

  test(
    'late response cannot be accepted by a replacement account or closed client',
    () async {
      var account = 'a';
      final response = Completer<http.Response>();
      final sent = Completer<void>();
      final client = IdentityHttpClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => account,
        accessToken: () async => 'token',
        client: MockClient((_) {
          sent.complete();
          return response.future;
        }),
      );
      final result = client.fetch(expectedContextKey: client.requestContextKey);
      final check = expectLater(
        result,
        throwsA(failure(IdentityFailure.contextChanged)),
      );
      await sent.future;
      account = 'b';
      response.complete(_ok());
      await check;
      client.close();
      await expectLater(
        client.fetch(expectedContextKey: client.requestContextKey),
        throwsA(failure(IdentityFailure.contextChanged)),
      );
    },
  );

  test('conflicts are typed and never retried', () async {
    var requests = 0;
    final client = IdentityHttpClient(
      baseUri: () => Uri.parse('https://example.test/'),
      accountId: () => 'a',
      accessToken: () async => 'token',
      client: MockClient((_) async {
        requests++;
        return http.Response('{"code":"IDENTITY_VERSION_CONFLICT"}', 409);
      }),
    );
    await expectLater(
      client.update(
        expectedContextKey: client.requestContextKey,
        expectedVersion: 2,
        playerName: 'Star',
        agentName: 'Wheat',
      ),
      throwsA(failure(IdentityFailure.conflict)),
    );
    expect(requests, 1);
  });

  test(
    'invalid success, missing route and unauthenticated responses fail closed',
    () async {
      for (final pair in [
        (
          http.Response('{"code":"OK","data":{}}', 200),
          IdentityFailure.invalidResponse,
        ),
        (http.Response('404 page not found', 404), IdentityFailure.unavailable),
        (http.Response('{}', 401), IdentityFailure.authenticationRequired),
      ]) {
        final client = IdentityHttpClient(
          baseUri: () => Uri.parse('https://example.test/'),
          accountId: () => 'a',
          accessToken: () async => 'token',
          client: MockClient((_) async => pair.$1),
        );
        await expectLater(
          client.fetch(expectedContextKey: client.requestContextKey),
          throwsA(failure(pair.$2)),
        );
      }
    },
  );
}
