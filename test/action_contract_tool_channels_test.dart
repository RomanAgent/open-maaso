import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/delayed_choice_executor.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/production_skill_action_metadata.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/agent/data/skills/tool_call_runner.dart';

void main() {
  group('SkillManager Action Contract V2', () {
    test(
      'off and shadow preserve exact output and one legacy effect',
      () async {
        for (final mode in <FeatureRolloutMode>[
          FeatureRolloutMode.off,
          FeatureRolloutMode.shadow,
        ]) {
          final harness = await _ContractHarness.create(mode: mode);
          final skill = _ProbeSkill(
            name: 'Identity',
            methodNames: const <String>['read'],
            nativeMethods: const <String>['read'],
            result: ' legacy bytes stay exact \n',
          );
          harness.manager.registerSkill(skill);
          final tool = SkillManager.nativeToolName(skill, 'read');

          final result = await harness.manager.invokeTool(
            tool,
            const <String, dynamic>{},
            callId: 'identity-$mode',
          );

          expect(result, ' legacy bytes stay exact \n');
          expect(skill.handlerCalls, 1);
          expect(
            harness.catalog.find(tool),
            same(harness.manager.productionDefinitionForTool(tool)),
          );
          expect(
            harness.audit.records,
            mode == FeatureRolloutMode.off ? isEmpty : hasLength(2),
          );
        }
      },
    );

    test('off and shadow rethrow the identical legacy exception', () async {
      for (final mode in <FeatureRolloutMode>[
        FeatureRolloutMode.off,
        FeatureRolloutMode.shadow,
      ]) {
        final harness = await _ContractHarness.create(mode: mode);
        final failure = StateError('legacy-sentinel');
        final skill = _ProbeSkill(
          name: 'Throwing',
          methodNames: const <String>['read'],
          nativeMethods: const <String>['read'],
          onInvoke: () => throw failure,
        );
        harness.manager.registerSkill(skill);
        final tool = SkillManager.nativeToolName(skill, 'read');

        Object? caught;
        try {
          await harness.manager.invokeTool(
            tool,
            const <String, dynamic>{},
            callId: 'throw-$mode',
          );
        } catch (error) {
          caught = error;
        }

        expect(caught, same(failure));
        expect(skill.handlerCalls, 1);
      }
    });

    test('native runner preserves provider call id in enforce audit', () async {
      final harness = await _ContractHarness.create(
        mode: FeatureRolloutMode.enforce,
      );
      final skill = _ProbeSkill(
        name: 'NativeRead',
        methodNames: const <String>['read'],
        nativeMethods: const <String>['read'],
        result: '{"value":7}',
      );
      harness.manager.registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'read');
      final client = _SingleToolClient(
        ToolCall(id: 'provider-call-42', name: tool, argumentsJson: '{}'),
      );

      await ToolCallRunner(
        client: client,
        skillManager: harness.manager,
        maxRounds: 2,
      ).run(messages: <Message>[Message.user('read')]);

      expect(skill.handlerCalls, 1);
      expect(
        jsonDecode(client.toolResults.single),
        containsPair('status', 'ok'),
      );
      expect(
        harness.audit.records.map((record) => record.invocation.callId),
        everyElement('provider-call-42'),
      );
      expect(
        harness.audit.records.map((record) => record.invocation.agentId),
        everyElement('agent-a'),
      );
    });

    test(
      'sanitized collision fails closed only in enforce with zero effect',
      () async {
        final harness = await _ContractHarness.create(
          mode: FeatureRolloutMode.enforce,
        );
        final first = _ProbeSkill(
          name: 'A.B',
          methodNames: const <String>['read'],
          nativeMethods: const <String>['read'],
          result: 'first',
        );
        final second = _ProbeSkill(
          name: 'A/B',
          methodNames: const <String>['read'],
          nativeMethods: const <String>['read'],
          result: 'second',
        );
        harness.manager
          ..registerSkill(first)
          ..registerSkill(second);
        final tool = SkillManager.nativeToolName(first, 'read');

        final result = jsonDecode(
          await harness.manager.invokeTool(
            tool,
            const <String, dynamic>{},
            callId: 'collision',
          ),
        );

        expect(result, containsPair('code', 'contract_rejected'));
        expect(first.handlerCalls, 0);
        expect(second.handlerCalls, 0);
        expect(harness.manager.toNativeTools().map(_openAiToolName), <String>[
          tool,
          tool,
        ]);
        expect(harness.manager.productionDefinitionForTool(tool), isNull);
      },
    );

    test(
      'sanitized collision keeps legacy first-match off and shadow',
      () async {
        for (final mode in <FeatureRolloutMode>[
          FeatureRolloutMode.off,
          FeatureRolloutMode.shadow,
        ]) {
          final harness = await _ContractHarness.create(mode: mode);
          final first = _ProbeSkill(
            name: 'Legacy.A',
            methodNames: const <String>['read'],
            nativeMethods: const <String>['read'],
            result: 'legacy-first',
          );
          final second = _ProbeSkill(
            name: 'Legacy/A',
            methodNames: const <String>['read'],
            nativeMethods: const <String>['read'],
            result: 'legacy-second',
          );
          harness.manager
            ..registerSkill(first)
            ..registerSkill(second);
          final tool = SkillManager.nativeToolName(first, 'read');

          final result = await harness.manager.invokeTool(
            tool,
            const <String, dynamic>{},
            callId: 'legacy-collision-${mode.name}',
          );

          expect(result, 'legacy-first');
          expect(first.handlerCalls, 1);
          expect(second.handlerCalls, 0);
          expect(harness.catalog.isConflicted(tool), isTrue);
        }
      },
    );

    test(
      'sanitized collision is shared across managers and fails closed',
      () async {
        final harness = await _ContractHarness.create(
          mode: FeatureRolloutMode.enforce,
        );
        final otherManager = SkillManager(
          actionContract: harness.service,
          productionCatalog: harness.catalog,
          actionContractAgentId: 'agent-b',
          contractMetadataResolver: (_, _, _) =>
              const SkillActionContractMetadata.readOnly(),
        );
        final first = _ProbeSkill(
          name: 'Cross.Manager',
          methodNames: const <String>['read'],
          nativeMethods: const <String>['read'],
          result: 'first',
        );
        final second = _ProbeSkill(
          name: 'Cross/Manager',
          methodNames: const <String>['read'],
          nativeMethods: const <String>['read'],
          result: 'second',
        );
        harness.manager.registerSkill(first);
        otherManager.registerSkill(second);
        final tool = SkillManager.nativeToolName(first, 'read');

        final firstResult = jsonDecode(
          await harness.manager.invokeTool(
            tool,
            const <String, dynamic>{},
            callId: 'cross-manager-first',
          ),
        );
        final secondResult = jsonDecode(
          await otherManager.invokeTool(
            tool,
            const <String, dynamic>{},
            callId: 'cross-manager-second',
          ),
        );

        expect(firstResult, containsPair('code', 'contract_rejected'));
        expect(secondResult, containsPair('code', 'contract_rejected'));
        expect(first.handlerCalls, 0);
        expect(second.handlerCalls, 0);
        expect(harness.catalog.isConflicted(tool), isTrue);
        expect(harness.catalog.findExact(tool), isNull);
      },
    );

    test(
      'schema drift rejects an old exact definition before effect',
      () async {
        final harness = await _ContractHarness.create(
          mode: FeatureRolloutMode.enforce,
        );
        final schema = <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
          'additionalProperties': false,
        };
        final skill = _ProbeSkill(
          name: 'SchemaDrift',
          methodNames: const <String>['read'],
          nativeMethods: const <String>['read'],
          schema: schema,
          result: 'should-not-run',
        );
        harness.manager.registerSkill(skill);
        final tool = SkillManager.nativeToolName(skill, 'read');
        (schema['properties'] as Map<String, dynamic>)['optional'] =
            <String, dynamic>{'type': 'string'};

        final result = jsonDecode(
          await harness.manager.invokeTool(
            tool,
            const <String, dynamic>{},
            callId: 'schema-drift',
          ),
        );

        expect(result, containsPair('code', 'contract_rejected'));
        expect(skill.handlerCalls, 0);
        expect(harness.manager.productionDefinitionForTool(tool), isNull);
      },
    );

    test('undeclared risk is unsupported in enforce', () async {
      final harness = await _ContractHarness.create(
        mode: FeatureRolloutMode.enforce,
        declareReadOnly: false,
      );
      final skill = _ProbeSkill(
        name: 'NoRiskGuess',
        methodNames: const <String>['read'],
        nativeMethods: const <String>['read'],
        result: 'should-not-run',
      );
      harness.manager.registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'read');

      final result = jsonDecode(
        await harness.manager.invokeTool(
          tool,
          const <String, dynamic>{},
          callId: 'unsupported-risk',
        ),
      );

      expect(result, containsPair('code', 'contract_rejected'));
      expect(skill.handlerCalls, 0);
    });

    test(
      'production output schema admits the existing handler exactly once',
      () async {
        final harness = await _ContractHarness.create(
          mode: FeatureRolloutMode.enforce,
          declareReadOnly: false,
          metadataResolver: productionSkillActionContractMetadata,
        );
        final skill = _ProbeSkill(
          name: 'AppNavigate',
          methodNames: const <String>['listPages'],
          nativeMethods: const <String>['listPages'],
          result: '{"pages":[{"id":"home","title":"Home"}]}',
        );
        harness.manager.registerSkill(skill);
        final tool = SkillManager.nativeToolName(skill, 'listPages');

        final result =
            jsonDecode(
                  await harness.manager.invokeTool(
                    tool,
                    const <String, dynamic>{},
                    callId: 'valid-production-output',
                  ),
                )
                as Map<String, dynamic>;

        expect(result, containsPair('status', 'ok'));
        expect(result, containsPair('code', 'ok'));
        expect(result['data'], <Object?>[
          <String, Object?>{
            'pages': <Object?>[
              <String, Object?>{'id': 'home', 'title': 'Home'},
            ],
          },
        ]);
        expect(skill.handlerCalls, 1);
      },
    );

    test(
      'production output schema rejects malformed JSON without leaking data',
      () async {
        final harness = await _ContractHarness.create(
          mode: FeatureRolloutMode.enforce,
          declareReadOnly: false,
          metadataResolver: productionSkillActionContractMetadata,
        );
        final skill = _ProbeSkill(
          name: 'AppNavigate',
          methodNames: const <String>['listPages'],
          nativeMethods: const <String>['listPages'],
          result: '{"pages":"private-sentinel","internal":"secret"}',
        );
        harness.manager.registerSkill(skill);
        final tool = SkillManager.nativeToolName(skill, 'listPages');

        final raw = await harness.manager.invokeTool(
          tool,
          const <String, dynamic>{},
          callId: 'malformed-production-output',
        );
        final result = jsonDecode(raw) as Map<String, dynamic>;

        expect(result, containsPair('status', 'failed'));
        expect(result, containsPair('code', 'invalid_tool_outcome'));
        expect(result.containsKey('data'), isFalse);
        expect(result.containsKey('display'), isFalse);
        expect(raw, isNot(contains('private-sentinel')));
        expect(raw, isNot(contains('secret')));
        expect(skill.handlerCalls, 1);
      },
    );

    test('semantic owners override generic entry channels centrally', () async {
      final harness = await _ContractHarness.create(
        mode: FeatureRolloutMode.shadow,
      );
      final appControl = _ProbeSkill(
        name: 'AppControl',
        methodNames: const <String>['execute'],
        nativeMethods: const <String>['execute'],
      );
      final surface = _ProbeSkill(
        name: 'FreeformSurface',
        methodNames: const <String>['showSurface'],
      );
      harness.manager
        ..registerSkill(appControl)
        ..registerSkill(surface);
      final appTool = SkillManager.nativeToolName(appControl, 'execute');
      final surfaceTool = SkillManager.nativeToolName(surface, 'showSurface');

      final appCall = harness.manager.contractCallForTool(
        toolName: appTool,
        arguments: const <String, dynamic>{},
        channel: ActionContractChannel.nativeTool,
      );
      final surfaceCall = harness.manager.contractCallForTool(
        toolName: surfaceTool,
        arguments: const <String, dynamic>{},
        channel: ActionContractChannel.structured,
      );

      expect(appCall.channel, ActionContractChannel.appControl);
      expect(surfaceCall.channel, ActionContractChannel.surface);
      expect(
        appCall.expectedDefinition!.allowsChannel(
          ActionContractChannel.appControl,
        ),
        isTrue,
      );
      expect(
        surfaceCall.expectedDefinition!.allowsChannel(
          ActionContractChannel.surface,
        ),
        isTrue,
      );
    });
  });

  group('local-agent Action Contract V2', () {
    test(
      'manifest read risk without output schema rejects before effect',
      () async {
        final harness = await _ContractHarness.create(
          mode: FeatureRolloutMode.enforce,
          declareReadOnly: false,
        );
        final skill = _ProbeSkill(
          name: 'LocalRead',
          methodNames: const <String>['lookup'],
          result: '{"answer":42}',
        );
        harness.manager.registerSkill(skill);
        final invoker = LocalSkillInvoker(skillManager: harness.manager);

        final result = await invoker.invoke(
          _localManifest(
            id: 'local/read',
            skillName: skill.skillName,
            method: 'lookup',
            risk: LocalSkillRisk.read,
          ),
          const <String, dynamic>{},
          contractCallId: 'local-read-call',
        );

        expect(result.status, LocalSkillResultStatus.unavailable);
        expect(
          jsonDecode(result.output),
          containsPair('code', 'contract_rejected'),
        );
        expect(skill.handlerCalls, 0);
        final definition = harness.catalog.find('local.local_read');
        expect(definition, isNotNull);
        expect(definition!.definition.outputSchema, isNull);
        expect(
          definition.enforcementEligibility,
          ActionEnforcementEligibility.unsupported,
        );
        expect(
          harness.audit.records.map((record) => record.invocation.callId),
          everyElement('local-read-call'),
        );
      },
    );

    test(
      'manifest read risk preserves exact off and shadow behavior',
      () async {
        for (final mode in <FeatureRolloutMode>[
          FeatureRolloutMode.off,
          FeatureRolloutMode.shadow,
        ]) {
          final harness = await _ContractHarness.create(
            mode: mode,
            declareReadOnly: false,
          );
          final skill = _ProbeSkill(
            name: 'LocalLegacy${mode.name}',
            methodNames: const <String>['lookup'],
            result: ' local legacy bytes stay exact \n',
          );
          harness.manager.registerSkill(skill);

          final result = await LocalSkillInvoker(skillManager: harness.manager)
              .invoke(
                _localManifest(
                  id: 'local/${mode.name}/read',
                  skillName: skill.skillName,
                  method: 'lookup',
                  risk: LocalSkillRisk.read,
                ),
                const <String, dynamic>{},
                contractCallId: 'local-${mode.name}-identity',
              );

          expect(result.status, LocalSkillResultStatus.ok, reason: mode.name);
          expect(
            result.output,
            ' local legacy bytes stay exact \n',
            reason: mode.name,
          );
          expect(skill.handlerCalls, 1, reason: mode.name);
        }
      },
    );

    test('manifest local mutation remains ineligible by default', () async {
      final harness = await _ContractHarness.create(
        mode: FeatureRolloutMode.enforce,
        declareReadOnly: false,
      );
      final skill = _ProbeSkill(
        name: 'LocalWrite',
        methodNames: const <String>['save'],
        result: '{"saved":true}',
      );
      harness.manager.registerSkill(skill);

      final result = await LocalSkillInvoker(skillManager: harness.manager)
          .invoke(
            _localManifest(
              id: 'local/write',
              skillName: skill.skillName,
              method: 'save',
              risk: LocalSkillRisk.writeLocal,
            ),
            const <String, dynamic>{},
            contractCallId: 'local-write-call',
          );

      expect(result.status, LocalSkillResultStatus.unavailable);
      expect(
        jsonDecode(result.output),
        containsPair('code', 'contract_rejected'),
      );
      expect(skill.handlerCalls, 0);
    });
  });

  group('delayed-tool Action Contract V2', () {
    test(
      'concurrent commit claims before await and executes exactly once',
      () async {
        final harness = await _ContractHarness.create(
          mode: FeatureRolloutMode.shadow,
        );
        final started = Completer<void>();
        final release = Completer<void>();
        final skill = _ProbeSkill(
          name: 'DelayedUpdate',
          methodNames: const <String>['update'],
          nativeMethods: const <String>['update'],
          onInvoke: () async {
            if (!started.isCompleted) started.complete();
            await release.future;
            return '{"updated":true}';
          },
        );
        harness.manager.registerSkill(skill);
        final tool = SkillManager.nativeToolName(skill, 'update');
        final executor = DelayedChoiceExecutor();
        final client = _SingleToolClient(
          ToolCall(id: 'provider-update', name: tool, argumentsJson: '{}'),
        );
        await executor.run(
          client: client,
          skillManager: harness.manager,
          messages: <Message>[Message.user('update')],
          maxRounds: 2,
        );
        final branchId = executor.pending.single.id;

        final first = executor.commit(branchId, harness.manager);
        await started.future;
        final second = await executor.commit(branchId, harness.manager);
        release.complete();
        final firstResult = await first;

        expect(jsonDecode(second), containsPair('status', 'missing'));
        expect(jsonDecode(firstResult), containsPair('status', 'committed'));
        expect(skill.handlerCalls, 1);
        expect(executor.pending, isEmpty);
      },
    );

    test(
      'discard during a claimed failure does not resurrect branch',
      () async {
        final harness = await _ContractHarness.create(
          mode: FeatureRolloutMode.enforce,
        );
        final started = Completer<void>();
        final release = Completer<void>();
        final skill = _ProbeSkill(
          name: 'DiscardClaimed',
          methodNames: const <String>['update'],
          nativeMethods: const <String>['update'],
          onInvoke: () async {
            started.complete();
            await release.future;
            throw StateError('claimed attempt failed');
          },
        );
        harness.manager.registerSkill(skill);
        final tool = SkillManager.nativeToolName(skill, 'update');
        final executor = DelayedChoiceExecutor();
        await executor.run(
          client: _SingleToolClient(
            ToolCall(id: 'discard-claimed', name: tool, argumentsJson: '{}'),
          ),
          skillManager: harness.manager,
          messages: <Message>[Message.user('update')],
          maxRounds: 2,
        );
        final branchId = executor.pending.single.id;

        final committing = executor.commit(branchId, harness.manager);
        await started.future;
        expect(executor.pending, isEmpty);
        expect(executor.discardAll(), 0);
        release.complete();
        final failed = await committing;

        expect(jsonDecode(failed), containsPair('status', 'error'));
        expect(skill.handlerCalls, 1);
        expect(executor.pending, isEmpty);
      },
    );

    test('enforced failed claim is consumed and cannot run twice', () async {
      final harness = await _ContractHarness.create(
        mode: FeatureRolloutMode.enforce,
      );
      var attempts = 0;
      final skill = _ProbeSkill(
        name: 'RetryUpdate',
        methodNames: const <String>['update'],
        nativeMethods: const <String>['update'],
        onInvoke: () {
          attempts += 1;
          if (attempts == 1) throw StateError('first attempt fails');
          return '{"updated":true}';
        },
      );
      harness.manager.registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'update');
      final executor = DelayedChoiceExecutor();
      await executor.run(
        client: _SingleToolClient(
          ToolCall(id: 'retry-update', name: tool, argumentsJson: '{}'),
        ),
        skillManager: harness.manager,
        messages: <Message>[Message.user('update')],
        maxRounds: 2,
      );
      final branchId = executor.pending.single.id;

      final failed = await executor.commit(branchId, harness.manager);
      expect(jsonDecode(failed), containsPair('status', 'error'));
      expect(executor.pending, isEmpty);

      final retried = await executor.commit(branchId, harness.manager);
      expect(jsonDecode(retried), containsPair('status', 'missing'));
      expect(skill.handlerCalls, 1);
      expect(executor.pending, isEmpty);
    });

    test(
      'off and shadow preserve legacy failed-claim retry behavior',
      () async {
        for (final mode in <FeatureRolloutMode>[
          FeatureRolloutMode.off,
          FeatureRolloutMode.shadow,
        ]) {
          final harness = await _ContractHarness.create(mode: mode);
          var attempts = 0;
          final skill = _ProbeSkill(
            name: 'LegacyRetry${mode.name}',
            methodNames: const <String>['update'],
            nativeMethods: const <String>['update'],
            onInvoke: () {
              attempts += 1;
              if (attempts == 1) throw StateError('legacy attempt fails');
              return '{"updated":true}';
            },
          );
          harness.manager.registerSkill(skill);
          final tool = SkillManager.nativeToolName(skill, 'update');
          final executor = DelayedChoiceExecutor();
          await executor.run(
            client: _SingleToolClient(
              ToolCall(
                id: 'legacy-retry-${mode.name}',
                name: tool,
                argumentsJson: '{}',
              ),
            ),
            skillManager: harness.manager,
            messages: <Message>[Message.user('update')],
            maxRounds: 2,
          );
          final branchId = executor.pending.single.id;

          final failed = await executor.commit(branchId, harness.manager);
          expect(
            jsonDecode(failed),
            containsPair('status', 'error'),
            reason: mode.name,
          );
          expect(executor.pending.single.id, branchId, reason: mode.name);

          final retried = await executor.commit(branchId, harness.manager);
          expect(
            jsonDecode(retried),
            containsPair('status', 'committed'),
            reason: mode.name,
          );
          expect(skill.handlerCalls, 2, reason: mode.name);
          expect(executor.pending, isEmpty, reason: mode.name);
        }
      },
    );
  });
}

String _openAiToolName(Map<String, dynamic> tool) =>
    (tool['function'] as Map<String, dynamic>)['name']! as String;

LocalSkillManifest _localManifest({
  required String id,
  required String skillName,
  required String method,
  required LocalSkillRisk risk,
}) => LocalSkillManifest(
  id: id,
  skillName: skillName,
  method: method,
  summary: 'contract probe',
  tags: const <String>['contract'],
  argsSchema: const <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{},
    'additionalProperties': false,
  },
  risk: risk,
);

final class _ProbeSkill extends AgentSkill {
  _ProbeSkill({
    required this.name,
    required this.methodNames,
    this.nativeMethods = const <String>[],
    this.result = '{}',
    this.onInvoke,
    Map<String, dynamic>? schema,
  }) : schema =
           schema ??
           <String, dynamic>{
             'type': 'object',
             'properties': <String, dynamic>{},
             'additionalProperties': false,
           };

  final String name;
  final List<String> methodNames;
  final List<String> nativeMethods;
  final String result;
  final FutureOr<Object?> Function()? onInvoke;
  final Map<String, dynamic> schema;
  int handlerCalls = 0;

  @override
  String get skillName => name;

  @override
  String get description => 'Action Contract probe.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        for (final method in methodNames) method: (_) => _invoke(),
      };

  Object? _invoke() {
    handlerCalls += 1;
    return onInvoke?.call() ?? result;
  }

  @override
  Map<String, Map<String, dynamic>>? get nativeToolSchemas =>
      nativeMethods.isEmpty
      ? null
      : <String, Map<String, dynamic>>{
          for (final method in nativeMethods) method: schema,
        };
}

final class _ContractHarness {
  const _ContractHarness({
    required this.catalog,
    required this.audit,
    required this.service,
    required this.manager,
  });

  static Future<_ContractHarness> create({
    required FeatureRolloutMode mode,
    bool declareReadOnly = true,
    SkillActionContractMetadataResolver? metadataResolver,
  }) async {
    final now = DateTime.utc(2026, 8, 30, 12);
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
    final catalog = ProductionActionDefinitionCatalog();
    final audit = _AuditSink();
    final service = ActionContractV2Service(
      featureFlags: flags,
      catalog: catalog,
      audit: audit,
      accountScope: 'account-a',
      accountGeneration: 9,
      mountIsCurrent: () => true,
    );
    final manager = SkillManager(
      actionContract: service,
      productionCatalog: catalog,
      actionContractAgentId: 'agent-a',
      contractMetadataResolver:
          metadataResolver ??
          (declareReadOnly
              ? (_, _, _) => const SkillActionContractMetadata.readOnly()
              : null),
    );
    return _ContractHarness(
      catalog: catalog,
      audit: audit,
      service: service,
      manager: manager,
    );
  }

  final ProductionActionDefinitionCatalog catalog;
  final _AuditSink audit;
  final ActionContractV2Service service;
  final SkillManager manager;
}

final class _AuditSink implements ActionContractV2AuditSink {
  final List<ActionContractAuditRecord> records = <ActionContractAuditRecord>[];

  @override
  String record(ActionContractAuditRecord record) {
    records.add(record);
    return 'audit-${record.invocation.callId}-${record.definition.id}';
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

final class _SingleToolClient extends LLMClient {
  _SingleToolClient(this.call);

  final ToolCall call;
  int _round = 0;
  List<String> toolResults = const <String>[];

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    if (_round++ == 0) {
      return ChatTurnResult(content: '', toolCalls: <ToolCall>[call]);
    }
    toolResults = messages
        .where((message) => message.role == 'tool')
        .map((message) => message.content)
        .toList(growable: false);
    return ChatTurnResult(content: 'done', toolCalls: const <ToolCall>[]);
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnsupportedError('not used');
}
