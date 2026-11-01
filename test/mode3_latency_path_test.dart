import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mode 3 simple chat uses a low-latency streaming path', () {
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();
    final persona = File(
      'lib/src/features/agent/application/persona/persona_chat_loop.dart',
    ).readAsStringSync();

    expect(runtime, contains('AgentTurnOrchestrator'));
    expect(runtime, contains('AgentBodyController'));
    expect(runtime, contains('PersonaChatLoop'));
    expect(runtime, contains('AgentTaskJobStore'));
    expect(persona, contains('llmClient.streamChat'));
    expect(persona, contains('mode3.persona_chat_loop'));
    expect(persona, contains('tts.stream.flush_first'));
    expect(persona, contains('FullDuplexTTSEngine'));
    expect(persona, contains('MethodChannelStreamingAudioSink'));
    expect(persona, contains('tts.session.first_audio_frame'));
    expect(runtime, contains('structured_actions'));
  });

  test('mode 3 low-latency path is gated away from agent work', () {
    final orchestrator = File(
      'lib/src/features/agent/application/orchestration/agent_turn_orchestrator.dart',
    ).readAsStringSync();

    expect(orchestrator, contains('AgentPipelineMode.proxyDefault'));
    expect(orchestrator, contains('policy.card != CardIntent.none'));
    expect(orchestrator, contains('policy.shouldSearch'));
    expect(orchestrator, contains('policy.preferMultiStep'));
    expect(orchestrator, contains('policy.preferNativeTools'));
    expect(orchestrator, contains('policy.preferredSkills.isNotEmpty'));
    expect(orchestrator, contains('policy.surface.isSurface'));
    expect(orchestrator, contains('!plan.usePersonaLoop'));
  });

  test('streaming speech buffer flushes an early first spoken chunk', () {
    final persona = File(
      'lib/src/features/agent/application/persona/persona_chat_loop.dart',
    ).readAsStringSync();

    expect(persona, contains('class PersonaSpeechBuffer'));
    expect(persona, contains('firstChunkMinChars'));
    expect(persona, contains('laterChunkMinChars'));
    expect(persona, contains('finish()'));
  });

  test('mode 3 persona deltas are bridged to the UI subtitle stream', () {
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();
    final persona = File(
      'lib/src/features/agent/application/persona/persona_chat_loop.dart',
    ).readAsStringSync();

    expect(persona, contains('onReplyDelta'));
    expect(runtime, contains('onReplyDelta: _emitReplyDelta'));
    expect(runtime, contains('void _emitReplyDelta(String delta)'));
    expect(runtime, contains('_localReplyDeltas.add(delta)'));
  });

  test('mode 3 persona prompt allows stripped body intent sideband', () {
    final persona = File(
      'lib/src/features/agent/application/persona/persona_chat_loop.dart',
    ).readAsStringSync();
    final promptBundle = File(
      'lib/src/core/prompts/bundles/runtime_prompts_en.dart',
    ).readAsStringSync();

    expect(persona, contains('<body_intent>'));
    expect(persona, contains('body.intent'));
    expect(promptBundle, contains('machine-only body marker'));
  });

  test('turn plan metadata stays out of user message text', () {
    final persona = File(
      'lib/src/features/agent/application/persona/persona_chat_loop.dart',
    ).readAsStringSync();
    final englishPrompts = File(
      'lib/src/core/prompts/bundles/runtime_prompts_en.dart',
    ).readAsStringSync();
    final chinesePrompts = File(
      'lib/src/core/prompts/bundles/runtime_prompts_zh.dart',
    ).readAsStringSync();

    expect(persona, contains("'runtime.persona.system'"));
    expect(englishPrompts, contains('Internal turn plan:'));
    expect(englishPrompts, contains('CURRENT_USER_MESSAGE'));
    expect(englishPrompts, contains('CONTEXT_FOR_ANSWER_ONLY'));
    expect(chinesePrompts, contains('内部回合计划：'));
    expect(chinesePrompts, contains('当前用户消息：'));
    expect(chinesePrompts, contains('仅供回答参考的上下文：'));
    expect(persona, isNot(contains('turnPlan.promptHint')));
  });

  test('low-latency path does not eagerly build structured prompt', () {
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();

    expect(runtime, contains('String? systemPrompt;'));
    expect(runtime, contains('_runStructuredActions'));
    expect(runtime, contains('systemPrompt != null'));
    expect(
      runtime,
      contains('executablePromptProfile.executableHostGrant.isEmpty'),
    );
    expect(runtime, contains('_brain.buildSystemPromptForTurn'));
    expect(runtime, contains('locale: locale'));
    expect(
      runtime,
      isNot(contains('final systemPrompt = _brain.buildSystemPromptForTurn')),
    );
  });

  test('background generated tasks notify body and UI when they finish', () {
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();

    expect(runtime, contains('reactToTaskCompleted'));
    expect(runtime, contains('reactToTaskFailed'));
    expect(runtime, contains('_notifyBackgroundTask'));
    expect(runtime, contains('task.job.completed'));
    expect(runtime, contains('task.job.failed'));
  });

  test(
    'cloud stream event trace includes client setup and backend trace SSE',
    () {
      final llmProxy = File(
        'lib/src/core/services/llm_proxy_service.dart',
      ).readAsStringSync();
      final methodIndex = llmProxy.indexOf(
        'Stream<LLMStreamEvent> streamChatEvents',
      );
      final stopwatchIndex = llmProxy.indexOf(
        "'cloud.stream_events'",
        methodIndex,
      );
      final ensureIndex = llmProxy.indexOf(
        'await _proxy.ensureClient()',
        methodIndex,
      );

      expect(methodIndex, isNonNegative);
      expect(stopwatchIndex, isNonNegative);
      expect(ensureIndex, isNonNegative);
      expect(stopwatchIndex, lessThan(ensureIndex));
      expect(llmProxy, contains("event.event == 'trace'"));
      expect(llmProxy, contains('_logCloudStreamTrace'));
    },
  );
}
