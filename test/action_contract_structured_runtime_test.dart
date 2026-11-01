import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
  });

  tearDown(() async {
    await appServices.reset();
  });

  test('late invalid action rejects before an earlier effect', () async {
    await _installContract(FeatureRolloutMode.enforce, includeSurface: true);
    var published = 0;
    final executor = _surfaceExecutor(() => published += 1);
    final result = await executor.execute(
      AgentActionEnvelope(
        scope: AgentActionScope.chat,
        reply: '',
        actions: <AgentAction>[
          _surfaceAction(),
          const AgentAction(
            type: 'missing.action',
            data: <String, Object?>{'type': 'missing.action'},
          ),
        ],
      ),
    );

    expect(result.ok, isFalse);
    expect(published, 0);
  });

  test(
    'contract rejection occurs before beforeExecute and action effects',
    () async {
      await _installContract(FeatureRolloutMode.enforce, includeSurface: true);
      var gateCalls = 0;
      var published = 0;
      final result = await debugStructuredActionProcess(
        llmClient: _SingleLlm(
          '{"reply":"","actions":['
          '{"type":"surface.call","action":"contract.test","data":{}},'
          '{"type":"missing.action"}]}',
        ),
        profile: _profile(),
        instruction: 'respond',
        systemPrompt: 'Return one JSON envelope.',
        actionScope: AgentActionScope.chat,
        executor: _surfaceExecutor(() => published += 1),
        locale: AppLocale.en,
        beforeExecute: (_) async {
          gateCalls += 1;
          return true;
        },
      );

      expect(result.isSuccess, isFalse);
      expect(gateCalls, 0);
      expect(published, 0);
    },
  );

  test('false beforeExecute abandons admission with zero effects', () async {
    final harness = await _installContract(
      FeatureRolloutMode.enforce,
      includeSurface: true,
    );
    var gateCalls = 0;
    var published = 0;
    final result = await debugStructuredActionProcess(
      llmClient: const _SingleLlm(
        '{"reply":"","actions":['
        '{"type":"surface.call","action":"contract.test","data":{}}]}',
      ),
      profile: _profile(),
      instruction: 'respond',
      systemPrompt: 'Return one JSON envelope.',
      actionScope: AgentActionScope.chat,
      executor: _surfaceExecutor(() => published += 1),
      locale: AppLocale.en,
      beforeExecute: (_) async {
        gateCalls += 1;
        return false;
      },
    );

    expect(result.isSuccess, isTrue, reason: result.stderr);
    expect(gateCalls, 1);
    expect(published, 0);
    expect(harness.service.pendingTicketCount, 0);
  });

  test('cancellation after beforeExecute abandons before effects', () async {
    final harness = await _installContract(
      FeatureRolloutMode.enforce,
      includeSurface: true,
    );
    var cancelled = false;
    var published = 0;
    final result = await debugStructuredActionProcess(
      llmClient: const _SingleLlm(
        '{"reply":"","actions":['
        '{"type":"surface.call","action":"contract.test","data":{}}]}',
      ),
      profile: _profile(),
      instruction: 'respond',
      systemPrompt: 'Return one JSON envelope.',
      actionScope: AgentActionScope.chat,
      executor: _surfaceExecutor(() => published += 1),
      locale: AppLocale.en,
      beforeExecute: (_) async {
        cancelled = true;
        return true;
      },
      shouldCancel: () => cancelled,
    );

    expect(result.isSuccess, isTrue, reason: result.stderr);
    expect(published, 0);
    expect(harness.service.pendingTicketCount, 0);
  });

  test('reply-only envelope admits both implicit calls in shadow', () async {
    final harness = await _installContract(FeatureRolloutMode.shadow);
    var speechCalls = 0;
    var emotionCalls = 0;
    final executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: SkillManager(),
      locale: AppLocale.en,
      speak: (_) => speechCalls += 1,
      avatarBehaviorDirector: AvatarBehaviorDirector(
        agentId: 'self',
        runtimeProvider: () => null,
        emitEmotion: (_) => emotionCalls += 1,
      ),
    );

    final result = await executor.execute(
      const AgentActionEnvelope(reply: 'Hello there', actions: <AgentAction>[]),
    );

    expect(result.ok, isTrue, reason: result.errors.join("; "));
    expect(speechCalls, 1);
    expect(emotionCalls, 1);
    expect(
      harness.audit.records.map((record) => record.definition.id).toSet(),
      <String>{'voice.fallback', 'avatar.auto_react'},
    );
  });

  test('off and shadow preserve the legacy result and effect count', () async {
    Future<({List<String> observations, List<String> errors, int effects})> run(
      FeatureRolloutMode? mode,
    ) async {
      await appServices.reset();
      appServices.testMode = true;
      if (mode != null) {
        await _installContract(mode, includeSurface: true);
      }
      var effects = 0;
      final result = await _surfaceExecutor(() => effects += 1).execute(
        AgentActionEnvelope(
          reply: '',
          actions: <AgentAction>[_surfaceAction()],
          scope: AgentActionScope.chat,
        ),
      );
      return (
        observations: result.observations,
        errors: result.errors,
        effects: effects,
      );
    }

    final legacy = await run(null);
    final off = await run(FeatureRolloutMode.off);
    final shadow = await run(FeatureRolloutMode.shadow);

    expect(off.observations, legacy.observations);
    expect(off.errors, legacy.errors);
    expect(off.effects, legacy.effects);
    expect(shadow.observations, legacy.observations);
    expect(shadow.errors, legacy.errors);
    expect(shadow.effects, legacy.effects);
  });

  test('enforce executes an eligible read-only action exactly once', () async {
    await _installContract(FeatureRolloutMode.enforce, includeSurface: true);
    var published = 0;
    final result = await _surfaceExecutor(() => published += 1).execute(
      AgentActionEnvelope(
        reply: '',
        actions: <AgentAction>[_surfaceAction()],
        scope: AgentActionScope.chat,
      ),
    );

    expect(result.ok, isTrue, reason: result.errors.join("; "));
    expect(published, 1);
    expect(result.errors, isEmpty);
  });

  test('enforce accepts an internal empty envelope as a no-op', () async {
    await _installContract(FeatureRolloutMode.enforce);
    final result = await AgentActionExecutor(
      agentId: 'self',
      skillManager: SkillManager(),
      locale: AppLocale.en,
    ).execute(const AgentActionEnvelope(reply: '', actions: <AgentAction>[]));

    expect(result.ok, isTrue, reason: result.errors.join("; "));
  });

  test('strict missing contract dependencies reject before callback', () async {
    final harness = await _installContract(
      FeatureRolloutMode.enforce,
      includeSurface: true,
    );
    var published = 0;
    final result =
        await AgentActionExecutor(
          agentId: 'self',
          skillManager: SkillManager(
            requirePinnedActionContract: true,
            useAppServicesActionContractFallback: false,
          ),
          locale: AppLocale.en,
          requirePinnedActionContract: true,
          useAppServicesActionContractFallback: false,
          surfaceRuntime: _ContractSurfaceRuntime(() => published += 1),
        ).execute(
          AgentActionEnvelope(
            scope: AgentActionScope.chat,
            reply: '',
            actions: <AgentAction>[_surfaceAction()],
          ),
        );

    expect(result.ok, isFalse);
    expect(published, 0);
    expect(harness.audit.records, isEmpty);
  });

  test(
    'explicit ungoverned executor ignores a global enforce service',
    () async {
      final harness = await _installContract(
        FeatureRolloutMode.enforce,
        includeSurface: true,
      );
      var published = 0;
      final result =
          await AgentActionExecutor(
            agentId: 'self',
            skillManager: SkillManager(
              useAppServicesActionContractFallback: false,
            ),
            locale: AppLocale.en,
            useAppServicesActionContractFallback: false,
            surfaceRuntime: _ContractSurfaceRuntime(() => published += 1),
          ).execute(
            AgentActionEnvelope(
              scope: AgentActionScope.chat,
              reply: '',
              actions: <AgentAction>[_surfaceAction()],
            ),
          );

      expect(result.ok, isTrue, reason: result.errors.join("; "));
      expect(published, 1);
      expect(harness.audit.records, isEmpty);
    },
  );

  test(
    'enforce suppresses behavior training while off and shadow retain it',
    () async {
      Future<int> observationsFor(FeatureRolloutMode mode) async {
        await appServices.reset();
        appServices.testMode = true;
        final harness = await _installContract(mode, includeSurface: true);
        var observations = 0;
        final result =
            await AgentActionExecutor(
              agentId: 'self',
              skillManager: SkillManager(),
              locale: AppLocale.en,
              surfaceRuntime: _ContractSurfaceRuntime(() {}),
              observeBehavior: ({required agentId, required succeeded}) {
                observations += 1;
              },
            ).execute(
              AgentActionEnvelope(
                scope: AgentActionScope.chat,
                reply: '',
                actions: <AgentAction>[_surfaceAction()],
              ),
            );
        expect(result.ok, isTrue, reason: result.errors.join("; "));
        await harness.service.sealAndDrain();
        await Future<void>.delayed(Duration.zero);
        return observations;
      }

      expect(await observationsFor(FeatureRolloutMode.enforce), 0);
      expect(await observationsFor(FeatureRolloutMode.off), 1);
      expect(await observationsFor(FeatureRolloutMode.shadow), 1);
    },
  );
}

AgentActionExecutor _surfaceExecutor(void Function() perform) =>
    AgentActionExecutor(
      agentId: 'self',
      skillManager: SkillManager(),
      locale: AppLocale.en,
      surfaceRuntime: _ContractSurfaceRuntime(perform),
    );

AgentAction _surfaceAction() => const AgentAction(
  type: 'surface.call',
  data: <String, Object?>{
    'type': 'surface.call',
    'action': 'contract.test',
    'data': <String, Object?>{},
  },
);

final class _ContractSurfaceRuntime extends SurfaceRuntime {
  _ContractSurfaceRuntime(this.perform);

  final void Function() perform;

  @override
  String? preflightCall(String action, Object? data) => null;

  @override
  Future<String?> surfaceCall(String action, Object? data) async {
    perform();
    return null;
  }
}

AgentProfile _profile() => AgentProfile(
  nickname: 'Contract Tester',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['careful'],
  catchphrase: 'ok',
);

Future<_ContractHarness> _installContract(
  FeatureRolloutMode mode, {
  bool includeSurface = false,
}) async {
  final now = DateTime.utc(2026, 8, 30, 8);
  final flags = await MaasoFeatureFlagService(
    store: _MemoryFlagStore(),
    compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
      MaasoFeatureFlag.actionContractV2: FeatureRolloutMode.enforce,
    },
    clock: () => now,
  ).init();
  await flags.assign(
    flag: MaasoFeatureFlag.actionContractV2,
    mode: mode,
    revision: 1,
    expiresAt: now.add(const Duration(hours: 1)),
  );
  final catalog = ProductionActionDefinitionCatalog.intrinsics();
  if (includeSurface) catalog.register(_surfaceDefinition());
  final audit = _AuditSink();
  final service = ActionContractV2Service(
    featureFlags: flags,
    catalog: catalog,
    audit: audit,
    accountScope: 'account-a',
    accountGeneration: 7,
    mountIsCurrent: () => true,
  );
  appServices.put<ProductionActionDefinitionCatalog>(catalog);
  appServices.put<ActionContractV2Service>(service);
  return _ContractHarness(audit: audit, service: service, catalog: catalog);
}

ProductionActionDefinition _surfaceDefinition() => ProductionActionDefinition(
  definition: ActionDefinition(
    id: 'surface.call',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, Object?>{
        'action': <String, Object?>{'type': 'string'},
        'data': <String, Object?>{'type': 'object'},
      },
      'required': <String>['action', 'data'],
      'additionalProperties': false,
    },
    outputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, Object?>{},
      'additionalProperties': false,
    },
    scopes: const <AgentActionScope>{AgentActionScope.chat},
    risk: ActionRisk.readOnly,
    consequencePolicy: ActionConsequencePolicy.reversible,
    targetResolver: (_) => 'surface:test',
    handler: (_) => throw StateError('metadata handler must not run'),
  ),
  channels: const <ActionContractChannel>{ActionContractChannel.surface},
  enforcementEligibility: ActionEnforcementEligibility.readOnly,
);

final class _ContractHarness {
  const _ContractHarness({
    required this.audit,
    required this.service,
    required this.catalog,
  });

  final _AuditSink audit;
  final ActionContractV2Service service;
  final ProductionActionDefinitionCatalog catalog;
}

final class _AuditSink implements ActionContractV2AuditSink {
  final List<ActionContractAuditRecord> records = <ActionContractAuditRecord>[];

  @override
  String record(ActionContractAuditRecord record) {
    records.add(record);
    return 'audit:${record.definition.id}';
  }
}

final class _MemoryFlagStore implements MaasoFeatureFlagAssignmentStore {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      rows.map(Map<String, Object?>.from).toList(growable: false);

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    rows.removeWhere((row) => row['flag'] == assignment.flag.key);
    rows.add(assignment.toJson());
  }
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
