import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_animation_catalog.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_protection.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/emotion_to_avatar.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(appServices.reset);

  for (final mood in ['calm', 'thinking', 'serious']) {
    test(
      'explicit none keeps $mood body still while omitted gesture infers',
      () async {
        final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
        final emotions = <AvatarEmotionIntent>[];
        final director = AvatarBehaviorDirector(
          runtimeProvider: () => runtime,
          emitEmotion: emotions.add,
        );
        final explicitNone = AvatarAct.fromJson({
          'mood': mood,
          'gesture': 'none',
          'gaze': 'user',
        });
        expect(explicitNone.inferGesture, isFalse);
        expect((await director.applyAct(explicitNone)).applied, isTrue);
        expect(emotions.single.label, mood);
        expect(runtime.gaze, isNotNull);
        expect(runtime.primitiveType, isNull);
        expect(runtime.clipId, isNull);
        final omitted = AvatarAct.fromJson({'mood': mood});
        expect(omitted.inferGesture, isTrue);
        await director.applyAct(omitted);
        expect(runtime.primitiveType, isNotNull);
      },
    );
  }

  test(
    'explicit expression blocks ambient face body and gaze until expiry',
    () async {
      var now = DateTime(2026, 9, 2, 12);
      final protection = appServices.put(
        AvatarBehaviorProtection(now: () => now),
      );
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final emotions = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => runtime,
        emitEmotion: emotions.add,
      );
      final explicit = director.applyReaction(
        const AvatarReaction(
          mood: 'serious',
          gesture: 'wave',
          gaze: 'user',
          durationMs: 1500,
        ),
      );
      final blocked = await director.applyAct(
        const AvatarAct(mood: 'calm', gesture: 'listen', gaze: 'down'),
        ambient: true,
      );
      expect((await explicit).applied, isTrue);
      expect(blocked.applied, isFalse);
      expect(emotions.map((event) => event.label), ['serious']);
      expect(runtime.primitiveType, 'wave');
      expect(runtime.gaze?.headY, 0);

      now = now.add(const Duration(milliseconds: 1500));
      final resumed = await director.applyAct(
        const AvatarAct(mood: 'calm', gesture: 'listen', gaze: 'down'),
        ambient: true,
      );
      expect(resumed.applied, isTrue);
      expect(emotions.last.label, 'calm');
      expect(runtime.primitiveType, 'listen');
      expect(runtime.gaze?.headY, lessThan(0));
      expect(protection.isProtected('self'), isFalse);
    },
  );

  test(
    'renderer failure and empty intent do not retain explicit protection',
    () async {
      final protection = appServices.put(AvatarBehaviorProtection());
      final failed = AvatarBehaviorDirector(
        runtimeProvider: () => _RecordingAvatarRuntime(
          AvatarBackendKind.unity,
          transientError: PlatformException(code: 'not_ready'),
        ),
      );
      expect(
        (await failed.applyAct(const AvatarAct(gesture: 'wave'))).applied,
        isFalse,
      );
      expect(protection.isProtected('self'), isFalse);

      final empty = AvatarBehaviorDirector(runtimeProvider: () => null);
      expect(
        (await empty.applyReaction(const AvatarReaction())).applied,
        isFalse,
      );
      expect(protection.isProtected('self'), isFalse);
    },
  );

  test(
    'unknown legacy gesture can at most hold the bounded expression window',
    () async {
      var now = DateTime(2026, 9, 2, 12);
      final protection = appServices.put(
        AvatarBehaviorProtection(now: () => now),
      );
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => _RecordingAvatarRuntime(AvatarBackendKind.unity),
      );
      await director.applyReaction(
        const AvatarReaction(gesture: 'custom_unknown', durationMs: 100000),
      );
      now = now.add(const Duration(seconds: 5));
      expect(protection.isProtected('self'), isFalse);
    },
  );

  test('common moods remain restrained and serious does not smile', () {
    final calm = emotionToAvatarParams(EmotionParams.calm.scaled(0.65));
    final comfort = emotionToAvatarParams(
      EmotionParams.comforting.scaled(0.65),
    );
    final serious = emotionToAvatarParams(EmotionParams.serious.scaled(0.65));
    expect(calm.happy, 0);
    expect(comfort.happy, 0);
    expect(comfort.mouthSmile, 0);
    expect(comfort.browConcern, greaterThan(calm.browConcern));
    expect(serious.happy, 0);
    expect(serious.mouthSmile, 0);
    expect(serious.mouthOpen, 0);
    expect(emotionToAvatarParams(EmotionParams.neutral).happy, 0);
  });

  test(
    'reaction can suppress only emotion while preserving mood-driven body',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final emotions = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => runtime,
        emitEmotion: emotions.add,
      );
      final result = await director.applyReaction(
        AvatarReaction.fromJson({
          'mood': 'excited',
          'gaze': 'user',
          'emitMood': false,
        }),
      );
      expect(result.applied, isTrue);
      expect(result.mood, 'excited');
      expect(runtime.primitiveType, 'cheer');
      expect(runtime.gaze, isNotNull);
      expect(emotions, isEmpty);
    },
  );

  test('act and reaction emit their own bounded cue duration', () async {
    final emotions = <AvatarEmotionIntent>[];
    final director = AvatarBehaviorDirector(emitEmotion: emotions.add);
    await director.applyAct(const AvatarAct(mood: 'calm', durationMs: 1800));
    await director.applyReaction(
      const AvatarReaction(mood: 'comforting', durationMs: 900),
    );
    expect(emotions.map((event) => event.duration), <Duration>[
      const Duration(milliseconds: 1800),
      const Duration(milliseconds: 900),
    ]);
  });

  test(
    'explicit avatar reaction drives mood, gesture, gaze, and intensity',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final emotions = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => runtime,
        emitEmotion: emotions.add,
      );

      final result = await director.applyReaction(
        AvatarReaction.fromJson({
          'mood': 'playful',
          'gesture': 'wink',
          'gaze': 'user',
          'style': 'dramatic',
          'intensity': 0.8,
          'durationMs': 1200,
        }),
      );

      expect(result.applied, isTrue);
      expect(emotions.single.label, 'playful');
      expect(emotions.single.intensity, 0.8);
      expect(runtime.primitiveType, 'wink');
      expect(runtime.primitiveOpts?['durationMs'], 1200);
      expect(runtime.primitiveOpts?['amplitude'], greaterThan(0.8));
      expect(runtime.gaze?.headX, 0);
      expect(runtime.gaze?.headY, 0);
    },
  );

  test(
    'auto reaction supplies a thinking gesture for spoken thinking turns',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final director = AvatarBehaviorDirector(
        animationCatalog: AvatarAnimationCatalog(const []),
        runtimeProvider: () => runtime,
      );

      final result = await director.autoReact(
        const AvatarAutoReactionContext(
          reply: '我先捋一下这个问题。',
          voiceText: '我先捋一下这个问题。',
          emotionLabel: 'thinking',
          actionTypes: {'emotion.set', 'voice.speak'},
        ),
      );

      expect(result.applied, isTrue);
      expect(runtime.primitiveType, 'think');
      expect(runtime.primitiveOpts?['durationMs'], greaterThanOrEqualTo(900));
    },
  );

  test('auto reaction exposes a scene-aware thinking plan', () {
    final director = AvatarBehaviorDirector();

    final plan = director.planAutoReaction(
      const AvatarAutoReactionContext(
        reply: '我先捋一下这个问题。',
        voiceText: '我先捋一下这个问题。',
        emotionLabel: 'thinking',
        actionTypes: {'emotion.set', 'voice.speak'},
      ),
    );

    expect(plan.kind, AvatarBehaviorPlanKind.act);
    expect(plan.scenario, 'thinking');
    expect(plan.mood, 'thinking');
    expect(plan.gesture, 'think');
    expect(plan.gaze, 'down');
    expect(plan.style, 'subtle');
    expect(plan.emitMood, isFalse);
  });

  test(
    'auto reaction showcases generated game surfaces without duplicate emotion',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final emotions = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(
        animationCatalog: AvatarAnimationCatalog(const []),
        runtimeProvider: () => runtime,
        emitEmotion: emotions.add,
      );

      const context = AvatarAutoReactionContext(
        reply: '雷霆战机做好了，点击开始就能玩。',
        voiceText: '雷霆战机做好了。',
        emotionLabel: 'excited',
        actionTypes: {'emotion.set', 'voice.speak', 'surface.show'},
      );
      final plan = director.planAutoReaction(context);

      expect(plan.kind, AvatarBehaviorPlanKind.act);
      expect(plan.scenario, 'game_showcase');
      expect(plan.mood, 'excited');
      expect(plan.gesture, 'explain');
      expect(plan.gaze, 'surface');
      expect(plan.intensity, greaterThanOrEqualTo(0.68));
      expect(plan.emitMood, isFalse);

      final result = await director.autoReact(context);

      expect(result.applied, isTrue);
      expect(emotions, isEmpty);
      expect(runtime.handIkTarget, 'explain');
      expect(runtime.primitiveType, 'nod');
      expect(runtime.gaze?.headX, greaterThan(0));
    },
  );

  test(
    'auto reaction stays silent when the agent already controlled motion',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final director = AvatarBehaviorDirector(runtimeProvider: () => runtime);

      final result = await director.autoReact(
        const AvatarAutoReactionContext(
          reply: '交给我。',
          voiceText: '交给我。',
          emotionLabel: 'excited',
          actionTypes: {'emotion.set', 'voice.speak', 'avatar.react'},
        ),
      );

      expect(result.applied, isFalse);
      expect(runtime.primitiveType, isNull);
    },
  );

  test(
    'semantic avatar act maps explain intent to gaze and hand target',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final emotions = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(
        animationCatalog: AvatarAnimationCatalog(const []),
        runtimeProvider: () => runtime,
        emitEmotion: emotions.add,
      );

      final result = await director.applyAct(
        AvatarAct.fromJson({
          'mood': 'thinking',
          'gesture': 'explain',
          'gaze': 'user',
          'style': 'subtle',
          'intensity': 0.7,
          'durationMs': 1500,
        }),
      );

      expect(result.applied, isTrue);
      expect(result.mood, 'thinking');
      expect(emotions.single.label, 'thinking');
      expect(runtime.handIkTarget, 'explain');
      expect(runtime.handIkOpts?['durationMs'], 1500);
      expect(runtime.handIkOpts?['intensity'], 0.7);
      expect(runtime.primitiveType, 'nod');
      expect(runtime.gaze?.headX, 0);
    },
  );

  test('temporary behavior gaze uses the registered lease handler', () async {
    final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
    final gazeHandler = _RecordingGazeIntentHandler();
    appServices.put<AvatarGazeIntentHandler>(gazeHandler);
    final director = AvatarBehaviorDirector(runtimeProvider: () => runtime);

    final result = await director.applyAct(
      const AvatarAct(gesture: 'explain', gaze: 'surface', durationMs: 1750),
    );

    expect(result.applied, isTrue);
    expect(gazeHandler.gazes.single?.headX, closeTo(0.25, 1e-9));
    expect(gazeHandler.gazes.single?.headRoll, closeTo(-0.07, 1e-9));
    expect(gazeHandler.gazes.single?.upperBodyX, closeTo(0.25, 1e-9));
    expect(gazeHandler.durations.single, const Duration(milliseconds: 1750));
    expect(runtime.gaze, isNull);
  });

  test('unknown behavior gaze cancels only the behavior lease', () async {
    final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
    final gazeHandler = _RecordingGazeIntentHandler();
    appServices.put<AvatarGazeIntentHandler>(gazeHandler);
    final director = AvatarBehaviorDirector(runtimeProvider: () => runtime);

    await director.applyReaction(
      const AvatarReaction(gaze: 'unsupported', durationMs: 900),
    );

    expect(gazeHandler.gazes, [isNull]);
    expect(gazeHandler.durations, [const Duration(milliseconds: 900)]);
    expect(runtime.gaze, isNull);
  });

  test(
    'semantic wave uses hand IK and primitive when no imported clip exists',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final director = AvatarBehaviorDirector(
        animationCatalog: AvatarAnimationCatalog(const []),
        runtimeProvider: () => runtime,
      );

      final result = await director.applyAct(
        AvatarAct.fromJson({
          'mood': 'happy',
          'gesture': 'wave',
          'gaze': 'user',
          'intensity': 0.8,
          'durationMs': 1600,
        }),
      );

      expect(result.applied, isTrue);
      expect(runtime.clipId, isNull);
      expect(runtime.primitiveType, 'wave');
      expect(runtime.handIkTarget, 'wave');
    },
  );

  test(
    'bundled semantic wave plays the imported clip without duplicate IK',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final director = AvatarBehaviorDirector(runtimeProvider: () => runtime);
      final result = await director.applyAct(
        const AvatarAct(gesture: 'wave', gaze: 'user', durationMs: 1600),
      );

      expect(result.applied, isTrue);
      expect(runtime.clipId, 'annie_wave');
      expect(runtime.clipOpts?['durationMs'], 1600);
      expect(runtime.primitiveType, isNull);
      expect(runtime.handIkTarget, isNull);
      expect(runtime.gaze, isNotNull);
    },
  );

  test('automatic imported clip obeys the same gesture cooldown', () async {
    var now = DateTime(2026, 10, 15, 12);
    final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
    final director = AvatarBehaviorDirector(
      runtimeProvider: () => runtime,
      now: () => now,
    );
    const context = AvatarAutoReactionContext(
      reply: 'Let me think.',
      emotionLabel: 'thinking',
    );

    await director.autoReact(context);
    await director.autoReact(context);
    expect(runtime.clipHistory, ['annie_think']);
    expect(runtime.gaze, isNotNull);
    expect(runtime.primitiveHistory, isEmpty);

    now = now.add(const Duration(seconds: 4));
    await director.autoReact(context);
    expect(runtime.clipHistory, ['annie_think', 'annie_think']);
  });

  test(
    'unity semantic jump falls back to primitive when no imported clip exists',
    () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final director = AvatarBehaviorDirector(runtimeProvider: () => runtime);

      final result = await director.applyAct(
        AvatarAct.fromJson({
          'mood': 'excited',
          'gesture': 'jump',
          'gaze': 'user',
          'intensity': 0.8,
          'durationMs': 1600,
        }),
      );

      expect(result.applied, isTrue);
      expect(runtime.clipId, isNull);
      expect(runtime.primitiveType, 'jump');
      expect(runtime.handIkTarget, isNull);
    },
  );

  test('automatic act degrades while the renderer is loading', () async {
    final runtime = _RecordingAvatarRuntime(
      AvatarBackendKind.unity,
      transientError: PlatformException(
        code: 'not_ready',
        message: 'Unity WebGL is loading',
      ),
    );
    final director = AvatarBehaviorDirector(runtimeProvider: () => runtime);

    final result = await director.autoReact(
      const AvatarAutoReactionContext(
        reply: '我先想一下。',
        voiceText: '我先想一下。',
        emotionLabel: 'thinking',
      ),
    );

    expect(result.applied, isFalse);
    expect(result.reason, AvatarBehaviorDirector.rendererNotReadyReason);
  });

  test(
    'automatic gesture cooldown keeps gaze without replaying the body',
    () async {
      var now = DateTime(2026, 9, 23, 12);
      var runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final director = AvatarBehaviorDirector(
        animationCatalog: AvatarAnimationCatalog(const []),
        runtimeProvider: () => runtime,
        now: () => now,
      );
      const context = AvatarAutoReactionContext(
        reply: '我先想一想。',
        emotionLabel: 'thinking',
      );

      expect((await director.autoReact(context)).applied, isTrue);
      expect(runtime.primitiveHistory, ['think']);
      expect((await director.autoReact(context)).applied, isTrue);
      expect(runtime.primitiveHistory, ['think']);
      expect(runtime.gaze, isNotNull);

      now = now.add(const Duration(seconds: 4));
      await director.autoReact(context);
      expect(runtime.primitiveHistory, ['think', 'think']);

      runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      await director.autoReact(context);
      expect(runtime.primitiveHistory, [
        'think',
      ], reason: 'a replaced renderer gets a fresh bounded cue');
      director.resetAutoBehavior();
      await director.autoReact(context);
      expect(runtime.primitiveHistory, ['think', 'think']);
    },
  );

  test(
    'real conversation phases are distinct, idempotent and ambient',
    () async {
      var now = DateTime(2026, 9, 23, 12);
      final protection = appServices.put(
        AvatarBehaviorProtection(now: () => now),
      );
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final director = AvatarBehaviorDirector(
        animationCatalog: AvatarAnimationCatalog(const []),
        runtimeProvider: () => runtime,
      );

      expect(
        (await director.reactToConversationPhase(
          AvatarConversationPhase.listening,
        )).applied,
        isTrue,
      );
      expect(runtime.primitiveHistory, ['listen']);
      expect(
        (await director.reactToConversationPhase(
          AvatarConversationPhase.stopped,
        )).applied,
        isFalse,
        reason: 'TTS stop cannot interrupt user speech',
      );
      await director.reactToConversationPhase(AvatarConversationPhase.thinking);
      await director.reactToConversationPhase(AvatarConversationPhase.speaking);
      expect(runtime.primitiveHistory, ['listen', 'think', 'nod']);
      expect(runtime.handIkTarget, 'explain');
      expect(
        (await director.reactToConversationPhase(
          AvatarConversationPhase.speaking,
        )).applied,
        isFalse,
      );
      await director.reactToConversationPhase(AvatarConversationPhase.stopped);
      expect(runtime.primitiveHistory, [
        'listen',
        'think',
        'nod',
      ], reason: 'stop is a gaze cue, not a new mouth or body command');

      await director.applyReaction(const AvatarReaction(gesture: 'wave'));
      expect(protection.isProtected('self'), isTrue);
      expect(
        (await director.reactToConversationPhase(
          AvatarConversationPhase.speaking,
        )).applied,
        isFalse,
        reason: 'explicit Avatar command wins',
      );
      now = now.add(const Duration(seconds: 2));
      expect(
        (await director.reactToConversationPhase(
          AvatarConversationPhase.speaking,
        )).applied,
        isTrue,
      );
    },
  );

  test(
    'native phase hints never wait or schedule a fixed speech body clip',
    () async {
      final nativeGate = Completer<void>();
      final runtime = _PhaseAvatarRuntime(gate: nativeGate.future);
      final director = AvatarBehaviorDirector(runtimeProvider: () => runtime);
      final listening = await director
          .reactToConversationPhase(AvatarConversationPhase.listening)
          .timeout(const Duration(milliseconds: 100));
      expect(
        listening.applied,
        true,
        reason: 'native scheduling cannot block the response path',
      );
      await director.reactToConversationPhase(
        AvatarConversationPhase.listening,
      );
      await director.reactToConversationPhase(AvatarConversationPhase.stopped);
      await director.reactToConversationPhase(AvatarConversationPhase.speaking);
      expect(runtime.phases.map((e) => e.$1), [
        'listening',
      ], reason: 'duplicates and TTS while user speaks are suppressed');
      await director.reactToConversationPhase(AvatarConversationPhase.thinking);
      await director.reactToConversationPhase(AvatarConversationPhase.speaking);
      await director.reactToConversationPhase(AvatarConversationPhase.stopped);
      expect(runtime.phases.map((e) => e.$1), [
        'listening',
        'thinking',
        'speaking',
        'stopped',
      ]);
      final sequences = runtime.phases.map((e) => e.$2).toList();
      expect(sequences.every((sequence) => sequence > 0), true);
      for (var i = 1; i < sequences.length; i++) {
        expect(sequences[i], greaterThan(sequences[i - 1]));
      }
      expect(runtime.primitiveHistory, isEmpty);
      expect(runtime.clipHistory, isEmpty);
      expect(runtime.handIkTarget, isNull);
      expect(
        runtime.gaze,
        isNotNull,
        reason: 'face/gaze still follows real phases',
      );
      nativeGate.complete();
      await pumpEventQueue();
    },
  );

  test(
    'optional phase errors preserve face/gaze and unready renderer fallback',
    () async {
      final failed = _PhaseAvatarRuntime(fail: true);
      final director = AvatarBehaviorDirector(runtimeProvider: () => failed);
      expect(
        (await director.reactToConversationPhase(
          AvatarConversationPhase.speaking,
        )).applied,
        true,
      );
      await pumpEventQueue();
      expect(failed.phases.single.$1, 'speaking');
      expect(failed.primitiveHistory, isEmpty);
      final loading = _PhaseAvatarRuntime()..isReady.value = false;
      final fallback = AvatarBehaviorDirector(
        animationCatalog: AvatarAnimationCatalog(const []),
        runtimeProvider: () => loading,
      );
      await fallback.reactToConversationPhase(AvatarConversationPhase.thinking);
      expect(loading.phases, isEmpty);
      expect(loading.primitiveHistory, ['think']);
    },
  );

  test('required act reports renderer loading to the action boundary', () {
    final runtime = _RecordingAvatarRuntime(
      AvatarBackendKind.unity,
      transientError: PlatformException(
        code: 'not_ready',
        message: 'Unity WebGL is loading',
      ),
    );
    final director = AvatarBehaviorDirector(runtimeProvider: () => runtime);

    expect(
      () => director.applyRequiredAct(
        const AvatarAct(mood: 'thinking', gesture: 'think'),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'not_ready',
        ),
      ),
    );
  });
}

class _RecordingGazeIntentHandler implements AvatarGazeIntentHandler {
  final gazes = <AvatarGaze?>[];
  final durations = <Duration>[];

  @override
  Future<void> hold(AvatarGaze? gaze, {required Duration duration}) async {
    gazes.add(gaze);
    durations.add(duration);
  }
}

class _RecordingAvatarRuntime extends AvatarRuntime {
  _RecordingAvatarRuntime(this.backendKind, {this.transientError});

  @override
  final AvatarBackendKind backendKind;
  final PlatformException? transientError;

  @override
  final isReady = false.obs;

  String? primitiveType;
  final primitiveHistory = <String>[];
  Map<String, dynamic>? primitiveOpts;
  String? motionType;
  Map<String, dynamic>? motionOpts;
  String? clipId;
  final clipHistory = <String>[];
  Map<String, dynamic>? clipOpts;
  AvatarBodyPose? bodyPose;
  AvatarGaze? gaze;
  String? handIkTarget;
  Map<String, dynamic>? handIkOpts;

  @override
  Future<void> clearGaze() async {
    gaze = null;
  }

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {
    final error = transientError;
    if (error != null) throw error;
    primitiveType = type;
    primitiveHistory.add(type);
    primitiveOpts = opts;
  }

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async {
    final error = transientError;
    if (error != null) throw error;
    clipId = id;
    clipOpts = opts;
    clipHistory.add(id);
  }

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async {
    motionType = type;
    motionOpts = opts;
  }

  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {}

  @override
  Future<void> setFraming(String mode) async {}

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async {
    handIkTarget = target;
    handIkOpts = opts;
  }

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async {
    bodyPose = pose;
  }

  @override
  Future<void> setGaze(AvatarGaze gaze) async {
    this.gaze = gaze;
  }

  @override
  Future<void> setMouthOpen(double value) async {}

  @override
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async {}

  @override
  Future<void> stopLipSync() async {}
}

final class _PhaseAvatarRuntime extends _RecordingAvatarRuntime
    implements AvatarConversationPhaseRuntime {
  _PhaseAvatarRuntime({this.gate, this.fail = false})
    : super(AvatarBackendKind.unity) {
    isReady.value = true;
  }
  final Future<void>? gate;
  final bool fail;
  final phases = <(String, int)>[];
  @override
  Future<void> setConversationPhase(String phase, {required int sequence}) {
    phases.add((phase, sequence));
    if (fail) {
      return Future<void>.error(StateError('optional phase unavailable'));
    }
    return gate ?? Future<void>.value();
  }
}
