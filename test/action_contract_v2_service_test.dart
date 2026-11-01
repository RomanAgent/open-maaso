import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_legacy_adapter.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/tool_outcome.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 8, 30, 8);

  test('off preserves exact caller output and executes legacy once', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.off,
      now: now,
    );
    final request = harness.request();
    final admission = await harness.service.prepare(request);
    final original = <String, Object?>{'legacy': Object()};
    var calls = 0;

    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult(
          callerOutput: original,
          actionOutputs: const <Object?>['ok'],
        );
      },
    );

    expect(result.status, ActionContractExecutionStatus.legacy);
    expect(result.outputForCaller, same(original));
    expect(calls, 1);
    expect(harness.audit.records, isEmpty);
    final replay = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult.single('again');
      },
    );
    expect(replay.outcome?.code, 'ticket_invalid');
    expect(calls, 1);
  });

  test(
    'shadow diagnoses but preserves legacy and never runs metadata handler',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.shadow,
        now: now,
      );
      final request = harness.request(arguments: const <String, Object?>{});
      final admission = await harness.service.prepare(request);
      final original = Object();
      var calls = 0;

      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult(
            callerOutput: original,
            actionOutputs: const <Object?>[
              <String, Object?>{'unexpected': true},
            ],
          );
        },
      );

      expect(admission.admitted, isTrue);
      expect(
        admission.diagnostics.map((entry) => entry.code),
        contains('invalid_arguments'),
      );
      expect(result.outputForCaller, same(original));
      expect(calls, 1);
      expect(harness.definitionHandlerCalls, 0);
      expect(
        harness.service.recentDiagnostics.map((entry) => entry.code),
        contains('invalid_tool_outcome'),
      );
    },
  );

  test('off and shadow rethrow the exact legacy exception', () async {
    for (final mode in <FeatureRolloutMode>[
      FeatureRolloutMode.off,
      FeatureRolloutMode.shadow,
    ]) {
      final harness = await _Harness.create(mode: mode, now: now);
      final request = harness.request();
      final admission = await harness.service.prepare(request);
      final legacyError = StateError('legacy-private-detail');
      Object? caught;
      try {
        await harness.service.execute(
          admission: admission,
          currentRequest: request,
          legacyCallback: () => throw legacyError,
        );
      } catch (error) {
        caught = error;
      }
      expect(caught, same(legacyError), reason: mode.name);
      await harness.service.sealAndDrain();
      expect(
        harness.audit.records.map((record) => record.stage),
        mode == FeatureRolloutMode.off
            ? isEmpty
            : <ActionAuditStage>[
                ActionAuditStage.decided,
                ActionAuditStage.result,
              ],
        reason: mode.name,
      );
      expect(
        harness.audit.records.map((record) => record.code),
        mode == FeatureRolloutMode.off
            ? isEmpty
            : <String>['v2.shadow_observed', 'v2.shadow_failed'],
        reason: mode.name,
      );
    }
  });

  test('enforce rejects the whole envelope before any effect', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final request = harness.request(
      actions: <ActionContractCall>[
        harness.call(),
        const ActionContractCall(
          actionId: 'missing.action',
          arguments: <String, Object?>{},
        ),
      ],
    );
    final admission = await harness.service.prepare(request);
    var calls = 0;

    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult.single('ok');
      },
    );

    expect(admission.admitted, isFalse);
    expect(
      admission.diagnostics.map((entry) => entry.code),
      contains('definition_missing'),
    );
    expect(result.outcome?.code, 'contract_rejected');
    expect(calls, 0);
    expect(harness.definitionHandlerCalls, 0);
  });

  test(
    'enforce ticket is opaque one-shot and returns a typed outcome',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final request = harness.request();
      final admission = await harness.service.prepare(request);
      var calls = 0;

      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult(
            callerOutput: 'legacy-wire',
            actionOutputs: const <Object?>['ok'],
          );
        },
      );
      final replay = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult.single('ok');
        },
      );

      expect(result.status, ActionContractExecutionStatus.enforced);
      expect(result.outcome?.isOk, isTrue);
      expect(replay.outcome?.code, 'ticket_invalid');
      expect(calls, 1);
      expect(harness.definitionHandlerCalls, 0);
    },
  );

  test(
    'semantic invocation is reserved before audit and replay stays fenced',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final decisionGate = Completer<void>();
      harness.audit.gates[ActionAuditStage.decided] = decisionGate;
      final request = harness.request();

      final firstPreparation = harness.service.prepare(request);
      final concurrentReplay = await harness.service.prepare(request);
      final concurrentConflict = await harness.service.prepare(
        harness.request(arguments: const <String, Object?>{'value': 'other'}),
      );

      expect(
        concurrentReplay.diagnostics.map((entry) => entry.code),
        contains('invocation_replayed'),
      );
      expect(
        concurrentConflict.diagnostics.map((entry) => entry.code),
        contains('invocation_conflict'),
      );
      expect(harness.service.semanticInvocationCount, 1);
      var rejectedCalls = 0;
      for (final rejected in <ActionContractAdmission>[
        concurrentReplay,
        concurrentConflict,
      ]) {
        final rejectedExecution = await harness.service.execute(
          admission: rejected,
          currentRequest: request,
          legacyCallback: () {
            rejectedCalls += 1;
            return ActionContractLegacyResult.single('must-not-run');
          },
        );
        expect(rejectedExecution.outcome?.code, 'contract_rejected');
      }
      expect(rejectedCalls, 0);

      decisionGate.complete();
      final admission = await firstPreparation;
      var calls = 0;
      final execution = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult.single('ok');
        },
      );
      final completedReplay = await harness.service.prepare(request);

      expect(admission.admitted, isTrue);
      expect(execution.outcome?.isOk, isTrue);
      expect(calls, 1);
      expect(
        completedReplay.diagnostics.map((entry) => entry.code),
        contains('invocation_replayed'),
      );
      final completedReplayExecution = await harness.service.execute(
        admission: completedReplay,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult.single('must-not-run');
        },
      );
      expect(completedReplayExecution.outcome?.code, 'contract_rejected');
      expect(calls, 1);
    },
  );

  test('semantic invocation tombstones are bounded and retained', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
      maximumPendingTickets: 2,
      maximumInvocationRecords: 2,
      ticketTtl: const Duration(minutes: 1),
      invocationRetention: const Duration(minutes: 1),
    );

    for (final callId in <String>['call-1', 'call-2']) {
      final request = harness.request(callId: callId);
      final admission = await harness.service.prepare(request);
      expect(
        (await harness.service.execute(
          admission: admission,
          currentRequest: request,
          legacyCallback: () => ActionContractLegacyResult.single('ok'),
        )).outcome?.isOk,
        isTrue,
      );
    }
    final atCapacity = await harness.service.prepare(
      harness.request(callId: 'call-3'),
    );
    expect(
      atCapacity.diagnostics.map((entry) => entry.code),
      contains('invocation_capacity_exhausted'),
    );

    harness.monotonic.value = const Duration(minutes: 2);
    final afterRetention = await harness.service.prepare(
      harness.request(callId: 'call-3'),
    );
    expect(afterRetention.admitted, isTrue);
    expect(harness.service.semanticInvocationCount, 1);
  });

  test('mode round-trip permanently stales an old ticket', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final request = harness.request();
    final admission = await harness.service.prepare(request);
    await harness.setMode(FeatureRolloutMode.off);
    await harness.setMode(FeatureRolloutMode.enforce);
    var calls = 0;

    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult.single('ok');
      },
    );

    expect(result.outcome?.code, 'ticket_stale');
    expect(calls, 0);
  });

  test(
    'account generation, args, and target mutations stale tickets',
    () async {
      Future<void> expectStale(
        _Harness harness,
        ActionContractEnvelopeRequest Function(_Harness) mutate,
      ) async {
        final original = harness.request();
        final admission = await harness.service.prepare(original);
        var calls = 0;
        final result = await harness.service.execute(
          admission: admission,
          currentRequest: mutate(harness),
          legacyCallback: () {
            calls += 1;
            return ActionContractLegacyResult.single('ok');
          },
        );
        expect(result.outcome?.code, 'ticket_stale');
        expect(calls, 0);
      }

      await expectStale(
        await _Harness.create(mode: FeatureRolloutMode.enforce, now: now),
        (harness) => harness.request(accountGeneration: 8),
      );
      await expectStale(
        await _Harness.create(mode: FeatureRolloutMode.enforce, now: now),
        (harness) => harness.request(accountScope: 'account-b'),
      );
      await expectStale(
        await _Harness.create(mode: FeatureRolloutMode.enforce, now: now),
        (harness) => harness.request(arguments: const {'value': 'changed'}),
      );
      await expectStale(
        await _Harness.create(mode: FeatureRolloutMode.enforce, now: now),
        (harness) => harness.request(target: 'resource:other'),
      );
    },
  );

  test('unrelated catalog registration does not stale admission', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final request = harness.request();
    final admission = await harness.service.prepare(request);
    harness.registerExtra();
    var calls = 0;

    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult.single('ok');
      },
    );

    expect(result.status, ActionContractExecutionStatus.enforced);
    expect(result.outcome?.isOk, isTrue);
    expect(calls, 1);
    expect(harness.definitionHandlerCalls, 0);
  });

  test('relevant definition fingerprint mutation stales admission', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final mutableValueSchema = <String, Object?>{'type': 'string'};
    final production = ProductionActionDefinition(
      definition: ActionDefinition(
        id: 'test.mutable',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, Object?>{'value': mutableValueSchema},
          'required': <String>['value'],
          'additionalProperties': false,
        },
        outputSchema: _outputSchema,
        scopes: const <AgentActionScope>{AgentActionScope.chat},
        risk: ActionRisk.readOnly,
        consequencePolicy: ActionConsequencePolicy.reversible,
        targetResolver: (_) => 'resource:mutable',
        handler: (_) => throw StateError('metadata_handler_ran'),
      ),
      channels: const <ActionContractChannel>{ActionContractChannel.structured},
      enforcementEligibility: ActionEnforcementEligibility.readOnly,
    );
    harness.catalog.register(production);
    final request = harness.request(
      actions: <ActionContractCall>[
        ActionContractCall(
          actionId: 'test.mutable',
          arguments: const <String, Object?>{'value': 'ok'},
          expectedDefinition: production,
        ),
      ],
    );
    final admission = await harness.service.prepare(request);
    mutableValueSchema['maxLength'] = 3;
    var calls = 0;

    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult.single('ok');
      },
    );

    expect(result.outcome?.code, 'ticket_stale');
    expect(calls, 0);
  });

  test('invalid enforce output fails once without retry', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final request = harness.request();
    final admission = await harness.service.prepare(request);
    var calls = 0;

    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult(
          callerOutput: 'ignored',
          actionOutputs: const <Object?>[
            <String, Object?>{'unexpected': true},
          ],
        );
      },
    );

    expect(result.outcome?.code, 'invalid_tool_outcome');
    expect(result.outcome?.retryable, isFalse);
    expect(result.outputForCaller.toString(), isNot(contains('unexpected')));
    expect(calls, 1);
    expect(harness.audit.records.last.stage, ActionAuditStage.result);
  });

  test('wrong enforce output count is a fixed non-retryable failure', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final request = harness.request();
    final admission = await harness.service.prepare(request);
    var calls = 0;
    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return const ActionContractLegacyResult(
          callerOutput: 'private-legacy-output',
          actionOutputs: <Object?>[],
        );
      },
    );

    expect(result.outcome?.code, 'invalid_tool_outcome');
    expect(result.outcome?.retryable, isFalse);
    expect(result.outputForCaller.toString(), isNot(contains('private')));
    expect(calls, 1);
  });

  test('off and shadow preserve unknown-definition legacy behavior', () async {
    for (final mode in <FeatureRolloutMode>[
      FeatureRolloutMode.off,
      FeatureRolloutMode.shadow,
    ]) {
      final harness = await _Harness.create(mode: mode, now: now);
      final request = harness.request(
        actions: const <ActionContractCall>[
          ActionContractCall(
            actionId: 'unknown.action',
            arguments: <String, Object?>{'hostile': true},
          ),
        ],
      );
      final admission = await harness.service.prepare(request);
      final original = Object();
      var calls = 0;
      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult(
            callerOutput: original,
            actionOutputs: const <Object?>['legacy'],
          );
        },
      );
      expect(admission.admitted, isTrue, reason: mode.name);
      expect(result.outputForCaller, same(original), reason: mode.name);
      expect(calls, 1, reason: mode.name);
    }
  });

  test(
    'empty envelope is legacy-compatible off and an enforced no-op',
    () async {
      final off = await _Harness.create(mode: FeatureRolloutMode.off, now: now);
      final offRequest = off.request(actions: const <ActionContractCall>[]);
      final offAdmission = await off.service.prepare(offRequest);
      var offCalls = 0;
      final offResult = await off.service.execute(
        admission: offAdmission,
        currentRequest: offRequest,
        legacyCallback: () {
          offCalls += 1;
          return const ActionContractLegacyResult(
            callerOutput: 'reply-only',
            actionOutputs: <Object?>[],
          );
        },
      );
      expect(offResult.outputForCaller, 'reply-only');
      expect(offCalls, 1);

      final enforce = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final request = enforce.request(actions: const <ActionContractCall>[]);
      final admission = await enforce.service.prepare(request);
      var enforceCalls = 0;
      final result = await enforce.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          enforceCalls += 1;
          return const ActionContractLegacyResult(
            callerOutput: 'must-not-run',
            actionOutputs: <Object?>[],
          );
        },
      );
      expect(admission.admitted, isTrue);
      expect(admission.diagnostics, isEmpty);
      expect(result.status, ActionContractExecutionStatus.enforced);
      expect(result.outcome?.isOk, isTrue);
      expect(result.outcome?.data, const <Object?>[]);
      expect(enforceCalls, 0);
      expect(enforce.audit.records, isEmpty);
      expect(enforce.definitionHandlerCalls, 0);
    },
  );

  test('enforce audit failure produces zero execution', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    harness.audit.fail = true;
    final request = harness.request();
    final admission = await harness.service.prepare(request);
    var calls = 0;

    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult.single('ok');
      },
    );

    expect(admission.admitted, isFalse);
    expect(result.outcome?.code, 'contract_rejected');
    expect(calls, 0);
  });

  test('null enforce audit receipt produces zero execution', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    harness.audit.returnNull = true;
    final request = harness.request();
    final admission = await harness.service.prepare(request);
    var calls = 0;
    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return ActionContractLegacyResult.single('ok');
      },
    );

    expect(admission.admitted, isFalse);
    expect(result.outcome?.code, 'contract_rejected');
    expect(calls, 0);
  });

  test('executed audit must preserve exact receipt before callback', () async {
    for (final breakContinuity in <bool>[false, true]) {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      if (breakContinuity) {
        harness.audit.breakContinuityAtStage = ActionAuditStage.executed;
      } else {
        harness.audit.failAtStage = ActionAuditStage.executed;
      }
      final request = harness.request();
      final admission = await harness.service.prepare(request);
      var calls = 0;

      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult.single('ok');
        },
      );

      expect(result.outcome?.code, 'audit_unavailable');
      expect(calls, 0);
      expect(
        (await harness.service.prepare(
          request,
        )).diagnostics.map((entry) => entry.code),
        contains('invocation_replayed'),
      );
    }
  });

  test('duplicate actions have distinct continuous audit receipts', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final request = harness.request(
      actions: <ActionContractCall>[harness.call(), harness.call()],
    );
    final admission = await harness.service.prepare(request);
    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () => const ActionContractLegacyResult(
        callerOutput: 'legacy',
        actionOutputs: <Object?>['ok', 'ok'],
      ),
    );

    expect(result.outcome?.isOk, isTrue);
    expect(
      harness.audit.records.map((record) => record.stage),
      <ActionAuditStage>[
        ActionAuditStage.decided,
        ActionAuditStage.decided,
        ActionAuditStage.executed,
        ActionAuditStage.executed,
        ActionAuditStage.result,
        ActionAuditStage.result,
      ],
    );
    expect(harness.audit.records.map((record) => record.actionIndex), <int>[
      0,
      1,
      0,
      1,
      0,
      1,
    ]);
    expect(harness.audit.receiptIds[0], harness.audit.receiptIds[2]);
    expect(harness.audit.receiptIds[0], harness.audit.receiptIds[4]);
    expect(harness.audit.receiptIds[1], harness.audit.receiptIds[3]);
    expect(harness.audit.receiptIds[1], harness.audit.receiptIds[5]);
    expect(harness.audit.receiptIds[0], isNot(harness.audit.receiptIds[1]));
  });

  test('ActionAuditLog sink digests action index and channel identity', () {
    final harnessDefinition = _testProduction();
    final sink = ActionAuditLogContractV2Sink(ActionAuditLog());
    ActionContractAuditRecord record({
      required int actionIndex,
      required ActionAuditStage stage,
      ActionContractChannel channel = ActionContractChannel.structured,
    }) => ActionContractAuditRecord(
      stage: stage,
      invocation: const ActionContractInvocationScope(
        accountScope: 'account-a',
        accountGeneration: 7,
        agentId: 'agent-a',
        callId: 'call-a',
      ),
      actionIndex: actionIndex,
      channel: channel,
      definition: harnessDefinition.definition,
      arguments: const <String, Object?>{'value': 'same'},
      target: 'resource:test',
      outcome: ActionAuditOutcome.allowed,
      code: 'v2.test',
      occurredAt: now,
    );

    final first = sink.record(
      record(actionIndex: 0, stage: ActionAuditStage.decided),
    );
    final sameLifecycle = sink.record(
      record(actionIndex: 0, stage: ActionAuditStage.executed),
    );
    final duplicate = sink.record(
      record(actionIndex: 1, stage: ActionAuditStage.decided),
    );
    final otherChannel = sink.record(
      record(
        actionIndex: 0,
        stage: ActionAuditStage.decided,
        channel: ActionContractChannel.nativeTool,
      ),
    );

    expect(sameLifecycle, first);
    expect(duplicate, isNot(first));
    expect(otherChannel, isNot(first));
  });

  test('callback error and timeout both emit terminal result audit', () async {
    final throwing = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final throwingRequest = throwing.request();
    final throwingAdmission = await throwing.service.prepare(throwingRequest);
    final thrown = await throwing.service.execute(
      admission: throwingAdmission,
      currentRequest: throwingRequest,
      legacyCallback: () => throw StateError('private-callback-error'),
    );
    expect(thrown.outcome?.code, 'execution_failed');
    expect(thrown.outputForCaller.toString(), isNot(contains('private')));
    expect(throwing.audit.records.last.stage, ActionAuditStage.result);
    expect(throwing.audit.records.last.code, 'execution_failed');

    final timedOut = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
      readOnlyCallbackDeadline: const Duration(milliseconds: 10),
    );
    final timedOutRequest = timedOut.request();
    final timedOutAdmission = await timedOut.service.prepare(timedOutRequest);
    final callbackGate = Completer<ActionContractLegacyResult>();
    final timeoutResult = await timedOut.service.execute(
      admission: timedOutAdmission,
      currentRequest: timedOutRequest,
      legacyCallback: () => callbackGate.future,
    );
    expect(timeoutResult.outcome?.code, 'execution_timeout');
    expect(timedOut.audit.records.last.stage, ActionAuditStage.result);
    expect(timedOut.audit.records.last.code, 'execution_timeout');
    await timedOut.service.sealAndDrain().timeout(
      const Duration(milliseconds: 100),
    );
    expect(timedOut.service.activeOperationCount, 0);
  });

  test(
    'hung terminal audit is deadline-bounded and does not block drain',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
        auditDeadline: const Duration(milliseconds: 10),
      );
      final request = harness.request();
      final admission = await harness.service.prepare(request);
      harness.audit.gates[ActionAuditStage.result] = Completer<void>();

      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () => ActionContractLegacyResult.single('ok'),
      );

      expect(result.outcome?.code, 'audit_unavailable');
      await harness.service.sealAndDrain().timeout(
        const Duration(milliseconds: 100),
      );
      expect(harness.service.activeOperationCount, 0);
    },
  );

  test(
    'synchronous seal fences new work and drain awaits active callback',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final request = harness.request();
      final admission = await harness.service.prepare(request);
      final callbackGate = Completer<ActionContractLegacyResult>();
      var callbackStarted = false;
      final execution = harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          callbackStarted = true;
          return callbackGate.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(callbackStarted, isTrue);

      var drained = false;
      final drain = harness.service.sealAndDrain().then((_) => drained = true);
      final sameDrain = harness.service.sealAndDrain();
      expect(identical(harness.service.sealAndDrain(), sameDrain), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(harness.service.isSealed, isTrue);
      expect(drained, isFalse);
      final rejected = await harness.service.prepare(request);
      expect(rejected.admitted, isFalse);

      callbackGate.complete(ActionContractLegacyResult.single('ok'));
      expect((await execution).outcome?.code, 'stale_after_execution');
      await drain;
      expect(drained, isTrue);
      expect(harness.service.activeOperationCount, 0);
    },
  );

  test('ticket and diagnostic state stay bounded', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
      maximumPendingTickets: 2,
      maximumDiagnostics: 3,
    );
    expect((await harness.service.prepare(harness.request())).admitted, isTrue);
    expect(
      (await harness.service.prepare(
        harness.request(callId: 'call-2'),
      )).admitted,
      isTrue,
    );
    final capacity = await harness.service.prepare(
      harness.request(callId: 'call-3'),
    );
    expect(capacity.admitted, isFalse);
    for (var index = 0; index < 6; index += 1) {
      await harness.service.prepare(
        harness.request(
          callId: 'invalid-$index',
          arguments: const <String, Object?>{},
        ),
      );
    }
    expect(harness.service.pendingTicketCount, 2);
    expect(harness.service.recentDiagnostics, hasLength(3));
  });

  test('legacy adapter recognizes every wire status without failure data', () {
    final adapter = ActionContractLegacyAdapter();
    const expected = <String, ToolOutcomeStatus>{
      'ok': ToolOutcomeStatus.ok,
      'invalid_arguments': ToolOutcomeStatus.invalidArguments,
      'confirmation_required': ToolOutcomeStatus.confirmationRequired,
      'commit_required': ToolOutcomeStatus.confirmationRequired,
      'denied': ToolOutcomeStatus.denied,
      'unavailable': ToolOutcomeStatus.unavailable,
      'cancelled': ToolOutcomeStatus.cancelled,
      'failed': ToolOutcomeStatus.failed,
    };

    for (final entry in expected.entries) {
      final outcome = adapter.adaptOutput(<String, Object?>{
        'status': entry.key,
        'code': '${entry.key}_code',
        'data': const <String, Object?>{'secret': 'must-not-leak'},
        'display': 'must-not-leak',
        'retryable': true,
        'auditId': 'must-not-leak',
      });
      expect(outcome.status, entry.value, reason: entry.key);
      if (outcome.isOk) {
        expect(outcome.data, const <String, Object?>{
          'secret': 'must-not-leak',
        });
      } else {
        expect(outcome.data, isNull, reason: entry.key);
        expect(outcome.display, isNull, reason: entry.key);
        expect(outcome.auditId, isNull, reason: entry.key);
        expect(outcome.retryable, isTrue, reason: entry.key);
      }
    }

    final typed = adapter.adaptOutput(
      ToolOutcome.failure(
        status: ToolOutcomeStatus.denied,
        code: 'permission_denied',
        data: const <String, Object?>{'secret': 'typed-secret'},
        display: 'typed-secret',
        retryable: true,
        auditId: 'private-audit-id',
      ),
    );
    expect(typed.status, ToolOutcomeStatus.denied);
    expect(typed.code, 'permission_denied');
    expect(typed.retryable, isTrue);
    expect(typed.data, isNull);
    expect(typed.display, isNull);
    expect(typed.auditId, isNull);
  });

  test(
    'legacy adapter bounds hostile output and never calls value toString',
    () {
      final adapter = ActionContractLegacyAdapter();
      final oversized = adapter.adaptOutput('x' * 65537);
      final hostileStatus = adapter.adaptOutput(<String, Object?>{
        'status': _ThrowingToString(),
      });
      final oversizedMap = adapter.adaptOutput(<String, Object?>{
        for (var index = 0; index < 4097; index += 1) 'key-$index': index,
      });

      for (final outcome in <ToolOutcome>[
        oversized,
        hostileStatus,
        oversizedMap,
      ]) {
        expect(outcome.status, ToolOutcomeStatus.failed);
        expect(outcome.code, 'invalid_tool_outcome');
        expect(outcome.data, isNull);
      }
    },
  );

  test(
    'enforce preserves typed failure status but never raw failure data',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final request = harness.request();
      final admission = await harness.service.prepare(request);
      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () => ActionContractLegacyResult.single(
          ToolOutcome.failure(
            status: ToolOutcomeStatus.denied,
            code: 'permission_denied',
            data: const <String, Object?>{'secret': 'private-value'},
            display: 'private-value',
            retryable: true,
            auditId: 'private-audit-id',
          ),
        ),
      );

      expect(result.outcome?.status, ToolOutcomeStatus.denied);
      expect(result.outcome?.code, 'permission_denied');
      expect(result.outcome?.retryable, isTrue);
      expect(
        result.outputForCaller.toString(),
        isNot(contains('private-value')),
      );
      expect(
        result.outputForCaller.toString(),
        isNot(contains('private-audit-id')),
      );
    },
  );

  test(
    'abandon consumes ticket, audits cancellation, and keeps tombstone',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final request = harness.request();
      final admission = await harness.service.prepare(request);

      final abandoned = await harness.service.abandon(
        admission: admission,
        currentRequest: request,
      );
      var calls = 0;
      final replayExecution = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult.single('ok');
        },
      );
      final replayPreparation = await harness.service.prepare(request);

      expect(abandoned.outcome?.status, ToolOutcomeStatus.cancelled);
      expect(abandoned.outcome?.code, 'caller_cancelled');
      expect(replayExecution.outcome?.code, 'ticket_invalid');
      expect(calls, 0);
      expect(
        replayPreparation.diagnostics.map((entry) => entry.code),
        contains('invocation_replayed'),
      );
      expect(
        harness.audit.records.map((record) => record.stage),
        <ActionAuditStage>[ActionAuditStage.decided, ActionAuditStage.result],
      );
      expect(harness.audit.records.last.outcome, ActionAuditOutcome.cancelled);
      expect(harness.audit.receiptIds.first, harness.audit.receiptIds.last);
    },
  );

  test(
    'abandon marks a changed current request stale while consuming it',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final request = harness.request();
      final admission = await harness.service.prepare(request);

      final result = await harness.service.abandon(
        admission: admission,
        currentRequest: harness.request(
          arguments: const <String, Object?>{'value': 'changed'},
        ),
        code: 'caller_cancelled',
      );

      expect(result.outcome?.status, ToolOutcomeStatus.cancelled);
      expect(result.outcome?.code, 'abandon_stale');
      expect(harness.audit.records.last.code, 'abandon_stale');
      expect(
        (await harness.service.prepare(
          request,
        )).diagnostics.map((entry) => entry.code),
        contains('invocation_replayed'),
      );
    },
  );

  test(
    'issueInvocation returns only current account-owned identities',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );

      final invocation = harness.service.issueInvocation(
        agentId: ' agent-b ',
        callId: ' call-b ',
      );
      expect(invocation?.accountScope, 'account-a');
      expect(invocation?.accountGeneration, 7);
      expect(invocation?.agentId, 'agent-b');
      expect(invocation?.callId, 'call-b');
      expect(
        harness.service.issueInvocation(agentId: '', callId: 'call-c'),
        isNull,
      );

      harness.service.seal();
      expect(
        harness.service.issueInvocation(agentId: 'agent-c', callId: 'call-c'),
        isNull,
      );
    },
  );

  test(
    'invocation identity normalization is stable across audit stages',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final request = harness.request(
        accountScope: ' account-a ',
        agentId: ' agent-a ',
        callId: ' call-spaced ',
      );
      final admission = await harness.service.prepare(request);
      var calls = 0;

      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult.single('ok');
        },
      );

      expect(admission.admitted, isTrue);
      expect(result.outcome?.isOk, isTrue);
      expect(calls, 1);
      expect(harness.audit.receiptIds.toSet(), hasLength(1));
    },
  );

  test(
    'enforced active operation capacity rejects excess preparation',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
        maximumActiveEnforcedOperations: 1,
      );
      final decisionGate = Completer<void>();
      harness.audit.gates[ActionAuditStage.decided] = decisionGate;
      final firstPreparation = harness.service.prepare(
        harness.request(callId: 'call-first'),
      );

      final excess = await harness.service.prepare(
        harness.request(callId: 'call-excess'),
      );
      expect(
        excess.diagnostics.map((entry) => entry.code),
        contains('active_operation_capacity_exhausted'),
      );
      expect(harness.service.activeEnforcedOperationCount, 1);
      expect(harness.service.semanticInvocationCount, 1);

      decisionGate.complete();
      final firstAdmission = await firstPreparation;
      expect(firstAdmission.admitted, isTrue);
      expect(harness.service.activeEnforcedOperationCount, 0);
    },
  );

  test(
    'off and shadow ignore TTL, catalog, and observer audit changes',
    () async {
      for (final mode in <FeatureRolloutMode>[
        FeatureRolloutMode.off,
        FeatureRolloutMode.shadow,
      ]) {
        final harness = await _Harness.create(
          mode: mode,
          now: now,
          auditDeadline: const Duration(milliseconds: 10),
        );
        if (mode == FeatureRolloutMode.shadow) {
          harness.audit.gates[ActionAuditStage.decided] = Completer<void>();
        }
        final request = harness.request();
        final admission = await harness.service
            .prepare(request)
            .timeout(const Duration(milliseconds: 100));
        final callerOutput = Object();
        harness.monotonic.value = const Duration(hours: 1);
        harness.registerExtra();
        harness.audit.fail = true;
        var calls = 0;

        final result = await harness.service.execute(
          admission: admission,
          currentRequest: harness.request(
            arguments: const <String, Object?>{'value': 'changed'},
          ),
          legacyCallback: () {
            calls += 1;
            return ActionContractLegacyResult(
              callerOutput: callerOutput,
              actionOutputs: const <Object?>['ok'],
            );
          },
        );

        expect(result.outputForCaller, same(callerOutput), reason: mode.name);
        expect(calls, 1, reason: mode.name);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    },
  );

  test(
    'shadow audit stays detached from behavior but joins account drain',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.shadow,
        now: now,
        auditDeadline: const Duration(seconds: 2),
      );
      final auditGate = Completer<void>();
      harness.audit.gates[ActionAuditStage.decided] = auditGate;

      final admission = await harness.service
          .prepare(harness.request())
          .timeout(const Duration(milliseconds: 100));
      expect(admission.admitted, isTrue);
      expect(harness.service.activeOperationCount, 1);

      var drained = false;
      final drain = harness.service.sealAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);

      auditGate.complete();
      await drain.timeout(const Duration(milliseconds: 100));
      expect(drained, isTrue);
      expect(harness.service.activeOperationCount, 0);
    },
  );

  test('catalog conflicts permanently disable exact enforce lookup', () async {
    final catalog = ProductionActionDefinitionCatalog();
    final first = _testProduction();
    catalog.register(first);
    final beforeConflict = catalog.revision;

    expect(() => catalog.register(_testProduction()), throwsStateError);
    expect(catalog.isConflicted('test.read'), isTrue);
    expect(catalog.find('test.read'), same(first));
    expect(catalog.findExact('test.read'), isNull);
    expect(catalog.revision, beforeConflict + 1);
    catalog.markConflict('test.read');
    expect(catalog.revision, beforeConflict + 1);

    final enforce = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    enforce.catalog.markConflict('test.read');
    final enforceRequest = enforce.request();
    final enforceAdmission = await enforce.service.prepare(enforceRequest);
    var enforceCalls = 0;
    final enforceResult = await enforce.service.execute(
      admission: enforceAdmission,
      currentRequest: enforceRequest,
      legacyCallback: () {
        enforceCalls += 1;
        return ActionContractLegacyResult.single('ok');
      },
    );
    expect(
      enforceAdmission.diagnostics.map((entry) => entry.code),
      contains('definition_conflicted'),
    );
    expect(enforceResult.outcome?.code, 'contract_rejected');
    expect(enforceCalls, 0);

    final shadow = await _Harness.create(
      mode: FeatureRolloutMode.shadow,
      now: now,
    );
    shadow.catalog.markConflict('test.read');
    final shadowRequest = shadow.request();
    final shadowAdmission = await shadow.service.prepare(shadowRequest);
    final marker = Object();
    final shadowResult = await shadow.service.execute(
      admission: shadowAdmission,
      currentRequest: shadowRequest,
      legacyCallback: () => ActionContractLegacyResult(
        callerOutput: marker,
        actionOutputs: const <Object?>['ok'],
      ),
    );
    expect(shadowAdmission.admitted, isTrue);
    expect(shadowResult.outputForCaller, same(marker));
  });

  test('request construction rejects an unbounded action list', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );

    expect(
      () => harness.request(
        actions: List<ActionContractCall>.filled(1025, harness.call()),
      ),
      throwsArgumentError,
    );
  });

  test('channel taxonomy independently covers every production path', () {
    expect(
      ActionContractChannel.values.toSet(),
      containsAll(<ActionContractChannel>{
        ActionContractChannel.structured,
        ActionContractChannel.nativeTool,
        ActionContractChannel.localAgent,
        ActionContractChannel.delayedTool,
        ActionContractChannel.realtime,
        ActionContractChannel.appControl,
        ActionContractChannel.surface,
      }),
    );
    final production = _testProduction(
      channels: ActionContractChannel.values.toSet(),
    );
    for (final channel in ActionContractChannel.values) {
      expect(production.allowsChannel(channel), isTrue, reason: channel.name);
    }
  });

  test('mixed structured and surface calls bind per-call channels', () async {
    final harness = await _Harness.create(
      mode: FeatureRolloutMode.enforce,
      now: now,
    );
    final surface = harness.registerSurface();
    final request = harness.request(
      actions: <ActionContractCall>[
        harness.call(),
        ActionContractCall(
          actionId: 'surface.show',
          arguments: const <String, Object?>{'value': 'ok'},
          channel: ActionContractChannel.surface,
          expectedDefinition: surface,
        ),
      ],
    );
    final admission = await harness.service.prepare(request);
    var calls = 0;
    final result = await harness.service.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: () {
        calls += 1;
        return const ActionContractLegacyResult(
          callerOutput: 'legacy',
          actionOutputs: <Object?>['ok', 'ok'],
        );
      },
    );

    expect(admission.admitted, isTrue);
    expect(result.outcome?.isOk, isTrue);
    expect(calls, 1);
  });

  test(
    'wrong per-call channel rejects whole enforce batch before callback',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final request = harness.request(
        actions: <ActionContractCall>[
          harness.call(channel: ActionContractChannel.surface),
        ],
      );
      final admission = await harness.service.prepare(request);
      var calls = 0;
      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult.single('ok');
        },
      );

      expect(
        admission.diagnostics.map((entry) => entry.code),
        contains('channel_denied'),
      );
      expect(result.outcome?.code, 'contract_rejected');
      expect(calls, 0);
    },
  );

  test(
    'mismatched exact definition identity rejects enforce with zero effect',
    () async {
      final harness = await _Harness.create(
        mode: FeatureRolloutMode.enforce,
        now: now,
      );
      final impostor = _testProduction();
      final request = harness.request(
        actions: <ActionContractCall>[
          harness.call(expectedDefinition: impostor),
        ],
      );
      final admission = await harness.service.prepare(request);
      var calls = 0;
      final result = await harness.service.execute(
        admission: admission,
        currentRequest: request,
        legacyCallback: () {
          calls += 1;
          return ActionContractLegacyResult.single('ok');
        },
      );

      expect(
        admission.diagnostics.map((entry) => entry.code),
        contains('definition_identity_mismatch'),
      );
      expect(result.outcome?.code, 'contract_rejected');
      expect(calls, 0);
    },
  );

  test('intrinsic catalog exposes voice fallback and avatar auto react', () {
    final catalog = ProductionActionDefinitionCatalog.intrinsics();
    final voice = catalog.find('voice.fallback');
    final avatar = catalog.find('avatar.auto_react');
    expect(voice, isNotNull);
    expect(avatar, isNotNull);
    expect(voice!.allowsChannel(ActionContractChannel.synthetic), isTrue);
    expect(avatar!.allowsChannel(ActionContractChannel.synthetic), isTrue);
    expect(
      voice.enforcementEligibility,
      ActionEnforcementEligibility.reversibleLocal,
    );
    expect(
      avatar.enforcementEligibility,
      ActionEnforcementEligibility.reversibleLocal,
    );
    expect(catalog.definitions, hasLength(2));
  });
}

final class _Harness {
  _Harness._({
    required this.flags,
    required this.catalog,
    required this.audit,
    required this.service,
    required this.now,
    required this.monotonic,
  });

  static Future<_Harness> create({
    required FeatureRolloutMode mode,
    required DateTime now,
    int maximumPendingTickets = 128,
    int maximumDiagnostics = 256,
    int maximumInvocationRecords = 512,
    int maximumActiveEnforcedOperations = 64,
    Duration ticketTtl = const Duration(minutes: 2),
    Duration invocationRetention = const Duration(minutes: 10),
    Duration auditDeadline = const Duration(seconds: 2),
    Duration readOnlyCallbackDeadline = const Duration(seconds: 30),
  }) async {
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
    final catalog = ProductionActionDefinitionCatalog()
      ..register(_testProduction());
    final audit = _AuditSink();
    final monotonic = _MutableDurationClock();
    final service = ActionContractV2Service(
      featureFlags: flags,
      catalog: catalog,
      audit: audit,
      accountScope: 'account-a',
      accountGeneration: 7,
      mountIsCurrent: () => true,
      maximumPendingTickets: maximumPendingTickets,
      maximumDiagnostics: maximumDiagnostics,
      maximumInvocationRecords: maximumInvocationRecords,
      maximumActiveEnforcedOperations: maximumActiveEnforcedOperations,
      ticketTtl: ticketTtl,
      invocationRetention: invocationRetention,
      auditDeadline: auditDeadline,
      readOnlyCallbackDeadline: readOnlyCallbackDeadline,
      monotonicNow: monotonic.call,
    );
    return _Harness._(
      flags: flags,
      catalog: catalog,
      audit: audit,
      service: service,
      now: now,
      monotonic: monotonic,
    );
  }

  final MaasoFeatureFlagService flags;
  final ProductionActionDefinitionCatalog catalog;
  final _AuditSink audit;
  final ActionContractV2Service service;
  final DateTime now;
  final _MutableDurationClock monotonic;
  int revision = 1;

  int get definitionHandlerCalls => _definitionHandlerCalls;

  ActionContractCall call({
    Map<String, Object?> arguments = const <String, Object?>{'value': 'ok'},
    String? target,
    ActionContractChannel? channel,
    ProductionActionDefinition? expectedDefinition,
  }) => ActionContractCall(
    actionId: 'test.read',
    arguments: arguments,
    target: target,
    channel: channel,
    expectedDefinition: expectedDefinition ?? catalog.find('test.read'),
  );

  ActionContractEnvelopeRequest request({
    Map<String, Object?> arguments = const <String, Object?>{'value': 'ok'},
    String? target,
    int accountGeneration = 7,
    String accountScope = 'account-a',
    String agentId = 'agent-a',
    String callId = 'call-1',
    List<ActionContractCall>? actions,
    ActionContractChannel channel = ActionContractChannel.structured,
  }) => ActionContractEnvelopeRequest(
    invocation: ActionContractInvocationScope(
      accountScope: accountScope,
      accountGeneration: accountGeneration,
      agentId: agentId,
      callId: callId,
    ),
    scope: AgentActionScope.chat,
    channel: channel,
    actions:
        actions ??
        <ActionContractCall>[call(arguments: arguments, target: target)],
  );

  Future<void> setMode(FeatureRolloutMode mode) async {
    revision += 1;
    await flags.assign(
      flag: MaasoFeatureFlag.actionContractV2,
      mode: mode,
      revision: revision,
      expiresAt: now.add(const Duration(hours: 1)),
    );
  }

  void registerExtra() {
    catalog.register(
      ProductionActionDefinition(
        definition: ActionDefinition(
          id: 'test.extra',
          inputSchema: _inputSchema,
          outputSchema: _outputSchema,
          scopes: const <AgentActionScope>{AgentActionScope.chat},
          risk: ActionRisk.readOnly,
          consequencePolicy: ActionConsequencePolicy.reversible,
          handler: (_) => throw StateError('metadata_handler_ran'),
        ),
        channels: const <ActionContractChannel>{
          ActionContractChannel.structured,
        },
        enforcementEligibility: ActionEnforcementEligibility.readOnly,
      ),
    );
  }

  ProductionActionDefinition registerSurface() {
    final production = ProductionActionDefinition(
      definition: ActionDefinition(
        id: 'surface.show',
        inputSchema: _inputSchema,
        outputSchema: _outputSchema,
        scopes: const <AgentActionScope>{AgentActionScope.chat},
        risk: ActionRisk.readOnly,
        consequencePolicy: ActionConsequencePolicy.reversible,
        targetResolver: (_) => 'surface:test',
        handler: (_) => throw StateError('metadata_handler_ran'),
      ),
      channels: const <ActionContractChannel>{ActionContractChannel.surface},
      enforcementEligibility: ActionEnforcementEligibility.readOnly,
    );
    catalog.register(production);
    return production;
  }
}

final class _MutableDurationClock {
  Duration value = Duration.zero;

  Duration call() => value;
}

final class _ThrowingToString {
  @override
  String toString() => throw StateError('to_string_must_not_run');
}

int _definitionHandlerCalls = 0;

ProductionActionDefinition _testProduction({
  Set<ActionContractChannel> channels = const <ActionContractChannel>{
    ActionContractChannel.structured,
  },
}) => ProductionActionDefinition(
  definition: ActionDefinition(
    id: 'test.read',
    inputSchema: _inputSchema,
    outputSchema: _outputSchema,
    scopes: const <AgentActionScope>{AgentActionScope.chat},
    risk: ActionRisk.readOnly,
    consequencePolicy: ActionConsequencePolicy.reversible,
    targetResolver: (_) => 'resource:test',
    handler: (_) {
      _definitionHandlerCalls += 1;
      throw StateError('metadata_handler_ran');
    },
  ),
  channels: channels,
  enforcementEligibility: ActionEnforcementEligibility.readOnly,
);

const Map<String, dynamic> _inputSchema = <String, dynamic>{
  'type': 'object',
  'properties': <String, Object?>{
    'value': <String, Object?>{'type': 'string'},
  },
  'required': <String>['value'],
  'additionalProperties': false,
};

const Map<String, dynamic> _outputSchema = <String, dynamic>{
  'type': 'object',
  'properties': <String, Object?>{
    'value': <String, Object?>{'type': 'string'},
  },
  'required': <String>['value'],
  'additionalProperties': false,
};

final class _AuditSink implements ActionContractV2AuditSink {
  final List<ActionContractAuditRecord> records = <ActionContractAuditRecord>[];
  final List<String?> receiptIds = <String?>[];
  final Map<String, String> _ids = <String, String>{};
  final Map<ActionAuditStage, Completer<void>> gates =
      <ActionAuditStage, Completer<void>>{};
  bool fail = false;
  bool returnNull = false;
  ActionAuditStage? failAtStage;
  ActionAuditStage? returnNullAtStage;
  ActionAuditStage? breakContinuityAtStage;

  @override
  Future<String?> record(ActionContractAuditRecord record) async {
    final gate = gates[record.stage];
    if (gate != null) await gate.future;
    if (fail || failAtStage == record.stage) {
      throw StateError('injected_audit_failure');
    }
    records.add(record);
    if (returnNull || returnNullAtStage == record.stage) {
      receiptIds.add(null);
      return null;
    }
    final identity =
        '${record.invocation.accountScope}|'
        '${record.invocation.accountGeneration}|'
        '${record.invocation.agentId}|${record.invocation.callId}|'
        '${record.actionIndex}|${record.channel.name}|${record.definition.id}';
    final stable = _ids.putIfAbsent(identity, () => 'audit:${_ids.length + 1}');
    final receipt = breakContinuityAtStage == record.stage
        ? '$stable:broken:${record.stage.name}'
        : stable;
    receiptIds.add(receipt);
    return receipt;
  }
}

final class _MemoryFlagStore implements MaasoFeatureFlagAssignmentStore {
  final List<Map<String, Object?>> _rows = <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      _rows.map(Map<String, Object?>.from).toList(growable: false);

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    _rows.removeWhere((row) => row['flag'] == assignment.flag.key);
    _rows.add(assignment.toJson());
  }
}
