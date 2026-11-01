import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_pipeline_runtime_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_proxy_tts_engine.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test('LLM proxy ignores raw token until auth session is published', () async {
    final harness = _registerHarness();
    final proxy = LLMProxyService();

    expect(await proxy.ensureClient(), isNull);

    harness.auth.session.value = _publishedSession();
    expect(await proxy.ensureClient(), isA<LLMClient>());
    expect(proxy.cachedClientForTesting, isA<MaasoThinProxyLLMClient>());
    expect(proxy.cacheKeyForTesting, isNot(contains('published-token')));

    harness.auth.session.value = null;
    expect(await proxy.ensureClient(), isNull);
    await proxy.deactivateAccountAndDrain();
    expect(proxy.cacheKeyForTesting, isNull);
    expect(proxy.cachedClientForTesting, isNull);
  });

  test('LLM proxy drain gates account B and rebuilds its client', () async {
    final harness = _registerHarness();
    final closeStarted = Completer<void>();
    final releaseClose = Completer<void>();
    final closed = <Object>[];
    final proxy = LLMProxyService(
      cachedClientCloser: (client) async {
        closed.add(client);
        if (!closeStarted.isCompleted) closeStarted.complete();
        await releaseClose.future;
      },
    );

    harness.auth.session.value = _publishedSession();
    expect(await proxy.ensureClient(), isA<LLMClient>());
    final accountAClient = proxy.cachedClientForTesting;
    expect(accountAClient, isA<MaasoThinProxyLLMClient>());
    expect(proxy.cacheKeyForTesting, isNot(contains('published-token')));

    var drainCompleted = false;
    final drain = proxy.deactivateAccountAndDrain().then(
      (_) => drainCompleted = true,
    );
    await closeStarted.future;
    expect(proxy.cachedClientForTesting, isNull);
    expect(proxy.cacheKeyForTesting, isNull);
    expect(proxy.accountDrainActiveForTesting, isTrue);

    harness.auth.session.value = MaasoAuthSession(
      accountUuid: 'account-2',
      accessToken: 'account-b-token',
      refreshToken: 'account-b-refresh',
      expiresAt: DateTime.now().add(const Duration(hours: 2)),
    );
    expect(await proxy.ensureClient(), isNull);
    expect(drainCompleted, isFalse);

    releaseClose.complete();
    await drain;
    expect(closed, [same(accountAClient)]);
    expect(proxy.accountDrainActiveForTesting, isFalse);

    expect(await proxy.ensureClient(), isA<LLMClient>());
    final accountBClient = proxy.cachedClientForTesting;
    expect(accountBClient, isA<MaasoThinProxyLLMClient>());
    expect(accountBClient, isNot(same(accountAClient)));
    expect(proxy.cacheKeyForTesting, isNot(contains('account-b-token')));
    await proxy.deactivateAccountAndDrain();
  });

  test('LLM proxy cache close failure stays fenced and retries', () async {
    final harness = _registerHarness();
    var closeAttempts = 0;
    var failClose = true;
    final proxy = LLMProxyService(
      cachedClientCloser: (_) {
        closeAttempts += 1;
        if (failClose) throw StateError('close failed');
      },
    );

    harness.auth.session.value = _publishedSession();
    expect(await proxy.ensureClient(), isA<LLMClient>());
    final accountAClient = proxy.cachedClientForTesting;
    expect(accountAClient, isNotNull);

    await expectLater(
      proxy.deactivateAccountAndDrain(),
      throwsA(isA<StateError>()),
    );
    expect(closeAttempts, 1);
    expect(proxy.accountDrainActiveForTesting, isTrue);
    expect(proxy.cachedClientForTesting, isNull);
    expect(await proxy.ensureClient(), isNull);

    failClose = false;
    await proxy.deactivateAccountAndDrain();
    expect(closeAttempts, 2);
    expect(proxy.accountDrainActiveForTesting, isFalse);

    harness.auth.session.value = MaasoAuthSession(
      accountUuid: 'account-2',
      accessToken: 'account-b-token',
      refreshToken: 'account-b-refresh',
      expiresAt: DateTime.now().add(const Duration(hours: 2)),
    );
    expect(await proxy.ensureClient(), isA<LLMClient>());
    expect(proxy.cachedClientForTesting, isNot(same(accountAClient)));
    await proxy.deactivateAccountAndDrain();
  });

  test('proxy TTS ignores raw token until auth session is published', () async {
    final harness = _registerHarness();
    final pipeline = AgentPipelineRuntimeService();

    await pipeline.refreshTtsEngine(mode: AgentPipelineMode.proxyDefault);
    expect(TTSEngineRegistry.current, isNot(isA<MaasoProxyTtsEngine>()));
    expect(pipeline.proxyTtsReady.value, isFalse);

    harness.auth.session.value = _publishedSession();
    await pipeline.refreshTtsEngine(mode: AgentPipelineMode.proxyDefault);
    expect(TTSEngineRegistry.current, isA<MaasoProxyTtsEngine>());
    expect(pipeline.proxyTtsReady.value, isTrue);

    harness.auth.session.value = null;
    await pipeline.refreshTtsEngine(mode: AgentPipelineMode.proxyDefault);
    expect(TTSEngineRegistry.current, isNot(isA<MaasoProxyTtsEngine>()));
    expect(pipeline.proxyTtsReady.value, isFalse);

    harness.auth.session.value = _publishedSession();
    await pipeline.refreshTtsEngine(mode: AgentPipelineMode.proxyDefault);
    expect(pipeline.proxyTtsReady.value, isTrue);

    await pipeline.deactivateAccountAndDrain();
    expect(pipeline.proxyTtsReady.value, isFalse);
  });
}

_TokenHarness _registerHarness() {
  final storage = _MemorySecureStorage()
    ..values[GlobalConstant.keyMaasoAccessToken] = 'untrusted-raw-token';
  appServices.put<SecureStorageService>(storage);
  appServices.put(AppEnvironmentService());
  final auth = appServices.put(AuthSessionService());
  appServices.put(
    RealtimeAgentConfig.fromValues(
      enabled: true,
      baseUrl: 'https://api.example.test',
    ),
  );
  return _TokenHarness(auth);
}

MaasoAuthSession _publishedSession() => MaasoAuthSession(
  accountUuid: 'account-1',
  accessToken: 'published-token',
  refreshToken: 'published-refresh',
  expiresAt: DateTime.now().add(const Duration(hours: 2)),
);

class _TokenHarness {
  const _TokenHarness(this.auth);

  final AuthSessionService auth;
}

class _MemorySecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
