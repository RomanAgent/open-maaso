/// Regression test: isSpeaking must be driven directly by SpeakingStatusEvent,
/// independent of the TurnStateMachine. This was broken in the refactor that
/// wired isSpeaking through turn.transition(TurnState.speaking) — because TTS
/// fires the event after chat() ends (→ idle), the transition was rejected and
/// isSpeaking never became true during real speech.
library;

import 'package:flutter/services.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/emotion_to_avatar.dart';
import 'package:maaso/src/core/models/agent_profile.dart';

class _StubLlm implements LLMClient {
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      '{"reply":"ok","actions":[]}';

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) {
    throw UnsupportedError('not used');
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield '{"reply":"ok","actions":[]}';
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield const LLMStreamEvent(
      event: 'reply.delta',
      data: '{"delta":"{\\"reply\\":\\"ok\\",\\"actions\\":[]}"}',
    );
  }
}

class _RecordingAvatarRuntime extends AvatarRuntime {
  @override
  final backendKind = AvatarBackendKind.unity;

  @override
  final isReady = true.obs;

  final expressions = <AvatarExpressionParams>[];

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
  Future<void> setMouthOpen(double value) async {}

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}

  @override
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async {}

  @override
  Future<void> stopLipSync() async {}
}

AgentProfile _profile() => AgentProfile(
  nickname: 'Hiyori',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const ['warm'],
  catchphrase: 'ok',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Minimal TTS mock so init() does not throw on the platform channel.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
        call,
      ) async {
        switch (call.method) {
          case 'getLanguages':
            return <String>['en-US'];
          case 'getVoices':
            return <Object>[];
          case 'speak':
          case 'setLanguage':
          case 'setSpeechRate':
          case 'setVolume':
          case 'setPitch':
          case 'awaitSpeakCompletion':
          case 'stop':
            return 1;
          default:
            return null;
        }
      });

  group('isSpeaking is event-driven, independent of TurnStateMachine', () {
    late AgentRuntime runtime;

    setUp(() async {
      runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _StubLlm(),
      );
      await runtime.init();
    });

    tearDown(() {
      runtime.dispose();
      appServices.reset();
    });

    test('SpeakingStatusEvent(true) flips isSpeaking to true', () async {
      expect(runtime.isSpeaking.value, isFalse);

      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      // EventBus uses a broadcast StreamController; delivery is async (next
      // microtask). Drain the microtask queue before asserting.
      await Future<void>.delayed(Duration.zero);
      expect(runtime.isSpeaking.value, isTrue);
    });

    test('SpeakingStatusEvent(false) flips isSpeaking back to false', () async {
      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      await Future<void>.delayed(Duration.zero);
      expect(runtime.isSpeaking.value, isTrue);

      EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
      await Future<void>.delayed(Duration.zero);
      expect(runtime.isSpeaking.value, isFalse);
    });

    test(
      'isSpeaking responds even when turn is idle (fire-and-forget TTS path)',
      () async {
        // Verify the machine is indeed idle — the critical scenario is that
        // TTS fires AFTER chat() completes (→ idle), and isSpeaking still flips.
        expect(runtime.turn.isProcessing, isFalse);

        EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
        await Future<void>.delayed(Duration.zero);
        expect(
          runtime.isSpeaking.value,
          isTrue,
          reason: 'isSpeaking must flip even when turn is idle',
        );
      },
    );

    test('explicit notification taps bypass environment cooldowns', () async {
      Future<String> open(String id) {
        final response = runtime.onProactiveResponse.first.timeout(
          const Duration(seconds: 3),
        );
        EventBus().fire(
          SystemStatusEvent(
            'notification_opened',
            payload: <String, Object?>{
              'deliveryId': id,
              'prompt': 'Briefly acknowledge the notification tap.',
            },
          ),
        );
        return response;
      }

      expect(await open('first'), 'ok');
      expect(await open('second'), 'ok');
    });
  });

  test(
    'init pushes a neutral expression when avatar is already ready',
    () async {
      final active = appServices.put(ActiveAvatarRuntime());
      final avatar = _RecordingAvatarRuntime();
      active.register(avatar);
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _StubLlm(),
      );

      try {
        await runtime.init(enabledSkillIds: const {});

        expect(avatar.expressions, hasLength(1));
        expect(
          avatar.expressions.single.toJson(),
          emotionToAvatarParams(EmotionParams.neutral).toJson(),
        );
        expect(runtime.emotion.value.eyeOpen, 1);
        expect(runtime.emotion.value.eyeShape, 0);
        expect(runtime.emotion.value.mouthCurve, 0);
        expect(runtime.emotion.value.mouthOpen, 0);
      } finally {
        runtime.dispose();
        appServices.reset();
      }
    },
  );
}
