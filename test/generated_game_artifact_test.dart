import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'support/project_source_fixture.dart';

const instruction =
    'Build my complete game with all requested screens and controls; choose missing details.';
GeneratedGameArtifact artifact(
  SourceFixtureClient client, {
  bool Function()? shouldCancel,
  List<GeneratedTaskCheckpoint>? phases,
}) => GeneratedGameArtifact(
  client: client,
  instruction: instruction,
  surfaceId: 'game-host-owned',
  zh: false,
  shouldCancel: shouldCancel,
  onCheckpoint: (phase, {publicSummary}) => phases?.add(phase),
);
void main() {
  test(
    'planned source files assemble one offline fullscreen read-only game',
    () async {
      final client = SourceFixtureClient(sourceFixtureResponses());
      final phases = <GeneratedTaskCheckpoint>[];
      final envelope = await artifact(client, phases: phases).generate();
      expect(client.requests, hasLength(4));
      expect(client.ordinaryCalls, 0);
      final surface = SurfaceProject.fromJson(
        envelope.actions.single['surface'] as Map,
      );
      expect(surface.id, 'game-host-owned');
      expect(surface.kind, SurfaceKind.fullscreen);
      expect(surface.rendering, SurfaceRendering.webApp);
      expect(surface.experienceType, SurfaceExperienceType.game);
      expect(surface.manifest.actions, isEmpty);
      expect(surface.manifest.events.map((v) => v.name), [
        'game.state',
        'game.event',
      ]);
      expect(surface.html, sourceHtml);
      expect(surface.css, sourceCss);
      expect(surface.js, sourceJs);
      SurfaceProjectValidator.validateForPublicGame(surface);
      expect(phases.first, GeneratedTaskCheckpoint.sourcePlanning);
      expect(
        phases.where((v) => v == GeneratedTaskCheckpoint.sourceFileComplete),
        hasLength(3),
      );
      for (final request in client.requests) {
        expect(request.map((m) => m.role), ['system', 'user']);
        expect(request.last.content, instruction);
        expect(request.first.content, isNot(contains('COMPACT DRAFT')));
        expect(
          request.first.content,
          isNot(contains('representative version')),
        );
      }
    },
  );
  test(
    'only display metadata is bounded; source and authoring requirements are preserved',
    () async {
      final plan = {
        ...sourcePlan,
        'title': 't' * 100,
        'summary': 's' * 600,
        'skillInstructions': 'd' * 2600,
      };
      final client = SourceFixtureClient(sourceFixtureResponses(plan: plan));
      final drafts = <SourceWorkspaceSnapshot>[];
      final envelope = await GeneratedGameArtifact(
        client: client,
        instruction: instruction,
        surfaceId: 'game-host-owned',
        zh: false,
        onDraft: drafts.add,
      ).generate();
      final surface = envelope.actions.single['surface'] as Map;
      expect((surface['title'] as String).length, 80);
      expect(envelope.reply.length, 240);
      expect(surface['skillInstructions'], 'd' * 2600);
      expect(drafts.last.blueprint!.skillInstructions, 'd' * 2600);
      expect(surface['js'], sourceJs);
    },
  );
  test('JSON script markers and escaping remain plain source data', () async {
    final plan = {
      ...sourcePlan,
      'skillInstructions': 'Dr.Claw.\n```javascript\nplay()\n```',
    };
    const js = 'const text="Dr.Claw.";\nconst slash="\\\\";';
    final envelope = await artifact(
      SourceFixtureClient(sourceFixtureResponses(plan: plan, js: js)),
    ).generate();
    expect((envelope.actions.single['surface'] as Map)['js'], js);
  });
  test(
    'invalid source responses stall with no invented complete artifact',
    () async {
      final client = SourceFixtureClient(['bad', 'bad', 'bad']);
      await expectLater(
        artifact(client).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(client.requests, hasLength(3));
    },
  );
  test(
    'the source plan cannot grant model host actions or game authority',
    () async {
      final client = SourceFixtureClient([
        jsonEncode({
          ...sourcePlan,
          'actions': [
            {'type': 'voice.speak'},
          ],
        }),
      ]);
      await expectLater(
        artifact(client).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.responseInvalid,
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );
  test('file repair preserves metadata and unmodified source files', () async {
    const fixed = 'const fixed=true;';
    final client = SourceFixtureClient([
      ...sourceFixtureResponses(),
      jsonEncode(boundSourceChunk('game.js', fixed)),
    ]);
    final producer = artifact(client);
    final original = await producer.generate();
    final repaired = await producer.repair(
      original,
      'surface worker first frame rejected: runtimeError',
    );
    final before = original.actions.single['surface'] as Map;
    final after = repaired.actions.single['surface'] as Map;
    for (final key in [
      'id',
      'title',
      'summary',
      'kind',
      'rendering',
      'manifest',
      'experienceType',
      'category',
      'placement',
      'html',
      'css',
      'skillInstructions',
    ]) {
      expect(after[key], before[key], reason: key);
    }
    expect(repaired.reply, original.reply);
    expect(after['js'], fixed);
    expect(client.requests, hasLength(5));
    expect(
      client.requests.last.first.content,
      contains('"sourceVersion":"current"'),
    );
    expect(client.requests.last.first.content, contains(jsonEncode(sourceJs)));
  });
  test('unsupported transport is not retried into another API mode', () async {
    const error = LLMResponseIntegrityException.publicFailure(
      'structuredOutputUnsupported',
    );
    final client = SourceFixtureClient([error]);
    await expectLater(artifact(client).generate(), throwsA(same(error)));
    expect(client.requests, hasLength(1));
  });
  test('cancelled admission has no source request or artifact', () async {
    var cancel = false;
    final client = SourceFixtureClient(sourceFixtureResponses())
      ..beforeAdmission = () => cancel = true;
    await expectLater(
      artifact(client, shouldCancel: () => cancel).generate(),
      throwsA(
        isA<GeneratedTaskFailure>().having(
          (e) => e.code,
          'code',
          GeneratedTaskFailureCode.interrupted,
        ),
      ),
    );
    expect(client.requests, isEmpty);
  });
  test(
    'a late planning response cannot start a file after cancellation',
    () async {
      var cancel = false;
      final client = SourceFixtureClient(sourceFixtureResponses())
        ..afterResponse = () => cancel = true;
      await expectLater(
        artifact(client, shouldCancel: () => cancel).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );
  test(
    'runtime executes only the host-assembled source project envelope',
    () async {
      final client = SourceFixtureClient(sourceFixtureResponses());
      final executor = SourceFixtureExecutor();
      final result = await debugStructuredActionProcess(
        llmClient: client,
        profile: AgentProfile(
          nickname: 'Matt',
          avatar: '',
          bio: '',
          personalityTraits: [],
          catchphrase: '',
        ),
        instruction: instruction,
        systemPrompt: 'PRIVATE_PERSONA_CONTEXT',
        executor: executor,
        locale: AppLocale.en,
        generatedGameSurfaceId: 'game-host-owned',
      );
      expect(result.isSuccess, isTrue, reason: result.stderr);
      expect(executor.executed!.actions.single.type, 'surface.show');
      expect(client.requests, hasLength(4));
      expect(
        client.requests
            .expand((r) => r)
            .any((m) => m.content.contains('PRIVATE_PERSONA_CONTEXT')),
        isFalse,
      );
    },
  );
  test(
    'runtime keeps precise transport failure without executing source',
    () async {
      final executor = SourceFixtureExecutor();
      final result = await debugStructuredActionProcess(
        llmClient: SourceFixtureClient([
          const LLMResponseIntegrityException.publicFailure(
            'modelStreamInterrupted',
          ),
        ]),
        profile: AgentProfile(
          nickname: 'Matt',
          avatar: '',
          bio: '',
          personalityTraits: [],
          catchphrase: '',
        ),
        instruction: instruction,
        systemPrompt: 'unused',
        executor: executor,
        locale: AppLocale.en,
        generatedGameSurfaceId: 'game-host-owned',
      );
      expect(result.isSuccess, isFalse);
      expect(result.failureCode, 'modelStreamInterrupted');
      expect(executor.executed, isNull);
    },
  );
}
