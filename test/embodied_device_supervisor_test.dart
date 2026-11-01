import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/device/embodied_device_facade.dart';
import 'package:maaso/src/core/services/device/embodied_device_supervisor.dart';
import 'package:maaso/src/core/services/device/physical_motion_policy.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';

void main() {
  group('EmbodiedDeviceSupervisor', () {
    test('production placeholder never grants motion authority', () async {
      const gateway = UnavailableEmbodiedMotionConfirmationGateway();
      final now = DateTime.utc(2026, 8, 30);
      final request = EmbodiedMotionConfirmationRequest(
        invocation: EmbodiedMotionInvocation(
          accountId: 'account-a',
          facadeGeneration: 1,
          agentId: 'self',
          runtimeGeneration: 1,
          callId: 'call-1',
        ),
        actionId: 'device.motion.move',
        target: 'device-a',
        motion:
            PhysicalMotionPolicy(accountId: 'account-a', facadeGeneration: 1)
                .bound(
                  const EmbodiedMotionRequest(
                    capability: EmbodiedDeviceCapability.move,
                  ),
                )
                .motion!,
        motionFingerprint: 'bounded-fingerprint',
        challengeNonce: 'bounded-challenge',
        issuedAt: now,
        expiresAt: now.add(const Duration(seconds: 30)),
      );

      final result = await gateway.confirm(request);

      expect(result.outcome, EmbodiedConfirmationOutcome.unavailable);
      expect(result.grant, isNull);
      await gateway.cancelAll();
    });

    test('off and shadow perform zero consequential writes', () async {
      final off = _Harness(mode: FeatureRolloutMode.off);

      final offResult = await off.execute();

      expect(offResult.outcome, EmbodiedSupervisorOutcome.disabled);
      expect(off.facade.capabilitiesCalls, 0);
      expect(off.facade.telemetryCalls, 0);
      expect(off.confirmation.requests, isEmpty);
      expect(off.audit.events, isEmpty);
      expect(off.facade.motionCalls, 0);
      expect(off.facade.stopCalls, 0);
      await off.supervisor.retireAndDrain();
      expect(off.facade.retireCalls, 1);

      final shadow = _Harness(mode: FeatureRolloutMode.shadow);
      final shadowResult = await shadow.execute();

      expect(shadowResult.outcome, EmbodiedSupervisorOutcome.shadowEligible);
      expect(shadow.facade.capabilitiesCalls, 1);
      expect(shadow.facade.telemetryCalls, 1);
      expect(shadow.confirmation.requests, isEmpty);
      expect(shadow.audit.events, isEmpty);
      expect(shadow.facade.motionCalls, 0);
      expect(shadow.facade.stopCalls, 0);
      await shadow.supervisor.retireAndDrain();
      expect(shadow.facade.retireCalls, 1);
    });

    test('unsupported motion fails before confirmation or audit', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.facade.supported
        ..remove(EmbodiedDeviceCapability.move)
        ..remove(EmbodiedDeviceCapability.stop);

      final result = await harness.execute();

      expect(result.outcome, EmbodiedSupervisorOutcome.denied);
      expect(result.code, 'capability_unsupported');
      expect(harness.confirmation.requests, isEmpty);
      expect(harness.audit.events, isEmpty);
      expect(harness.facade.motionCalls, 0);
      expect(harness.facade.stopCalls, 0);
      await harness.supervisor.retireAndDrain();
    });

    test('shadow also requires a fresh supported stop capability', () async {
      final harness = _Harness(mode: FeatureRolloutMode.shadow);
      harness.facade.supported.remove(EmbodiedDeviceCapability.stop);

      final result = await harness.execute();

      expect(result.outcome, EmbodiedSupervisorOutcome.shadowRejected);
      expect(result.code, 'stop_capability_unavailable');
      expect(harness.facade.motionCalls, 0);
      expect(harness.confirmation.requests, isEmpty);
      await harness.supervisor.retireAndDrain();
    });

    test(
      'wrong-generation stop snapshot is rejected before consequential work',
      () async {
        for (final mode in <FeatureRolloutMode>[
          FeatureRolloutMode.shadow,
          FeatureRolloutMode.enforce,
        ]) {
          final harness = _Harness(mode: mode)
            ..facade.stopSnapshotGeneration = 99;

          final result = await harness.execute();

          expect(
            result.outcome,
            mode == FeatureRolloutMode.shadow
                ? EmbodiedSupervisorOutcome.shadowRejected
                : EmbodiedSupervisorOutcome.denied,
            reason: mode.name,
          );
          expect(result.code, 'account_or_generation_mismatch');
          expect(harness.confirmation.requests, isEmpty);
          expect(harness.audit.events, isEmpty);
          expect(harness.facade.deadManArmCalls, 0);
          expect(harness.facade.motionCalls, 0);
          expect(harness.facade.stopCalls, 0);
          await harness.supervisor.retireAndDrain();
        }
      },
    );

    test('stop snapshot generation is rechecked after confirmation', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.facade.afterCapabilities = (call) {
        if (call == 1) harness.facade.stopSnapshotGeneration = 99;
      };

      final result = await harness.execute();

      expect(result.outcome, EmbodiedSupervisorOutcome.denied);
      expect(result.code, 'account_or_generation_mismatch');
      expect(harness.confirmation.requests, hasLength(1));
      expect(harness.facade.deadManArmCalls, 0);
      expect(harness.facade.motionCalls, 0);
      expect(harness.facade.stopCalls, 0);
      expect(
        harness.audit.events.last.outcomeCode,
        'account_or_generation_mismatch',
      );
      await harness.supervisor.retireAndDrain();
    });

    test(
      'stale authority makes shadow and enforce perform zero facade calls',
      () async {
        for (final mode in <FeatureRolloutMode>[
          FeatureRolloutMode.shadow,
          FeatureRolloutMode.enforce,
        ]) {
          final harness = _Harness(mode: mode)..authorityCurrent = false;

          final result = await harness.execute();

          expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
          expect(harness.facade.capabilitiesCalls, 0, reason: mode.name);
          expect(harness.facade.telemetryCalls, 0, reason: mode.name);
          expect(harness.facade.deadManArmCalls, 0, reason: mode.name);
          expect(harness.facade.motionCalls, 0, reason: mode.name);
          expect(harness.facade.stopCalls, 0, reason: mode.name);
          await harness.supervisor.retireAndDrain();
        }
      },
    );

    test(
      'authority is rechecked between every asynchronous state read',
      () async {
        final shadow = _Harness(mode: FeatureRolloutMode.shadow);
        shadow.facade.afterCapabilities = (_) =>
            shadow.authorityCurrent = false;
        final shadowResult = await shadow.execute();
        expect(shadowResult.outcome, EmbodiedSupervisorOutcome.shadowRejected);
        expect(shadow.facade.capabilitiesCalls, 1);
        expect(shadow.facade.telemetryCalls, 0);
        await expectLater(shadow.supervisor.retireAndDrain(), throwsStateError);

        final enforce = _Harness(mode: FeatureRolloutMode.enforce);
        enforce.facade.afterCapabilities = (call) {
          if (call == 2) enforce.authorityCurrent = false;
        };
        final enforceResult = await enforce.execute();
        expect(enforceResult.outcome, EmbodiedSupervisorOutcome.denied);
        expect(enforce.facade.capabilitiesCalls, 2);
        expect(enforce.facade.telemetryCalls, 1);
        expect(enforce.facade.deadManArmCalls, 0);
        expect(enforce.facade.motionCalls, 0);
        expect(
          enforce.audit.events.last.stage,
          EmbodiedMotionAuditStage.result,
        );
        await expectLater(
          enforce.supervisor.retireAndDrain(),
          throwsStateError,
        );
      },
    );

    test(
      'stop during a held state read fences the epoch before a second read',
      () async {
        final capabilities = _Harness(mode: FeatureRolloutMode.shadow);
        capabilities.facade.holdCapabilities = true;
        final heldCapabilities = capabilities.execute();
        await pumpEventQueue();
        expect(capabilities.facade.capabilitiesCalls, 1);

        expect(await capabilities.supervisor.stop(), isTrue);
        capabilities.facade.releaseCapabilities();
        final capabilitiesResult = await heldCapabilities;

        expect(
          capabilitiesResult.outcome,
          EmbodiedSupervisorOutcome.shadowRejected,
        );
        expect(capabilities.facade.telemetryCalls, 0);
        expect(capabilities.confirmation.requests, isEmpty);
        await capabilities.supervisor.retireAndDrain();

        final telemetry = _Harness(mode: FeatureRolloutMode.enforce);
        telemetry.facade.holdTelemetry = true;
        final heldTelemetry = telemetry.execute();
        await pumpEventQueue();
        expect(telemetry.facade.capabilitiesCalls, 1);
        expect(telemetry.facade.telemetryCalls, 1);

        expect(await telemetry.supervisor.stop(), isTrue);
        telemetry.facade.releaseTelemetry();
        final telemetryResult = await heldTelemetry;

        expect(telemetryResult.outcome, EmbodiedSupervisorOutcome.denied);
        expect(telemetry.confirmation.requests, isEmpty);
        expect(telemetry.facade.deadManArmCalls, 0);
        await telemetry.supervisor.retireAndDrain();
      },
    );

    test(
      'kill switch during a held read skips telemetry and confirmation',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.facade.holdCapabilities = true;
        final motion = harness.execute();
        await pumpEventQueue();
        expect(harness.facade.capabilitiesCalls, 1);

        harness.mode = FeatureRolloutMode.off;
        harness.facade.releaseCapabilities();
        final result = await motion;

        expect(result.outcome, EmbodiedSupervisorOutcome.denied);
        expect(result.code, 'device_state_unavailable');
        expect(harness.facade.telemetryCalls, 0);
        expect(harness.confirmation.requests, isEmpty);
        expect(harness.facade.deadManArmCalls, 0);
        await harness.supervisor.retireAndDrain();
      },
    );

    test(
      'enforce confirms, audits, executes one lease, then watchdog stops',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);

        final first = await harness.execute();
        final concurrentLease = await harness.execute(callId: 'call-2');

        expect(first.outcome, EmbodiedSupervisorOutcome.executed);
        expect(concurrentLease.outcome, EmbodiedSupervisorOutcome.denied);
        expect(concurrentLease.code, 'motion_already_active');
        expect(harness.confirmation.requests, hasLength(1));
        expect(harness.facade.motionCalls, 1);
        expect(harness.facade.deadManArmCalls, 1);
        expect(
          harness.facade.callOrder.indexOf('armDeadMan'),
          lessThan(harness.facade.callOrder.indexOf('beginMotion')),
        );
        expect(harness.facade.stopCalls, 0);
        expect(
          harness.audit.events.map((event) => event.stage),
          <EmbodiedMotionAuditStage>[
            EmbodiedMotionAuditStage.asked,
            EmbodiedMotionAuditStage.decided,
            EmbodiedMotionAuditStage.executed,
            EmbodiedMotionAuditStage.result,
          ],
        );
        expect(harness.watchdogs.activeCount, 1);

        harness.now = harness.now.add(const Duration(seconds: 1));
        harness.watchdogs.fireLatest();
        await pumpEventQueue();

        expect(harness.facade.stopCalls, 1);
        expect(harness.supervisor.safetyState, PhysicalMotionSafetyState.idle);
        await harness.supervisor.retireAndDrain();
      },
    );

    test('hardware dead-man must arm successfully before motion', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.facade.deadManArmSucceeds = false;

      final result = await harness.execute();

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(result.code, 'dead_man_arm_failed');
      expect(harness.facade.deadManArmCalls, 1);
      expect(harness.facade.motionCalls, 0);
      expect(
        harness.audit.events.map((event) => event.outcomeCode),
        contains('dead_man_arm_failed'),
      );
      await harness.supervisor.retireAndDrain();
    });

    test('timed-out dead-man arm is cancelled and drained', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.facade.holdDeadManArm = true;

      final result = await harness.execute();

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(result.code, 'dead_man_arm_failed');
      expect(harness.facade.deadManArmCancellationCalls, 1);
      expect(harness.facade.motionCalls, 0);
      await harness.supervisor.retireAndDrain();
    });

    test(
      'fresh telemetry is re-read after confirmation and can veto motion',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.facade.telemetryFactory = () {
          final stale = harness.facade.telemetryCalls >= 2;
          return harness.facade.makeTelemetry(
            capturedAt: stale
                ? harness.now.subtract(const Duration(seconds: 3))
                : harness.now,
          );
        };

        final result = await harness.execute();

        expect(result.outcome, EmbodiedSupervisorOutcome.denied);
        expect(result.code, 'telemetry_stale');
        expect(harness.facade.telemetryCalls, 2);
        expect(harness.confirmation.requests, hasLength(1));
        expect(harness.facade.motionCalls, 0);
        await harness.supervisor.retireAndDrain();
      },
    );

    test(
      'rejected confirmation records decision and performs no write',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.confirmation.outcome = EmbodiedConfirmationOutcome.rejected;

        final result = await harness.execute();

        expect(result.outcome, EmbodiedSupervisorOutcome.confirmationRejected);
        expect(result.code, 'confirmation_rejected');
        expect(harness.facade.motionCalls, 0);
        expect(
          harness.audit.events.map((event) => event.stage),
          <EmbodiedMotionAuditStage>[
            EmbodiedMotionAuditStage.asked,
            EmbodiedMotionAuditStage.decided,
          ],
        );
        await harness.supervisor.retireAndDrain();
      },
    );

    test('audit failure fails closed before motion', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.audit.failOnCall = 1;

      final result = await harness.execute();
      final second = await harness.execute(callId: 'call-2');

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(result.code, 'audit_unavailable');
      expect(second.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(harness.supervisor.auditCompromised, isTrue);
      expect(harness.confirmation.requests, isEmpty);
      expect(harness.facade.motionCalls, 0);
      await harness.supervisor.retireAndDrain();
    });

    test('result audit failure forces stop and blocks later motion', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.audit.failOnCall = 4;

      final result = await harness.execute();
      final second = await harness.execute(callId: 'call-2');

      expect(result.outcome, EmbodiedSupervisorOutcome.failed);
      expect(harness.facade.motionCalls, 1);
      expect(harness.facade.stopCalls, 1);
      expect(harness.supervisor.auditCompromised, isTrue);
      expect(second.outcome, EmbodiedSupervisorOutcome.unavailable);
      await harness.supervisor.retireAndDrain();
    });

    test('stop failure remains fail-closed until a successful retry', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      expect(
        (await harness.execute()).outcome,
        EmbodiedSupervisorOutcome.executed,
      );
      harness.facade.stopSucceeds = false;

      expect(await harness.supervisor.onDisconnected(), isFalse);
      expect(
        harness.supervisor.safetyState,
        PhysicalMotionSafetyState.stopRequired,
      );
      final denied = await harness.execute(callId: 'call-2');
      expect(denied.outcome, EmbodiedSupervisorOutcome.denied);
      expect(denied.code, 'motion_already_active');
      expect(harness.facade.motionCalls, 1);

      harness.facade.stopSucceeds = true;
      harness.watchdogs.fireLatest();
      await pumpEventQueue();
      expect(harness.supervisor.safetyState, PhysicalMotionSafetyState.idle);
      expect(harness.facade.stopCalls, 4);
      await harness.supervisor.retireAndDrain();
    });

    test(
      'timed-out stop is cancelled and drained before persistent retry',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        expect(
          (await harness.execute()).outcome,
          EmbodiedSupervisorOutcome.executed,
        );
        harness.facade.holdStop = true;

        expect(await harness.supervisor.stop(), isFalse);
        expect(harness.facade.stopCalls, 3);
        expect(harness.facade.stopCancellationCalls, 3);
        expect(
          harness.supervisor.safetyState,
          PhysicalMotionSafetyState.stopRequired,
        );

        harness.facade.holdStop = false;
        harness.watchdogs.fireLatest();
        await pumpEventQueue();
        expect(harness.facade.stopCalls, 4);
        expect(harness.supervisor.safetyState, PhysicalMotionSafetyState.idle);
        await harness.supervisor.retireAndDrain();
      },
    );

    test(
      'hung stop drain fences retries, later motion, and rotated authority',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        expect(
          (await harness.execute()).outcome,
          EmbodiedSupervisorOutcome.executed,
        );
        harness.facade
          ..holdStop = true
          ..stopCancellationHangs = true;

        expect(await harness.supervisor.stop(), isFalse);
        expect(harness.facade.stopCalls, 1);
        expect(
          harness.supervisor.safetyState,
          PhysicalMotionSafetyState.stopRequired,
        );

        final blockedMotion = await harness.execute(callId: 'call-2');
        expect(blockedMotion.outcome, EmbodiedSupervisorOutcome.denied);
        expect(harness.facade.motionCalls, 1);

        expect(await harness.supervisor.stop(), isFalse);
        expect(harness.facade.stopCalls, 1);
        expect(
          harness.supervisor.safetyState,
          PhysicalMotionSafetyState.stopRequired,
        );

        harness.authorityCurrent = false;
        expect(await harness.supervisor.stop(), isFalse);
        expect(harness.facade.stopCalls, 1);
        expect(
          harness.supervisor.safetyState,
          PhysicalMotionSafetyState.stopRequired,
        );

        harness.authorityCurrent = true;
        harness.facade
          ..holdStop = false
          ..stopCancellationHangs = false
          ..releaseStopCancellation();
        await pumpEventQueue();

        expect(await harness.supervisor.stop(), isTrue);
        expect(harness.facade.stopCalls, 2);
        expect(harness.supervisor.safetyState, PhysicalMotionSafetyState.idle);
        await harness.supervisor.retireAndDrain();
      },
    );

    test('retire fences admission, cancels confirmation, and drains', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.confirmation.hold = true;
      final motion = harness.execute();
      await pumpEventQueue();
      expect(harness.confirmation.requests, hasLength(1));

      final retiring = harness.supervisor.retireAndDrain();
      await retiring;
      final result = await motion;
      final afterRetire = await harness.execute(callId: 'call-2');

      expect(harness.confirmation.cancelCalls, 1);
      expect(result.outcome, EmbodiedSupervisorOutcome.confirmationRejected);
      expect(harness.facade.motionCalls, 0);
      expect(harness.facade.retireCalls, 1);
      expect(afterRetire.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(harness.supervisor.safetyState, PhysicalMotionSafetyState.retired);
    });

    test(
      'retire permanently fences a facade with no prior invocation',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.off);

        final retirement = harness.supervisor.retireAndDrain();

        expect(harness.facade.retireCalls, 1);
        await retirement;
        expect(
          harness.supervisor.safetyState,
          PhysicalMotionSafetyState.retired,
        );
      },
    );

    test(
      'stop during executed audit fences the pending physical write',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.audit.holdOnCall = 3;
        final motion = harness.execute();
        await pumpEventQueue();
        expect(harness.audit.heldAppend, isNotNull);

        expect(await harness.supervisor.stop(), isTrue);
        expect(harness.facade.stopCalls, 1);
        harness.audit.releaseHeld();
        final result = await motion;

        expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
        expect(result.code, 'execution_fence_failed');
        expect(harness.facade.motionCalls, 0);
        await harness.supervisor.retireAndDrain();
      },
    );

    test(
      'emergency stop reaches facade before a blocked audit settles',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        expect(
          (await harness.execute()).outcome,
          EmbodiedSupervisorOutcome.executed,
        );
        harness.audit.holdOnCall = 5;

        final stopping = harness.supervisor.stop();
        await pumpEventQueue();
        expect(harness.facade.stopCalls, 1);
        expect(harness.audit.heldAppend, isNotNull);
        harness.audit.releaseHeld();

        expect(await stopping, isTrue);
        await harness.supervisor.retireAndDrain();
      },
    );

    test('failed stop audit is awaited by stop and retirement drain', () async {
      final harness = _Harness(
        mode: FeatureRolloutMode.enforce,
        maximumStopAttempts: 1,
      );
      expect(
        (await harness.execute()).outcome,
        EmbodiedSupervisorOutcome.executed,
      );
      harness.facade.stopSucceeds = false;
      harness.audit.holdOnCall = 6;

      final stopping = harness.supervisor.stop();
      await pumpEventQueue();
      expect(harness.audit.heldAppend, isNotNull);
      final retirement = harness.supervisor.retireAndDrain();
      var stopSettled = false;
      var retirementSettled = false;
      unawaited(stopping.whenComplete(() => stopSettled = true));
      unawaited(
        retirement.then<void>(
          (_) => retirementSettled = true,
          onError: (Object _, StackTrace _) => retirementSettled = true,
        ),
      );
      await pumpEventQueue();

      expect(harness.facade.retireCalls, 1);
      expect(stopSettled, isFalse);
      expect(retirementSettled, isFalse);
      harness.audit.releaseHeld();

      expect(await stopping, isFalse);
      await expectLater(retirement, throwsStateError);
      expect(harness.supervisor.auditCompromised, isFalse);
    });

    test('failed stop audit failure is bounded and fails closed', () async {
      final harness = _Harness(
        mode: FeatureRolloutMode.enforce,
        maximumStopAttempts: 1,
      );
      expect(
        (await harness.execute()).outcome,
        EmbodiedSupervisorOutcome.executed,
      );
      harness.facade.stopSucceeds = false;
      harness.audit.failOnCall = 6;

      expect(await harness.supervisor.stop(), isFalse);
      expect(harness.supervisor.auditCompromised, isTrue);
      await expectLater(harness.supervisor.retireAndDrain(), throwsStateError);
      expect(harness.facade.retireCalls, 1);
    });

    test(
      'manual stop invalidates a confirmation that is still pending',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.confirmation.hold = true;
        final motion = harness.execute();
        await pumpEventQueue();

        expect(await harness.supervisor.stop(), isTrue);
        harness.confirmation.releasePendingAllowed();
        final result = await motion;

        expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
        expect(harness.facade.motionCalls, 0);
        expect(harness.facade.stopCalls, 0);
        await harness.supervisor.retireAndDrain();
      },
    );

    test('rollout kill switch is checked again at physical commit', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.confirmation.hold = true;
      final motion = harness.execute();
      await pumpEventQueue();

      harness.mode = FeatureRolloutMode.off;
      harness.confirmation.releasePendingAllowed();
      final result = await motion;

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(harness.facade.motionCalls, 0);
      expect(harness.facade.stopCalls, 0);
      await harness.supervisor.retireAndDrain();
    });

    test(
      'confirmation is challenge-bound and consumed before admission',
      () async {
        final mismatch = _Harness(mode: FeatureRolloutMode.enforce);
        mismatch.confirmation.mismatchChallenge = true;
        final mismatched = await mismatch.execute();
        expect(mismatched.code, 'confirmation_mismatch');
        expect(mismatch.facade.motionCalls, 0);
        await mismatch.supervisor.retireAndDrain();

        final replay = _Harness(mode: FeatureRolloutMode.enforce);
        replay.confirmation.fixedReceiptId = 'one-shot-receipt';
        replay.facade.telemetryFactory = () => replay.facade.makeTelemetry(
          capturedAt: replay.facade.telemetryCalls == 2
              ? replay.now.subtract(const Duration(seconds: 3))
              : replay.now,
        );
        final first = await replay.execute();
        final second = await replay.execute(callId: 'call-2');

        expect(first.code, 'telemetry_stale');
        expect(second.code, 'confirmation_replayed');
        expect(replay.audit.events.last.outcomeCode, 'confirmation_replayed');
        expect(replay.facade.motionCalls, 0);
        await replay.supervisor.retireAndDrain();
      },
    );

    test('confirmation grant binds every authority and TTL field', () async {
      for (final field in <String>[
        'challengeNonce',
        'accountId',
        'facadeGeneration',
        'agentId',
        'runtimeGeneration',
        'callId',
        'actionId',
        'target',
        'motionFingerprint',
        'issuedAt',
        'expiresAt',
      ]) {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.confirmation.mismatchGrantField = field;

        final result = await harness.execute();

        expect(result.code, 'confirmation_mismatch', reason: field);
        expect(harness.facade.motionCalls, 0, reason: field);
        expect(
          harness.audit.events.last.outcomeCode,
          'confirmation_mismatch',
          reason: field,
        );
        await harness.supervisor.retireAndDrain();
      }
    });

    test('watchdog arm failure stops without invoking motion', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.watchdogs.throwOnSchedule = true;

      final result = await harness.execute();

      expect(result.code, 'watchdog_unavailable');
      expect(harness.facade.motionCalls, 0);
      expect(harness.facade.stopCalls, 1);
      await harness.supervisor.retireAndDrain();

      final synchronous = _Harness(mode: FeatureRolloutMode.enforce);
      synchronous.watchdogs.fireSynchronously = true;
      final synchronousResult = await synchronous.execute();
      expect(synchronousResult.code, 'execution_fence_failed');
      expect(synchronous.facade.motionCalls, 0);
      expect(synchronous.facade.stopCalls, 1);
      await synchronous.supervisor.retireAndDrain();
    });

    test(
      'dead-man stop survives an early fire and backward wall clock',
      () async {
        final early = _Harness(mode: FeatureRolloutMode.enforce);
        expect(
          (await early.execute()).outcome,
          EmbodiedSupervisorOutcome.executed,
        );
        early.watchdogs.fireLatest();
        await pumpEventQueue();
        expect(early.facade.stopCalls, 1);
        expect(early.supervisor.safetyState, PhysicalMotionSafetyState.idle);
        await early.supervisor.retireAndDrain();

        final rollback = _Harness(mode: FeatureRolloutMode.enforce);
        expect(
          (await rollback.execute()).outcome,
          EmbodiedSupervisorOutcome.executed,
        );
        rollback.now = rollback.now.subtract(const Duration(hours: 6));
        rollback.watchdogs.fireLatest();
        await pumpEventQueue();
        expect(rollback.facade.stopCalls, 1);
        expect(rollback.supervisor.safetyState, PhysicalMotionSafetyState.idle);
        await rollback.supervisor.retireAndDrain();
      },
    );

    test('stale motion and stop results never clear safety fences', () async {
      final motion = _Harness(mode: FeatureRolloutMode.enforce);
      motion.facade.motionResultGeneration = 99;
      final motionResult = await motion.execute();
      expect(motionResult.outcome, EmbodiedSupervisorOutcome.failed);
      expect(motion.facade.stopCalls, 1);
      await motion.supervisor.retireAndDrain();

      final stop = _Harness(mode: FeatureRolloutMode.enforce);
      expect(
        (await stop.execute()).outcome,
        EmbodiedSupervisorOutcome.executed,
      );
      stop.facade.stopResultGeneration = 99;
      expect(await stop.supervisor.stop(), isFalse);
      expect(stop.facade.stopCalls, 3);
      expect(
        stop.supervisor.safetyState,
        PhysicalMotionSafetyState.stopRequired,
      );
      stop.facade.stopResultGeneration = 1;
      await stop.supervisor.retireAndDrain();
    });

    test('hung motion is bounded and retirement still drains', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.facade.holdMotion = true;
      final motion = harness.execute();
      await pumpEventQueue();
      expect(harness.facade.motionCalls, 1);

      await harness.supervisor.retireAndDrain();
      final result = await motion;

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(harness.facade.stopCalls, 1);
      expect(harness.supervisor.safetyState, PhysicalMotionSafetyState.retired);
    });

    test(
      'timed-out queued motion is cancelled and cannot dispatch after retire',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.facade.delayMotionDispatch = true;

        final result = await harness.execute();
        expect(result.outcome, EmbodiedSupervisorOutcome.failed);
        expect(harness.facade.motionCalls, 0);
        expect(harness.facade.motionCancellationCalls, 1);
        expect(harness.facade.stopCalls, 1);

        await harness.supervisor.retireAndDrain();
        harness.facade.releaseDelayedMotionDispatch();
        await pumpEventQueue();
        expect(harness.facade.motionCalls, 0);
        expect(
          harness.supervisor.safetyState,
          PhysicalMotionSafetyState.retired,
        );
      },
    );

    test('hung motion drain keeps retirement failed closed', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.facade
        ..delayMotionDispatch = true
        ..motionCancellationHangs = true;
      unawaited(harness.execute());
      await pumpEventQueue();

      await expectLater(
        harness.supervisor.retireAndDrain(),
        throwsA(anyOf(isA<TimeoutException>(), isA<StateError>())),
      );
      harness.facade.releaseDelayedMotionDispatch();
      await pumpEventQueue();

      expect(harness.facade.motionCalls, 0);
      expect(harness.facade.motionCancellationCalls, 1);
      final afterFailure = await harness.execute(callId: 'call-2');
      expect(afterFailure.outcome, EmbodiedSupervisorOutcome.unavailable);
    });

    test('authority is rechecked after a held motion result', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.facade.holdMotion = true;
      final motion = harness.execute();
      await pumpEventQueue();
      expect(harness.facade.motionCalls, 1);

      harness.authorityCurrent = false;
      harness.facade.releaseMotionResult();
      final result = await motion;

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(result.code, 'execution_fence_failed_after_motion_result');
      expect(harness.facade.stopCalls, 0);
      await expectLater(harness.supervisor.retireAndDrain(), throwsStateError);
    });

    test(
      'stale-result audit settles before motion and retirement complete',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.facade.holdMotion = true;
        harness.audit.holdOnCall = 4;
        final motion = harness.execute();
        await pumpEventQueue();
        expect(harness.facade.motionCalls, 1);

        harness.authorityCurrent = false;
        harness.facade.releaseMotionResult();
        await pumpEventQueue();
        expect(harness.audit.heldAppend, isNotNull);

        var motionSettled = false;
        var retirementSettled = false;
        unawaited(
          motion.whenComplete(() {
            motionSettled = true;
          }),
        );
        final retirement = harness.supervisor.retireAndDrain();
        unawaited(
          retirement.then<void>(
            (_) => retirementSettled = true,
            onError: (Object _, StackTrace _) => retirementSettled = true,
          ),
        );
        await pumpEventQueue();

        expect(motionSettled, isFalse);
        expect(retirementSettled, isFalse);
        harness.audit.releaseHeld();

        final result = await motion;
        expect(result.code, 'execution_fence_failed_after_motion_result');
        await expectLater(retirement, throwsStateError);
      },
    );

    test('rollout is rechecked after a held result audit', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.audit.holdOnCall = 4;
      final motion = harness.execute();
      await pumpEventQueue();
      expect(harness.audit.heldAppend, isNotNull);

      harness.mode = FeatureRolloutMode.off;
      harness.audit.releaseHeld();
      final result = await motion;

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(result.code, 'execution_fence_failed_after_result_audit');
      expect(harness.facade.stopCalls, 1);
      await harness.supervisor.retireAndDrain();
    });

    test('lease freshness is rechecked after a held result audit', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.audit.holdOnCall = 4;
      final motion = harness.execute();
      await pumpEventQueue();
      expect(harness.audit.heldAppend, isNotNull);

      harness.now = harness.now.add(const Duration(seconds: 2));
      harness.audit.releaseHeld();
      final result = await motion;

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(result.code, 'execution_fence_failed_after_result_audit');
      expect(harness.facade.stopCalls, 1);
      await harness.supervisor.retireAndDrain();
    });

    test('confirmation mismatch gets a bounded terminal audit', () async {
      final harness = _Harness(mode: FeatureRolloutMode.enforce);
      harness.confirmation.mismatchChallenge = true;
      harness.audit.holdOnCall = 3;

      final result = await harness.execute();

      expect(result.outcome, EmbodiedSupervisorOutcome.unavailable);
      expect(result.code, 'audit_unavailable');
      expect(harness.facade.motionCalls, 0);
      expect(
        harness.audit.events.map((event) => event.stage),
        <EmbodiedMotionAuditStage>[
          EmbodiedMotionAuditStage.asked,
          EmbodiedMotionAuditStage.decided,
          EmbodiedMotionAuditStage.result,
        ],
      );
      expect(harness.audit.events.last.outcomeCode, 'confirmation_mismatch');
      harness.audit.releaseHeld();
      await harness.supervisor.retireAndDrain();
    });

    test(
      'hung confirmation cancellation fails retirement closed in bounded time',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.confirmation
          ..hold = true
          ..cancelHangs = true;
        unawaited(harness.execute());
        await pumpEventQueue();

        await expectLater(
          harness.supervisor.retireAndDrain(),
          throwsA(isA<TimeoutException>()),
        );
        final afterFailure = await harness.execute(callId: 'call-2');
        expect(afterFailure.outcome, EmbodiedSupervisorOutcome.unavailable);
        harness.confirmation.releasePendingAllowed();
      },
    );

    test(
      'authority and identity fences are checked before device motion',
      () async {
        final harness = _Harness(mode: FeatureRolloutMode.enforce);
        harness.authorityCurrent = false;

        final stale = await harness.execute();
        final wrongAccount = await harness.supervisor.executeMotion(
          invocation: EmbodiedMotionInvocation(
            accountId: 'account-b',
            facadeGeneration: 1,
            agentId: 'agent-a',
            runtimeGeneration: 1,
            callId: 'call-2',
          ),
          request: harness.request,
        );

        expect(stale.outcome, EmbodiedSupervisorOutcome.unavailable);
        expect(stale.code, 'authority_stale');
        expect(wrongAccount.outcome, EmbodiedSupervisorOutcome.unavailable);
        expect(harness.confirmation.requests, isEmpty);
        expect(harness.facade.motionCalls, 0);
        await harness.supervisor.retireAndDrain();
      },
    );

    test('ActionAuditLog adapter retains keyed target digest only', () async {
      const rawTarget = 'device:private-hardware-serial-123';
      final log = ActionAuditLog(capacity: 2);
      final sink = ActionAuditLogEmbodiedMotionAuditSink(log);
      final event = EmbodiedMotionAuditEvent(
        stage: EmbodiedMotionAuditStage.result,
        accountId: 'account-a',
        facadeGeneration: 1,
        agentId: 'agent-a',
        runtimeGeneration: 1,
        callId: 'call-a',
        actionId: 'device.motion.move',
        motionFingerprint: 'f' * 64,
        outcomeCode: 'succeeded',
        occurredAt: DateTime.utc(2026, 8, 30, 8),
      );

      expect(await sink.append(event, transientTarget: rawTarget), isTrue);
      final entries = log.query(
        scope: const ActionAuditScope(
          accountScope: 'account-a',
          agentId: 'agent-a',
          runtimeGeneration: 1,
        ),
      );
      expect(entries, hasLength(1));
      expect(entries.single.target, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(jsonEncode(entries.single.toJson()), isNot(contains(rawTarget)));
    });

    test('ActionAuditLog adapter resolves one shared log lazily', () async {
      final log = ActionAuditLog(capacity: 2);
      var resolutions = 0;
      final sink = ActionAuditLogEmbodiedMotionAuditSink.lazy(() {
        resolutions += 1;
        return log;
      });
      final event = EmbodiedMotionAuditEvent(
        stage: EmbodiedMotionAuditStage.result,
        accountId: 'account-a',
        facadeGeneration: 1,
        agentId: 'agent-a',
        runtimeGeneration: 1,
        callId: 'call-a',
        actionId: 'device.motion.move',
        motionFingerprint: 'f' * 64,
        outcomeCode: 'succeeded',
        occurredAt: DateTime.utc(2026, 8, 30, 8),
      );

      expect(resolutions, 0);
      expect(await sink.append(event, transientTarget: 'device-a'), isTrue);
      expect(await sink.append(event, transientTarget: 'device-a'), isTrue);
      expect(resolutions, 1);
      expect(log.length, 2);

      final failing = ActionAuditLogEmbodiedMotionAuditSink.lazy(
        () => throw StateError('resolver unavailable'),
      );
      expect(await failing.append(event, transientTarget: 'device-a'), isFalse);
    });
  });
}

final class _Harness {
  _Harness({required this.mode, int maximumStopAttempts = 3}) {
    motionAuthority = createEmbodiedMotionAuthorityPair();
    facade = _FakeFacade(
      clock: () => now,
      motionVerifier: motionAuthority.verifier,
    );
    policy = PhysicalMotionPolicy(accountId: 'account-a', facadeGeneration: 1);
    supervisor = EmbodiedDeviceSupervisor(
      facade: facade,
      policy: policy,
      rolloutMode: () => mode,
      authorityIsCurrent: (_) => authorityCurrent,
      confirmation: confirmation,
      audit: audit,
      motionCapabilityIssuer: motionAuthority.issuer,
      deviceTarget: 'device:test-projector',
      clock: () => now,
      scheduleWatchdog: watchdogs.schedule,
      confirmationTtl: const Duration(milliseconds: 150),
      auditTimeout: const Duration(milliseconds: 80),
      deviceCallTimeout: const Duration(milliseconds: 80),
      stopCallTimeout: const Duration(milliseconds: 80),
      retireTimeout: const Duration(milliseconds: 300),
      maximumStopAttempts: maximumStopAttempts,
    );
  }

  DateTime now = DateTime.utc(2026, 8, 30, 8);
  FeatureRolloutMode mode;
  bool authorityCurrent = true;
  final _FakeConfirmationGateway confirmation = _FakeConfirmationGateway();
  final _FakeAuditSink audit = _FakeAuditSink();
  final _ManualWatchdogScheduler watchdogs = _ManualWatchdogScheduler();
  late final _FakeFacade facade;
  late final EmbodiedMotionAuthorityPair motionAuthority;
  late final PhysicalMotionPolicy policy;
  late final EmbodiedDeviceSupervisor supervisor;

  EmbodiedMotionRequest get request => const EmbodiedMotionRequest(
    capability: EmbodiedDeviceCapability.move,
    distanceMeters: 0.5,
    speedMetersPerSecond: 0.25,
    duration: Duration(seconds: 2),
  );

  Future<EmbodiedSupervisorResult> execute({String callId = 'call-1'}) =>
      supervisor.executeMotion(
        invocation: EmbodiedMotionInvocation(
          accountId: 'account-a',
          facadeGeneration: 1,
          agentId: 'agent-a',
          runtimeGeneration: 1,
          callId: callId,
        ),
        request: request,
      );
}

final class _FakeFacade implements EmbodiedDeviceFacade {
  _FakeFacade({
    required DateTime Function() clock,
    required EmbodiedMotionCapabilityVerifier motionVerifier,
  }) : _clock = clock,
       _motionVerifier = motionVerifier;

  final DateTime Function() _clock;
  final EmbodiedMotionCapabilityVerifier _motionVerifier;
  final Set<EmbodiedDeviceCapability> supported = <EmbodiedDeviceCapability>{
    EmbodiedDeviceCapability.status,
    EmbodiedDeviceCapability.health,
    EmbodiedDeviceCapability.move,
    EmbodiedDeviceCapability.stop,
  };
  int capabilitiesCalls = 0;
  int telemetryCalls = 0;
  int motionCalls = 0;
  int deadManArmCalls = 0;
  int stopCalls = 0;
  int retireCalls = 0;
  bool deadManArmSucceeds = true;
  bool holdDeadManArm = false;
  bool stopSucceeds = true;
  bool holdStop = false;
  bool stopCancellationHangs = false;
  bool holdCapabilities = false;
  bool holdTelemetry = false;
  bool holdMotion = false;
  bool delayMotionDispatch = false;
  bool motionCancellationHangs = false;
  int motionResultGeneration = 1;
  int stopResultGeneration = 1;
  String stopSnapshotAccountId = 'account-a';
  int stopSnapshotGeneration = 1;
  EmbodiedDeviceCapability? stopResultCapability;
  EmbodiedDeviceTelemetry Function()? telemetryFactory;
  int motionCancellationCalls = 0;
  int deadManArmCancellationCalls = 0;
  int stopCancellationCalls = 0;
  void Function(int call)? afterCapabilities;
  void Function(int call)? afterTelemetry;
  final List<String> callOrder = <String>[];
  _FakeMotionOperation? lastMotionOperation;
  _FakeStopOperation? lastStopOperation;
  Completer<void>? _capabilitiesGate;
  Completer<void>? _telemetryGate;

  @override
  String get deviceId => 'fake-device';

  @override
  String get accountId => 'account-a';

  @override
  int get facadeGeneration => 1;

  @override
  Future<List<EmbodiedCapabilitySnapshot>> capabilities() async {
    capabilitiesCalls += 1;
    callOrder.add('capabilities');
    if (holdCapabilities) {
      final gate = _capabilitiesGate ??= Completer<void>();
      await gate.future;
    }
    final result = <EmbodiedCapabilitySnapshot>[
      for (final capability in EmbodiedDeviceCapability.values)
        EmbodiedCapabilitySnapshot(
          capability: capability,
          supported: supported.contains(capability),
          unit: supported.contains(capability)
              ? EmbodiedUnit.boolean
              : EmbodiedUnit.none,
          capturedAt: _clock(),
          freshness: EmbodiedFreshness.fresh,
          accountId: capability == EmbodiedDeviceCapability.stop
              ? stopSnapshotAccountId
              : accountId,
          facadeGeneration: capability == EmbodiedDeviceCapability.stop
              ? stopSnapshotGeneration
              : facadeGeneration,
        ),
    ];
    afterCapabilities?.call(capabilitiesCalls);
    return result;
  }

  @override
  Future<EmbodiedDeviceTelemetry> telemetry() async {
    telemetryCalls += 1;
    callOrder.add('telemetry');
    if (holdTelemetry) {
      final gate = _telemetryGate ??= Completer<void>();
      await gate.future;
    }
    final result = telemetryFactory?.call() ?? makeTelemetry();
    afterTelemetry?.call(telemetryCalls);
    return result;
  }

  EmbodiedDeviceTelemetry makeTelemetry({DateTime? capturedAt}) =>
      EmbodiedDeviceTelemetry(
        unit: EmbodiedUnit.boolean,
        capturedAt: capturedAt ?? _clock(),
        freshness: EmbodiedFreshness.fresh,
        accountId: accountId,
        facadeGeneration: facadeGeneration,
        connected: true,
        backgrounded: false,
        value: const EmbodiedBooleanValue(true),
      );

  @override
  Future<EmbodiedDeviceResult> status() async =>
      _result(EmbodiedDeviceCapability.status);

  @override
  Future<EmbodiedDeviceResult> health() async =>
      _result(EmbodiedDeviceCapability.health);

  @override
  Future<EmbodiedDeviceResult> sense(EmbodiedSenseRequest request) async =>
      _result(EmbodiedDeviceCapability.sense);

  @override
  EmbodiedDeadManArmOperation armDeadMan(EmbodiedMotionCapability capability) {
    deadManArmCalls += 1;
    callOrder.add('armDeadMan');
    final result = deadManArmSucceeds && _motionVerifier.recognizes(capability)
        ? EmbodiedDeadManArmResult(
            status: EmbodiedDeadManArmStatus.armed,
            receipt: _motionVerifier.recordHardwareDeadManArmed(
              capability: capability,
              monotonicArmedAtMicros: 1000,
              monotonicExpiresAtMicros: 1000000,
            ),
          )
        : const EmbodiedDeadManArmResult(
            status: EmbodiedDeadManArmStatus.failed,
          );
    final operation = _FakeDeadManArmOperation(
      owner: this,
      armedResult: result,
    );
    operation.start();
    return operation;
  }

  @override
  EmbodiedMotionOperation beginMotion(
    EmbodiedMotionCapability capability,
    EmbodiedDeadManReceipt deadManReceipt,
  ) {
    final motion = _motionVerifier.consume(
      capability,
      deadManReceipt,
      monotonicNowMicros: 2000,
    );
    callOrder.add('beginMotion');
    final operation = _FakeMotionOperation(owner: this, motion: motion);
    lastMotionOperation = operation;
    operation.start();
    return operation;
  }

  void releaseDelayedMotionDispatch() => lastMotionOperation?.dispatch();

  void releaseMotionResult() => lastMotionOperation?.completeResult();

  void releaseCapabilities() {
    final gate = _capabilitiesGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void releaseTelemetry() {
    final gate = _telemetryGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void releaseStopCancellation() => lastStopOperation?.releaseDrain();

  @override
  EmbodiedStopOperation beginStop() {
    stopCalls += 1;
    callOrder.add('beginStop');
    final operation = _FakeStopOperation(
      owner: this,
      completedResult: _result(
        stopResultCapability ?? EmbodiedDeviceCapability.stop,
        status: stopSucceeds
            ? EmbodiedResultStatus.ok
            : EmbodiedResultStatus.failed,
        facadeGeneration: stopResultGeneration,
      ),
    );
    lastStopOperation = operation;
    operation.start();
    return operation;
  }

  @override
  Future<void> retireAndDrain() async {
    retireCalls += 1;
  }

  EmbodiedDeviceResult _result(
    EmbodiedDeviceCapability capability, {
    EmbodiedResultStatus status = EmbodiedResultStatus.ok,
    int facadeGeneration = 1,
  }) => EmbodiedDeviceResult(
    capability: capability,
    status: status,
    unit: EmbodiedUnit.boolean,
    capturedAt: _clock(),
    freshness: EmbodiedFreshness.fresh,
    accountId: accountId,
    facadeGeneration: facadeGeneration,
    value: const EmbodiedBooleanValue(true),
  );
}

final class _FakeMotionOperation implements EmbodiedMotionOperation {
  _FakeMotionOperation({required this.owner, required this.motion});

  final _FakeFacade owner;
  final VerifiedEmbodiedMotion motion;

  @override
  String get capabilityId => motion.id;

  final Completer<EmbodiedDeviceResult> _result =
      Completer<EmbodiedDeviceResult>();
  bool _cancelled = false;
  bool _dispatched = false;

  @override
  Future<EmbodiedDeviceResult> get result => _result.future;

  void start() {
    if (!owner.delayMotionDispatch) dispatch();
  }

  void dispatch() {
    if (_cancelled || _dispatched) return;
    _dispatched = true;
    owner.motionCalls += 1;
    if (!owner.holdMotion) completeResult();
  }

  void completeResult() {
    if (_result.isCompleted) return;
    _result.complete(
      owner._result(
        motion.capability,
        status: _cancelled
            ? EmbodiedResultStatus.failed
            : EmbodiedResultStatus.ok,
        facadeGeneration: owner.motionResultGeneration,
      ),
    );
  }

  @override
  Future<void> cancelAndDrain() {
    owner.motionCancellationCalls += 1;
    _cancelled = true;
    if (owner.motionCancellationHangs) return Completer<void>().future;
    completeResult();
    return Future<void>.value();
  }
}

final class _FakeDeadManArmOperation implements EmbodiedDeadManArmOperation {
  _FakeDeadManArmOperation({required this.owner, required this.armedResult});

  final _FakeFacade owner;
  final EmbodiedDeadManArmResult armedResult;
  final Completer<EmbodiedDeadManArmResult> _result =
      Completer<EmbodiedDeadManArmResult>();

  @override
  Future<EmbodiedDeadManArmResult> get result => _result.future;

  void start() {
    if (!owner.holdDeadManArm) _result.complete(armedResult);
  }

  @override
  Future<void> cancelAndDrain() {
    owner.deadManArmCancellationCalls += 1;
    if (!_result.isCompleted) {
      _result.complete(
        const EmbodiedDeadManArmResult(status: EmbodiedDeadManArmStatus.failed),
      );
    }
    return Future<void>.value();
  }
}

final class _FakeStopOperation implements EmbodiedStopOperation {
  _FakeStopOperation({required this.owner, required this.completedResult});

  final _FakeFacade owner;
  final EmbodiedDeviceResult completedResult;
  final Completer<EmbodiedDeviceResult> _result =
      Completer<EmbodiedDeviceResult>();
  Completer<void>? _cancellationDrain;

  @override
  Future<EmbodiedDeviceResult> get result => _result.future;

  void start() {
    if (!owner.holdStop) _result.complete(completedResult);
  }

  @override
  Future<void> cancelAndDrain() {
    owner.stopCancellationCalls += 1;
    if (owner.stopCancellationHangs) {
      return (_cancellationDrain ??= Completer<void>()).future;
    }
    if (!_result.isCompleted) _result.complete(completedResult);
    return Future<void>.value();
  }

  void releaseDrain() {
    if (!_result.isCompleted) _result.complete(completedResult);
    final drain = _cancellationDrain;
    if (drain != null && !drain.isCompleted) drain.complete();
  }
}

final class _FakeConfirmationGateway
    implements EmbodiedMotionConfirmationGateway {
  final List<EmbodiedMotionConfirmationRequest> requests =
      <EmbodiedMotionConfirmationRequest>[];
  EmbodiedConfirmationOutcome outcome = EmbodiedConfirmationOutcome.allowed;
  bool hold = false;
  String? fixedReceiptId;
  bool mismatchChallenge = false;
  String? mismatchGrantField;
  bool cancelHangs = false;
  int cancelCalls = 0;
  Completer<EmbodiedMotionConfirmationResult>? _pending;
  EmbodiedMotionConfirmationRequest? _pendingRequest;

  @override
  Future<EmbodiedMotionConfirmationResult> confirm(
    EmbodiedMotionConfirmationRequest request,
  ) {
    requests.add(request);
    if (hold) {
      final pending = Completer<EmbodiedMotionConfirmationResult>();
      _pending = pending;
      _pendingRequest = request;
      return pending.future;
    }
    return Future<EmbodiedMotionConfirmationResult>.value(_result(request));
  }

  EmbodiedMotionConfirmationResult _result(
    EmbodiedMotionConfirmationRequest request,
  ) => EmbodiedMotionConfirmationResult(
    outcome: outcome,
    grant: outcome == EmbodiedConfirmationOutcome.allowed
        ? EmbodiedMotionConfirmationGrant(
            receipt: MotionConfirmationReceipt(
              id: fixedReceiptId ?? 'confirmation-${requests.length}',
              accountId: request.invocation.accountId,
              facadeGeneration: request.invocation.facadeGeneration,
              motionFingerprint: request.motionFingerprint,
              issuedAt: request.issuedAt,
              expiresAt: request.expiresAt,
            ),
            challengeNonce:
                mismatchChallenge || mismatchGrantField == 'challengeNonce'
                ? '${request.challengeNonce}-wrong'
                : request.challengeNonce,
            accountId: _mismatchedString(
              'accountId',
              request.invocation.accountId,
            ),
            facadeGeneration: _mismatchedInt(
              'facadeGeneration',
              request.invocation.facadeGeneration,
            ),
            agentId: _mismatchedString('agentId', request.invocation.agentId),
            runtimeGeneration: _mismatchedInt(
              'runtimeGeneration',
              request.invocation.runtimeGeneration,
            ),
            callId: _mismatchedString('callId', request.invocation.callId),
            actionId: _mismatchedString('actionId', request.actionId),
            target: _mismatchedString('target', request.target),
            motionFingerprint: _mismatchedString(
              'motionFingerprint',
              request.motionFingerprint,
            ),
            issuedAt: _mismatchedDate('issuedAt', request.issuedAt),
            expiresAt: _mismatchedDate('expiresAt', request.expiresAt),
          )
        : null,
  );

  String _mismatchedString(String field, String value) =>
      mismatchGrantField == field ? '$value-wrong' : value;

  int _mismatchedInt(String field, int value) =>
      mismatchGrantField == field ? value + 1 : value;

  DateTime _mismatchedDate(String field, DateTime value) =>
      mismatchGrantField == field
      ? value.add(const Duration(seconds: 1))
      : value;

  @override
  Future<void> cancelAll() async {
    cancelCalls += 1;
    if (cancelHangs) return Completer<void>().future;
    final pending = _pending;
    _pending = null;
    _pendingRequest = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(
        const EmbodiedMotionConfirmationResult(
          outcome: EmbodiedConfirmationOutcome.cancelled,
        ),
      );
    }
  }

  void releasePendingAllowed() {
    final pending = _pending;
    final request = _pendingRequest;
    _pending = null;
    _pendingRequest = null;
    if (pending != null && request != null && !pending.isCompleted) {
      pending.complete(_result(request));
    }
  }
}

final class _FakeAuditSink implements EmbodiedMotionAuditSink {
  final List<EmbodiedMotionAuditEvent> events = <EmbodiedMotionAuditEvent>[];
  int? failOnCall;
  int? holdOnCall;
  Completer<bool>? heldAppend;
  var _calls = 0;

  @override
  Future<bool> append(
    EmbodiedMotionAuditEvent event, {
    required String transientTarget,
  }) async {
    _calls += 1;
    events.add(event);
    if (holdOnCall == _calls) {
      final held = Completer<bool>();
      heldAppend = held;
      return held.future;
    }
    return failOnCall != _calls;
  }

  void releaseHeld({bool result = true}) {
    final held = heldAppend;
    if (held != null && !held.isCompleted) held.complete(result);
  }
}

final class _ManualWatchdogScheduler {
  final List<_ManualWatchdogHandle> handles = <_ManualWatchdogHandle>[];
  bool throwOnSchedule = false;
  bool fireSynchronously = false;

  EmbodiedWatchdogHandle schedule(Duration delay, void Function() callback) {
    if (throwOnSchedule) throw StateError('watchdog unavailable');
    final handle = _ManualWatchdogHandle(delay: delay, callback: callback);
    handles.add(handle);
    if (fireSynchronously) handle.fire();
    return handle;
  }

  int get activeCount => handles.where((handle) => !handle.cancelled).length;

  void fireLatest() {
    final handle = handles.lastWhere((candidate) => !candidate.cancelled);
    handle.fire();
  }
}

final class _ManualWatchdogHandle implements EmbodiedWatchdogHandle {
  _ManualWatchdogHandle({required this.delay, required this.callback});

  final Duration delay;
  final void Function() callback;
  bool cancelled = false;

  void fire() {
    if (cancelled) return;
    cancelled = true;
    callback();
  }

  @override
  void cancel() => cancelled = true;
}
