import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/presentation/ui_control/agent_control_hud.dart';

void main() {
  group('AppAgentShell', () {
    late AgentUiControlCoordinator coordinator;

    setUp(() {
      coordinator = AgentUiControlCoordinator();
    });

    tearDown(() async {
      await coordinator.dispose();
    });

    testWidgets('pointer down pauses UI control without consuming page taps', (
      tester,
    ) async {
      var pageTaps = 0;
      await _pumpShell(
        tester,
        coordinator: coordinator,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => pageTaps += 1,
          child: const SizedBox.expand(),
        ),
      );
      coordinator.begin(sessionId: 'tap', purpose: 'navigate and operate');

      await tester.tapAt(const Offset(400, 300));

      expect(pageTaps, 1);
      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
      expect(coordinator.snapshot.pauseReason, 'pointer_down');
    });

    testWidgets('pointer listener does not consume page drag gestures', (
      tester,
    ) async {
      var panUpdates = 0;
      await _pumpShell(
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
    });

    testWidgets('idle pointer activity is a no-op', (tester) async {
      await _pumpShell(tester, coordinator: coordinator);

      await tester.tapAt(const Offset(400, 300));

      expect(coordinator.snapshot.phase, AgentUiControlPhase.idle);
    });

    testWidgets(
      'global shell hides the orb by default while keeping status feedback',
      (tester) async {
        await _pumpShell(tester, coordinator: coordinator);

        expect(find.byKey(AppAgentShell.pointerListenerKey), findsOneWidget);
        expect(find.byKey(AgentControlHud.hudKey), findsOneWidget);
        expect(
          tester
              .widget<IgnorePointer>(
                find.byKey(AgentControlHud.statusIgnorePointerKey),
              )
              .ignoring,
          isTrue,
        );
        expect(find.byKey(AgentControlHud.orbTapTargetKey), findsNothing);
      },
    );

    testWidgets('programmatic UI steps do not trigger user takeover', (
      tester,
    ) async {
      await _pumpShell(tester, coordinator: coordinator);
      final lease = coordinator
          .begin(sessionId: 'programmatic', purpose: 'operate current page')
          .value!;

      final result = await tester.runAsync(
        () => coordinator.runStep<int>(
          lease: lease,
          stepId: 'programmatic-step',
          command: (context) async => 7,
        ),
      );

      expect(result!.isSuccess, isTrue);
      expect(result.value, 7);
      expect(coordinator.snapshot.phase, AgentUiControlPhase.operating);
      expect(coordinator.snapshot.pauseReason, isNull);
    });

    testWidgets('orb pointer pauses before the orb callback runs', (
      tester,
    ) async {
      final callbackPhases = <AgentUiControlPhase>[];
      await _pumpShell(
        tester,
        coordinator: coordinator,
        onOrbTap: () => callbackPhases.add(coordinator.snapshot.phase),
        showOrb: true,
      );
      coordinator.begin(sessionId: 'orb', purpose: 'navigate to another page');

      await tester.tap(find.byKey(AgentControlHud.orbTapTargetKey));

      expect(callbackPhases, <AgentUiControlPhase>[
        AgentUiControlPhase.pausedByUser,
      ]);
      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
    });

    testWidgets(
      'route changes in an idle buildScope defer the parent rebuild',
      (tester) async {
        final route = ValueNotifier<String>('/home');
        addTearDown(route.dispose);
        final key = GlobalKey();
        var change = false;
        await _pumpShell(
          tester,
          coordinator: coordinator,
          routeListenable: route,
          currentRoute: () => route.value,
          child: Builder(
            key: key,
            builder: (_) {
              if (change) {
                change = false;
                route.value = '/settings';
              }
              return const SizedBox.expand();
            },
          ),
        );
        change = true;
        final element = key.currentContext! as Element;
        element.markNeedsBuild();
        tester.binding.buildOwner!.buildScope(element);
        expect(tester.takeException(), isNull);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(route.value, '/settings');
      },
    );

    testWidgets('route notifications during build rebuild after the frame', (
      tester,
    ) async {
      final route = ValueNotifier<String>('/home');
      addTearDown(route.dispose);
      var changedDuringBuild = false;

      await _pumpShell(
        tester,
        coordinator: coordinator,
        routeListenable: route,
        currentRoute: () => route.value,
        child: Builder(
          builder: (_) {
            if (!changedDuringBuild) {
              changedDuringBuild = true;
              route.value = '/settings';
            }
            return const SizedBox.expand();
          },
        ),
      );

      expect(tester.takeException(), isNull);
      expect(changedDuringBuild, isTrue);
    });
  });
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required AgentUiControlCoordinator coordinator,
  Widget child = const SizedBox.expand(),
  VoidCallback? onOrbTap,
  bool? showOrb,
  Listenable? routeListenable,
  String Function()? currentRoute,
}) async {
  final shell = showOrb == null
      ? AppAgentShell(
          coordinator: coordinator,
          onOrbTap: onOrbTap,
          routeListenable: routeListenable,
          currentRoute: currentRoute,
          child: child,
        )
      : AppAgentShell(
          coordinator: coordinator,
          onOrbTap: onOrbTap,
          showOrb: showOrb,
          routeListenable: routeListenable,
          currentRoute: currentRoute,
          child: child,
        );
  await tester.pumpWidget(MaterialApp(home: shell));
  await tester.pump();
}
