import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/production_agent_action_definitions.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/intent/creation_intent.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart'
    show SkillActionContractMetadata;

const _create = <String, Object?>{
  'type': 'creation.intent',
  'mode': 'create',
  'kind': 'game',
  'requirements': '由触屏控制重力、收集星星和进入下一关的任意互动作品。',
};
const _none = <String, Object?>{'type': 'creation.intent', 'mode': 'none'};

AgentActionEnvelope _envelope(
  List<Map<String, Object?>> actions, {
  String reply = '',
  AgentActionScope scope = AgentActionScope.chat,
}) => AgentActionEnvelope.parse(
  jsonEncode({'reply': reply, 'actions': actions}),
  scope: scope,
);

AgentActionExecutor _executor({
  Future<String> Function(CreationIntent)? onIntent,
  Future<void> Function(String)? speak,
  String? jobId,
  bool Function()? shouldCancel,
  ActionContractV2Service? contract,
  ProductionActionDefinitionCatalog? catalog,
}) => AgentActionExecutor(
  agentId: 'self',
  skillManager: SkillManager(),
  locale: AppLocale.zh,
  generatedTaskJobId: jobId,
  onCreationIntent: onIntent,
  speak: speak ?? (_) async {},
  shouldCancel: shouldCancel,
  actionContract: contract,
  productionActionCatalog: catalog,
  useAppServicesActionContractFallback: false,
  avatarBehaviorDirector: AvatarBehaviorDirector(
    agentId: 'self',
    runtimeProvider: () => null,
    emitEmotion: (_) {},
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => appServices.testMode = true);
  tearDown(appServices.reset);

  test(
    'existing reply/actions without creation intent retain compatibility',
    () async {
      final spoken = <String>[];
      final response = _envelope(const [], reply: 'Hello');
      final result = await _executor(
        speak: (text) async => spoken.add(text),
      ).execute(response);
      expect(result.ok, isTrue);
      expect(spoken, ['Hello']);
      expect(response.validateCreationIntentActions(), isNull);
    },
  );

  for (final intent in <Map<String, Object?>>[
    _none,
    _create,
    {
      'type': 'creation.intent',
      'mode': 'propose',
      'kind': 'utility',
      'requirements': '记录当天观察到的星座。',
    },
    {
      'type': 'creation.intent',
      'mode': 'confirm',
      'proposalId': 'proposal-host-1',
    },
    {
      'type': 'creation.intent',
      'mode': 'edit',
      'projectId': 'project-host-1',
      'requirements': '加入深色模式。',
    },
    {'type': 'creation.intent', 'mode': 'cancel', 'taskId': 'task-host-1'},
    {'type': 'creation.intent', 'mode': 'retry', 'taskId': 'task-host-1'},
    {'type': 'creation.intent', 'mode': 'status', 'taskId': 'task-host-1'},
  ]) {
    test(
      '${intent['mode']} flat intent parses as data and freezes its fields',
      () {
        final envelope = _envelope([intent]);
        expect(
          envelope.validateCreationIntentActions()!.mode.name,
          intent['mode'],
        );
        expect(envelope.actions.single.type, 'creation.intent');
        expect(
          () => envelope.actions.single.data['mode'] = 'cancel',
          throwsUnsupportedError,
        );
        expect(
          AgentActionEnvelope.parse(jsonEncode(envelope.toJson())).toJson(),
          envelope.toJson(),
        );
      },
    );
  }

  for (final malformed in <Map<String, Object?>>[
    {'type': 'creation.intent'},
    {'type': 'creation.intent', 'mode': 'unknown'},
    {'type': 'creation.intent', 'mode': 'none', 'kind': 'game'},
    {'type': 'creation.intent', 'mode': 'create', 'kind': 'game'},
    {..._create, 'requirements': ''},
    {..._create, 'kind': 'anything'},
    {
      ..._create,
      'args': {'force': true},
    },
    {..._create, 'grant': true},
    {'type': 'creation.intent', 'mode': 'cancel', 'taskId': 'invalid secret\n'},
    {'type': 'creation.intent', 'mode': 'retry'},
    {'type': 'creation.intent', 'mode': 'status', 'taskId': 'invalid secret\n'},
  ]) {
    test('malformed intent rejects the whole parsed batch: $malformed', () {
      expect(
        () => _envelope([
          {'type': 'voice.speak', 'text': 'Earlier'},
          malformed,
        ]),
        throwsA(
          isA<AgentActionProtocolException>().having(
            (error) => error.code,
            'code',
            'creation_intent_invalid',
          ),
        ),
      );
    });
  }

  test('repeated and nonterminal intent records fail before effects', () async {
    final traces = <String>[];
    final executor = _executor(
      speak: (text) async => traces.add(text),
      onIntent: (_) async {
        traces.add('intent');
        return '';
      },
    );
    for (final actions in <List<AgentAction>>[
      [
        const AgentAction(
          type: 'voice.speak',
          data: {'type': 'voice.speak', 'text': 'Earlier'},
        ),
        AgentAction.fromJson(_none),
        AgentAction.fromJson(_create),
      ],
      [
        AgentAction.fromJson(_create),
        const AgentAction(
          type: 'voice.speak',
          data: {'type': 'voice.speak', 'text': 'Later'},
        ),
      ],
      [
        const AgentAction(
          type: 'voice.speak',
          data: {'type': 'voice.speak', 'text': 'Earlier'},
        ),
        const AgentAction(
          type: 'creation.intent',
          data: {'type': 'creation.intent', 'mode': 'create'},
        ),
      ],
    ]) {
      final result = await executor.execute(
        AgentActionEnvelope(reply: 'Fallback', actions: actions),
      );
      expect(result.ok, isFalse);
      expect(
        result.errors.single,
        contains('creation.intent: creation_intent_'),
      );
      expect(traces, isEmpty);
    }
    expect(
      () => _envelope([_none, _create]),
      throwsA(
        isA<AgentActionProtocolException>().having(
          (error) => error.code,
          'code',
          'creation_intent_duplicate',
        ),
      ),
    );
    expect(
      () => _envelope([
        _create,
        {'type': 'voice.speak', 'text': 'Later'},
      ]),
      throwsA(
        isA<AgentActionProtocolException>().having(
          (error) => error.code,
          'code',
          'creation_intent_not_terminal',
        ),
      ),
    );
  });

  test(
    'no human callback cannot grant creation or an earlier voice effect',
    () async {
      final spoken = <String>[];
      final result = await _executor(speak: (text) async => spoken.add(text))
          .execute(
            _envelope([
              {'type': 'voice.speak', 'text': 'Not started'},
              _create,
            ], reply: 'Fallback'),
          );
      expect(result.ok, isFalse);
      expect(result.errors, ['creation.intent: creation_intent_not_granted']);
      expect(spoken, isEmpty);
    },
  );

  test(
    'owning human callback runs after explicit speech and fallback speech',
    () async {
      for (final explicitSpeech in [true, false]) {
        final traces = <String>[];
        final result =
            await _executor(
              speak: (text) async => traces.add(text),
              onIntent: (intent) async {
                traces.add('intent:${intent.mode.name}');
                return 'host-receipt';
              },
            ).execute(
              _envelope([
                if (explicitSpeech)
                  {'type': 'voice.speak', 'text': 'Intend to write'},
                _create,
              ], reply: 'Fallback intention'),
            );
        expect(result.ok, isTrue);
        expect(traces, [
          explicitSpeech ? 'Intend to write' : 'Fallback intention',
          'intent:create',
        ]);
        expect(result.observations, ['host-receipt']);
      }
    },
  );

  for (final mode in [CreationIntentMode.retry, CreationIntentMode.status]) {
    test(
      '${mode.name} dispatches only the exact host task through its human callback',
      () async {
        final received = <CreationIntent>[];
        final result =
            await _executor(
              onIntent: (intent) async {
                received.add(intent);
                return 'host-task-receipt';
              },
            ).execute(
              _envelope([
                {
                  'type': 'creation.intent',
                  'mode': mode.name,
                  'taskId': 'task-host-1',
                },
              ]),
            );
        expect(result.ok, isTrue);
        expect(received, hasLength(1));
        expect(received.single.mode, mode);
        expect(received.single.taskId, 'task-host-1');
        expect(received.single.requirements, isEmpty);
        expect(result.observations, ['host-task-receipt']);
      },
    );
  }

  for (final scope in [
    AgentActionScope.proactivePresence,
    AgentActionScope.notificationInteraction,
  ]) {
    test(
      '${scope.name} rejects intent even with an injected callback and bypassed parser',
      () async {
        final traces = <String>[];
        final result =
            await _executor(
              speak: (text) async => traces.add(text),
              onIntent: (_) async {
                traces.add('intent');
                return '';
              },
            ).execute(
              AgentActionEnvelope(
                reply: 'Fallback',
                scope: scope,
                actions: [AgentAction.fromJson(_create)],
              ),
            );
        expect(result.errors, [
          'creation.intent: creation_intent_scope_not_allowed',
        ]);
        expect(traces, isEmpty);
        expect(
          () => _envelope([_create], scope: scope),
          throwsA(isA<AgentActionProtocolException>()),
        );
      },
    );
  }

  test('generated worker cannot inherit a foreground callback', () async {
    var calls = 0;
    final result = await _executor(
      jobId: 'source-worker-1',
      onIntent: (_) async {
        calls += 1;
        return '';
      },
    ).execute(_envelope([_create]));
    expect(result.errors, [
      'creation.intent: creation_intent_task_not_allowed',
    ]);
    expect(calls, 0);
  });

  test(
    'native, realtime and other nonhuman channels reject before contract reservation',
    () async {
      var calls = 0;
      final executor = _executor(
        onIntent: (_) async {
          calls += 1;
          return '';
        },
      );
      for (final channel in ActionContractChannel.values.where(
        (value) => value != ActionContractChannel.structured,
      )) {
        await expectLater(
          executor.prepareActionContract(
            _envelope([_create]),
            channel: channel,
          ),
          throwsA(
            isA<AgentActionProtocolException>().having(
              (error) => error.code,
              'code',
              'creation_intent_channel_not_allowed',
            ),
          ),
        );
      }
      expect(calls, 0);
    },
  );

  test(
    'cancelled or failed preceding presentation never admits creation',
    () async {
      var calls = 0;
      final failed = await _executor(
        speak: (_) async => throw StateError('presentation-unavailable'),
        onIntent: (_) async {
          calls += 1;
          return '';
        },
      ).execute(_envelope([_create], reply: 'Intend to write'));
      expect(failed.ok, isFalse);
      final cancelled = await _executor(
        shouldCancel: () => true,
        onIntent: (_) async {
          calls += 1;
          return '';
        },
      ).execute(_envelope([_create]));
      expect(cancelled.ok, isFalse);
      expect(calls, 0);
    },
  );

  test(
    'callback failures expose a stable code without provider detail',
    () async {
      final result = await _executor(
        onIntent: (_) async => throw StateError('private-provider-detail'),
      ).execute(_envelope([_create]));
      expect(result.errors, [
        'creation.intent: creation_intent_admission_failed',
      ]);
      expect(result.errors.join(), isNot(contains('private-provider-detail')));
    },
  );

  test(
    'metadata is not authority and enforce needs a host-selected exact local ID',
    () async {
      for (final allowed in [false, true]) {
        final host = await _contract(allowed: allowed);
        addTearDown(host.service.sealAndDrain);
        var calls = 0;
        final executor = _executor(
          contract: host.service,
          catalog: host.catalog,
          onIntent: (_) async {
            calls += 1;
            return '';
          },
        );
        final envelope = _envelope([_create]);
        final prepared = await executor.prepareActionContract(envelope);
        expect(prepared, isNotNull);
        expect(prepared!.isRejected, !allowed);
        final result = await executor.executeAdmitted(envelope, prepared);
        expect(result.ok, allowed, reason: result.errors.join(';'));
        expect(calls, allowed ? 1 : 0);
        await executor.executeAdmitted(envelope, prepared);
        expect(calls, allowed ? 1 : 0);
        final definition = host.catalog.find('creation.intent')!;
        expect(definition.channels, {ActionContractChannel.structured});
        expect(definition.definition.scopes, {AgentActionScope.chat});
        await expectLater(
          definition.definition.execute({'mode': 'none'}),
          throwsStateError,
        );
      }
    },
  );

  test('malformed intents reserve no contract ticket or invocation', () async {
    final host = await _contract(allowed: true);
    addTearDown(host.service.sealAndDrain);
    final executor = _executor(
      contract: host.service,
      catalog: host.catalog,
      onIntent: (_) async => '',
    );
    final invalid = AgentActionEnvelope(
      reply: '',
      actions: [AgentAction.fromJson(_none), AgentAction.fromJson(_create)],
    );
    await expectLater(
      executor.prepareActionContract(invalid),
      throwsA(isA<AgentActionProtocolException>()),
    );
    expect(host.service.pendingTicketCount, 0);
    expect(host.service.semanticInvocationCount, 0);
  });

  test(
    'a granted read-only search plus terminal none succeeds under enforce',
    () async {
      final host = await _contract(allowed: true);
      addTearDown(host.service.sealAndDrain);
      final search = _SearchFixture();
      final registry = LazyHostSkillRegistry(
        agentId: 'self',
        specs: [
          SkillSpec(
            id: 'search-fixture',
            name: 'search-fixture',
            description: 'Offline search boundary fixture',
            icon: Icons.search,
            color: Colors.blue,
            category: SkillCategory.knowledge,
            factory: (_) => search,
            hostRouting: HostSkillRoutingManifest(
              skillName: search.skillName,
              summary: 'Read-only search fixture',
              methods: ['search'],
              nativeMethods: ['search'],
            ),
          ),
        ],
      );
      final grant = registry.issueGrant(
        TurnSkillGrant.bounded(
          rankedDescriptors: [registry.descriptorFor(search.skillName)!],
          maxSkills: 1,
          promptBudget: 8192,
        ),
      );
      final manager = SkillManager(
        actionContract: host.service,
        productionCatalog: host.catalog,
        actionContractAgentId: 'self',
        contractMetadataResolver: (_, _, _) =>
            const SkillActionContractMetadata.readOnly(),
      )..registerSkill(search);
      var semanticCalls = 0;
      final executor = AgentActionExecutor(
        agentId: 'self',
        skillManager: manager,
        locale: AppLocale.en,
        actionContract: host.service,
        productionActionCatalog: host.catalog,
        executableHostGrant: grant,
        useAppServicesActionContractFallback: false,
        onCreationIntent: (intent) async {
          expect(intent.mode, CreationIntentMode.none);
          semanticCalls += 1;
          return '';
        },
      );
      final result = await executor.execute(
        _envelope([
          {
            'type': 'skill.call',
            'tool': SkillManager.nativeToolName(search, 'search'),
            'args': {'query': 'offline fixture'},
          },
          _none,
        ]),
      );
      expect(result.ok, isTrue, reason: result.errors.join(';'));
      expect(search.calls, 1);
      expect(semanticCalls, 1);
      expect(result.observations.single, contains('skill.call'));
      final ungranted = await executor.execute(
        _envelope([
          {
            'type': 'skill.call',
            'tool': 'skill_ungranted_write',
            'args': <String, Object?>{},
          },
          _none,
        ]),
      );
      expect(ungranted.ok, isFalse);
      expect(search.calls, 1);
      expect(semanticCalls, 1);
    },
  );
}

class _SearchFixture extends AgentSkill {
  int calls = 0;

  @override
  String get skillName => 'WebSearchFixture';

  @override
  String get description => 'Offline read-only search';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'search': (_) {
      calls += 1;
      return '{"results":[]}';
    },
  };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'search': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
      },
      'required': ['query'],
      'additionalProperties': false,
    },
  };
}

Future<
  ({ActionContractV2Service service, ProductionActionDefinitionCatalog catalog})
>
_contract({required bool allowed}) async {
  final now = DateTime.utc(2026, 10, 12);
  final flags = await MaasoFeatureFlagService(
    store: _FlagStore(),
    compileMaximums: {
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
  registerProductionAgentActionDefinitions(catalog);
  final service = ActionContractV2Service(
    featureFlags: flags,
    catalog: catalog,
    audit: _Audit(),
    accountScope: 'account-a',
    accountGeneration: 1,
    mountIsCurrent: () => true,
    clock: () => now,
    enforcedReversibleLocalActionIds: allowed ? {'creation.intent'} : const {},
  );
  return (service: service, catalog: catalog);
}

class _Audit implements ActionContractV2AuditSink {
  @override
  String record(ActionContractAuditRecord record) =>
      'audit:${record.definition.id}';
}

class _FlagStore implements MaasoFeatureFlagAssignmentStore {
  final rows = <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> readAll() async => rows;

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    rows.add(assignment.toJson());
  }
}
