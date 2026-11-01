import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/self_avatar_speech_bridge.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_protection.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_background_task_work_contract.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_command_dispatch_sink.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/agent_sound_platforms.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(installAgentSoundPlatforms);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MaasoTtsPlugin.soundEnabled.value = true;
  });

  tearDown(() async {
    final authority = appServices
        .maybeFind<AvatarProjectionProductionAuthority>();
    if (authority != null) {
      try {
        await authority.sealAndDrain();
      } on Object {
        // Failure-path tests intentionally retain the renderer reset gate.
      }
    }
    await appServices.reset();
    AvatarProductionOwnership.resetForTest();
    MaasoTtsPlugin.soundEnabled.value = true;
  });

  test('semantic speech metadata uses the admitted body ticket only', () async {
    final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
    harness.sink.applied.clear();
    harness.sink.operations.clear();
    harness.renderer.calls.clear();
    final director = AvatarBehaviorDirector(
      runtimeProvider: () => harness.renderer,
      emitEmotion: (_) {},
    );
    expect(
      (await director.applyReaction(
        AvatarReaction.fromJson({
          'mood': 'proud',
          'gesture': 'explain',
          'energy': 'high',
          'intensity': .75,
          'durationMs': 3500,
        }),
      )).applied,
      isTrue,
    );
    await _flush(harness.authority);
    final body = harness.sink.applied
        .where((dispatch) => dispatch.command is AvatarBodyGestureCommand)
        .single;
    expect(body.source, AvatarCommandSource.explicitAgent);
    expect(body.command!.toCanonicalJson(), {
      'channel': 'bodyGesture',
      'gesture': 'explain',
      'energy': 'high',
      'intensity': .75,
      'emotion': 'happy',
    });
    final operation = harness.sink.operations.singleWhere(
      (operation) => operation.dispatch.command is AvatarBodyGestureCommand,
    );
    expect(
      operation.validUntil!
          .difference(harness.sink.operationTimes[operation]!)
          .inMilliseconds,
      inInclusiveRange(3000, 3500),
    );
    expect(harness.renderer.calls, isEmpty);
    expect(
      harness.sink.applied.any(
        (dispatch) => dispatch.channel == AvatarCommandChannel.mouth,
      ),
      isFalse,
    );
    expect(
      harness.authority
          .preflightBehavior(bodyGesture: 'annie_g_roll_both')
          .applied,
      isFalse,
    );
  });

  test(
    'explicit none profile preserves speech semantics and reviewed capability bounds',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
      harness.sink.applied.clear();
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => harness.renderer,
        emitEmotion: (_) {},
      );
      expect(
        (await director.applyAct(
          AvatarAct.fromJson({
            'mood': 'excited',
            'gesture': 'none',
            'energy': 'high',
          }),
        )).applied,
        isTrue,
      );
      await _flush(harness.authority);
      final command = harness.sink.applied
          .map((dispatch) => dispatch.command)
          .whereType<AvatarBodyGestureCommand>()
          .single;
      expect(command.gesture, 'speech');
      expect(command.emotion, 'excited');
      for (final gesture in [
        'speech',
        'explain',
        'palms_open',
        'point_small',
        'chest',
        'point_self',
        'dance',
        'clap',
        'laugh',
        'bow',
        'hand_to_chest',
      ]) {
        expect(
          harness.authority.preflightBehavior(bodyGesture: gesture).applied,
          isTrue,
          reason: gesture,
        );
      }
    },
  );

  test(
    'cancelled speech profile releases its exact admitted generation',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
      harness.sink.applied.clear();
      harness.sink.holdNextBodyMutation = true;
      var current = true;
      final pending = harness.authority.applyBehavior(
        bodyGesture: 'speech',
        energy: 'gentle',
        intensity: .35,
        emotion: 'comforting',
        duration: const Duration(milliseconds: 3500),
        shouldContinue: () => current,
      );
      await harness.sink.waitUntilHeld();
      current = false;
      harness.sink.completeHeld();
      expect((await pending).applied, isFalse);
      await _flush(harness.authority);
      final body = harness.sink.applied
          .where(
            (dispatch) => dispatch.channel == AvatarCommandChannel.bodyGesture,
          )
          .toList();
      expect(body, hasLength(2));
      expect(body.first.command!.toCanonicalJson()['energy'], 'gentle');
      expect(body.last.clearsChannel, isTrue);
      expect(body.first.commandGeneration, isPositive);
      expect(
        body.last.commandGeneration,
        isNull,
        reason: 'an exact release leaves no selected body owner',
      );
    },
  );

  test('native playback clock stays in production TTS ownership', () async {
    final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
    harness.sink.applied.clear();
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    EventBus().fire(
      SpeechPlaybackClockEvent(
        SpeechPlaybackClock(
          playbackId: 'wav-owned',
          generation: 100,
          turnId: 't',
          utteranceId: 'u',
          sequence: 1,
          state: SpeechPlaybackClockState.start,
          positionMs: 0,
          source: SpeechPlaybackClockSource.wav,
          authoritative: false,
          envelope: [0.1, 0.8, 0],
          frameRate: 30,
        ),
        agentId: 'self',
      ),
    );
    await _flush(harness.authority);
    final clocks = harness.sink.applied
        .where(
          (dispatch) => dispatch.command is AvatarSpeechPlaybackClockCommand,
        )
        .toList();
    expect(clocks, hasLength(1));
    expect(clocks.single.source, AvatarCommandSource.ttsMouth);
    expect(clocks.single.channel, AvatarCommandChannel.mouth);
    final command = clocks.single.command! as AvatarSpeechPlaybackClockCommand;
    expect(command.clock.playbackId, 'wav-owned');
    expect(command.clock.envelope, [0.1, 0.8, 0]);
    harness.sink.applied.clear();
    // A stale account event subscription cannot publish into the next owner.
    await harness.authority.sealAndDrain();
    harness.sink.applied.clear();
    EventBus().fire(
      SpeechPlaybackClockEvent(
        SpeechPlaybackClock(
          playbackId: 'wav-owned',
          generation: 100,
          turnId: 't',
          utteranceId: 'u',
          sequence: 2,
          state: SpeechPlaybackClockState.update,
          positionMs: 100,
          source: SpeechPlaybackClockSource.wav,
          authoritative: true,
        ),
        agentId: 'self',
      ),
    );
    await pumpEventQueue();
    expect(harness.sink.applied, isEmpty);
  });

  test(
    'mute clears active production mouth and rejects late speech cues',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      EventBus().fire(LipSyncEnvelopeEvent([0.2, 0.8], agentId: 'self'));
      await _flush(harness.authority);
      expect(
        harness.sink.applied.any(
          (dispatch) => dispatch.command is AvatarLipEnvelopeCommand,
        ),
        isTrue,
      );
      await MaasoTtsPlugin.setSoundEnabled(false);
      await _flush(harness.authority);
      final mouth = harness.sink.applied.lastWhere(
        (dispatch) => dispatch.channel == AvatarCommandChannel.mouth,
      );
      expect(
        mouth.clearsChannel ||
            (mouth.command is AvatarMouthCommand &&
                (mouth.command! as AvatarMouthCommand).value == 0),
        isTrue,
      );
      harness.sink.applied.clear();
      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      EventBus().fire(LipSyncAmplitudeEvent(0.9, agentId: 'self'));
      EventBus().fire(LipSyncEnvelopeEvent([0.9, 0.8], agentId: 'self'));
      EventBus().fire(
        LipSyncVisemeTrackEvent(
          LipSyncVisemeTrack(
            envelope: [0.8],
            cues: [LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.aa)],
          ),
          agentId: 'self',
        ),
      );
      await _flush(harness.authority);
      expect(harness.sink.applied, isEmpty);
    },
  );

  for (final speechAgent in ['self', 'another_agent']) {
    test(
      'muted production mouth accepts only its own scoped game speech ($speechAgent)',
      () async {
        final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
        MaasoTtsPlugin.soundEnabled.value = false;
        final plugin = MaasoTtsPlugin(agentId: speechAgent);
        addTearDown(plugin.dispose);
        final turn = plugin.openTurn(
          turnId: 'game-mouth-scope',
          text: 'Game reply.',
          canSpeak: () => true,
        );
        harness.sink.applied.clear();
        final track = LipSyncVisemeTrack(
          envelope: [0.1, 0.8, 0],
          cues: [
            LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.sil),
            LipSyncVisemeCue(frame: 1, viseme: LipSyncViseme.aa),
          ],
        );
        SpeechPlaybackClock clock(
          SpeechPlaybackClockState state,
          int sequence,
        ) => SpeechPlaybackClock(
          playbackId: 'game-mouth-clock',
          generation: 101,
          turnId: 'game-mouth-scope',
          utteranceId: 'game-mouth-unit',
          sequence: sequence,
          state: state,
          positionMs: state == SpeechPlaybackClockState.start ? 0 : 50,
          source: SpeechPlaybackClockSource.wav,
          authoritative: true,
          envelope: state == SpeechPlaybackClockState.start
              ? track.envelope
              : const [],
          frameRate: state == SpeechPlaybackClockState.start
              ? track.frameRate
              : null,
        );
        final events = <ClawEvent>[
          SpeakingStatusEvent(true, agentId: 'self'),
          LipSyncAmplitudeEvent(.7, agentId: 'self'),
          LipSyncEnvelopeEvent(track.envelope, agentId: 'self'),
          LipSyncVisemeTrackEvent(track, agentId: 'self'),
          SpeechPlaybackClockEvent(
            clock(SpeechPlaybackClockState.start, 1),
            agentId: 'self',
          ),
        ];
        for (final event in events) {
          EventBus().fire(event);
          await _flush(harness.authority);
        }
        if (speechAgent != 'self') {
          expect(
            harness.sink.applied,
            isEmpty,
            reason:
                'A different agent cannot authorize the self avatar while chat is muted.',
          );
          return;
        }
        final mouth = harness.sink.applied
            .where((dispatch) => dispatch.channel == AvatarCommandChannel.mouth)
            .toList();
        expect(
          mouth
              .map((dispatch) => dispatch.command)
              .whereType<AvatarMouthCommand>()
              .any((command) => command.value == .7),
          isTrue,
        );
        expect(
          mouth
              .map((dispatch) => dispatch.command)
              .whereType<AvatarLipEnvelopeCommand>(),
          isNotEmpty,
        );
        expect(
          mouth
              .map((dispatch) => dispatch.command)
              .whereType<AvatarVisemeTrackCommand>(),
          isNotEmpty,
        );
        expect(
          mouth
              .map((dispatch) => dispatch.command)
              .whereType<AvatarSpeechPlaybackClockCommand>(),
          hasLength(1),
        );
        expect(
          mouth.every(
            (dispatch) => dispatch.source == AvatarCommandSource.ttsMouth,
          ),
          isTrue,
        );
        expect(MaasoTtsPlugin.soundEnabled.value, isFalse);

        await turn.cancel('game_voice_disabled');
        harness.sink.applied.clear();
        for (final event in events.take(4)) {
          EventBus().fire(event);
        }
        EventBus().fire(
          SpeechPlaybackClockEvent(
            clock(SpeechPlaybackClockState.update, 2),
            agentId: 'self',
          ),
        );
        await _flush(harness.authority);
        expect(
          harness.sink.applied,
          isEmpty,
          reason: 'Revoked speech cannot reopen the production mouth.',
        );
        EventBus().fire(
          SpeechPlaybackClockEvent(
            clock(SpeechPlaybackClockState.stop, 3),
            agentId: 'self',
          ),
        );
        await _flush(harness.authority);
        final stop = harness.sink.applied
            .map((dispatch) => dispatch.command)
            .whereType<AvatarSpeechPlaybackClockCommand>()
            .single;
        expect(
          stop.clock.state,
          SpeechPlaybackClockState.stop,
          reason:
              'The final stop must still retire a track after its scoped permission is gone.',
        );
      },
    );
  }

  test(
    'rejected ambient furniture cannot run after an explicit gesture expires',
    () async {
      final h = await _Harness.create(mode: FeatureRolloutMode.enforce);
      expect(
        (await h.authority.applyBehavior(
          bodyGesture: 'wave',
          duration: const Duration(milliseconds: 350),
        )).applied,
        true,
      );
      final result = await h.authority.applyBehavior(
        bodyGesture: 'lie_bed',
        duration: const Duration(seconds: 5),
        ambient: true,
      );
      expect(result.applied, false);
      await Future<void>.delayed(const Duration(milliseconds: 420));
      await _flush(h.authority);
      expect(
        h.sink.applied.where(
          (d) =>
              d.command is AvatarBodyGestureCommand &&
              (d.command as AvatarBodyGestureCommand).gesture == 'lie_bed',
        ),
        isEmpty,
      );
    },
  );

  test('camera source changes retire the previous manual lease', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      cameraFramingIsManaged: () => true,
    );
    harness.sink.applied.clear();
    for (final request in [
      ('head', AvatarCommandSource.explicitUser),
      ('upper_body', AvatarCommandSource.explicitUser),
      ('upper_body', AvatarCommandSource.auto),
      ('hero_full_body', AvatarCommandSource.idle),
    ]) {
      expect(
        (await harness.authority.applyCameraFraming(
          mode: request.$1,
          source: request.$2,
        )).applied,
        isTrue,
      );
    }
    final cameras = harness.sink.applied
        .where((dispatch) => dispatch.command is AvatarFramingCommand)
        .toList();
    expect(cameras.map((d) => (d.command! as AvatarFramingCommand).mode), [
      'head',
      'upper_body',
      'upper_body',
      'hero_full_body',
    ]);
    expect(cameras.map((d) => d.source), [
      AvatarCommandSource.explicitUser,
      AvatarCommandSource.explicitUser,
      AvatarCommandSource.auto,
      AvatarCommandSource.idle,
    ]);
    expect((await harness.authority.releaseCameraFraming()).applied, isTrue);
    expect(harness.sink.applied.last.clearsChannel, isTrue);
    final count = harness.sink.applied.length;
    expect((await harness.authority.releaseCameraFraming()).applied, isTrue);
    expect(harness.sink.applied, hasLength(count));
    expect(harness.renderer.calls, isEmpty);
  });

  test(
    'task lease retirement cannot clear a replacement body behavior',
    () async {
      final h = await _Harness.create(mode: FeatureRolloutMode.enforce);
      final id = 'a' * 64;
      expect(
        (await h.authority.applyBackgroundTaskWork(
          sessionId: id,
          phase: AvatarBackgroundTaskWorkPhase.start,
          shouldContinue: () => true,
        )).applied,
        true,
      );
      final command = h.sink.applied.last.command as AvatarBodyGestureCommand;
      expect(command.workSessionId, id);
      expect(command.workPhase, AvatarBackgroundTaskWorkPhase.start);
      expect(
        (await h.authority.applyBehavior(
          bodyGesture: 'sit_sofa',
          duration: const Duration(seconds: 2),
        )).applied,
        true,
      );
      h.sink.applied.clear();
      await h.authority.releaseBackgroundTaskWorkLease(id);
      expect(
        h.sink.applied,
        isEmpty,
        reason: 'The new body generation is a different owner',
      );
      await h.authority.releaseBackgroundTaskWorkLease(id);
      expect(h.sink.applied, isEmpty);
    },
  );

  test('managed camera takes over ready framing and survives speech', () async {
    var managed = false;
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      cameraFramingIsManaged: () => managed,
    );
    expect(
      harness.sink.applied.any((d) => d.command is AvatarFramingCommand),
      isTrue,
    );
    managed = true;
    harness.sink.applied.clear();
    expect(
      (await harness.authority.applyCameraFraming(
        mode: 'upper_body',
        source: AvatarCommandSource.auto,
      )).applied,
      isTrue,
    );
    expect(
      (await harness.authority.applyCameraFraming(
        mode: 'head',
        source: AvatarCommandSource.explicitUser,
      )).applied,
      isTrue,
    );
    harness.sink.applied.clear();
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    EventBus().fire(LipSyncAmplitudeEvent(0.5, agentId: 'self'));
    await _flush(harness.authority);
    EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
    await _flush(harness.authority);
    expect(
      harness.sink.applied.where(
        (d) => d.channel == AvatarCommandChannel.framing,
      ),
      isEmpty,
    );
    expect(
      harness.sink.applied.any((d) => d.channel == AvatarCommandChannel.mouth),
      isTrue,
    );
    expect(harness.authority.phase, AvatarProductionAuthorityPhase.enforcing);
    expect(harness.renderer.calls, isEmpty);
  });

  test(
    'retained camera is not applied and release preserves scene owner',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
      harness.sink.applied.clear();
      final result = await harness.authority.applyCameraFraming(
        mode: 'hero_full_body',
        source: AvatarCommandSource.idle,
      );
      expect(result.applied, isFalse);
      expect(
        result.disposition,
        AvatarProductionBehaviorDisposition.retainedBehindHigherPriority,
      );
      expect(harness.sink.applied, isEmpty);
      expect((await harness.authority.releaseCameraFraming()).applied, isTrue);
      expect(harness.sink.applied, isEmpty);
      // Default legacy behavior remains available after releasing only the
      // director's retained lease.
      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      await _flush(harness.authority);
      final framing = harness.sink.applied
          .where((d) => d.command is AvatarFramingCommand)
          .last;
      expect((framing.command! as AvatarFramingCommand).mode, 'full');
      expect(framing.source, AvatarCommandSource.scene);
    },
  );

  test('cancelled camera dispatch releases its exact generation', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      cameraFramingIsManaged: () => true,
    );
    var current = true;
    harness.sink.applied.clear();
    harness.sink.holdNextMutation = true;
    final pending = harness.authority.applyCameraFraming(
      mode: 'head',
      source: AvatarCommandSource.explicitUser,
      shouldContinue: () => current,
    );
    await harness.sink.waitUntilHeld();
    current = false;
    harness.sink.completeHeld();
    expect((await pending).applied, isFalse);
    expect(harness.sink.applied.last.clearsChannel, isTrue);
    expect(
      (await harness.authority.applyCameraFraming(
        mode: 'upper_body',
        source: AvatarCommandSource.auto,
      )).applied,
      isTrue,
    );
    expect(
      (harness.sink.applied.last.command! as AvatarFramingCommand).mode,
      'upper_body',
    );
  });

  test('retiring epoch rejects held and later camera work', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      cameraFramingIsManaged: () => true,
    );
    harness.sink.holdNextMutation = true;
    final pending = harness.authority.applyCameraFraming(
      mode: 'head',
      source: AvatarCommandSource.explicitUser,
    );
    await harness.sink.waitUntilHeld();
    final drained = harness.authority.sealAndDrain();
    harness.sink.completeHeld();
    expect(
      (await pending).disposition,
      AvatarProductionBehaviorDisposition.authorityStale,
    );
    await drained;
    final count = harness.sink.applied.length;
    expect(
      (await harness.authority.applyCameraFraming(
        mode: 'upper_body',
        source: AvatarCommandSource.auto,
      )).applied,
      isFalse,
    );
    expect(harness.sink.applied, hasLength(count));
  });

  test(
    'camera rejects unsupported modes, sources and unready renderer',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        cameraFramingIsManaged: () => true,
      );
      harness.sink.applied.clear();
      for (final request in [
        ('full', AvatarCommandSource.explicitUser),
        ('head', AvatarCommandSource.scene),
        ('head', AvatarCommandSource.explicitAgent),
        ('head', AvatarCommandSource.ttsMouth),
      ]) {
        final result = await harness.authority.applyCameraFraming(
          mode: request.$1,
          source: request.$2,
        );
        expect(result.applied, isFalse);
        expect(
          result.disposition,
          AvatarProductionBehaviorDisposition.capabilityUnavailable,
        );
      }
      expect(harness.sink.applied, isEmpty);
      harness.renderer.isReady.value = false;
      await _flush(harness.authority);
      expect(
        (await harness.authority.applyCameraFraming(
          mode: 'head',
          source: AvatarCommandSource.explicitUser,
        )).applied,
        isFalse,
      );
      expect(harness.renderer.calls, isEmpty);
    },
  );

  test('camera renderer rejection is never reported as applied', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      cameraFramingIsManaged: () => true,
    );
    harness.sink.applied.clear();
    harness.sink.failNextFraming = true;
    final result = await harness.authority.applyCameraFraming(
      mode: 'head',
      source: AvatarCommandSource.explicitUser,
    );
    expect(result.applied, isFalse);
    expect(
      result.disposition,
      AvatarProductionBehaviorDisposition.dispatchFailed,
    );
    expect(harness.sink.applied, isEmpty);
    expect(harness.renderer.calls, isEmpty);
  });

  for (final mode in FeatureRolloutMode.values) {
    test(
      '$mode interrupted ambient gaze cannot resume over explicit behavior',
      () async {
        final harness = await _Harness.create(mode: mode);
        final protection = appServices.put(AvatarBehaviorProtection());
        final gaze = _PausedGazeHandler();
        final emotions = <AvatarEmotionIntent>[];
        final director = AvatarBehaviorDirector(
          runtimeProvider: () => harness.renderer,
          gazeIntentHandler: gaze,
          emitEmotion: emotions.add,
        );
        harness.sink.applied.clear();
        harness.renderer.calls.clear();
        if (mode == FeatureRolloutMode.enforce) {
          harness.sink.holdNextMutation = true;
        }
        final ambient = director.applyAct(
          const AvatarAct(
            mood: 'calm',
            gesture: 'listen',
            gaze: 'down',
            posture: 'step_forward',
          ),
          ambient: true,
        );
        if (mode == FeatureRolloutMode.enforce) {
          await harness.sink.waitUntilHeld();
        } else {
          await gaze.started.future;
        }
        final explicit = director.applyReaction(
          const AvatarReaction(mood: 'serious', gesture: 'wave', gaze: 'user'),
        );
        expect(protection.isProtected('self'), isTrue);
        if (mode == FeatureRolloutMode.enforce) {
          harness.sink.completeHeld();
        } else {
          gaze.resume.complete();
        }
        expect((await explicit).applied, isTrue);
        expect((await ambient).applied, isFalse);
        expect(emotions.map((intent) => intent.label), ['calm', 'serious']);
        if (mode == FeatureRolloutMode.enforce) {
          final body = harness.sink.applied.where(
            (dispatch) => dispatch.command is AvatarBodyGestureCommand,
          );
          expect(
            body.map(
              (dispatch) =>
                  (dispatch.command! as AvatarBodyGestureCommand).gesture,
            ),
            ['wave'],
          );
          expect(body.single.source, AvatarCommandSource.explicitAgent);
          expect(harness.sink.applied.first.source, AvatarCommandSource.idle);
          expect(harness.renderer.calls, isEmpty);
        } else {
          expect(harness.renderer.calls, ['primitive']);
          expect(harness.sink.applied, isEmpty);
        }
        expect(
          (await director.applyAct(
            const AvatarAct(mood: 'calm'),
            ambient: true,
          )).applied,
          isFalse,
        );
        expect(emotions.map((intent) => intent.label), ['calm', 'serious']);
      },
    );
  }

  test(
    'production expression cue expires onto base without touching TTS',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
      EventBus().fire(
        EmotionStateEvent(EmotionParams.serious, agentId: 'self'),
      );
      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      EventBus().fire(LipSyncAmplitudeEvent(0.7, agentId: 'self'));
      await _flush(harness.authority);
      harness.sink.applied.clear();
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.happy,
          agentId: 'self',
          duration: const Duration(milliseconds: 80),
        ),
      );
      await _flush(harness.authority);
      expect(
        (harness.sink.applied.last.command! as AvatarExpressionCommand)
            .params
            .happy,
        1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await _flush(harness.authority);
      expect(
        harness.sink.applied.map((dispatch) => dispatch.channel),
        everyElement(AvatarCommandChannel.expression),
      );
      final restored =
          harness.sink.applied.last.command! as AvatarExpressionCommand;
      expect(restored.params.happy, 0);
      // The production arbiter removes mouth data from every expression packet;
      // the already-active TTS mouth lease remains untouched.
      expect(restored.params.mouthOpen, 0);
      expect(harness.renderer.calls, isEmpty);
    },
  );

  test(
    'production reset and renderer reload cannot revive a temporary face',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
      EventBus().fire(
        EmotionStateEvent(EmotionParams.serious, agentId: 'self'),
      );
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.happy,
          agentId: 'self',
          duration: const Duration(milliseconds: 80),
        ),
      );
      await _flush(harness.authority);
      EventBus().fire(AvatarEmotionResetEvent(agentId: 'self'));
      await _flush(harness.authority);
      expect(
        (harness.sink.applied.last.command! as AvatarExpressionCommand)
            .params
            .happy,
        0,
      );
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.happy,
          agentId: 'self',
          duration: const Duration(milliseconds: 80),
        ),
      );
      await _flush(harness.authority);
      harness.renderer.isReady.value = false;
      await _flush(harness.authority);
      harness.renderer.isReady.value = true;
      await _flush(harness.authority);
      final expression =
          harness.sink.applied
                  .lastWhere(
                    (dispatch) =>
                        dispatch.channel == AvatarCommandChannel.expression,
                  )
                  .command!
              as AvatarExpressionCommand;
      expect(expression.params.happy, 0);
      harness.sink.applied.clear();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await _flush(harness.authority);
      expect(harness.sink.applied, isEmpty);
    },
  );

  for (final mode in <FeatureRolloutMode>[
    FeatureRolloutMode.off,
    FeatureRolloutMode.shadow,
  ]) {
    test(
      '$mode legacy owner restores its temporary face with no v2 writes',
      () async {
        final harness = await _Harness.create(mode: mode);
        appServices.put(SelfAvatarBridge());
        harness.renderer.calls.clear();
        harness.renderer.expressions.clear();
        EventBus().fire(
          EmotionStateEvent(
            EmotionParams.happy,
            agentId: 'self',
            duration: const Duration(milliseconds: 80),
          ),
        );
        await _flush(harness.authority);
        expect(
          harness.renderer.calls.where((call) => call == 'expression'),
          isNotEmpty,
          reason:
              'the expiry may already run while a loaded test runner drains',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await _flush(harness.authority);
        expect(
          harness.renderer.calls.where((call) => call == 'expression'),
          hasLength(2),
        );
        expect(harness.renderer.expressions, hasLength(2));
        expect(harness.renderer.expressions.first.happy, 1);
        expect(harness.renderer.expressions.last.happy, 0);
        expect(harness.sink.applied, isEmpty);
      },
    );
  }

  for (final mode in [FeatureRolloutMode.off, FeatureRolloutMode.enforce]) {
    test(
      '$mode distinguishes automatic repeat from a new authored short smile',
      () async {
        final harness = await _Harness.create(mode: mode);
        if (mode == FeatureRolloutMode.off) appServices.put(SelfAvatarBridge());
        List<AvatarExpressionParams> faces() => mode == FeatureRolloutMode.off
            ? harness.renderer.expressions
            : harness.sink.applied
                  .map((dispatch) => dispatch.command)
                  .whereType<AvatarExpressionCommand>()
                  .map((command) => command.params)
                  .toList();
        void clearFaces() {
          harness.renderer.expressions.clear();
          harness.sink.applied.clear();
        }

        Future<void> send(EmotionStateEvent event) async {
          EventBus().fire(event);
          await _flush(harness.authority);
        }

        await send(EmotionStateEvent(EmotionParams.serious, agentId: 'self'));
        await send(
          EmotionStateEvent(
            EmotionParams.happy.scaled(0.3),
            agentId: 'self',
            semanticLabel: 'happy',
            automatic: true,
            duration: const Duration(milliseconds: 80),
          ),
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        await _flush(harness.authority);
        expect(faces().last.happy, 0);
        clearFaces();
        await send(
          EmotionStateEvent(
            EmotionParams.happy.scaled(0.4),
            agentId: 'self',
            semanticLabel: 'happy',
            automatic: true,
            duration: const Duration(milliseconds: 1200),
          ),
        );
        expect(
          faces().every((face) => face.happy == 0),
          isTrue,
          reason: 'automatic repetition is still held off after three seconds',
        );
        clearFaces();
        await send(
          EmotionStateEvent(
            EmotionParams.happy.scaled(0.5),
            agentId: 'self',
            semanticLabel: 'happy',
            duration: const Duration(milliseconds: 1200),
          ),
        );
        expect(
          faces().any((face) => (face.happy - 0.5).abs() < 1e-9),
          isTrue,
          reason: 'new authored cue is visible without persistent hold',
        );
        await Future<void>.delayed(const Duration(milliseconds: 1300));
        await _flush(harness.authority);
        expect(faces().last.happy, 0);
        expect(faces().last.browConcern, greaterThan(0));
        await send(
          EmotionStateEvent(
            EmotionParams.happy.scaled(0.35),
            agentId: 'self',
            semanticLabel: 'happy',
            persistent: true,
          ),
        );
        expect(faces().last.happy, closeTo(0.35, 1e-9));
        await send(
          EmotionStateEvent(
            EmotionParams.comforting,
            agentId: 'self',
            semanticLabel: 'comforting',
          ),
        );
        expect(faces().last.happy, 0);
        expect(faces().last.browConcern, greaterThan(0));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await _flush(harness.authority);
        expect(
          faces().last.happy,
          0,
          reason: 'negative/support context ends the requested held face',
        );
      },
    );
  }

  test(
    'off and shadow preserve legacy writes; enforce has one owner',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.off);
      appServices.put(SelfAvatarBridge());

      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.happy,
          semanticLabel: 'happy',
          agentId: 'self',
        ),
      );
      await _flush(harness.authority);
      expect(harness.renderer.calls, contains('expression'));
      expect(harness.sink.applied, isEmpty);
      expect(AvatarProductionOwnership.ownsRenderer, isFalse);

      harness.renderer.calls.clear();
      await harness.setMode(FeatureRolloutMode.shadow);
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.sad,
          semanticLabel: 'sad',
          agentId: 'self',
        ),
      );
      await _flush(harness.authority);
      expect(harness.renderer.calls, contains('expression'));
      expect(harness.sink.applied, isEmpty);
      expect(AvatarProductionOwnership.ownsRenderer, isFalse);

      harness.renderer.calls.clear();
      await harness.setMode(FeatureRolloutMode.enforce);
      harness.sink.applied.clear();
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.love,
          semanticLabel: 'love',
          agentId: 'self',
        ),
      );
      await _flush(harness.authority);

      expect(harness.renderer.calls, isEmpty);
      expect(
        harness.sink.applied.where(
          (dispatch) => dispatch.channel == AvatarCommandChannel.expression,
        ),
        hasLength(1),
      );
      expect(AvatarProductionOwnership.ownsRenderer, isTrue);
    },
  );

  test(
    'mode round trips always create a fresh ticket authority epoch',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.off);
      final generations = <int>[harness.authority.rendererGeneration];

      await harness.setMode(FeatureRolloutMode.enforce);
      expect(harness.authority.phase, AvatarProductionAuthorityPhase.enforcing);
      generations.add(harness.authority.rendererGeneration);

      await harness.setMode(FeatureRolloutMode.off);
      expect(harness.authority.phase, AvatarProductionAuthorityPhase.legacy);
      expect(AvatarProductionOwnership.ownsRenderer, isFalse);
      generations.add(harness.authority.rendererGeneration);

      await harness.setMode(FeatureRolloutMode.enforce);
      expect(harness.authority.phase, AvatarProductionAuthorityPhase.enforcing);
      generations.add(harness.authority.rendererGeneration);

      await harness.setMode(FeatureRolloutMode.shadow);
      expect(harness.authority.phase, AvatarProductionAuthorityPhase.shadow);
      expect(AvatarProductionOwnership.ownsRenderer, isFalse);
      generations.add(harness.authority.rendererGeneration);

      await harness.setMode(FeatureRolloutMode.enforce);
      expect(harness.authority.phase, AvatarProductionAuthorityPhase.enforcing);
      generations.add(harness.authority.rendererGeneration);

      expect(generations.toSet(), hasLength(generations.length));
      for (var index = 1; index < generations.length; index++) {
        expect(generations[index], greaterThan(generations[index - 1]));
      }
    },
  );

  test('enforce filters peer events and TTS exclusively owns mouth', () async {
    final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
    harness.sink.applied.clear();

    EventBus().fire(
      EmotionStateEvent(
        EmotionParams.angry,
        semanticLabel: 'angry',
        agentId: 'peer-1',
      ),
    );
    await _flush(harness.authority);
    expect(harness.sink.applied, isEmpty);

    EventBus().fire(
      EmotionStateEvent(
        EmotionParams(mouthCurve: 0.4, mouthOpen: 0.9),
        semanticLabel: 'talking',
        agentId: 'self',
      ),
    );
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    EventBus().fire(LipSyncAmplitudeEvent(0.72, agentId: 'self'));
    await _flush(harness.authority);

    final expression =
        harness.sink.applied
                .where(
                  (dispatch) =>
                      dispatch.channel == AvatarCommandChannel.expression,
                )
                .last
                .command!
            as AvatarExpressionCommand;
    final mouth = harness.sink.applied
        .where((dispatch) => dispatch.channel == AvatarCommandChannel.mouth)
        .last;
    expect(expression.params.mouthOpen, 0);
    expect(mouth.source, AvatarCommandSource.ttsMouth);
    expect(
      (mouth.command! as AvatarMouthCommand).value,
      closeTo(0.72, 1e-9),
      reason: 'semantic open mouth cannot impose a TTS amplitude minimum',
    );
    for (final amplitude in [0.0, 0.2]) {
      EventBus().fire(LipSyncAmplitudeEvent(amplitude, agentId: 'self'));
      await _flush(harness.authority);
      final silentOrSoftMouth = harness.sink.applied
          .where((dispatch) => dispatch.channel == AvatarCommandChannel.mouth)
          .last;
      expect(silentOrSoftMouth.source, AvatarCommandSource.ttsMouth);
      expect(
        (silentOrSoftMouth.command! as AvatarMouthCommand).value,
        amplitude,
      );
    }

    EventBus().fire(
      LipSyncEnvelopeEvent(
        const <double>[0.1, 0.8, 0.2],
        frameRate: 24,
        agentId: 'self',
      ),
    );
    await _flush(harness.authority);
    final envelope = harness.sink.applied.last.command;
    expect(envelope, isA<AvatarLipEnvelopeCommand>());
    expect(harness.sink.applied.last.source, AvatarCommandSource.ttsMouth);

    final track = LipSyncVisemeTrack(
      envelope: const <double>[0, 0.8, 0],
      cues: <LipSyncVisemeCue>[
        LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.sil),
        LipSyncVisemeCue(frame: 1, viseme: LipSyncViseme.ih),
        LipSyncVisemeCue(frame: 2, viseme: LipSyncViseme.sil),
      ],
    );
    EventBus().fire(LipSyncVisemeTrackEvent(track, agentId: 'self'));
    await _flush(harness.authority);
    final viseme = harness.sink.applied.last.command;
    expect(viseme, isA<AvatarVisemeTrackCommand>());
    expect((viseme! as AvatarVisemeTrackCommand).track, same(track));
    expect(harness.sink.applied.last.source, AvatarCommandSource.ttsMouth);
  });

  for (final held in [false, true]) {
    test(
      'not-ready never writes and ready replays ${held ? "held expression" : "resting mood"}',
      () async {
        final harness = await _Harness.create(
          mode: FeatureRolloutMode.enforce,
          ready: false,
        );
        final firstGeneration = harness.authority.rendererGeneration;

        EventBus().fire(
          EmotionStateEvent(
            EmotionParams.love,
            semanticLabel: 'love',
            persistent: held,
            agentId: 'self',
          ),
        );
        await _flush(harness.authority);
        expect(harness.sink.applied, isEmpty);

        harness.renderer.isReady.value = true;
        await _flush(harness.authority);
        final readyGeneration = harness.authority.rendererGeneration;
        expect(readyGeneration, greaterThan(firstGeneration));
        expect(
          harness.sink.applied.any((dispatch) {
            final command = dispatch.command;
            return command is AvatarExpressionCommand &&
                (held
                    ? command.params.love > 0
                    : command.params.love == 0 &&
                          command.params.happy == 0 &&
                          command.params.mouthSmile == 0);
          }),
          isTrue,
        );

        harness.sink.applied.clear();
        harness.renderer.isReady.value = false;
        await _flush(harness.authority);
        final unreadyGeneration = harness.authority.rendererGeneration;
        harness.renderer.isReady.value = true;
        await _flush(harness.authority);

        expect(unreadyGeneration, greaterThan(readyGeneration));
        expect(
          harness.authority.rendererGeneration,
          greaterThan(unreadyGeneration),
        );
        expect(
          harness.sink.applied.any(
            (dispatch) => dispatch.channel == AvatarCommandChannel.expression,
          ),
          isTrue,
        );
      },
    );
  }

  test('enforce to off stays legacy-locked until held work drains', () async {
    final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
    expect(harness.authority.phase, AvatarProductionAuthorityPhase.enforcing);
    harness.sink.applied.clear();
    harness.sink.holdNextMutation = true;

    EventBus().fire(
      EmotionStateEvent(
        EmotionParams.excited,
        semanticLabel: 'excited',
        agentId: 'self',
      ),
    );
    await harness.sink.waitUntilHeld();
    expect(harness.authority.phase, AvatarProductionAuthorityPhase.enforcing);
    harness.flags.setRuntimeMaximum(
      MaasoFeatureFlag.avatarProjectionV2,
      FeatureRolloutMode.off,
    );

    expect(
      harness.authority.phase,
      AvatarProductionAuthorityPhase.drainingLocked,
    );
    expect(AvatarProductionOwnership.ownsRenderer, isTrue);

    harness.sink.completeHeld();
    await _flush(harness.authority);
    expect(harness.authority.phase, AvatarProductionAuthorityPhase.legacy);
    expect(AvatarProductionOwnership.ownsRenderer, isFalse);
  });

  test(
    'off account teardown requires exact next-owner reset and failure locks',
    () async {
      final sink = _RecordingSink();
      final renderer = _RecordingAvatarRuntime(ready: true);
      final active = ActiveAvatarRuntime()..register(renderer);
      final first = await _Harness.create(
        mode: FeatureRolloutMode.off,
        accountGeneration: 10,
        sink: sink,
        renderer: renderer,
        active: active,
      );

      await first.authority.sealAndDrain();
      await appServices.delete<AvatarProjectionProductionAuthority>(
        force: true,
      );
      expect(sink.resetOperations, isEmpty);
      expect(AvatarProductionOwnership.ownsRenderer, isTrue);

      sink.failNextReset = true;
      final second = await _Harness.create(
        mode: FeatureRolloutMode.off,
        accountGeneration: 11,
        sink: sink,
        renderer: renderer,
        active: active,
      );
      expect(
        second.authority.phase,
        AvatarProductionAuthorityPhase.failedLocked,
      );
      expect(sink.resetOperations, hasLength(1));
      expect(AvatarProductionOwnership.ownsRenderer, isTrue);

      await second.authority.sealAndDrain();
      await appServices.delete<AvatarProjectionProductionAuthority>(
        force: true,
      );
      final third = await _Harness.create(
        mode: FeatureRolloutMode.off,
        accountGeneration: 12,
        sink: sink,
        renderer: renderer,
        active: active,
      );

      expect(third.authority.phase, AvatarProductionAuthorityPhase.legacy);
      expect(sink.resetOperations, hasLength(2));
      expect(sink.resetMutations, hasLength(1));
      expect(AvatarProductionOwnership.ownsRenderer, isFalse);

      await third.authority.sealAndDrain();
      await appServices.delete<AvatarProjectionProductionAuthority>(
        force: true,
      );
      final fourth = await _Harness.create(
        mode: FeatureRolloutMode.off,
        accountGeneration: 13,
        sink: sink,
        renderer: renderer,
        active: active,
      );
      expect(fourth.authority.phase, AvatarProductionAuthorityPhase.legacy);
      expect(sink.resetOperations, hasLength(3));
      expect(sink.resetMutations, hasLength(2));
      expect(
        sink.resetOperations[2].retiredRendererGeneration,
        sink.resetOperations[1].targetRendererGeneration,
      );
    },
  );

  test(
    'enforce then off teardown resets the last native owner epoch',
    () async {
      final sink = _RecordingSink();
      final renderer = _RecordingAvatarRuntime(ready: true);
      final active = ActiveAvatarRuntime()..register(renderer);
      final first = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        accountGeneration: 30,
        sink: sink,
        renderer: renderer,
        active: active,
      );
      final appliedGeneration = sink.applied
          .lastWhere((dispatch) => !dispatch.clearsChannel)
          .rendererGeneration;
      await first.setMode(FeatureRolloutMode.off);
      await first.authority.sealAndDrain();
      await appServices.delete<AvatarProjectionProductionAuthority>(
        force: true,
      );

      final second = await _Harness.create(
        mode: FeatureRolloutMode.off,
        accountGeneration: 31,
        sink: sink,
        renderer: renderer,
        active: active,
      );

      expect(second.authority.phase, AvatarProductionAuthorityPhase.legacy);
      expect(sink.resetOperations, hasLength(1));
      expect(
        sink.resetOperations.single.retiredRendererGeneration,
        appliedGeneration,
      );
    },
  );

  test('default wave retains the ticketed semantic primitive route', () async {
    final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
    harness.renderer.calls.clear();
    harness.sink.applied.clear();
    harness.sink.operations.clear();
    final emotions = <AvatarEmotionIntent>[];
    final director = AvatarBehaviorDirector(
      runtimeProvider: () => harness.renderer,
      emitEmotion: (intent) {
        emotions.add(intent);
        EventBus().fire(
          EmotionStateEvent(
            intent.params,
            semanticLabel: intent.label,
            duration: intent.duration,
            agentId: intent.agentId,
          ),
        );
      },
    );
    const act = AvatarAct(mood: 'happy', gesture: 'wave', gaze: 'user');

    final started = DateTime.now();
    expect(act.durationMs, 1200);
    expect((await director.applyAct(act)).applied, isTrue);
    await _flush(harness.authority);
    final body = harness.sink.applied
        .where((dispatch) => dispatch.command is AvatarBodyGestureCommand)
        .single;
    expect((body.command! as AvatarBodyGestureCommand).gesture, 'wave');
    expect(body.source, AvatarCommandSource.explicitAgent);
    expect(harness.renderer.calls, isEmpty);
    final bodyOperation = harness.sink.operations.singleWhere(
      (operation) => operation.dispatch.command is AvatarBodyGestureCommand,
    );
    final gazeOperation = harness.sink.operations.singleWhere(
      (operation) => operation.dispatch.command is AvatarGazeCommand,
    );
    expect(
      bodyOperation.validUntil!.difference(started),
      greaterThanOrEqualTo(const Duration(milliseconds: 2500)),
    );
    expect(
      gazeOperation.validUntil!
          .difference(harness.sink.operationTimes[gazeOperation]!)
          .inMilliseconds,
      inInclusiveRange(1150, 1200),
    );
    expect(emotions.single.duration, const Duration(milliseconds: 1200));
    expect(
      harness.authority
          .preflightBehavior(bodyGesture: 'annie_wave')
          .disposition,
      AvatarProductionBehaviorDisposition.capabilityUnavailable,
      reason: 'imported clip IDs do not expand the ticketed capability list',
    );
  });

  test('cancelled extended body lease releases its exact generation', () async {
    final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
    harness.sink.applied.clear();
    harness.sink.holdNextBodyMutation = true;
    var current = true;
    final pending = harness.authority.applyBehavior(
      gaze: const AvatarGaze(eyeX: 0.2, eyeY: 0, headX: 0, headY: 0),
      bodyGesture: 'wave',
      duration: const Duration(milliseconds: 1200),
      bodyDuration: const Duration(milliseconds: 2500),
      shouldContinue: () => current,
    );
    await harness.sink.waitUntilHeld();
    current = false;
    harness.sink.completeHeld();

    expect((await pending).applied, isFalse);
    await _flush(harness.authority);
    final body = harness.sink.applied.where(
      (dispatch) => dispatch.channel == AvatarCommandChannel.bodyGesture,
    );
    expect(body, hasLength(2));
    expect((body.first.command! as AvatarBodyGestureCommand).gesture, 'wave');
    expect(body.last.clearsChannel, isTrue);
    expect(
      harness.sink.applied
          .where((dispatch) => dispatch.channel == AvatarCommandChannel.gaze)
          .last
          .clearsChannel,
      isTrue,
    );
    expect(
      (await harness.authority.applyBehavior(
        clearGaze: true,
        bodyGesture: 'listen',
        duration: const Duration(milliseconds: 1200),
      )).applied,
      isTrue,
      reason: 'cancelled gaze ownership cannot leave a stale adapter lease',
    );
  });

  test(
    'body-only extension retains the existing five-second ceiling',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
      harness.sink.operations.clear();
      expect(
        (await harness.authority.applyBehavior(
          bodyGesture: 'wave',
          duration: const Duration(milliseconds: 1200),
          bodyDuration: const Duration(days: 1),
        )).applied,
        isTrue,
      );
      final bodyOperation = harness.sink.operations.singleWhere(
        (operation) => operation.dispatch.command is AvatarBodyGestureCommand,
      );
      expect(
        bodyOperation.validUntil!
            .difference(harness.sink.operationTimes[bodyOperation]!)
            .inMilliseconds,
        inInclusiveRange(4950, 5000),
      );
    },
  );

  test(
    'director enforce route never calls animation IK or motion APIs',
    () async {
      final harness = await _Harness.create(mode: FeatureRolloutMode.enforce);
      harness.renderer.calls.clear();
      harness.sink.applied.clear();
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => harness.renderer,
        emitEmotion: (intent) => EventBus().fire(
          EmotionStateEvent(
            intent.params,
            semanticLabel: intent.label,
            agentId: intent.agentId,
          ),
        ),
      );

      final result = await director.applyAct(
        const AvatarAct(
          mood: 'happy',
          gesture: 'wave',
          gaze: 'user',
          posture: 'step_forward',
        ),
      );
      await _flush(harness.authority);

      expect(result.applied, isTrue);
      expect(harness.renderer.calls, isEmpty);
      expect(
        harness.sink.applied.map((dispatch) => dispatch.channel),
        containsAll(<AvatarCommandChannel>[
          AvatarCommandChannel.expression,
          AvatarCommandChannel.gaze,
          AvatarCommandChannel.bodyGesture,
        ]),
      );
      expect(
        harness.sink.applied
            .where((dispatch) => dispatch.command is AvatarBodyGestureCommand)
            .map(
              (dispatch) =>
                  (dispatch.command! as AvatarBodyGestureCommand).gesture,
            ),
        ['wave'],
      );

      harness.sink.applied.clear();
      await expectLater(
        director.applyRequiredAct(
          const AvatarAct(mood: 'happy', gesture: 'tease', gaze: 'user'),
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'avatar_capability_unavailable',
          ),
        ),
      );
      await _flush(harness.authority);
      expect(harness.sink.applied, isEmpty);

      await expectLater(
        director.applyRequiredReaction(
          const AvatarReaction(mood: 'happy', gesture: 'tease', gaze: 'user'),
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'avatar_capability_unavailable',
          ),
        ),
      );
      await _flush(harness.authority);
      expect(harness.sink.applied, isEmpty);
    },
  );

  test(
    'required mood-only actions fail closed while renderer is unready',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        ready: false,
      );
      var moodEmissions = 0;
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => harness.renderer,
        emitEmotion: (_) => moodEmissions += 1,
      );

      await expectLater(
        director.applyRequiredAct(const AvatarAct(mood: 'sad')),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'not_ready',
          ),
        ),
      );
      await expectLater(
        director.applyRequiredReaction(const AvatarReaction(mood: 'angry')),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'not_ready',
          ),
        ),
      );
      await _flush(harness.authority);

      expect(moodEmissions, 0);
      expect(harness.sink.applied, isEmpty);
      expect(harness.renderer.calls, isEmpty);
    },
  );

  test(
    'Unity enforce admits ticket transport and keeps legacy cache clean',
    () async {
      final flags = await _productionFlags();
      final transport = _AckingUnityTransport();
      final runtime = UnityAvatarRuntime(transport: transport);
      final active = ActiveAvatarRuntime()..register(runtime);
      appServices.put(active);
      await transport.emit(const MethodCall('ready'));
      transport.calls.clear();
      final authority = AvatarProjectionProductionAuthority(
        accountGeneration: 20,
        featureFlags: flags,
        activeAvatarRuntime: active,
        renderer: runtime,
        dispatchSink: runtime.commandDispatchSink,
        mountIsCurrent: () => true,
      );
      appServices.put(authority);
      await _flush(authority);
      expect(authority.phase, AvatarProductionAuthorityPhase.enforcing);
      transport.calls.clear();

      await runtime.setExpressionParams(const AvatarExpressionParams(happy: 1));
      await runtime.setMouthOpen(0.8);
      await (active.current! as AvatarScreenAttentionRuntime).reactToScreenTap(
        normalizedX: .9,
        normalizedY: .3,
      );
      await expectLater(
        runtime.playPrimitive('wave'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'avatar_authority_owned',
          ),
        ),
      );
      await expectLater(
        runtime.playAnimationClip('legacy-clip'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'avatar_authority_owned',
          ),
        ),
      );
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.love,
          semanticLabel: 'love',
          agentId: 'self',
        ),
      );
      await _flush(authority);
      await runtime.setWorldLighting(AvatarWorldLighting.day);

      final methods = transport.calls.map((call) => call.method).toList();
      expect(methods, isNot(contains('setExpression')));
      expect(methods, isNot(contains('setMouthOpen')));
      expect(methods, isNot(contains('reactToScreenTap')));
      expect(methods, isNot(contains('playPrimitive')));
      expect(methods, isNot(contains('playAnimationClip')));
      expect(methods, contains(UnityAvatarCommandDispatchSink.commandMethod));
      expect(methods, contains('setWorldTimeOfDay'));

      flags.setRuntimeMaximum(
        MaasoFeatureFlag.avatarProjectionV2,
        FeatureRolloutMode.off,
      );
      await _flush(authority);
      transport.calls.clear();
      await transport.emit(
        const MethodCall('unready', <String, Object?>{'reason': 'test'}),
      );
      await _flush(authority);
      await transport.emit(const MethodCall('ready'));
      await _flush(authority);

      final replay = transport.calls.lastWhere(
        (call) => call.method == 'setExpression',
      );
      final replayParams = Map<String, Object?>.from(
        replay.arguments! as Map<Object?, Object?>,
      );
      expect(replayParams['happy'], 0);
    },
  );

  test('main mount and drain source keeps Avatar authority ordering', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final runtimeSource = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();
    final mount = mainSource.indexOf('AvatarProjectionProductionAuthority(');
    final bridge = mainSource.indexOf('putOwned(SelfAvatarBridge())');
    final drain = mainSource.indexOf("'avatar_projection_authority'");
    final flags = mainSource.indexOf("'feature_flags'");
    final reset = mainSource.indexOf("'avatar_reset'");

    expect(mount, greaterThanOrEqualTo(0));
    expect(bridge, greaterThan(mount));
    expect(drain, greaterThanOrEqualTo(0));
    expect(flags, greaterThan(drain));
    expect(reset, greaterThan(flags));
    final resetBody = mainSource.substring(reset);
    final resetCall = resetBody.indexOf('resetAvatarForAccountBoundary(');
    final awaitedDrains = RegExp(
      r'await\s+Future\.wait<void>\(\s*<Future<void>>\[(.*?)\]',
      dotAll: true,
    ).firstMatch(resetBody);
    expect(resetCall, greaterThanOrEqualTo(0));
    expect(awaitedDrains, isNotNull);
    expect(awaitedDrains!.end, lessThan(resetCall));
    for (final requiredDrain in <String>[
      'avatarOwnershipDrain',
      'runtimeDrain',
      'ttsDrain',
    ]) {
      expect(awaitedDrains.group(1), matches(RegExp('\\b$requiredDrain\\b')));
    }
    expect(
      runtimeSource,
      contains(
        'if (avatar.isReady.value && '
        '!AvatarProductionOwnership.ownsRenderer)',
      ),
    );
    expect(
      runtimeSource,
      contains('if (ready && !AvatarProductionOwnership.ownsRenderer)'),
    );
  });
}

Future<void> _flush(AvatarProjectionProductionAuthority authority) async {
  for (var attempt = 0; attempt < 4; attempt++) {
    authority.phase;
    await Future<void>.delayed(Duration.zero);
    await authority.waitForIdle();
  }
}

final class _PausedGazeHandler implements AvatarGazeIntentHandler {
  final started = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<void> hold(AvatarGaze? gaze, {required Duration duration}) async {
    if (!started.isCompleted) {
      started.complete();
      await resume.future;
    }
  }
}

final class _Harness {
  const _Harness({
    required this.flags,
    required this.active,
    required this.renderer,
    required this.sink,
    required this.authority,
  });

  final MaasoFeatureFlagService flags;
  final ActiveAvatarRuntime active;
  final _RecordingAvatarRuntime renderer;
  final _RecordingSink sink;
  final AvatarProjectionProductionAuthority authority;

  static Future<_Harness> create({
    required FeatureRolloutMode mode,
    int accountGeneration = 1,
    bool ready = true,
    _RecordingSink? sink,
    _RecordingAvatarRuntime? renderer,
    ActiveAvatarRuntime? active,
    bool Function()? cameraFramingIsManaged,
  }) async {
    final flags = await _productionFlags();
    if (mode != FeatureRolloutMode.enforce) {
      flags.setRuntimeMaximum(MaasoFeatureFlag.avatarProjectionV2, mode);
    }

    final concreteSink = sink ?? _RecordingSink();
    final concreteRenderer = renderer ?? _RecordingAvatarRuntime(ready: ready);
    final activeRuntime = active ?? ActiveAvatarRuntime();
    if (activeRuntime.current == null) activeRuntime.register(concreteRenderer);
    if (!appServices.isRegistered<ActiveAvatarRuntime>()) {
      appServices.put(activeRuntime);
    }
    final authority = AvatarProjectionProductionAuthority(
      accountGeneration: accountGeneration,
      featureFlags: flags,
      activeAvatarRuntime: activeRuntime,
      renderer: concreteRenderer,
      dispatchSink: concreteSink,
      mountIsCurrent: () => true,
      cameraFramingIsManaged: cameraFramingIsManaged,
    );
    appServices.put(authority);
    final harness = _Harness(
      flags: flags,
      active: activeRuntime,
      renderer: concreteRenderer,
      sink: concreteSink,
      authority: authority,
    );
    await _flush(authority);
    return harness;
  }

  Future<void> setMode(FeatureRolloutMode mode) async {
    flags.setRuntimeMaximum(MaasoFeatureFlag.avatarProjectionV2, mode);
    await _flush(authority);
  }
}

Future<MaasoFeatureFlagService> _productionFlags() async {
  final flags = await MaasoFeatureFlagService(
    store: _MemoryFeatureFlagStore(),
    compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
      MaasoFeatureFlag.avatarProjectionV2: FeatureRolloutMode.enforce,
    },
  ).init();
  await flags.assign(
    flag: MaasoFeatureFlag.avatarProjectionV2,
    mode: FeatureRolloutMode.enforce,
    revision: 1,
    expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
  );
  return flags;
}

final class _MemoryFeatureFlagStore implements MaasoFeatureFlagAssignmentStore {
  final Map<MaasoFeatureFlag, Map<String, Object?>> _rows =
      <MaasoFeatureFlag, Map<String, Object?>>{};

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      _rows.values.map(Map<String, Object?>.from).toList(growable: false);

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    _rows[assignment.flag] = assignment.toJson();
  }
}

final class _RecordingSink implements AvatarCommandDispatchSink {
  final operations = <AvatarCommandDispatchOperation>[];
  final operationTimes = <AvatarCommandDispatchOperation, DateTime>{};
  final List<AvatarCommandDispatch> applied = <AvatarCommandDispatch>[];
  final List<AvatarRendererResetOperation> resetOperations =
      <AvatarRendererResetOperation>[];
  final List<int> resetMutations = <int>[];
  bool failNextReset = false;
  bool failNextFraming = false;
  bool holdNextMutation = false;
  bool holdNextBodyMutation = false;
  AvatarCommandDispatchOperation? _heldOperation;
  AvatarCommandDispatchReceipt? _heldReceipt;
  Completer<AvatarCommandDispatchReceipt>? _heldCompleter;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    operations.add(operation);
    operationTimes[operation] = DateTime.now();
    if (failNextFraming && operation.dispatch.command is AvatarFramingCommand) {
      failNextFraming = false;
      throw StateError('framing_not_supported_by_renderer');
    }
    if ((holdNextMutation ||
            (holdNextBodyMutation &&
                operation.dispatch.command is AvatarBodyGestureCommand)) &&
        !operation.dispatch.clearsChannel) {
      holdNextMutation = false;
      holdNextBodyMutation = false;
      _heldOperation = operation;
      _heldReceipt = operation.applyIfCurrent(applied.add);
      if (_heldReceipt == null) throw StateError('dispatch_stale');
      final completer = Completer<AvatarCommandDispatchReceipt>();
      _heldCompleter = completer;
      return completer.future;
    }
    final receipt = operation.applyIfCurrent(applied.add);
    if (receipt == null) throw StateError('dispatch_stale');
    return receipt;
  }

  Future<void> waitUntilHeld() async {
    for (var attempt = 0; attempt < 100 && _heldOperation == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(_heldOperation, isNotNull);
  }

  void completeHeld() {
    final completer = _heldCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(_heldReceipt!);
    }
  }

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async {
    resetOperations.add(operation);
    if (failNextReset) {
      failNextReset = false;
      operation.resetOrDisposeIfCurrent(() {
        throw StateError('reset_failed');
      });
      throw StateError('reset_failed');
    }
    final receipt = operation.resetOrDisposeIfCurrent(
      () => resetMutations.add(operation.requirementId),
    );
    if (receipt == null) throw StateError('reset_stale');
    return receipt;
  }
}

final class _RecordingAvatarRuntime extends AvatarRuntime {
  _RecordingAvatarRuntime({required bool ready}) : isReady = ready.obs;

  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;

  @override
  final RxBool isReady;

  final List<String> calls = <String>[];
  final expressions = <AvatarExpressionParams>[];

  @override
  Future<void> clearGaze() async => calls.add('clearGaze');

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const <String, dynamic>{},
  ]) async => calls.add('loadAvatar');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async => calls.add('animation');

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async =>
      calls.add('motion');

  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) async =>
      calls.add('motionSequence');

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async =>
      calls.add('primitive');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async => calls.add('bodyPose');

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {
    calls.add('expression');
    expressions.add(params);
  }

  @override
  Future<void> setFraming(String mode) async => calls.add('framing');

  @override
  Future<void> setGaze(AvatarGaze gaze) async => calls.add('gaze');

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async => calls.add('handIk');

  @override
  Future<void> setMouthOpen(double value) async => calls.add('mouth');

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async =>
      calls.add('safeArea');

  @override
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async => calls.add('lipEnvelope');

  @override
  Future<void> stopLipSync() async => calls.add('stopLipSync');
}

final class _AckingUnityTransport implements UnityAvatarTransport {
  final List<MethodCall> calls = <MethodCall>[];
  UnityAvatarMethodCallHandler? _handler;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    final call = MethodCall(method, arguments);
    calls.add(call);
    if (method == UnityAvatarCommandDispatchSink.commandMethod ||
        method == UnityAvatarCommandDispatchSink.resetMethod) {
      final payload = Map<String, dynamic>.from(
        arguments! as Map<Object?, Object?>,
      )..remove('payloadJson');
      scheduleMicrotask(
        () => _handler?.call(
          MethodCall('commandResult', <String, dynamic>{
            ...payload,
            'method': method,
            'ok': true,
            'code': '',
          }),
        ),
      );
    }
    return null;
  }

  Future<dynamic> emit(MethodCall call) {
    final handler = _handler;
    if (handler == null) throw StateError('unity_handler_missing');
    return handler(call);
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {
    _handler = handler;
  }

  @override
  void dispose() {
    _handler = null;
  }
}
