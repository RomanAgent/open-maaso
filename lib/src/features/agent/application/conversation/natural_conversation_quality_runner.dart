import 'dart:async';

import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

import 'conversation_reply_generator.dart';
import 'natural_conversation_quality.dart';
import 'natural_conversation_quality_catalog.dart';

/// Runs the curated corpus through the same bounded reply generator used by the
/// production Persona path. It never publishes UI, audio, or Avatar effects.
class NaturalConversationModelScenarioRunner
    implements NaturalConversationQualityScenarioRunner {
  NaturalConversationModelScenarioRunner(this.client);

  final LLMClient client;

  ConversationReplyGenerator? _activeGenerator;
  Completer<void>? _activeCancellation;

  @override
  Future<NaturalConversationQualityObservation> run(
    NaturalConversationQualityScenario scenario, {
    required Duration timeout,
  }) async {
    if (_activeGenerator != null) {
      throw StateError('natural_conversation_runner_busy');
    }
    final generator = ConversationReplyGenerator(client);
    final cancellation = Completer<void>();
    _activeGenerator = generator;
    _activeCancellation = cancellation;
    var timedOut = false;
    try {
      final draft = await generator
          .generate(
            messages: _messagesFor(scenario),
            cancelled: cancellation.future,
          )
          .timeout(timeout);
      await generator.drained.timeout(const Duration(seconds: 3));
      if (draft == null) {
        return const NaturalConversationQualityObservation.failure(
          NaturalConversationQualityOutcome.failed,
        );
      }
      return NaturalConversationQualityObservation.completed(
        aggregateReply: draft.reply,
        usesUtteranceProtocol: draft.usesUtteranceProtocol,
        utterances: [
          for (final utterance in draft.utterances)
            NaturalConversationQualityUtterance(
              text: utterance.text,
              after: utterance.after.wireValue,
              pause: utterance.pause?.name,
              body: utterance.body,
            ),
        ],
      );
    } on TimeoutException {
      timedOut = true;
      rethrow;
    } on ConversationReplyProtocolException {
      try {
        await generator.drained.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        timedOut = true;
        rethrow;
      }
      return const NaturalConversationQualityObservation.failure(
        NaturalConversationQualityOutcome.invalidResponse,
      );
    } catch (_) {
      try {
        await generator.drained.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        timedOut = true;
        rethrow;
      }
      return const NaturalConversationQualityObservation.failure(
        NaturalConversationQualityOutcome.failed,
      );
    } finally {
      if (!timedOut && identical(_activeGenerator, generator)) {
        _activeGenerator = null;
        _activeCancellation = null;
      }
    }
  }

  @override
  Future<void> cancelAndDrain() async {
    final cancellation = _activeCancellation;
    final generator = _activeGenerator;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    try {
      await generator?.drained;
    } finally {
      if (identical(_activeGenerator, generator)) {
        _activeGenerator = null;
        _activeCancellation = null;
      }
    }
  }

  List<Message> _messagesFor(NaturalConversationQualityScenario scenario) {
    final locale = scenario.locale == NaturalConversationQualityLocale.zh
        ? AppLocale.zh
        : AppLocale.en;
    return ConversationReplyGenerator.buildMessages(
      userText: scenario.userText,
      currentUserText: scenario.userText,
      history: [
        for (final turn in scenario.history)
          if (turn.role == NaturalConversationHistoryRole.user)
            Message.user(turn.text)
          else
            Message.assistant(turn.text),
      ],
      turnPlan: const AgentTurnPlan(route: AgentTurnRoute.chitchat),
      profile: _qualityProfile,
      locale: locale,
      outputContract: naturalConversationQualityOutputContract(locale),
    );
  }
}

final _qualityProfile = AgentProfile(
  nickname: 'Maaso',
  avatar: '',
  bio: '',
  personalityTraits: const ['warm', 'attentive', 'direct'],
  catchphrase: '',
);

String naturalConversationQualityOutputContract(AppLocale locale) {
  final style = locale == AppLocale.zh
      ? '结合最近对话和用户当前语气，像熟悉的人自然聊天。明确的问题直接答；'
            '只有商量、犹豫或确有必要的补充才分成两三次发言。不要固定用语气词开头，'
            '不要复读，不要每轮凑三段。先接住感受再提建议，情绪证据不足时保持克制。'
            '需要思考、倾听或回应情绪时自主选择轻微身体提示；用户不必下达动作命令。'
      : 'Use the recent conversation and the user\'s tone. Answer direct '
            'questions directly; use two or three utterances only for a useful '
            'suggestion, hesitation, or supplement. Do not reuse filler openings, '
            'repeat yourself, or force three parts. Acknowledge feelings before '
            'advice and stay restrained when emotion is uncertain. Choose subtle '
            'thinking, listening, or emotional body cues when useful; the user '
            'does not need to request an action.';
  return '''
This turn uses the following JSON contract, replacing earlier plain-text and
sideband output instructions. $style
Return exactly {"actions":[...],"reply":"complete aggregate"} with no wrapper.
Keep the top-level "actions" field before "reply" so each closed action can be
presented early. The host still accepts valid reply-first JSON for compatibility.
Use 1–3 reply.utterance actions. Each needs nonempty text and after.
after is continue, optional, yield, or finish. The last action must yield or finish.
Only one optional supplement is allowed, immediately before the final action.
pause may be brief or invite. Split by conversational intent, never punctuation.
A body object is optional. Use at most two different subtle cues in the whole reply.
Omit body when no cue helps. Never emit a mouth cue: TTS owns mouth movement.
body fields are mood, gesture, gaze, posture, style, intensity, durationMs, emitMood.
Do not emit tools, scripts, IDs, timestamps, raw Avatar controls, body_intent, or
task_handoff. The host owns delivery, interruption, timing, speech, and idle motion.
''';
}
