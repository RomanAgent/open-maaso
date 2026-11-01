import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/presentation/desktop_pet_stage.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_channel_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_texture.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_scope.dart';
import 'package:maaso/src/features/agent/presentation/companion/companion_session_scope.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const portalChannel = MethodChannel(AvatarPortalChannelGateway.channelName);
  late AgentUiControlCoordinator uiControl;
  DesktopWindowModeController? windowController;
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SpUtils.init();
    await appServices.reset();
    uiControl = AgentUiControlCoordinator();
    windowController = null;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(portalChannel, null);
    windowController?.dispose();
    await uiControl.dispose();
    await appServices.reset();
  });

  testWidgets(
    'AppAgentShell hosts the desktop pet through an injected controller',
    (tester) async {
      appServices.put(DBService());
      appServices.put(AgentRuntimeRegistry());
      appServices.put(AgentReplyPresentationService());
      final controller = DesktopWindowModeController(
        gateway: _FakeDesktopWindowGateway(),
      );
      windowController = controller;
      await controller.enterPetMode();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 420,
            child: AppAgentShell(
              coordinator: uiControl,
              desktopWindowModeController: controller,
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      );

      expect(find.byType(DesktopPetStage), findsOneWidget);
      expect(find.byKey(DesktopPetStage.menuButtonKey), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('desktop focus loss keeps the active Avatar portal lease', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = <MethodCall>[];
    _installPortalMock(portalChannel, calls);
    _registerPortalServices();
    final controller = DesktopWindowModeController(
      gateway: _FakeDesktopWindowGateway(),
    );
    windowController = controller;
    await controller.enterPetMode();
    await _pumpVisiblePet(
      tester,
      uiControl: uiControl,
      windowController: controller,
      portalChannel: portalChannel,
      calls: calls,
    );

    final lifecycleStart = calls.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(
      calls
          .skip(lifecycleStart)
          .where(
            (call) =>
                call.method == 'suspend' ||
                call.method == 'resume' ||
                call.method == 'release',
          ),
      isEmpty,
    );
    expect(find.byType(AvatarPortalTexture), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'Mac pet restores renderers after the actual selection hide receipt',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      final renderer = _registerPortalServices(runtimeReady: false);
      final controller = DesktopWindowModeController(
        gateway: _IndependentFakeDesktopWindowGateway(),
      );
      windowController = controller;
      final host = _SequencedDesktopCompanionHostGateway(<String>[]);
      await tester.pumpWidget(
        MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            desktopCompanionHostGateway: host,
            currentRoute: () => '/home',
            child: const SizedBox(),
          ),
        ),
      );
      final acquire = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, acquire);
      await tester.pumpAndSettle();
      final config = appServices.find<AvatarConfigService>();
      expect(config.selectionDisplayCurrent, isTrue);
      expect(
        renderer.visibility,
        contains(false),
        reason:
            'The real model selection service must still hide while loading.',
      );
      expect(
        renderer.visibility.last,
        isTrue,
        reason:
            'A received frame may be transparent; desktop must restore mesh visibility after model selection.',
      );
      expect(renderer.modelVisible, isTrue);
      expect(controller.petVisible, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'Mac selected model returns after a native renderer epoch reset',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      final renderer = _registerPortalServices(runtimeReady: false);
      final controller = DesktopWindowModeController(
        gateway: _IndependentFakeDesktopWindowGateway(),
      );
      windowController = controller;
      final host = _SequencedDesktopCompanionHostGateway(<String>[]);
      await tester.pumpWidget(
        MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            desktopCompanionHostGateway: host,
            currentRoute: () => '/home',
            child: const SizedBox(),
          ),
        ),
      );
      final initial = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, initial);
      await tester.pumpAndSettle();
      expect(renderer.modelVisible, isTrue);
      final previousLoads = renderer.loadCalls;
      renderer.modelEpoch++;
      renderer.modelVisible = false;
      renderer.isReady.value = false;
      await tester.pumpAndSettle();
      expect(
        appServices.find<AvatarConfigService>().selectionDisplayCurrent,
        isFalse,
      );
      expect(renderer.modelVisible, isFalse);
      renderer.isReady.value = true;
      await tester.pumpAndSettle();
      expect(renderer.loadCalls, greaterThan(previousLoads));
      expect(
        appServices.find<AvatarConfigService>().selectionDisplayCurrent,
        isTrue,
      );
      expect(renderer.modelVisible, isTrue);
      expect(renderer.visibility.last, isTrue);
      expect(controller.petVisible, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('late desktop model readiness cannot reveal a retired account', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = <MethodCall>[];
    _installPortalMock(portalChannel, calls);
    final renderer = _registerPortalServices(runtimeReady: false);
    final gate = Completer<void>();
    renderer.loadGate = gate;
    final lifecycle = _PortalAccountLifecycle();
    appServices.put<AccountSessionLifecycleService>(lifecycle);
    final controller = DesktopWindowModeController(
      gateway: _IndependentFakeDesktopWindowGateway(),
    );
    windowController = controller;
    final host = _SequencedDesktopCompanionHostGateway(<String>[]);
    await tester.pumpWidget(
      MaterialApp(
        home: AppAgentShell(
          coordinator: uiControl,
          desktopWindowModeController: controller,
          desktopCompanionHostGateway: host,
          currentRoute: () => '/home',
          child: const SizedBox(),
        ),
      ),
    );
    for (var i = 0; i < 20 && renderer.loadCalls == 0; i++) {
      await tester.pump();
    }
    expect(renderer.loadCalls, 1);
    lifecycle.publish(mounted: false, ownsExecution: false);
    gate.complete();
    await tester.pumpAndSettle();
    expect(renderer.modelVisible, isFalse);
    expect(renderer.visibility, isNot(contains(true)));
    expect(host.calls, isNot(contains('show')));
    expect(controller.petVisible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'macOS Space and window changes keep the live Avatar texture resident',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final calls = <MethodCall>[];
        _installPortalMock(portalChannel, calls);
        _registerPortalServices();
        final controller = DesktopWindowModeController(
          gateway: _IndependentFakeDesktopWindowGateway(),
        );
        windowController = controller;
        await controller.enterPetMode();
        await _pumpVisiblePet(
          tester,
          uiControl: uiControl,
          windowController: controller,
          portalChannel: portalChannel,
          calls: calls,
        );
        expect(
          (calls.firstWhere((call) => call.method == 'acquire').arguments
              as Map<Object?, Object?>)['profile'],
          AvatarPortalProfile.desktopHigh.wireName,
        );
        calls.clear();

        for (final state in <AppLifecycleState>[
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(
          calls.where(
            (call) =>
                call.method == 'suspend' ||
                call.method == 'resume' ||
                call.method == 'release',
          ),
          isEmpty,
        );
        expect(_visiblePetPortal(tester).phase, AvatarPortalPhase.visible);
        expect(find.byKey(DesktopPetStage.fallbackAvatarKey), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'macOS keeps chat open alongside the first pet frame and recovers on failure',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final portalCalls = <MethodCall>[];
        _installPortalMock(portalChannel, portalCalls);
        final avatarRuntime = _registerPortalServices(runtimeReady: false);
        final transitionOrder = <String>[];
        final windowGateway = _SequencedIndependentFakeDesktopWindowGateway(
          transitionOrder,
        );
        final controller = DesktopWindowModeController(gateway: windowGateway);
        final host = _SequencedDesktopCompanionHostGateway(transitionOrder);
        final route = ValueNotifier<String>('/chat');
        windowController = controller;
        addTearDown(route.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: AppAgentShell(
              coordinator: uiControl,
              desktopWindowModeController: controller,
              desktopCompanionHostGateway: host,
              routeListenable: route,
              currentRoute: () => route.value,
              child: const SizedBox(
                key: ValueKey<String>('first-frame-gated-host'),
              ),
            ),
          ),
        );
        final acquire = await _waitForAcquire(tester, portalCalls);

        expect(avatarRuntime.loadCalls, 1);
        expect(
          avatarRuntime.loadedModelUrl,
          AvatarConfigService.builtInCatalog.single.modelUrl,
        );
        expect(controller.mode, DesktopWindowMode.app);
        expect(controller.petVisible, isFalse);
        expect(windowGateway.calls, isNot(contains('enterPetMode')));
        expect(host.calls, isNot(contains('show')));

        await _sendFirstFrame(portalChannel, acquire);
        await tester.pumpAndSettle();

        expect(controller.mode, DesktopWindowMode.app);
        expect(controller.petVisible, isTrue);
        expect(windowGateway.calls, isNot(contains('enterPetMode')));
        expect(host.calls, contains('show'));
        expect(transitionOrder, <String>['show']);

        final generation =
            (acquire.arguments as Map<Object?, Object?>)['generation']! as int;
        await _sendNativeCall(
          portalChannel,
          MethodCall('event', <String, Object>{
            'type': 'released',
            'generation': generation,
            'reason': 'sidecarExited',
          }),
        );
        await tester.pumpAndSettle();

        expect(controller.mode, DesktopWindowMode.app);
        expect(controller.petVisible, isFalse);
        expect(windowGateway.calls, isNot(contains('enterAppMode')));
        expect(host.calls, containsAllInOrder(<String>['show', 'hide']));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  for (final executionMovesAway in [false, true]) {
    testWidgets(
      'macOS space returns to a pet with remote execution=$executionMovesAway',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final calls = <MethodCall>[];
        _installPortalMock(portalChannel, calls);
        _registerPortalServices();
        final lifecycle =
            appServices.put<AccountSessionLifecycleService>(
                  _PortalAccountLifecycle(),
                )
                as _PortalAccountLifecycle;
        final gateway = _IndependentFakeDesktopWindowGateway();
        final controller = DesktopWindowModeController(gateway: gateway);
        windowController = controller;
        final host = _SequencedDesktopCompanionHostGateway(<String>[]);
        final route = ValueNotifier<String>('/agent-space');
        addTearDown(route.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: AppAgentShell(
              coordinator: uiControl,
              desktopWindowModeController: controller,
              desktopCompanionHostGateway: host,
              routeListenable: route,
              currentRoute: () => route.value,
              child: const UnityAvatarView(
                key: ValueKey<String>('world-to-chat-host'),
                includeWorld: true,
              ),
            ),
          ),
        );
        final element = tester.element(
          find.byKey(const ValueKey<String>('world-to-chat-host')),
        );
        final portal = CompanionSessionScope.of(element).portal;
        final initial = await _waitForAcquire(tester, calls);
        expect((initial.arguments as Map)['includeWorld'], isTrue);
        await _sendFirstFrame(portalChannel, initial);
        await tester.pumpAndSettle();
        expect(portal.capturesWorld, isTrue);
        expect(host.calls, isNot(contains('show')));
        calls.clear();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        expect(portal.capturesWorld, isTrue);

        if (executionMovesAway) {
          lifecycle.publish(ownsExecution: false);
          await tester.pump();
          expect(portal.capturesWorld, isTrue);
          expect(calls.where((call) => call.method == 'release'), isEmpty);
        }
        route.value = '/home';
        final petAcquire = await _waitForAcquire(tester, calls);
        expect(petAcquire.arguments, isNot(contains('includeWorld')));
        await _sendFirstFrame(portalChannel, petAcquire);
        await tester.pumpAndSettle();
        expect(portal.capturesWorld, isFalse);
        expect(controller.mode, DesktopWindowMode.app);
        expect(controller.petVisible, isTrue);
        expect(gateway.calls, isNot(contains('enterPetMode')));
        expect(host.calls, contains('show'));
        calls.clear();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        expect(portal.capturesWorld, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  for (final replaceAccount in [false, true]) {
    testWidgets(
      '${replaceAccount ? 'account replacement' : 'retirement'} while Agent space exit waits cannot summon a pet',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final calls = <MethodCall>[];
        _installPortalMock(portalChannel, calls);
        _registerPortalServices();
        final lifecycle = _PortalAccountLifecycle();
        appServices.put<AccountSessionLifecycleService>(lifecycle);
        final world = _DeferredPortalSpaceExit();
        appServices.put<AgentSpaceController>(world);
        final controller = DesktopWindowModeController(
          gateway: _IndependentFakeDesktopWindowGateway(),
        );
        windowController = controller;
        final host = _SequencedDesktopCompanionHostGateway(<String>[]);
        final route = ValueNotifier<String>('/agent-space');
        addTearDown(route.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: AppAgentShell(
              coordinator: uiControl,
              desktopWindowModeController: controller,
              desktopCompanionHostGateway: host,
              routeListenable: route,
              currentRoute: () => route.value,
              child: const UnityAvatarView(
                key: ValueKey<String>('retiring-world-host'),
                includeWorld: true,
              ),
            ),
          ),
        );
        final initial = await _waitForAcquire(tester, calls);
        await _sendFirstFrame(portalChannel, initial);
        await tester.pumpAndSettle();
        calls.clear();
        route.value = '/home';
        for (var i = 0; i < 10 && !world.leaveStarted.isCompleted; i++) {
          await tester.pump();
        }
        expect(world.leaveStarted.isCompleted, isTrue);
        expect(calls.where((call) => call.method == 'acquire'), isEmpty);
        if (replaceAccount) lifecycle.generation++;
        lifecycle.publish(mounted: false, ownsExecution: false);
        route.value = '/login';
        await tester.pump();
        world.allowLeave.complete();
        await tester.pumpAndSettle();
        expect(calls.where((call) => call.method == 'acquire'), isEmpty);
        expect(controller.petVisible, isFalse);
        expect(host.calls, isNot(contains('show')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  for (final startupStage in <String>[
    'authentication',
    'preparation',
    'firstFrame',
    'completed',
  ]) {
    testWidgets(
      'macOS startup preserves Home chat and pet during $startupStage',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final calls = <MethodCall>[];
        _installPortalMock(portalChannel, calls);
        _registerPortalServices();
        final gateway = _IndependentFakeDesktopWindowGateway();
        final controller = DesktopWindowModeController(gateway: gateway);
        windowController = controller;
        final _FakeDesktopCompanionHostGateway host =
            startupStage == 'firstFrame'
            ? _FirstFrameGatedDesktopCompanionHostGateway(<String>[])
            : _FakeDesktopCompanionHostGateway();
        final route = ValueNotifier<String>(
          startupStage == 'authentication' ? '/login' : '/chat',
        );
        addTearDown(route.dispose);
        if (host is _FirstFrameGatedDesktopCompanionHostGateway) {
          addTearDown(() {
            if (!host.allowFirstFrame.isCompleted) {
              host.allowFirstFrame.complete();
            }
          });
        }
        await tester.pumpWidget(
          MaterialApp(
            home: AppAgentShell(
              coordinator: uiControl,
              desktopWindowModeController: controller,
              desktopCompanionHostGateway: host,
              routeListenable: route,
              currentRoute: () => route.value,
              child: const SizedBox(key: ValueKey<String>('startup-home-host')),
            ),
          ),
        );
        if (startupStage == 'authentication') route.value = '/home';
        final acquire = await _waitForAcquire(tester, calls);
        if (startupStage == 'preparation') route.value = '/home';
        await _sendFirstFrame(portalChannel, acquire);
        await tester.pump();
        if (host is _FirstFrameGatedDesktopCompanionHostGateway) {
          for (var i = 0; i < 10 && !host.showStarted.isCompleted; i++) {
            await tester.pump();
          }
          expect(host.showStarted.isCompleted, isTrue);
          route.value = '/home';
          host.allowFirstFrame.complete();
        } else if (startupStage == 'completed') {
          await tester.pumpAndSettle();
          expect(controller.mode, DesktopWindowMode.app);
          expect(controller.petVisible, isTrue);
          route.value = '/home';
        }
        await tester.pumpAndSettle();
        expect(controller.mode, DesktopWindowMode.app);
        expect(controller.petVisible, isTrue);
        expect(gateway.calls, isNot(contains('enterPetMode')));
        expect(host.calls, contains('show'));
        expect(
          find.byKey(const ValueKey<String>('startup-home-host')),
          findsOneWidget,
        );
        expect(
          CompanionSessionScope.of(
            tester.element(
              find.byKey(const ValueKey<String>('startup-home-host')),
            ),
          ).portal.capturesWorld,
          isFalse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('macOS pet upgrades an existing visible compact Avatar lease', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      _registerPortalServices();
      final controller = DesktopWindowModeController(
        gateway: _IndependentFakeDesktopWindowGateway(),
      );
      windowController = controller;
      final route = ValueNotifier<String>('/login');
      addTearDown(route.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            routeListenable: route,
            currentRoute: () => route.value,
            child: const SizedBox(
              key: ValueKey<String>('compact-visible-upgrade-host'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final portal = CompanionSessionScope.of(
        tester.element(
          find.byKey(const ValueKey<String>('compact-visible-upgrade-host')),
        ),
      ).portal;
      final compactSummon = portal.summon(
        profile: AvatarPortalProfile.compactHigh,
      );
      final compactAcquire = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, compactAcquire);
      await compactSummon;
      expect(portal.phase, AvatarPortalPhase.visible);
      expect(portal.lease?.width, 320);
      calls.clear();

      await controller.enterPetMode();
      final desktopAcquire = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, desktopAcquire);
      await tester.pumpAndSettle();

      expect(calls.map((call) => call.method), <String>['release', 'acquire']);
      expect(
        (desktopAcquire.arguments as Map<Object?, Object?>)['profile'],
        AvatarPortalProfile.desktopHigh.wireName,
      );
      expect(portal.phase, AvatarPortalPhase.visible);
      expect(portal.lease?.width, 1024);
      expect(portal.lease?.height, 1792);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS pet upgrades an existing suspended compact Avatar lease', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      _registerPortalServices();
      final controller = DesktopWindowModeController(
        gateway: _IndependentFakeDesktopWindowGateway(),
      );
      windowController = controller;
      final route = ValueNotifier<String>('/login');
      addTearDown(route.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            routeListenable: route,
            currentRoute: () => route.value,
            child: const SizedBox(
              key: ValueKey<String>('compact-suspended-upgrade-host'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final portal = CompanionSessionScope.of(
        tester.element(
          find.byKey(const ValueKey<String>('compact-suspended-upgrade-host')),
        ),
      ).portal;
      final compactSummon = portal.summon(
        profile: AvatarPortalProfile.compactHigh,
      );
      final compactAcquire = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, compactAcquire);
      await compactSummon;
      await portal.suspend();
      expect(portal.phase, AvatarPortalPhase.suspended);
      calls.clear();

      await controller.enterPetMode();
      final desktopAcquire = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, desktopAcquire);
      await tester.pumpAndSettle();

      expect(calls.map((call) => call.method), <String>['release', 'acquire']);
      expect(
        (desktopAcquire.arguments as Map<Object?, Object?>)['profile'],
        AvatarPortalProfile.desktopHigh.wireName,
      );
      expect(portal.phase, AvatarPortalPhase.visible);
      expect(portal.lease?.width, 1024);
      expect(portal.lease?.height, 1792);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'Windows keeps the app visible until the native first-frame show completes',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final portalCalls = <MethodCall>[];
        _installPortalMock(portalChannel, portalCalls);
        final avatarRuntime = _registerPortalServices(
          registerAvatarConfig: false,
        );
        final transitionOrder = <String>[];
        final windowGateway = _SequencedIndependentFakeDesktopWindowGateway(
          transitionOrder,
        );
        final controller = DesktopWindowModeController(gateway: windowGateway);
        final host = _FirstFrameGatedDesktopCompanionHostGateway(
          transitionOrder,
        );
        final route = ValueNotifier<String>('/home');
        windowController = controller;
        addTearDown(route.dispose);
        addTearDown(() {
          if (!host.allowFirstFrame.isCompleted) {
            host.allowFirstFrame.complete();
          }
        });

        Widget buildShell() => MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            desktopCompanionHostGateway: host,
            routeListenable: route,
            currentRoute: () => route.value,
            child: const SizedBox(
              key: ValueKey<String>('windows-first-frame-gated-host'),
            ),
          ),
        );

        await tester.pumpWidget(buildShell());
        await tester.pump();

        expect(avatarRuntime.loadCalls, 0);
        expect(host.showStarted.isCompleted, isFalse);
        expect(controller.mode, DesktopWindowMode.app);
        expect(controller.petVisible, isFalse);
        expect(windowGateway.calls, isNot(contains('enterPetMode')));

        appServices.put(AvatarConfigService().init());
        await tester.pumpWidget(buildShell());
        for (var attempt = 0; attempt < 10; attempt += 1) {
          await tester.pump();
          if (host.showStarted.isCompleted) break;
        }

        expect(avatarRuntime.loadCalls, 1);
        expect(
          avatarRuntime.loadedModelUrl,
          AvatarConfigService.builtInCatalog.single.modelUrl,
        );
        expect(host.showStarted.isCompleted, isTrue);
        expect(portalCalls, isEmpty);
        expect(controller.mode, DesktopWindowMode.app);
        expect(controller.petVisible, isFalse);
        expect(windowGateway.calls, isNot(contains('enterPetMode')));
        expect(transitionOrder, <String>['show:start']);

        host.allowFirstFrame.complete();
        await tester.pumpAndSettle();

        expect(controller.mode, DesktopWindowMode.pet);
        expect(controller.petVisible, isTrue);
        expect(transitionOrder, <String>[
          'show:start',
          'show:complete',
          'enterPetMode',
        ]);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'desktop presentation FPS change replaces the active portal generation',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final calls = <MethodCall>[];
        _installPortalMock(portalChannel, calls);
        _registerPortalServices();
        final controller = DesktopWindowModeController(
          gateway: _IndependentFakeDesktopWindowGateway(),
        );
        windowController = controller;
        await controller.enterPetMode();
        await _pumpVisiblePet(
          tester,
          uiControl: uiControl,
          windowController: controller,
          portalChannel: portalChannel,
          calls: calls,
        );
        final initialAcquire = calls.firstWhere(
          (call) => call.method == 'acquire',
        );
        expect(initialAcquire.arguments, containsPair('targetFps', 30));
        calls.clear();

        final preferences = appServices
            .find<DesktopCompanionPreferencesService>();
        expect(await preferences.setTargetFps(60), isTrue);
        final replacementAcquire = await _waitForAcquire(tester, calls);

        expect(calls.map((call) => call.method), <String>[
          'release',
          'acquire',
        ]);
        expect(replacementAcquire.arguments, containsPair('targetFps', 60));
        await _sendFirstFrame(portalChannel, replacementAcquire);
        await tester.pumpAndSettle();
        expect(_visiblePetPortal(tester).lease?.generation, 2);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('macOS pet transition does not cancel a pending Avatar portal', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      _registerPortalServices();
      final gateway = _DelayedPetDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      windowController = controller;
      final route = ValueNotifier<String>('/login');
      addTearDown(route.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            routeListenable: route,
            currentRoute: () => route.value,
            child: const SizedBox(key: ValueKey<String>('pending-portal-host')),
          ),
        ),
      );
      await tester.pump();
      final portal = CompanionSessionScope.of(
        tester.element(
          find.byKey(const ValueKey<String>('pending-portal-host')),
        ),
      ).portal;
      final summon = portal.summon();
      final acquire = await _waitForAcquire(tester, calls);
      calls.clear();

      final transition = controller.enterPetMode();
      await gateway.enterPetModeStarted.future;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();

      expect(calls.where((call) => call.method == 'release'), isEmpty);

      gateway.allowEnterPetMode.complete();
      await transition;
      await tester.pump();
      expect(calls.where((call) => call.method == 'release'), isEmpty);

      await _sendFirstFrame(portalChannel, acquire);
      await summon;
      await tester.pump();
      // The pending compact request finishes before the queued desktop lease
      // is acquired. Only its replacement first frame makes the pet visible.
      expect(portal.phase, AvatarPortalPhase.waitingForFirstFrame);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final desktopAcquire = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, desktopAcquire);
      await tester.pumpAndSettle();
      expect(
        (desktopAcquire.arguments as Map<Object?, Object?>)['profile'],
        AvatarPortalProfile.desktopHigh.wireName,
      );
      expect(portal.phase, AvatarPortalPhase.visible);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'rapid hide and resume serializes suspend before crisp profile replacement',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final calls = <MethodCall>[];
      final suspendStarted = Completer<void>();
      final allowSuspend = Completer<void>();
      _installPortalMock(
        portalChannel,
        calls,
        onSuspend: () async {
          if (!suspendStarted.isCompleted) suspendStarted.complete();
          await allowSuspend.future;
        },
      );
      _registerPortalServices();
      final controller = DesktopWindowModeController(
        gateway: _FakeDesktopWindowGateway(),
      );
      windowController = controller;
      await controller.enterPetMode();
      await _pumpVisiblePet(
        tester,
        uiControl: uiControl,
        windowController: controller,
        portalChannel: portalChannel,
        calls: calls,
      );
      calls.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      await suspendStarted.future;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(calls.map((call) => call.method), <String>['suspend']);
      allowSuspend.complete();
      final replacementAcquire = await _waitForAcquire(tester, calls);

      expect(calls.map((call) => call.method), <String>[
        'suspend',
        'release',
        'acquire',
      ]);
      expect(
        replacementAcquire.arguments,
        containsPair('profile', AvatarPortalProfile.desktopHigh.wireName),
      );
      await _sendFirstFrame(portalChannel, replacementAcquire);
      await tester.pumpAndSettle();
      expect(find.byType(AvatarPortalTexture), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('pet mode retains the Avatar portal across router changes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = <MethodCall>[];
    _installPortalMock(portalChannel, calls);
    _registerPortalServices();
    final controller = DesktopWindowModeController(
      gateway: _IndependentFakeDesktopWindowGateway(),
    );
    windowController = controller;
    await controller.enterPetMode();
    final route = ValueNotifier<String>('/home');
    addTearDown(route.dispose);
    await _pumpVisiblePet(
      tester,
      uiControl: uiControl,
      windowController: controller,
      portalChannel: portalChannel,
      calls: calls,
      route: route,
    );
    calls.clear();

    route.value = '/settings';
    await tester.pumpAndSettle();

    expect(calls.where((call) => call.method == 'release'), isEmpty);
    expect(_visiblePetPortal(tester).phase, AvatarPortalPhase.visible);

    route.value = '/agent-space';
    await tester.pumpAndSettle();
    route.value = '/home';
    await tester.pumpAndSettle();

    expect(controller.petVisible, isTrue);
    expect(calls.where((call) => call.method == 'release'), isEmpty);
    expect(_visiblePetPortal(tester).phase, AvatarPortalPhase.visible);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('macOS Agent space summons the portal while the pet is hidden', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      _registerPortalServices();
      final controller = DesktopWindowModeController(
        gateway: _IndependentFakeDesktopWindowGateway(),
      );
      windowController = controller;
      final route = ValueNotifier<String>('/login');
      addTearDown(route.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            routeListenable: route,
            currentRoute: () => route.value,
            child: const UnityAvatarView(
              key: ValueKey<String>('world-portal-consumer'),
              includeWorld: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.petVisible, isFalse);
      calls.clear();

      route.value = '/agent-space';
      final acquire = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, acquire);
      await tester.pumpAndSettle();

      final portal = CompanionSessionScope.of(
        tester.element(
          find.byKey(const ValueKey<String>('world-portal-consumer')),
        ),
      ).portal;
      expect(controller.petVisible, isFalse);
      expect(portal.phase, AvatarPortalPhase.visible);
      expect(calls.where((call) => call.method == 'release'), isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'macOS authenticated Login keeps the doorway scene until Home takes over',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      _registerPortalServices();
      final lifecycle = _PortalAccountLifecycle()
        ..publish(mounted: false, ownsExecution: false);
      appServices.put<AccountSessionLifecycleService>(lifecycle);
      final controller = DesktopWindowModeController(
        gateway: _IndependentFakeDesktopWindowGateway(),
      );
      windowController = controller;
      final host = _SequencedDesktopCompanionHostGateway(<String>[]);
      final route = ValueNotifier<String>('/login');
      addTearDown(route.dispose);
      bool? sceneActive;
      await tester.pumpWidget(
        MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            desktopCompanionHostGateway: host,
            routeListenable: route,
            currentRoute: () => route.value,
            child: Builder(
              builder: (context) {
                sceneActive = AvatarPortalScope.of(context).sceneSurfaceActive;
                return const UnityAvatarView(
                  key: ValueKey<String>('login-scene-consumer'),
                  includeWorld: true,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sceneActive, isFalse);
      expect(calls.where((call) => call.method == 'acquire'), isEmpty);
      expect(controller.petVisible, isFalse);

      lifecycle.publish(ownsExecution: true);
      final sceneAcquire = await _waitForAcquire(tester, calls);
      expect(sceneActive, isTrue);
      expect(sceneAcquire.arguments, containsPair('includeWorld', true));
      final portal = AvatarPortalScope.of(
        tester.element(
          find.byKey(const ValueKey<String>('login-scene-consumer')),
        ),
      ).portal;
      calls.clear();

      // A companion lease update and application resume can occur while Unity
      // is preparing the room. Neither can replace or release Login's capture.
      lifecycle.publish(ownsExecution: false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.where((call) => call.method == 'release'), isEmpty);
      expect(calls.where((call) => call.method == 'acquire'), isEmpty);
      await _sendFirstFrame(portalChannel, sceneAcquire);
      await tester.pumpAndSettle();
      expect(portal.capturesWorld, isTrue);
      expect(portal.phase, AvatarPortalPhase.visible);
      expect(controller.petVisible, isFalse);
      expect(host.calls, isNot(contains('show')));

      // Login stays on its route through the final framing receipt. Only the
      // subsequent Home route returns capture ownership to the desktop pet.
      route.value = '/home';
      final petAcquire = await _waitForAcquire(tester, calls);
      expect(
        (petAcquire.arguments as Map<Object?, Object?>)['includeWorld'] ??
            false,
        isFalse,
      );
      await _sendFirstFrame(portalChannel, petAcquire);
      await tester.pumpAndSettle();
      expect(sceneActive, isFalse);
      expect(portal.capturesWorld, isFalse);
      expect(portal.phase, AvatarPortalPhase.visible);
      expect(controller.petVisible, isTrue);
      expect(host.calls, contains('show'));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'Mac window avatar scope excludes signed-out Login and app routes',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      _registerPortalServices();
      final controller = DesktopWindowModeController(
        gateway: _IndependentFakeDesktopWindowGateway(),
      );
      windowController = controller;
      final route = ValueNotifier<String>('/login');
      addTearDown(route.dispose);
      final rebuildChild = ValueNotifier<int>(0);
      addTearDown(rebuildChild.dispose);
      String? routeDuringBuild;
      bool? sceneActive;
      await tester.pumpWidget(
        MaterialApp(
          home: AppAgentShell(
            coordinator: uiControl,
            desktopWindowModeController: controller,
            desktopCompanionHostGateway: _SequencedDesktopCompanionHostGateway(
              <String>[],
            ),
            routeListenable: route,
            currentRoute: () => route.value,
            child: ValueListenableBuilder<int>(
              valueListenable: rebuildChild,
              builder: (context, _, _) {
                final nextRoute = routeDuringBuild;
                routeDuringBuild = null;
                if (nextRoute != null) route.value = nextRoute;
                sceneActive = AvatarPortalScope.of(context).sceneSurfaceActive;
                return const UnityAvatarView(includeWorld: true);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sceneActive, isFalse);
      expect(calls.where((call) => call.method == 'acquire'), isEmpty);
      route.value = '/agent-space';
      final acquire = await _waitForAcquire(tester, calls);
      await _sendFirstFrame(portalChannel, acquire);
      await tester.pumpAndSettle();
      expect(sceneActive, isTrue);
      expect(controller.mode, DesktopWindowMode.app);

      routeDuringBuild = '/agent-space';
      rebuildChild.value++;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(sceneActive, isTrue);

      for (final path in <String>[
        '/home',
        '/agent-selfie',
        '/live-host',
        '/settings',
        '/login',
      ]) {
        calls.clear();
        route.value = path;
        if (path == '/home') {
          final petCapture = await _waitForAcquire(tester, calls);
          await _sendFirstFrame(portalChannel, petCapture);
        }
        await tester.pumpAndSettle();
        expect(sceneActive, isFalse, reason: path);
        expect(controller.mode, DesktopWindowMode.app);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('pet resume re-summons dormant and failed Avatar portals', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = <MethodCall>[];
    _installPortalMock(portalChannel, calls);
    _registerPortalServices();
    final controller = DesktopWindowModeController(
      gateway: _FakeDesktopWindowGateway(),
    );
    windowController = controller;
    await controller.enterPetMode();
    await _pumpVisiblePet(
      tester,
      uiControl: uiControl,
      windowController: controller,
      portalChannel: portalChannel,
      calls: calls,
    );
    final portal = CompanionSessionScope.of(
      tester.element(find.byType(DesktopPetStage)),
    ).portal;

    await portal.release();
    await tester.pump();
    expect(portal.phase, AvatarPortalPhase.dormant);
    calls.clear();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final dormantAcquire = await _waitForAcquire(tester, calls);
    await _sendFirstFrame(portalChannel, dormantAcquire);
    await tester.pumpAndSettle();

    expect(portal.phase, AvatarPortalPhase.visible);
    expect(find.byType(AvatarPortalTexture), findsOneWidget);

    final failedGeneration = portal.lease!.generation;
    await _sendNativeCall(
      portalChannel,
      MethodCall('event', <String, Object>{
        'type': 'released',
        'generation': failedGeneration,
        'reason': 'memoryPressure',
      }),
    );
    await tester.pump();
    expect(portal.phase, AvatarPortalPhase.failed);
    calls.clear();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final failedAcquire = await _waitForAcquire(tester, calls);
    await _sendFirstFrame(portalChannel, failedAcquire);
    await tester.pumpAndSettle();

    expect(portal.phase, AvatarPortalPhase.visible);
    expect(find.byType(AvatarPortalTexture), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });
}

void _installPortalMock(
  MethodChannel portalChannel,
  List<MethodCall> calls, {
  Future<void> Function()? onSuspend,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(portalChannel, (call) async {
        calls.add(call);
        if (call.method == 'acquire') {
          final arguments = call.arguments as Map<Object?, Object?>;
          final desktopHigh =
              arguments['profile'] == AvatarPortalProfile.desktopHigh.wireName;
          return <String, Object>{
            'textureId': 91,
            'width':
                arguments['viewportWidth'] as int? ??
                (desktopHigh ? 1024 : 320),
            'height':
                arguments['viewportHeight'] as int? ??
                (desktopHigh ? 1792 : 560),
            'generation': arguments['generation']! as int,
          };
        }
        if (call.method == 'suspend' && onSuspend != null) {
          await onSuspend();
        }
        return null;
      });
}

_ReadyAvatarRuntime _registerPortalServices({
  bool runtimeReady = true,
  bool registerAvatarConfig = true,
}) {
  final activeAvatar = appServices.put(ActiveAvatarRuntime());
  final runtime = _ReadyAvatarRuntime()..isReady.value = runtimeReady;
  activeAvatar.register(runtime);
  if (registerAvatarConfig) {
    appServices.put(AvatarConfigService().init());
  }
  appServices.put(DBService());
  appServices.put(AgentRuntimeRegistry());
  appServices.put(AgentReplyPresentationService());
  appServices.put(DesktopCompanionPreferencesService());
  return runtime;
}

Future<void> _pumpVisiblePet(
  WidgetTester tester, {
  required AgentUiControlCoordinator uiControl,
  required DesktopWindowModeController windowController,
  required MethodChannel portalChannel,
  required List<MethodCall> calls,
  ValueNotifier<String>? route,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: 320,
        height: 420,
        child: AppAgentShell(
          coordinator: uiControl,
          desktopWindowModeController: windowController,
          routeListenable: route,
          currentRoute: route == null ? null : () => route.value,
          child: const ColoredBox(
            key: ValueKey<String>('visible-pet-host'),
            color: Colors.white,
          ),
        ),
      ),
    ),
  );
  if (windowController.supportsIndependentPetWindow &&
      windowController.petVisible) {
    // The production shell transitions from the visible app into pet mode
    // after mounting. Recreate that notification when a test injects a
    // controller that was already placed in independent-pet mode.
    await windowController.hidePet();
    await windowController.enterPetMode();
  }
  for (var attempt = 0; attempt < 10; attempt += 1) {
    await tester.pump();
    if (calls.any((call) => call.method == 'acquire')) break;
  }
  final acquire = calls.firstWhere((call) => call.method == 'acquire');
  await _sendFirstFrame(portalChannel, acquire);
  await tester.pump();
  if (windowController.supportsIndependentPetWindow) {
    expect(_visiblePetPortal(tester).phase, AvatarPortalPhase.visible);
  } else {
    expect(find.byType(AvatarPortalTexture), findsOneWidget);
  }
}

AvatarPortalCoordinator _visiblePetPortal(WidgetTester tester) =>
    CompanionSessionScope.of(
      tester.element(find.byKey(const ValueKey<String>('visible-pet-host'))),
    ).portal;

Future<MethodCall> _waitForAcquire(
  WidgetTester tester,
  List<MethodCall> calls,
) async {
  for (var attempt = 0; attempt < 10; attempt += 1) {
    await tester.pump();
    if (calls.any((call) => call.method == 'acquire')) break;
  }
  return calls.lastWhere((call) => call.method == 'acquire');
}

Future<void> _sendFirstFrame(
  MethodChannel portalChannel,
  MethodCall acquire,
) async {
  final arguments = acquire.arguments as Map<Object?, Object?>;
  final generation = arguments['generation']! as int;
  final desktopHigh =
      arguments['profile'] == AvatarPortalProfile.desktopHigh.wireName;
  await _sendNativeCall(
    portalChannel,
    MethodCall('event', <String, Object>{
      'type': 'firstFrame',
      'generation': generation,
      'textureId': 91,
      'width': arguments['viewportWidth'] as int? ?? (desktopHigh ? 1024 : 320),
      'height':
          arguments['viewportHeight'] as int? ?? (desktopHigh ? 1792 : 560),
    }),
  );
}

Future<void> _sendNativeCall(MethodChannel channel, MethodCall call) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = channel.codec.encodeMethodCall(call);
  await messenger.handlePlatformMessage(channel.name, data, (_) {});
}

class _ReadyAvatarRuntime extends AvatarRuntime {
  int loadCalls = 0;
  String? loadedModelUrl;
  final visibility = <bool>[];
  bool modelVisible = false;
  int modelEpoch = 0;
  Completer<void>? loadGate;
  @override
  int get modelLoadEpoch => modelEpoch;

  @override
  Future<void> setLocalAvatarVisible(bool visible) async {
    visibility.add(visible);
    modelVisible = visible;
  }

  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;

  @override
  final isReady = false.obs;

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const <String, dynamic>{},
  ]) async {
    loadCalls += 1;
    loadedModelUrl = modelUrl;
    await loadGate?.future;
    isReady.value = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeDesktopWindowGateway implements DesktopWindowGateway {
  final List<String> calls = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 20, top: 20, width: 1000, height: 700);

  @override
  Future<void> enterPetMode() async {
    calls.add('enterPetMode');
  }

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {
    calls.add('enterAppMode');
  }

  @override
  Future<void> startDragging() async {}
}

class _IndependentFakeDesktopWindowGateway extends _FakeDesktopWindowGateway
    implements IndependentDesktopPetWindowGateway {
  @override
  bool get supportsIndependentPetWindow => true;
}

class _SequencedIndependentFakeDesktopWindowGateway
    extends _IndependentFakeDesktopWindowGateway {
  _SequencedIndependentFakeDesktopWindowGateway(this.transitionOrder);

  final List<String> transitionOrder;

  @override
  Future<void> enterPetMode() async {
    transitionOrder.add('enterPetMode');
    await super.enterPetMode();
  }
}

class _DelayedPetDesktopWindowGateway
    extends _IndependentFakeDesktopWindowGateway {
  final enterPetModeStarted = Completer<void>();
  final allowEnterPetMode = Completer<void>();

  @override
  Future<void> enterPetMode() async {
    enterPetModeStarted.complete();
    await allowEnterPetMode.future;
  }
}

class _FakeDesktopCompanionHostGateway implements DesktopCompanionHostGateway {
  final List<String> calls = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize({
    required FutureOr<void> Function(String id) onMenuSelected,
    required FutureOr<void> Function(DesktopCompanionHostCommand command)
    onCommand,
    required FutureOr<void> Function(Offset? gaze) onGazeChanged,
    required FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)
    onInteraction,
  }) async {
    calls.add('initialize');
  }

  @override
  Future<void> configureMenu(List<DesktopCompanionHostMenuItem> items) async {
    calls.add('configureMenu');
  }

  @override
  Future<void> configurePresentation(
    DesktopCompanionPresentationConfigV1 config,
  ) async {
    calls.add('configurePresentation');
  }

  @override
  Future<void> show({required int interactionGeneration}) async {
    calls.add('show');
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
  }

  @override
  Future<void> showBubble(String text) async {
    calls.add('showBubble');
  }

  @override
  Future<void> clearBubble() async {
    calls.add('clearBubble');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }
}

class _SequencedDesktopCompanionHostGateway
    extends _FakeDesktopCompanionHostGateway {
  _SequencedDesktopCompanionHostGateway(this.transitionOrder);

  final List<String> transitionOrder;

  @override
  Future<void> show({required int interactionGeneration}) async {
    transitionOrder.add('show');
    await super.show(interactionGeneration: interactionGeneration);
  }
}

class _FirstFrameGatedDesktopCompanionHostGateway
    extends _FakeDesktopCompanionHostGateway {
  _FirstFrameGatedDesktopCompanionHostGateway(this.transitionOrder);

  final List<String> transitionOrder;
  final Completer<void> showStarted = Completer<void>();
  final Completer<void> allowFirstFrame = Completer<void>();

  @override
  Future<void> show({required int interactionGeneration}) async {
    transitionOrder.add('show:start');
    if (!showStarted.isCompleted) showStarted.complete();
    await allowFirstFrame.future;
    await super.show(interactionGeneration: interactionGeneration);
    transitionOrder.add('show:complete');
  }
}

/// Separates account mounting from the executor lease for visual portal tests.
class _PortalAccountLifecycle extends AppService
    implements AccountSessionLifecycleService {
  final _changes = ChangeNotifier();
  bool _mounted = true;
  bool _ownsExecution = true;

  @override
  final phase = AccountSessionLifecyclePhase.mounted.obs;
  @override
  int generation = 1;
  @override
  bool get isMounted => _mounted;
  @override
  bool get canPresentAvatar => _mounted;
  @override
  bool get canExecuteAgent => _mounted && _ownsExecution;
  @override
  bool get usesExclusiveDeviceLease => true;
  @override
  AccountRuntimeAuthorityMode get effectiveAuthorityMode =>
      AccountRuntimeAuthorityMode.enforce;

  void publish({bool mounted = true, required bool ownsExecution}) {
    _mounted = mounted;
    _ownsExecution = ownsExecution;
    phase.value = mounted
        ? AccountSessionLifecyclePhase.mounted
        : AccountSessionLifecyclePhase.retiring;
    _changes.notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);
  @override
  void updateApplicationPresence({
    required bool foreground,
    bool handoffInProgress = false,
  }) {}
  @override
  void onClose() {
    _changes.dispose();
    super.onClose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _DeferredPortalSpaceExit extends AgentSpaceController {
  _DeferredPortalSpaceExit() : super(avatar: ActiveAvatarRuntime());
  final leaveStarted = Completer<void>();
  final allowLeave = Completer<void>();

  @override
  Future<void> leave({
    bool animated = false,
    AvatarViewportSafeArea? homeViewportSafeArea,
  }) {
    if (!leaveStarted.isCompleted) leaveStarted.complete();
    return allowLeave.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
