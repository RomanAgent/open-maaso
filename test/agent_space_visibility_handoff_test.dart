import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_agent_space.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HomePresentationPreferenceService preference;
  late AgentUiControlCoordinator uiControl;
  late _DisplayLifecycle lifecycle;
  var serial = 0;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues({
      HomePresentationPreferenceService.storageKey: 'chat',
    });
    preference = appServices.put(
      await HomePresentationPreferenceService().load(),
    );
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    appServices.put(
      await DBService().init(
        factory: databaseFactoryMemory,
        path: 'space-display-${serial++}.db',
      ),
    );
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put(AgentTaskJobStore());
    appServices.put<AgentCoreController>(_UnbootedCore());
    lifecycle = _DisplayLifecycle();
    appServices.put<AccountSessionLifecycleService>(lifecycle);
    uiControl = AgentUiControlCoordinator();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('maaso/avatar_portal'),
      (_) async => null,
    );
  });
  tearDown(() async {
    await uiControl.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('maaso/avatar_portal'),
      null,
    );
    debugDefaultTargetPlatformOverride = null;
    await appServices.reset();
  });

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  Future<void> mountHome(
    WidgetTester tester,
    GlobalKey<NavigatorState> navigator,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);
    appServices.put(HomeController());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.build(
            AppPalette.of(Brightness.light, AppAccent.blue),
          ),
          home: const HomePage(),
        ),
      ),
    );
    await frames(tester);
  }

  Future<void> queueHomeModeChanges(WidgetTester tester) async {
    preference.mode.value = HomePresentationMode.avatar;
    await frames(tester);
    preference.mode.value = HomePresentationMode.chat;
    await frames(tester);
  }

  for (final disposeHome in [false, true]) {
    testWidgets(
      'delayed Home hide cannot supersede Space after ${disposeHome ? 'disposal' : 'route handoff'}',
      (tester) async {
        final renderer = _VisibilityRenderer()
          ..firstVisibility = Completer<void>();
        final avatar = ActiveAvatarRuntime()..register(renderer);
        appServices.put(avatar);
        final navigator = GlobalKey<NavigatorState>();
        await mountHome(tester, navigator);
        expect(renderer.visibility, [false]);
        await queueHomeModeChanges(tester);
        if (disposeHome) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          unawaited(
            navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Agent Space')),
              ),
            ),
          );
          await frames(tester);
        }
        final room = AgentSpaceController(avatar: avatar);
        await room.enter();
        expect(avatar.localAvatarVisible, isTrue);
        final afterSpace = renderer.visibility.length;
        renderer.firstVisibility!.complete();
        await frames(tester);
        expect(renderer.visibility.skip(afterSpace), isNot(contains(false)));
        expect(avatar.localAvatarVisible, isTrue);
        await room.leave();
        expect(avatar.localAvatarVisible, isFalse);
        room.onClose();
        await tester.pumpWidget(const SizedBox.shrink());
        await appServices.delete<HomeController>();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('queued Home writes cannot mutate the next account or renderer', (
    tester,
  ) async {
    final old = _VisibilityRenderer()..firstVisibility = Completer<void>();
    final avatar = ActiveAvatarRuntime()..register(old);
    appServices.put(avatar);
    await mountHome(tester, GlobalKey<NavigatorState>());
    await queueHomeModeChanges(tester);
    lifecycle.replaceGeneration();
    final next = _VisibilityRenderer();
    avatar.register(next);
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await avatar.setLocalAvatarVisible(true);
    final writes = next.visibility.length;
    old.firstVisibility!.complete();
    await frames(tester);
    expect(next.visibility.skip(writes), isEmpty);
    expect(avatar.localAvatarVisible, isTrue);
    await appServices.delete<HomeController>();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'mounted Space owns visibility while account retirement still hides it',
    (tester) async {
      final renderer = _VisibilityRenderer();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      appServices.put(avatar);
      await avatar.setLocalAvatarVisible(false);
      final route = ValueNotifier<String>(AppRouteCatalog.agentSpace);
      addTearDown(route.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MaterialApp(
            home: AppAgentShell(
              coordinator: uiControl,
              routeListenable: route,
              currentRoute: () => route.value,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await frames(tester);
      expect(
        avatar.localAvatarVisible,
        isFalse,
        reason:
            'the shell must not overwrite the saved Home chat preference before Space captures it',
      );
      await avatar.setLocalAvatarVisible(true);
      lifecycle.retire();
      await frames(tester);
      expect(avatar.localAvatarVisible, isFalse);
      expect(renderer.visibility.last, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('Home chrome is visible throughout the native walk back', (
    tester,
  ) async {
    try {
      preference.mode.value = HomePresentationMode.avatar;
      final renderer = _VisibilityRenderer()..homeReturn = Completer<void>();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      appServices.put(avatar);
      await avatar.setLocalAvatarVisible(true);
      final generation = lifecycle.generation;
      final room = appServices.put(
        AgentSpaceController(
          avatar: avatar,
          isCurrent: () =>
              lifecycle.isMounted && lifecycle.generation == generation,
          homeRouteIsCurrent: () => true,
        ),
      );
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      final exit = room.leave(animated: true, handoffToHome: true);
      room.setActivity(resumed: true, currentPage: false, source: source);
      renderer.presence.clear();
      renderer.visibility.clear();
      await mountHome(tester, GlobalKey<NavigatorState>());
      await frames(tester);
      expect(find.byKey(const ValueKey('home-menu-toggle')), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(room.isReturningHome, isTrue);
      expect(renderer.exitAnimations, [true]);
      expect(renderer.presence, isEmpty);
      expect(renderer.visibility, isEmpty);
      expect(avatar.localAvatarVisible, isTrue);
      appServices.find<HomeController>().inputController.text = '回来后继续写';
      await frames(tester);
      expect(find.text('回来后继续写'), findsOneWidget);
      expect(renderer.presence, isEmpty);
      renderer.homeReturn!.complete();
      await exit;
      await frames(tester);
      expect(room.isReturningHome, isFalse);
      expect(renderer.presence, isEmpty);
      expect(renderer.visibility, isNot(contains(false)));
      expect(
        room.consumeHomeReturnFrame(renderer),
        isFalse,
        reason: 'Mounted Home adopts only the acknowledged final native frame.',
      );
      expect(renderer.exitAnimations, [true]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await frames(tester);
      await appServices.delete<HomeController>();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final interruption in ['background', 'covering route']) {
    testWidgets('Home retires the exact pending return on $interruption', (
      tester,
    ) async {
      try {
        preference.mode.value = HomePresentationMode.avatar;
        final renderer = _VisibilityRenderer()..homeReturn = Completer<void>();
        final avatar = ActiveAvatarRuntime()..register(renderer);
        appServices.put(avatar);
        await avatar.setLocalAvatarVisible(true);
        final room = appServices.put(
          AgentSpaceController(avatar: avatar, homeRouteIsCurrent: () => true),
        );
        await room.enter();
        final exit = room.leave(animated: true, handoffToHome: true);
        final navigator = GlobalKey<NavigatorState>();
        await mountHome(tester, navigator);
        await frames(tester);
        expect(room.isReturningHome, isTrue);
        if (interruption == 'background') {
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        } else {
          unawaited(
            navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Covering page')),
              ),
            ),
          );
        }
        await frames(tester);
        await exit;
        expect(room.isReturningHome, isFalse);
        expect(room.consumeHomeReturnFrame(renderer), isFalse);
        expect(renderer.exitAnimations, [true, false]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await frames(tester);
        await appServices.delete<HomeController>();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
          for (final state in [
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        }
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets(
    'recreated Home adopts the native return without hiding or re-entering',
    (tester) async {
      try {
        preference.mode.value = HomePresentationMode.avatar;
        final renderer = _VisibilityRenderer();
        final avatar = ActiveAvatarRuntime()..register(renderer);
        appServices.put(avatar);
        await mountHome(tester, GlobalKey<NavigatorState>());
        await frames(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await frames(tester);
        await appServices.delete<HomeController>();
        // The room starts from the previously shown local Home actor. Fake native
        // receipts exercise the real newly mounted Home State, not an ever-entered flag.
        await avatar.setLocalAvatarVisible(true);
        final generation = lifecycle.generation;
        final room = appServices.put(
          AgentSpaceController(
            avatar: avatar,
            isCurrent: () =>
                lifecycle.isMounted && lifecycle.generation == generation,
          ),
        );
        final source = Object();
        room.setActivity(resumed: true, currentPage: true, source: source);
        await room.enter(animated: true);
        await room.leave(handoffToHome: true);
        room.setActivity(resumed: false, currentPage: false, source: source);
        await frames(tester);
        renderer.visibility.clear();
        renderer.presence.clear();
        await mountHome(tester, GlobalKey<NavigatorState>());
        await frames(tester);

        expect(
          renderer.presence,
          isEmpty,
          reason:
              'Native already completed Home; no prepare/enter/restore may replay.',
        );
        expect(renderer.visibility, isNot(contains(false)));
        expect(avatar.localAvatarVisible, isTrue);
        expect(
          room.consumeHomeReturnFrame(renderer),
          isFalse,
          reason: 'Fresh Home consumed the proof exactly once.',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await frames(tester);
        expect(
          renderer.presence,
          isEmpty,
          reason: 'Disposing an adopted frame must not send native cleanup.',
        );
        await appServices.delete<HomeController>();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

class _UnbootedCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _DisplayLifecycle extends AppService
    implements AccountSessionLifecycleService {
  final _listeners = <VoidCallback>[];
  @override
  final phase = AccountSessionLifecyclePhase.mounted.obs;
  @override
  int generation = 1;
  @override
  bool get isMounted => phase.value == AccountSessionLifecyclePhase.mounted;
  @override
  bool get canPresentAvatar => isMounted;
  @override
  bool get canExecuteAgent => false;
  @override
  bool get presenceRecoveryInProgress => false;
  @override
  get canonicalRemoteHolder => null;
  @override
  bool get hasCompanionRuntime => true;
  @override
  bool get usesExclusiveDeviceLease => false;
  @override
  AccountRuntimeAuthorityMode get effectiveAuthorityMode =>
      AccountRuntimeAuthorityMode.off;
  void replaceGeneration() {
    generation++;
    _notify();
  }

  void retire() {
    phase.value = AccountSessionLifecyclePhase.retiring;
    _notify();
  }

  void _notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _VisibilityRenderer extends AvatarRuntime
    implements AvatarAgentSpaceRuntime {
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  final visibility = <bool>[];
  final presence = <AvatarPresencePhase>[];
  final exitAnimations = <bool>[];
  Completer<void>? homeReturn;
  Completer<void>? firstVisibility;
  @override
  Future<void> setLocalAvatarVisible(bool visible) async {
    visibility.add(visible);
    if (visibility.length == 1) await firstVisibility?.future;
  }

  @override
  Future<void> transitionPresence(AvatarPresenceTransition transition) async {
    presence.add(transition.phase);
  }

  @override
  Future<void> prepareRenderer() async {}
  @override
  Future<void> enterAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {}
  @override
  Future<void> leaveAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {
    exitAnimations.add(animated);
    if (animated) {
      await homeReturn?.future;
    } else if (homeReturn != null && !homeReturn!.isCompleted) {
      homeReturn!.completeError(
        const AvatarAgentSpaceCommandException(
          method: 'leaveAgentSpace',
          code: 'space_transition_cancelled',
        ),
      );
    }
  }

  @override
  Future<void> moveAgentSpaceAtScreenPoint({
    required String sessionId,
    required double x,
    required double y,
  }) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
