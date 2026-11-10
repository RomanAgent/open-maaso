import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';

void main() {
  setUp(appServices.reset);
  tearDown(appServices.reset);

  test(
    'saved key migrates old Cloud-off into usable atomic config without a probe',
    () async {
      final fixture = _ConfigFixture();
      fixture.seed(
        'fixture-key',
        'https://model.example.test/v1',
        'fixture-model',
        false,
      );
      var probes = 0;
      appServices.put(
        CloudLLMHealthService(
          probe: (_, _, _) async {
            probes++;
            return const CloudLLMHealth(status: CloudLLMStatus.available);
          },
        ),
      );
      await fixture.activate();
      final controller = fixture.controller;
      expect(controller.cloudUsable, isTrue);
      expect(controller.cloudEnabled.value, isTrue);
      expect(
        fixture.storage.values[fixture.scoped(
          GlobalConstant.keyLlmCloudEnabled,
        )],
        'true',
      );
      final committed = await LLMDirectCloudConfig.readFrom(fixture.storage);
      expect(committed?.enabled, isTrue);
      expect(committed?.apiKey, 'fixture-key');
      await controller.recheckCloudHealth(
        session: controller.requireActiveAccountSession(),
      );
      expect(probes, 0);
      await fixture.close();
    },
  );

  test(
    'saving a usable key enables calls without a switch; clearing it invalidates before partial writes',
    () async {
      final fixture = _ConfigFixture();
      await fixture.activate();
      final controller = fixture.controller;
      final session = controller.requireActiveAccountSession();
      await controller.saveConfig(
        'fixture-key',
        'https://model.example.test/v1',
        'fixture-model',
        session: session,
        enabled: false,
      );
      expect(controller.cloudUsable, isTrue);
      expect(
        (await LLMDirectCloudConfig.readFrom(fixture.storage))?.enabled,
        isTrue,
      );
      fixture.storage.blockNextWriteTo(
        fixture.scoped(GlobalConstant.keyLlmApiKey),
      );
      final clearing = controller.saveConfig(
        '',
        'https://model.example.test/v1',
        'fixture-model',
        session: session,
        enabled: true,
      );
      expect(controller.cloudUsable, isFalse);
      await fixture.storage.writeEntered.future;
      expect(await LLMDirectCloudConfig.readFrom(fixture.storage), isNull);
      fixture.storage.releaseWrite();
      await clearing;
      final committed = await LLMDirectCloudConfig.readFrom(fixture.storage);
      expect(committed?.enabled, isFalse);
      expect(committed?.apiKey, isEmpty);
      await fixture.close();
    },
  );

  test('partial or unsafe provider fields never enable inference', () async {
    final fixture = _ConfigFixture();
    await fixture.activate();
    final controller = fixture.controller;
    final session = controller.requireActiveAccountSession();
    for (final config in [
      (key: 'fixture-key', url: '', model: 'fixture-model'),
      (
        key: 'fixture-key',
        url: 'http://model.example.test/v1',
        model: 'fixture-model',
      ),
      (
        key: 'fixture-key',
        url: 'https://user:password@model.example.test/v1',
        model: 'fixture-model',
      ),
      (
        key: 'fixture-key',
        url: 'https://model.example.test/v1?secret=x',
        model: 'fixture-model',
      ),
      (key: 'fixture-key', url: 'https://model.example.test/v1', model: ''),
      (
        key: 'fixture\nkey',
        url: 'https://model.example.test/v1',
        model: 'fixture-model',
      ),
    ]) {
      await controller.saveConfig(
        config.key,
        config.url,
        config.model,
        session: session,
        enabled: true,
      );
      expect(controller.cloudUsable, isFalse, reason: config.toString());
      expect(
        (await LLMDirectCloudConfig.readFrom(fixture.storage))?.enabled,
        isFalse,
      );
    }
    await fixture.close();
  });

  test(
    'keyless inference requires an explicitly saved loopback model API',
    () async {
      final fixture = _ConfigFixture();
      await fixture.activate();
      final controller = fixture.controller;
      expect(controller.cloudUsable, isFalse);
      final session = controller.requireActiveAccountSession();
      await controller.saveConfig(
        '',
        'http://127.0.0.1:11434/v1',
        'qwen3:8b',
        session: session,
      );
      expect(controller.cloudUsable, isTrue);
      expect(controller.usesLocalEndpoint, isTrue);
      await fixture.close();
      await fixture.activate();
      expect(controller.cloudUsable, isTrue);
      expect(controller.apiKey.value, isEmpty);
      expect(controller.model.value, 'qwen3:8b');
      await fixture.close();
    },
  );

  test(
    'account retirement drains migration and prevents stale publication',
    () async {
      final fixture = _ConfigFixture();
      fixture.seed(
        'fixture-key',
        'https://model.example.test/v1',
        'fixture-model',
        false,
      );
      fixture.storage.blockNextWriteTo(
        fixture.scoped(GlobalConstant.keyLlmApiKey),
      );
      final activating = fixture.activate();
      await fixture.storage.writeEntered.future;
      fixture.scopes.unmount(fixture.mount!);
      var drained = false;
      final drain = fixture.controller.deactivateAccountAndDrain().then(
        (_) => drained = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      fixture.storage.releaseWrite();
      await expectLater(activating, throwsStateError);
      await drain;
      expect(await LLMDirectCloudConfig.readFrom(fixture.storage), isNull);
      expect(fixture.controller.apiKey.value, isEmpty);
    },
  );

  test('legacy edition retains the independent Cloud toggle', () async {
    final fixture = _ConfigFixture(localEdition: false);
    fixture.seed(
      'fixture-key',
      'https://model.example.test/v1',
      'fixture-model',
      false,
    );
    await fixture.activate();
    expect(fixture.controller.cloudUsable, isFalse);
    expect(
      (await LLMDirectCloudConfig.readFrom(fixture.storage))?.enabled,
      isFalse,
    );
    await fixture.controller.saveConfig(
      'fixture-key',
      'https://model.example.test/v1',
      'fixture-model',
      session: fixture.controller.requireActiveAccountSession(),
      enabled: true,
    );
    expect(fixture.controller.cloudUsable, isTrue);
    await fixture.close();
  });
}

final class _ConfigFixture {
  _ConfigFixture({bool localEdition = true}) {
    controller = LLMConfigController(
      storage: storage,
      storageScopes: scopes,
      localEdition: localEdition,
    );
  }
  final storage = _GatedStorage();
  final scopes = AccountStorageScopeService();
  final scope = AccountStorageScope(
    environmentKey: 'test',
    accountUuid: 'api-only-fixture',
  );
  late final LLMConfigController controller;
  AccountStorageScopeMount? mount;
  String scoped(String key) => '${scope.storageNamespace}.llm.byok.v1.$key';
  void seed(String key, String url, String model, bool enabled) {
    storage.values.addAll({
      scoped(GlobalConstant.keyLlmApiKey): key,
      scoped(GlobalConstant.keyLlmBaseUrl): url,
      scoped(GlobalConstant.keyLlmModel): model,
      scoped(GlobalConstant.keyLlmCloudEnabled): '$enabled',
    });
  }

  Future<void> activate() =>
      controller.activateAccount(mount = scopes.mount(scope));
  Future<void> close() async {
    scopes.unmount(mount!);
    await controller.deactivateAccountAndDrain();
  }
}

final class _GatedStorage extends SecureStorageService {
  final values = <String, String>{};
  String? _writeKey;
  Completer<void> writeEntered = Completer<void>();
  Completer<void> _release = Completer<void>();
  void blockNextWriteTo(String key) {
    _writeKey = key;
    writeEntered = Completer<void>();
    _release = Completer<void>();
  }

  void releaseWrite() => _release.complete();
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    if (key == _writeKey) {
      _writeKey = null;
      writeEntered.complete();
      await _release.future;
    }
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
