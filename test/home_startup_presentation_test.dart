import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_selection_startup_retry.dart';
import 'package:maaso/src/core/services/app_launch_presentation_session.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_agent_space.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/auth/application/login_doorway_coordinator.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/application/home_avatar_entrance_coordinator.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_native_text_editor.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Exercise the real HomeController subscription and its synchronous onInit
// reconciliation. Only the account authority source and Agent boot are faked;
// no UI test is allowed to grant execution merely to reserve the mobile stage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AgentRuntimeRegistry registry;
  late _PresentationLifecycle lifecycle;
  late HomePresentationPreferenceService presentation;
  late AgentUiControlCoordinator uiControl;
  var databaseSerial = 0;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    uiControl = AgentUiControlCoordinator();
    SharedPreferences.setMockInitialValues({});
    presentation = await appServices
        .putAsync<HomePresentationPreferenceService>(
          () => HomePresentationPreferenceService().load(),
        );
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    appServices.put(
      await DBService().init(
        factory: databaseFactoryMemory,
        path: 'home-startup-presentation-${databaseSerial++}.db',
      ),
    );
    registry = appServices.put(
      AgentRuntimeRegistry(hostExecutionEnabled: false),
    );
    appServices.put(AgentTaskJobStore());
    appServices.put<AgentCoreController>(_UnbootedCore());
    lifecycle = _PresentationLifecycle(registry);
    appServices.put<AccountSessionLifecycleService>(lifecycle);
  });

  tearDown(() async {
    await uiControl.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    debugDefaultTargetPlatformOverride = null;
    await appServices.reset();
  });

  Future<HomeController> mountHome(
    WidgetTester tester, {
    bool withShell = false,
    HomeDraftIntent? draftIntent,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);
    final home = appServices.put(HomeController());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          theme: AppTheme.build(
            AppPalette.of(Brightness.light, AppAccent.blue),
          ),
          home: !withShell
              ? HomePage(draftIntent: draftIntent)
              : AppAgentShell(
                  coordinator: uiControl,
                  currentRoute: () => '/home',
                  child: HomePage(draftIntent: draftIntent),
                ),
        ),
      ),
    );
    return home;
  }

  final avatarWindow = find.byKey(const ValueKey('home-avatar-chat-window'));

  Future<void> unmountHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await appServices.delete<HomeController>();
    debugDefaultTargetPlatformOverride = null;
  }

  _EntranceRenderer installRenderer({bool ready = true, bool? presented}) {
    final renderer = _EntranceRenderer(ready: ready, presented: presented);
    appServices.put<ActiveAvatarRuntime>(
      ActiveAvatarRuntime()..register(renderer),
    );
    return renderer;
  }

  Future<void> flushPresentation(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  void expectCovered(WidgetTester tester) {
    expect(find.byKey(const ValueKey('home-startup-transition')), findsNothing);
    expect(find.byType(UnityAvatarView), findsOneWidget);
    expect(avatarWindow, findsOneWidget);
    expect(
      tester
          .widget<Scaffold>(
            find.ancestor(of: avatarWindow, matching: find.byType(Scaffold)),
          )
          .backgroundColor,
      Colors.transparent,
    );
  }

  Future<void> finishEntry(
    WidgetTester tester,
    _EntranceRenderer renderer, {
    bool animated = true,
  }) async {
    expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
    renderer.completeLast();
    await flushPresentation(tester);
    expect(
      renderer.commands.last.phase,
      animated ? AvatarPresencePhase.enter : AvatarPresencePhase.restore,
    );
    if (!renderer.receipts.last.isCompleted) renderer.completeLast();
    await flushPresentation(tester);
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      '${platform.name} Home leaves the independent pet renderer visible',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        lifecycle.publish(local: true);
        final renderer = installRenderer();
        await renderer.setLocalAvatarVisible(true);
        await mountHome(tester);
        await flushPresentation(tester);

        expect(find.byType(UnityAvatarView), findsNothing);
        expect(find.byType(HomeChatHistory), findsOneWidget);
        expect(renderer.visibility, [true]);

        await tester.runAsync(
          () => presentation.setMode(HomePresentationMode.chat),
        );
        renderer.isReady.value = false;
        await flushPresentation(tester);
        renderer.isReady.value = true;
        await tester.runAsync(
          () => presentation.setMode(HomePresentationMode.avatar),
        );
        await flushPresentation(tester);

        expect(
          renderer.visibility,
          [true],
          reason:
              'Desktop Home does not own the shared pet renderer visibility.',
        );
        expect(renderer.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await unmountHome(tester);
      },
    );
  }

  testWidgets(
    'unknown location immediately shows the avatar Home without execution',
    (tester) async {
      final home = await mountHome(tester);
      home.inputController.text = '离线时继续写';
      expect(lifecycle.canExecuteAgent, isFalse);
      expect(registry.canHostExecution, isFalse);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(avatarWindow, findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(find.text('home.agent_location_connecting'.tr), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(avatarWindow, findsOneWidget);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(home.inputController.text, '离线时继续写');
      expect(lifecycle.canExecuteAgent, isFalse);
      expect(registry.canHostExecution, isFalse);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets('restored local admission starts directly on the Agent stage', (
    tester,
  ) async {
    lifecycle.publish(local: true);
    await mountHome(tester);
    expect(avatarWindow, findsOneWidget);
    expect(find.byType(UnityAvatarView), findsOneWidget);
    expect(find.byKey(const ValueKey('home-agent-away-chat')), findsNothing);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  testWidgets(
    'cold authenticated Home keeps a scene still and controls while Unity wakes',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer(ready: false);
      await mountHome(tester);
      await flushPresentation(tester);

      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-native-scene-poster')),
        findsOneWidget,
      );
      final roomStill = tester.widget<Image>(
        find.descendant(
          of: find.byKey(const ValueKey('home-native-scene-poster')),
          matching: find.byType(Image),
        ),
      );
      expect(
        roomStill.image,
        isA<AssetImage>().having(
          (source) => source.assetName,
          'assetName',
          'assets/brand/home_room.png',
        ),
      );
      expect(roomStill.fit, BoxFit.cover);
      expect(roomStill.excludeFromSemantics, isTrue);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(avatarWindow, findsOneWidget);
      expect(find.byKey(const ValueKey('home-composer-slot')), findsOneWidget);
      expect(renderer.commands, isEmpty);

      renderer.isReady.value = true;
      await flushPresentation(tester);
      expect(
        find.byKey(const ValueKey('home-native-scene-poster')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
      await finishEntry(tester, renderer);
      expect(avatarWindow, findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'read-only Avatar startup keeps the room and offers an account-bound retry',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      final config = appServices.put(
        AvatarConfigService(persistSelection: (_, _) async => true).init(),
      );
      final generation = lifecycle.generation;
      var passes = 0;
      final releaseRetry = Completer<void>();
      void requireOwner() {
        if (lifecycle.generation != generation) {
          throw StateError('account mount replaced');
        }
      }

      await AvatarSelectionStartupRetry.forConfig(config).run(
        requireCurrentMount: requireOwner,
        reconcile: () async {
          passes++;
          if (passes == 1) return;
          await releaseRetry.future;
          requireOwner();
          config.selectionAuthorityState.value =
              AvatarSelectionAuthorityState.ready;
        },
      );
      config.selectionAuthorityState.value =
          AvatarSelectionAuthorityState.readOnlyBundled;
      await mountHome(tester);
      await flushPresentation(tester);

      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(avatarWindow, findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(find.text('home.avatar_selection_unavailable'.tr), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-avatar-selection-retry')),
        findsOneWidget,
      );
      expect(renderer.visibility.last, isFalse);

      await tester.tap(
        find.byKey(const ValueKey('home-avatar-selection-retry')),
      );
      await flushPresentation(tester);
      expect(passes, 2);
      expect(find.text('home.avatar_selection_retrying'.tr), findsOneWidget);
      expect(renderer.visibility.last, isFalse);

      releaseRetry.complete();
      await flushPresentation(tester);
      expect(find.text('home.avatar_selection_retrying'.tr), findsNothing);
      expect(find.text('home.avatar_selection_unavailable'.tr), findsNothing);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'lost admission and failed recovery preserve the avatar and draft',
    (tester) async {
      lifecycle.publish(local: true);
      final home = await mountHome(tester);
      home.inputController.text = '恢复后继续写';
      // Compare admission changes with the same settled draft/editor geometry.
      await flushPresentation(tester);
      final stageRect = tester.getRect(avatarWindow);
      lifecycle.publish(local: false, recovering: true);
      await tester.pump();
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(tester.getRect(avatarWindow), stageRect);
      lifecycle.publish(local: false);
      await tester.pump(const Duration(seconds: 45));
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(avatarWindow, findsOneWidget);
      expect(home.inputController.text, '恢复后继续写');
      lifecycle.publish(local: true);
      await tester.pump();
      expect(tester.getRect(avatarWindow), stageRect);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets('remote executor keeps the selected avatar Home on this device', (
    tester,
  ) async {
    lifecycle.publish(local: false, remote: _remoteHolder);
    await mountHome(tester);
    expect(avatarWindow, findsOneWidget);
    expect(find.byType(UnityAvatarView), findsOneWidget);
    expect(presentation.mode.value, HomePresentationMode.avatar);
    expect(lifecycle.canExecuteAgent, isFalse);
    await unmountHome(tester);
  });

  testWidgets('completed login framing never reopens Home preparation', (
    tester,
  ) async {
    lifecycle.publish(local: true);
    final renderer = installRenderer();
    final doorway = appServices.put(
      LoginDoorwayCoordinator(
        currentScope: () => 'account-a',
        currentGeneration: () => 1,
        accountMounted: () => true,
        consumeEntrance: () => true,
      ),
    );
    doorway.requestAuthenticated();
    doorway.reconcile(
      renderer: _InstantDoorwayAvatar(),
      canPresent: () => true,
      reduceMotion: false,
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    expect(doorway.completed, isTrue);
    await mountHome(tester);
    await flushPresentation(tester);
    expect(renderer.commands, isEmpty);
    expect(find.byKey(const ValueKey('home-startup-transition')), findsNothing);
    expect(
      find.byKey(const ValueKey('home-native-scene-poster')),
      findsNothing,
    );
    expect(avatarWindow, findsOneWidget);
    await unmountHome(tester);
  });

  testWidgets(
    'interrupted login retains the scene still until Home can restore the pose',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer(ready: false);
      final doorway = appServices.put(
        LoginDoorwayCoordinator(
          currentScope: () => 'account-a',
          currentGeneration: () => 1,
          accountMounted: () => true,
          consumeEntrance:
              AppLaunchPresentationSession.ensure().consumeAuthenticatedDoorway,
        ),
      );
      doorway.requestAuthenticated();
      doorway.interrupt();
      await mountHome(tester);
      await flushPresentation(tester);

      expect(
        find.byKey(const ValueKey('home-native-scene-poster')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(avatarWindow, findsOneWidget);
      expect(renderer.commands, isEmpty);

      renderer.isReady.value = true;
      await flushPresentation(tester);
      expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
      await finishEntry(tester, renderer, animated: false);
      expect(renderer.phases, isNot(contains(AvatarPresencePhase.enter)));
      expect(
        find.byKey(const ValueKey('home-native-scene-poster')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'a mounted remote companion displays its avatar without execution authority',
    (tester) async {
      lifecycle.publish(local: false, remote: _remoteHolder);
      final renderer = installRenderer();
      await mountHome(tester, withShell: true);
      await flushPresentation(tester);
      expect(lifecycle.canExecuteAgent, isFalse);
      expect(registry.canHostExecution, isFalse);
      expect(avatarWindow, findsOneWidget);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(renderer.visibility.last, isFalse);
      await finishEntry(tester, renderer);
      expect(renderer.visibility.last, isTrue);
      expect(renderer.phases, isNot(contains(AvatarPresencePhase.exit)));
      await unmountHome(tester);
    },
  );

  for (final busyBeforeEntry in [false, true]) {
    testWidgets(
      'execution handoff busy ${busyBeforeEntry ? "before" : "after"} local entry cannot hide Home',
      (tester) async {
        lifecycle.publish(local: false, remote: _remoteHolder);
        final renderer = installRenderer();
        final bridge = _PendingExecutionBridge();
        final handoff = AgentHandoffService(
          authority: _BusyExecutionAuthority(),
          gateway: _UnusedExecutionGateway(),
          bridge: bridge,
          accountContext: () => const HandoffAccountContext(
            environment: MaasoEnvironment.test,
            accountUuid: 'home-display-account',
            presenceSessionId: 'source-presence',
          ),
          serializeAuthority: <T>(Future<T> Function() work) => work(),
        );
        appServices.put<AgentHandoffService>(handoff);
        addTearDown(handoff.dispose);
        Future<void>? request;
        addTearDown(() {
          if (request != null && !bridge.identity.isCompleted) {
            bridge.identity.completeError(StateError('execution test retired'));
          }
        });
        void startExecutionHandoff() {
          request = handoff
              .request('target-presence')
              .then<void>((_) {}, onError: (Object _, StackTrace _) {});
        }

        if (busyBeforeEntry) startExecutionHandoff();
        final home = await mountHome(tester, withShell: true);
        home.inputController.text = '执行权交接时保留人物和草稿';
        await flushPresentation(tester);
        await finishEntry(tester, renderer);
        final commandCount = renderer.commands.length;
        if (!busyBeforeEntry) startExecutionHandoff();
        await flushPresentation(tester);

        expect(handoff.isBusy, isTrue);
        expect(renderer.visibility.last, isTrue);
        expect(renderer.commands, hasLength(commandCount));
        expect(find.byType(UnityAvatarView), findsOneWidget);
        expect(avatarWindow, findsOneWidget);
        expect(lifecycle.canExecuteAgent, isFalse);
        expect(home.inputController.text, '执行权交接时保留人物和草稿');

        bridge.identity.completeError(StateError('execution test completed'));
        await tester.pump();
        await request;
        await flushPresentation(tester);
        expect(handoff.isBusy, isFalse);
        expect(renderer.visibility.last, isTrue);
        expect(renderer.commands, hasLength(commandCount));
        expect(tester.takeException(), isNull);
        await unmountHome(tester);
      },
    );
  }

  testWidgets(
    'unknown executor follows the same local entry without execution authority',
    (tester) async {
      final renderer = installRenderer();
      await mountHome(tester, withShell: true);
      await flushPresentation(tester);
      expect(renderer.visibility.last, isFalse);
      expect(renderer.phases, [AvatarPresencePhase.prepare]);
      lifecycle.publish(local: false, recovering: true);
      await flushPresentation(tester);
      expect(renderer.phases, [AvatarPresencePhase.prepare]);
      await finishEntry(tester, renderer);
      expect(renderer.visibility.last, isTrue);
      expect(lifecycle.canExecuteAgent, isFalse);
      expect(registry.canHostExecution, isFalse);
      expect(avatarWindow, findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'remote executor confirmation preserves the visible avatar and draft',
    (tester) async {
      final renderer = installRenderer();
      final home = await mountHome(tester, withShell: true);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      final commands = renderer.commands.length;
      home.inputController.text = '给远端 Agent 的草稿';
      lifecycle.publish(local: false, remote: _remoteHolder);
      await flushPresentation(tester);
      expect(renderer.commands, hasLength(commands));
      expect(renderer.phases, isNot(contains(AvatarPresencePhase.exit)));
      expect(renderer.visibility.last, isTrue);
      expect(avatarWindow, findsOneWidget);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(presentation.mode.value, HomePresentationMode.avatar);
      expect(home.inputController.text, '给远端 Agent 的草稿');
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'ready engine retains the room poster until its presentation host is ready',
    (tester) async {
      final renderer = installRenderer(presented: false);
      await mountHome(tester);
      await flushPresentation(tester);
      final poster = find.byKey(const ValueKey('home-native-scene-poster'));
      expect(renderer.isReady.value, isTrue);
      expect(poster, findsOneWidget);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      renderer.presentationReady.value = true;
      await flushPresentation(tester);
      expect(poster, findsNothing);
      await finishEntry(tester, renderer);
      renderer.presentationReady.value = false;
      await flushPresentation(tester);
      expect(renderer.isReady.value, isTrue);
      expect(poster, findsOneWidget);
      renderer.presentationReady.value = true;
      await flushPresentation(tester);
      expect(poster, findsNothing);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'resume serializes a delayed native hide before the final same-model reveal',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      final commandCount = renderer.commands.length;
      final before = renderer.visibilityRequests.length;
      renderer.blockedHide = Completer<void>();
      await tester.runAsync(
        () => presentation.setMode(HomePresentationMode.chat),
      );
      await flushPresentation(tester);
      expect(renderer.visibilityRequests.sublist(before), [false]);
      expect(renderer.hideInFlight, isTrue);
      await tester.runAsync(
        () => presentation.setMode(HomePresentationMode.avatar),
      );
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await flushPresentation(tester);
      expect(
        renderer.visibilityRequests.sublist(before),
        [false],
        reason:
            'The current reveal must wait for the native hide already in flight.',
      );
      renderer.blockedHide!.complete();
      await flushPresentation(tester);
      expect(renderer.visibilityRequests.sublist(before), [false, true]);
      expect(renderer.visibility.last, isTrue);
      expect(renderer.commands, hasLength(commandCount));
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'same model is revealed again after background hides it without replaying entry',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      final home = await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      final originalEpoch = renderer.modelLoadEpoch;
      final originalCommands = renderer.commands.length;
      home.inputController.text = '回来继续写';
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      // The native host/account model owner can hide the same model without
      // changing its load epoch or selected model generation.
      await renderer.setLocalAvatarVisible(false);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await flushPresentation(tester);
      expect(renderer.visibility.last, isTrue);
      expect(renderer.modelLoadEpoch, originalEpoch);
      expect(renderer.commands, hasLength(originalCommands));
      expect(home.inputController.text, '回来继续写');
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'same-model native view retry obtains a new reveal receipt after external hide',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer(presented: true);
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      final originalEpoch = renderer.modelLoadEpoch;
      final beforeReattach = renderer.visibility.length;
      renderer.presentationReady.value = false;
      await renderer.setLocalAvatarVisible(false);
      await flushPresentation(tester);
      await tester.pump(const Duration(seconds: 22));
      await flushPresentation(tester);
      await tester.tap(find.byKey(const ValueKey('home-avatar-entry-retry')));
      await flushPresentation(tester);
      renderer.presentationReady.value = true;
      await flushPresentation(tester);
      await finishEntry(tester, renderer, animated: false);
      expect(renderer.visibility.sublist(beforeReattach), contains(true));
      expect(renderer.visibility.last, isTrue);
      expect(renderer.modelLoadEpoch, originalEpoch);
      expect(
        renderer.phases.where((phase) => phase == AvatarPresencePhase.enter),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'presentation timeout retries the native view while retaining the room and draft',
    (tester) async {
      final renderer = installRenderer(presented: false);
      final home = await mountHome(tester);
      await flushPresentation(tester);
      expect(renderer.commands, isEmpty);
      home.inputController.text = '重新连接人物后继续写';
      final originalNativeView = tester.element(find.byType(UnityAvatarView));
      final poster = find.byKey(const ValueKey('home-native-scene-poster'));
      await tester.pump(const Duration(seconds: 22));
      await flushPresentation(tester);
      expect(poster, findsOneWidget);
      expect(find.text('home.avatar_entry_failed'.tr), findsOneWidget);
      final retry = find.byKey(const ValueKey('home-avatar-entry-retry'));
      expect(retry, findsOneWidget);
      await tester.tap(retry);
      await flushPresentation(tester);
      expect(find.text('home.avatar_entry_failed'.tr), findsNothing);
      expect(poster, findsOneWidget);
      expect(
        tester.element(find.byType(UnityAvatarView)),
        isNot(same(originalNativeView)),
      );
      expect(home.inputController.text, '重新连接人物后继续写');
      expect(avatarWindow, findsOneWidget);
      renderer.presentationReady.value = true;
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      expect(poster, findsNothing);
      expect(retry, findsNothing);
      expect(home.inputController.text, '重新连接人物后继续写');
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'unknown location keeps the room while an unready actor stays hidden',
    (tester) async {
      final renderer = installRenderer(ready: false);
      await mountHome(tester);
      await flushPresentation(tester);
      await tester.pump(const Duration(minutes: 1));
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(avatarWindow, findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(renderer.commands, isEmpty);
      expect(renderer.visibility.last, isFalse);
      renderer.isReady.value = true;
      await flushPresentation(tester);
      expect(renderer.visibility.last, isFalse);
      await finishEntry(tester, renderer);
      expect(renderer.visibility.last, isTrue);
      expect(lifecycle.canExecuteAgent, isFalse);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'a fast model replacement cannot reuse the previous visibility receipt',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      final selection = appServices.put(
        AvatarConfigService(
          initialCatalog: const [
            ...AvatarConfigService.builtInCatalog,
            AvatarOption(
              id: 'matt',
              name: 'Matt',
              backend: AvatarBackendKind.unity,
              modelUrl: 'unity://masso/avatar_matt',
            ),
          ],
          persistSelection: (_, _) async => true,
        ),
      );
      await selection.applyInitial();
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      final before = renderer.visibility.length;
      renderer.instantPresence = true;
      await selection.select('matt');
      // Native can hide, load and report readiness between Flutter frames.
      // Home still must reveal this model with its own current acknowledgement.
      expect(renderer.visibility.last, isFalse);
      await flushPresentation(tester);
      expect(renderer.visibility.sublist(before), contains(true));
      expect(renderer.visibility.last, isTrue);
      expect(renderer.phases.take(2), [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.enter,
      ]);
      expect(renderer.phases.skip(2), [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.restore,
      ]);
      expect(find.text('home.avatar_entry_failed'.tr), findsNothing);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'new selected models restore after preparation without replaying launch entry',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      final selection = appServices.put(
        AvatarConfigService(
          initialCatalog: const [
            ...AvatarConfigService.builtInCatalog,
            AvatarOption(
              id: 'matt',
              name: 'Matt',
              backend: AvatarBackendKind.unity,
              modelUrl: 'unity://masso/avatar_matt',
            ),
          ],
          persistSelection: (_, _) async => true,
        ),
      );
      await selection.applyInitial();
      expect(selection.selectionDisplayCurrent, isTrue);
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      final initialCommands = renderer.commands.length;

      renderer.blockedModelLoad = Completer<void>();
      final selectMatt = selection.select('matt');
      await flushPresentation(tester);
      expect(renderer.visibility.last, isFalse);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(avatarWindow, findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );

      renderer.blockedModelLoad!.complete();
      await selectMatt;
      await flushPresentation(tester);
      expect(
        renderer.visibility.last,
        isFalse,
        reason: 'visibility=${renderer.visibility} phases=${renderer.phases}',
      );
      expect(renderer.commands, hasLength(initialCommands + 1));
      expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
      expect(avatarWindow, findsOneWidget);
      renderer.completeLast();
      await flushPresentation(tester);
      expect(renderer.visibility.last, isTrue);
      expect(renderer.commands.last.phase, AvatarPresencePhase.restore);

      // A native renderer reset can reload the same Matt model. Its selected
      // ID is unchanged, but the model epoch needs a fresh preparation/restore.
      final mattGeneration = selection.selectionDisplayGeneration.value;
      final beforeReset = renderer.commands.length;
      renderer.isReady.value = false;
      renderer.resetNativeModel();
      await flushPresentation(tester);
      expect(renderer.visibility.last, isFalse);
      renderer.isReady.value = true;
      await selection.applyInitial();
      await flushPresentation(tester);
      expect(selection.selectionDisplayGeneration.value, mattGeneration);
      expect(renderer.commands, hasLength(beforeReset + 1));
      expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
      expect(renderer.visibility.last, isFalse);
      await finishEntry(tester, renderer, animated: false);
      expect(renderer.visibility.last, isTrue);

      final settledCommands = renderer.commands.length;
      selection.selectionDisplayReady.value = false;
      await flushPresentation(tester);
      selection.selectionDisplayReady.value = true;
      await flushPresentation(tester);
      expect(renderer.commands, hasLength(settledCommands));
      expect(renderer.visibility.last, isTrue);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);

      // A deep link may replace rather than push Home while the model store is
      // open. The account-scoped receipt must survive that Home State disposal.
      renderer.blockedModelLoad = Completer<void>();
      final selectAgent = selection.select('agent');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await mountHome(tester);
      await flushPresentation(tester);
      expect(renderer.visibility.last, isFalse);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(avatarWindow, findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      renderer.blockedModelLoad!.complete();
      await selectAgent;
      await flushPresentation(tester);
      expect(renderer.commands, hasLength(settledCommands + 1));
      expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
      expect(renderer.visibility.last, isFalse);
      renderer.receipts.last.completeError(
        const AvatarPresenceTransitionException('transition_busy'),
      );
      await flushPresentation(tester);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(avatarWindow, findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      final retry = find.byKey(const ValueKey('home-avatar-entry-retry'));
      expect(retry, findsOneWidget);
      await tester.tap(retry);
      await flushPresentation(tester);
      expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
      await finishEntry(tester, renderer, animated: false);
      expect(renderer.visibility.last, isTrue);
      expect(
        renderer.phases.where((phase) => phase == AvatarPresencePhase.enter),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'model chosen on a pushed route restores only after Home returns',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      final selection = appServices.put(
        AvatarConfigService(
          initialCatalog: const [
            ...AvatarConfigService.builtInCatalog,
            AvatarOption(
              id: 'matt',
              name: 'Matt',
              backend: AvatarBackendKind.unity,
              modelUrl: 'unity://masso/avatar_matt',
            ),
          ],
          persistSelection: (_, _) async => true,
        ),
      );
      await selection.applyInitial();
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      final initialCommands = renderer.commands.length;

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Model store')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await selection.select('matt');
      await flushPresentation(tester);
      expect(renderer.commands, hasLength(initialCommands));

      navigator.pop();
      await tester.pump(const Duration(milliseconds: 500));
      await flushPresentation(tester);
      expect(renderer.commands, hasLength(initialCommands + 1));
      expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
      expect(renderer.visibility.last, isFalse);
      await finishEntry(tester, renderer, animated: false);
      expect(renderer.visibility.last, isTrue);
      expect(
        renderer.phases.where((phase) => phase == AvatarPresencePhase.enter),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'same Matt in a new renderer restores after Home remount even when both epochs are zero',
    (tester) async {
      lifecycle.publish(local: true);
      final firstRenderer = installRenderer();
      final selection = appServices.put(
        AvatarConfigService(
          initialCatalog: const [
            ...AvatarConfigService.builtInCatalog,
            AvatarOption(
              id: 'matt',
              name: 'Matt',
              backend: AvatarBackendKind.unity,
              modelUrl: 'unity://masso/avatar_matt',
            ),
          ],
          persistSelection: (_, _) async => true,
        ),
      );
      await selection.applyInitial();
      await selection.select('matt');
      final mattGeneration = selection.selectionDisplayGeneration.value;
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, firstRenderer);
      await unmountHome(tester);

      final nextRenderer = _EntranceRenderer(ready: true);
      appServices.find<ActiveAvatarRuntime>().register(nextRenderer);
      await selection.applyInitial();
      expect(selection.selectionDisplayGeneration.value, mattGeneration);
      expect(firstRenderer.modelLoadEpoch, 0);
      expect(nextRenderer.modelLoadEpoch, 0);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await mountHome(tester);
      await flushPresentation(tester);
      expect(nextRenderer.commands.last.phase, AvatarPresencePhase.prepare);
      expect(nextRenderer.visibility.last, isFalse);
      await finishEntry(tester, nextRenderer, animated: false);
      expect(nextRenderer.phases.last, AvatarPresencePhase.restore);
      await unmountHome(tester);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, nextRenderer, animated: false);
      expect(
        nextRenderer.phases.where(
          (phase) => phase == AvatarPresencePhase.enter,
        ),
        isEmpty,
      );
      expect(
        firstRenderer.phases.where(
          (phase) => phase == AvatarPresencePhase.enter,
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'remote confirmation during hidden entry preserves the in-flight entrance',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      await mountHome(tester);
      await flushPresentation(tester);
      final prepare = renderer.commands.single;
      lifecycle.publish(local: false, remote: _remoteHolder);
      await flushPresentation(tester);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(avatarWindow, findsOneWidget);
      expect(renderer.commands, [prepare]);
      expect(renderer.visibility.last, isFalse);
      await finishEntry(tester, renderer);
      expect(renderer.visibility.last, isTrue);
      expect(renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.enter,
      ]);
      expect(lifecycle.canExecuteAgent, isFalse);
      await unmountHome(tester);
    },
  );

  for (final replaceRenderer in [false, true]) {
    testWidgets(
      '${replaceRenderer ? 'renderer' : 'account'} replacement rejects the old entrance receipt',
      (tester) async {
        final renderer = installRenderer();
        await mountHome(tester);
        await flushPresentation(tester);
        final oldPrepare = renderer.receipts.last;
        final oldCycle = renderer.commands.last.transitionId;
        var currentRenderer = renderer;
        if (replaceRenderer) {
          currentRenderer = _EntranceRenderer(ready: true);
          appServices.find<ActiveAvatarRuntime>().register(currentRenderer);
        } else {
          lifecycle.generation++;
        }
        lifecycle.publish(local: false, remote: _remoteHolder);
        await flushPresentation(tester);
        expect(avatarWindow, findsOneWidget);
        expect(currentRenderer.visibility.last, isFalse);
        oldPrepare.complete();
        await flushPresentation(tester);
        expect(
          currentRenderer.commands.last.phase,
          AvatarPresencePhase.prepare,
        );
        expect(currentRenderer.commands.last.transitionId, isNot(oldCycle));
        expect(currentRenderer.visibility.last, isFalse);
        await finishEntry(tester, currentRenderer, animated: false);
        expect(
          currentRenderer.phases.where(
            (phase) => phase == AvatarPresencePhase.enter,
          ),
          isEmpty,
        );
        expect(currentRenderer.visibility.last, isTrue);
        expect(lifecycle.canExecuteAgent, isFalse);
        expect(tester.takeException(), isNull);
        await unmountHome(tester);
      },
    );
  }

  testWidgets(
    'retiring the account hides its local avatar before storage closes',
    (tester) async {
      final renderer = installRenderer();
      await mountHome(tester, withShell: true);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      lifecycle.publish(local: false, mounted: false);
      await flushPresentation(tester);
      expect(appServices.isRegistered<DBService>(), isTrue);
      expect(renderer.visibility.last, isFalse);
      expect(find.byType(UnityAvatarView), findsNothing);
      expect(avatarWindow, findsNothing);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'the device can switch between avatar and chat while execution changes',
    (tester) async {
      lifecycle.publish(local: false, remote: _remoteHolder);
      final renderer = installRenderer();
      final home = await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      home.inputController.text = '只改变本设备的显示方式';
      await tester.runAsync(
        () => presentation.setMode(HomePresentationMode.chat),
      );
      await flushPresentation(tester);
      expect(find.byType(UnityAvatarView), findsNothing);
      expect(
        tester.widget<HomeChatHistory>(find.byType(HomeChatHistory)).compact,
        isFalse,
      );
      lifecycle.publish(local: true);
      await flushPresentation(tester);
      expect(presentation.mode.value, HomePresentationMode.chat);
      expect(find.byType(UnityAvatarView), findsNothing);
      lifecycle.publish(local: false, remote: _remoteHolder);
      await flushPresentation(tester);
      expect(presentation.mode.value, HomePresentationMode.chat);
      expect(find.byType(UnityAvatarView), findsNothing);
      await tester.runAsync(
        () => presentation.setMode(HomePresentationMode.avatar),
      );
      await flushPresentation(tester);
      expect(avatarWindow, findsOneWidget);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(renderer.visibility.last, isTrue);
      expect(home.inputController.text, '只改变本设备的显示方式');
      expect(lifecycle.canExecuteAgent, isFalse);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets('remote executor recovery keeps the same avatar Home', (
    tester,
  ) async {
    lifecycle.publish(local: false, remote: _remoteHolder);
    final home = await mountHome(tester);
    home.inputController.text = '重新打开后的草稿';
    lifecycle.publish(local: false, recovering: true);
    await tester.pump();
    expect(avatarWindow, findsOneWidget);
    expect(find.byType(UnityAvatarView), findsOneWidget);
    expect(find.byKey(const ValueKey('home-startup-transition')), findsNothing);
    expect(home.inputController.text, '重新打开后的草稿');
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  testWidgets('saved chat preference is restored before Home and on rebuild', (
    tester,
  ) async {
    await tester.runAsync(
      () => presentation.setMode(HomePresentationMode.chat),
    );
    await mountHome(tester);
    expect(find.byKey(const ValueKey('home-startup-transition')), findsNothing);
    expect(tester.getSize(find.byType(HomeChatHistory)), const Size(393, 852));
    expect(find.byType(UnityAvatarView), findsNothing);
    expect(avatarWindow, findsNothing);
    await unmountHome(tester);

    await tester.runAsync(() async {
      await appServices.delete<HomePresentationPreferenceService>();
      await (await SharedPreferences.getInstance()).reload();
      presentation = await appServices
          .putAsync<HomePresentationPreferenceService>(
            () => HomePresentationPreferenceService().load(),
          );
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    lifecycle.publish(local: true);
    await mountHome(tester);
    expect(presentation.mode.value, HomePresentationMode.chat);
    expect(find.byKey(const ValueKey('home-startup-transition')), findsNothing);
    expect(find.byType(UnityAvatarView), findsNothing);
    expect(avatarWindow, findsNothing);
    final history = tester.widget<HomeChatHistory>(
      find.byType(HomeChatHistory),
    );
    expect(history.compact, isFalse);
    expect(history.autoHide, isFalse);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  testWidgets(
    'switching to avatar while unresolved shows the stage and keeps the draft',
    (tester) async {
      await tester.runAsync(
        () => presentation.setMode(HomePresentationMode.chat),
      );
      final home = await mountHome(tester);
      expect(find.byType(HomeChatHistory), findsOneWidget);
      home.inputController.text = '切换界面时保留的草稿';

      await tester.runAsync(
        () => presentation.setMode(HomePresentationMode.avatar),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(avatarWindow, findsOneWidget);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(avatarWindow, findsOneWidget);
      expect(home.inputController.text, '切换界面时保留的草稿');

      await tester.runAsync(
        () => presentation.setMode(HomePresentationMode.chat),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(
        tester.getSize(find.byType(HomeChatHistory)),
        const Size(393, 852),
      );
      expect(home.inputController.text, '切换界面时保留的草稿');

      await tester.runAsync(
        () => presentation.setMode(HomePresentationMode.avatar),
      );
      await tester.pump();
      lifecycle.publish(local: true);
      await tester.pump();
      expect(avatarWindow, findsOneWidget);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(home.inputController.text, '切换界面时保留的草稿');
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  test(
    'bootstrap restores the Home preference before the application mount',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final bootstrap = source.substring(
        source.indexOf('Future<void> _bootstrapApplication('),
      );
      final initialized = bootstrap.indexOf('await SpUtils.init()');
      final restored = bootstrap.indexOf(
        'await appServices.putAsync<HomePresentationPreferenceService>(',
      );
      final application = bootstrap.indexOf('runApp(');
      expect(initialized, greaterThanOrEqualTo(0));
      expect(restored, greaterThan(initialized));
      expect(
        bootstrap,
        contains('() => HomePresentationPreferenceService().load()'),
      );
      expect(application, greaterThan(restored));
    },
  );

  testWidgets(
    'native entry waits for readiness and a rendered prepare receipt',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer(ready: false);
      await mountHome(tester);
      await flushPresentation(tester);
      expectCovered(tester);
      expect(
        find.byKey(const ValueKey('home-native-scene-poster')),
        findsOneWidget,
      );
      expect(renderer.commands, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      expectCovered(tester);
      expect(renderer.commands, isEmpty);

      renderer.isReady.value = true;
      await flushPresentation(tester);
      expect(renderer.phases, [AvatarPresencePhase.prepare]);
      expectCovered(tester);
      expect(renderer.visibility.last, isFalse);
      renderer.completeLast();
      await flushPresentation(tester);
      expect(renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.enter,
      ]);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.transparent,
      );
      expect(avatarWindow, findsOneWidget);
      expect(renderer.receipts.last.isCompleted, isFalse);
      renderer.completeLast();
      await flushPresentation(tester);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  for (final adopted in [false, true]) {
    testWidgets(
      'app switcher keeps the ${adopted ? 'space-return' : 'completed entrance'} actor while its native attachment is suspended',
      (tester) async {
        lifecycle.publish(local: true);
        final _EntranceRenderer renderer;
        Future<void>? homeReturn;
        if (adopted) {
          final returning = _ReturningRenderer(presented: true);
          renderer = returning;
          final avatar = ActiveAvatarRuntime()..register(returning);
          appServices.put(avatar);
          await avatar.setLocalAvatarVisible(true);
          final room = appServices.put(
            AgentSpaceController(
              avatar: avatar,
              homeRouteIsCurrent: () => true,
              isCurrent: () => lifecycle.isMounted,
            ),
          );
          await room.enter();
          homeReturn = room.leave(animated: true, handoffToHome: true);
        } else {
          renderer = installRenderer(presented: true);
        }
        final home = await mountHome(tester);
        try {
          await flushPresentation(tester);
          if (adopted) {
            (renderer as _ReturningRenderer).homeReturn.complete();
            await homeReturn;
            await flushPresentation(tester);
            expect(renderer.commands, isEmpty);
          } else {
            await finishEntry(tester, renderer);
          }
          final commandCount = renderer.commands.length;
          final visibilityCount = renderer.visibilityRequests.length;
          home.inputController.text = '切回后继续聊';

          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          renderer.presentationReady.value = false;
          await flushPresentation(tester);
          expect(
            renderer.visibilityRequests.skip(visibilityCount),
            isNot(contains(false)),
            reason:
                'The app switcher must retain the last completed actor frame.',
          );
          expect(renderer.commands, hasLength(commandCount));

          for (final state in [
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
            tester.binding.scheduleForcedFrame();
            await flushPresentation(tester);
          }
          expect(
            renderer.visibilityRequests.skip(visibilityCount),
            isNot(contains(false)),
          );
          expect(renderer.commands, hasLength(commandCount));

          for (final state in [
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          renderer.presentationReady.value = true;
          await flushPresentation(tester);
          expect(renderer.visibility.last, isTrue);
          expect(renderer.commands, hasLength(commandCount));
          expect(home.inputController.text, '切回后继续聊');
          expect(tester.takeException(), isNull);
        } finally {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await unmountHome(tester);
        }
      },
    );
  }

  for (final interruption in [
    'secondary route',
    'Home remount',
    'background',
  ]) {
    testWidgets(
      'late cold selection interrupted by $interruption never replays its walk',
      (tester) async {
        lifecycle.publish(local: true);
        final renderer = installRenderer();
        renderer.blockedModelLoad = Completer<void>();
        final selection = appServices.put(
          AvatarConfigService(persistSelection: (_, _) async => true),
        );
        await mountHome(tester);
        await flushPresentation(tester);
        expect(renderer.commands, isEmpty);
        expect(selection.selectionDisplayGeneration.value, 0);

        // The real startup can make the persisted selection ready only after
        // Home observes its initial generation. This used to force an entrance
        // independently of the process's already-consumed launch allowance.
        renderer.blockedModelLoad!.complete();
        await selection.applyInitial();
        await flushPresentation(tester);
        expect(selection.selectionDisplayGeneration.value, 1);
        expect(renderer.phases, [AvatarPresencePhase.prepare]);
        renderer.completeLast();
        await flushPresentation(tester);
        expect(renderer.phases.last, AvatarPresencePhase.enter);
        final interruptedReceipt = renderer.receipts.last;
        final interruptedCycle = renderer.commands.last.transitionId;

        switch (interruption) {
          case 'secondary route':
            final navigator = Navigator.of(
              tester.element(find.byType(HomePage)),
            );
            unawaited(
              navigator.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Settings route')),
                ),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
            expect(find.text('Settings route'), findsOneWidget);
            interruptedReceipt.complete();
            await flushPresentation(tester);
            navigator.pop();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
          case 'Home remount':
            await unmountHome(tester);
            interruptedReceipt.complete();
            debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
            await mountHome(tester);
          case 'background':
            for (final state in [
              AppLifecycleState.inactive,
              AppLifecycleState.hidden,
              AppLifecycleState.paused,
            ]) {
              tester.binding.handleAppLifecycleStateChanged(state);
            }
            interruptedReceipt.complete();
            for (final state in [
              AppLifecycleState.hidden,
              AppLifecycleState.inactive,
              AppLifecycleState.resumed,
            ]) {
              tester.binding.handleAppLifecycleStateChanged(state);
            }
        }

        await flushPresentation(tester);
        expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
        expect(renderer.commands.last.transitionId, isNot(interruptedCycle));
        await finishEntry(tester, renderer, animated: false);
        expect(renderer.phases, [
          AvatarPresencePhase.prepare,
          AvatarPresencePhase.enter,
          interruption == 'Home remount'
              ? AvatarPresencePhase.holdHidden
              : AvatarPresencePhase.restore,
          AvatarPresencePhase.prepare,
          AvatarPresencePhase.restore,
        ]);
        expect(
          renderer.phases.where((phase) => phase == AvatarPresencePhase.enter),
          hasLength(1),
        );
        expect(renderer.visibility.last, isTrue);
        expect(find.text('home.avatar_entry_failed'.tr), findsNothing);
        expect(avatarWindow, findsOneWidget);
        expect(tester.takeException(), isNull);
        await unmountHome(tester);
      },
    );
  }

  testWidgets(
    'completed Home entry survives settings and background resume without replay',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer);
      final navigator = Navigator.of(tester.element(find.byType(HomePage)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Settings route')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Settings route'), findsOneWidget);
      expect(renderer.commands, hasLength(2));
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await flushPresentation(tester);
      expect(renderer.commands, hasLength(2));
      expect(avatarWindow, findsOneWidget);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      // Flutter stops painting while paused. Resuming the same process keeps
      // the completed presentation and cannot consume another entrance.
      expect(renderer.commands, hasLength(2));
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await flushPresentation(tester);
      expect(renderer.commands, hasLength(2));
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(avatarWindow, findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets('disposing and remounting Home shares the process entrance', (
    tester,
  ) async {
    lifecycle.publish(local: true);
    final renderer = installRenderer();
    await mountHome(tester);
    await flushPresentation(tester);
    await finishEntry(tester, renderer);
    await unmountHome(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await mountHome(tester);
    await flushPresentation(tester);
    await finishEntry(tester, renderer, animated: false);
    expect(
      renderer.phases.where((phase) => phase == AvatarPresencePhase.enter),
      hasLength(1),
    );
    expect(avatarWindow, findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  testWidgets('an entrance consumed by login does not also walk into Home', (
    tester,
  ) async {
    lifecycle.publish(local: true);
    final renderer = installRenderer();
    expect(AppLaunchPresentationSession.ensure().consumeEntrance(), isTrue);
    await mountHome(tester);
    await flushPresentation(tester);
    await finishEntry(tester, renderer, animated: false);
    expect(renderer.phases, [
      AvatarPresencePhase.prepare,
      AvatarPresencePhase.restore,
    ]);
    expect(avatarWindow, findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  test(
    'explicit login can claim a new doorway after an earlier Home entrance',
    () {
      final session = AppLaunchPresentationSession.ensure();
      expect(session.consumeEntrance(), isTrue);
      expect(session.consumeEntrance(), isFalse);
      expect(session.consumeAuthenticatedDoorway(), isTrue);
      expect(
        session.consumeEntrance(),
        isFalse,
        reason: 'The new login door must not trigger a second Home walk.',
      );
    },
  );

  testWidgets(
    'game creation intent keeps an existing draft unless replacement is chosen',
    (tester) async {
      final home = await mountHome(tester);
      home.inputController.text = '先保留这段草稿';
      final intent = HomeDraftIntent.gameCreation(
        scopeKey: AppletLocalOwnership.currentScopeKey(),
        prompt: '生成一个可以玩的小游戏',
      );
      await mountHome(tester, draftIntent: intent);
      await tester.pump(const Duration(milliseconds: 250));
      expect(home.inputController.text, '先保留这段草稿');
      await tester.tap(find.byKey(const ValueKey('game-draft-keep')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(home.inputController.text, '先保留这段草稿');
      expect(home.isThinking.value, isFalse);
      await mountHome(tester, draftIntent: intent);
      expect(home.inputController.text, '先保留这段草稿');
      expect(find.byKey(const ValueKey('game-draft-keep')), findsNothing);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets('game prompt replacement never submits a turn', (tester) async {
    final home = await mountHome(tester);
    home.inputController.text = 'old draft';
    await mountHome(
      tester,
      draftIntent: HomeDraftIntent.gameCreation(
        scopeKey: AppletLocalOwnership.currentScopeKey(),
        prompt: 'new game prompt',
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('game-draft-replace')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(home.inputController.text, 'new game prompt');
    expect(home.inputController.selection.baseOffset, 15);
    expect(home.isThinking.value, isFalse);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  testWidgets('stale game prompt dialog does not overwrite a newer draft', (
    tester,
  ) async {
    final home = await mountHome(tester);
    home.inputController.text = 'original draft';
    await mountHome(
      tester,
      draftIntent: HomeDraftIntent.gameCreation(
        scopeKey: AppletLocalOwnership.currentScopeKey(),
        prompt: 'new game prompt',
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    home.inputController.text = 'edited while pending';
    await tester.tap(find.byKey(const ValueKey('game-draft-replace')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(home.inputController.text, 'edited while pending');
    expect(home.isThinking.value, isFalse);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  testWidgets('empty game draft is prepared without a confirmation or send', (
    tester,
  ) async {
    final home = await mountHome(
      tester,
      draftIntent: HomeDraftIntent.gameCreation(
        scopeKey: AppletLocalOwnership.currentScopeKey(),
        prompt: 'new game prompt',
      ),
    );
    expect(home.inputController.text, 'new game prompt');
    expect(find.byKey(const ValueKey('game-draft-keep')), findsNothing);
    expect(home.isThinking.value, isFalse);
    await unmountHome(tester);
  });

  testWidgets('a background interruption restores without replaying entry', (
    tester,
  ) async {
    lifecycle.publish(local: true);
    final renderer = installRenderer();
    await mountHome(tester);
    await flushPresentation(tester);
    final pendingPrepare = renderer.receipts.last;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    pendingPrepare.complete();
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await flushPresentation(tester);
    await finishEntry(tester, renderer, animated: false);
    expect(renderer.phases, isNot(contains(AvatarPresencePhase.enter)));
    expect(avatarWindow, findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  for (final pendingPhase in [
    AvatarPresencePhase.prepare,
    AvatarPresencePhase.enter,
  ]) {
    testWidgets(
      'selfie takeover of pending ${pendingPhase.name} restores Home without another walk',
      (tester) async {
        lifecycle.publish(local: true);
        final renderer = installRenderer();
        final home = await mountHome(tester);
        await flushPresentation(tester);
        if (pendingPhase == AvatarPresencePhase.enter) {
          renderer.completeLast();
          await flushPresentation(tester);
        }
        expect(renderer.commands.last.phase, pendingPhase);
        final oldCycle = renderer.commands.last.transitionId;
        final oldReceipt = renderer.receipts.last;
        final commandCount = renderer.commands.length;
        home.inputController.text = '自拍回来继续写';
        final navigator = Navigator.of(tester.element(find.byType(HomePage)));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Selfie route')),
            ),
          ),
        );
        // Deliver the native scene takeover before pumping the route change:
        // Home has not rebuilt or run its post-frame cancellation yet.
        oldReceipt.completeError(
          const AvatarPresenceTransitionException('scene_takeover'),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Selfie route'), findsOneWidget);
        // Native already retired this transaction. A late restore would alter
        // the new scene, and a failed phase would prevent Home from retrying.
        expect(renderer.commands, hasLength(commandCount));
        expect(
          find.byKey(
            const ValueKey('home-avatar-entry-retry'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(
          find.text('home.avatar_entry_failed'.tr, skipOffstage: false),
          findsNothing,
        );

        navigator.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await flushPresentation(tester);
        expectCovered(tester);
        expect(renderer.commands.last.phase, AvatarPresencePhase.prepare);
        expect(renderer.commands.last.transitionId, isNot(oldCycle));
        expect(
          find.byKey(const ValueKey('home-avatar-entry-retry')),
          findsNothing,
        );
        await finishEntry(tester, renderer, animated: false);
        expect(avatarWindow, findsOneWidget);
        expect(
          find.byKey(const ValueKey('home-startup-transition')),
          findsNothing,
        );
        expect(find.text('home.avatar_entry_failed'.tr), findsNothing);
        expect(home.inputController.text, '自拍回来继续写');
        expect(tester.takeException(), isNull);
        await unmountHome(tester);
      },
    );
  }

  testWidgets('manual chat never dispatches an avatar entry even when ready', (
    tester,
  ) async {
    await tester.runAsync(
      () => presentation.setMode(HomePresentationMode.chat),
    );
    lifecycle.publish(local: true);
    final renderer = installRenderer();
    await mountHome(tester);
    await flushPresentation(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(renderer.commands, isEmpty);
    expect(find.byType(HomeChatHistory), findsOneWidget);
    expect(find.byType(UnityAvatarView), findsNothing);
    expect(find.byKey(const ValueKey('home-startup-transition')), findsNothing);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  testWidgets(
    'failed native entry stays covered until an explicit retry succeeds',
    (tester) async {
      lifecycle.publish(local: true);
      final renderer = installRenderer();
      await mountHome(tester);
      await flushPresentation(tester);
      final firstCycle = renderer.commands.first.transitionId;
      renderer.receipts.first.completeError(
        const AvatarPresenceTransitionException('transition_busy'),
      );
      await flushPresentation(tester);
      expectCovered(tester);
      expect(find.text('home.avatar_entry_failed'.tr), findsOneWidget);
      final retry = find.byKey(const ValueKey('home-avatar-entry-retry'));
      expect(retry, findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(
        renderer.phases.where((phase) => phase == AvatarPresencePhase.prepare),
        hasLength(1),
      );
      await tester.tap(retry);
      await flushPresentation(tester);
      expect(renderer.commands.last.transitionId, isNot(firstCycle));
      expectCovered(tester);
      await finishEntry(tester, renderer, animated: false);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(avatarWindow, findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets('Home entry uses reduced motion enabled after the first frame', (
    tester,
  ) async {
    lifecycle.publish(local: true);
    final renderer = installRenderer(ready: false);
    await mountHome(tester);
    await flushPresentation(tester);
    expectCovered(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await flushPresentation(tester);
    renderer.isReady.value = true;
    await flushPresentation(tester);
    expect(renderer.phases, [AvatarPresencePhase.prepare]);
    expectCovered(tester);
    renderer.completeLast();
    await flushPresentation(tester);
    expect(renderer.phases, [
      AvatarPresencePhase.prepare,
      AvatarPresencePhase.restore,
    ]);
    expect(find.byKey(const ValueKey('home-startup-transition')), findsNothing);
    expect(avatarWindow, findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });

  testWidgets(
    'reduced motion keeps the local avatar through remote executor confirmation',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final renderer = installRenderer();
      await mountHome(tester);
      await flushPresentation(tester);
      await finishEntry(tester, renderer, animated: false);
      final commands = renderer.commands.length;
      lifecycle.publish(local: false, remote: _remoteHolder);
      await flushPresentation(tester);
      expect(renderer.commands, hasLength(commands));
      expect(renderer.visibility.last, isTrue);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(avatarWindow, findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountHome(tester);
    },
  );

  testWidgets(
    'first Home frame delegates return despite an older model presentation ledger',
    (tester) async {
      try {
        lifecycle.publish(local: true);
        presentation.mode.value = HomePresentationMode.avatar;
        final renderer = _ReturningRenderer();
        final avatar = ActiveAvatarRuntime()..register(renderer);
        appServices.put(avatar);
        HomeAvatarSelectionPresentationLedger.record(
          lifecycle,
          accountGeneration: lifecycle.generation,
          modelSignature: const HomeAvatarModelPresentationSignature(
            selectionGeneration: -1,
            modelLoadEpoch: -1,
            renderer: null,
          ),
        );
        await avatar.setLocalAvatarVisible(true);
        final room = appServices.put(
          AgentSpaceController(
            avatar: avatar,
            homeRouteIsCurrent: () => true,
            isCurrent: () => lifecycle.isMounted,
          ),
        );
        await room.enter();
        final exit = room.leave(animated: true, handoffToHome: true);
        renderer.visibility.clear();
        renderer.visibilityRequests.clear();
        final home = await mountHome(tester);
        await flushPresentation(tester);
        expect(find.byKey(const ValueKey('home-menu-toggle')), findsOneWidget);
        final editor = find.byType(HomeNativeTextEditor);
        expect(editor, findsOneWidget);
        final bridge = tester.widget<HomeNativeTextEditor>(editor).bridge;
        expect(bridge.controller, same(home.inputController));
        expect(bridge.enabled, isTrue);
        expect(avatarWindow, findsOneWidget);
        expect(room.isReturningHome, isTrue);
        expect(
          renderer.commands,
          isEmpty,
          reason:
              'Startup must not prepare, enter, holdHidden, or restore over an owned return.',
        );
        expect(renderer.visibilityRequests, isEmpty);
        home.inputController.text = 'Home 输入框已经可用';
        await flushPresentation(tester);
        expect(bridge.controller.text, 'Home 输入框已经可用');
        expect(
          tester.widget<HomeNativeTextEditor>(editor).bridge,
          same(bridge),
        );
        renderer.homeReturn.complete();
        await exit;
        await flushPresentation(tester);
        expect(room.isReturningHome, isFalse);
        expect(room.consumeHomeReturnFrame(renderer), isFalse);
        expect(
          HomeAvatarSelectionPresentationLedger.lastPresented(
            lifecycle,
            lifecycle.generation,
          ),
          HomeAvatarModelPresentationSignature(
            selectionGeneration: 0,
            modelLoadEpoch: renderer.modelLoadEpoch,
            renderer: renderer,
          ),
          reason:
              'Adoption must retire the old ledger signature before another build.',
        );
        expect(renderer.commands, isEmpty);
        expect(renderer.visibilityRequests, isNot(contains(false)));
        expect(tester.takeException(), isNull);
        await unmountHome(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('desktop recovery remains full chat through local admission', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await mountHome(tester);
    expect(avatarWindow, findsNothing);
    expect(tester.getSize(find.byType(HomeChatHistory)), const Size(393, 852));
    lifecycle.publish(local: true);
    await tester.pump();
    expect(avatarWindow, findsNothing);
    expect(find.byType(UnityAvatarView), findsNothing);
    expect(tester.getSize(find.byType(HomeChatHistory)), const Size(393, 852));
    expect(tester.takeException(), isNull);
    await unmountHome(tester);
  });
}

final _remoteHolder = AccountDeviceLeaseHolder(
  installationId: 'other-installation',
  runtimeInstanceId: 'other-runtime',
  presenceSessionId: 'other-session',
  deviceLabel: 'Maaso Mac',
  platform: 'macos',
  lastSeenAt: DateTime.utc(2026, 9, 15),
);

class _UnbootedCore extends AgentCoreController {
  @override
  // Keep the real HomeController while avoiding model loads in a widget test.
  // ignore: must_call_super
  void onInit() {}
}

class _PresentationLifecycle extends AppService
    implements AccountSessionLifecycleService {
  _PresentationLifecycle(this.registry);
  final AgentRuntimeRegistry registry;
  final _listeners = <VoidCallback>[];
  @override
  bool canExecuteAgent = false;
  @override
  bool presenceRecoveryInProgress = false;
  @override
  AccountDeviceLeaseHolder? canonicalRemoteHolder;
  @override
  bool get canPresentAvatar => canExecuteAgent;
  @override
  bool get hasCompanionRuntime => true;
  @override
  bool get usesExclusiveDeviceLease => true;
  @override
  AccountRuntimeAuthorityMode get effectiveAuthorityMode =>
      AccountRuntimeAuthorityMode.enforce;
  @override
  final phase = AccountSessionLifecyclePhase.mounted.obs;
  @override
  bool get isMounted => phase.value == AccountSessionLifecyclePhase.mounted;
  @override
  bool get canChatLocally => isMounted;
  @override
  int generation = 1;

  void publish({
    required bool local,
    bool recovering = false,
    bool mounted = true,
    AccountDeviceLeaseHolder? remote,
  }) {
    phase.value = mounted
        ? AccountSessionLifecyclePhase.mounted
        : AccountSessionLifecyclePhase.retiring;
    if (local) {
      registry.activateHostedExecution();
    } else {
      unawaited(registry.suspendHostedExecution());
    }
    canExecuteAgent = local;
    presenceRecoveryInProgress = recovering;
    canonicalRemoteHolder = remote;
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

class _EntranceRenderer extends AvatarRuntime {
  _EntranceRenderer({required bool ready, bool? presented})
    : isReady = ready.obs,
      _presentationReady = presented?.obs;

  @override
  final RxBool isReady;
  final RxBool? _presentationReady;
  @override
  RxBool get presentationReady => _presentationReady ?? isReady;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  int _modelLoadEpoch = 0;
  @override
  int get modelLoadEpoch => _modelLoadEpoch;
  void resetNativeModel() => _modelLoadEpoch++;
  final commands = <AvatarPresenceTransition>[];
  final visibility = <bool>[];
  final visibilityRequests = <bool>[];
  Completer<void>? blockedHide;
  bool hideInFlight = false;
  bool deferCleanup = false;
  bool instantPresence = false;

  @override
  Future<void> setLocalAvatarVisible(bool visible) async {
    visibilityRequests.add(visible);
    if (!visible && blockedHide?.isCompleted == false) {
      hideInFlight = true;
      await blockedHide!.future;
      hideInFlight = false;
    }
    visibility.add(visible);
  }

  @override
  Future<void> loadAvatar(String url, [Map<String, dynamic>? config]) async {
    await blockedModelLoad?.future;
  }

  Completer<void>? blockedModelLoad;
  final receipts = <Completer<void>>[];
  List<AvatarPresencePhase> get phases =>
      commands.map((command) => command.phase).toList();

  @override
  Future<void> transitionPresence(AvatarPresenceTransition command) {
    commands.add(command);
    final receipt = Completer<void>();
    receipts.add(receipt);
    if (instantPresence ||
        !deferCleanup &&
            (command.phase == AvatarPresencePhase.restore ||
                command.phase == AvatarPresencePhase.holdHidden)) {
      receipt.complete();
    }
    return receipt.future;
  }

  void completeLast() => receipts.last.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReturningRenderer extends _EntranceRenderer
    implements AvatarAgentSpaceRuntime {
  _ReturningRenderer({super.presented}) : super(ready: true);

  final homeReturn = Completer<void>();

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
    if (animated) await homeReturn.future;
  }

  @override
  Future<void> moveAgentSpaceAtScreenPoint({
    required String sessionId,
    required double x,
    required double y,
  }) async {}
}

class _InstantDoorwayAvatar extends AvatarRuntime {
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  @override
  bool get supportsLoginDoorway => true;
  @override
  Future<void> transitionLoginDoorway(
    AvatarDoorwayTransition transition,
  ) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _BusyExecutionAuthority implements AccountDeviceLeaseCoordinator {
  @override
  bool get canAdmitMutations => true;
  @override
  final currentPresence = AccountDevicePresenceReceipt(
    agentId: 'self',
    installationId: 'home-installation',
    runtimeInstanceId: 'home-runtime',
    presenceSessionId: 'source-presence',
    generation: 1,
    deviceLabel: 'Local phone',
    platform: 'ios',
    appVersion: '1.0.0',
    openedAt: DateTime.utc(2026, 9, 12),
    lastSeenAt: DateTime.utc(2026, 9, 12),
    expiresAt: DateTime.utc(2026, 9, 12, 0, 1),
    remainingTtl: const Duration(minutes: 1),
    renewAfter: const Duration(seconds: 20),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected execution authority call: ${invocation.memberName}',
  );
}

class _PendingExecutionBridge implements AgentHandoffRuntimeBridge {
  final identity = Completer<HandoffAvatarIdentity>();
  @override
  bool get isAvailable => true;
  @override
  Future<HandoffAvatarIdentity> currentAvatar() => identity.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected execution bridge call: ${invocation.memberName}',
  );
}

class _UnusedExecutionGateway implements AccountDeviceHandoffGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected execution network call: ${invocation.memberName}',
  );
}
