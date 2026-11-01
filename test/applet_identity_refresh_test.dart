import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/data/identity_local_store.dart';
import 'package:maaso/src/features/identity/domain/identity_local_state.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';

import 'identity_test_support.dart';

class _Storage extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<bool> write(String key, String? value) async => true;
  @override
  Future<bool> delete(String key) async => true;
}

class _IdentityStore implements IdentityLocalStore {
  _IdentityStore(this.value);
  IdentityLocalState value;
  @override
  Future<IdentityLocalState?> read() async => value;
  @override
  Future<void> write(IdentityLocalState state) async => value = state;
}

MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'token-$account',
  refreshToken: 'refresh',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

void main() {
  late AppletCatalogService applets;
  late AuthSessionService auth;
  late FakeIdentityGateway gateway;
  late IdentityService identity;
  late _IdentityStore store;
  late List<http.Request> requests;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put<SecureStorageService>(_Storage());
    appServices.put(AppEnvironmentService());
    appServices.put(LocaleConfigService());
    auth = appServices.put(AuthSessionService())
      ..session.value = _session('account-a');
    gateway = FakeIdentityGateway(initial: identityFixture());
    store = _IdentityStore(IdentityLocalState(serverProfile: gateway.stored));
    identity = appServices.put(
      IdentityService(
        gateway: gateway,
        localStore: store,
        allowLocalSetup: () => true,
      ),
    );
    requests = [];
    applets = AppletCatalogService(
      httpClient: MockClient((request) async {
        requests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'code': 'OK',
            'data': {
              'id': 'agc_comment',
              'displayName': 'Star',
              'actorId': 'player-1',
              'actorKind': 'user',
              'text': body['text'],
              'parentCommentId': ?body['parentCommentId'],
              'createdAt': '2026-09-13T12:00:00Z',
            },
          }),
          200,
        );
      }),
    );
  });
  tearDown(() async {
    applets.onClose();
    await appServices.reset();
  });

  Future<Object> post(bool reply, {String text = 'Hello'}) => reply
      ? applets.postCommentWithInput(
          'game',
          text,
          requestId: 'request-1',
          parentCommentId: 'agc_parent',
          expectedContextKey: applets.requestContextKey,
        )
      : applets.postComment(
          'game',
          text,
          expectedContextKey: applets.requestContextKey,
        );

  for (final reply in [false, true]) {
    final operation = reply ? 'reply' : 'comment';
    test('cold-start cached identity refreshes before $operation', () async {
      await identity.restore();
      expect(identity.onboardingCompleted, isTrue);
      expect(identity.completed, isFalse);
      expect(identity.profile, isNull);
      await post(reply);
      expect(gateway.reads, 1);
      expect(identity.completed, isTrue);
      expect(requests, hasLength(1));
      expect(jsonDecode(requests.single.body), {
        'text': 'Hello',
        if (reply) 'requestId': 'request-1',
        if (reply) 'parentCommentId': 'agc_parent',
      });
      await post(reply);
      expect(gateway.reads, 1);
    });

    test('unavailable pending identity cannot publish $operation', () async {
      store.value = IdentityLocalState(
        pendingNames: IdentityLocalNames(
          playerName: 'Star',
          agentName: 'Wheat',
        ),
      );
      gateway.fetchOverride = () async =>
          throw const IdentityException(IdentityFailure.unavailable);
      await identity.restore();
      expect(identity.onboardingCompleted, isTrue);
      await expectLater(
        post(reply),
        throwsA(
          isA<IdentityException>().having(
            (error) => error.failure,
            'failure',
            IdentityFailure.unavailable,
          ),
        ),
      );
      expect(identity.completed, isFalse);
      expect(gateway.reads, 1);
      expect(gateway.writes, 0);
      expect(requests, isEmpty);
    });

    test('incomplete fresh identity cannot publish $operation', () async {
      gateway.stored = identityFixture(version: 0, player: '', agent: '');
      await identity.restore();
      await expectLater(
        post(reply),
        throwsA(
          isA<IdentityException>().having(
            (error) => error.failure,
            'failure',
            IdentityFailure.rejected,
          ),
        ),
      );
      expect(requests, isEmpty);
    });

    test('account change during identity refresh cancels $operation', () async {
      final fetched = Completer<IdentityProfile>();
      final started = Completer<void>();
      gateway.fetchOverride = () {
        started.complete();
        return fetched.future;
      };
      final pending = post(reply);
      final assertion = expectLater(pending, throwsA(isA<StateError>()));
      await started.future;
      auth.session.value = _session('account-b');
      fetched.complete(gateway.stored);
      await assertion;
      expect(requests, isEmpty);
    });

    test('retiring identity during refresh cancels $operation', () async {
      final fetched = Completer<IdentityProfile>();
      final started = Completer<void>();
      gateway.fetchOverride = () {
        started.complete();
        return fetched.future;
      };
      final pending = post(reply);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<IdentityException>().having(
            (error) => error.failure,
            'failure',
            IdentityFailure.contextChanged,
          ),
        ),
      );
      await started.future;
      await appServices.delete<IdentityService>();
      appServices.put(IdentityService(gateway: FakeIdentityGateway()));
      fetched.complete(gateway.stored);
      await assertion;
      expect(requests, isEmpty);
    });

    test('invalid $operation input does not load identity', () async {
      await expectLater(post(reply, text: '  '), throwsFormatException);
      expect(gateway.reads, 0);
      expect(requests, isEmpty);
    });
  }
}
