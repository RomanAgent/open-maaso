import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';

void main() {
  setUp(appServices.reset);
  tearDown(appServices.reset);

  test('partial BYOK save is fail-closed until one envelope commits', () async {
    final storage = _GatedSecureStorage();
    final scopes = AccountStorageScopeService();
    final controller = LLMConfigController(
      storage: storage,
      storageScopes: scopes,
    );
    final mount = scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'account-a'),
    );
    await controller.activateAccount(mount);
    final session = controller.requireActiveAccountSession();
    await controller.saveConfig(
      'old-secret',
      'https://old.example.test/v1',
      'old-model',
      session: session,
      enabled: true,
    );

    storage.blockNextWriteTo(GlobalConstant.keyLlmApiKey);
    final save = controller.saveConfig(
      'new-secret',
      'https://new.example.test/v1',
      'new-model',
      session: session,
      enabled: true,
    );
    await storage.blockedWriteEntered.future;

    expect(await LLMDirectCloudConfig.readFrom(storage), isNull);

    storage.releaseBlockedWrite();
    await save;
    final committed = await LLMDirectCloudConfig.readFrom(storage);
    expect(committed?.apiKey, 'new-secret');
    expect(committed?.baseUrl, 'https://new.example.test/v1');
    expect(committed?.model, 'new-model');
    expect(committed?.enabled, isTrue);

    scopes.unmount(mount);
    await controller.deactivateAccountAndDrain();
  });
}

final class _GatedSecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};
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

  @override
  Future<String?> read(String key) async => values[key];

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
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
