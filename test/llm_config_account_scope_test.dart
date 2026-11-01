import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(appServices.reset);

  test(
    'A and B use isolated BYOK keys and a late A route cannot overwrite B',
    () async {
      final storage = _MemorySecureStorage(<String, String>{
        GlobalConstant.keyLlmApiKey: 'unowned-legacy-secret',
        GlobalConstant.keyLlmBaseUrl: 'https://legacy.example.test/v1',
        GlobalConstant.keyLlmModel: 'legacy-model',
        GlobalConstant.keyLlmCloudEnabled: 'true',
      });
      final scopes = AccountStorageScopeService();
      final controller = LLMConfigController(
        storage: storage,
        storageScopes: scopes,
      );
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );

      await controller.quarantineLegacyConfig();
      expect(storage.values.values, isNot(contains('unowned-legacy-secret')));

      final mountA = scopes.mount(accountA);
      await controller.activateAccount(mountA);
      final sessionA = controller.requireActiveAccountSession();
      expect(controller.apiKey.value, isEmpty);
      await controller.saveConfig(
        'secret-a',
        'https://a.example.test/v1',
        'model-a',
        session: sessionA,
        enabled: true,
      );
      expect(storage.values[_scopedKey(accountA)], 'secret-a');
      expect(storage.values[GlobalConstant.keyLlmApiKey], 'secret-a');

      scopes.unmount(mountA);
      await controller.deactivateAccountAndDrain();
      expect(storage.values[GlobalConstant.keyLlmApiKey], isNull);
      expect(controller.apiKey.value, isEmpty);

      final mountB = scopes.mount(accountB);
      await controller.activateAccount(mountB);
      final sessionB = controller.requireActiveAccountSession();
      expect(controller.apiKey.value, isEmpty);
      await controller.saveConfig(
        'secret-b',
        'https://b.example.test/v1',
        'model-b',
        session: sessionB,
        enabled: true,
      );

      expect(
        () => controller.saveConfig(
          'late-secret-a',
          'https://late-a.example.test/v1',
          'late-model-a',
          session: sessionA,
          enabled: true,
        ),
        throwsStateError,
      );
      expect(controller.apiKey.value, 'secret-b');
      expect(storage.values[_scopedKey(accountB)], 'secret-b');
      expect(storage.values[GlobalConstant.keyLlmApiKey], 'secret-b');

      scopes.unmount(mountB);
      await controller.deactivateAccountAndDrain();
      final secondMountA = scopes.mount(accountA);
      await controller.activateAccount(secondMountA);
      expect(controller.apiKey.value, 'secret-a');
      expect(controller.baseUrl.value, 'https://a.example.test/v1');
      expect(controller.model.value, 'model-a');
      expect(controller.cloudEnabled.value, isTrue);

      scopes.unmount(secondMountA);
      await controller.deactivateAccountAndDrain();
    },
  );

  test('drain waits for admitted A save and never republishes it', () async {
    final storage = _MemorySecureStorage();
    final scopes = AccountStorageScopeService();
    final controller = LLMConfigController(
      storage: storage,
      storageScopes: scopes,
    );
    final accountA = AccountStorageScope(
      environmentKey: 'test',
      accountUuid: 'account-a',
    );
    final mountA = scopes.mount(accountA);
    await controller.activateAccount(mountA);
    final sessionA = controller.requireActiveAccountSession();
    storage.blockNextWriteTo(_scopedKey(accountA));

    final save = controller.saveConfig(
      'secret-a',
      'https://a.example.test/v1',
      'model-a',
      session: sessionA,
      enabled: true,
    );
    await storage.blockedWriteEntered.future;

    scopes.unmount(mountA);
    var drained = false;
    final drain = controller.deactivateAccountAndDrain().then(
      (_) => drained = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    expect(
      () => controller.saveConfig(
        'late-secret-a',
        'https://late.example.test/v1',
        'late-model',
        session: sessionA,
      ),
      throwsStateError,
    );

    storage.releaseBlockedWrite();
    await save;
    await drain;
    expect(storage.values[_scopedKey(accountA)], 'secret-a');
    expect(storage.values[GlobalConstant.keyLlmApiKey], isNull);
  });

  test(
    'failed compatibility cleanup blocks B until drain retry succeeds',
    () async {
      final storage = _MemorySecureStorage();
      final scopes = AccountStorageScopeService();
      final controller = LLMConfigController(
        storage: storage,
        storageScopes: scopes,
      );
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      final mountA = scopes.mount(accountA);
      await controller.activateAccount(mountA);
      await controller.saveConfig(
        'secret-a',
        'https://a.example.test/v1',
        'model-a',
        session: controller.requireActiveAccountSession(),
        enabled: true,
      );

      scopes.unmount(mountA);
      storage.failNextDeleteOf(GlobalConstant.keyLlmApiKey);
      await expectLater(
        controller.deactivateAccountAndDrain(),
        throwsStateError,
      );

      final mountB = scopes.mount(accountB);
      expect(() => controller.activateAccount(mountB), throwsStateError);
      await controller.deactivateAccountAndDrain();
      await controller.activateAccount(mountB);
      expect(controller.apiKey.value, isEmpty);
      expect(storage.values[GlobalConstant.keyLlmApiKey], isEmpty);

      scopes.unmount(mountB);
      await controller.deactivateAccountAndDrain();
    },
  );

  test(
    'late A bootstrap is fenced and drained before disabled B activates',
    () async {
      final storage = _MemorySecureStorage();
      final scopes = AccountStorageScopeService();
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      _seedScopedConfig(storage, accountA, apiKey: 'secret-a', enabled: true);
      final probe = _QueuedHealthProbe();
      final aProbe = probe.enqueue();
      final health = appServices.put(CloudLLMHealthService(probe: probe.call));
      final controller = LLMConfigController(
        storage: storage,
        storageScopes: scopes,
      );

      final mountA = scopes.mount(accountA);
      await controller.activateAccount(mountA);
      await aProbe.entered.future;
      expect(health.current.status, CloudLLMStatus.checking);

      scopes.unmount(mountA);
      var drained = false;
      final rawDrain = controller.deactivateAccountAndDrain();
      expect(
        identical(rawDrain, controller.deactivateAccountAndDrain()),
        isTrue,
      );
      final drain = rawDrain.then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(health.current.status, CloudLLMStatus.disabled);
      expect(drained, isFalse);

      final mountB = scopes.mount(accountB);
      expect(() => controller.activateAccount(mountB), throwsStateError);

      aProbe.complete(
        CloudLLMHealth(
          status: CloudLLMStatus.unavailable,
          reason: 'unauthorized',
          checkedAt: DateTime.now(),
        ),
      );
      await drain;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_healthCacheKey(accountA, 'status')), isNull);

      await controller.activateAccount(mountB);
      await Future<void>.delayed(Duration.zero);
      expect(health.current.status, CloudLLMStatus.disabled);
      expect(probe.calls, hasLength(1));

      scopes.unmount(mountB);
      await controller.deactivateAccountAndDrain();
    },
  );

  test(
    'late A manual recheck cannot publish or persist into enabled B',
    () async {
      final storage = _MemorySecureStorage();
      final scopes = AccountStorageScopeService();
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'account-b',
      );
      _seedScopedConfig(storage, accountA, apiKey: 'secret-a', enabled: true);
      _seedScopedConfig(storage, accountB, apiKey: 'secret-b', enabled: true);
      final controller = LLMConfigController(
        storage: storage,
        storageScopes: scopes,
      );
      final mountA = scopes.mount(accountA);
      await controller.activateAccount(mountA);
      final sessionA = controller.requireActiveAccountSession();

      final probe = _QueuedHealthProbe();
      final aProbe = probe.enqueue();
      final bProbe = probe.enqueue();
      final health = appServices.put(CloudLLMHealthService(probe: probe.call));
      final manualA = controller.recheckCloudHealth(session: sessionA);
      await aProbe.entered.future;
      final healthSessionA = health.activeAccountSession!;

      scopes.unmount(mountA);
      final drain = controller.deactivateAccountAndDrain();
      final mountB = scopes.mount(accountB);
      expect(() => controller.activateAccount(mountB), throwsStateError);

      aProbe.complete(
        CloudLLMHealth(
          status: CloudLLMStatus.unavailable,
          reason: 'unauthorized',
          checkedAt: DateTime.now(),
        ),
      );
      await manualA;
      await drain;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_healthCacheKey(accountA, 'status')), isNull);
      await prefs.setString(
        _healthCacheKey(accountA, 'status'),
        CloudLLMStatus.available.name,
      );
      await prefs.setInt(
        _healthCacheKey(accountA, 'checked_at'),
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setString(
        'cloud_health.status',
        CloudLLMStatus.available.name,
      );
      await prefs.setInt(
        'cloud_health.checked_at',
        DateTime.now().millisecondsSinceEpoch,
      );

      await controller.activateAccount(mountB);
      final sessionB = controller.requireActiveAccountSession();
      await bProbe.entered.future;
      expect(health.current.status, CloudLLMStatus.checking);
      expect(probe.calls[0].apiKey, 'secret-a');
      expect(probe.calls[1].apiKey, 'secret-b');
      expect(
        () => controller.recheckCloudHealth(session: sessionA),
        throwsStateError,
      );
      expect(
        () =>
            controller.activateCloudHealthForCurrentAccount(session: sessionA),
        throwsStateError,
      );

      bProbe.complete(
        CloudLLMHealth(
          status: CloudLLMStatus.available,
          checkedAt: DateTime.now(),
          latencyMs: 7,
        ),
      );
      await _waitForHealthStatus(health, CloudLLMStatus.available);
      expect(controller.isAccountSessionActive(sessionB), isTrue);

      // A cloud request may complete only after B has mounted. Its receipt is
      // stale, so neither a failure nor a success may mutate B's verdict.
      health.reportRuntimeFailure(
        StateError('OpenAI API error [401]'),
        session: healthSessionA,
      );
      expect(health.current.status, CloudLLMStatus.available);
      health.reportRuntimeSuccess(session: healthSessionA);
      expect(health.current.status, CloudLLMStatus.available);

      scopes.unmount(mountB);
      await controller.deactivateAccountAndDrain();
      expect(
        prefs.getString(_healthCacheKey(accountB, 'status')),
        CloudLLMStatus.available.name,
      );
      expect(
        prefs.getString(_healthCacheKey(accountA, 'status')),
        CloudLLMStatus.available.name,
      );
    },
  );

  test(
    'drain waits for admitted account cache save and B loads only B scope',
    () async {
      final storage = _MemorySecureStorage();
      final scopes = AccountStorageScopeService();
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'account-b',
      );
      _seedScopedConfig(storage, accountA, apiKey: 'secret-a', enabled: true);
      _seedScopedConfig(storage, accountB, apiKey: 'secret-b', enabled: true);

      final cache = _GatedHealthCache();
      final saveA = cache.gateNextSave();
      final probe = _QueuedHealthProbe();
      final aProbe = probe.enqueue();
      final bProbe = probe.enqueue();
      final health = appServices.put(
        CloudLLMHealthService(probe: probe.call, cache: cache),
      );
      final controller = LLMConfigController(
        storage: storage,
        storageScopes: scopes,
      );

      final mountA = scopes.mount(accountA);
      await controller.activateAccount(mountA);
      await aProbe.entered.future;
      aProbe.complete(
        CloudLLMHealth(
          status: CloudLLMStatus.available,
          checkedAt: DateTime.now(),
          latencyMs: 4,
        ),
      );
      await saveA.entered.future;

      scopes.unmount(mountA);
      var drained = false;
      final drain = controller.deactivateAccountAndDrain().then(
        (_) => drained = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);

      final mountB = scopes.mount(accountB);
      expect(() => controller.activateAccount(mountB), throwsStateError);
      saveA.release();
      await drain;
      expect(
        cache.values[accountA.storageNamespace]?.status,
        CloudLLMStatus.available,
      );

      await controller.activateAccount(mountB);
      await bProbe.entered.future;
      expect(health.current.status, CloudLLMStatus.checking);
      expect(cache.loads, <String>[
        accountA.storageNamespace,
        accountB.storageNamespace,
      ]);
      bProbe.complete(
        CloudLLMHealth(
          status: CloudLLMStatus.available,
          checkedAt: DateTime.now(),
          latencyMs: 5,
        ),
      );
      await _waitForHealthStatus(health, CloudLLMStatus.available);

      scopes.unmount(mountB);
      await controller.deactivateAccountAndDrain();
    },
  );

  test(
    'failed health operation retains drain for a successful retry',
    () async {
      final storage = _MemorySecureStorage();
      final scopes = AccountStorageScopeService();
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      _seedScopedConfig(storage, accountA, apiKey: 'secret-a', enabled: true);
      final controller = LLMConfigController(
        storage: storage,
        storageScopes: scopes,
      );
      final mountA = scopes.mount(accountA);
      await controller.activateAccount(mountA);
      final sessionA = controller.requireActiveAccountSession();

      final probe = _QueuedHealthProbe();
      final aProbe = probe.enqueue();
      appServices.put(CloudLLMHealthService(probe: probe.call));
      final manualA = controller.recheckCloudHealth(session: sessionA);
      await aProbe.entered.future;

      scopes.unmount(mountA);
      final drain = controller.deactivateAccountAndDrain();
      expect(identical(drain, controller.deactivateAccountAndDrain()), isTrue);
      final mountB = scopes.mount(accountB);
      expect(() => controller.activateAccount(mountB), throwsStateError);

      final manualFailure = expectLater(manualA, throwsStateError);
      final drainFailure = expectLater(drain, throwsStateError);
      aProbe.fail(StateError('probe failed'));
      await manualFailure;
      await drainFailure;
      expect(() => controller.activateAccount(mountB), throwsStateError);

      await controller.deactivateAccountAndDrain();
      await controller.activateAccount(mountB);
      expect(controller.apiKey.value, isEmpty);

      scopes.unmount(mountB);
      await controller.deactivateAccountAndDrain();
    },
  );

  test('main activates and drains BYOK inside the account barrier', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final settingsSource = File(
      'lib/src/features/settings/application/agent_settings_controller.dart',
    ).readAsStringSync();
    final llmProxySource = File(
      'lib/src/core/services/llm_proxy_service.dart',
    ).readAsStringSync();
    final mountStart = mainSource.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime',
    );
    final mountEnd = mainSource.indexOf(
      'Future<void> _disposeAccountRuntime',
      mountStart,
    );
    final mountBody = mainSource.substring(mountStart, mountEnd);

    expect(mainSource, contains('await llmConfig.quarantineLegacyConfig()'));
    expect(mountBody, contains('activateAccount(mount)'));
    expect(
      mountBody.indexOf('activateAccount(mount)'),
      lessThan(mountBody.indexOf('prepareAccountScope(')),
    );
    expect(
      mountBody.indexOf('activateCloudHealthForCurrentAccount('),
      greaterThan(mountBody.indexOf('refreshForCurrentMode()')),
    );
    expect(mountBody, contains('requireActiveAccountSession()'));
    expect(mainSource, contains("'llm_config'"));
    expect(mainSource, contains('deactivateAccountAndDrain()'));
    expect(settingsSource, contains('LLMConfigAccountSession _llmSession'));
    expect(settingsSource, contains('session: _llmSession'));
    expect(
      settingsSource,
      contains('_llm.recheckCloudHealth(session: _llmSession)'),
    );
    expect(
      llmProxySource,
      contains('final healthSession = _captureCloudHealthSession();'),
    );
    expect(llmProxySource, contains('_reportCloudFailure(e, healthSession)'));
  });
}

String _scopedKey(AccountStorageScope scope) {
  return '${scope.storageNamespace}.llm.byok.v1.'
      '${GlobalConstant.keyLlmApiKey}';
}

String _scopedConfigKey(AccountStorageScope scope, String logicalKey) {
  return '${scope.storageNamespace}.llm.byok.v1.$logicalKey';
}

String _healthCacheKey(AccountStorageScope scope, String suffix) {
  return '${scope.storageNamespace}.cloud_health.v1.$suffix';
}

void _seedScopedConfig(
  _MemorySecureStorage storage,
  AccountStorageScope scope, {
  required String apiKey,
  required bool enabled,
}) {
  storage.values[_scopedConfigKey(scope, GlobalConstant.keyLlmApiKey)] = apiKey;
  storage.values[_scopedConfigKey(scope, GlobalConstant.keyLlmBaseUrl)] =
      'https://${scope.environmentKey}.example.test/v1';
  storage.values[_scopedConfigKey(scope, GlobalConstant.keyLlmModel)] =
      'model-${scope.environmentKey}';
  storage.values[_scopedConfigKey(scope, GlobalConstant.keyLlmCloudEnabled)] =
      enabled.toString();
}

Future<void> _waitForHealthStatus(
  CloudLLMHealthService health,
  CloudLLMStatus expected,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (health.current.status == expected) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail(
    'Cloud health did not reach $expected; '
    'current=${health.current.status}.',
  );
}

final class _QueuedHealthProbe {
  final List<_GatedHealthProbe> _pending = <_GatedHealthProbe>[];
  final List<_HealthProbeInvocation> calls = <_HealthProbeInvocation>[];

  _GatedHealthProbe enqueue() {
    final probe = _GatedHealthProbe();
    _pending.add(probe);
    return probe;
  }

  Future<CloudLLMHealth> call(String apiKey, String baseUrl, String model) {
    if (_pending.isEmpty) {
      throw StateError('No queued cloud health probe result.');
    }
    final probe = _pending.removeAt(0);
    calls.add(
      _HealthProbeInvocation(apiKey: apiKey, baseUrl: baseUrl, model: model),
    );
    if (!probe.entered.isCompleted) probe.entered.complete();
    return probe._result.future;
  }
}

final class _GatedHealthProbe {
  final Completer<void> entered = Completer<void>();
  final Completer<CloudLLMHealth> _result = Completer<CloudLLMHealth>();

  void complete(CloudLLMHealth result) {
    if (!_result.isCompleted) _result.complete(result);
  }

  void fail(Object error) {
    if (!_result.isCompleted) _result.completeError(error, StackTrace.current);
  }
}

final class _HealthProbeInvocation {
  const _HealthProbeInvocation({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  final String apiKey;
  final String baseUrl;
  final String model;
}

final class _GatedHealthCache implements CloudLLMHealthCache {
  final Map<String, CloudLLMHealth> values = <String, CloudLLMHealth>{};
  final List<String> loads = <String>[];
  final List<String> saves = <String>[];
  _HealthCacheSaveGate? _nextSaveGate;

  _HealthCacheSaveGate gateNextSave() {
    if (_nextSaveGate != null) {
      throw StateError('A cache save is already gated.');
    }
    return _nextSaveGate = _HealthCacheSaveGate();
  }

  @override
  Future<CloudLLMHealth?> load(String accountScopeKey) async {
    loads.add(accountScopeKey);
    return values[accountScopeKey];
  }

  @override
  Future<void> save(String accountScopeKey, CloudLLMHealth health) async {
    saves.add(accountScopeKey);
    final gate = _nextSaveGate;
    if (gate != null) {
      _nextSaveGate = null;
      if (!gate.entered.isCompleted) gate.entered.complete();
      await gate.released.future;
    }
    values[accountScopeKey] = health;
  }
}

final class _HealthCacheSaveGate {
  final Completer<void> entered = Completer<void>();
  final Completer<void> released = Completer<void>();

  void release() {
    if (!released.isCompleted) released.complete();
  }
}

final class _MemorySecureStorage extends SecureStorageService {
  _MemorySecureStorage([Map<String, String>? initialValues])
    : values = <String, String>{...?initialValues};

  final Map<String, String> values;
  final Map<String, int> _deleteFailures = <String, int>{};
  String? _blockedWriteKey;
  Completer<void> blockedWriteEntered = Completer<void>();
  Completer<void> _blockedWriteRelease = Completer<void>();

  void blockNextWriteTo(String key) {
    _blockedWriteKey = key;
    blockedWriteEntered = Completer<void>();
    _blockedWriteRelease = Completer<void>();
  }

  void releaseBlockedWrite() {
    if (!_blockedWriteRelease.isCompleted) _blockedWriteRelease.complete();
  }

  void failNextDeleteOf(String key) {
    _deleteFailures[key] = (_deleteFailures[key] ?? 0) + 1;
  }

  @override
  Future<bool> write(String key, String? value) async {
    if (_blockedWriteKey == key) {
      _blockedWriteKey = null;
      if (!blockedWriteEntered.isCompleted) blockedWriteEntered.complete();
      await _blockedWriteRelease.future;
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> delete(String key) async {
    final remainingFailures = _deleteFailures[key] ?? 0;
    if (remainingFailures > 0) {
      _deleteFailures[key] = remainingFailures - 1;
      return false;
    }
    values.remove(key);
    return true;
  }
}
