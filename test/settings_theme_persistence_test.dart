import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await SpUtils.init();
  });
  tearDown(appServices.reset);

  for (final mode in ThemeModePreference.values) {
    test('settings persists ${mode.key} through an account reload', () async {
      final fixture = await _install('appearance-${mode.key}.db');
      await fixture.settings.setThemeMode(mode);
      expect(fixture.settings.selectedThemeMode.value, mode);
      expect(fixture.theme.mode.value, mode);
      expect((await fixture.database.getSelfProfile())!.themeMode, mode.key);

      // Reconstruct the same account's profile from the actual Sembast row,
      // as account mounting does after relaunch or signing in again.
      fixture.theme.setMode(mode.next);
      await fixture.core.loadProfile();
      expect(fixture.theme.mode.value, mode);
      fixture.theme.setSystemBrightnessForTest(Brightness.dark);
      expect(
        fixture.theme.brightness.value,
        mode == ThemeModePreference.light ? Brightness.light : Brightness.dark,
      );
    });
  }

  test(
    'appearance save failure restores the mode and original profile',
    () async {
      final fixture = await _install('appearance-failure.db');
      final original = fixture.core.profile.value!;
      expect(
        fixture.settings.selectedThemeMode.value,
        ThemeModePreference.system,
      );
      await fixture.database.close();

      await expectLater(
        fixture.settings.setThemeMode(ThemeModePreference.dark),
        throwsStateError,
      );
      expect(
        fixture.settings.selectedThemeMode.value,
        ThemeModePreference.system,
      );
      expect(fixture.theme.mode.value, ThemeModePreference.system);
      expect(fixture.core.profile.value, same(original));
      expect(original.themeMode, 'system');
    },
  );

  test('a retired account cannot apply an appearance choice', () async {
    final fixture = await _install('appearance-retired.db');
    fixture.storageScopes.unmount(fixture.mount);
    await fixture.llm.deactivateAccountAndDrain();

    await expectLater(
      fixture.settings.setThemeMode(ThemeModePreference.dark),
      throwsStateError,
    );
    expect(fixture.theme.mode.value, ThemeModePreference.system);
    expect(fixture.core.profile.value!.themeMode, 'system');
    expect((await fixture.database.getSelfProfile())!.themeMode, 'system');
  });
}

Future<_Fixture> _install(String databasePath) async {
  final database = appServices.put(
    await DBService().init(factory: databaseFactoryMemory, path: databasePath),
  );
  await database.saveAgentProfile(
    AgentProfile(
      nickname: 'Maaso',
      avatar: '',
      bio: '',
      personalityTraits: const [],
      catchphrase: '',
      agentToken: 'appearance-test-token',
      gender: 'female',
      voiceId: 'f1',
      birthDate: DateTime.utc(2026, 1, 1),
    ),
  );
  final theme = appServices.put(ThemeService());
  final core = appServices.put(AgentCoreController());
  await core.ensureLoaded();
  final storage = appServices.put<SecureStorageService>(_MemorySecureStorage());
  final scopes = appServices.put(AccountStorageScopeService());
  final mount = scopes.mount(
    AccountStorageScope(environmentKey: 'test', accountUuid: databasePath),
  );
  final llm = appServices.put(
    LLMConfigController(storage: storage, storageScopes: scopes),
  );
  await llm.activateAccount(mount);
  appServices.put(await LocaleConfigService().init());
  appServices.put(await MaasoAgentModeService().init());
  appServices.put<AuthSessionService>(_UnusedAuth());
  appServices.put<AccountSessionLifecycleService>(_UnusedAccountLifecycle());
  appServices.put<AvatarConfigService>(_IdleAvatarConfig());
  final settings = appServices.put(AgentSettingsController());
  return _Fixture(database, theme, core, scopes, mount, llm, settings);
}

final class _Fixture {
  const _Fixture(
    this.database,
    this.theme,
    this.core,
    this.storageScopes,
    this.mount,
    this.llm,
    this.settings,
  );

  final DBService database;
  final ThemeService theme;
  final AgentCoreController core;
  final AccountStorageScopeService storageScopes;
  final AccountStorageScopeMount mount;
  final LLMConfigController llm;
  final AgentSettingsController settings;
}

final class _MemorySecureStorage extends SecureStorageService {
  final _values = <String, String>{};

  @override
  Future<String?> readPlatformValue(String key) async => _values[key];

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    _values.remove(key);
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
  // This settings test does not mount a renderer or run selection retries.
  // ignore: must_call_super
  void onInit() {}
}
