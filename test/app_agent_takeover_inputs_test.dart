import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';

void main() {
  group('AppAgentShell takeover inputs', () {
    late AgentUiControlCoordinator coordinator;

    setUp(() {
      coordinator = AgentUiControlCoordinator();
      appAgentTakeoverBackButtonDispatcher.bind(coordinator);
    });

    tearDown(() async {
      appAgentTakeoverBackButtonDispatcher.bind(null);
      await coordinator.dispose();
    });

    testWidgets('expected agent target route does not pause its own lease', (
      tester,
    ) async {
      final route = ValueNotifier<String>('/home');
      addTearDown(route.dispose);
      await _pumpObservedShell(tester, coordinator: coordinator, route: route);
      coordinator.begin(
        sessionId: 'expected-route',
        purpose: 'open selfie preparation',
        targetRoute: '/selfie?source=agent',
      );

      route.value = '/selfie?source=agent#director';
      await tester.pump();

      expect(coordinator.snapshot.phase, AgentUiControlPhase.navigating);
      expect(coordinator.snapshot.pauseReason, isNull);
    });

    testWidgets('unexpected route change pauses an active agent lease', (
      tester,
    ) async {
      final route = ValueNotifier<String>('/selfie?source=agent');
      addTearDown(route.dispose);
      await _pumpObservedShell(tester, coordinator: coordinator, route: route);
      coordinator.begin(
        sessionId: 'manual-route',
        purpose: 'prepare selfie form',
        targetRoute: '/selfie?source=agent',
      );

      route.value = '/settings';
      await tester.pump();

      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
      expect(coordinator.snapshot.pauseReason, 'unexpected_route_change');
    });

    testWidgets('hardware key pauses control without consuming the key', (
      tester,
    ) async {
      var pageKeyDowns = 0;
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await _pumpObservedShell(
        tester,
        coordinator: coordinator,
        child: Focus(
          focusNode: focusNode,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent) pageKeyDowns += 1;
            return KeyEventResult.handled;
          },
          child: const SizedBox.expand(),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      coordinator.begin(sessionId: 'keyboard', purpose: 'fill visible form');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);

      expect(pageKeyDowns, 1);
      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
      expect(coordinator.snapshot.pauseReason, 'keyboard_input');
    });

    testWidgets('system back pauses control and still pops the route', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/home',
        routes: <RouteBase>[
          GoRoute(path: '/home', builder: (_, _) => const Text('Home')),
          GoRoute(path: '/selfie', builder: (_, _) => const Text('Selfie')),
        ],
      );
      addTearDown(router.dispose);
      String currentRoute() =>
          router.routerDelegate.currentConfiguration.uri.toString();
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: appAgentTakeoverRouterConfig(router),
          builder: (context, child) => AppAgentShell(
            coordinator: coordinator,
            routeListenable: router.routerDelegate,
            currentRoute: currentRoute,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      unawaited(router.push<void>('/selfie?source=agent'));
      await tester.pumpAndSettle();
      coordinator.begin(
        sessionId: 'system-back',
        purpose: 'prepare selfie form',
        targetRoute: '/selfie?source=agent',
      );

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(handled, isTrue);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
      expect(coordinator.snapshot.pauseReason, 'system_back');
    });

    testWidgets('backgrounding pauses an active lease', (tester) async {
      await _pumpObservedShell(tester, coordinator: coordinator);
      coordinator.begin(
        sessionId: 'background',
        purpose: 'operate current page',
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
      expect(coordinator.snapshot.pauseReason, 'app_background');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('takeover inputs are no-ops while control is idle', (
      tester,
    ) async {
      final route = ValueNotifier<String>('/home');
      addTearDown(route.dispose);
      await _pumpObservedShell(tester, coordinator: coordinator, route: route);

      route.value = '/settings';
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      expect(coordinator.snapshot.phase, AgentUiControlPhase.idle);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('global takeover observers preserve page drag gestures', (
      tester,
    ) async {
      var panUpdates = 0;
      await _pumpObservedShell(
        tester,
        coordinator: coordinator,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (_) => panUpdates += 1,
          child: const SizedBox.expand(),
        ),
      );
      coordinator.begin(sessionId: 'drag', purpose: 'operate current page');

      await tester.dragFrom(const Offset(400, 300), const Offset(0, -120));

      expect(panUpdates, greaterThan(0));
      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
      expect(coordinator.snapshot.pauseReason, 'pointer_down');
    });
  });
}

Future<void> _pumpObservedShell(
  WidgetTester tester, {
  required AgentUiControlCoordinator coordinator,
  ValueNotifier<String>? route,
  Widget child = const SizedBox.expand(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AppAgentShell(
        coordinator: coordinator,
        routeListenable: route,
        currentRoute: route == null ? null : () => route.value,
        child: child,
      ),
    ),
  );
  await tester.pump();
}
