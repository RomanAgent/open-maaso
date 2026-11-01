import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_camera_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _cameraTest('speech holds a bust shot until 45 seconds after it ends', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    expect(h.avatar.shots, ['hero_full_body']);
    await h.speech(true);
    expect(h.avatar.shots.last, 'upper_body');
    await tester.pump(const Duration(minutes: 2));
    expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
    await h.speech(false);
    await tester.pump(const Duration(seconds: 44));
    expect(h.avatar.shots.last, 'upper_body');
    await tester.pump(const Duration(seconds: 1));
    expect(h.avatar.shots.last, 'hero_full_body');
  });

  for (final kind in [
    PresenceInputActivityKind.focus,
    PresenceInputActivityKind.tap,
    PresenceInputActivityKind.typing,
  ]) {
    _cameraTest('${kind.name} keeps a bust shot until conversation idles', (
      tester,
    ) async {
      final h = await _Harness.start(tester);
      final presence = AgentPresenceService(now: tester.binding.clock.now);
      h.director.bindPresence(presence);
      presence.observeInputActivity(kind);
      await tester.pump();
      expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
      await h.speech(true);
      expect(h.avatar.shots.last, 'upper_body');
      await tester.pump(const Duration(minutes: 2));
      expect(h.avatar.shots.last, 'upper_body');
      await h.speech(false);
      await tester.pump(const Duration(seconds: 44));
      expect(h.avatar.shots.last, 'upper_body');
      await tester.pump(const Duration(seconds: 1));
      expect(h.avatar.shots.last, 'hero_full_body');
      await h.speech(true);
      expect(h.avatar.shots.last, 'upper_body');
    });
  }

  _cameraTest('typing refreshes the bust shot without redispatch', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final presence = AgentPresenceService(now: tester.binding.clock.now);
    h.director.bindPresence(presence);
    presence.observeInputActivity(PresenceInputActivityKind.tap);
    await tester.pump();
    expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
    await tester.pump(const Duration(seconds: 40));
    presence.observeInputActivity(PresenceInputActivityKind.typing);
    await tester.pump();
    expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
    await tester.pump(const Duration(seconds: 44));
    expect(h.avatar.shots.last, 'upper_body');
    await tester.pump(const Duration(seconds: 1));
    expect(h.avatar.shots.last, 'hero_full_body');
  });

  for (final kind in [
    PresenceInputActivityKind.voiceModeEntry,
    PresenceInputActivityKind.voiceUtteranceEnded,
  ]) {
    _cameraTest('${kind.name} leaves voice-only conversation on bust framing', (
      tester,
    ) async {
      final h = await _Harness.start(tester);
      final presence = AgentPresenceService(now: tester.binding.clock.now);
      h.director.bindPresence(presence);
      presence.observeInputActivity(kind);
      await tester.pump();
      expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
    });
  }

  for (final entry in {
    'face': 'head',
    'bust': 'upper_body',
    'full': 'hero_full_body',
  }.entries) {
    _cameraTest('explicit ${entry.key} wins over text input framing', (
      tester,
    ) async {
      final h = await _Harness.start(tester);
      final presence = AgentPresenceService(now: tester.binding.clock.now);
      h.director.bindPresence(presence);
      await h.director.setFraming(entry.key);
      final count = h.avatar.shots.length;
      presence.observeInputActivity(PresenceInputActivityKind.tap);
      presence.observeInputActivity(PresenceInputActivityKind.typing);
      await tester.pump();
      expect(h.avatar.shots.last, entry.value);
      expect(h.avatar.shots.length, count);
      await h.director.setFraming('auto');
      expect(h.avatar.shots.last, 'upper_body');
    });
  }

  _cameraTest('sleeping and confirmed work retain priority over text input', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final presence = AgentPresenceService(now: tester.binding.clock.now);
    h.director.bindPresence(presence);
    presence.observeInputActivity(PresenceInputActivityKind.tap);
    await tester.pump();
    expect(h.avatar.shots.last, 'upper_body');
    h.avatar.posture(AvatarFurniturePhase.lying);
    await tester.pump();
    presence.observeInputActivity(PresenceInputActivityKind.tap);
    await tester.pump();
    expect(h.avatar.shots.last, 'sleeping_top');
    h.avatar.posture(
      AvatarFurniturePhase.working,
      furnitureId: 'desk',
      workSessionId: 'c' * 64,
    );
    await tester.pump();
    expect(h.avatar.shots.last, 'desk_over_shoulder');
    final count = h.avatar.shots.length;
    presence.observeInputActivity(PresenceInputActivityKind.typing);
    await tester.pump();
    expect(h.avatar.shots.length, count);
    await tester.pump(const Duration(seconds: 45));
    expect(h.avatar.shots.length, count);
  });

  _cameraTest('text input respects external camera and route ownership', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final presence = AgentPresenceService(now: tester.binding.clock.now);
    h.director.bindPresence(presence);
    h.capturing = true;
    presence.observeInputActivity(PresenceInputActivityKind.tap);
    await tester.pump();
    expect(h.avatar.shots, ['hero_full_body']);
    h.route.value = '/world';
    await tester.pump();
    presence.observeInputActivity(PresenceInputActivityKind.typing);
    await tester.pump();
    expect(h.avatar.shots, ['hero_full_body']);
    h.capturing = false;
    h.route.value = '/home';
    await tester.pump();
    expect(h.avatar.shots.last, 'hero_full_body');
    await h.speech(true);
    expect(h.avatar.shots.last, 'upper_body');
  });

  _cameraTest('sleeping shot remains until renderer confirms seated wake', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    h.avatar.posture(AvatarFurniturePhase.lying);
    await tester.pump();
    expect(h.avatar.shots.last, 'sleeping_top');
    await h.speech(true);
    expect(h.avatar.shots.last, 'sleeping_top');
    h.avatar.posture(AvatarFurniturePhase.aligning);
    await tester.pump();
    expect(h.avatar.shots.last, 'sleeping_top');
    h.avatar.posture(AvatarFurniturePhase.seated);
    await tester.pump();
    expect(h.avatar.shots.last, 'upper_body');
  });

  _cameraTest('foreign speech and redundant initial stop do not zoom', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'other'));
    await tester.pump();
    expect(h.avatar.shots, ['hero_full_body']);
  });

  _cameraTest('only confirmed task working uses the rear desk shot', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final id = 'a' * 64;
    h.avatar.posture(
      AvatarFurniturePhase.approaching,
      furnitureId: 'desk',
      workSessionId: id,
    );
    await tester.pump();
    expect(h.avatar.shots.last, 'hero_full_body');
    h.avatar.posture(AvatarFurniturePhase.working, furnitureId: 'desk');
    await tester.pump();
    expect(
      h.avatar.shots.last,
      'hero_full_body',
      reason: 'User sitting at a desk is not a task camera owner',
    );
    h.avatar.posture(
      AvatarFurniturePhase.working,
      furnitureId: 'desk',
      workSessionId: id,
    );
    await tester.pump();
    expect(h.avatar.shots.last, 'desk_over_shoulder');
    await h.speech(true);
    await h.speech(false);
    await tester.pump(const Duration(seconds: 60));
    expect(
      h.avatar.shots.last,
      'desk_over_shoulder',
      reason: 'TTS and conversational idle cannot interrupt the coding shot',
    );
    h.avatar.posture(AvatarFurniturePhase.rising, furnitureId: 'desk');
    await tester.pump();
    expect(h.avatar.shots.last, 'hero_full_body');
  });

  _cameraTest('explicit user framing wins and auto returns to task shot', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    h.avatar.posture(
      AvatarFurniturePhase.working,
      furnitureId: 'desk',
      workSessionId: 'b' * 64,
    );
    await tester.pump();
    await h.director.setFraming('face');
    await h.speech(true);
    expect(h.avatar.shots.last, 'head');
    await h.director.setFraming('auto');
    expect(h.avatar.shots.last, 'desk_over_shoulder');
    expect(
      (await h.director.setFraming('desk_over_shoulder'))['ok'],
      false,
      reason:
          'Work shot remains host-owned rather than a model/user camera token',
    );
  });

  _cameraTest(
    'actual input activity retains the task camera without redispatch',
    (tester) async {
      final h = await _Harness.start(tester);
      final presence = AgentPresenceService(now: tester.binding.clock.now);
      h.director.bindPresence(presence);
      h.avatar.posture(
        AvatarFurniturePhase.working,
        furnitureId: 'desk',
        workSessionId: 'a' * 64,
      );
      await tester.pump();
      final count = h.avatar.shots.length;
      expect(h.avatar.shots.last, 'desk_over_shoulder');
      presence.observeInputActivity(PresenceInputActivityKind.tap);
      await tester.pump();
      presence.observeInputActivity(PresenceInputActivityKind.typing);
      await tester.pump();
      expect(h.avatar.shots.length, count);
      await tester.pump(const Duration(seconds: 46));
      expect(
        h.avatar.shots.length,
        count,
        reason: 'The idle timeout does not replay the task shot',
      );
      h.avatar.posture(AvatarFurniturePhase.standing);
      await tester.pump();
      expect(h.avatar.shots.last, 'hero_full_body');
    },
  );

  _cameraTest(
    'host handoff resumes bust and returns to idle without an intermediate full shot',
    (tester) async {
      final h = await _Harness.start(tester);
      h.capturing = true;
      h.director.resumeAfterExternalPresentation();
      await tester.pump();
      expect(h.avatar.shots, ['hero_full_body']);
      h.capturing = false;
      h.director.resumeAfterExternalPresentation();
      await tester.pump();
      expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
      await tester.pump(const Duration(seconds: 45));
      expect(h.avatar.shots.last, 'hero_full_body');
      h.current = false;
      h.director.resumeAfterExternalPresentation();
      await tester.pump();
      expect(h.avatar.shots, [
        'hero_full_body',
        'upper_body',
        'hero_full_body',
      ]);
    },
  );

  for (final expired in [false, true]) {
    _cameraTest(
      'login handoff resumes bust after ${expired ? 'expired' : 'recent'} input activity',
      (tester) async {
        final h = await _Harness.start(tester);
        final presence = AgentPresenceService(now: tester.binding.clock.now);
        h.director.bindPresence(presence);
        h.capturing = true;
        presence.observeInputActivity(PresenceInputActivityKind.tap);
        await tester.pump(
          expired ? const Duration(seconds: 46) : const Duration(seconds: 1),
        );
        h.director.resumeAfterExternalPresentation();
        await tester.pump();
        expect(h.avatar.shots, ['hero_full_body']);
        h.capturing = false;
        h.director.resumeAfterExternalPresentation();
        await tester.pump();
        expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
        await tester.pump(const Duration(seconds: 45));
        expect(h.avatar.shots.last, 'hero_full_body');
      },
    );
  }

  for (final entry in {'face': 'head', 'full': 'hero_full_body'}.entries) {
    _cameraTest('explicit ${entry.key} survives speech and expires on idle', (
      tester,
    ) async {
      final h = await _Harness.start(tester);
      expect((await h.director.setFraming(entry.key))['ok'], true);
      await h.speech(true);
      expect(h.avatar.shots.last, entry.value);
      await h.speech(false);
      await tester.pump(const Duration(seconds: 45));
      expect(h.avatar.shots.last, 'hero_full_body');
      await h.speech(true);
      expect(h.avatar.shots.last, 'upper_body');
    });
  }

  _cameraTest('auto relinquishes explicit close-up immediately', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    await h.director.setFraming('face');
    final result = await h.director.setFraming('auto');
    expect(result, {
      'ok': true,
      'framing': 'upper_body',
      'mode': 'auto',
      'automatic': true,
      'idleTimeoutSeconds': 45,
    });
    expect(h.avatar.shots.last, 'upper_body');
  });

  _cameraTest('typing extends idle but unrelated presence ticks do not', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final presence = AgentPresenceService(now: tester.binding.clock.now);
    h.director.bindPresence(presence);
    presence.state.value = presence.state.value.copyWith(
      lastInputActivityAt: tester.binding.clock.now(),
    );
    await tester.pump();
    expect(h.avatar.shots.last, 'upper_body');
    await tester.pump(const Duration(seconds: 40));
    presence.state.value = presence.state.value.copyWith(
      lastUserInteractionAt: tester.binding.clock.now(),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 40));
    presence.state.value = presence.state.value.copyWith(energy: 0.5);
    await tester.pump();
    expect(h.avatar.shots.last, 'upper_body');
    await tester.pump(const Duration(seconds: 5));
    expect(h.avatar.shots.last, 'hero_full_body');
  });

  _cameraTest(
    'asynchronous restored activity stays wide until a new interaction',
    (tester) async {
      final h = await _Harness.start(tester);
      final presence = AgentPresenceService(now: tester.binding.clock.now);
      final boundAt = tester.binding.clock.now();
      h.director.bindPresence(presence);
      await tester.pump(const Duration(seconds: 1));
      scheduleMicrotask(() {
        presence.state.value = presence.state.value.copyWith(
          lastInputActivityAt: boundAt.subtract(const Duration(minutes: 5)),
        );
      });
      await tester.pump();
      expect(h.avatar.shots, ['hero_full_body']);
      scheduleMicrotask(() {
        presence.state.value = presence.state.value.copyWith(
          lastUserInteractionAt: boundAt.subtract(const Duration(minutes: 1)),
        );
      });
      await tester.pump();
      expect(h.avatar.shots, ['hero_full_body']);
      presence.state.value = presence.state.value.copyWith(
        lastInputActivityAt: tester.binding.clock.now(),
      );
      await tester.pump();
      expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
    },
  );

  _cameraTest(
    'human speech starts framing and a long utterance cannot time out',
    (tester) async {
      final h = await _Harness.start(tester);
      EventBus().fire(UserSpeakingStartedEvent());
      await tester.pump();
      expect(h.avatar.shots.last, 'upper_body');
      await tester.pump(const Duration(minutes: 2));
      expect(h.avatar.shots.last, 'upper_body');
      EventBus().fire(
        UserSpeakingEndedEvent(
          duration: const Duration(minutes: 2),
          samples: Float32List(0),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 45));
      expect(h.avatar.shots.last, 'hero_full_body');
    },
  );

  _cameraTest(
    'voice start coalesces a pending explicit request without overriding it',
    (tester) async {
      final h = await _Harness.start(tester);
      final gate = Completer<void>();
      h.avatar.gate = gate;
      final face = h.director.setFraming('face');
      await tester.pump();
      await h.speech(true);
      gate.complete();
      expect((await face)['ok'], true);
      await h.director.waitForIdle();
      expect(h.avatar.shots, ['hero_full_body', 'head']);
    },
  );

  _cameraTest(
    'latest request wins before dispatch and after an in-flight shot',
    (tester) async {
      final h = await _Harness.start(tester);
      final face = h.director.setFraming('face');
      final full = h.director.setFraming('full');
      expect((await face)['error'], 'camera_request_superseded');
      expect((await full)['ok'], true);
      expect(h.avatar.shots, isNot(contains('head')));
      final gate = Completer<void>();
      h.avatar.gate = gate;
      final pending = h.director.setFraming('face');
      await tester.pump();
      final bust = h.director.setFraming('bust');
      gate.complete();
      expect((await pending)['ok'], false);
      expect((await bust)['ok'], true);
      expect(h.avatar.shots.last, 'upper_body');
    },
  );

  for (final route in [
    '/world',
    '/world?space=personal',
    '/selfie',
    '/live-room',
  ]) {
    _cameraTest(
      '$route and lifecycle boundaries cancel idle and clear manual shots',
      (tester) async {
        final h = await _Harness.start(tester);
        await h.director.setFraming('face');
        h.route.value = route;
        await tester.pump();
        final count = h.avatar.shots.length;
        await tester.pump(const Duration(seconds: 60));
        expect(h.avatar.shots.length, count);
        expect(
          (await h.director.setFraming('face'))['error'],
          'camera_presentation_unavailable',
        );
        h.route.value = '/home';
        await tester.pump();
        expect(h.avatar.shots.last, 'hero_full_body');
        await h.director.setFraming('face');
        h.director.didChangeAppLifecycleState(AppLifecycleState.paused);
        final pausedCount = h.avatar.shots.length;
        await h.speech(true);
        expect(h.avatar.shots.length, pausedCount);
        h.director.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        expect(h.avatar.shots.last, 'upper_body');
      },
    );
  }

  _cameraTest('capture and retired account cannot issue camera commands', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    h.capturing = true;
    expect((await h.director.setFraming('face'))['ok'], false);
    await h.speech(true);
    expect(h.avatar.shots, ['hero_full_body']);
    h.capturing = false;
    h.current = false;
    await h.speech(false);
    expect((await h.director.setFraming('face'))['ok'], false);
    expect(h.avatar.shots, ['hero_full_body']);
  });

  _cameraTest('Home return keeps native camera until its completion signal', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final returning = ValueNotifier<bool>(false);
    addTearDown(returning.dispose);
    h.director.bindExternalCameraChanges(returning);
    h.route.value = '/agent-space';
    await tester.pump();
    h.capturing = true;
    returning.value = true;
    h.route.value = '/home';
    await tester.pump();
    final count = h.avatar.shots.length;
    await tester.pump(const Duration(seconds: 3));
    expect(h.avatar.shots.length, count);
    h.capturing = false;
    returning.value = false;
    await tester.pump();
    expect(h.avatar.shots.last, 'hero_full_body');
    expect(h.avatar.shots.length, count + 1);
  });

  _cameraTest('typing during return resumes only after the native walk ends', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final returning = ValueNotifier<bool>(false);
    addTearDown(returning.dispose);
    final presence = AgentPresenceService(now: tester.binding.clock.now);
    h.director.bindPresence(presence);
    h.director.bindExternalCameraChanges(returning);
    h.capturing = true;
    returning.value = true;
    final count = h.avatar.shots.length;
    await tester.pump(const Duration(seconds: 1));
    presence.observeInputActivity(PresenceInputActivityKind.typing);
    await tester.pump();
    expect(h.avatar.shots.length, count);
    h.capturing = false;
    returning.value = false;
    await tester.pump();
    expect(h.avatar.shots.last, 'upper_body');
    await tester.pump(const Duration(seconds: 45));
    expect(h.avatar.shots.last, 'hero_full_body');
  });

  _cameraTest('text input during native return restores its bust shot', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final returning = ValueNotifier<bool>(false);
    addTearDown(returning.dispose);
    final presence = AgentPresenceService(now: tester.binding.clock.now);
    h.director.bindPresence(presence);
    h.director.bindExternalCameraChanges(returning);
    h.capturing = true;
    returning.value = true;
    final count = h.avatar.shots.length;
    await tester.pump(const Duration(seconds: 1));
    presence.observeInputActivity(PresenceInputActivityKind.tap);
    await tester.pump(const Duration(seconds: 10));
    presence.observeInputActivity(PresenceInputActivityKind.typing);
    await tester.pump();
    expect(h.avatar.shots.length, count);
    h.capturing = false;
    returning.value = false;
    await tester.pump();
    expect(h.avatar.shots, ['hero_full_body', 'upper_body']);
    await tester.pump(const Duration(seconds: 45));
    expect(h.avatar.shots.last, 'hero_full_body');
  });

  _cameraTest('expired input during native return cannot restore a bust shot', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final presence = AgentPresenceService(now: tester.binding.clock.now);
    h.director.bindPresence(presence);
    final returning = ValueNotifier<bool>(false);
    addTearDown(returning.dispose);
    h.director.bindExternalCameraChanges(returning);
    h.capturing = true;
    returning.value = true;
    presence.observeInputActivity(PresenceInputActivityKind.tap);
    await tester.pump(const Duration(seconds: 46));
    h.capturing = false;
    returning.value = false;
    await tester.pump();
    expect(h.avatar.shots.last, 'hero_full_body');
    await h.speech(true);
    expect(h.avatar.shots.last, 'upper_body');
  });

  _cameraTest('return interaction cannot leak into a later Home visit', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    final returning = ValueNotifier<bool>(false);
    addTearDown(returning.dispose);
    final presence = AgentPresenceService(now: tester.binding.clock.now);
    h.director.bindPresence(presence);
    h.director.bindExternalCameraChanges(returning);
    h.capturing = true;
    returning.value = true;
    await tester.pump(const Duration(seconds: 1));
    presence.observeInputActivity(PresenceInputActivityKind.typing);
    await tester.pump();
    h.route.value = '/settings';
    await tester.pump();
    h.capturing = false;
    returning.value = false;
    h.route.value = '/home';
    await tester.pump();
    expect(h.avatar.shots.last, 'hero_full_body');
    await _pumpFuture(tester, h.director.sealAndDrain());
    final count = h.avatar.shots.length;
    returning.value = true;
    await tester.pump();
    expect(h.avatar.shots.length, count);
  });

  _cameraTest(
    'model readiness reset clears explicit framing and retries on ready',
    (tester) async {
      final h = await _Harness.start(tester);
      await h.director.setFraming('face');
      h.avatar.isReady.value = false;
      await tester.pump();
      expect(
        (await h.director.setFraming('face'))['error'],
        'camera_renderer_not_ready',
      );
      h.avatar.isReady.value = true;
      await tester.pump();
      expect(h.avatar.shots.last, 'hero_full_body');
      await h.speech(true);
      expect(h.avatar.shots.last, 'upper_body');
    },
  );

  _cameraTest('renderer failures clear manual preference and report failure', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    h.avatar.fail = true;
    expect(
      (await h.director.setFraming('face'))['error'],
      'camera_dispatch_failed',
    );
    h.avatar.fail = false;
    await h.speech(true);
    expect(h.avatar.shots.last, 'upper_body');
  });

  _cameraTest(
    'seal fences queued commands and drains an already dispatched command',
    (tester) async {
      final h = await _Harness.start(tester);
      final gate = Completer<void>();
      h.avatar.gate = gate;
      final request = h.director.setFraming('face');
      await tester.pump();
      var drained = false;
      final drain = h.director.sealAndDrain().then((_) => drained = true);
      await tester.pump();
      expect(drained, false);
      expect(h.director.isActive, false);
      gate.complete();
      expect((await _pumpFuture(tester, request))['ok'], false);
      await _pumpFuture(tester, drain);
      expect(drained, true);
      final count = h.avatar.shots.length;
      await h.speech(true);
      await tester.pump(const Duration(minutes: 1));
      expect(h.avatar.shots.length, count);
    },
  );

  _cameraTest('only supported self camera requests reach the renderer', (
    tester,
  ) async {
    final h = await _Harness.start(tester);
    expect(
      (await h.director.setFraming('head'))['error'],
      'camera_mode_invalid',
    );
    expect(
      (await h.director.setFraming('face', agentId: 'other'))['error'],
      'camera_agent_unsupported',
    );
    expect(h.avatar.shots, ['hero_full_body']);
  });
}

void _cameraTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      final drain = appServices
          .maybeFind<AvatarCameraDirector>()
          ?.sealAndDrain();
      if (drain != null) await _pumpFuture(tester, drain);
      await _pumpFuture(tester, appServices.reset());
    }
  });
}

Future<T> _pumpFuture<T>(WidgetTester tester, Future<T> future) async {
  var completed = false;
  T? result;
  Object? error;
  StackTrace? stack;
  future.then(
    (value) {
      result = value;
      completed = true;
    },
    onError: (Object caught, StackTrace trace) {
      error = caught;
      stack = trace;
      completed = true;
    },
  );
  // Cancellation can join futures from both the widget's fake-clock zone and
  // the real async zone. Awaiting the whole drain in runAsync starves the
  // fake microtask queue, while pump alone can starve root-zone completions.
  // Drive both queues without advancing the camera's simulated idle clock.
  for (var i = 0; i < 20 && !completed; i++) {
    await tester.pump();
    if (!completed) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
  }
  expect(completed, isTrue, reason: 'Future must finish after microtask pumps');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return result as T;
}

class _Harness {
  _Harness(this.tester);
  final WidgetTester tester;
  final avatar = _Avatar();
  final route = ValueNotifier<String>('/home');
  bool current = true;
  bool capturing = false;
  late final AvatarCameraDirector director;

  static Future<_Harness> start(WidgetTester tester) async {
    final h = _Harness(tester);
    final active = appServices.put(ActiveAvatarRuntime())..register(h.avatar);
    h.director = appServices.put(
      AvatarCameraDirector(
        avatarRuntime: active,
        mountIsCurrent: () => h.current,
        externalCameraActive: () => h.capturing,
        currentRoute: () => h.route.value,
        now: tester.binding.clock.now,
      ),
    );
    h.director.bindRouteListener(h.route);
    await tester.pump();
    addTearDown(() async {
      h.route.dispose();
    });
    return h;
  }

  Future<void> speech(bool speaking) async {
    EventBus().fire(SpeakingStatusEvent(speaking, agentId: 'self'));
    await tester.pump();
  }
}

class _Avatar extends AvatarRuntime implements AvatarFurnitureRuntime {
  final furnitureEvents = StreamController<AvatarFurnitureState>.broadcast();
  @override
  AvatarFurnitureState? furnitureState;
  @override
  Stream<AvatarFurnitureState> get furnitureStates => furnitureEvents.stream;
  void posture(
    AvatarFurniturePhase phase, {
    String furnitureId = 'bed',
    String? workSessionId,
  }) {
    furnitureState = AvatarFurnitureState(
      phase: phase,
      furnitureId: furnitureId,
      workSessionId: workSessionId,
      sceneId: 'room',
      sequence: (furnitureState?.sequence ?? 0) + 1,
    );
    furnitureEvents.add(furnitureState!);
  }

  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  final shots = <String>[];
  Completer<void>? gate;
  bool fail = false;

  @override
  Future<void> setFraming(String mode) async {
    shots.add(mode);
    if (fail) throw StateError('renderer rejected');
    await gate?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
