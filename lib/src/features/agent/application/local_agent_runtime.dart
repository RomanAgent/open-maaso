import 'dart:convert';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/local_skill_retriever.dart';

enum LocalAgentActionType { speak, ask, call, finish }

class LocalAgentAction {
  final LocalAgentActionType type;
  final String? text;
  final String? question;
  final String? skillId;
  final Map<String, dynamic> args;

  const LocalAgentAction._({
    required this.type,
    this.text,
    this.question,
    this.skillId,
    this.args = const {},
  });

  factory LocalAgentAction.speak(String text) =>
      LocalAgentAction._(type: LocalAgentActionType.speak, text: text);

  factory LocalAgentAction.ask(String question) =>
      LocalAgentAction._(type: LocalAgentActionType.ask, question: question);

  factory LocalAgentAction.call(String skillId, Map<String, dynamic> args) =>
      LocalAgentAction._(
        type: LocalAgentActionType.call,
        skillId: skillId,
        args: args,
      );

  factory LocalAgentAction.finish(String text) =>
      LocalAgentAction._(type: LocalAgentActionType.finish, text: text);
}

class LocalAgentTurn {
  final String userText;
  final int step;
  final List<LocalSkillManifest> candidates;
  final List<LocalSkillResult> observations;

  const LocalAgentTurn({
    required this.userText,
    required this.step,
    required this.candidates,
    required this.observations,
  });
}

abstract class LocalAgentPlanner {
  Future<LocalAgentAction> next(LocalAgentTurn turn);
}

enum LocalAgentRunStatus {
  finished,
  asked,
  commitRequired,
  maxStepsExceeded,
  error,
}

class LocalAgentRunResult {
  final LocalAgentRunStatus status;
  final String finalText;
  final List<LocalSkillResult> observations;

  const LocalAgentRunResult({
    required this.status,
    required this.finalText,
    required this.observations,
  });
}

class LocalAgentRuntime {
  static int _nextContractRunSerial = 0;

  LocalAgentRuntime({
    required SkillManager skillManager,
    required Iterable<LocalSkillManifest> manifests,
    required LocalAgentPlanner planner,
    LocalSkillRetriever? retriever,
    LocalSkillInvoker? invoker,
  }) : _planner = planner,
       _retriever = retriever ?? LocalSkillRetriever(manifests),
       _invoker = invoker ?? LocalSkillInvoker(skillManager: skillManager);

  final LocalAgentPlanner _planner;
  final LocalSkillRetriever _retriever;
  final LocalSkillInvoker _invoker;

  Future<LocalAgentRunResult> run(
    String userText, {
    int maxSteps = 4,
    bool confirmed = false,
    Iterable<String> preferredSkillIds = const [],
    AppLocale? locale,
  }) {
    final turnLocale = locale ?? AgentPromptCatalog.currentLocale;
    return AgentPromptCatalog.runWithLocale(
      turnLocale,
      () => _run(
        userText,
        maxSteps: maxSteps,
        confirmed: confirmed,
        preferredSkillIds: preferredSkillIds,
        locale: turnLocale,
      ),
    );
  }

  Future<LocalAgentRunResult> _run(
    String userText, {
    required int maxSteps,
    required bool confirmed,
    required Iterable<String> preferredSkillIds,
    required AppLocale locale,
  }) async {
    _nextContractRunSerial += 1;
    final contractRunId = _nextContractRunSerial;
    final candidates = _retriever.retrieve(
      userText,
      maxResults: 6,
      preferredSkillIds: preferredSkillIds,
    );
    final candidateById = {
      for (final manifest in candidates) manifest.id: manifest,
    };
    final observations = <LocalSkillResult>[];

    for (var step = 1; step <= maxSteps; step++) {
      final action = await _planner.next(
        LocalAgentTurn(
          userText: userText,
          step: step,
          candidates: candidates,
          observations: List.unmodifiable(observations),
        ),
      );

      switch (action.type) {
        case LocalAgentActionType.speak:
          break;
        case LocalAgentActionType.ask:
          return LocalAgentRunResult(
            status: LocalAgentRunStatus.asked,
            finalText: action.question ?? '',
            observations: List.unmodifiable(observations),
          );
        case LocalAgentActionType.finish:
          return LocalAgentRunResult(
            status: LocalAgentRunStatus.finished,
            finalText: action.text ?? '',
            observations: List.unmodifiable(observations),
          );
        case LocalAgentActionType.call:
          final skillId = action.skillId;
          final manifest = skillId == null ? null : candidateById[skillId];
          if (manifest == null) {
            observations.add(
              LocalSkillResult(
                status: LocalSkillResultStatus.denied,
                skillId: skillId ?? '',
                output: jsonEncode({'error': 'skill_not_in_local_candidates'}),
              ),
            );
            break;
          }
          final result = await _invoker.invoke(
            manifest,
            action.args,
            confirmed: confirmed,
            locale: locale,
            contractCallId: 'local-$contractRunId-$step',
          );
          observations.add(result);
          if (result.status == LocalSkillResultStatus.commitRequired) {
            return LocalAgentRunResult(
              status: LocalAgentRunStatus.commitRequired,
              finalText: result.output,
              observations: List.unmodifiable(observations),
            );
          }
      }
    }

    return LocalAgentRunResult(
      status: LocalAgentRunStatus.maxStepsExceeded,
      finalText: 'local_agent_max_steps_exceeded',
      observations: List.unmodifiable(observations),
    );
  }
}
