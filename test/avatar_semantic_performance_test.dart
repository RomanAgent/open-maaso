import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/body/avatar_body_intent_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() async {
    final authority = appServices
        .maybeFind<AvatarProjectionProductionAuthority>();
    if (authority != null) await authority.sealAndDrain();
    await appServices.reset();
    AvatarProductionOwnership.resetForTest();
  });

  test(
    'enforced listening phase admits a bounded five-key body cue without gaze lock',
    () async {
      final fixture = await _EnforcedPerformanceFixture.create();
      final result = await fixture.director.reactToConversationPhase(
        AvatarConversationPhase.listening,
      );
      expect(result.applied, isTrue);
      await fixture.flush();
      final body = fixture.sink.applied
          .map((d) => d.command)
          .whereType<AvatarBodyGestureCommand>()
          .single;
      expect(body.toCanonicalJson(), {
        'channel': 'bodyGesture',
        'gesture': 'listen',
        'energy': 'gentle',
        'intensity': .3,
        'emotion': 'comforting',
      });
      expect(
        fixture.sink.applied.where(
          (d) => d.channel == AvatarCommandChannel.gaze,
        ),
        isEmpty,
      );
      expect(
        fixture.sink.applied.where(
          (d) => d.channel == AvatarCommandChannel.mouth,
        ),
        isEmpty,
      );
      expect(fixture.runtime.primitive, isNull);
    },
  );

  test(
    'enforced speaking phase uses an audio-driven profile and scoped stop retires it',
    () async {
      final fixture = await _EnforcedPerformanceFixture.create();
      expect(
        (await fixture.director.reactToConversationPhase(
          AvatarConversationPhase.speaking,
        )).applied,
        isTrue,
      );
      await fixture.flush();
      var body = fixture.sink.applied
          .map((d) => d.command)
          .whereType<AvatarBodyGestureCommand>()
          .last;
      expect(body.gesture, 'speech');
      expect(body.energy, 'gentle');
      expect(body.intensity, .36);
      expect(
        (await fixture.director.reactToConversationPhase(
          AvatarConversationPhase.stopped,
        )).applied,
        isTrue,
      );
      await fixture.flush();
      body = fixture.sink.applied
          .map((d) => d.command)
          .whereType<AvatarBodyGestureCommand>()
          .last;
      expect(body.gesture, 'speech');
      expect(body.intensity, 0);
      expect(body.emotion, 'neutral');
      expect(
        fixture.sink.applied.where(
          (d) => d.channel == AvatarCommandChannel.mouth,
        ),
        isEmpty,
      );
      expect(fixture.runtime.primitive, isNull);
    },
  );

  test('phase episode cannot displace explicit task body ownership', () async {
    final fixture = await _EnforcedPerformanceFixture.create();
    expect(
      (await fixture.authority.applyBehavior(
        bodyGesture: 'work_desk',
        duration: const Duration(seconds: 5),
      )).applied,
      isTrue,
    );
    fixture.sink.applied.clear();
    expect(
      (await fixture.director.reactToConversationPhase(
        AvatarConversationPhase.listening,
      )).applied,
      isFalse,
    );
    await fixture.flush();
    expect(fixture.sink.applied, isEmpty);
    expect(fixture.runtime.mouthWrites, 0);
  });

  test(
    'renderer scope reset prevents a stale phase stop from retiring another episode',
    () async {
      final fixture = await _EnforcedPerformanceFixture.create();
      await fixture.director.reactToConversationPhase(
        AvatarConversationPhase.speaking,
      );
      await fixture.flush();
      fixture.director.resetAutoBehavior();
      fixture.sink.applied.clear();
      await fixture.director.reactToConversationPhase(
        AvatarConversationPhase.stopped,
      );
      await fixture.flush();
      expect(
        fixture.sink.applied
            .map((d) => d.command)
            .whereType<AvatarBodyGestureCommand>(),
        isEmpty,
      );
    },
  );

  test(
    'published and sideband body policy preserves bounded semantic energy',
    () {
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
        final normalized = AvatarBodyIntentPolicy.normalize({
          'mood': 'curious',
          'gesture': gesture,
          'energy': ' HIGH ',
        });
        expect(normalized, isNotNull, reason: gesture);
        expect(normalized!['energy'], 'high');
        expect(AvatarAct.fromJson(normalized).energy, 'high');
      }
      expect(
        AvatarBodyIntentPolicy.normalize({'energy': 'gentle'})!['energy'],
        'gentle',
      );
      expect(
        AvatarBodyIntentPolicy.normalize({'energy': 'unsupported'}),
        isNull,
      );
      expect(AvatarBodyIntentPolicy.normalize({'energy': 3}), isNull);
      expect(
        AvatarBodyIntentPolicy.normalize({
          'gesture': 'annie_g_point_r',
          'energy': 'high',
        }),
        isNull,
      );
    },
  );

  test(
    'energy changes are deduplicated separately but intensity alone remains the same beat',
    () {
      Map<String, dynamic> payload(String? energy, double intensity) =>
          AvatarBodyIntentPolicy.normalize({
            'mood': 'calm',
            'gesture': 'explain',
            'energy': energy,
            'intensity': intensity,
          })!;
      final normal = payload('moderate', .4);
      expect(
        AvatarBodyIntentPolicy.signature(normal),
        AvatarBodyIntentPolicy.signature(payload('moderate', .8)),
      );
      expect(
        AvatarBodyIntentPolicy.signature(normal),
        isNot(AvatarBodyIntentPolicy.signature(payload('high', .4))),
      );
      expect(
        AvatarBodyIntentPolicy.signature(payload(null, .4)),
        isNot(contains('energy')),
      );
    },
  );

  test('energy is optional and bounded on the existing action types', () {
    expect(AvatarAct.fromJson({'gesture': 'wave'}).energy, isNull);
    expect(AvatarReaction.fromJson({'mood': 'happy'}).energy, isNull);
    expect(AvatarAct.fromJson({'energy': ' HIGH '}).energy, 'high');
    expect(AvatarReaction.fromJson({'energy': 'gentle'}).energy, 'gentle');
    for (final bad in ['loud', '', 2, true]) {
      expect(() => AvatarAct.fromJson({'energy': bad}), throwsArgumentError);
      expect(
        () => AvatarReaction.fromJson({'energy': bad}),
        throwsArgumentError,
      );
    }
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(
        () => AvatarAct.fromJson({'energy': 'high', 'intensity': bad}),
        throwsArgumentError,
      );
      expect(
        () => AvatarReaction.fromJson({'energy': 'high', 'intensity': bad}),
        throwsArgumentError,
      );
    }
  });

  test(
    'performance payload is exactly five fields and legacy bytes stay small',
    () {
      expect(AvatarBodyGestureCommand('wave').toCanonicalJson(), {
        'channel': 'bodyGesture',
        'gesture': 'wave',
      });
      final command = AvatarBodyGestureCommand(
        'explain',
        energy: 'moderate',
        intensity: .6,
        emotion: 'thinking',
      );
      expect(command.toCanonicalJson(), {
        'channel': 'bodyGesture',
        'gesture': 'explain',
        'energy': 'moderate',
        'intensity': .6,
        'emotion': 'thinking',
      });
      expect(command.channel, AvatarCommandChannel.bodyGesture);
      expect(
        AvatarBodyGestureCommand(
          'work_desk',
          workSessionId: 'a' * 64,
          workPhase: AvatarBackgroundTaskWorkPhase.start,
        ).toCanonicalJson(),
        {
          'channel': 'bodyGesture',
          'gesture': 'work_desk',
          'workSessionId': 'a' * 64,
          'workPhase': 'start',
        },
      );
    },
  );

  test(
    'partial, nonfinite, unknown and mixed work metadata cannot dispatch',
    () {
      for (final build in <AvatarBodyGestureCommand Function()>[
        () => AvatarBodyGestureCommand('speech'),
        () => AvatarBodyGestureCommand('wave', intensity: .4),
        () => AvatarBodyGestureCommand('wave', emotion: 'happy'),
        () => AvatarBodyGestureCommand('wave', energy: 'high'),
        () => AvatarBodyGestureCommand(
          'wave',
          energy: 'loud',
          intensity: .5,
          emotion: 'happy',
        ),
        () => AvatarBodyGestureCommand(
          'wave',
          energy: 'high',
          intensity: double.nan,
          emotion: 'happy',
        ),
        () => AvatarBodyGestureCommand(
          'wave',
          energy: 'high',
          intensity: 1.1,
          emotion: 'happy',
        ),
        () => AvatarBodyGestureCommand(
          'wave',
          energy: 'high',
          intensity: .5,
          emotion: 'untrusted_face',
        ),
        () => AvatarBodyGestureCommand(
          'work_desk',
          workSessionId: 'a' * 64,
          workPhase: AvatarBackgroundTaskWorkPhase.start,
          energy: 'high',
          intensity: .5,
          emotion: 'happy',
        ),
      ]) {
        expect(build, throwsArgumentError);
      }
    },
  );

  test(
    'explicit none with energy gives a speech profile, not a cheer or clip',
    () async {
      final runtime = _PerformanceRuntime();
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => runtime,
        emitEmotion: (_) {},
      );
      for (final action in [
        AvatarAct.fromJson({
          'mood': 'excited',
          'gesture': 'none',
          'energy': 'high',
          'intensity': .8,
        }),
        AvatarReaction.fromJson({
          'mood': 'excited',
          'gesture': 'none',
          'energy': 'high',
          'intensity': .8,
        }),
      ]) {
        final result = action is AvatarAct
            ? await director.applyAct(action)
            : await director.applyReaction(action as AvatarReaction);
        expect(result.applied, isTrue);
        expect(runtime.primitive, 'speech');
        expect(runtime.options, containsPair('energy', 'high'));
        expect(runtime.options, containsPair('emotion', 'excited'));
        expect(runtime.options, containsPair('intensity', .8));
        expect(runtime.clips, isEmpty);
        expect(runtime.mouthWrites, 0);
      }
    },
  );

  test(
    'semantic energy follows the existing primitive path and derives mood aliases',
    () async {
      final runtime = _PerformanceRuntime();
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => runtime,
        emitEmotion: (_) {},
      );
      for (final pair in {
        'playful': 'happy',
        'proud': 'happy',
        'serious': 'calm',
        'sleepy': 'calm',
        'shy': 'calm',
        'thinking': 'thinking',
        'unsupported_mood': 'neutral',
      }.entries) {
        await director.applyAct(
          AvatarAct(mood: pair.key, gesture: 'explain', energy: 'moderate'),
        );
        expect(runtime.primitive, 'explain');
        expect(runtime.options, containsPair('emotion', pair.value));
        expect(runtime.options, containsPair('energy', 'moderate'));
        expect(
          runtime.clips,
          isEmpty,
          reason: 'metadata cannot be lost in a direct clip call',
        );
      }
      await director.applyReaction(const AvatarReaction(gesture: 'wave'));
      expect(runtime.options!.keys.toSet(), {'durationMs', 'amplitude'});
    },
  );

  test(
    'invalid constructor energy fails before any face or body mutation',
    () async {
      final runtime = _PerformanceRuntime();
      final faces = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => runtime,
        emitEmotion: faces.add,
      );
      await expectLater(
        director.applyAct(
          const AvatarAct(mood: 'happy', gesture: 'wave', energy: 'invalid'),
        ),
        throwsArgumentError,
      );
      expect(runtime.primitive, isNull);
      expect(faces, isEmpty);
    },
  );
}

class _PerformanceRuntime extends AvatarRuntime {
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  String? primitive;
  Map<String, dynamic>? options;
  final clips = <String>[];
  int mouthWrites = 0;
  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {
    primitive = type;
    options = opts;
  }

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async => clips.add(id);
  @override
  Future<void> setGaze(AvatarGaze gaze) async {}
  @override
  Future<void> clearGaze() async {}
  @override
  Future<void> setMouthOpen(double value) async => mouthWrites++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _EnforcedPerformanceFixture {
  _EnforcedPerformanceFixture(this.runtime, this.sink, this.authority)
    : director = AvatarBehaviorDirector(
        runtimeProvider: () => runtime,
        emitEmotion: (_) {},
      );
  final _PerformanceRuntime runtime;
  final _PerformanceSink sink;
  final AvatarProjectionProductionAuthority authority;
  final AvatarBehaviorDirector director;

  static Future<_EnforcedPerformanceFixture> create() async {
    final flags = await MaasoFeatureFlagService(
      store: _PerformanceFlags(),
      compileMaximums: const {
        MaasoFeatureFlag.avatarProjectionV2: FeatureRolloutMode.enforce,
      },
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.avatarProjectionV2,
      mode: FeatureRolloutMode.enforce,
      revision: 1,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
    );
    final runtime = _PerformanceRuntime();
    final active = ActiveAvatarRuntime()..register(runtime);
    final sink = _PerformanceSink();
    final authority = AvatarProjectionProductionAuthority(
      accountGeneration: 1,
      featureFlags: flags,
      activeAvatarRuntime: active,
      renderer: runtime,
      dispatchSink: sink,
      mountIsCurrent: () => true,
    );
    appServices.put(active);
    appServices.put(authority);
    final fixture = _EnforcedPerformanceFixture(runtime, sink, authority);
    await fixture.flush();
    sink.applied.clear();
    return fixture;
  }

  Future<void> flush() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      authority.phase;
      await Future<void>.delayed(Duration.zero);
      await authority.waitForIdle();
    }
  }
}

final class _PerformanceFlags implements MaasoFeatureFlagAssignmentStore {
  final rows = <MaasoFeatureFlag, Map<String, Object?>>{};
  @override
  Future<List<Map<String, Object?>>> readAll() async => rows.values.toList();
  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async =>
      rows[assignment.flag] = assignment.toJson();
}

final class _PerformanceSink implements AvatarCommandDispatchSink {
  final applied = <AvatarCommandDispatch>[];
  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    final receipt = operation.applyIfCurrent(applied.add);
    if (receipt == null) throw StateError('stale_performance_dispatch');
    return receipt;
  }

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async {
    final receipt = operation.resetOrDisposeIfCurrent(() {});
    if (receipt == null) throw StateError('stale_performance_reset');
    return receipt;
  }
}
