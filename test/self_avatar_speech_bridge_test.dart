import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/emotion_to_avatar.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';
import 'package:maaso/src/core/services/self_avatar_speech_bridge.dart';
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

  tearDown(appServices.reset);
  tearDown(() {
    MaasoTtsPlugin.soundEnabled.value = true;
  });

  test('muted legacy bridge rejects late mouth tracks', () async {
    final active = appServices.put(ActiveAvatarRuntime());
    final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
    active.register(avatar);
    appServices.put(SelfAvatarBridge());
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    EventBus().fire(LipSyncEnvelopeEvent([0.2, 0.8], agentId: 'self'));
    await Future<void>.delayed(Duration.zero);
    expect(avatar.lipSyncEnvelopes, hasLength(1));
    await MaasoTtsPlugin.setSoundEnabled(false);
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
    await Future<void>.delayed(Duration.zero);
    expect(avatar.lipSyncEnvelopes, hasLength(1));
    expect(avatar.visemeTracks, isEmpty);
    expect(avatar.expressions.last.mouthOpen, 0);
  });

  test('muted bridge accepts only current authorized game speech', () async {
    final active = appServices.put(ActiveAvatarRuntime());
    final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
    active.register(avatar);
    appServices.put(SelfAvatarBridge());
    MaasoTtsPlugin.soundEnabled.value = false;
    var permitted = true;
    final plugin = MaasoTtsPlugin(agentId: 'self');
    addTearDown(plugin.dispose);
    final turn = plugin.openTurn(
      turnId: 'game',
      text: 'Hello',
      canSpeak: () => permitted,
    );
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    EventBus().fire(LipSyncEnvelopeEvent([.2, .8], agentId: 'self'));
    await Future<void>.delayed(Duration.zero);
    expect(avatar.lipSyncEnvelopes, hasLength(1));
    permitted = false;
    EventBus().fire(LipSyncEnvelopeEvent([.9, .9], agentId: 'self'));
    await Future<void>.delayed(Duration.zero);
    expect(avatar.lipSyncEnvelopes, hasLength(1));
    await turn.cancel();
    permitted = true;
    EventBus().fire(LipSyncEnvelopeEvent([.9, .9], agentId: 'self'));
    await Future<void>.delayed(Duration.zero);
    expect(avatar.lipSyncEnvelopes, hasLength(1));
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
  });

  testWidgets('legacy bridge restores the base while preserving speech mouth', (
    tester,
  ) async {
    final active = appServices.put(ActiveAvatarRuntime());
    final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
    active.register(avatar);
    appServices.put(SelfAvatarBridge());
    EventBus().fire(EmotionStateEvent(EmotionParams.serious, agentId: 'self'));
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    EventBus().fire(LipSyncAmplitudeEvent(0.7, agentId: 'self'));
    EventBus().fire(
      EmotionStateEvent(
        EmotionParams.happy,
        agentId: 'self',
        duration: const Duration(seconds: 1),
      ),
    );
    await tester.pump();
    expect(avatar.expressions.last.happy, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(avatar.expressions.last.happy, 0);
    expect(avatar.expressions.last.mouthOpen, 0);
    expect(avatar.expressions.last.surprised, 0);
    expect(avatar.mouthOpens.last, 0.7);
    EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
    await tester.pump();
    expect(
      avatar.expressions.last.toJson(),
      emotionToAvatarParams(EmotionParams.serious).toJson(),
    );
    await appServices.reset();
  });

  testWidgets('legacy bridge reset and model reload cancel temporary emotion', (
    tester,
  ) async {
    final active = appServices.put(ActiveAvatarRuntime());
    final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
    active.register(avatar);
    appServices.put(SelfAvatarBridge());
    EventBus().fire(EmotionStateEvent(EmotionParams.calm, agentId: 'self'));
    EventBus().fire(
      EmotionStateEvent(
        EmotionParams.happy,
        agentId: 'self',
        duration: const Duration(seconds: 1),
      ),
    );
    await tester.pump();
    EventBus().fire(AvatarEmotionResetEvent(agentId: 'self'));
    await tester.pump();
    expect(
      avatar.expressions.last.toJson(),
      emotionToAvatarParams(EmotionParams.calm).toJson(),
    );
    EventBus().fire(
      EmotionStateEvent(
        EmotionParams.happy,
        agentId: 'self',
        duration: const Duration(seconds: 1),
      ),
    );
    await tester.pump();
    avatar.isReady.value = false;
    avatar.isReady.value = true;
    await tester.pump();
    expect(
      avatar.expressions.last.toJson(),
      emotionToAvatarParams(EmotionParams.calm).toJson(),
    );
    final count = avatar.expressions.length;
    await tester.pump(const Duration(seconds: 2));
    expect(avatar.expressions, hasLength(count));
    await appServices.reset();
  });

  test(
    'self avatar bridge routes lip-sync envelopes to active avatar',
    () async {
      final active = appServices.put(ActiveAvatarRuntime());
      final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      active.register(avatar);
      appServices.put(SelfAvatarBridge());

      EventBus().fire(
        LipSyncEnvelopeEvent(
          const [0.1, 0.6, 0.2],
          frameRate: 24,
          agentId: 'self',
        ),
      );
      final track = LipSyncVisemeTrack(
        envelope: const <double>[0.1, 0.6, 0.2],
        cues: <LipSyncVisemeCue>[
          LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.aa),
          LipSyncVisemeCue(frame: 1, viseme: LipSyncViseme.ih),
        ],
        frameRate: 24,
      );
      EventBus().fire(LipSyncVisemeTrackEvent(track, agentId: 'self'));
      await Future<void>.delayed(Duration.zero);

      expect(avatar.lipSyncEnvelopes, [
        [0.1, 0.6, 0.2],
      ]);
      expect(avatar.lipSyncFrameRates, [24]);
      expect(avatar.visemeTracks, <LipSyncVisemeTrack>[track]);
    },
  );

  test('self avatar bridge starts from a neutral expression', () async {
    final active = appServices.put(ActiveAvatarRuntime());
    final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
    avatar.isReady.value = false;
    active.register(avatar);
    appServices.put(SelfAvatarBridge());

    avatar.isReady.value = true;
    await Future<void>.delayed(Duration.zero);

    expect(avatar.expressions, hasLength(1));
    expect(
      avatar.expressions.single.toJson(),
      emotionToAvatarParams(EmotionParams.neutral).toJson(),
    );
  });
}

class _RecordingAvatarRuntime extends AvatarRuntime
    implements AvatarVisemeRuntime {
  _RecordingAvatarRuntime(this.backendKind);

  @override
  final AvatarBackendKind backendKind;

  @override
  final isReady = true.obs;

  final lipSyncEnvelopes = <List<double>>[];
  final lipSyncFrameRates = <int>[];
  final visemeTracks = <LipSyncVisemeTrack>[];
  final expressions = <AvatarExpressionParams>[];
  final mouthOpens = <double>[];

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
  Future<void> resume() async {}

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async {}

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {
    expressions.add(params);
  }

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
  Future<void> setMouthOpen(double value) async {
    mouthOpens.add(value);
  }

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}

  @override
  Future<void> startLipSync(List<double> envelope, {int frameRate = 30}) async {
    lipSyncEnvelopes.add(List<double>.of(envelope));
    lipSyncFrameRates.add(frameRate);
  }

  @override
  Future<void> startVisemeTrack(LipSyncVisemeTrack track) async {
    visemeTracks.add(track);
  }

  @override
  Future<void> stopLipSync() async {}
}
