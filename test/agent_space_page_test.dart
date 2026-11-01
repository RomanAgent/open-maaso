import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/avatar_viewport_policy.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_agent_space.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';
import 'package:maaso/src/features/agent_space/presentation/agent_space_page.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
  });
  tearDown(appServices.reset);

  testWidgets('the active personal room has only one exit control', (
    tester,
  ) async {
    final controller = _RecordingController(AgentSpacePhase.active);
    await _mount(tester, controller);

    final view = tester.widget<UnityAvatarView>(find.byType(UnityAvatarView));
    expect(view.includeWorld, isTrue);
    expect(view.holdToWalk, isTrue);
    expect(view.viewportSafeArea, isNull);
    expect(view.viewportActive, isTrue);
    expect(find.byType(AppGlassIconButton), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-space-exit')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('agent-space-status')), findsNothing);
    expect(find.byIcon(Icons.map_outlined), findsNothing);
    expect(find.byIcon(Icons.tune_rounded), findsNothing);
    expect(tester.getSize(find.byType(AppGlassIconButton)), const Size(48, 48));
  });

  testWidgets('entry mounts the host first and preserves Home framing', (
    tester,
  ) async {
    final controller = _RecordingController(AgentSpacePhase.entering);
    await _mount(tester, controller, autoEnter: true);
    expect(controller.entries, 1);
    final view = tester.widget<UnityAvatarView>(find.byType(UnityAvatarView));
    expect(view.viewportSafeArea, isNull);
    expect(view.viewportActive, isTrue);
    expect(view.showLoadingPlaceholder, isFalse);
    expect(
      find.byKey(const ValueKey('agent-space-entry-bubble')),
      findsNothing,
    );
    expect(find.byType(MessageFrostSurface), findsNothing);
    expect(find.text('准备自由活动啦。'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.view_in_ar_rounded), findsNothing);
    expect(find.byKey(const ValueKey('agent-space-status')), findsNothing);
    expect(find.byKey(const ValueKey('agent-space-retry')), findsNothing);

    await tester.tapAt(tester.getCenter(find.byType(UnityAvatarView)));
    await tester.pump();
    expect(controller.taps, isEmpty);

    controller.state.value = const AgentSpaceState(AgentSpacePhase.active);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('agent-space-entry-bubble')),
      findsNothing,
    );
    await tester.tapAt(const Offset(80, 140));
    await tester.pump();
    expect(controller.taps, hasLength(1));
  });

  testWidgets('Mac room entry stays silent while capture waits', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final controller = _RecordingController(AgentSpacePhase.entering);
      await _mount(tester, controller, autoEnter: true);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('agent-space-entry-bubble')),
        findsNothing,
      );
      expect(find.text('准备自由活动啦。'), findsNothing);
      // Inspect the real Mac portal fallback descendants, not just the page cue.
      expect(find.byIcon(Icons.view_in_ar_rounded), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const ValueKey('agent-space-status')), findsNothing);
      controller.state.value = const AgentSpaceState(AgentSpacePhase.failure);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('agent-space-entry-bubble')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('agent-space-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-space-retry')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-space-exit')), findsOneWidget);
      expect(find.byIcon(Icons.view_in_ar_rounded), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('silent entry can exit before a late success', (tester) async {
    final controller = _RecordingController(AgentSpacePhase.entering);
    await _mount(tester, controller);
    final cue = find.byKey(const ValueKey('agent-space-entry-bubble'));
    expect(cue, findsNothing);
    await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
    await tester.pumpAndSettle();
    expect(appNavigation.currentRoute, AppRouteCatalog.home);
    expect(cue, findsNothing);
    controller.state.value = const AgentSpaceState(AgentSpacePhase.active);
    await tester.pump();
    expect(cue, findsNothing);
    expect(find.text('准备自由活动啦。'), findsNothing);
  });

  for (final chinese in [true, false]) {
    for (final size in [const Size(320, 568), const Size(640, 320)]) {
      testWidgets(
        'silent entry keeps exit accessible at $size with large text, zh=$chinese',
        (tester) async {
          AppLocalization.updateLocale(
            chinese ? const Locale('zh', 'CN') : const Locale('en', 'US'),
          );
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          final controller = _RecordingController(AgentSpacePhase.entering);
          await _mount(tester, controller, textScale: 2);
          expect(
            find.text(chinese ? '准备自由活动啦。' : 'Getting ready to roam around.'),
            findsNothing,
          );
          expect(find.byType(MessageFrostSurface), findsNothing);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          expect(find.byType(AppGlassIconButton), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            find.byKey(const ValueKey('agent-space-exit')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
          await tester.pumpAndSettle();
          expect(appNavigation.currentRoute, AppRouteCatalog.home);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('exit shows Home before the native return receipt completes', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final controller = _RecordingController(
      AgentSpacePhase.active,
      leaveGate: gate,
    );
    final router = await _mount(
      tester,
      controller,
      initialLocation: '/another-page',
    );
    unawaited(router.push<void>(AppRouteCatalog.agentSpace));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
    await tester.pumpAndSettle();
    expect(appNavigation.currentRoute, AppRouteCatalog.home);
    expect(find.byKey(const ValueKey('agent-space-home')), findsOneWidget);
    expect(find.byType(AgentSpacePage), findsNothing);
    expect(controller.leaves, 1);
    expect(gate.isCompleted, isFalse);
    await tester.tapAt(const Offset(80, 140));
    await tester.pump();
    expect(controller.taps, isEmpty);
    gate.complete();
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRouteCatalog.home,
    );
    expect(find.byKey(const ValueKey('agent-space-home')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-space-previous')), findsNothing);
  });

  testWidgets('system back also returns Home and fences room activity', (
    tester,
  ) async {
    final controller = _RecordingController(AgentSpacePhase.active);
    final router = await _mount(tester, controller);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRouteCatalog.home,
    );
    expect(controller.leaves, 1);
    expect(controller.activities.last.currentPage, isFalse);
    expect(controller.activities.last.resumed, isTrue);
  });

  testWidgets('a late exit cannot overwrite an externally selected route', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final controller = _RecordingController(
      AgentSpacePhase.active,
      leaveGate: gate,
    );
    final router = await _mount(tester, controller);
    await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
    await tester.pump();
    router.go('/another-page');
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/another-page');
    expect(find.byKey(const ValueKey('agent-space-previous')), findsOneWidget);
  });

  testWidgets('a retired account exit cannot navigate its replacement', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final controller = _RecordingController(
      AgentSpacePhase.active,
      leaveGate: gate,
    );
    final router = await _mount(tester, controller);
    await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
    await tester.pump();
    expect(appNavigation.currentRoute, AppRouteCatalog.home);
    controller.isCurrentPresentation = false;
    router.go('/another-page');
    gate.complete();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/another-page');
    expect(controller.leaves, 1);
  });

  testWidgets(
    'a late native failure cannot leave again or replace a newer route',
    (tester) async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final controller = _RecordingController(
        AgentSpacePhase.active,
        leaveGate: gate,
      );
      final router = await _mount(tester, controller, disableAnimations: false);
      await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
      await tester.pumpAndSettle();
      expect(appNavigation.currentRoute, AppRouteCatalog.home);
      expect(controller.exitAnimations, [true]);
      router.go('/another-page');
      await tester.pumpAndSettle();
      controller.isCurrentPresentation = false;
      gate.completeError(StateError('late old renderer failure'));
      await tester.pumpAndSettle();
      expect(appNavigation.currentRoute, '/another-page');
      expect(controller.leaves, 1);
      expect(
        find.byKey(const ValueKey('agent-space-previous')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an account retired before the tap cannot issue exit or navigation',
    (tester) async {
      final controller = _RecordingController(AgentSpacePhase.active);
      await _mount(tester, controller);
      // Keep the already-built button callback, just as an account transition
      // can retire the controller before the next Flutter rebuild.
      controller.isCurrentPresentation = false;
      await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
      await tester.pump();
      expect(controller.leaves, 0);
      expect(appNavigation.currentRoute, AppRouteCatalog.agentSpace);
    },
  );

  testWidgets(
    'covering Home during native return never revives the old room page',
    (tester) async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final controller = _RecordingController(
        AgentSpacePhase.active,
        leaveGate: gate,
        activateOnEnter: true,
      );
      await _mount(tester, controller, autoEnter: true);
      await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
      await tester.pumpAndSettle();
      final navigator = Navigator.of(
        tester.element(find.byKey(const ValueKey('agent-space-home'))),
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covering page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Covering page'), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(controller.entries, 1);
      expect(find.byKey(const ValueKey('agent-space-exit')), findsNothing);
      expect(appNavigation.currentRoute, AppRouteCatalog.home);
    },
  );

  testWidgets(
    'exit failure is observed without a second unscoped native leave',
    (tester) async {
      final controller = _RecordingController(AgentSpacePhase.active)
        ..leaveFailure = StateError('renderer stopped');
      final router = await _mount(tester, controller, disableAnimations: false);
      await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        AppRouteCatalog.home,
      );
      expect(controller.exitAnimations, [true]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real room controller transfers its pending return to Home immediately',
    (tester) async {
      final renderer = _DelayedRoomRenderer();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      final controller = AgentSpaceController(avatar: avatar);
      await _mount(
        tester,
        controller,
        autoEnter: true,
        disableAnimations: false,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(controller.state.value.phase, AgentSpacePhase.entering);
      expect(renderer.entries.single.animated, isTrue);
      expect(renderer.entries.single.viewport, isNull);
      renderer.entryReceipt.complete();
      await tester.pumpAndSettle();
      expect(controller.state.value.phase, AgentSpacePhase.active);
      expect(avatar.localAvatarVisible, isTrue);
      await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
      await tester.pumpAndSettle();
      expect(controller.state.value.phase, AgentSpacePhase.leaving);
      expect(appNavigation.currentRoute, AppRouteCatalog.home);
      expect(find.byType(AgentSpacePage), findsNothing);
      expect(controller.isReturningHome, isTrue);
      expect(renderer.exits.single.animated, isTrue);
      expect(renderer.exits.single.viewport, isNotNull);
      expect(avatar.localAvatarVisible, isTrue);
      renderer.exitReceipt.complete();
      await tester.pumpAndSettle();
      expect(appNavigation.currentRoute, AppRouteCatalog.home);
      expect(avatar.localAvatarVisible, isTrue);
      expect(controller.isReturningHome, isFalse);
      expect(renderer.viewportWrites, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.onClose();
    },
  );

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'entry follows reduced motion and exit is immediate: $reduceMotion',
      (tester) async {
        final controller = _RecordingController(AgentSpacePhase.active);
        await _mount(
          tester,
          controller,
          autoEnter: true,
          disableAnimations: reduceMotion,
        );
        expect(controller.entryAnimations, [!reduceMotion]);
        expect(controller.entryViewports, [null]);
        final view = tester.widget<UnityAvatarView>(
          find.byType(UnityAvatarView),
        );
        expect(view.viewportSafeArea, isNull);
        await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
        await tester.pumpAndSettle();
        expect(controller.exitAnimations, [!reduceMotion]);
        expect(controller.exitHandoffs, [true]);
        expect(controller.homeViewport, isNotNull);
      },
    );
  }

  testWidgets('exit restores the keyboard-free Home viewport', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.padding = const FakeViewPadding(top: 47);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    final controller = _RecordingController(AgentSpacePhase.active);
    await _mount(tester, controller);
    expect(tester.getSize(find.byType(UnityAvatarView)), const Size(390, 844));

    await tester.tap(find.byKey(const ValueKey('agent-space-exit')));
    await tester.pumpAndSettle();
    expect(
      controller.homeViewport,
      MaasoAvatarViewportPolicy.safeAreaFor(
        size: const Size(390, 844),
        padding: const EdgeInsets.only(top: 47, bottom: 34),
        viewInsets: EdgeInsets.zero,
      ),
    );
  });

  testWidgets('covered and background room hosts cannot handle input', (
    tester,
  ) async {
    final controller = _RecordingController(AgentSpacePhase.active);
    await _mount(tester, controller);
    final navigator = Navigator.of(tester.element(find.byType(AgentSpacePage)));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    final view = find.descendant(
      of: find.byType(AgentSpacePage, skipOffstage: false),
      matching: find.byType(UnityAvatarView, skipOffstage: false),
      skipOffstage: false,
    );
    expect(tester.widget<UnityAvatarView>(view).viewportActive, isFalse);
    expect(controller.activities.last.currentPage, isFalse);
    navigator.pop();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(controller.activities.last.resumed, isFalse);
    // A paused app does not draw another frame. The native view's lifecycle
    // input fence must still reject input before a resumed frame is built.
    await tester.tapAt(const Offset(40, 80));
    await tester.pump();
    expect(controller.taps, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('page registration is removed when the room is disposed', (
    tester,
  ) async {
    final uiControl = appServices.put(AgentUiControlService());
    final controller = _RecordingController(AgentSpacePhase.active);
    final router = await _mount(tester, controller);
    expect(uiControl.adapters.length, 1);
    router.go(AppRouteCatalog.home);
    await tester.pumpAndSettle();
    expect(uiControl.adapters.length, 0);
    expect(controller.activities.last.currentPage, isFalse);
  });

  testWidgets('returning to a covered space re-enters after native cleanup', (
    tester,
  ) async {
    final controller = _RecordingController(
      AgentSpacePhase.active,
      activateOnEnter: true,
    );
    await _mount(tester, controller, autoEnter: true);
    expect(controller.entries, 1);
    final navigator = Navigator.of(tester.element(find.byType(AgentSpacePage)));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    controller.state.value = const AgentSpaceState(AgentSpacePhase.initial);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(controller.entries, 2);
    expect(controller.activities.last.currentPage, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(controller.entries, 3);
  });

  testWidgets('failure keeps exit available and retry bound to this space', (
    tester,
  ) async {
    final controller = _RecordingController(AgentSpacePhase.failure);
    controller.state.value = const AgentSpaceState(
      AgentSpacePhase.failure,
      message: 'Avatar connection failed',
    );
    await _mount(tester, controller);
    expect(find.text('Avatar connection failed'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-space-entry-bubble')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('agent-space-exit')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-space-retry')));
    await tester.pump();
    expect(controller.entries, 1);
  });

  for (final size in [const Size(320, 568), const Size(640, 320)]) {
    testWidgets('exit and failure status fit $size with large text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final controller = _RecordingController(AgentSpacePhase.failure);
      await _mount(tester, controller, textScale: 2);
      expect(tester.takeException(), isNull);
      final exit = tester.getRect(
        find.byKey(const ValueKey('agent-space-exit')),
      );
      expect(exit.right, lessThanOrEqualTo(size.width));
      expect(exit.top, greaterThanOrEqualTo(0));
      expect(exit.size, const Size(48, 48));
    });
  }
}

Future<GoRouter> _mount(
  WidgetTester tester,
  AgentSpaceController controller, {
  bool autoEnter = false,
  String initialLocation = AppRouteCatalog.agentSpace,
  double textScale = 1,
  bool disableAnimations = true,
}) async {
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: AppRouteCatalog.home,
        builder: (_, _) => const Scaffold(key: ValueKey('agent-space-home')),
      ),
      GoRoute(
        path: '/another-page',
        builder: (_, _) =>
            const Scaffold(key: ValueKey('agent-space-previous')),
      ),
      GoRoute(
        path: AppRouteCatalog.agentSpace,
        builder: (_, _) =>
            AgentSpacePage(controller: controller, autoEnter: autoEnter),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  appNavigation.configure(router);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
    ),
  );
  await tester.pump();
  return router;
}

class _DelayedRoomRenderer extends AvatarRuntime
    implements AvatarAgentSpaceRuntime {
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  final entryReceipt = Completer<void>();
  final exitReceipt = Completer<void>();
  final entries = <({bool animated, AvatarViewportSafeArea? viewport})>[];
  final exits = <({bool animated, AvatarViewportSafeArea? viewport})>[];
  final visibility = <bool>[];
  final viewportWrites = <AvatarViewportSafeArea>[];

  @override
  Future<void> prepareRenderer() async {}
  @override
  Future<void> setLocalAvatarVisible(bool visible) async =>
      visibility.add(visible);
  @override
  Future<void> enterAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {
    entries.add((animated: animated, viewport: targetViewportSafeArea));
    await entryReceipt.future;
  }

  @override
  Future<void> leaveAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {
    exits.add((animated: animated, viewport: targetViewportSafeArea));
    await exitReceipt.future;
  }

  @override
  Future<void> moveAgentSpaceAtScreenPoint({
    required String sessionId,
    required double x,
    required double y,
  }) async {}
  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async =>
      viewportWrites.add(safeArea);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingController implements AgentSpaceController {
  _RecordingController(
    AgentSpacePhase phase, {
    this.leaveGate,
    this.activateOnEnter = false,
  }) : state = ValueNotifier(AgentSpaceState(phase));

  @override
  final ValueNotifier<AgentSpaceState> state;
  final Completer<void>? leaveGate;
  final bool activateOnEnter;
  int entries = 0;
  int leaves = 0;
  @override
  bool isCurrentPresentation = true;
  Object? leaveFailure;
  final entryAnimations = <bool>[];
  final exitAnimations = <bool>[];
  final exitHandoffs = <bool>[];
  final entryViewports = <AvatarViewportSafeArea?>[];
  AvatarViewportSafeArea? homeViewport;
  final taps = <Offset>[];
  final activities = <({bool resumed, bool currentPage, Object source})>[];

  @override
  Future<void> enter({
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {
    entries++;
    entryAnimations.add(animated);
    entryViewports.add(targetViewportSafeArea);
    if (activateOnEnter) {
      state.value = const AgentSpaceState(AgentSpacePhase.active);
    }
  }

  @override
  Future<void> leave({
    bool animated = false,
    bool handoffToHome = false,
    AvatarViewportSafeArea? homeViewportSafeArea,
  }) async {
    leaves++;
    exitAnimations.add(animated);
    exitHandoffs.add(handoffToHome);
    homeViewport = homeViewportSafeArea;
    await leaveGate?.future;
    if (leaveFailure case final Object failure) throw failure;
  }

  @override
  Future<void> handleScreenTap(double normalizedX, double normalizedY) async {
    taps.add(Offset(normalizedX, normalizedY));
  }

  @override
  void setActivity({
    required bool resumed,
    required bool currentPage,
    required Object source,
  }) => activities.add((
    resumed: resumed,
    currentPage: currentPage,
    source: source,
  ));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
