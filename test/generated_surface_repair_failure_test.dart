import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/surface/surface_execution_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime_diagnostic.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';

import 'support/project_source_fixture.dart';

const _badSource = '$sourceJs\nfetch("/unsupported-network");';
const _instruction = 'Build the complete requested game and every control.';
AgentProfile _profile() => AgentProfile(
  nickname: 'Test companion',
  avatar: '',
  bio: '',
  personalityTraits: [],
  catchphrase: '',
);

String _envelope({String source = _badSource, String reply = 'Writing'}) =>
    jsonEncode({
      'reply': reply,
      'actions': [
        {
          'type': 'surface.show',
          'surface': {
            'id': 'host-owned',
            'title': 'Complete game',
            'kind': 'fullscreen',
            'rendering': 'webApp',
            'experienceType': 'game',
            'html': sourceHtml,
            'css': sourceCss,
            'js': source,
            'manifest': {'actions': [], 'events': []},
          },
        },
      ],
    });

_RepairExecutor _executor() {
  final registry = LazyHostSkillRegistry(
    agentId: 'self',
    specs: SkillCatalog.all,
    enabledSkillIds: const {'freeform_surface'},
  );
  final hostGrant = registry.issueGrant(
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[
        registry.descriptorFor('FreeformSurface')!,
      ],
      maxSkills: 1,
      promptBudget: 4096,
    ),
  );
  final manager = SkillManager()
    ..registerSkill(hostGrant.activatedSkills.single);
  final scope = AppletLocalOwnership.currentScopeKey();
  return _RepairExecutor(
    manager,
    scope,
    SurfaceExecutionGrant.issue(
      executableHostGrant: hostGrant,
      agentId: 'self',
      appletScopeKey: scope,
      experienceType: SurfaceExperienceType.game,
    ),
  );
}

class _RepairExecutor extends AgentActionExecutor {
  _RepairExecutor(
    SkillManager manager,
    String scope,
    SurfaceExecutionGrant grant,
  ) : super(
        agentId: 'self',
        skillManager: manager,
        locale: AppLocale.en,
        expectedAppletScopeKey: scope,
        surfaceExecutionGrant: grant,
      );

  int validationCalls = 0;
  bool executed = false;
  SurfaceRuntimeDiagnostic? runtimeFailure;
  AgentAction? runtimeRepairedAction;

  @override
  void preflightSurfaceActions(AgentActionEnvelope envelope) {
    validationCalls += 1;
    SurfaceProjectValidator.validateForPublicGame(
      SurfaceProject.fromJson(envelope.actions.single['surface'] as Map),
    );
  }

  @override
  Future<AgentActionExecutionResult> execute(
    AgentActionEnvelope envelope, {
    SurfaceWorkerActionRepair? surfaceWorkerRepair,
  }) async {
    executed = true;
    if (runtimeFailure != null) {
      runtimeRepairedAction = await surfaceWorkerRepair!(
        envelope.actions.single,
        SurfaceWorkerRepairFailure(
          SurfaceWorkerFatalReason.runtimeFailed,
          diagnostic: runtimeFailure,
        ),
      );
    }
    return const AgentActionExecutionResult();
  }
}

class _EnvelopeClient extends LLMClient {
  _EnvelopeClient(this.outputs);
  final List<Object> outputs;
  int calls = 0;

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls += 1;
    final output = outputs.removeAt(0);
    if (output is! String) throw output;
    return output;
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => appServices.testMode = true);
  tearDown(appServices.reset);

  test(
    'runtime repair passes authenticated source facts into the ordinary producer',
    () async {
      const broken = '$sourceJs\nmissingContract();';
      final executor = _executor()
        ..runtimeFailure = SurfaceRuntimeDiagnostic(
          category: 'reference_error',
          sourceHash: SurfaceRuntimeDiagnostic.hashSource(broken),
          line: 2,
          column: 1,
        );
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(js: broken),
        jsonEncode({
          'fileId': 'game.js',
          'baseHash': sourceWorkspaceDigest(broken),
          'edits': [
            {'oldText': 'missingContract();', 'newText': 'const ready=1;'},
          ],
        }),
      ]);
      final result = await debugStructuredActionProcess(
        llmClient: client,
        profile: _profile(),
        instruction: _instruction,
        systemPrompt: 'One structured response.',
        executor: executor,
        locale: AppLocale.en,
        generatedGameSurfaceId: 'host-owned',
      );
      expect(result.isSuccess, isTrue);
      expect(client.requests, hasLength(5));
      expect(
        client.requests.last.first.content,
        contains('Authenticated host engine diagnostic:'),
      );
      expect(
        client.requests.last.first.content,
        contains('"category":"reference_error"'),
      );
      final repaired = executor.runtimeRepairedAction!['surface'] as Map;
      expect(repaired['js'], contains('const ready=1;'));
      expect(repaired['js'], isNot(contains('missingContract();')));
    },
  );

  final failures = <(Object, GeneratedTaskFailureCode)>[
    (
      StateError('PRIVATE_PROVIDER_FAILURE_AND_KEY'),
      GeneratedTaskFailureCode.modelUnavailable,
    ),
    (
      TimeoutException('PRIVATE_TIMEOUT_AND_KEY'),
      GeneratedTaskFailureCode.modelTimeout,
    ),
    (
      const HostedLLMFailure(HostedLLMFailureKind.authentication),
      GeneratedTaskFailureCode.modelAuthentication,
    ),
    (
      const HostedLLMFailure(HostedLLMFailureKind.contextLimit),
      GeneratedTaskFailureCode.modelContextLimit,
    ),
    (
      const HostedLLMFailure(HostedLLMFailureKind.consent),
      GeneratedTaskFailureCode.modelConsentRequired,
    ),
    (
      const HostedLLMFailure(HostedLLMFailureKind.quota),
      GeneratedTaskFailureCode.modelQuotaExceeded,
    ),
    (
      const LLMResponseIntegrityException.publicFailure(
        'modelStreamInterrupted',
      ),
      GeneratedTaskFailureCode.modelStreamInterrupted,
    ),
    (
      const GeneratedTaskFailure(GeneratedTaskFailureCode.interrupted),
      GeneratedTaskFailureCode.interrupted,
    ),
  ];

  for (final (failure, expected) in failures) {
    for (final sourceMode in [true, false]) {
      test(
        '${sourceMode ? 'source' : 'envelope'} repair preserves ${expected.name} instead of validation failure',
        () async {
          final executor = _executor();
          final sourceClient = SourceFixtureClient([
            ...sourceFixtureResponses(js: _badSource),
            // Source mode reduces only optional display ranges after known
            // context rejection. Keep rejecting through its zero-display
            // request so the terminal provider category remains testable.
            ...List.filled(
              expected == GeneratedTaskFailureCode.modelContextLimit ? 32 : 1,
              failure,
            ),
          ]);
          final envelopeClient = _EnvelopeClient([_envelope(), failure]);
          final result = await debugStructuredActionProcess(
            llmClient: sourceMode ? sourceClient : envelopeClient,
            profile: _profile(),
            instruction: _instruction,
            systemPrompt: 'One structured response.',
            executor: executor,
            locale: AppLocale.en,
            generatedGameSurfaceId: sourceMode ? 'host-owned' : null,
          );
          expect(result.isSuccess, isFalse);
          expect(result.failureCode, expected.name);
          expect(result.stderr, isNot(contains('PRIVATE_')));
          expect(executor.validationCalls, 1);
          expect(executor.executed, isFalse);
          if (sourceMode) {
            if (expected == GeneratedTaskFailureCode.modelContextLimit) {
              expect(sourceClient.requests.length, greaterThan(5));
              expect(sourceClient.requests.length, lessThan(25));
              expect(
                sourceClient.requests.map((request) => request.last.content),
                everyElement(_instruction),
              );
            } else {
              expect(sourceClient.requests, hasLength(5));
            }
            expect(sourceClient.ordinaryCalls, 0);
          } else {
            expect(envelopeClient.calls, 2);
          }
        },
      );
    }
  }

  test(
    'a returned repair that fails validation keeps validation category',
    () async {
      final executor = _executor();
      final client = _EnvelopeClient([_envelope(), _envelope()]);
      final result = await debugStructuredActionProcess(
        llmClient: client,
        profile: _profile(),
        instruction: _instruction,
        systemPrompt: 'One structured response.',
        executor: executor,
        locale: AppLocale.en,
      );
      expect(result.isSuccess, isFalse);
      expect(
        result.failureCode,
        GeneratedTaskFailureCode.surfaceValidationFailed.name,
      );
      expect(client.calls, 2);
      expect(executor.validationCalls, 2);
      expect(executor.executed, isFalse);
    },
  );

  for (final repair in [
    '{"reply":',
    _envelope(source: sourceJs, reply: 'Changed protected reply'),
  ]) {
    test(
      'invalid repair contract stays distinct from failed validation',
      () async {
        final executor = _executor();
        final client = _EnvelopeClient([_envelope(), repair]);
        final result = await debugStructuredActionProcess(
          llmClient: client,
          profile: _profile(),
          instruction: _instruction,
          systemPrompt: 'One structured response.',
          executor: executor,
          locale: AppLocale.en,
        );
        expect(result.isSuccess, isFalse);
        expect(
          result.failureCode,
          GeneratedTaskFailureCode.responseInvalid.name,
        );
        expect(client.calls, 2);
        expect(executor.validationCalls, 1);
        expect(executor.executed, isFalse);
      },
    );
  }
}
