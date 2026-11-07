import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/sherpa_model_download_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:maaso/src/features/settings/presentation/device_handoff_panel.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SpUtils.init();
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });

  tearDown(() async {
    await appServices.reset();
  });

  testWidgets(
    'real settings page follows mobile web and desktop capability snapshots',
    (tester) async {
      _useTallViewport(tester);
      final snapshots = appServices.put(
        _snapshotService(AppHostPlatform.macos),
      );
      await _installSettingsDependencies(
        databasePath: 'settings-capability-entry.db',
      );

      await tester.pumpWidget(const MaterialApp(home: AgentSettingsPage()));
      await tester.pump();

      const advancedEntry = 'Open advanced features';
      expect(find.text(advancedEntry), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-avatar-single-device')),
        findsNothing,
      );
      expect(find.text('settings.avatar_presence'.tr), findsNothing);
      expect(find.byType(DeviceHandoffPanel), findsNothing);

      for (final platform in <AppHostPlatform>[
        AppHostPlatform.android,
        AppHostPlatform.ios,
        AppHostPlatform.web,
      ]) {
        snapshots.refresh(snapshots.context.copyWith(hostPlatform: platform));
        await tester.pump();
        expect(
          find.text(advancedEntry),
          findsNothing,
          reason: '$platform must hide desktop-only advanced settings',
        );
      }

      for (final platform in <AppHostPlatform>[
        AppHostPlatform.macos,
        AppHostPlatform.windows,
        AppHostPlatform.linux,
      ]) {
        snapshots.refresh(snapshots.context.copyWith(hostPlatform: platform));
        await tester.pump();
        expect(
          find.text(advancedEntry),
          findsOneWidget,
          reason: '$platform must expose advanced settings',
        );
      }
    },
  );

  testWidgets(
    'local edition adds API configuration to the original mobile settings',
    (tester) async {
      _useTallViewport(tester);
      appServices.put(_snapshotService(AppHostPlatform.ios));
      await _installSettingsDependencies(
        databasePath: 'settings-local-model-entry.db',
        localEdition: true,
      );
      await tester.pumpWidget(const MaterialApp(home: AgentSettingsPage()));
      await tester.pump();
      expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
      expect(find.byType(HomePresentationSettingsSection), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-privacy')), findsOneWidget);
      expect(find.text('Open advanced features'), findsNothing);
      expect(find.text('settings.api_key'.tr), findsOneWidget);
      final providers = tester.widget<DropdownButton<String>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is DropdownButton<String> &&
              widget.value == 'Volcano Engine (Doubao)',
        ),
      );
      expect(providers.items, hasLength(12));
      expect(providers.items!.map((item) => item.value), contains('Anthropic'));
      expect(providers.items!.map((item) => item.value), contains('Gemini'));
      expect(providers.items!.map((item) => item.value), contains('Custom'));
      expect(appServices.isRegistered<SherpaModelDownloadService>(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('real advanced deep link redirects on web and opens on desktop', (
    tester,
  ) async {
    _useTallViewport(tester);
    final snapshots = appServices.put(_snapshotService(AppHostPlatform.web));
    final router = createAppRouter(
      initialLocation: AppRoutes.advancedFeatures,
      capabilitySnapshots: snapshots,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.web,
      ),
    );
    addTearDown(router.dispose);

    // The router intentionally captures a signed-out-free test guard before
    // the settings controller's account dependencies are installed. This
    // keeps the test focused on the capability redirect while still pumping
    // the production route and page builders.
    await _installSettingsDependencies(
      databasePath: 'settings-capability-deep-link.db',
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(_currentPath(router), AppRoutes.settings);
    expect(find.text('Advanced Features'), findsNothing);
    expect(appServices.isRegistered<SherpaModelDownloadService>(), isFalse);
    expect(appServices.isRegistered<VadService>(), isFalse);

    snapshots.refresh(
      snapshots.context.copyWith(hostPlatform: AppHostPlatform.macos),
    );
    router.go(AppRoutes.advancedFeatures);
    await tester.pumpAndSettle();

    expect(_currentPath(router), AppRoutes.advancedFeatures);
    expect(find.text('Advanced Features'), findsOneWidget);
    expect(appServices.isRegistered<SherpaModelDownloadService>(), isTrue);
    expect(appServices.isRegistered<VadService>(), isTrue);
  });
}

void _useTallViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 6000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

String _currentPath(GoRouter router) =>
    router.routeInformationProvider.value.uri.path;

AppCapabilitySnapshotService _snapshotService(AppHostPlatform platform) {
  return AppCapabilitySnapshotService(
    resolver: AppPlatformCapabilitySnapshotResolver(
      routeIds: AppRouteCatalog.destinations.map(
        (destination) => destination.id,
      ),
    ),
    initialContext: AppCapabilitySnapshotContext(
      hostPlatform: platform,
      rolloutGeneration: 0,
    ),
  );
}

Future<void> _installSettingsDependencies({
  required String databasePath,
  bool localEdition = false,
}) async {
  final database = await DBService().init(
    factory: databaseFactoryMemory,
    path: databasePath,
  );
  appServices.put<DBService>(database);
  appServices.put<ThemeService>(ThemeService());
  appServices.put<AgentCoreController>(_IdleAgentCoreController());

  final storage = appServices.put<SecureStorageService>(
    _MemorySecureStorageService(),
  );
  final environment = appServices.put(await AppEnvironmentService().init());
  final auth = appServices.put(AuthSessionService());
  final storageScopes = appServices.put(AccountStorageScopeService());
  appServices.put<AccountSessionLifecycleService>(
    _MountedAccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      storageScopes: storageScopes,
    ),
  );

  final mount = storageScopes.mount(
    AccountStorageScope(
      environmentKey: 'test',
      accountUuid: 'settings-capability-test-account',
    ),
  );
  final llm = appServices.put<LLMConfigController>(
    LLMConfigController(
      storage: storage,
      storageScopes: storageScopes,
      localEdition: localEdition,
    ),
  );
  await llm.activateAccount(mount);
  appServices.put(await LocaleConfigService().init());
  appServices.put(
    await MaasoAgentModeService(
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.macos,
      ),
    ).init(),
  );
  appServices.put<AvatarConfigService>(_IdleAvatarConfigService());
  appServices.put<AgentSettingsController>(AgentSettingsController());
}

final class _IdleAgentCoreController extends AgentCoreController {
  @override
  // Test double isolates the settings surface from profile bootstrap.
  // ignore: must_call_super
  void onInit() {}
}

final class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> _values = <String, String>{};

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

final class _MountedAccountSessionLifecycleService
    extends AccountSessionLifecycleService {
  _MountedAccountSessionLifecycleService({
    required super.auth,
    required super.environment,
    required super.storageScopes,
  }) : super(mountRuntime: (_) async => const _NoopAccountRuntimeLease());

  @override
  bool get isMounted => true;
}

final class _IdleAvatarConfigService extends AvatarConfigService {
  @override
  // Test double avoids starting a renderer retry loop for a settings test.
  // ignore: must_call_super
  void onInit() {}
}

final class _NoopAccountRuntimeLease implements AccountRuntimeLease {
  const _NoopAccountRuntimeLease();

  @override
  Future<void> close() async {}
}
