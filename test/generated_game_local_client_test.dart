import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/execution_result.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'support/project_source_fixture.dart';

const instruction =
    'Create my full offline game with score, restart and all requested features.';
Future<ExecutionResult> run(LLMClient client, SourceFixtureExecutor executor) =>
    debugStructuredActionProcess(
      llmClient: client,
      profile: AgentProfile(
        nickname: 'Maaso',
        avatar: '',
        bio: '',
        personalityTraits: [],
        catchphrase: '',
      ),
      instruction: instruction,
      systemPrompt: 'PRIVATE_PERSONA_CONTEXT',
      executor: executor,
      locale: AppLocale.en,
      generatedGameSurfaceId: 'game-host-local',
    );
void main() {
  test(
    'local compatibility emits the same blueprint and bound files, never an old envelope',
    () async {
      final client = _LocalClient(sourceFixtureResponses().cast<String>());
      final executor = SourceFixtureExecutor();
      expect(client, isNot(isA<ProjectSourceLLMClient>()));
      final result = await run(client, executor);
      expect(result.isSuccess, isTrue, reason: result.stderr);
      expect(client.requests, hasLength(4));
      expect(client.flattenedJsonCalls, 0);
      for (final request in client.requests) {
        expect(request.map((m) => m.role), ['system', 'user']);
        expect(request.last.content, instruction);
        expect(
          request.first.content,
          isNot(contains('PRIVATE_PERSONA_CONTEXT')),
        );
      }
      final surface = SurfaceProject.fromJson(
        executor.executed!.actions.single['surface'] as Map,
      );
      expect(surface.id, 'game-host-local');
      expect(surface.kind, SurfaceKind.fullscreen);
      expect(surface.rendering, SurfaceRendering.webApp);
      expect(surface.manifest.actions, isEmpty);
      expect(surface.manifest.events.map((e) => e.name), [
        'game.state',
        'game.event',
      ]);
      expect(surface.html, sourceHtml);
      expect(surface.js, sourceJs);
      SurfaceProjectValidator.validateForPublicGame(surface);
    },
  );
  test(
    'full source can use more than four requests with append-only unchanged features',
    () async {
      final h1 = sourceHtml.substring(0, 50), h2 = sourceHtml.substring(50);
      final j1 = sourceJs.substring(0, 40),
          j2 = sourceJs.substring(40, 100),
          j3 = sourceJs.substring(100);
      final client = _LocalClient([
        jsonEncode(sourcePlan),
        jsonEncode(boundSourceChunk('screen.html', h1, done: false)),
        jsonEncode(boundSourceChunk('screen.html', h2, prefix: h1)),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
        jsonEncode(boundSourceChunk('game.js', j1, done: false)),
        jsonEncode(boundSourceChunk('game.js', j2, prefix: j1, done: false)),
        jsonEncode(boundSourceChunk('game.js', j3, prefix: j1 + j2)),
      ]);
      final executor = SourceFixtureExecutor();
      final result = await run(client, executor);
      expect(result.isSuccess, isTrue, reason: result.stderr);
      expect(client.requests, hasLength(7));
      final surface = executor.executed!.actions.single['surface'] as Map;
      expect(surface['html'], sourceHtml);
      expect(surface['js'], sourceJs);
      for (final request in client.requests) {
        expect(request.last.content, instruction);
        expect(request.first.content, isNot(contains('COMPACT DRAFT')));
        expect(request.first.content, isNot(contains('js <= 1800')));
      }
    },
  );
  test(
    'local plan cannot supply identity, host actions or undeclared permissions',
    () async {
      final response = jsonEncode({
        ...sourcePlan,
        'id': 'model-owned',
        'actions': [
          {'type': 'skill.call'},
        ],
      });
      final client = _LocalClient([response]);
      final executor = SourceFixtureExecutor();
      final result = await run(client, executor);
      expect(result.isSuccess, isFalse);
      expect(result.failureCode, 'responseInvalid');
      expect(client.requests, hasLength(1));
      expect(executor.executed, isNull);
    },
  );
  test(
    'whole game action envelopes remain retired even for a local client',
    () async {
      final client = _LocalClient([
        jsonEncode({
          'reply': 'old game',
          'actions': [
            {
              'type': 'surface.show',
              'surface': {'html': sourceHtml, 'js': sourceJs},
            },
          ],
        }),
      ]);
      final executor = SourceFixtureExecutor();
      final result = await run(client, executor);
      expect(result.isSuccess, isFalse);
      expect(result.failureCode, 'responseInvalid');
      expect(client.requests, hasLength(1));
      expect(executor.executed, isNull);
    },
  );
}

class _LocalClient extends LLMClient {
  _LocalClient(this.outputs);
  final List<String> outputs;
  final requests = <List<Message>>[];
  int flattenedJsonCalls = 0;
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    requests.add(List<Message>.unmodifiable(messages));
    return outputs.removeAt(0);
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    flattenedJsonCalls++;
    throw StateError('roles must be preserved');
  }
}
