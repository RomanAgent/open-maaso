import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_gates.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_manifest.dart';

import 'persona_package_test_support.dart';

void main() {
  final initialNow = DateTime.utc(2026, 8, 30, 12);

  tearDown(appServices.reset);

  test(
    'host invocation rejects a handler result after grant revocation',
    () async {
      final harness = _PersonaInvocationHarness.create(initialNow);
      final started = Completer<void>();
      final release = Completer<void>();
      harness.skill.onRun = () async {
        started.complete();
        await release.future;
      };
      final tool = harness.toolsByMethod['run']!;

      final execution = harness.executor.execute(
        AgentActionEnvelope(
          reply: '',
          actions: <AgentAction>[
            AgentAction(
              type: 'skill.call',
              data: <String, Object?>{
                'tool': tool,
                'args': const <String, Object?>{
                  'direction': 'left',
                  'steps': 1,
                },
              },
            ),
          ],
        ),
      );
      await started.future;
      harness.registry.invalidate();
      release.complete();

      final result = await execution;
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('skill_not_granted'));
    },
  );

  test('canonical operation digest is order-stable and target-bound', () {
    final first = PersonaOperationRequest(
      skillId: 'companion.chat',
      method: 'run',
      arguments: <String, Object?>{'b': 2, 'a': 1},
      target: 'device://toy/primary',
    );
    final second = PersonaOperationRequest(
      skillId: 'companion.chat',
      method: 'run',
      arguments: <String, Object?>{'a': 1, 'b': 2},
      target: 'device://toy/primary',
    );
    final otherTarget = PersonaOperationRequest(
      skillId: 'companion.chat',
      method: 'run',
      arguments: <String, Object?>{'a': 1, 'b': 2},
      target: 'device://toy/other',
    );

    expect(first.canonicalArgsTargetDigest, second.canonicalArgsTargetDigest);
    expect(
      first.canonicalArgsTargetDigest,
      isNot(otherTarget.canonicalArgsTargetDigest),
    );
  });

  test(
    'direct callers cannot mint an admission without host context',
    () async {
      final harness = _PersonaInvocationHarness.create(initialNow);
      final clock = _MutableClock(initialNow);
      final fence = _MutableTrustFence(harness.scope);
      final operation = _operation();

      final decision =
          await _gate(
            clock,
            fence,
            harness,
            consumer: _MemoryReceiptConsumer(),
          ).admit(
            installation: harness.installation,
            permission: PersonaPermission.deviceMotion,
            operation: operation,
            approvalReceipt: _receipt(
              harness.installation,
              'forged-call',
              operation,
              clock.now(),
            ),
          );

      expect(decision.reason, 'host_invocation_required');
      expect(decision.admission, isNull);
    },
  );

  test('exact host binding admits once and commit runs only once', () async {
    final harness = _PersonaInvocationHarness.create(initialNow);
    final clock = _MutableClock(initialNow);
    final fence = _MutableTrustFence(harness.scope);
    final consumer = _MemoryReceiptConsumer();
    var effectCalls = 0;
    late PersonaAdmissionDecision admissionDecision;
    late PersonaAdmissionDecision receiptReplay;
    late PersonaCommitDecision firstCommit;
    late PersonaCommitDecision replayCommit;

    await harness.execute(() async {
      final operation = _operation();
      final gate = _gate(clock, fence, harness, consumer: consumer);
      final receipt = _receipt(
        harness.installation,
        ActionInvocationContext.current!.callId,
        operation,
        clock.now(),
      );
      admissionDecision = await gate.admit(
        installation: harness.installation,
        permission: PersonaPermission.deviceMotion,
        operation: operation,
        approvalReceipt: receipt,
      );
      receiptReplay = await gate.admit(
        installation: harness.installation,
        permission: PersonaPermission.deviceMotion,
        operation: operation,
        approvalReceipt: receipt,
      );
      final prepared = admissionDecision.admission!
          .prepare(operation: operation)
          .prepared!;
      firstCommit = prepared.commitTo(
        sink: _testSink(
          harness.sinkAuthority,
          prepared: prepared,
          effect: () {
            effectCalls += 1;
          },
        ),
      );
      replayCommit = prepared.commitTo(
        sink: _testSink(
          harness.sinkAuthority,
          prepared: prepared,
          effect: () {
            effectCalls += 1;
          },
        ),
      );
    });

    expect(admissionDecision.status, PersonaGateStatus.admitted);
    expect(firstCommit.committed, isTrue);
    expect(receiptReplay.reason, 'approval_replayed');
    expect(replayCommit.reason, 'prepared_operation_already_consumed');
    expect(effectCalls, 1);
    expect(consumer.consumeCalls, 2);
  });

  test(
    'same-named independent registration and mismatched action args execute zero effects',
    () async {
      for (final scenario in <String>['same-name', 'args']) {
        final harness = _PersonaInvocationHarness.create(initialNow);
        final clock = _MutableClock(initialNow);
        final fence = _MutableTrustFence(harness.scope);
        final consumer = _MemoryReceiptConsumer();
        var effectCalls = 0;
        late PersonaAdmissionDecision decision;
        final registeredTool = scenario == 'same-name'
            ? _independentSameNameBinding()
            : harness.binding;

        await harness.execute(
          () async {
            final operation = _operation();
            decision =
                await _gate(
                  clock,
                  fence,
                  harness,
                  registeredHostTool: registeredTool,
                  consumer: consumer,
                ).admit(
                  installation: harness.installation,
                  permission: PersonaPermission.deviceMotion,
                  operation: operation,
                  approvalReceipt: _receipt(
                    harness.installation,
                    ActionInvocationContext.current!.callId,
                    operation,
                    clock.now(),
                  ),
                );
            final admission = decision.admission;
            if (admission != null) {
              final prepared = admission
                  .prepare(operation: operation)
                  .prepared!;
              prepared.commitTo(
                sink: _testSink(
                  harness.sinkAuthority,
                  prepared: prepared,
                  effect: () {
                    effectCalls += 1;
                  },
                ),
              );
            }
          },
          actionArguments: scenario == 'args'
              ? const <String, Object?>{'direction': 'right', 'steps': 1}
              : const <String, Object?>{'direction': 'left', 'steps': 1},
        );

        expect(decision.reason, 'host_binding_mismatch', reason: scenario);
        expect(consumer.consumeCalls, 0, reason: scenario);
        expect(effectCalls, 0, reason: scenario);
        appServices.reset();
      }
    },
  );

  test(
    'package permission union cannot be borrowed by another skill',
    () async {
      final manifest = portablePersonaManifest(
        skills: <Object?>[
          <String, Object?>{
            'id': 'companion.chat',
            'version': '1.0.0',
            'entryRef': 'package://skills/companion-chat',
            'permissions': <Object?>['voice.use'],
          },
          <String, Object?>{
            'id': 'other.motion',
            'version': '1.0.0',
            'entryRef': 'package://skills/companion-chat',
            'permissions': <Object?>['device.motion'],
          },
        ],
      );
      final harness = _PersonaInvocationHarness.create(
        initialNow,
        manifest: manifest,
      );
      final clock = _MutableClock(initialNow);
      final fence = _MutableTrustFence(harness.scope);
      final consumer = _MemoryReceiptConsumer();
      late PersonaAdmissionDecision decision;

      await harness.execute(() async {
        final operation = _operation();
        decision = await _gate(clock, fence, harness, consumer: consumer).admit(
          installation: harness.installation,
          permission: PersonaPermission.deviceMotion,
          operation: operation,
          approvalReceipt: _receipt(
            harness.installation,
            ActionInvocationContext.current!.callId,
            operation,
            clock.now(),
          ),
        );
      });

      expect(decision.reason, 'skill_permission_not_declared');
      expect(consumer.consumeCalls, 0);
    },
  );

  test('delayed verifier crossing expiry fails before consume', () async {
    final harness = _PersonaInvocationHarness.create(initialNow);
    final clock = _MutableClock(initialNow);
    final fence = _MutableTrustFence(harness.scope);
    final consumer = _MemoryReceiptConsumer();
    late PersonaAdmissionDecision decision;

    await harness.execute(() async {
      final operation = _operation();
      final receipt = _receipt(
        harness.installation,
        ActionInvocationContext.current!.callId,
        operation,
        clock.now(),
        lifetime: const Duration(seconds: 2),
      );
      decision =
          await _gate(
            clock,
            fence,
            harness,
            consumer: consumer,
            verifier: _TestReceiptVerifier(
              afterDelay: () => clock.advance(const Duration(seconds: 3)),
            ),
          ).admit(
            installation: harness.installation,
            permission: PersonaPermission.deviceMotion,
            operation: operation,
            approvalReceipt: receipt,
          );
    });

    expect(decision.status, PersonaGateStatus.rejected);
    expect(consumer.consumeCalls, 0);
  });

  test('verifier and durable consumer exceptions fail closed', () async {
    for (final failure in <String>['verifier', 'consumer']) {
      final harness = _PersonaInvocationHarness.create(initialNow);
      final clock = _MutableClock(initialNow);
      final fence = _MutableTrustFence(harness.scope);
      final consumer = _MemoryReceiptConsumer(
        throwOnConsume: failure == 'consumer',
      );
      late PersonaAdmissionDecision decision;

      await harness.execute(() async {
        final operation = _operation();
        decision =
            await _gate(
              clock,
              fence,
              harness,
              consumer: consumer,
              verifier: _TestReceiptVerifier(
                throwOnVerify: failure == 'verifier',
              ),
            ).admit(
              installation: harness.installation,
              permission: PersonaPermission.deviceMotion,
              operation: operation,
              approvalReceipt: _receipt(
                harness.installation,
                ActionInvocationContext.current!.callId,
                operation,
                clock.now(),
              ),
            );
      });

      expect(decision.admission, isNull, reason: failure);
      expect(
        decision.reason,
        failure == 'verifier' ? 'approval_invalid' : 'approval_consume_failed',
      );
      appServices.reset();
    }
  });

  test('account switch and revoke during verifier fail closed', () async {
    for (final mutation in <String>['account', 'revoke']) {
      final harness = _PersonaInvocationHarness.create(initialNow);
      final clock = _MutableClock(initialNow);
      final fence = _MutableTrustFence(harness.scope);
      final consumer = _MemoryReceiptConsumer();
      late PersonaAdmissionDecision decision;

      await harness.execute(() async {
        final operation = _operation();
        decision =
            await _gate(
              clock,
              fence,
              harness,
              consumer: consumer,
              verifier: _TestReceiptVerifier(
                afterDelay: () {
                  if (mutation == 'account') {
                    harness.scopes.unmount(harness.mount);
                  } else {
                    fence.revoked = true;
                  }
                },
              ),
            ).admit(
              installation: harness.installation,
              permission: PersonaPermission.deviceMotion,
              operation: operation,
              approvalReceipt: _receipt(
                harness.installation,
                ActionInvocationContext.current!.callId,
                operation,
                clock.now(),
              ),
            );
      }, expectExecutionSuccess: mutation != 'account');

      expect(decision.status, PersonaGateStatus.rejected, reason: mutation);
      expect(consumer.consumeCalls, 0, reason: mutation);
      appServices.reset();
    }
  });

  test(
    'revocation after consume but before side effect blocks commit',
    () async {
      final harness = _PersonaInvocationHarness.create(initialNow);
      final clock = _MutableClock(initialNow);
      final fence = _MutableTrustFence(harness.scope);
      final consumer = _MemoryReceiptConsumer();
      var effectCalls = 0;
      late PersonaCommitDecision commit;

      await harness.execute(() async {
        final operation = _operation();
        final decision = await _gate(clock, fence, harness, consumer: consumer)
            .admit(
              installation: harness.installation,
              permission: PersonaPermission.deviceMotion,
              operation: operation,
              approvalReceipt: _receipt(
                harness.installation,
                ActionInvocationContext.current!.callId,
                operation,
                clock.now(),
              ),
            );
        expect(decision.status, PersonaGateStatus.admitted);
        final prepared = decision.admission!
            .prepare(operation: operation)
            .prepared!;
        fence.revoked = true;
        commit = prepared.commitTo(
          sink: _testSink(
            harness.sinkAuthority,
            prepared: prepared,
            effect: () {
              effectCalls += 1;
            },
          ),
        );
      });

      expect(consumer.consumeCalls, 1);
      expect(commit.reason, 'admission_stale');
      expect(effectCalls, 0);
    },
  );

  test(
    'effect-held revoke and Host grant invalidation fail at token consume',
    () async {
      for (final mutation in <String>['revoke', 'grant']) {
        final harness = _PersonaInvocationHarness.create(initialNow);
        final clock = _MutableClock(initialNow);
        final fence = _MutableTrustFence(harness.scope);
        final consumer = _MemoryReceiptConsumer();
        var effectCalls = 0;
        late PersonaCommitDecision commit;

        await harness.execute(() async {
          final operation = _operation();
          final decision =
              await _gate(clock, fence, harness, consumer: consumer).admit(
                installation: harness.installation,
                permission: PersonaPermission.deviceMotion,
                operation: operation,
                approvalReceipt: _receipt(
                  harness.installation,
                  ActionInvocationContext.current!.callId,
                  operation,
                  clock.now(),
                ),
              );
          expect(decision.status, PersonaGateStatus.admitted);
          final prepared = decision.admission!
              .prepare(operation: operation)
              .prepared!;
          commit = prepared.commitTo(
            sink: _testSink(
              harness.sinkAuthority,
              prepared: prepared,
              beforeConsume: () {
                if (mutation == 'revoke') {
                  fence.revoked = true;
                } else {
                  harness.registry.invalidate();
                }
              },
              effect: () {
                effectCalls += 1;
              },
            ),
          );
        }, expectExecutionSuccess: mutation != 'grant');

        expect(commit.reason, 'effect_token_not_consumed', reason: mutation);
        expect(effectCalls, 0, reason: mutation);
        appServices.reset();
      }
    },
  );

  test(
    'a sink from another Host authority cannot consume the operation',
    () async {
      final harness = _PersonaInvocationHarness.create(initialNow);
      final clock = _MutableClock(initialNow);
      final fence = _MutableTrustFence(harness.scope);
      final consumer = _MemoryReceiptConsumer();
      var effectCalls = 0;
      late PersonaCommitDecision commit;

      await harness.execute(() async {
        final operation = _operation();
        final decision = await _gate(clock, fence, harness, consumer: consumer)
            .admit(
              installation: harness.installation,
              permission: PersonaPermission.deviceMotion,
              operation: operation,
              approvalReceipt: _receipt(
                harness.installation,
                ActionInvocationContext.current!.callId,
                operation,
                clock.now(),
              ),
            );
        final prepared = decision.admission!
            .prepare(operation: operation)
            .prepared!;
        commit = prepared.commitTo(
          sink: _testSink(
            PersonaEffectSinkAuthority(),
            prepared: prepared,
            effect: () {
              effectCalls += 1;
            },
          ),
        );
      });

      expect(commit.reason, 'effect_sink_untrusted');
      expect(effectCalls, 0);
    },
  );

  test('an effect sink is bound to one full admission identity', () async {
    final authority = PersonaEffectSinkAuthority();
    final source = _PersonaInvocationHarness.create(
      initialNow,
      sinkAuthority: authority,
    );
    final sourceClock = _MutableClock(initialNow);
    final sourceFence = _MutableTrustFence(source.scope);
    late PersonaSynchronousEffectSink sourceSink;
    var effectCalls = 0;

    await source.execute(() async {
      final operation = _operation();
      final decision =
          await _gate(
            sourceClock,
            sourceFence,
            source,
            consumer: _MemoryReceiptConsumer(),
          ).admit(
            installation: source.installation,
            permission: PersonaPermission.deviceMotion,
            operation: operation,
            approvalReceipt: _receipt(
              source.installation,
              ActionInvocationContext.current!.callId,
              operation,
              sourceClock.now(),
            ),
          );
      final prepared = decision.admission!
          .prepare(operation: operation)
          .prepared!;
      sourceSink = _testSink(
        authority,
        prepared: prepared,
        effect: () {
          effectCalls += 1;
        },
      );
    });

    final scenarios = <_SinkIdentityScenario>[
      const _SinkIdentityScenario(name: 'call-receipt-replay'),
      const _SinkIdentityScenario(name: 'method', method: 'other'),
      const _SinkIdentityScenario(name: 'skill', skillName: 'other.motion'),
      const _SinkIdentityScenario(
        name: 'installation-package-version',
        packageVersion: '1.2.1',
      ),
      const _SinkIdentityScenario(name: 'skill-version', skillVersion: '1.0.1'),
      const _SinkIdentityScenario(name: 'account', accountUuid: 'account-b'),
      const _SinkIdentityScenario(name: 'generation', remountOnce: true),
    ];

    for (final scenario in scenarios) {
      appServices.reset();
      final target = _PersonaInvocationHarness.create(
        initialNow,
        accountUuid: scenario.accountUuid,
        remountOnce: scenario.remountOnce,
        skillName: scenario.skillName,
        skillVersion: scenario.skillVersion,
        packageVersion: scenario.packageVersion,
        sinkAuthority: authority,
      );
      final clock = _MutableClock(initialNow);
      final fence = _MutableTrustFence(target.scope);
      late PersonaCommitDecision commit;

      await target.execute(() async {
        final operation = _operation(
          skillId: scenario.skillName,
          method: scenario.method,
        );
        final decision =
            await _gate(
              clock,
              fence,
              target,
              registeredHostTool: target.bindingFor(scenario.method),
              consumer: _MemoryReceiptConsumer(),
            ).admit(
              installation: target.installation,
              permission: PersonaPermission.deviceMotion,
              operation: operation,
              approvalReceipt: _receipt(
                target.installation,
                ActionInvocationContext.current!.callId,
                operation,
                clock.now(),
              ),
            );
        final prepared = decision.admission!
            .prepare(operation: operation)
            .prepared!;
        commit = prepared.commitTo(sink: sourceSink);
      }, method: scenario.method);

      expect(commit.reason, 'effect_sink_untrusted', reason: scenario.name);
      expect(effectCalls, 0, reason: scenario.name);
    }
  });

  test('an exact effect sink can produce at most one effect', () async {
    final harness = _PersonaInvocationHarness.create(initialNow);
    final clock = _MutableClock(initialNow);
    final fence = _MutableTrustFence(harness.scope);
    final consumer = _MemoryReceiptConsumer();
    var effectCalls = 0;
    late PersonaCommitDecision first;
    late PersonaCommitDecision replay;

    await harness.execute(() async {
      final operation = _operation();
      final callId = ActionInvocationContext.current!.callId;
      final gate = _gate(clock, fence, harness, consumer: consumer);
      final firstAdmission = await gate.admit(
        installation: harness.installation,
        permission: PersonaPermission.deviceMotion,
        operation: operation,
        approvalReceipt: _receipt(
          harness.installation,
          callId,
          operation,
          clock.now(),
          idSuffix: 'first',
        ),
      );
      final replayAdmission = await gate.admit(
        installation: harness.installation,
        permission: PersonaPermission.deviceMotion,
        operation: operation,
        approvalReceipt: _receipt(
          harness.installation,
          callId,
          operation,
          clock.now(),
          idSuffix: 'replay',
        ),
      );
      final firstPrepared = firstAdmission.admission!
          .prepare(operation: operation)
          .prepared!;
      final replayPrepared = replayAdmission.admission!
          .prepare(operation: operation)
          .prepared!;
      final sink = _testSink(
        harness.sinkAuthority,
        prepared: firstPrepared,
        effect: () {
          effectCalls += 1;
        },
      );

      first = firstPrepared.commitTo(sink: sink);
      replay = replayPrepared.commitTo(sink: sink);
    });

    expect(first.committed, isTrue);
    expect(replay.reason, 'effect_sink_untrusted');
    expect(effectCalls, 1);
  });

  test('an async effect callback is rejected before it can run', () async {
    final harness = _PersonaInvocationHarness.create(initialNow);
    final clock = _MutableClock(initialNow);
    final fence = _MutableTrustFence(harness.scope);
    var asyncBodyCalls = 0;

    await harness.execute(() async {
      final operation = _operation();
      final decision =
          await _gate(
            clock,
            fence,
            harness,
            consumer: _MemoryReceiptConsumer(),
          ).admit(
            installation: harness.installation,
            permission: PersonaPermission.deviceMotion,
            operation: operation,
            approvalReceipt: _receipt(
              harness.installation,
              ActionInvocationContext.current!.callId,
              operation,
              clock.now(),
            ),
          );
      final prepared = decision.admission!
          .prepare(operation: operation)
          .prepared!;
      Future<PersonaSynchronousEffectOutcome> asyncCommit(
        PersonaOperationCommitToken token,
      ) async {
        asyncBodyCalls += 1;
        if (token.consume()) await Future<void>.delayed(Duration.zero);
        return PersonaSynchronousEffectOutcome.committed;
      }

      expect(
        () => harness.sinkAuthority.issue(
          prepared: prepared,
          commit: asyncCommit as dynamic,
        ),
        throwsA(isA<TypeError>()),
      );
    });

    expect(asyncBodyCalls, 0);
  });

  test('Persona boundary validation errors never echo hostile input', () {
    const hostile = 'credential-secret\ncontrol-sequence';

    Object capture(Object Function() action) {
      try {
        action();
        fail('expected Persona boundary validation to fail');
      } on Object catch (error) {
        return error;
      }
    }

    final failures = <Object>[
      capture(
        () => PersonaOperationRequest(
          skillId: hostile,
          method: 'run',
          arguments: const <String, Object?>{},
          target: 'device://toy/primary',
        ),
      ),
      capture(
        () => PersonaOperationRequest(
          skillId: 'companion.chat',
          method: 'run',
          arguments: const <String, Object?>{},
          target: hostile,
        ),
      ),
      capture(
        () => PersonaOperationRequest(
          skillId: 'companion.chat',
          method: 'run',
          arguments: <String, Object?>{hostile: true},
          target: 'device://toy/primary',
        ),
      ),
      capture(
        () => PersonaPackageScope(accountId: 'account-a', facadeGeneration: 0),
      ),
    ];

    for (final failure in failures) {
      expect(failure, isA<PersonaBoundaryValidationException>());
      expect(failure.toString(), isNot(contains(hostile)));
      expect(failure.toString(), isNot(contains('account-a')));
    }
  });

  test('revocation completed by consume is rechecked before minting', () async {
    final harness = _PersonaInvocationHarness.create(initialNow);
    final clock = _MutableClock(initialNow);
    final fence = _MutableTrustFence(harness.scope);
    final consumer = _MemoryReceiptConsumer(
      afterConsume: () => fence.revoked = true,
    );
    late PersonaAdmissionDecision decision;

    await harness.execute(() async {
      final operation = _operation();
      decision = await _gate(clock, fence, harness, consumer: consumer).admit(
        installation: harness.installation,
        permission: PersonaPermission.deviceMotion,
        operation: operation,
        approvalReceipt: _receipt(
          harness.installation,
          ActionInvocationContext.current!.callId,
          operation,
          clock.now(),
        ),
      );
    });

    expect(consumer.consumeCalls, 1);
    expect(decision.reason, 'persona_revoked');
    expect(decision.admission, isNull);
  });
}

PersonaRuntimeAdmissionGate _gate(
  _MutableClock clock,
  _MutableTrustFence fence,
  _PersonaInvocationHarness harness, {
  GrantedHostTool? registeredHostTool,
  required _MemoryReceiptConsumer consumer,
  PersonaApprovalReceiptVerifier verifier = const _TestReceiptVerifier(),
}) => PersonaRuntimeAdmissionGate(
  clock: clock,
  trustFence: fence,
  approvalReceiptVerifier: verifier,
  receiptConsumer: consumer,
  registeredHostTool: registeredHostTool ?? harness.binding,
  effectSinkVerifier: harness.sinkAuthority.verifier,
);

PersonaOperationRequest _operation({
  String skillId = 'companion.chat',
  String method = 'run',
}) => PersonaOperationRequest(
  skillId: skillId,
  method: method,
  arguments: const <String, Object?>{'direction': 'left', 'steps': 1},
  target: 'device://toy/primary',
);

PersonaOnceApprovalReceipt _receipt(
  PersonaInstallation installation,
  String callId,
  PersonaOperationRequest operation,
  DateTime now, {
  Duration lifetime = const Duration(minutes: 1),
  String idSuffix = 'default',
}) {
  final skill = installation.skillsById[operation.skillId]!;
  return PersonaOnceApprovalReceipt(
    id: 'approval-$callId-$idSuffix',
    issuer: 'maaso.host',
    installationId: installation.id,
    manifestDigest: installation.manifestDigest,
    scope: installation.scope,
    skillId: skill.id,
    skillVersion: skill.version,
    skillEntryRef: skill.entryRef,
    method: operation.method,
    argsTargetDigest: operation.canonicalArgsTargetDigest,
    callId: callId,
    permission: PersonaPermission.deviceMotion,
    issuedAt: now.subtract(const Duration(seconds: 1)),
    expiresAt: now.add(lifetime),
  );
}

final class _MutableClock implements PersonaTrustedClock {
  _MutableClock(this.value);

  DateTime value;

  @override
  DateTime now() => value;

  void advance(Duration duration) => value = value.add(duration);
}

final class _MutableTrustFence implements PersonaRuntimeTrustFence {
  _MutableTrustFence(this.scope);

  PersonaPackageScope? scope;
  bool revoked = false;

  @override
  String get issuer => 'maaso.host';

  @override
  PersonaPackageScope? currentScope() => scope;

  @override
  bool isRevoked({
    required String installationId,
    required String manifestDigest,
    required String issuer,
  }) => revoked;
}

final class _TestReceiptVerifier implements PersonaApprovalReceiptVerifier {
  const _TestReceiptVerifier({this.afterDelay, this.throwOnVerify = false});

  final void Function()? afterDelay;
  final bool throwOnVerify;

  @override
  Future<bool> allows({
    required PersonaOnceApprovalReceipt receipt,
    required PersonaInstallation installation,
    required PersonaOperationRequest operation,
    required ActionInvocationContext invocation,
    required DateTime now,
  }) async {
    await Future<void>.delayed(Duration.zero);
    afterDelay?.call();
    if (throwOnVerify) throw StateError('verifier failed');
    return receipt.issuer == 'maaso.host';
  }
}

final class _MemoryReceiptConsumer implements PersonaApprovalReceiptConsumer {
  _MemoryReceiptConsumer({this.afterConsume, this.throwOnConsume = false});

  final Set<String> _ids = <String>{};
  final void Function()? afterConsume;
  final bool throwOnConsume;
  int consumeCalls = 0;

  @override
  Future<bool> consumeOnce(
    PersonaOnceApprovalReceipt receipt, {
    required DateTime now,
  }) async {
    consumeCalls += 1;
    if (throwOnConsume) throw StateError('consumer failed');
    final consumed = _ids.add(receipt.id);
    if (consumed) afterConsume?.call();
    return consumed;
  }
}

PersonaSynchronousEffectSink _testSink(
  PersonaEffectSinkAuthority authority, {
  required PersonaPreparedOperation prepared,
  required void Function() effect,
  void Function()? beforeConsume,
}) => authority.issue(
  prepared: prepared,
  commit: (token) {
    beforeConsume?.call();
    if (token.consume()) effect();
    return PersonaSynchronousEffectOutcome.committed;
  },
);

final class _SinkIdentityScenario {
  const _SinkIdentityScenario({
    required this.name,
    this.method = 'run',
    this.skillName = 'companion.chat',
    this.skillVersion = '1.0.0',
    this.packageVersion = '1.2.0',
    this.accountUuid = 'account-a',
    this.remountOnce = false,
  });

  final String name;
  final String method;
  final String skillName;
  final String skillVersion;
  final String packageVersion;
  final String accountUuid;
  final bool remountOnce;
}

final class _PersonaInvocationHarness {
  _PersonaInvocationHarness._({
    required this.scopes,
    required this.mount,
    required this.scope,
    required this.installation,
    required this.skill,
    required this.registry,
    required this.bindingsByMethod,
    required this.sinkAuthority,
    required this.executor,
    required this.toolsByMethod,
  });

  factory _PersonaInvocationHarness.create(
    DateTime now, {
    Map<String, Object?>? manifest,
    String accountUuid = 'account-a',
    bool remountOnce = false,
    String skillName = 'companion.chat',
    String skillVersion = '1.0.0',
    String packageVersion = '1.2.0',
    PersonaEffectSinkAuthority? sinkAuthority,
  }) {
    final scopes = appServices.put(AccountStorageScopeService());
    final accountScope = AccountStorageScope(
      environmentKey: 'test',
      accountUuid: accountUuid,
    );
    var mount = scopes.mount(accountScope);
    if (remountOnce) {
      scopes.unmount(mount);
      mount = scopes.mount(accountScope);
    }
    final scope = PersonaPackageScope(
      accountId: mount.scope.storageNamespace,
      facadeGeneration: mount.generation,
    );
    final effectiveManifest =
        manifest ??
        (portablePersonaManifest(
          skills: <Object?>[
            <String, Object?>{
              'id': skillName,
              'version': skillVersion,
              'entryRef': 'package://skills/companion-chat',
              'permissions': <Object?>['voice.use', 'device.motion'],
            },
          ],
        )..['version'] = packageVersion);
    final verified = verifiedPersonaPackage(
      scope: scope,
      importedAt: now,
      manifest: effectiveManifest,
    );
    final installation = const PersonaPackageInstallGate()
        .validate(
          verifiedPackage: verified,
          context: personaInstallContext(scope, now),
        )
        .installation!;
    final skill = _PersonaAdmissionSkill(skillName);
    final registry = LazyHostSkillRegistry(
      agentId: 'self',
      specs: <SkillSpec>[
        SkillSpec(
          id: 'persona_companion_chat',
          name: skill.skillName,
          description: skill.description,
          icon: Icons.security,
          color: Colors.blue,
          category: SkillCategory.core,
          factory: (_) => skill,
          hostRouting: HostSkillRoutingManifest(
            skillName: skill.skillName,
            summary: skill.description,
            methods: const <String>['run', 'other'],
            nativeMethods: const <String>['run', 'other'],
            terms: const <String>['persona'],
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
    final activated = grant.activatedSkills.single as _PersonaAdmissionSkill;
    final manager = SkillManager()..registerSkill(activated);
    final toolsByMethod = <String, String>{
      for (final method in const <String>['run', 'other'])
        method: SkillManager.nativeToolName(activated, method),
    };
    final bindingsByMethod = <String, GrantedHostTool>{
      for (final entry in toolsByMethod.entries)
        entry.key: grant.authorize(agentId: 'self', tool: entry.value)!,
    };
    return _PersonaInvocationHarness._(
      scopes: scopes,
      mount: mount,
      scope: scope,
      installation: installation,
      skill: activated,
      registry: registry,
      bindingsByMethod: bindingsByMethod,
      sinkAuthority: sinkAuthority ?? PersonaEffectSinkAuthority(),
      executor: AgentActionExecutor(
        agentId: 'self',
        skillManager: manager,
        locale: AppLocale.en,
        executableHostGrant: grant,
      ),
      toolsByMethod: toolsByMethod,
    );
  }

  final AccountStorageScopeService scopes;
  final AccountStorageScopeMount mount;
  final PersonaPackageScope scope;
  final PersonaInstallation installation;
  final _PersonaAdmissionSkill skill;
  final LazyHostSkillRegistry registry;
  final Map<String, GrantedHostTool> bindingsByMethod;
  final PersonaEffectSinkAuthority sinkAuthority;
  final AgentActionExecutor executor;
  final Map<String, String> toolsByMethod;

  GrantedHostTool get binding => bindingFor('run');

  GrantedHostTool bindingFor(String method) => bindingsByMethod[method]!;

  Future<void> execute(
    Future<void> Function() action, {
    String method = 'run',
    bool expectExecutionSuccess = true,
    Map<String, Object?> actionArguments = const <String, Object?>{
      'direction': 'left',
      'steps': 1,
    },
  }) async {
    skill.onRun = action;
    final tool = toolsByMethod[method]!;
    final result = await executor.execute(
      AgentActionEnvelope(
        reply: '',
        actions: <AgentAction>[
          AgentAction(
            type: 'skill.call',
            data: <String, Object?>{'tool': tool, 'args': actionArguments},
          ),
        ],
      ),
    );
    if (expectExecutionSuccess) {
      expect(result.ok, isTrue, reason: result.errors.join('\n'));
    } else {
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('skill_not_granted'));
    }
  }
}

final class _PersonaAdmissionSkill extends AgentSkill {
  _PersonaAdmissionSkill(this._skillName);

  final String _skillName;
  Future<void> Function()? onRun;

  @override
  String get skillName => _skillName;

  @override
  String get description => 'Persona admission integration test skill';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'run': (_) async {
          await onRun!();
          return jsonEncode(<String, Object?>{'status': 'ok'});
        },
        'other': (_) async {
          await onRun!();
          return jsonEncode(<String, Object?>{'status': 'ok'});
        },
      };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas =>
      const <String, Map<String, dynamic>>{
        'run': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'direction': <String, dynamic>{
              'type': 'string',
              'enum': <String>['left', 'right'],
            },
            'steps': <String, dynamic>{'type': 'integer', 'minimum': 1},
          },
          'required': <String>['direction', 'steps'],
          'additionalProperties': false,
        },
        'other': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'direction': <String, dynamic>{
              'type': 'string',
              'enum': <String>['left', 'right'],
            },
            'steps': <String, dynamic>{'type': 'integer', 'minimum': 1},
          },
          'required': <String>['direction', 'steps'],
          'additionalProperties': false,
        },
      };
}

GrantedHostTool _independentSameNameBinding() {
  final skill = _PersonaAdmissionSkill('companion.chat');
  final registry = LazyHostSkillRegistry(
    agentId: 'self',
    specs: <SkillSpec>[
      SkillSpec(
        id: 'independent_companion_chat',
        name: skill.skillName,
        description: skill.description,
        icon: Icons.warning,
        color: Colors.orange,
        category: SkillCategory.core,
        factory: (_) => skill,
        hostRouting: HostSkillRoutingManifest(
          skillName: skill.skillName,
          summary: skill.description,
          methods: const <String>['run', 'other'],
          nativeMethods: const <String>['run', 'other'],
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
  final activated = grant.activatedSkills.single;
  final tool = SkillManager.nativeToolName(activated, 'run');
  return grant.authorize(agentId: 'self', tool: tool)!;
}
