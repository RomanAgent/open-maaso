import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/device/embodied_device_facade.dart';
import 'package:maaso/src/core/services/device/physical_motion_policy.dart';

void main() {
  final now = DateTime.utc(2026, 8, 30, 12);

  test('motion values are finite and clamped to policy bounds', () {
    final policy = _policy();
    final bounded = policy.bound(
      const EmbodiedMotionRequest(
        capability: EmbodiedDeviceCapability.move,
        distanceMeters: 99,
        angleDegrees: -999,
        speedMetersPerSecond: 99,
        duration: Duration(minutes: 1),
      ),
    );

    expect(bounded.accepted, isTrue);
    expect(
      bounded.motion!.distanceMeters,
      PhysicalMotionPolicy.maxDistanceMeters,
    );
    expect(bounded.motion!.angleDegrees, PhysicalMotionPolicy.minAngleDegrees);
    expect(
      bounded.motion!.speedMetersPerSecond,
      PhysicalMotionPolicy.maxSpeedMetersPerSecond,
    );
    expect(bounded.motion!.duration, PhysicalMotionPolicy.maxMotionDuration);

    final lowerBounded = policy.bound(
      const EmbodiedMotionRequest(
        capability: EmbodiedDeviceCapability.move,
        distanceMeters: -99,
        angleDegrees: 999,
        speedMetersPerSecond: -99,
        duration: Duration.zero,
      ),
    );
    expect(
      lowerBounded.motion!.distanceMeters,
      PhysicalMotionPolicy.minDistanceMeters,
    );
    expect(
      lowerBounded.motion!.angleDegrees,
      PhysicalMotionPolicy.maxAngleDegrees,
    );
    expect(
      lowerBounded.motion!.speedMetersPerSecond,
      PhysicalMotionPolicy.minSpeedMetersPerSecond,
    );
    expect(
      lowerBounded.motion!.duration,
      PhysicalMotionPolicy.minMotionDuration,
    );

    for (final value in <double>[
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      final rejected = policy.bound(
        EmbodiedMotionRequest(
          capability: EmbodiedDeviceCapability.move,
          distanceMeters: value,
        ),
      );
      expect(rejected.accepted, isFalse, reason: '$value');
      expect(rejected.reason, 'motion_value_not_finite');
    }
  });

  test('stale telemetry cannot authorize motion', () {
    final policy = _policy();
    final request = _request();
    final motion = policy.bound(request).motion!;
    final result = policy.admit(
      request: request,
      capability: _capability(now: now),
      telemetry: _telemetry(
        now: now.subtract(const Duration(seconds: 3)),
        freshness: EmbodiedFreshness.stale,
      ),
      confirmation: _receipt(policy, motion, now: now),
      now: now,
    );

    expect(result.status, MotionAdmissionStatus.rejected);
    expect(result.reason, 'telemetry_stale');
    expect(policy.activeLease, isNull);
  });

  test('confirmation must match exactly and is consumed once', () {
    final policy = _policy();
    final request = _request();
    final motion = policy.bound(request).motion!;
    final mismatched = policy.admit(
      request: request,
      capability: _capability(now: now),
      telemetry: _telemetry(now: now),
      confirmation: _receipt(policy, motion, now: now, accountId: 'account-b'),
      now: now,
    );
    expect(mismatched.reason, 'confirmation_mismatch');

    final receipt = _receipt(policy, motion, now: now, id: 'confirm-once');
    final admitted = policy.admit(
      request: request,
      capability: _capability(now: now),
      telemetry: _telemetry(now: now),
      confirmation: receipt,
      now: now,
    );
    expect(admitted.status, MotionAdmissionStatus.authorized);
    expect(admitted.lease, isNotNull);

    final replay = policy.admit(
      request: request,
      capability: _capability(now: now),
      telemetry: _telemetry(now: now),
      confirmation: receipt,
      now: now,
    );
    expect(replay.status, MotionAdmissionStatus.rejected);
    expect(replay.reason, 'confirmation_replayed');
  });

  test('dead-man lease expires within one second and stop is idempotent', () {
    final policy = _policy();
    final request = _request(duration: const Duration(seconds: 8));
    final motion = policy.bound(request).motion!;
    final admitted = policy.admit(
      request: request,
      capability: _capability(now: now),
      telemetry: _telemetry(now: now),
      confirmation: _receipt(policy, motion, now: now),
      now: now,
    );
    final lease = admitted.lease!;

    expect(
      lease.expiresAt.difference(now),
      PhysicalMotionPolicy.maxDeadManLease,
    );
    expect(lease.stopDeadline, lease.expiresAt);
    expect(policy.tick(now.add(const Duration(milliseconds: 999))), isNull);

    final expiredAt = now.add(const Duration(seconds: 1));
    final stop = policy.tick(expiredAt)!;
    expect(stop.reason, MotionStopReason.leaseTimeout);
    expect(
      stop.stopBy.difference(stop.triggeredAt),
      lessThanOrEqualTo(const Duration(seconds: 1)),
    );
    expect(policy.tick(expiredAt.add(const Duration(seconds: 1))), same(stop));
    expect(
      policy.requireStop(reason: MotionStopReason.manual, now: expiredAt),
      same(stop),
    );
    expect(
      policy.markStopped(
        stopRequirementId: stop.id,
        accountId: stop.accountId,
        facadeGeneration: stop.facadeGeneration,
      ),
      isTrue,
    );
    expect(
      policy.markStopped(
        stopRequirementId: stop.id,
        accountId: stop.accountId,
        facadeGeneration: stop.facadeGeneration,
      ),
      isTrue,
    );
    expect(policy.state, PhysicalMotionSafetyState.idle);
  });

  test('disconnect background and retirement enter stop-required state', () {
    final disconnected = _policy();
    expect(
      disconnected.onDisconnected(now).reason,
      MotionStopReason.disconnected,
    );
    expect(disconnected.state, PhysicalMotionSafetyState.stopRequired);
    expect(
      disconnected.onBackgrounded(now),
      same(disconnected.stopRequirement),
    );

    final backgrounded = _policy();
    expect(
      backgrounded.onBackgrounded(now).reason,
      MotionStopReason.backgrounded,
    );

    final retired = _policy();
    final stop = retired.retireAccount(now);
    expect(stop.reason, MotionStopReason.accountRetired);
    expect(
      retired.markStopped(
        stopRequirementId: stop.id,
        accountId: stop.accountId,
        facadeGeneration: stop.facadeGeneration,
      ),
      isTrue,
    );
    expect(retired.state, PhysicalMotionSafetyState.retired);
  });

  test('generation switch fences old telemetry and confirmation scope', () {
    final policy = _policy();
    final stop = policy.switchGeneration(
      accountId: 'account-a',
      facadeGeneration: 2,
      now: now,
    );
    expect(stop.reason, MotionStopReason.generationChanged);
    expect(stop.accountId, 'account-a');
    expect(stop.facadeGeneration, 1);
    expect(policy.facadeGeneration, 2);
    expect(
      policy.markStopped(
        stopRequirementId: stop.id,
        accountId: stop.accountId,
        facadeGeneration: stop.facadeGeneration,
      ),
      isTrue,
    );

    final request = _request();
    final motion = policy.bound(request).motion!;
    final rejected = policy.admit(
      request: request,
      capability: _capability(now: now, generation: 1),
      telemetry: _telemetry(now: now, generation: 1),
      confirmation: _receipt(policy, motion, now: now, generation: 2),
      now: now,
    );
    expect(rejected.reason, 'account_or_generation_mismatch');
  });

  test('unsupported capability cannot receive a motion lease', () {
    final policy = _policy();
    final request = _request(capability: EmbodiedDeviceCapability.move);
    final motion = policy.bound(request).motion!;
    final result = policy.admit(
      request: request,
      capability: _capability(
        now: now,
        capability: EmbodiedDeviceCapability.move,
        supported: false,
      ),
      telemetry: _telemetry(now: now),
      confirmation: _receipt(policy, motion, now: now),
      now: now,
    );

    expect(result.status, MotionAdmissionStatus.rejected);
    expect(result.reason, 'capability_unsupported');
    expect(policy.activeLease, isNull);
  });
}

PhysicalMotionPolicy _policy() =>
    PhysicalMotionPolicy(accountId: 'account-a', facadeGeneration: 1);

EmbodiedMotionRequest _request({
  EmbodiedDeviceCapability capability = EmbodiedDeviceCapability.move,
  Duration duration = const Duration(milliseconds: 500),
}) => EmbodiedMotionRequest(
  capability: capability,
  distanceMeters: 0.5,
  angleDegrees: 15,
  speedMetersPerSecond: 0.4,
  duration: duration,
);

EmbodiedCapabilitySnapshot _capability({
  required DateTime now,
  EmbodiedDeviceCapability capability = EmbodiedDeviceCapability.move,
  bool supported = true,
  int generation = 1,
}) => EmbodiedCapabilitySnapshot(
  capability: capability,
  supported: supported,
  unit: EmbodiedUnit.meters,
  capturedAt: now,
  freshness: EmbodiedFreshness.fresh,
  accountId: 'account-a',
  facadeGeneration: generation,
);

EmbodiedDeviceTelemetry _telemetry({
  required DateTime now,
  EmbodiedFreshness freshness = EmbodiedFreshness.fresh,
  int generation = 1,
}) => EmbodiedDeviceTelemetry(
  unit: EmbodiedUnit.meters,
  capturedAt: now,
  freshness: freshness,
  accountId: 'account-a',
  facadeGeneration: generation,
  connected: true,
  backgrounded: false,
  value: const EmbodiedNumericValue(0.8),
);

MotionConfirmationReceipt _receipt(
  PhysicalMotionPolicy policy,
  MotionPlan motion, {
  required DateTime now,
  String id = 'confirm-1',
  String accountId = 'account-a',
  int generation = 1,
}) => MotionConfirmationReceipt(
  id: id,
  accountId: accountId,
  facadeGeneration: generation,
  motionFingerprint: policy.fingerprint(motion),
  issuedAt: now.subtract(const Duration(seconds: 1)),
  expiresAt: now.add(const Duration(minutes: 1)),
);
