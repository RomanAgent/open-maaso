import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/self_avatar_speech_bridge.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/self_avatar_projection_service.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';
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
    await appServices.reset();
    MaasoTtsPlugin.soundEnabled.value = true;
  });

  for (final consumer in ['bridge', 'runtime']) {
    for (final viseme in [false, true]) {
      testWidgets(
        '$consumer face cue, expiry and neutral preserve active ${viseme ? "viseme" : "envelope"}',
        (tester) async {
          final avatar = _SpeechOwnedAvatar();
          final dispose = await _mountConsumer(consumer, avatar);
          addTearDown(dispose);
          EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
          await tester.pump();
          EventBus().fire(LipSyncAmplitudeEvent(.8, agentId: 'self'));
          if (viseme) {
            EventBus().fire(LipSyncVisemeTrackEvent(_track(), agentId: 'self'));
          } else {
            EventBus().fire(LipSyncEnvelopeEvent([0, .8, 0], agentId: 'self'));
          }
          await tester.pump();
          expect(avatar.activeTrack, isTrue);
          final scalarWrites = avatar.scalarWrites.length;
          final trackStarts = avatar.trackStarts;

          void expectSpeechUnchanged(String transition) {
            expect(avatar.activeTrack, isTrue, reason: transition);
            expect(
              avatar.scalarWrites,
              hasLength(scalarWrites),
              reason: transition,
            );
            expect(avatar.trackStarts, trackStarts, reason: transition);
            expect(avatar.cancelledTracks, 0, reason: transition);
            expect(avatar.expressions.last.mouthOpen, 0, reason: transition);
          }

          EventBus().fire(
            EmotionStateEvent(
              EmotionParams.happy.scaled(.4),
              semanticLabel: 'happy',
              duration: const Duration(milliseconds: 80),
              agentId: 'self',
            ),
          );
          await tester.pump();
          expect(avatar.expressions.last.happy, .4);
          expectSpeechUnchanged('face cue cannot issue a TTS scalar command');
          await tester.pump(const Duration(milliseconds: 100));
          expect(avatar.expressions.last.happy, 0);
          expectSpeechUnchanged('automatic face expiry cannot cancel speech');
          EventBus().fire(
            EmotionStateEvent(
              EmotionParams.happy.scaled(.35),
              semanticLabel: 'happy',
              duration: const Duration(milliseconds: 500),
              agentId: 'self',
            ),
          );
          await tester.pump();
          EventBus().fire(
            EmotionStateEvent(
              EmotionParams.neutral,
              semanticLabel: 'neutral',
              agentId: 'self',
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(avatar.expressions.last.happy, 0);
          expectSpeechUnchanged(
            'neutral and retired timer leave TTS track intact',
          );
          EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
          await tester.pump();
          expect(avatar.activeTrack, isFalse);
          expect(
            avatar.stopCalls,
            1,
            reason: 'only the TTS stop event retires the track',
          );
          await tester.runAsync(dispose);
          await appServices.reset();
        },
      );
    }

    testWidgets('$consumer scalar silence ignores semantic open mouth', (
      tester,
    ) async {
      final avatar = _SpeechOwnedAvatar();
      final dispose = await _mountConsumer(consumer, avatar);
      addTearDown(dispose);
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.surprised,
          semanticLabel: 'surprised',
          agentId: 'self',
        ),
      );
      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      await tester.pump();
      expect(
        avatar.expressions.last.mouthOpen,
        0,
        reason:
            'speech start retires the authored idle mouth without a scalar write',
      );
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.surprised,
          semanticLabel: 'surprised',
          agentId: 'self',
        ),
      );
      await tester.pump();
      expect(
        avatar.expressions.last.mouthOpen,
        0,
        reason: 'full face refresh cannot reopen a speech-owned silent mouth',
      );
      for (final amplitude in [0.0, .2]) {
        EventBus().fire(LipSyncAmplitudeEvent(amplitude, agentId: 'self'));
        await tester.pump();
        expect(
          avatar.scalarWrites.last,
          amplitude,
          reason:
              'a semantic .7 mouth cannot reopen a speech-owned silent frame',
        );
      }
      EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
      await tester.pump();
      await tester.runAsync(dispose);
      await appServices.reset();
    });
  }

  testWidgets(
    'enforced projection keeps TTS track independent of facial transitions',
    (tester) async {
      final sink = _ProjectionSink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 1,
        mode: () => FeatureRolloutMode.enforce,
        dispatchSink: sink,
      );
      addTearDown(service.onClose);
      await service.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        sequence: 1,
      );
      await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 2,
          isSpeaking: true,
          generation: 1,
        ),
      );
      await service.project(
        SelfAvatarVisemeTrackProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 3,
          track: _track(),
          generation: 1,
        ),
      );
      final trackToken = sink.trackToken;
      await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 4,
          params: EmotionParams.happy,
          semanticLabel: 'happy',
          duration: Duration(milliseconds: 80),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await service.waitForIdle();
      await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 5,
          params: EmotionParams.neutral,
          semanticLabel: 'neutral',
        ),
      );
      expect(sink.trackToken, trackToken);
      expect(sink.scalarWrites, isEmpty);
      expect(sink.stopCalls, 0);

      await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 6,
          params: EmotionParams.surprised,
          semanticLabel: 'surprised',
        ),
      );
      for (final entry in [0.0, .2].asMap().entries) {
        await service.project(
          SelfAvatarLipFrameProjectionInput(
            accountGeneration: 1,
            rendererGeneration: 1,
            sequence: 7 + entry.key,
            amplitude: entry.value,
            generation: 1,
          ),
        );
        expect(sink.scalarWrites.last, entry.value);
      }
      await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 9,
          isSpeaking: false,
          generation: 1,
        ),
      );
      expect(sink.stopCalls, 1);
    },
  );
}

LipSyncVisemeTrack _track() => LipSyncVisemeTrack(
  envelope: [0, .8, 0],
  cues: [
    LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.sil),
    LipSyncVisemeCue(frame: 1, viseme: LipSyncViseme.aa),
    LipSyncVisemeCue(frame: 2, viseme: LipSyncViseme.sil),
  ],
);

Future<Future<void> Function()> _mountConsumer(
  String consumer,
  _SpeechOwnedAvatar avatar,
) async {
  appServices.put(ActiveAvatarRuntime()).register(avatar);
  if (consumer == 'bridge') {
    appServices.put(SelfAvatarBridge());
    return () async {};
  }
  final runtime = AgentRuntime(
    agentId: 'self',
    profile: AgentProfile(
      nickname: 'test',
      avatar: '',
      bio: 'test',
      personalityTraits: const [],
      catchphrase: '',
    ),
    llmClient: _UnusedLlm(),
  );
  await runtime.init(enabledSkillIds: const {});
  var disposed = false;
  return () async {
    if (disposed) return;
    disposed = true;
    await runtime.retireAndDrain();
  };
}

class _UnusedLlm implements LLMClient {
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _SpeechOwnedAvatar extends AvatarRuntime implements AvatarVisemeRuntime {
  @override
  final backendKind = AvatarBackendKind.unity;
  @override
  final isReady = true.obs;
  final expressions = <AvatarExpressionParams>[];
  final scalarWrites = <double>[];
  bool activeTrack = false;
  int trackStarts = 0, cancelledTracks = 0, stopCalls = 0;

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {
    expressions.add(params);
  }

  @override
  Future<void> setMouthOpen(double value) async {
    // Match Unity: scalar mouth writes cancel the native envelope/viseme timeline.
    if (activeTrack) cancelledTracks++;
    activeTrack = false;
    scalarWrites.add(value);
  }

  @override
  Future<void> startLipSync(List<double> envelope, {int frameRate = 30}) async {
    activeTrack = true;
    trackStarts++;
  }

  @override
  Future<void> startVisemeTrack(LipSyncVisemeTrack track) async {
    activeTrack = true;
    trackStarts++;
  }

  @override
  Future<void> stopLipSync() async {
    activeTrack = false;
    stopCalls++;
  }

  @override
  Future<void> clearGaze() async {}
  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async {}
  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async {}
  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) async {}
  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {}
  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async {}
  @override
  Future<void> setFraming(String mode) async {}
  @override
  Future<void> setGaze(AvatarGaze gaze) async {}
  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async {}
  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}
  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}
}

class _ProjectionSink implements SelfAvatarProjectionDispatchSink {
  int trackToken = 0, stopCalls = 0;
  final scalarWrites = <double>[];
  @override
  Future<void> dispatch(SelfAvatarProjectionDispatch dispatch) async {
    if (dispatch.visemeTrack != null || dispatch.lipEnvelope.isNotEmpty) {
      trackToken++;
    }
    if (dispatch.mouthOpen != null) scalarWrites.add(dispatch.mouthOpen!);
    if (dispatch.stopLipSync) stopCalls++;
  }
}
