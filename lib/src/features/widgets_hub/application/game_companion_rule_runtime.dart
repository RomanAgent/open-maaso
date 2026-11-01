import 'dart:convert';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

import 'game_companion_adapter.dart';
import 'game_companion_context.dart';

/// Optional static-rule interpretation through the existing read-only owner.
/// It has no speech, tool execution, code evaluation or persistence capability.
final class GameCompanionRuleRuntime {
  GameCompanionRuleRuntime({
    required this.runtime,
    required this.isCurrent,
    this.timeout = const Duration(seconds: 6),
  }) {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 30)) {
      throw ArgumentError('Rule interpretation needs a bounded deadline.');
    }
  }

  final AgentRuntime? Function() runtime;
  final bool Function(String scopeKey) isCurrent;
  final Duration timeout;

  static GameCompanionDescriptor? parseDescriptor(String source) {
    if (source.length > GameCompanionDescriptor.maxBytes ||
        utf8.encode(source).length > GameCompanionDescriptor.maxBytes) {
      return null;
    }
    try {
      final descriptor = GameCompanionDescriptor.tryParse(jsonDecode(source));
      if (descriptor == null) return null;
      final data = descriptor.toPromptJson();
      // Current score/position/event fields never enter the adaptation cache.
      // The model must also omit transient statements inside allowed prose;
      // this structural gate is not a semantic proof of the prose's accuracy.
      if (data.keys.any(
        (key) => !const {
          'version',
          'name',
          'summary',
          'goals',
          'rules',
          'controls',
        }.contains(key),
      )) {
        return null;
      }
      bool meaningful(Object? value) => value is String
          ? value.trim().isNotEmpty
          : value is List &&
                value.any((item) => item is String && item.trim().isNotEmpty);
      if (!['goals', 'rules', 'controls'].any((key) => meaningful(data[key]))) {
        return null;
      }
      return descriptor;
    } on Object {
      return null;
    }
  }

  Future<GameCompanionDescriptor?> infer(
    GameCompanionRuleInferenceInput input, {
    required bool Function() isCurrent,
  }) async {
    final selected = runtime();
    if (selected == null) return null;
    var finished = false;
    bool current() =>
        !finished &&
        isCurrent() &&
        this.isCurrent(input.scopeKey) &&
        identical(runtime(), selected);
    if (!current() || !selected.canAcceptSurfacePlayDecision) return null;
    try {
      final result = await selected.runGameCommentaryDecision(
        () => chatWithPrivacyAdmission(
          selected.llmClient,
          [
            Message.system(
              AgentPromptCatalog.text('runtime.game_voice.infer_rules'),
            ),
            Message.user(jsonEncode(input.toPromptJson())),
          ],
          timeout: timeout,
          onAdmitted: () {
            if (!current() || !selected.isCurrentSurfacePlayDecision) {
              throw StateError('game_rules_revoked');
            }
          },
        ).timeout(timeout),
        isCurrent: current,
      );
      if (result == null || !current()) return null;
      return parseDescriptor(result);
    } on Object {
      return null;
    } finally {
      // A privacy prompt resolving after the deadline must not admit an
      // abandoned model request into a later session.
      finished = true;
    }
  }
}
