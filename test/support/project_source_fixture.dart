import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

const sourceHtml =
    '<main><h1>Tap score</h1><p id="score">0</p>'
    '<button id="play">Score</button><button id="restart">Restart</button></main>';
const sourceCss = 'button{min-height:48px;color:var(--maaso-text-primary)}';
const sourceJs =
    'let score=0;const label=document.getElementById("score");'
    'document.getElementById("play").addEventListener("click",()=>{'
    'label.textContent=String(++score);});'
    'document.getElementById("restart").addEventListener("click",()=>{'
    'score=0;label.textContent="0";});';
const sourcePlan = <String, Object?>{
  'title': 'Tap score',
  'summary': 'Tap to score and restart another round.',
  'skillInstructions': 'Tap Score to score; Restart resets the score.',
  'interfaces':
      'screen.html owns score/play/restart IDs; game.js wires all controls.',
  'files': [
    {
      'id': 'screen.html',
      'kind': 'html',
      'purpose': 'Complete game screen',
      'dependsOn': [],
    },
    {
      'id': 'skin.css',
      'kind': 'css',
      'purpose': 'Touch controls',
      'dependsOn': ['screen.html'],
    },
    {
      'id': 'game.js',
      'kind': 'js',
      'purpose': 'Scoring and restart',
      'dependsOn': ['screen.html'],
    },
  ],
  'done': true,
};

Map<String, Object?> boundSourceChunk(
  String id,
  String append, {
  String prefix = '',
  bool done = true,
}) => {
  'fileId': id,
  'baseCursor': utf8.encode(prefix).length,
  'prefixHash': sourceWorkspaceDigest(prefix),
  'append': append,
  'done': done,
};

List<Object> sourceFixtureResponses({
  Map<String, Object?> plan = sourcePlan,
  String js = sourceJs,
}) => [
  jsonEncode(plan),
  jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
  jsonEncode(boundSourceChunk('skin.css', sourceCss)),
  jsonEncode(boundSourceChunk('game.js', js)),
];

class SourceFixtureClient extends LLMClient implements ProjectSourceLLMClient {
  SourceFixtureClient(this.outputs);
  final List<Object> outputs;
  final requests = <List<Message>>[];
  int ordinaryCalls = 0;
  void Function()? beforeAdmission;
  void Function()? afterResponse;

  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    beforeAdmission?.call();
    await onAdmitted?.call();
    requests.add(List<Message>.unmodifiable(messages));
    final output = outputs.removeAt(0);
    if (output is! String && output is! ProjectSourceResponse) throw output;
    afterResponse?.call();
    return output is ProjectSourceResponse
        ? output
        : ProjectSourceResponse(
            visibleText: output as String,
            termination: ProjectSourceTermination.complete,
          );
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    ordinaryCalls++;
    throw StateError('project source must use its dedicated interface');
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async =>
      throw UnimplementedError();
}

class SourceFixtureExecutor extends AgentActionExecutor {
  SourceFixtureExecutor()
    : super(
        agentId: 'source-test',
        skillManager: SkillManager(),
        locale: AppLocale.en,
      );
  AgentActionEnvelope? executed;
  @override
  void preflightSurfaceActions(AgentActionEnvelope envelope) {
    SurfaceProjectValidator.validateForPublicGame(
      SurfaceProject.fromJson(envelope.actions.single['surface'] as Map),
    );
  }

  @override
  Future<AgentActionExecutionResult> execute(
    AgentActionEnvelope envelope, {
    SurfaceWorkerActionRepair? surfaceWorkerRepair,
  }) async {
    executed = envelope;
    return const AgentActionExecutionResult();
  }
}
