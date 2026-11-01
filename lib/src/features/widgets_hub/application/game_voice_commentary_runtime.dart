import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_delivery_policy.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_prompt.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

import 'game_companion_context.dart';
import 'game_companion_speech_policy.dart';
import 'game_voice_companion.dart';

typedef GameVoiceDeliveryObserver =
    void Function(
      GameVoiceObservation observation,
      String id,
      String text,
      GameCompanionDeliveryStage stage,
    );

/// Reads public game facts through the existing runtime; never applies actions.
final class GameVoiceCommentaryRuntime {
  const GameVoiceCommentaryRuntime({
    required this.runtime,
    required this.isCurrent,
    this.onDelivery,
  });

  final AgentRuntime? Function() runtime;
  final bool Function(String scopeKey) isCurrent;
  final GameVoiceDeliveryObserver? onDelivery;
  static int _deliverySerial = 0;

  static String parseReply(String source) {
    if (utf8.encode(source).length > 8192) {
      throw const FormatException('game_commentary_too_large');
    }
    final value = jsonDecode(source);
    if (value is! Map ||
        value.length != 2 ||
        value['reply'] is! String ||
        value['actions'] is! List ||
        (value['actions'] as List).isNotEmpty) {
      throw const FormatException('game_commentary_read_only');
    }
    final reply = (value['reply'] as String).trim();
    if (reply.runes.length > 160 ||
        reply.runes.any((rune) => rune < 32 || rune == 127)) {
      throw const FormatException('game_commentary_reply_bounds');
    }
    return reply;
  }

  Future<bool> comment(
    GameVoiceObservation observation, {
    required bool Function() isCurrent,
    required Future<void> onRevoked,
  }) async {
    final selected = runtime();
    if (selected == null) return false;
    final games = appServices.maybeFind<GameVoiceCompanionService>();
    final session = games?.currentSession;
    bool speechAllowed() => games == null
        ? MaasoTtsPlugin.soundEnabled.value
        : identical(
                appServices.maybeFind<GameVoiceCompanionService>(),
                games,
              ) &&
              session?.scopeKey == observation.scopeKey &&
              session?.playerId == observation.playerId &&
              session?.generation == observation.generation &&
              session?.spokenRepliesEnabled == true;
    final profile = selected.profile;
    final partner = _partnerExpression(profile);
    final partnerSnapshot = jsonEncode(partner);
    final voiceId = profile.voiceId;
    final userId = profile.userId;
    final locale = AgentPromptCatalog.currentLocale;
    var revoked = false;
    var finished = false;
    onRevoked.then<void>(
      (_) => revoked = true,
      onError: (Object _, StackTrace _) => revoked = true,
    );
    // The style snapshot captures this guard. It must never refer back to
    // style.isCurrent, which would recursively evaluate its own deliveryGuard.
    bool baseCurrent() =>
        !finished &&
        !revoked &&
        isCurrent() &&
        this.isCurrent(observation.scopeKey) &&
        identical(runtime(), selected) &&
        identical(selected.profile, profile) &&
        profile.voiceId == voiceId &&
        profile.userId == userId &&
        jsonEncode(_partnerExpression(profile)) == partnerSnapshot &&
        speechAllowed();
    if (!baseCurrent() || !selected.canAcceptSurfacePlayDecision) {
      return false;
    }
    ConversationStyleSnapshot? style;
    bool current() => baseCurrent() && style?.isCurrent == true;
    var started = false;
    var terminalRecorded = false;
    String? spokenReply;
    final deliveryId = 'game-voice-${++_deliverySerial}';
    void record(GameCompanionDeliveryStage stage) {
      final reply = spokenReply;
      if (reply == null) return;
      try {
        onDelivery?.call(observation, deliveryId, reply, stage);
      } on Object {
        // A failed optional receipt consumer cannot replay or alter speech.
      }
    }

    try {
      final response = await selected.runGameCommentaryDecision(() async {
        style = await selected.snapshotGameVoiceStyle();
        if (!current()) throw StateError('game_commentary_revoked');
        return chatWithPrivacyAdmission(
          selected.llmClient,
          [
            Message.system(
              [
                AgentPromptCatalog.text(
                  'runtime.game_voice.commentary',
                  locale: locale,
                  params: {'language': locale.code},
                ),
                ConversationStylePrompt.render(
                  style!,
                  locale: locale,
                  compact: true,
                ),
              ].join('\n\n'),
            ),
            Message.user(
              jsonEncode({
                'partner': partner,
                'title': observation.title,
                'summary': observation.summary,
                'publicState': observation.publicState,
                'event': observation.eventKind,
                'revision': observation.revision,
                'observedAt': observation.observedAt.toUtc().toIso8601String(),
                if (observation.context != null)
                  'companionContext': observation.context!.toPromptJson(),
                if (observation.moment != null)
                  'moment': observation.moment!.toPromptJson(),
              }),
            ),
          ],
          timeout: const Duration(seconds: 10),
          onAdmitted: () {
            if (!current() || !selected.isCurrentSurfacePlayDecision) {
              throw StateError('game_commentary_revoked');
            }
          },
        ).timeout(const Duration(seconds: 10));
      }, isCurrent: baseCurrent);
      if (response == null || !current()) return false;
      final reply = parseReply(response);
      if (reply.isEmpty ||
          !ConversationTextGate(style).allows(reply) ||
          GameCompanionSpeechPolicy().isRepeatedReply(
            reply,
            observation.context?.recentConversation
                    .where(
                      (entry) =>
                          entry.speaker == GameCompanionSpeaker.assistant,
                    )
                    .map((entry) => entry.text) ??
                const [],
          )) {
        return false;
      }
      spokenReply = reply;
      final completed = await selected.presentGameVoiceComment(
        reply,
        isCurrent: current,
        spokenRepliesAllowed: current,
        onRevoked: onRevoked,
        conversationStyle: style,
        onPresented: () {
          if (started) return;
          started = true;
          record(GameCompanionDeliveryStage.started);
        },
      );
      if (started) {
        record(
          completed
              ? GameCompanionDeliveryStage.completed
              : GameCompanionDeliveryStage.interrupted,
        );
        terminalRecorded = true;
      }
      return completed;
    } on Object {
      // No retry, fallback action, or delayed replay of an old game event.
      return false;
    } finally {
      finished = true;
      if (started && !terminalRecorded) {
        record(GameCompanionDeliveryStage.interrupted);
      }
    }
  }

  static Map<String, Object?> _partnerExpression(AgentProfile profile) {
    String bounded(String text, int limit) =>
        String.fromCharCodes(text.runes.take(limit));
    return {
      'name': bounded(profile.nickname, 120),
      'traits': profile.personalityTraits
          .take(8)
          .map((text) => bounded(text, 96))
          .toList(growable: false),
      'persona': bounded(profile.persona.toCapsule(), 1800),
      'catchphrase': bounded(profile.catchphrase, 120),
    };
  }
}
