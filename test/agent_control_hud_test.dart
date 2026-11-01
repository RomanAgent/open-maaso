import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_voice_orb.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/presentation/ui_control/agent_control_hud.dart';

void main() {
  group('AgentControlHud', () {
    late AgentUiControlCoordinator coordinator;
    late AgentUiControlStateMachine stateMachine;
    late StreamController<SpeakingStatusEvent> speakingEvents;

    setUp(() {
      stateMachine = AgentUiControlStateMachine();
      coordinator = AgentUiControlCoordinator(stateMachine: stateMachine);
      speakingEvents = StreamController<SpeakingStatusEvent>.broadcast(
        sync: true,
      );
    });

    tearDown(() async {
      await speakingEvents.close();
      await coordinator.dispose();
    });

    test('HUD has no continuous decorative ticker or edge painter', () {
      final source = File(
        'lib/src/features/agent/presentation/ui_control/agent_control_hud.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('AnimationController(')));
      expect(source, isNot(contains('CustomPaint(')));
      expect(source, isNot(contains('BoxShadow(')));
      expect(source, isNot(contains('Gradient(')));
    });

    testWidgets('static status follows control, user takeover and completion', (
      tester,
    ) async {
      await _pumpHud(
        tester,
        coordinator: coordinator,
        speakingEvents: speakingEvents.stream,
      );
      double visibleStatusOpacity() => tester
          .widget<AnimatedOpacity>(find.byKey(AgentControlHud.statusOpacityKey))
          .opacity;
      expect(visibleStatusOpacity(), 0);
      final lease = coordinator
          .begin(sessionId: 'hud', purpose: 'operate current page')
          .value!;
      await tester.pump();
      expect(visibleStatusOpacity(), 1);
      final navigatingStatus = tester
          .getSemantics(find.byKey(AgentControlHud.statusSemanticsKey))
          .value;
      expect(coordinator.pauseForUserActivity(reason: 'pointer_down'), isTrue);
      await tester.pump();
      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
      expect(visibleStatusOpacity(), 1);
      expect(
        tester
            .getSemantics(find.byKey(AgentControlHud.statusSemanticsKey))
            .value,
        isNot(navigatingStatus),
      );
      final resumedLease = coordinator.resume(lease).value!;
      expect(
        stateMachine
            .enterOperating(resumedLease, stepId: 'visible-step')
            .isSuccess,
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(coordinator.snapshot.phase, AgentUiControlPhase.operating);
      expect(visibleStatusOpacity(), 1);
      expect(tester.binding.transientCallbackCount, 0);
      coordinator.complete(resumedLease);
      await tester.pumpAndSettle();
      expect(visibleStatusOpacity(), 0);
    });

    testWidgets('only the bottom-left orb intercepts pointer input', (
      tester,
    ) async {
      var pageTaps = 0;
      var orbTaps = 0;
      await _pumpHud(
        tester,
        coordinator: coordinator,
        speakingEvents: speakingEvents.stream,
        onOrbTap: () => orbTaps += 1,
        underlay: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => pageTaps += 1,
          child: const SizedBox.expand(),
        ),
      );

      await tester.tapAt(const Offset(400, 300));
      expect(pageTaps, 1);
      expect(orbTaps, 0);

      final orbRect = tester.getRect(
        find.byKey(AgentControlHud.orbTapTargetKey),
      );
      expect(orbRect.left, lessThan(40));
      expect(orbRect.bottom, greaterThan(540));
      await tester.tap(find.byKey(AgentControlHud.orbTapTargetKey));
      expect(pageTaps, 1);
      expect(orbTaps, 1);

      final semantics = tester.getSemantics(
        find.byKey(AgentControlHud.orbSemanticsKey),
      );
      expect(semantics.label, 'Agent voice control');
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(semantics.flagsCollection.isLiveRegion, isTrue);
    });

    testWidgets(
      'shows a pass-through live status for the active visible step',
      (tester) async {
        var pageTaps = 0;
        await _pumpHud(
          tester,
          coordinator: coordinator,
          speakingEvents: speakingEvents.stream,
          underlay: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => pageTaps += 1,
            child: const SizedBox.expand(),
          ),
        );

        final lease = coordinator
            .begin(sessionId: 'status', purpose: 'prepare post')
            .value!;
        expect(
          stateMachine
              .enterOperating(
                lease,
                stepId: 'app_control.community.compose_post',
              )
              .isSuccess,
          isTrue,
        );
        await tester.pump();

        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(AgentControlHud.statusOpacityKey),
              )
              .opacity,
          1,
        );
        expect(find.text('Preparing the community draft'), findsOneWidget);
        final semantics = tester.getSemantics(
          find.byKey(AgentControlHud.statusSemanticsKey),
        );
        expect(semantics.label, 'Agent is controlling the app');
        expect(semantics.value, 'Preparing the community draft');
        expect(semantics.flagsCollection.isLiveRegion, isTrue);
        expect(
          tester
              .widget<IgnorePointer>(
                find.byKey(AgentControlHud.statusIgnorePointerKey),
              )
              .ignoring,
          isTrue,
        );

        final statusRect = tester.getRect(
          find.byKey(AgentControlHud.statusChipKey),
        );
        await tester.tapAt(statusRect.center);
        expect(pageTaps, 1);
      },
    );

    testWidgets('speaking events select a static orb phase without a ticker', (
      tester,
    ) async {
      await _pumpHud(
        tester,
        coordinator: coordinator,
        speakingEvents: speakingEvents.stream,
        agentId: 'agent-a',
      );
      expect(_voiceOrb(tester).phase, VoiceOrbPhase.listening);

      speakingEvents.add(SpeakingStatusEvent(true, agentId: 'agent-b'));
      await tester.pump();
      expect(_voiceOrb(tester).phase, VoiceOrbPhase.listening);

      speakingEvents.add(SpeakingStatusEvent(true, agentId: 'agent-a'));
      await tester.pump();
      expect(_voiceOrb(tester).phase, VoiceOrbPhase.speaking);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);

      speakingEvents.add(SpeakingStatusEvent(false, agentId: 'agent-a'));
      await tester.pump();
      expect(_voiceOrb(tester).phase, VoiceOrbPhase.listening);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('hidden orb keeps speaking state for a later opt-in', (
      tester,
    ) async {
      final events = speakingEvents.stream;
      await _pumpHud(
        tester,
        coordinator: coordinator,
        speakingEvents: events,
        agentId: 'agent-a',
        showOrb: false,
      );
      expect(find.byType(AppGlassVoiceOrb), findsNothing);

      speakingEvents.add(SpeakingStatusEvent(true, agentId: 'agent-a'));
      await tester.pump();
      await _pumpHud(
        tester,
        coordinator: coordinator,
        speakingEvents: events,
        agentId: 'agent-a',
      );

      expect(_voiceOrb(tester).phase, VoiceOrbPhase.speaking);
    });

    testWidgets(
      'reduced motion keeps static speaking state and immediate status',
      (tester) async {
        await _pumpHud(
          tester,
          coordinator: coordinator,
          speakingEvents: speakingEvents.stream,
          disableAnimations: true,
        );
        coordinator.begin(sessionId: 'reduced', purpose: 'navigate');
        speakingEvents.add(SpeakingStatusEvent(true));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));

        expect(find.byType(BackdropFilter), findsNothing);
        expect(_voiceOrb(tester).reducedMotion, isTrue);
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(AgentControlHud.statusOpacityKey),
              )
              .duration,
          Duration.zero,
        );
      },
    );

    testWidgets('status chip fits compact portrait and landscape at 2x text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpHud(
        tester,
        coordinator: coordinator,
        speakingEvents: speakingEvents.stream,
        size: const Size(320, 568),
        textScale: 2,
      );
      final lease = coordinator
          .begin(sessionId: 'large-text', purpose: 'prepare post')
          .value!;
      stateMachine.enterOperating(
        lease,
        stepId: 'app_control.community.type_and_publish',
      );
      await tester.pump();

      final rect = tester.getRect(find.byKey(AgentControlHud.statusChipKey));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(568, 320);
      await _pumpHud(
        tester,
        coordinator: coordinator,
        speakingEvents: speakingEvents.stream,
        size: const Size(568, 320),
        textScale: 2,
      );
      final landscapeRect = tester.getRect(
        find.byKey(AgentControlHud.statusChipKey),
      );
      expect(landscapeRect.left, greaterThanOrEqualTo(0));
      expect(landscapeRect.right, lessThanOrEqualTo(568));
      expect(landscapeRect.bottom, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _pumpHud(
  WidgetTester tester, {
  required AgentUiControlCoordinator coordinator,
  required Stream<SpeakingStatusEvent> speakingEvents,
  String? agentId,
  VoidCallback? onOrbTap,
  Widget underlay = const SizedBox.expand(),
  bool disableAnimations = false,
  bool showOrb = true,
  Size size = const Size(800, 600),
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              underlay,
              AgentControlHud(
                coordinator: coordinator,
                speakingEvents: speakingEvents,
                agentId: agentId,
                onOrbTap: onOrbTap,
                showOrb: showOrb,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

AppGlassVoiceOrb _voiceOrb(WidgetTester tester) =>
    tester.widget<AppGlassVoiceOrb>(find.byType(AppGlassVoiceOrb));
