import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/context_stats_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_production_metrics_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_observability.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<SkillSpec> originalCatalog;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          _,
        ) async {
          return 1;
        });
    for (final channel in <MethodChannel>[
      const MethodChannel('xyz.luan/audioplayers.global'),
      const MethodChannel('xyz.luan/audioplayers'),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
    }
  });

  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    appServices.put(SecureStorageService());
    appServices.put(AgentTaskJobStore());
    final mode = appServices.put(MaasoAgentModeService());
    mode.pipelineMode.value = AgentPipelineMode.directCloud;
    originalCatalog = List<SkillSpec>.from(SkillCatalog.all);
  });

  tearDown(() {
    SkillCatalog.all
      ..clear()
      ..addAll(originalCatalog);
    appServices.reset();
  });

  tearDownAll(() {
    for (final channel in <MethodChannel>[
      const MethodChannel('flutter_tts'),
      const MethodChannel('xyz.luan/audioplayers.global'),
      const MethodChannel('xyz.luan/audioplayers'),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  test('runtime binds SkillManager contract identity to its agent', () async {
    SkillCatalog.all.clear();
    final runtime = AgentRuntime(
      agentId: 'contract-agent',
      profile: _profile(),
      llmClient: _NoActionLlm(),
    );
    addTearDown(runtime.dispose);

    await runtime.init(enabledSkillIds: const <String>{});

    expect(runtime.skillManager.actionContractAgentId, 'contract-agent');
  });

  test(
    'runtime keeps its exact sealed account contract after account switch',
    () async {
      SkillCatalog.all.clear();
      final accountA = await _runtimeContractHarness('account-a');
      final runtime = AgentRuntime(
        agentId: 'contract-agent',
        profile: _profile(),
        llmClient: _NoActionLlm(),
        actionContract: accountA.service,
        productionActionCatalog: accountA.catalog,
        requirePinnedActionContract: true,
        useAppServicesActionContractFallback: false,
      );
      addTearDown(runtime.dispose);
      await runtime.init(enabledSkillIds: const <String>{});

      var handlerCalls = 0;
      final skill = _CountingNavigationSkill(() => handlerCalls += 1);
      runtime.skillManager.registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'listPages');
      final accountAOutcome =
          jsonDecode(
                await runtime.skillManager.invokeTool(
                  tool,
                  const <String, dynamic>{},
                  callId: 'account-a-call',
                ),
              )
              as Map<String, dynamic>;
      expect(accountAOutcome['status'], 'ok');
      expect(accountAOutcome['data'], <Object?>[
        <String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'id': 'home', 'title': 'Home'},
          ],
        },
      ]);
      expect(handlerCalls, 1);

      await accountA.service.sealAndDrain();
      final accountB = await _runtimeContractHarness('account-b');
      appServices.put<ProductionActionDefinitionCatalog>(accountB.catalog);
      appServices.put<ActionContractV2Service>(accountB.service);

      final stale =
          jsonDecode(
                await runtime.skillManager.invokeTool(
                  tool,
                  const <String, dynamic>{},
                  callId: 'after-account-switch',
                ),
              )
              as Map<String, dynamic>;
      expect(stale['code'], 'contract_authority_unavailable');
      expect(handlerCalls, 1);
      expect(accountB.audit.records, isEmpty);
    },
  );

  test(
    'default runtime is explicitly ungoverned and ignores global contract',
    () async {
      SkillCatalog.all.clear();
      final global = await _runtimeContractHarness('global-account');
      appServices.put<ProductionActionDefinitionCatalog>(global.catalog);
      appServices.put<ActionContractV2Service>(global.service);
      final runtime = AgentRuntime(
        agentId: 'legacy-agent',
        profile: _profile(),
        llmClient: _NoActionLlm(),
      );
      addTearDown(runtime.dispose);
      await runtime.init(enabledSkillIds: const <String>{});

      var handlerCalls = 0;
      final skill = _CountingNavigationSkill(() => handlerCalls += 1);
      runtime.skillManager.registerSkill(skill);
      final output = await runtime.skillManager.invokeTool(
        SkillManager.nativeToolName(skill, 'listPages'),
        const <String, dynamic>{},
        callId: 'legacy-call',
      );

      expect(
        output,
        jsonEncode(<String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'id': 'home', 'title': 'Home'},
          ],
        }),
      );
      expect(handlerCalls, 1);
      expect(global.audit.records, isEmpty);
    },
  );

  test(
    'strict runtime rejects missing pinned dependencies during init',
    () async {
      SkillCatalog.all.clear();
      final runtime = AgentRuntime(
        agentId: 'strict-agent',
        profile: _profile(),
        llmClient: _NoActionLlm(),
        requirePinnedActionContract: true,
        useAppServicesActionContractFallback: false,
      );
      addTearDown(runtime.dispose);

      await expectLater(
        runtime.init(enabledSkillIds: const <String>{}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'action_contract_dependencies_unavailable',
          ),
        ),
      );
    },
  );

  test(
    'lazy-host kill switch is rechecked and activation is observable',
    () async {
      var factoryCalls = 0;
      SkillCatalog.all
        ..clear()
        ..add(
          _spec(
            id: 'alpha',
            skillName: 'AlphaHost',
            summary: 'Alpha host',
            terms: const <String>['alpha ritual'],
            factory: (_) {
              factoryCalls++;
              return _RecordingHostSkill('AlphaHost');
            },
          ),
        );
      final metrics = AgentProductionMetricsService();
      final rollout = AgentCapabilityRolloutService();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _NoActionLlm(),
        productionMetrics: metrics,
        capabilityRollout: rollout,
      );
      addTearDown(runtime.dispose);
      addTearDown(rollout.onClose);
      await runtime.init(enabledSkillIds: const <String>{'alpha'});

      expect(
        (await runtime.chat('please use alpha ritual', const [])).isSuccess,
        isTrue,
      );
      expect(factoryCalls, 0);
      expect(
        metrics
            .snapshot()
            .routing
            .activationOutcomeCounts[SkillActivationOutcome.denied],
        1,
      );

      rollout.update(AgentCapabilityRollout.lazyActivationOnly);
      expect(
        (await runtime.chat(
          'please use alpha ritual again',
          const [],
        )).isSuccess,
        isTrue,
      );

      final snapshot = metrics.snapshot();
      expect(factoryCalls, 1);
      expect(snapshot.firstResponse.count, 1);
      expect(
        snapshot.firstResponseOutcomeCounts[AgentFirstResponseOutcome.success],
        1,
      );
      expect(snapshot.routing.routingCount, 2);
      expect(snapshot.routing.catalogSize.max, 1);
      expect(
        snapshot.routing.activationOutcomeCounts[SkillActivationOutcome
            .selected],
        1,
      );
    },
  );

  test(
    'page-scope boost is removed immediately when its gate is off',
    () async {
      SkillCatalog.all
        ..clear()
        ..add(
          _spec(
            id: 'creator',
            skillName: 'Creator',
            summary: 'creator neutral',
            terms: const <String>['draftword extra'],
            pageScopes: const <String>['selfie'],
            methods: const <String>['draftSelfieVideo'],
            factory: (_) =>
                _RecordingHostSkill('Creator', methodName: 'draftSelfieVideo'),
          ),
        );
      final metrics = AgentProductionMetricsService();
      final rollout = AgentCapabilityRolloutService(
        initial: AgentCapabilityRollout.lazyActivationOnly,
      );
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _NoActionLlm(),
        productionMetrics: metrics,
        capabilityRollout: rollout,
        currentRoute: () => '/selfie',
      );
      addTearDown(runtime.dispose);
      addTearDown(rollout.onClose);
      await runtime.init(enabledSkillIds: const <String>{'creator'});

      await runtime.chat('draftword please extra', const []);

      rollout.update(
        const AgentCapabilityRollout(
          requestLazyHostActivation: true,
          requestPageSkillDefaults: true,
        ),
      );
      await runtime.chat('draftword please extra', const []);

      final routing = metrics.snapshot().routing;
      expect(routing.routingCount, 2);
      expect(routing.dispositionCounts[SkillRouteDisposition.clarify], 1);
      expect(routing.dispositionCounts[SkillRouteDisposition.selected], 1);
      expect(
        routing.explanations['router_dispositions'],
        containsPair('clarify', 1),
      );
      expect(
        routing.explanations['router_dispositions'],
        containsPair('selected', 1),
      );
      expect(routing.explanations['reasons'], containsPair('lowConfidence', 1));
      expect(routing.explanations['reasons'], containsPair('selected', 1));
    },
  );

  test(
    'first user response is measured once inside an existing outer trace',
    () async {
      SkillCatalog.all.clear();
      final metrics = AgentProductionMetricsService();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _NoActionLlm(),
        productionMetrics: metrics,
      );
      addTearDown(runtime.dispose);
      await runtime.init(enabledSkillIds: const <String>{});

      await TurnTrace.run(
        'home.startup_greeting',
        () => runtime.chat(
          'startup',
          const <Message>[],
          origin: TurnOrigin.system,
        ),
      );
      expect(metrics.snapshot().firstResponse.count, 0);

      await TurnTrace.run(
        'home.send',
        () => runtime.chat('first user turn', const <Message>[]),
      );
      await TurnTrace.run(
        'home.send',
        () => runtime.chat('second user turn', const <Message>[]),
      );

      final firstResponse = metrics.snapshot().firstResponse;
      expect(firstResponse.count, 1);
      expect(
        metrics
            .snapshot()
            .firstResponseOutcomeCounts[AgentFirstResponseOutcome.success],
        1,
      );
    },
  );

  test(
    'first response records the first admitted reply segment before chat ends',
    () async {
      SkillCatalog.all.clear();
      appServices.find<MaasoAgentModeService>().pipelineMode.value =
          AgentPipelineMode.proxyDefault;
      final metrics = AgentProductionMetricsService();
      final llm = _BlockingReplyDeltaLlm();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
        productionMetrics: metrics,
      );
      addTearDown(runtime.dispose);
      await runtime.init(enabledSkillIds: const <String>{});

      final chat = runtime.chat('hello', const <Message>[]);
      await llm.blankDeltaConsumed.future;
      expect(metrics.snapshot().firstResponse.count, 0);

      llm.allowReplyDelta.complete();
      await llm.replyDeltaConsumed.future;
      // Raw tokens are still buffered until the complete segment is admitted
      // to the visible reply. They must not count as a user response yet.
      expect(metrics.snapshot().firstResponse.count, 0);
      llm.allowSegmentBoundary.complete();
      await llm.segmentBoundaryConsumed.future;

      final early = metrics.snapshot();
      expect(llm.finishStream.isCompleted, isFalse);
      expect(early.firstResponse.count, 1);
      expect(
        early.firstResponseOutcomeCounts[AgentFirstResponseOutcome.success],
        1,
      );
      expect(
        early.firstResponseOutcomeCounts[AgentFirstResponseOutcome.error],
        0,
      );

      llm.finishStream.complete();
      expect((await chat).isSuccess, isTrue);
      expect(metrics.snapshot().firstResponse.count, 1);
    },
  );

  test(
    'reply delta success is not overwritten by a terminal exception',
    () async {
      SkillCatalog.all.clear();
      appServices.find<MaasoAgentModeService>().pipelineMode.value =
          AgentPipelineMode.proxyDefault;
      appServices.put<ContextStatsService>(_ThrowingContextStatsService());
      final metrics = AgentProductionMetricsService();
      final llm = _BlockingReplyDeltaLlm();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
        productionMetrics: metrics,
      );
      addTearDown(runtime.dispose);
      await runtime.init(enabledSkillIds: const <String>{});

      final chat = runtime.chat('hello', const <Message>[]);
      await llm.blankDeltaConsumed.future;
      llm.allowReplyDelta.complete();
      await llm.replyDeltaConsumed.future;
      expect(metrics.snapshot().firstResponse.count, 0);
      llm.allowSegmentBoundary.complete();
      await llm.segmentBoundaryConsumed.future;
      expect(
        metrics
            .snapshot()
            .firstResponseOutcomeCounts[AgentFirstResponseOutcome.success],
        1,
      );

      llm.finishStream.complete();
      await expectLater(chat, throwsA(isA<StateError>()));

      final finalSnapshot = metrics.snapshot();
      expect(finalSnapshot.firstResponse.count, 1);
      expect(
        finalSnapshot.firstResponseOutcomeCounts[AgentFirstResponseOutcome
            .success],
        1,
      );
      expect(
        finalSnapshot.firstResponseOutcomeCounts[AgentFirstResponseOutcome
            .error],
        0,
      );
    },
  );

  test(
    'first response falls back to the final error without a delta',
    () async {
      SkillCatalog.all.clear();
      final metrics = AgentProductionMetricsService();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _FailingNoDeltaLlm(),
        productionMetrics: metrics,
      );
      addTearDown(runtime.dispose);
      await runtime.init(enabledSkillIds: const <String>{});

      final result = await runtime.chat('hello', const <Message>[]);

      expect(result.isSuccess, isFalse);
      final snapshot = metrics.snapshot();
      expect(snapshot.firstResponse.count, 1);
      expect(
        snapshot.firstResponseOutcomeCounts[AgentFirstResponseOutcome.success],
        0,
      );
      expect(
        snapshot.firstResponseOutcomeCounts[AgentFirstResponseOutcome.error],
        1,
      );
    },
  );
}

SkillSpec _spec({
  required String id,
  required String skillName,
  required String summary,
  List<String> terms = const <String>[],
  List<String> pageScopes = const <String>[],
  List<String> methods = const <String>['run'],
  required AgentSkill Function(String agentId) factory,
}) => SkillSpec(
  id: id,
  name: id,
  description: id,
  icon: Icons.extension_rounded,
  color: Colors.blue,
  category: SkillCategory.knowledge,
  factory: factory,
  hostRouting: HostSkillRoutingManifest(
    skillName: skillName,
    summary: summary,
    methods: methods,
    nativeMethods: methods,
    terms: terms,
    pageScopes: pageScopes,
  ),
);

AgentProfile _profile() => AgentProfile(
  nickname: 'Hiyori',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

class _RecordingHostSkill extends AgentSkill {
  _RecordingHostSkill(this._name, {this.methodName = 'run'});

  final String _name;
  final String methodName;

  @override
  String get skillName => _name;

  @override
  String get description => 'Recording host';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        methodName: (_) => jsonEncode(<String, Object?>{'status': 'ok'}),
      };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas =>
      <String, Map<String, dynamic>>{
        methodName: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
      };
}

final class _CountingNavigationSkill extends AgentSkill {
  _CountingNavigationSkill(this._onCall);

  final void Function() _onCall;

  @override
  String get skillName => 'AppNavigate';

  @override
  String get description => 'Counting contract test skill';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'listPages': (_) {
          _onCall();
          return jsonEncode(<String, Object?>{
            'pages': <Object?>[
              <String, Object?>{'id': 'home', 'title': 'Home'},
            ],
          });
        },
      };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas =>
      <String, Map<String, dynamic>>{
        'listPages': const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
          'additionalProperties': false,
        },
      };
}

Future<_RuntimeContractHarness> _runtimeContractHarness(
  String accountScope,
) async {
  final now = DateTime.utc(2026, 8, 30, 9);
  final flags = await MaasoFeatureFlagService(
    store: _RuntimeFlagStore(),
    compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
      MaasoFeatureFlag.actionContractV2: FeatureRolloutMode.enforce,
    },
    clock: () => now,
  ).init();
  await flags.assign(
    flag: MaasoFeatureFlag.actionContractV2,
    mode: FeatureRolloutMode.enforce,
    revision: 1,
    expiresAt: now.add(const Duration(hours: 1)),
  );
  final catalog = ProductionActionDefinitionCatalog.intrinsics();
  final audit = _RuntimeAuditSink();
  final service = ActionContractV2Service(
    featureFlags: flags,
    catalog: catalog,
    audit: audit,
    accountScope: accountScope,
    accountGeneration: 1,
    mountIsCurrent: () => true,
  );
  return _RuntimeContractHarness(
    service: service,
    catalog: catalog,
    audit: audit,
  );
}

final class _RuntimeContractHarness {
  const _RuntimeContractHarness({
    required this.service,
    required this.catalog,
    required this.audit,
  });

  final ActionContractV2Service service;
  final ProductionActionDefinitionCatalog catalog;
  final _RuntimeAuditSink audit;
}

final class _RuntimeAuditSink implements ActionContractV2AuditSink {
  final List<ActionContractAuditRecord> records = <ActionContractAuditRecord>[];

  @override
  String record(ActionContractAuditRecord record) {
    records.add(record);
    return 'runtime-audit:${record.definition.id}';
  }
}

final class _RuntimeFlagStore implements MaasoFeatureFlagAssignmentStore {
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

class _NoActionLlm implements LLMClient {
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      '{"reply":"ok","actions":[]}';

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"ok"}');
  }
}

class _BlockingReplyDeltaLlm extends _NoActionLlm {
  final blankDeltaConsumed = Completer<void>();
  final allowReplyDelta = Completer<void>();
  final replyDeltaConsumed = Completer<void>();
  final allowSegmentBoundary = Completer<void>();
  final segmentBoundaryConsumed = Completer<void>();
  final finishStream = Completer<void>();

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"   "}');
    blankDeltaConsumed.complete();
    await allowReplyDelta.future;
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"hello"}');
    replyDeltaConsumed.complete();
    await allowSegmentBoundary.future;
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"."}');
    segmentBoundaryConsumed.complete();
    await finishStream.future;
  }
}

class _FailingNoDeltaLlm extends _NoActionLlm {
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    throw StateError('no reply available');
  }
}

class _ThrowingContextStatsService extends ContextStatsService {
  @override
  void record({
    required String? modelName,
    required int systemPromptChars,
    required int userInputChars,
    required int responseChars,
  }) {
    throw StateError('terminal failure after reply delta');
  }
}
