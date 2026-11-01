import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          return switch (call.method) {
            'getLanguages' => <String>['en-US'],
            'getVoices' => <Object>[],
            _ => 1,
          };
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
    await appServices.reset();
  });

  test(
    'idle interrupt restores the base emotion and invalidates its old timer',
    () async {
      appServices.put(AgentTaskJobStore());
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Hiyori',
          avatar: '',
          bio: 'test',
          personalityTraits: const <String>['warm'],
          catchphrase: 'ok',
        ),
        llmClient: _InertLlmClient(),
      );
      addTearDown(runtime.retireAndDrain);
      await runtime.init(enabledSkillIds: const <String>{});
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.serious,
          semanticLabel: 'serious',
          agentId: 'self',
        ),
      );
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.happy,
          semanticLabel: 'happy',
          agentId: 'self',
          duration: const Duration(milliseconds: 80),
        ),
      );
      await pumpEventQueue();
      expect(runtime.emotion.value, EmotionParams.happy);
      runtime.cancelCurrent();
      await pumpEventQueue();
      expect(runtime.emotion.value, EmotionParams.serious);
      expect(runtime.emotionLabel.value, 'serious');
      EventBus().fire(
        EmotionStateEvent(
          EmotionParams.sad,
          semanticLabel: 'sad',
          agentId: 'self',
        ),
      );
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(runtime.emotion.value, EmotionParams.sad);
      expect(runtime.emotionLabel.value, 'sad');
    },
  );

  test(
    'tap interrupt stops trailing TTS after the turn reached idle',
    () async {
      appServices.put(AgentTaskJobStore());
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Hiyori',
          avatar: '',
          bio: 'test agent',
          personalityTraits: const <String>['warm'],
          catchphrase: 'ok',
        ),
        llmClient: _InertLlmClient(),
      );
      addTearDown(runtime.retireAndDrain);
      await runtime.init(enabledSkillIds: const <String>{});
      expect(runtime.turn.isProcessing, isFalse);

      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      await pumpEventQueue();
      expect(runtime.isSpeaking.value, isTrue);

      final generationBeforeInterrupt = MaasoTtsPlugin.debugSpeakGeneration;
      runtime.cancelCurrent();
      await pumpEventQueue();

      expect(
        MaasoTtsPlugin.debugSpeakGeneration,
        greaterThan(generationBeforeInterrupt),
      );
      expect(runtime.isSpeaking.value, isFalse);
      expect(runtime.turn.isProcessing, isFalse);
    },
  );
}

final class _InertLlmClient implements LLMClient {
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      '{"reply":"","actions":[]}';

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
  Stream<String> streamChat(List<Message> messages, {Duration? timeout}) =>
      const Stream<String>.empty();

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => const Stream<LLMStreamEvent>.empty();
}
