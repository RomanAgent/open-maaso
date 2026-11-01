import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';
import 'package:maaso/src/features/auth/presentation/login_page.dart';

void main() {
  test('login route is registered before home can be entered', () {
    final router = File(
      'lib/src/app/routing/router_config.dart',
    ).readAsStringSync();
    final catalog = File(
      'lib/src/app/routing/app_route_catalog.dart',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(AppRoutes.login, '/login');
    expect(catalog, contains("static const login = '/login';"));
    expect(router, contains('LoginPage'));
    expect(router, contains('LoginRouteDependencies'));
    expect(main, contains('StartupRouteService'));
    expect(main, contains('resolveInitialRoute'));
    expect(main, isNot(contains('AppRoutes.initial = AppRoutes.home;')));
  });

  test('login page exposes email signup with verification code', () {
    final page = File(
      'lib/src/features/auth/presentation/login_page.dart',
    ).readAsStringSync();
    final controller = File(
      'lib/src/features/auth/application/login_controller.dart',
    ).readAsStringSync();
    final auth = File(
      'lib/src/core/services/auth_session_service.dart',
    ).readAsStringSync();

    expect(page, contains('auth.switch_to_signup'));
    expect(page, contains('auth.switch_to_login'));
    expect(page, contains('auth.verification_code'));
    expect(page, contains('auth.send_code'));
    expect(page, contains('AutofillHints.oneTimeCode'));
    expect(page, contains('controller.submit'));
    expect(controller, contains('isSignupMode'));
    expect(controller, contains('Future<void> sendSignupCode()'));
    expect(controller, contains('Future<void> signup()'));
    expect(controller, contains('signupCodeId'));
    expect(auth, contains("'/v1/login/email/captcha'"));
    expect(auth, contains("'/v1/login/email/signup'"));
    expect(auth, contains("'codeId': codeId"));
    expect(auth, contains("..._appClaims()"));
  });

  test(
    'login keeps offline artwork until authenticated Unity doorway choreography',
    () {
      final page = File(
        'lib/src/features/auth/presentation/login_page.dart',
      ).readAsStringSync();
      final controller = File(
        'lib/src/features/auth/application/login_controller.dart',
      ).readAsStringSync();
      final coordinator = File(
        'lib/src/features/auth/application/login_doorway_coordinator.dart',
      ).readAsStringSync();
      expect(page, contains('LoginDoorwayArtwork'));
      expect(page, isNot(contains('SingleChildScrollView')));
      expect(page, contains("ValueKey('login-form-exit')"));
      expect(page, contains('if (_presentingWorld)'));
      expect(page, contains('UnityAvatarView'));
      expect(page, contains('await finished.future'));
      expect(page, isNot(contains('_playAvatarPasswordExitMotion')));
      expect(page, isNot(contains('_playAvatarEntryMotion')));
      expect(page, contains('onSubmit:'));
      expect(page, contains('_submitAuthForm,'));
      expect(page, contains('_logoTapCount >= 10'));
      expect(page, contains('controller.allowedEnvironments'));
      expect(page, contains('controller.setEnvironment(env)'));
      expect(page, contains('AppRouteCatalog.privacy'));
      expect(controller, contains('authenticateAndMount'));
      expect(
        controller,
        contains('LoginDoorwayCoordinator.ensure().requestAuthenticated()'),
      );
      expect(controller, contains('IdentityRoutePolicy.redirect'));
      expect(
        coordinator,
        contains(
          'AppLaunchPresentationSession.ensure().consumeAuthenticatedDoorway',
        ),
      );
      expect(coordinator, contains('consumeEntrance()'));
      expect(coordinator, contains('currentGeneration'));
    },
  );

  test('email login and signup actions keep opaque button treatments', () {
    final page = File(
      'lib/src/features/auth/presentation/login_page.dart',
    ).readAsStringSync();

    expect(page, contains('class _ImmersiveActionButton'));
    expect(page, contains('fillColor: ColorConstant.primaryColor'));
    expect(page, contains('foregroundColor: Colors.white'));
    expect(page, contains('class _OpaqueIconButton'));
    expect(page, contains('class _OpaqueTextButton'));
    expect(page, contains('backgroundColor: fillColor'));
    expect(page, contains('disabledBackgroundColor: fillColor'));
    expect(page, isNot(contains('(fillColor.a * 0.62)')));
    expect(page, isNot(contains('AppGlassButton(\n          label: loading')));
  });

  testWidgets(
    'email login and signup remain usable without provider placeholders',
    (tester) async {
      await appServices.reset();
      appServices.testMode = true;
      addTearDown(appServices.reset);
      AppLocalization.updateLocale(const Locale('en', 'US'));
      appServices.put<SecureStorageService>(_LoginTestStorage());
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final auth = appServices.put(AuthSessionService());
      appServices.put(
        AccountSessionLifecycleService(
          auth: auth,
          environment: environment,
          mountRuntime: (_) async =>
              throw StateError('Input validation must not mount a runtime.'),
        ),
      );
      final controller = appServices.put(LoginController());
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      await tester.pump();

      // V4 removed provider buttons whose only action reported unavailable.
      expect(find.textContaining('Google'), findsNothing);
      expect(find.textContaining('Apple'), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.text('Privacy & permissions'), findsOneWidget);
      _expectOpaqueAction(tester, 'auth.log_in'.tr);
      expect(controller.isSignupMode.value, isFalse);
      expect(find.byType(TextField), findsNWidgets(2));
      _expectOpaqueAction(tester, 'auth.log_in'.tr);
      await tester.ensureVisible(find.text('auth.log_in'.tr));
      await tester.tap(find.text('auth.log_in'.tr));
      await tester.pump();
      expect(find.text('auth.email_password_required'.tr), findsOneWidget);

      await tester.ensureVisible(find.text('auth.switch_to_signup'.tr));
      await tester.tap(find.text('auth.switch_to_signup'.tr));
      await tester.pump();
      expect(controller.isSignupMode.value, isTrue);
      expect(find.byType(TextField), findsNWidgets(3));
      final codeField = tester.widget<TextField>(find.byType(TextField).at(2));
      expect(codeField.autofillHints, contains(AutofillHints.oneTimeCode));
      await tester.ensureVisible(find.byTooltip('auth.send_code'.tr));
      await tester.tap(find.byTooltip('auth.send_code'.tr));
      await tester.pump();
      expect(find.text('auth.email_required'.tr), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).at(0),
        'player@example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), 'test-password');
      await tester.ensureVisible(find.text('auth.create_account'.tr));
      await tester.tap(find.text('auth.create_account'.tr));
      await tester.pump();
      expect(find.text('auth.code_required'.tr), findsOneWidget);
      _expectOpaqueAction(tester, 'auth.create_account'.tr);

      controller.isLoading.value = true;
      await tester.pump();
      final submit = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(submit.onPressed, isNull);
      expect(
        submit.style!.backgroundColor!.resolve({WidgetState.disabled})!.a,
        1,
      );
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      controller.isLoading.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));
      await tester.ensureVisible(find.text('auth.switch_to_login'.tr));
      await tester.tap(find.text('auth.switch_to_login'.tr));
      await tester.pump();
      expect(controller.isSignupMode.value, isFalse);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('auth.log_in'.tr), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  test(
    'welcome title keeps the scoped environment gesture without duplicating artwork',
    () {
      final page = File(
        'lib/src/features/auth/presentation/login_page.dart',
      ).readAsStringSync();
      expect(page, contains("'auth.sign_in'.tr"));
      expect(page, contains('onTap: _handleLogoTap'));
      expect(
        RegExp(r'child: const LoginDoorwayArtwork\(\)').allMatches(page),
        hasLength(1),
      );
    },
  );

  test('realtime agent defaults to hosted test environment', () {
    final config = RealtimeAgentConfig.fromValues(
      enabled: true,
      baseUrl: '',
      environmentBaseUrl: 'https://api-test.futurpals.com.cn',
    );

    expect(config.isReady, isTrue);
    expect(config.baseUri.toString(), 'https://api-test.futurpals.com.cn/');
  });

  test('settings hides local model panels behind advanced features', () {
    final settings = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final controller = File(
      'lib/src/features/settings/application/agent_settings_controller.dart',
    ).readAsStringSync();

    expect(settings, contains('class _AdvancedFeaturesSection'));
    expect(
      settings,
      contains(
        "import 'package:maaso/src/app/routing/app_route_catalog.dart';",
      ),
    );
    expect(
      settings,
      isNot(
        contains("import 'package:maaso/src/app/routing/router_config.dart';"),
      ),
    );
    expect(
      controller,
      contains(
        "import 'package:maaso/src/app/routing/app_route_catalog.dart';",
      ),
    );
    expect(
      controller,
      isNot(
        contains("import 'package:maaso/src/app/routing/router_config.dart';"),
      ),
    );
    expect(
      settings,
      contains('appNavigation.push(AppRouteCatalog.advancedFeatures)'),
    );
    expect(settings, contains('settings.advanced_features'));
    final settingsHome = _methodBody(
      settings,
      'class AgentSettingsPage',
      'class _AdvancedFeaturesPage',
    );
    final advancedPage = _methodBody(
      settings,
      'class _AdvancedFeaturesPage',
      'class _ModelConfigSection',
    );
    final advancedPrepare = _methodBody(
      settings,
      'Future<void> _prepareAdvancedBaseServices()',
      '  @override\n  Widget build(BuildContext context)',
    );
    expect(settingsHome, isNot(contains('Switch(')));
    expect(settingsHome, contains('supportsAdvancedAiSettings'));
    expect(settingsHome, isNot(contains('const _VoiceSection()')));
    expect(settingsHome, isNot(contains('const _OnDeviceBrainSection()')));
    expect(advancedPage, contains('const _RealtimeExperimentSection()'));
    expect(advancedPage, contains('const _DesktopLocalAsrSection()'));
    expect(advancedPage, contains('const _VoiceSection()'));
    expect(advancedPage, isNot(contains('const _VadSection()')));
    expect(settings, isNot(contains('class _VadSection')));
    expect(advancedPage, contains('const _OnDeviceBrainSection()'));
    expect(advancedPage, isNot(contains('const _AsrSection()')));
    expect(settings, contains('_prepareAdvancedBaseServices'));
    expect(advancedPrepare, contains('supportsAdvancedAiSettings'));
    expect(advancedPrepare, isNot(contains('LocalLLMService')));
    expect(advancedPrepare, isNot(contains('SherpaNeuralTts')));
    expect(advancedPrepare, isNot(contains('DesktopLocalAsr')));
    expect(settings, contains('SherpaModelDownloadService'));
    expect(settings, contains('FilePicker.getDirectoryPath'));
    expect(settings, contains('runtime.importUserDirectory('));
    expect(settings, contains('tts.ensureReady()'));
    expect(controller, isNot(contains('setAdvancedFeaturesEnabled')));
  });

  test(
    'default voice input keeps native ASR and pins explicit desktop local ASR',
    () {
      final chatInput = File(
        'lib/src/core/widgets/chat_input_bar.dart',
      ).readAsStringSync();
      final nativeAsr = File(
        'lib/src/core/services/platform_asr_service.dart',
      ).readAsStringSync();
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final android = File(
        'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
      ).readAsStringSync();

      expect(nativeAsr, contains("MethodChannel('maaso/native_asr')"));
      expect(chatInput, contains('PlatformAsrService'));
      expect(chatInput, contains('MaasoAgentModeService'));
      expect(chatInput, contains('VadService'));
      expect(chatInput, contains('DesktopLocalAsrService'));
      expect(
        chatInput,
        contains('DesktopLocalAsrService? _desktopLocalAsrSession;'),
      );
      expect(chatInput, contains('desktopLocalAsr: _desktopLocalAsrSession,'));
      expect(chatInput, contains('_enterNativeAsrWithVadVoice'));
      expect(chatInput, isNot(contains('usesLocalSpeechModels')));
      expect(chatInput, isNot(contains('final asr = _asr;')));
      final enterVoice = _methodBody(
        chatInput,
        'Future<void> _enterVoice() async',
        '  Future<bool> _enterNativeAsrWithVadVoice({',
      );
      expect(enterVoice, contains('_enterNativeAsrWithVadVoice'));
      expect(ios, contains('SFSpeechRecognizer'));
      expect(android, contains('SpeechRecognizer'));
    },
  );

  test(
    'secondary chat input keeps default native and opt-in local routing',
    () {
      final u2aInput = File(
        'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
      ).readAsStringSync();

      expect(u2aInput, contains('PlatformAsrService'));
      expect(u2aInput, contains('VadService'));
      expect(u2aInput, contains('DesktopLocalAsrService'));
      expect(
        u2aInput,
        contains('DesktopLocalAsrService? _desktopLocalAsrSession;'),
      );
      expect(u2aInput, contains('desktopLocalAsr: _desktopLocalAsrSession,'));
      expect(u2aInput, contains('_enterNativeAsrWithVadVoice'));
      expect(u2aInput, isNot(contains('usesLocalSpeechModels')));
      expect(u2aInput, isNot(contains('final asr = _asr;')));
    },
  );

  test('default hosted mode does not fall back to local agent paths', () {
    final llmProxy = File(
      'lib/src/core/services/llm_proxy_service.dart',
    ).readAsStringSync();
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();

    expect(llmProxy, contains('AgentPipelineMode.proxyDefault'));
    expect(llmProxy, contains('_ensureMaasoThinProxyClient'));
    expect(runtime, contains('AgentPipelineMode.proxyDefault'));
    expect(runtime, contains('AgentPipelineMode.localFull'));
    expect(runtime, contains('runtime.fallback.hosted_unavailable'));
  });

  test('settings exposes account logout for saved sessions', () {
    final settingsPage = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final settingsController = File(
      'lib/src/features/settings/application/agent_settings_controller.dart',
    ).readAsStringSync();

    expect(settingsPage, contains('settings.logout'));
    expect(settingsController, contains('AuthSessionService'));
    expect(settingsController, contains('AccountSessionLifecycleService'));
    expect(settingsController, contains('Future<void> logout()'));
    expect(settingsController, contains('signOutAndUnmount()'));
    expect(
      settingsController,
      contains('appNavigation.go(AppRouteCatalog.login)'),
    );
  });

  test('settings pipeline AppReactiveBuilder reads pipeline mode directly', () {
    final settingsPage = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final section = _methodBody(
      settingsPage,
      'class _RealtimeExperimentSection',
      '  String _pipelineModeTitle',
    );

    expect(
      section,
      contains('final selectedMode = controller.pipelineMode.value;'),
    );
    expect(section, contains('child: AppReactiveBuilder(() {'));
    expect(RegExp(r'\bBuilder\s*\(').hasMatch(section), isFalse);
  });
}

String _methodBody(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start);
  expect(start, isNonNegative);
  expect(end, isNonNegative);
  return source.substring(start, end);
}

void _expectOpaqueAction(WidgetTester tester, String label) {
  final button = tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, label),
  );
  expect(button.onPressed, isNotNull);
  for (final states in [
    <WidgetState>{},
    {WidgetState.disabled},
  ]) {
    final background = button.style!.backgroundColor!.resolve(states)!;
    final foreground = button.style!.foregroundColor!.resolve(states)!;
    expect(background.a, 1);
    expect(foreground.a, 1);
    expect(foreground, isNot(background));
  }
}

class _LoginTestStorage extends SecureStorageService {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<bool> write(String key, String? value) async {
    value == null ? _values.remove(key) : _values[key] = value;
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    _values.remove(key);
    return true;
  }
}
