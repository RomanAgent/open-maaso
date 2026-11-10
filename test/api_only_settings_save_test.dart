import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({});
    await SpUtils.init();
  });
  tearDown(appServices.reset);

  test(
    'editing the original API-key field enables and clears API-only routing without a toggle',
    () async {
      final database = appServices.put(
        await DBService().init(
          factory: databaseFactoryMemory,
          path: 'api-only-settings-save.db',
        ),
      );
      await database.saveAgentProfile(
        AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const [],
          catchphrase: '',
        ),
      );
      final core = appServices.put(AgentCoreController());
      await core.ensureLoaded();
      final storage = appServices.put<SecureStorageService>(_MemoryStorage());
      final scopes = appServices.put(AccountStorageScopeService());
      final mount = scopes.mount(
        AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'api-only-settings-save',
        ),
      );
      final config = appServices.put(
        LLMConfigController(
          storage: storage,
          storageScopes: scopes,
          localEdition: true,
        ),
      );
      await config.activateAccount(mount);
      appServices.put(await LocaleConfigService().init());
      appServices.put(await MaasoAgentModeService(localEdition: true).init());
      appServices.put<AuthSessionService>(_UnusedAuth());
      appServices.put<AccountSessionLifecycleService>(
        _UnusedAccountLifecycle(),
      );
      appServices.put<AvatarConfigService>(_IdleAvatarConfig());
      final settings = appServices.put(AgentSettingsController());
      expect(settings.cloudEnabled.value, isFalse);

      settings.baseUrl.text = 'https://model.example.test/v1';
      settings.model.text = 'fixture-model';
      settings.apiKey.text = 'fixture-key';
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(config.cloudUsable, isTrue);
      expect(settings.cloudEnabled.value, isTrue);
      expect((await LLMDirectCloudConfig.readFrom(storage))?.enabled, isTrue);
      settings.setCloudEnabled(false);
      expect(
        config.cloudUsable,
        isTrue,
        reason:
            'API-only configuration cannot be disabled by a retired Cloud switch',
      );

      settings.apiKey.clear();
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(config.cloudUsable, isFalse);
      expect(settings.cloudEnabled.value, isFalse);
      expect((await LLMDirectCloudConfig.readFrom(storage))?.enabled, isFalse);
      scopes.unmount(mount);
      await config.deactivateAccountAndDrain();
    },
  );
}

final class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
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

final class _UnusedAuth extends Fake implements AuthSessionService {
  @override
  void initializeLifecycle() {}
  @override
  void closeLifecycle() {}
}

final class _UnusedAccountLifecycle extends Fake
    implements AccountSessionLifecycleService {
  @override
  void initializeLifecycle() {}
  @override
  void closeLifecycle() {}
}

final class _IdleAvatarConfig extends AvatarConfigService {
  @override
  // ignore: must_call_super
  void onInit() {}
}
