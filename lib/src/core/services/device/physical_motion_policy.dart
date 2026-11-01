import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/services/device/embodied_device_facade.dart';

enum MotionAdmissionStatus { authorized, rejected, stopRequired }

enum PhysicalMotionSafetyState { idle, leased, stopRequired, retired }

enum MotionStopReason {
  leaseTimeout,
  disconnected,
  backgrounded,
  accountRetired,
  generationChanged,
  manual,
}

/// Immutable policy output. Its private constructor prevents callers from
/// claiming that unbounded values passed policy validation.
final class MotionPlan {
  const MotionPlan._({
    required this.capability,
    required this.distanceMeters,
    required this.angleDegrees,
    required this.speedMetersPerSecond,
    required this.duration,
  });

  final EmbodiedDeviceCapability capability;
  final double distanceMeters;
  final double angleDegrees;
  final double speedMetersPerSecond;
  final Duration duration;
}

/// Policy lease metadata; it is not accepted by any facade operation.
final class MotionLease {
  const MotionLease._({
    required this.id,
    required this.accountId,
    required this.facadeGeneration,
    required this.issuedAt,
    required this.expiresAt,
    required this.stopDeadline,
    required this.motion,
  });

  final String id;
  final String accountId;
  final int facadeGeneration;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final DateTime stopDeadline;
  final MotionPlan motion;
}

final class MotionBoundsResult {
  const MotionBoundsResult._({this.motion, this.reason});

  const MotionBoundsResult.accepted(MotionPlan motion) : this._(motion: motion);

  const MotionBoundsResult.rejected(String reason) : this._(reason: reason);

  final MotionPlan? motion;
  final String? reason;

  bool get accepted => motion != null;
}

final class MotionConfirmationReceipt {
  const MotionConfirmationReceipt({
    required this.id,
    required this.accountId,
    required this.facadeGeneration,
    required this.motionFingerprint,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String id;
  final String accountId;
  final int facadeGeneration;
  final String motionFingerprint;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

final class MotionAdmissionResult {
  const MotionAdmissionResult._({
    required this.status,
    required this.accountId,
    required this.facadeGeneration,
    required this.capturedAt,
    required this.freshness,
    this.lease,
    this.reason,
  });

  const MotionAdmissionResult.authorized({
    required String accountId,
    required int facadeGeneration,
    required DateTime capturedAt,
    required EmbodiedFreshness freshness,
    required MotionLease lease,
  }) : this._(
         status: MotionAdmissionStatus.authorized,
         accountId: accountId,
         facadeGeneration: facadeGeneration,
         capturedAt: capturedAt,
         freshness: freshness,
         lease: lease,
       );

  const MotionAdmissionResult.rejected({
    required String accountId,
    required int facadeGeneration,
    required DateTime capturedAt,
    required EmbodiedFreshness freshness,
    required String reason,
    MotionAdmissionStatus status = MotionAdmissionStatus.rejected,
  }) : this._(
         status: status,
         accountId: accountId,
         facadeGeneration: facadeGeneration,
         capturedAt: capturedAt,
         freshness: freshness,
         reason: reason,
       );

  final MotionAdmissionStatus status;
  final String accountId;
  final int facadeGeneration;
  final DateTime capturedAt;
  final EmbodiedFreshness freshness;
  final MotionLease? lease;
  final String? reason;
}

final class MotionStopRequirement {
  const MotionStopRequirement({
    required this.id,
    required this.reason,
    required this.accountId,
    required this.facadeGeneration,
    required this.triggeredAt,
    required this.stopBy,
  });

  final String id;
  final MotionStopReason reason;
  final String accountId;
  final int facadeGeneration;
  final DateTime triggeredAt;
  final DateTime stopBy;
}

/// Pure policy owner for bounded semantic movement and fail-safe stop state.
///
/// The one-second stop target is an admission contract for callers. It is not
/// a claim that a particular hardware transport meets that deadline.
final class PhysicalMotionPolicy {
  PhysicalMotionPolicy({
    required String accountId,
    required int facadeGeneration,
  }) : _accountId = accountId,
       _facadeGeneration = facadeGeneration {
    _requireIdentity(accountId, facadeGeneration);
  }

  static const double minDistanceMeters = -2;
  static const double maxDistanceMeters = 2;
  static const double minAngleDegrees = -180;
  static const double maxAngleDegrees = 180;
  static const double minSpeedMetersPerSecond = 0.05;
  static const double maxSpeedMetersPerSecond = 1.5;
  static const Duration minMotionDuration = Duration(milliseconds: 100);
  static const Duration maxMotionDuration = Duration(seconds: 10);
  static const Duration maxTelemetryAge = Duration(seconds: 2);
  static const Duration maxDeadManLease = Duration(seconds: 1);
  static const Duration maxStopTarget = Duration(seconds: 1);

  String _accountId;
  int _facadeGeneration;
  var _state = PhysicalMotionSafetyState.idle;
  var _retired = false;
  var _leaseSequence = 0;
  var _stopSequence = 0;
  final Set<String> _consumedReceiptIds = <String>{};
  MotionLease? _activeLease;
  MotionStopRequirement? _stopRequirement;
  String? _lastCompletedStopId;

  String get accountId => _accountId;

  int get facadeGeneration => _facadeGeneration;

  PhysicalMotionSafetyState get state => _state;

  MotionLease? get activeLease => _activeLease;

  MotionStopRequirement? get stopRequirement => _stopRequirement;

  MotionBoundsResult bound(EmbodiedMotionRequest request) {
    if (request.capability.permissionTier !=
            EmbodiedPermissionTier.consequentialMotion ||
        request.capability == EmbodiedDeviceCapability.stop) {
      return const MotionBoundsResult.rejected('unsupported_motion_capability');
    }
    if (!request.distanceMeters.isFinite ||
        !request.angleDegrees.isFinite ||
        !request.speedMetersPerSecond.isFinite) {
      return const MotionBoundsResult.rejected('motion_value_not_finite');
    }
    final durationMs = request.duration.inMilliseconds;
    final boundedDurationMs = durationMs
        .clamp(
          minMotionDuration.inMilliseconds,
          maxMotionDuration.inMilliseconds,
        )
        .toInt();
    return MotionBoundsResult.accepted(
      MotionPlan._(
        capability: request.capability,
        distanceMeters: request.distanceMeters
            .clamp(minDistanceMeters, maxDistanceMeters)
            .toDouble(),
        angleDegrees: request.angleDegrees
            .clamp(minAngleDegrees, maxAngleDegrees)
            .toDouble(),
        speedMetersPerSecond: request.speedMetersPerSecond
            .clamp(minSpeedMetersPerSecond, maxSpeedMetersPerSecond)
            .toDouble(),
        duration: Duration(milliseconds: boundedDurationMs),
      ),
    );
  }

  String fingerprint(MotionPlan motion) => sha256
      .convert(
        utf8.encode(
          '${motion.capability.name}|${motion.distanceMeters}|'
          '${motion.angleDegrees}|${motion.speedMetersPerSecond}|'
          '${motion.duration.inMilliseconds}',
        ),
      )
      .toString();

  MotionAdmissionResult admit({
    required EmbodiedMotionRequest request,
    required EmbodiedCapabilitySnapshot capability,
    required EmbodiedDeviceTelemetry telemetry,
    required MotionConfirmationReceipt confirmation,
    required DateTime now,
  }) {
    final capturedAt = telemetry.capturedAt;
    final freshness = telemetry.freshness;
    MotionAdmissionResult reject(
      String reason, {
      MotionAdmissionStatus status = MotionAdmissionStatus.rejected,
    }) => MotionAdmissionResult.rejected(
      accountId: _accountId,
      facadeGeneration: _facadeGeneration,
      capturedAt: capturedAt,
      freshness: freshness,
      reason: reason,
      status: status,
    );

    if (_retired) return reject('account_retired');
    if (_state == PhysicalMotionSafetyState.stopRequired) {
      return reject(
        'stop_required',
        status: MotionAdmissionStatus.stopRequired,
      );
    }
    final bounded = bound(request);
    final motion = bounded.motion;
    if (motion == null) return reject(bounded.reason!);
    if (capability.capability != request.capability || !capability.supported) {
      return reject('capability_unsupported');
    }
    if (!_matchesCurrent(capability.accountId, capability.facadeGeneration) ||
        !_matchesCurrent(telemetry.accountId, telemetry.facadeGeneration)) {
      return reject('account_or_generation_mismatch');
    }
    if (!_isFresh(
          capturedAt: capability.capturedAt,
          freshness: capability.freshness,
          now: now,
        ) ||
        !_isFresh(capturedAt: capturedAt, freshness: freshness, now: now)) {
      return reject('telemetry_stale');
    }
    if (!telemetry.connected) return reject('device_disconnected');
    if (telemetry.backgrounded) return reject('app_backgrounded');
    if (confirmation.id.isEmpty || confirmation.id.length > 128) {
      return reject('confirmation_invalid');
    }
    if (_consumedReceiptIds.contains(confirmation.id)) {
      return reject('confirmation_replayed');
    }
    if (!_matchesCurrent(
          confirmation.accountId,
          confirmation.facadeGeneration,
        ) ||
        confirmation.motionFingerprint != fingerprint(motion)) {
      return reject('confirmation_mismatch');
    }
    if (confirmation.issuedAt.isAfter(now) ||
        !confirmation.expiresAt.isAfter(now)) {
      return reject('confirmation_expired');
    }
    if (_activeLease != null) return reject('motion_already_active');

    _consumedReceiptIds.add(confirmation.id);
    _leaseSequence += 1;
    final leaseDuration = Duration(
      milliseconds: math.min(
        motion.duration.inMilliseconds,
        maxDeadManLease.inMilliseconds,
      ),
    );
    final expiresAt = now.add(leaseDuration);
    final lease = MotionLease._(
      id: 'motion-lease-$_facadeGeneration-$_leaseSequence',
      accountId: _accountId,
      facadeGeneration: _facadeGeneration,
      issuedAt: now,
      expiresAt: expiresAt,
      stopDeadline: expiresAt,
      motion: motion,
    );
    _activeLease = lease;
    _state = PhysicalMotionSafetyState.leased;
    return MotionAdmissionResult.authorized(
      accountId: _accountId,
      facadeGeneration: _facadeGeneration,
      capturedAt: capturedAt,
      freshness: freshness,
      lease: lease,
    );
  }

  MotionStopRequirement? tick(DateTime now) {
    final lease = _activeLease;
    if (lease == null || now.isBefore(lease.expiresAt)) {
      return _stopRequirement;
    }
    return requireStop(reason: MotionStopReason.leaseTimeout, now: now);
  }

  MotionStopRequirement onDisconnected(DateTime now) =>
      requireStop(reason: MotionStopReason.disconnected, now: now);

  MotionStopRequirement onBackgrounded(DateTime now) =>
      requireStop(reason: MotionStopReason.backgrounded, now: now);

  MotionStopRequirement retireAccount(DateTime now) {
    _retired = true;
    return requireStop(reason: MotionStopReason.accountRetired, now: now);
  }

  MotionStopRequirement switchGeneration({
    required String accountId,
    required int facadeGeneration,
    required DateTime now,
  }) {
    _requireIdentity(accountId, facadeGeneration);
    final requirement = requireStop(
      reason: MotionStopReason.generationChanged,
      now: now,
    );
    _accountId = accountId;
    _facadeGeneration = facadeGeneration;
    _consumedReceiptIds.clear();
    _retired = false;
    return requirement;
  }

  MotionStopRequirement requireStop({
    required MotionStopReason reason,
    required DateTime now,
  }) {
    final existing = _stopRequirement;
    if (existing != null) return existing;
    _stopSequence += 1;
    final leaseDeadline = _activeLease?.expiresAt;
    final target = now.add(maxStopTarget);
    final stopBy = leaseDeadline != null && leaseDeadline.isBefore(target)
        ? leaseDeadline
        : target;
    final requirement = MotionStopRequirement(
      id: 'motion-stop-$_facadeGeneration-$_stopSequence',
      reason: reason,
      accountId: _accountId,
      facadeGeneration: _facadeGeneration,
      triggeredAt: now,
      stopBy: stopBy.isBefore(now) ? now : stopBy,
    );
    _stopRequirement = requirement;
    _state = PhysicalMotionSafetyState.stopRequired;
    return requirement;
  }

  bool markStopped({
    required String stopRequirementId,
    required String accountId,
    required int facadeGeneration,
  }) {
    if (_lastCompletedStopId == stopRequirementId) return true;
    final requirement = _stopRequirement;
    if (requirement == null ||
        requirement.id != stopRequirementId ||
        requirement.accountId != accountId ||
        requirement.facadeGeneration != facadeGeneration) {
      return false;
    }
    _lastCompletedStopId = requirement.id;
    _stopRequirement = null;
    _activeLease = null;
    _state = _retired
        ? PhysicalMotionSafetyState.retired
        : PhysicalMotionSafetyState.idle;
    return true;
  }

  bool _matchesCurrent(String accountId, int facadeGeneration) =>
      accountId == _accountId && facadeGeneration == _facadeGeneration;

  static bool _isFresh({
    required DateTime capturedAt,
    required EmbodiedFreshness freshness,
    required DateTime now,
  }) {
    if (freshness != EmbodiedFreshness.fresh || capturedAt.isAfter(now)) {
      return false;
    }
    return now.difference(capturedAt) <= maxTelemetryAge;
  }

  static void _requireIdentity(String accountId, int facadeGeneration) {
    if (accountId.trim().isEmpty || accountId.length > 256) {
      throw ArgumentError.value(accountId, 'accountId');
    }
    if (facadeGeneration < 1) {
      throw ArgumentError.value(facadeGeneration, 'facadeGeneration');
    }
  }
}
