import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/surface/surface_interaction_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test(
    'invalid later skill call prevents every preceding side effect',
    () async {
      final authorization = _authorization(
        _TestSkill(name: 'Atomic', schemas: _valueSchema),
      );
      final emotions = <EmotionStateEvent>[];
      final spoken = <String>[];
      final subscription = EventBus().on<EmotionStateEvent>().listen(
        emotions.add,
      );
      addTearDown(subscription.cancel);
      final executor = _executor(authorization, speak: spoken.add);

      final result = await executor.execute(
        AgentActionEnvelope(
          reply: 'must not be spoken',
          actions: <AgentAction>[
            const AgentAction(
              type: 'emotion.set',
              data: <String, Object?>{'emotion': 'happy'},
            ),
            _skillAction(authorization.tool, const <String, Object?>{
              'value': 7,
            }),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(result.ok, isFalse);
      expect(result.errors.single, contains('bad_arguments'));
      expect(emotions, isEmpty);
      expect(spoken, isEmpty);
      expect(authorization.skill.callCount, 0);
    },
  );

  test(
    'invalid later surface call prevents every preceding side effect',
    () async {
      final authorization = _authorization(_TestSkill(name: 'SurfaceGate'));
      final surface = SurfaceRuntime();
      await surface.show(_visibleV2Surface('surface-preflight'));
      final emotions = <EmotionStateEvent>[];
      final spoken = <String>[];
      final subscription = EventBus().on<EmotionStateEvent>().listen(
        emotions.add,
      );
      addTearDown(subscription.cancel);
      final executor = _executor(
        authorization,
        surfaceRuntime: surface,
        speak: spoken.add,
      );

      final result = await executor.execute(
        AgentActionEnvelope(
          reply: 'must not be spoken',
          actions: const <AgentAction>[
            AgentAction(
              type: 'emotion.set',
              data: <String, Object?>{'emotion': 'happy'},
            ),
            AgentAction(
              type: 'voice.speak',
              data: <String, Object?>{'text': 'must not be spoken'},
            ),
            AgentAction(
              type: 'surface.call',
              data: <String, Object?>{
                'action': 'counter.set',
                'data': <String, Object?>{'value': 'not-an-integer'},
              },
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(result.ok, isFalse);
      expect(result.errors.single, contains('surface.call'));
      expect(result.errors.single, contains('invalid_arguments'));
      expect(emotions, isEmpty);
      expect(spoken, isEmpty);
    },
  );

  test('surface call preflight fails closed without registering a runtime', () {
    final authorization = _authorization(_TestSkill(name: 'NoSurface'));
    final executor = _executor(authorization);

    expect(
      () => executor.preflightSurfaceActions(
        AgentActionEnvelope(
          reply: '',
          actions: const <AgentAction>[
            AgentAction(
              type: 'surface.call',
              data: <String, Object?>{
                'action': 'missing',
                'data': <String, Object?>{},
              },
            ),
          ],
        ),
      ),
      throwsA(isA<Exception>()),
    );
    expect(appServices.isRegistered<SurfaceRuntime>(), isFalse);
  });

  test('runtime schema preflight runs before beforeExecute', () async {
    final authorization = _authorization(
      _TestSkill(name: 'GateSchema', schemas: _valueSchema),
    );
    var gateCalls = 0;

    final result = await debugStructuredActionProcess(
      llmClient: _SingleLlm(
        '{"reply":"","actions":[{"type":"skill.call",'
        '"tool":"${authorization.tool}","args":{"value":7}}]}',
      ),
      profile: _profile(),
      instruction: 'respond',
      systemPrompt: 'Return JSON.',
      executor: _executor(authorization),
      locale: AppLocale.en,
      beforeExecute: (_) async {
        gateCalls += 1;
        return true;
      },
    );

    expect(result.isSuccess, isFalse);
    expect(gateCalls, 0);
    expect(authorization.skill.callCount, 0);
  });

  test('bad Surface arguments do not consume the interaction grant', () async {
    final authorization = _authorization(
      _TestSkill(
        name: 'FreeformSurface',
        method: 'editSurface',
        schemas: const <String, Map<String, dynamic>>{
          'editSurface': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'surfaceId': <String, dynamic>{'type': 'string'},
              'html': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['surfaceId', 'html'],
            'additionalProperties': false,
          },
        },
      ),
    );
    const surfaceId = 'active-surface';
    final surface = SurfaceRuntime();
    await surface.show(_visibleSurface(surfaceId));
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final interactionGrant = SurfaceInteractionGrant.issue(
      executableHostGrant: authorization.grant,
      agentId: 'self',
      appletScopeKey: scopeKey,
      request: const SurfaceInteractionRequest(
        operation: SurfaceInteractionOperation.edit,
        targetSurfaceId: surfaceId,
      ),
      surfaceRuntime: surface,
    );
    final executor = _executor(
      authorization,
      surfaceRuntime: surface,
      surfaceInteractionGrant: interactionGrant,
      expectedAppletScopeKey: scopeKey,
    );

    final invalid = await executor.execute(
      _envelope(
        _skillAction(authorization.tool, const <String, Object?>{
          'surfaceId': surfaceId,
        }),
      ),
    );
    final valid = await executor.execute(
      _envelope(
        _skillAction(authorization.tool, const <String, Object?>{
          'surfaceId': surfaceId,
          'html': '<main>edited</main>',
        }),
      ),
    );

    expect(invalid.ok, isFalse);
    expect(invalid.errors.single, contains('bad_arguments'));
    expect(valid.ok, isTrue);
    expect(authorization.skill.callCount, 1);
  });

  test('preflight requires the exact granted manager binding', () async {
    final authorization = _authorization(
      _TestSkill(name: 'Exact', schemas: _valueSchema),
    );
    final imposter = _TestSkill(name: 'Exact', schemas: _valueSchema);
    final manager = SkillManager()
      ..registerSkill(imposter)
      ..registerSkill(authorization.skill);
    final executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: manager,
      locale: AppLocale.en,
      executableHostGrant: authorization.grant,
    );

    expect(
      () => executor.preflightSkillActions(
        _envelope(
          _skillAction(authorization.tool, const <String, Object?>{
            'value': 'ok',
          }),
        ),
      ),
      throwsA(
        isA<StructuredActionSchemaPreflightException>().having(
          (error) => error.code,
          'code',
          'skill_not_granted',
        ),
      ),
    );
    expect(imposter.callCount, 0);
    expect(authorization.skill.callCount, 0);
  });

  test(
    'default rejects bad and malformed schemas but permits missing schema',
    () async {
      final bad = _authorization(
        _TestSkill(name: 'BadValue', schemas: _valueSchema),
      );
      final malformed = _authorization(
        _TestSkill(
          name: 'Malformed',
          schemas: const <String, Map<String, dynamic>>{
            'run': <String, dynamic>{'type': 'mystery'},
          },
        ),
      );
      final missing = _authorization(_TestSkill(name: 'Legacy'));

      final badResult = await _executor(bad).execute(
        _envelope(_skillAction(bad.tool, const <String, Object?>{'value': 7})),
      );
      final malformedResult = await _executor(malformed).execute(
        _envelope(
          _skillAction(malformed.tool, const <String, Object?>{'value': 'ok'}),
        ),
      );
      final missingResult = await _executor(missing).execute(
        _envelope(_skillAction(missing.tool, const <String, Object?>{})),
      );

      expect(badResult.errors.single, contains('bad_arguments'));
      expect(malformedResult.errors.single, contains('host_schema_invalid'));
      expect(missingResult.ok, isTrue);
      expect(bad.skill.callCount, 0);
      expect(malformed.skill.callCount, 0);
      expect(missing.skill.callCount, 1);
    },
  );

  test(
    'shadow reports redacted diagnostics while strict rejects missing schema',
    () async {
      final shadowed = _authorization(
        _TestSkill(name: 'Shadowed', schemas: _valueSchema),
      );
      final diagnostics = <StructuredActionSchemaDiagnostic>[];
      final shadowResult =
          await _executor(
            shadowed,
            rollout: StructuredActionSchemaRollout.shadow,
            onDiagnostic: diagnostics.add,
          ).execute(
            _envelope(
              _skillAction(shadowed.tool, const <String, Object?>{
                'value': 7,
                'secret': 'do-not-leak',
              }),
            ),
          );
      final strict = _authorization(_TestSkill(name: 'StrictLegacy'));
      final strictResult =
          await _executor(
            strict,
            rollout: StructuredActionSchemaRollout.strict,
          ).execute(
            _envelope(_skillAction(strict.tool, const <String, Object?>{})),
          );

      expect(shadowResult.ok, isTrue);
      expect(shadowed.skill.callCount, 1);
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single.code, 'bad_arguments');
      expect(diagnostics.join(' '), isNot(contains('do-not-leak')));
      expect(strictResult.errors.single, contains('skill_call_schema_missing'));
      expect(strict.skill.callCount, 0);
    },
  );

  test('non-object and non-JSON object arguments fail with stable codes', () {
    final authorization = _authorization(
      _TestSkill(name: 'JsonArgs', schemas: _valueSchema),
    );
    final executor = _executor(authorization);

    expect(
      () => executor.preflightSkillActions(
        _envelope(_skillAction(authorization.tool, 'not-an-object')),
      ),
      throwsA(
        isA<StructuredActionSchemaPreflightException>().having(
          (error) => error.code,
          'code',
          'skill_call_args_not_object',
        ),
      ),
    );
    expect(
      () => executor.preflightSkillActions(
        _envelope(
          _skillAction(authorization.tool, <String, Object?>{
            'value': 'ok',
            'nested': <Object?, Object?>{1: 'do-not-leak'},
          }),
        ),
      ),
      throwsA(
        isA<StructuredActionSchemaPreflightException>().having(
          (error) => error.code,
          'code',
          'bad_arguments',
        ),
      ),
    );
  });

  test(
    'execution revalidates a grant invalidated by an earlier await',
    () async {
      final authorization = _authorization(
        _TestSkill(name: 'Reloaded', schemas: _valueSchema),
      );
      final spoken = <String>[];
      final executor = _executor(
        authorization,
        speak: (text) {
          spoken.add(text);
          authorization.registry.reload(const <String>{});
        },
      );

      final result = await executor.execute(
        AgentActionEnvelope(
          reply: '',
          actions: <AgentAction>[
            const AgentAction(
              type: 'voice.speak',
              data: <String, Object?>{'text': 'invalidate'},
            ),
            _skillAction(authorization.tool, const <String, Object?>{
              'value': 'ok',
            }),
          ],
        ),
      );

      expect(spoken, <String>['invalidate']);
      expect(result.errors.single, contains('skill_not_granted'));
      expect(authorization.skill.callCount, 0);
    },
  );

  test(
    'execute rechecks after a gate invalidates the preflight grant',
    () async {
      final authorization = _authorization(
        _TestSkill(name: 'GateReload', schemas: _valueSchema),
      );
      var gateCalls = 0;
      final emotions = <EmotionStateEvent>[];
      final subscription = EventBus().on<EmotionStateEvent>().listen(
        emotions.add,
      );
      addTearDown(subscription.cancel);

      final result = await debugStructuredActionProcess(
        llmClient: _SingleLlm(
          '{"reply":"","actions":['
          '{"type":"emotion.set","emotion":"happy"},'
          '{"type":"skill.call","tool":"${authorization.tool}",'
          '"args":{"value":"ok"}}]}',
        ),
        profile: _profile(),
        instruction: 'respond',
        systemPrompt: 'Return JSON.',
        executor: _executor(authorization),
        locale: AppLocale.en,
        beforeExecute: (_) async {
          gateCalls += 1;
          authorization.registry.reload(const <String>{});
          return true;
        },
      );
      await Future<void>.delayed(Duration.zero);

      expect(result.isSuccess, isFalse);
      expect(gateCalls, 1);
      expect(emotions, isEmpty);
      expect(authorization.skill.callCount, 0);
    },
  );
}

const _valueSchema = <String, Map<String, dynamic>>{
  'run': <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'value': <String, dynamic>{'type': 'string'},
    },
    'required': <String>['value'],
    'additionalProperties': false,
  },
};

final class _Authorization {
  const _Authorization({
    required this.skill,
    required this.registry,
    required this.grant,
    required this.manager,
    required this.tool,
  });

  final _TestSkill skill;
  final LazyHostSkillRegistry registry;
  final ExecutableHostGrant grant;
  final SkillManager manager;
  final String tool;
}

_Authorization _authorization(_TestSkill skill) {
  final nativeMethods = skill.nativeToolSchemas?.keys.toList() ?? <String>[];
  final registry = LazyHostSkillRegistry(
    agentId: 'self',
    specs: <SkillSpec>[
      SkillSpec(
        id: skill.skillName.toLowerCase(),
        name: skill.skillName,
        description: skill.description,
        icon: Icons.extension_rounded,
        color: Colors.blue,
        category: SkillCategory.knowledge,
        factory: (_) => skill,
        hostRouting: HostSkillRoutingManifest(
          skillName: skill.skillName,
          summary: skill.description,
          methods: <String>[skill.method],
          nativeMethods: nativeMethods,
          terms: <String>[skill.skillName],
        ),
      ),
    ],
  );
  final descriptor = registry.descriptorFor(skill.skillName)!;
  final grant = registry.issueGrant(
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[descriptor],
      maxSkills: 1,
      promptBudget: 1024,
    ),
  );
  final activated = grant.activatedSkills.single as _TestSkill;
  final manager = SkillManager()..registerSkill(activated);
  return _Authorization(
    skill: activated,
    registry: registry,
    grant: grant,
    manager: manager,
    tool: SkillManager.nativeToolName(activated, activated.method),
  );
}

AgentActionExecutor _executor(
  _Authorization authorization, {
  AgentSpeak? speak,
  StructuredActionSchemaRollout rollout =
      StructuredActionSchemaRollout.schemaBackedEnforce,
  StructuredActionSchemaDiagnosticSink? onDiagnostic,
  SurfaceRuntime? surfaceRuntime,
  SurfaceInteractionGrant? surfaceInteractionGrant,
  String? expectedAppletScopeKey,
}) => AgentActionExecutor(
  agentId: 'self',
  skillManager: authorization.manager,
  locale: AppLocale.en,
  executableHostGrant: authorization.grant,
  speak: speak,
  schemaRollout: rollout,
  onSchemaDiagnostic: onDiagnostic,
  surfaceRuntime: surfaceRuntime,
  surfaceInteractionGrant: surfaceInteractionGrant,
  expectedAppletScopeKey: expectedAppletScopeKey,
);

AgentActionEnvelope _envelope(AgentAction action) =>
    AgentActionEnvelope(reply: '', actions: <AgentAction>[action]);

AgentAction _skillAction(String tool, Object? arguments) => AgentAction(
  type: 'skill.call',
  data: <String, Object?>{'tool': tool, 'args': arguments},
);

SurfaceProject _visibleSurface(String id) =>
    SurfaceProject.fromJson(<String, Object?>{
      'id': id,
      'title': id,
      'kind': 'fullscreen',
      'rendering': 'dom',
      'html': '<main>ready</main>',
    });

SurfaceProject _visibleV2Surface(String id) => SurfaceProject(
  id: id,
  title: id,
  kind: SurfaceKind.fullscreen,
  rendering: SurfaceRendering.dom,
  html: '<main>ready</main>',
  css: '',
  js: '',
  transparent: false,
  placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
  manifest: SurfaceManifest.v2(
    actions: <SurfaceEntry>[
      SurfaceEntry.v2(
        name: 'counter.set',
        schema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'value': <String, Object?>{'type': 'integer'},
          },
          'required': <String>['value'],
          'additionalProperties': false,
        },
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
      ),
    ],
  ),
  backend: const <String, Object?>{},
  revisions: const <SurfaceRevision>[],
);

AgentProfile _profile() => AgentProfile(
  nickname: 'Schema Tester',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['careful'],
  catchphrase: 'ok',
);

final class _TestSkill extends AgentSkill
    implements StructuredActionPromptSchemaProvider {
  _TestSkill({
    required this.name,
    this.method = 'run',
    this.schemas = const <String, Map<String, dynamic>>{},
  });

  final String name;
  final String method;
  final Map<String, Map<String, dynamic>> schemas;
  int callCount = 0;

  @override
  String get skillName => name;

  @override
  String get description => 'Schema preflight test skill';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        method: (_) {
          callCount += 1;
          return '{}';
        },
      };

  @override
  StructuredActionPromptSchemas get structuredActionPromptSchemas =>
      schemas.isEmpty
      ? StructuredActionPromptSchemas.none
      : StructuredActionPromptSchemas(schemas);
}

final class _SingleLlm implements LLMClient {
  const _SingleLlm(this.response);

  final String response;

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      response;

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnsupportedError('not used');

  @override
  Stream<String> streamChat(List<Message> messages, {Duration? timeout}) =>
      const Stream<String>.empty();

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => const Stream<LLMStreamEvent>.empty();
}
