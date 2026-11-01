import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/privacy/data/privacy_http_client.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'privacy_models_test.dart' show privacySnapshotJson;

Matcher privacyCode(String code) =>
    isA<PrivacyException>().having((e) => e.code, 'code', code);
http.Response ok(Object value) =>
    http.Response(jsonEncode({'code': 'OK', 'data': value}), 200);

void main() {
  test('anonymous policy sends no token or private account data', () async {
    var tokens = 0;
    final gateway = PrivacyHttpClient(
      baseUri: () => Uri.parse('https://maaso.test/'),
      accountId: () => '',
      accessToken: () async {
        tokens++;
        return 'secret';
      },
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://maaso.test/v1/privacy/policy');
        expect(request.headers.containsKey('authorization'), isFalse);
        expect(request.body, isEmpty);
        return ok({'ready': false});
      }),
    );
    expect(gateway.hasAccount, isFalse);
    expect(
      (await gateway.policy(
        expectedContextKey: gateway.requestContextKey,
      )).ready,
      isFalse,
    );
    expect(tokens, 0);
  });
  test(
    'account changes while refreshing token prevent the HTTP dispatch',
    () async {
      final token = Completer<String>();
      var account = 'a';
      var requests = 0;
      final gateway = PrivacyHttpClient(
        baseUri: () => Uri.parse('https://maaso.test/'),
        accountId: () => account,
        accessToken: () => token.future,
        client: MockClient((_) async {
          requests++;
          return ok(privacySnapshotJson());
        }),
      );
      final read = gateway.read(expectedContextKey: gateway.requestContextKey);
      final checked = expectLater(
        read,
        throwsA(privacyCode('PRIVACY_CONTEXT_CHANGED')),
      );
      account = 'b';
      token.complete('secret');
      await checked;
      expect(requests, 0);
    },
  );
  test(
    'late responses after environment replacement or close are discarded',
    () async {
      for (final close in [false, true]) {
        final response = Completer<http.Response>();
        var base = Uri.parse('https://maaso.test/');
        final sent = Completer<void>();
        final gateway = PrivacyHttpClient(
          baseUri: () => base,
          accountId: () => 'a',
          accessToken: () async => 'secret',
          client: MockClient((_) {
            sent.complete();
            return response.future;
          }),
        );
        final read = gateway.read(
          expectedContextKey: gateway.requestContextKey,
        );
        final checked = expectLater(
          read,
          throwsA(privacyCode('PRIVACY_CONTEXT_CHANGED')),
        );
        await sent.future;
        if (close) {
          gateway.close();
        } else {
          base = Uri.parse('https://other.test/');
        }
        response.complete(ok(privacySnapshotJson()));
        await checked;
      }
    },
  );
  test(
    'human mutation binds exactly the reviewed policy and revision',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final gateway = PrivacyHttpClient(
        baseUri: () => Uri.parse('https://maaso.test/'),
        accountId: () => 'private-account',
        accessToken: () async => 'secret',
        client: MockClient((r) async {
          expect(r.method, 'POST');
          expect(r.headers['authorization'], 'Bearer secret');
          expect(r.url.query, isEmpty);
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          return ok(privacySnapshotJson(revision: 2));
        }),
      );
      final key = gateway.requestContextKey;
      final hash = List.filled(64, 'a').join();
      await gateway.declareAge(
        expectedContextKey: key,
        requestKey: 'req-age',
        expectedRevision: 1,
        expectedPolicyVersion: 'v1',
        expectedPolicyHash: hash,
        birthDate: '2000-01-01',
      );
      await gateway.setConsent(
        expectedContextKey: key,
        requestKey: 'req-consent',
        expectedRevision: 1,
        expectedPolicyVersion: 'v1',
        expectedPolicyHash: hash,
        recipientId: 'provider',
        scope: 'cloud_text',
        allow: false,
      );
      expect(bodies[0], {
        'requestKey': 'req-age',
        'expectedRevision': 1,
        'expectedPolicyVersion': 'v1',
        'expectedPolicyHash': hash,
        'birthDate': '2000-01-01',
      });
      expect(bodies[1], {
        'requestKey': 'req-consent',
        'expectedRevision': 1,
        'expectedPolicyVersion': 'v1',
        'expectedPolicyHash': hash,
        'recipientId': 'provider',
        'scope': 'cloud_text',
        'allow': false,
      });
    },
  );
  test(
    'server stable errors do not expose raw response or birth date',
    () async {
      for (final code in [
        'PRIVACY_UNAVAILABLE',
        'PRIVACY_AGE_INELIGIBLE',
        'PRIVACY_POLICY_CHANGED',
        'PRIVACY_REVISION_CONFLICT',
        'PRIVACY_CONSENT_REQUIRED',
      ]) {
        final gateway = PrivacyHttpClient(
          baseUri: () => Uri.parse('https://maaso.test/'),
          accountId: () => 'a',
          accessToken: () async => 'secret',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({'code': code, 'message': 'private 2000-01-01'}),
              409,
            ),
          ),
        );
        await expectLater(
          gateway.read(expectedContextKey: gateway.requestContextKey),
          throwsA(privacyCode(code)),
        );
      }
      expect(
        const PrivacyException('PRIVACY_INVALID_INPUT').toString(),
        'PrivacyException(PRIVACY_INVALID_INPUT)',
      );
    },
  );
  test('invalid revision fails before token lookup', () async {
    var tokens = 0;
    final gateway = PrivacyHttpClient(
      baseUri: () => Uri.parse('https://maaso.test/'),
      accountId: () => 'a',
      accessToken: () async {
        tokens++;
        return 'secret';
      },
    );
    await expectLater(
      gateway.setConsent(
        expectedContextKey: gateway.requestContextKey,
        requestKey: 'request',
        expectedRevision: 9007199254740991,
        expectedPolicyVersion: 'v1',
        expectedPolicyHash: List.filled(64, 'a').join(),
        recipientId: 'provider',
        scope: 'cloud_text',
        allow: true,
      ),
      throwsA(privacyCode('PRIVACY_INVALID_INPUT')),
    );
    expect(tokens, 0);
    gateway.close();
  });
  test(
    'malformed OK envelope cannot create a default eligible snapshot',
    () async {
      final gateway = PrivacyHttpClient(
        baseUri: () => Uri.parse('https://maaso.test/'),
        accountId: () => 'a',
        accessToken: () async => 'secret',
        client: MockClient((_) async => ok({'ready': true})),
      );
      await expectLater(
        gateway.read(expectedContextKey: gateway.requestContextKey),
        throwsA(privacyCode('PRIVACY_INVALID_RESPONSE')),
      );
    },
  );
}
