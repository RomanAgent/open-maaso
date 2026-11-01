import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

void main() {
  late _RefreshingAuth auth;
  late RealtimeAgentConfig config;
  late LLMProxyService proxy;

  setUp(() async {
    appServices.testMode = true;
    await appServices.reset();
    appServices.put<SecureStorageService>(_MemoryStorage());
    appServices.put(AppEnvironmentService());
    auth = _RefreshingAuth();
    appServices.put<AuthSessionService>(auth);
    config = appServices.put(
      RealtimeAgentConfig.fromValues(
        enabled: true,
        baseUrl: 'https://api.example.test',
      ),
    );
    proxy = LLMProxyService();
  });

  tearDown(() async {
    await proxy.deactivateAccountAndDrain();
    await appServices.reset();
  });

  test(
    'expired mounted session refreshes before resolving hosted chat',
    () async {
      auth.session.value = _session(expired: true);
      auth.onRefresh = () async {
        auth.session.value = _session();
        return true;
      };

      expect(await proxy.ensureClient(), isNotNull);
      expect(auth.refreshCalls, 1);
      expect(proxy.cachedClientForTesting, isNotNull);
      expect(proxy.cacheKeyForTesting, isNot(contains('access-token')));
    },
  );

  test(
    'valid mounted session reuses its transport after token rotation',
    () async {
      auth.session.value = _session();
      expect(await proxy.ensureClient(), isNotNull);
      final transport = proxy.cachedClientForTesting;
      expect(auth.refreshCalls, 0);
      auth.session.value = _session(expired: true);
      auth.onRefresh = () async {
        auth.session.value = _session();
        return true;
      };

      expect(await proxy.ensureClient(), isNotNull);
      expect(proxy.cachedClientForTesting, same(transport));
      expect(auth.refreshCalls, 1);
    },
  );

  test(
    'unpublished credentials never trigger refresh or client creation',
    () async {
      expect(await proxy.ensureClient(), isNull);
      expect(auth.refreshCalls, 0);
      expect(proxy.cachedClientForTesting, isNull);
    },
  );

  test(
    'failed refresh does not cache a client and a later turn can recover',
    () async {
      auth.session.value = _session(expired: true);
      expect(await proxy.ensureClient(), isNull);
      expect(proxy.cachedClientForTesting, isNull);
      auth.onRefresh = () async {
        auth.session.value = _session();
        return true;
      };

      expect(await proxy.ensureClient(), isNotNull);
      expect(auth.refreshCalls, 2);
    },
  );

  test('concurrent resolutions share one expired-session refresh', () async {
    auth.session.value = _session(expired: true);
    final release = Completer<bool>();
    auth.onRefresh = () => release.future;
    final first = proxy.ensureClient();
    final second = proxy.ensureClient();
    await auth.refreshStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(auth.refreshCalls, 1);
    auth.session.value = _session();
    release.complete(true);

    expect(await first, isNotNull);
    final transport = proxy.cachedClientForTesting;
    expect(await second, isNotNull);
    expect(proxy.cachedClientForTesting, same(transport));
  });

  test(
    'account switch while refreshing cannot resolve another account',
    () async {
      auth.session.value = _session(expired: true);
      final release = Completer<bool>();
      auth.onRefresh = () => release.future;
      final resolving = proxy.ensureClient();
      await auth.refreshStarted.future;
      auth.session.value = _session(account: 'account-b');
      release.complete(true);

      expect(await resolving, isNull);
      expect(proxy.cachedClientForTesting, isNull);
      expect(await proxy.ensureClient(), isNotNull);
    },
  );

  test(
    'environment switch while refreshing invalidates the resolution',
    () async {
      auth.session.value = _session(expired: true);
      final release = Completer<bool>();
      auth.onRefresh = () => release.future;
      final resolving = proxy.ensureClient();
      await auth.refreshStarted.future;
      config.updateBaseUrl('https://other.example.test');
      auth.session.value = _session();
      release.complete(true);

      expect(await resolving, isNull);
      expect(proxy.cachedClientForTesting, isNull);
    },
  );

  for (final invalidation in ['account', 'environment', 'refresh failure']) {
    test(
      'cached request is not sent after $invalidation during refresh',
      () async {
        var requests = 0;
        await http.runWithClient(
          () async {
            auth.session.value = _session();
            expect(await proxy.ensureClient(), isNotNull);
            final transport = proxy.cachedClientForTesting!;
            auth.session.value = _session(expired: true);
            final release = Completer<bool>();
            auth.onRefresh = () => release.future;
            final response = transport.chat([Message.user('private old turn')]);
            final rejected = expectLater(
              response,
              throwsA(
                isA<HostedLLMFailure>().having(
                  (failure) => failure.kind,
                  'kind',
                  HostedLLMFailureKind.authentication,
                ),
              ),
            );
            await auth.refreshStarted.future;
            if (invalidation == 'account') {
              auth.session.value = _session(account: 'account-b');
            } else if (invalidation == 'environment') {
              config.updateBaseUrl('https://other.example.test');
              auth.session.value = _session();
            }
            release.complete(invalidation != 'refresh failure');
            await rejected;
            expect(requests, 0);
          },
          () => MockClient((_) async {
            requests++;
            return http.Response('data: [DONE]\n\n', 200);
          }),
        );
      },
    );
  }

  test('account drain waits for refresh and rejects its late client', () async {
    auth.session.value = _session(expired: true);
    final release = Completer<bool>();
    auth.onRefresh = () => release.future;
    final resolving = proxy.ensureClient();
    await auth.refreshStarted.future;
    var drained = false;
    final drain = proxy.deactivateAccountAndDrain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    expect(await proxy.ensureClient(), isNull);
    auth.session.value = _session();
    release.complete(true);

    expect(await resolving, isNull);
    await drain;
    expect(proxy.cachedClientForTesting, isNull);
  });
}

MaasoAuthSession _session({
  bool expired = false,
  String account = 'account-a',
}) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  expiresAt: DateTime.now().add(Duration(minutes: expired ? -1 : 60)),
);

class _RefreshingAuth extends AuthSessionService {
  int refreshCalls = 0;
  final refreshStarted = Completer<void>();
  Future<bool> Function() onRefresh = () async => false;

  @override
  Future<bool> restoreOrRefresh() {
    refreshCalls++;
    if (!refreshStarted.isCompleted) refreshStarted.complete();
    return onRefresh();
  }
}

class _MemoryStorage extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;
}
