import 'dart:async';
import 'dart:math';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/device/embodied_device_facade.dart';
import 'package:maaso/src/core/services/device/physical_motion_policy.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';

typedef EmbodiedSupervisorClock = DateTime Function();
typedef EmbodiedRolloutReader = FeatureRolloutMode Function();
typedef EmbodiedAuthorityReader =
    bool Function(EmbodiedMotionInvocation invocation);
typedef EmbodiedWatchdogScheduler =
    EmbodiedWatchdogHandle Function(Duration delay, void Function() callback);
typedef EmbodiedActionAuditLogResolver = ActionAuditLog Function();

enum EmbodiedConfirmationOutcome { allowed, rejected, cancelled, unavailable }

enum EmbodiedMotionAuditStage { asked, decided, executed, result }

enum EmbodiedSupervisorOutcome {
  disabled,
  shadowEligible,
  shadowRejected,
  confirmationRejected,
  denied,
  executed,
  failed,
  unavailable,
}

enum _EmbodiedSupervisorLifecycle { active, retiring, retired, failedRetire }

enum _ConfirmationGrantDisposition { accepted, mismatch, replayed }

abstract interface class EmbodiedWatchdogHandle {
  void cancel();
}

/// Bounded authority identity supplied by the runtime/skill boundary.
final class EmbodiedMotionInvocation {
  EmbodiedMotionInvocation({
    required String accountId,
    required this.facadeGeneration,
    required String agentId,
    required this.runtimeGeneration,
    required String callId,
  }) : accountId = _boundedIdentifier(accountId, 'accountId', 256),
       agentId = _boundedIdentifier(agentId, 'agentId', 256),
       callId = _boundedIdentifier(callId, 'callId', 256) {
    if (facadeGeneration < 1) {
      throw ArgumentError.value(facadeGeneration, 'facadeGeneration');
    }
    if (runtimeGeneration < 0) {
      throw ArgumentError.value(runtimeGeneration, 'runtimeGeneration');
    }
  }

  final String accountId;
  final int facadeGeneration;
  final String agentId;
  final int runtimeGeneration;
  final String callId;
}

/// Exact, content-safe request sent to the host confirmation bridge.
final class EmbodiedMotionConfirmationRequest {
  const EmbodiedMotionConfirmationRequest({
    required this.invocation,
    required this.actionId,
    required this.target,
    required this.motion,
    required this.motionFingerprint,
    required this.challengeNonce,
    required this.issuedAt,
    required this.expiresAt,
  });

  final EmbodiedMotionInvocation invocation;
  final String actionId;
  final String target;
  final MotionPlan motion;
  final String motionFingerprint;
  final String challengeNonce;
  final DateTime issuedAt;
  final DateTime expiresAt;

  Map<String, Object> get boundedArguments => <String, Object>{
    'capability': motion.capability.name,
    'distanceMeters': motion.distanceMeters,
    'angleDegrees': motion.angleDegrees,
    'speedMetersPerSecond': motion.speedMetersPerSecond,
    'durationMilliseconds': motion.duration.inMilliseconds,
    'motionFingerprint': motionFingerprint,
  };
}

final class EmbodiedMotionConfirmationGrant {
  const EmbodiedMotionConfirmationGrant({
    required this.receipt,
    required this.challengeNonce,
    required this.accountId,
    required this.facadeGeneration,
    required this.agentId,
    required this.runtimeGeneration,
    required this.callId,
    required this.actionId,
    required this.target,
    required this.motionFingerprint,
    required this.issuedAt,
    required this.expiresAt,
  });

  final MotionConfirmationReceipt receipt;
  final String challengeNonce;
  final String accountId;
  final int facadeGeneration;
  final String agentId;
  final int runtimeGeneration;
  final String callId;
  final String actionId;
  final String target;
  final String motionFingerprint;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

final class EmbodiedMotionConfirmationResult {
  const EmbodiedMotionConfirmationResult({required this.outcome, this.grant});

  final EmbodiedConfirmationOutcome outcome;
  final EmbodiedMotionConfirmationGrant? grant;

  bool get isAllowed =>
      outcome == EmbodiedConfirmationOutcome.allowed && grant != null;
}

/// Bridge implemented later with ActionApprovalService + ActionApprovalHost.
abstract interface class EmbodiedMotionConfirmationGateway {
  Future<EmbodiedMotionConfirmationResult> confirm(
    EmbodiedMotionConfirmationRequest request,
  );

  /// Must settle every pending [confirm] before completing.
  Future<void> cancelAll();
}

/// Production-safe placeholder for products without a host-owned motion
/// confirmation coordinator.
///
/// This keeps the semantic device facade mountable for read-only status and
/// health while ensuring that no consequential motion can be admitted merely
/// because an internal rollout ceiling is raised. A future motion-capable
/// product must replace this object with a private Host confirmation bridge;
/// it must never expose its issuer through `appServices` or a model skill.
final class UnavailableEmbodiedMotionConfirmationGateway
    implements EmbodiedMotionConfirmationGateway {
  const UnavailableEmbodiedMotionConfirmationGateway();

  @override
  Future<EmbodiedMotionConfirmationResult> confirm(
    EmbodiedMotionConfirmationRequest request,
  ) => Future<EmbodiedMotionConfirmationResult>.value(
    const EmbodiedMotionConfirmationResult(
      outcome: EmbodiedConfirmationOutcome.unavailable,
    ),
  );

  @override
  Future<void> cancelAll() => Future<void>.value();
}

/// Content-safe audit event. It contains no PCM, image bytes, transport frame,
/// arbitrary diagnostic, or unbounded user-authored text.
final class EmbodiedMotionAuditEvent {
  const EmbodiedMotionAuditEvent({
    required this.stage,
    required this.accountId,
    required this.facadeGeneration,
    required this.agentId,
    required this.runtimeGeneration,
    required this.callId,
    required this.actionId,
    required this.motionFingerprint,
    required this.outcomeCode,
    required this.occurredAt,
  });

  final EmbodiedMotionAuditStage stage;
  final String accountId;
  final int facadeGeneration;
  final String agentId;
  final int runtimeGeneration;
  final String callId;
  final String actionId;
  final String motionFingerprint;
  final String outcomeCode;
  final DateTime occurredAt;
}

abstract interface class EmbodiedMotionAuditSink {
  /// Returns false when the event could not be recorded. Callers fail closed.
  Future<bool> append(
    EmbodiedMotionAuditEvent event, {
    required String transientTarget,
  });
}

/// Bounded keyed-digest adapter over the shared action audit log.
///
/// [transientTarget] is passed directly into [ActionAuditLog.append], which
/// retains only a process-private keyed digest. It is never added to the event.
final class ActionAuditLogEmbodiedMotionAuditSink
    implements EmbodiedMotionAuditSink {
  ActionAuditLogEmbodiedMotionAuditSink(ActionAuditLog log)
    : _log = log,
      _resolver = null;

  ActionAuditLogEmbodiedMotionAuditSink.lazy(
    EmbodiedActionAuditLogResolver resolver,
  ) : _log = null,
      _resolver = resolver;

  ActionAuditLog? _log;
  final EmbodiedActionAuditLogResolver? _resolver;

  @override
  Future<bool> append(
    EmbodiedMotionAuditEvent event, {
    required String transientTarget,
  }) async {
    try {
      final log = _log ??= _resolver!();
      log.append(
        stage: ActionAuditStage.values.byName(event.stage.name),
        accountScope: event.accountId,
        agentId: event.agentId,
        runtimeGeneration: event.runtimeGeneration,
        callId: event.callId,
        actionId: event.actionId,
        arguments: <String, Object>{
          'facadeGeneration': event.facadeGeneration,
          'motionFingerprint': event.motionFingerprint,
        },
        target: transientTarget,
        risk: ActionRisk.physicalAction,
        consequencePolicy: ActionConsequencePolicy.destructive,
        outcome: _actionAuditOutcome(event.outcomeCode),
        code: event.outcomeCode,
        occurredAt: event.occurredAt,
      );
      return true;
    } on Object {
      return false;
    }
  }

  static ActionAuditOutcome _actionAuditOutcome(String code) {
    if (code == 'confirmation_required') {
      return ActionAuditOutcome.confirmationRequired;
    }
    if (code == 'allowed') return ActionAuditOutcome.allowed;
    if (code == 'rejected') return ActionAuditOutcome.rejected;
    if (code == 'cancelled') return ActionAuditOutcome.cancelled;
    if (code == 'started') return ActionAuditOutcome.started;
    if (code == 'succeeded' || code == 'stop_succeeded') {
      return ActionAuditOutcome.succeeded;
    }
    if (code.contains('unavailable') || code.contains('stale')) {
      return ActionAuditOutcome.unavailable;
    }
    if (code.contains('denied') || code.contains('mismatch')) {
      return ActionAuditOutcome.denied;
    }
    return ActionAuditOutcome.failed;
  }
}

final class EmbodiedSupervisorResult {
  const EmbodiedSupervisorResult({
    required this.outcome,
    required this.code,
    this.deviceResult,
  });

  final EmbodiedSupervisorOutcome outcome;
  final String code;
  final EmbodiedDeviceResult? deviceResult;
}

/// Account-scoped safety owner around one semantic embodied-device facade.
///
/// `off` and `shadow` never call a consequential facade method. `enforce`
/// requires fresh telemetry, exact one-shot confirmation, bounded audit, a
/// single motion lease, and a supported stop capability before device motion.
final class EmbodiedDeviceSupervisor extends AppService {
  EmbodiedDeviceSupervisor({
    required EmbodiedDeviceFacade facade,
    required PhysicalMotionPolicy policy,
    required EmbodiedRolloutReader rolloutMode,
    required EmbodiedAuthorityReader authorityIsCurrent,
    required EmbodiedMotionConfirmationGateway confirmation,
    required EmbodiedMotionAuditSink audit,
    required EmbodiedMotionCapabilityIssuer motionCapabilityIssuer,
    required String deviceTarget,
    EmbodiedSupervisorClock? clock,
    EmbodiedWatchdogScheduler? scheduleWatchdog,
    this.confirmationTtl = const Duration(seconds: 30),
    this.auditTimeout = const Duration(milliseconds: 500),
    this.deviceCallTimeout = const Duration(seconds: 2),
    this.stopCallTimeout = const Duration(milliseconds: 250),
    this.retireTimeout = const Duration(seconds: 4),
    this.maximumStopAttempts = 3,
  }) : _facade = facade,
       _policy = policy,
       _rolloutMode = rolloutMode,
       _authorityIsCurrent = authorityIsCurrent,
       _confirmation = confirmation,
       _audit = audit,
       _motionCapabilityIssuer = motionCapabilityIssuer,
       _deviceTarget = _boundedIdentifier(deviceTarget, 'deviceTarget', 512),
       _clock = clock ?? DateTime.now,
       _scheduleWatchdog = scheduleWatchdog ?? _scheduleTimerWatchdog,
       _nonceRandom = Random.secure() {
    _motionCapabilityIssuer.claim(this);
    if (facade.accountId != policy.accountId ||
        facade.facadeGeneration != policy.facadeGeneration) {
      throw ArgumentError('facade and policy identity must match');
    }
    if (confirmationTtl <= Duration.zero ||
        confirmationTtl > const Duration(minutes: 2)) {
      throw ArgumentError.value(confirmationTtl, 'confirmationTtl');
    }
    if (auditTimeout <= Duration.zero ||
        deviceCallTimeout <= Duration.zero ||
        stopCallTimeout <= Duration.zero ||
        retireTimeout <= Duration.zero ||
        maximumStopAttempts < 1 ||
        maximumStopAttempts > 5) {
      throw ArgumentError('invalid supervisor timeout or retry configuration');
    }
    final stopBudgetMicroseconds =
        stopCallTimeout.inMicroseconds * maximumStopAttempts +
        const Duration(milliseconds: 25).inMicroseconds *
            (maximumStopAttempts - 1);
    if (stopBudgetMicroseconds >
        PhysicalMotionPolicy.maxStopTarget.inMicroseconds) {
      throw ArgumentError('stop retry budget exceeds the stop target');
    }
  }

  final EmbodiedDeviceFacade _facade;
  final PhysicalMotionPolicy _policy;
  final EmbodiedRolloutReader _rolloutMode;
  final EmbodiedAuthorityReader _authorityIsCurrent;
  final EmbodiedMotionConfirmationGateway _confirmation;
  final EmbodiedMotionAuditSink _audit;
  final EmbodiedMotionCapabilityIssuer _motionCapabilityIssuer;
  final String _deviceTarget;
  final EmbodiedSupervisorClock _clock;
  final EmbodiedWatchdogScheduler _scheduleWatchdog;
  final Random _nonceRandom;
  final Duration confirmationTtl;
  final Duration auditTimeout;
  final Duration deviceCallTimeout;
  final Duration stopCallTimeout;
  final Duration retireTimeout;
  final int maximumStopAttempts;

  final Set<Future<void>> _operations = <Future<void>>{};
  _EmbodiedSupervisorLifecycle _lifecycle = _EmbodiedSupervisorLifecycle.active;
  bool _confirmationInFlight = false;
  bool _auditCompromised = false;
  EmbodiedWatchdogHandle? _watchdog;
  EmbodiedWatchdogHandle? _stopRetryWatchdog;
  EmbodiedDeadManArmOperation? _activeArmOperation;
  Future<void>? _armDrain;
  EmbodiedMotionOperation? _activeMotionOperation;
  Future<void>? _motionDrain;
  final Set<_TrackedStopOperation> _stopOperations = <_TrackedStopOperation>{};
  Future<bool>? _stopInFlight;
  Future<void>? _retireFuture;
  final Map<String, DateTime> _consumedConfirmations = <String, DateTime>{};
  int _attemptEpoch = 0;
  int _challengeSequence = 0;
  int _watchdogGeneration = 0;
  int _stopRetryGeneration = 0;
  EmbodiedMotionInvocation? _lastAuthorizedInvocation;

  PhysicalMotionSafetyState get safetyState => _policy.state;
  bool get auditCompromised => _auditCompromised;

  Future<EmbodiedSupervisorResult> executeMotion({
    required EmbodiedMotionInvocation invocation,
    required EmbodiedMotionRequest request,
  }) {
    final operation = _executeMotion(invocation: invocation, request: request);
    _track(operation);
    return operation;
  }

  Future<EmbodiedSupervisorResult> _executeMotion({
    required EmbodiedMotionInvocation invocation,
    required EmbodiedMotionRequest request,
  }) async {
    if (!_active || _auditCompromised || !_matchesInvocation(invocation)) {
      return const EmbodiedSupervisorResult(
        outcome: EmbodiedSupervisorOutcome.unavailable,
        code: 'supervisor_unavailable',
      );
    }
    final mode = _safeRolloutMode();
    if (mode == FeatureRolloutMode.off) {
      return const EmbodiedSupervisorResult(
        outcome: EmbodiedSupervisorOutcome.disabled,
        code: 'rollout_off',
      );
    }
    if (!_stillCurrent(invocation)) {
      return const EmbodiedSupervisorResult(
        outcome: EmbodiedSupervisorOutcome.unavailable,
        code: 'authority_stale',
      );
    }
    _lastAuthorizedInvocation = invocation;
    final attemptEpoch = _attemptEpoch;

    final bounded = _policy.bound(request);
    final motion = bounded.motion;
    if (motion == null) {
      return EmbodiedSupervisorResult(
        outcome: mode == FeatureRolloutMode.shadow
            ? EmbodiedSupervisorOutcome.shadowRejected
            : EmbodiedSupervisorOutcome.denied,
        code: bounded.reason ?? 'motion_invalid',
      );
    }

    if (mode == FeatureRolloutMode.shadow) {
      final reason = await _shadowRejectionReason(
        invocation,
        request.capability,
        expectedAttemptEpoch: attemptEpoch,
        expectedMode: mode,
      );
      return EmbodiedSupervisorResult(
        outcome: reason == null
            ? EmbodiedSupervisorOutcome.shadowEligible
            : EmbodiedSupervisorOutcome.shadowRejected,
        code: reason ?? 'shadow_eligible',
      );
    }

    if (_confirmationInFlight || _policy.activeLease != null) {
      return const EmbodiedSupervisorResult(
        outcome: EmbodiedSupervisorOutcome.denied,
        code: 'motion_already_active',
      );
    }
    _confirmationInFlight = true;
    try {
      final preflightReason = await _enforcePreflight(
        invocation,
        request.capability,
        expectedAttemptEpoch: attemptEpoch,
        expectedMode: mode,
      );
      if (preflightReason != null) {
        return EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.denied,
          code: preflightReason,
        );
      }
      if (!_stillCurrent(invocation)) {
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'authority_stale',
        );
      }

      final now = _clock().toUtc();
      final fingerprint = _policy.fingerprint(motion);
      final actionId = 'device.motion.${request.capability.name}';
      final challengeNonce = _newChallengeNonce(now);
      final confirmationRequest = EmbodiedMotionConfirmationRequest(
        invocation: invocation,
        actionId: actionId,
        target: _deviceTarget,
        motion: motion,
        motionFingerprint: fingerprint,
        challengeNonce: challengeNonce,
        issuedAt: now,
        expiresAt: now.add(confirmationTtl),
      );
      if (!await _appendAudit(
        invocation: invocation,
        stage: EmbodiedMotionAuditStage.asked,
        actionId: actionId,
        fingerprint: fingerprint,
        code: 'confirmation_required',
      )) {
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'audit_unavailable',
        );
      }

      final confirmation = await _confirm(confirmationRequest);
      final decisionCode = confirmation.outcome.name;
      if (!await _appendAudit(
        invocation: invocation,
        stage: EmbodiedMotionAuditStage.decided,
        actionId: actionId,
        fingerprint: fingerprint,
        code: decisionCode,
      )) {
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'audit_unavailable',
        );
      }
      if (!confirmation.isAllowed) {
        return EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.confirmationRejected,
          code: 'confirmation_$decisionCode',
        );
      }
      final grant = confirmation.grant!;
      final grantDisposition = _consumeConfirmationGrant(
        confirmationRequest,
        grant,
      );
      if (grantDisposition != _ConfirmationGrantDisposition.accepted) {
        final code = grantDisposition == _ConfirmationGrantDisposition.replayed
            ? 'confirmation_replayed'
            : 'confirmation_mismatch';
        final recorded = await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: code,
        );
        return EmbodiedSupervisorResult(
          outcome: recorded
              ? EmbodiedSupervisorOutcome.confirmationRejected
              : EmbodiedSupervisorOutcome.unavailable,
          code: recorded ? code : 'audit_unavailable',
        );
      }
      if (!_readContextCurrent(
        invocation,
        expectedAttemptEpoch: attemptEpoch,
        expectedMode: mode,
      )) {
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'execution_context_stale',
        );
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'execution_context_stale',
        );
      }

      final snapshots = await _safeCapabilities(
        invocation,
        expectedAttemptEpoch: attemptEpoch,
        expectedMode: mode,
      );
      final capability = _snapshotFor(snapshots, request.capability);
      final stopCapability = _snapshotFor(
        snapshots,
        EmbodiedDeviceCapability.stop,
      );
      final telemetry = snapshots == null
          ? null
          : await _safeTelemetry(
              invocation,
              expectedAttemptEpoch: attemptEpoch,
              expectedMode: mode,
            );
      if (capability == null || stopCapability == null || telemetry == null) {
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'device_state_unavailable',
        );
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.denied,
          code: 'device_state_unavailable',
        );
      }
      if (!stopCapability.supported || !_snapshotFresh(stopCapability)) {
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'stop_capability_unavailable',
        );
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.denied,
          code: 'stop_capability_unavailable',
        );
      }
      final stateRejection = _telemetryRejection(
        capability,
        stopCapability,
        telemetry,
      );
      if (stateRejection != null) {
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: stateRejection,
        );
        return EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.denied,
          code: stateRejection,
        );
      }
      final admitted = _policy.admit(
        request: request,
        capability: capability,
        telemetry: telemetry,
        confirmation: grant.receipt,
        now: _clock().toUtc(),
      );
      final lease = admitted.lease;
      if (lease == null) {
        final recorded = await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: admitted.reason ?? 'motion_denied',
        );
        return EmbodiedSupervisorResult(
          outcome: recorded
              ? EmbodiedSupervisorOutcome.denied
              : EmbodiedSupervisorOutcome.unavailable,
          code: recorded
              ? admitted.reason ?? 'motion_denied'
              : 'audit_unavailable',
        );
      }
      if (!_attemptCanCommit(invocation, attemptEpoch, lease) ||
          !await _appendAudit(
            invocation: invocation,
            stage: EmbodiedMotionAuditStage.executed,
            actionId: actionId,
            fingerprint: fingerprint,
            code: 'started',
          ) ||
          !_attemptCanCommit(invocation, attemptEpoch, lease)) {
        final stopping = _requireStop(
          MotionStopReason.manual,
          invalidateAttempt: false,
        );
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'execution_fence_failed',
        );
        await stopping;
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'execution_fence_failed',
        );
      }

      if (!_armWatchdog(lease)) {
        final stopping = _requireStop(
          MotionStopReason.manual,
          invalidateAttempt: false,
        );
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'watchdog_unavailable',
        );
        await stopping;
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.failed,
          code: 'watchdog_unavailable',
        );
      }
      if (!_attemptCanCommit(invocation, attemptEpoch, lease)) {
        _cancelWatchdog();
        final stopping = _requireStop(
          MotionStopReason.manual,
          invalidateAttempt: false,
        );
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'execution_fence_failed',
        );
        await stopping;
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'execution_fence_failed',
        );
      }
      final opaqueCapability = _motionCapabilityIssuer.issue(
        owner: this,
        accountId: lease.accountId,
        facadeGeneration: lease.facadeGeneration,
        capability: lease.motion.capability,
        distanceMeters: lease.motion.distanceMeters,
        angleDegrees: lease.motion.angleDegrees,
        speedMetersPerSecond: lease.motion.speedMetersPerSecond,
        duration: lease.motion.duration,
        issuedAt: lease.issuedAt,
        expiresAt: lease.expiresAt,
      );
      late final EmbodiedDeadManReceipt deadManReceipt;
      try {
        if (!_attemptCanCommit(invocation, attemptEpoch, lease)) {
          throw StateError('dead_man_authority_stale');
        }
        final armOperation = _facade.armDeadMan(opaqueCapability);
        _activeArmOperation = armOperation;
        final armResult = await armOperation.result
            .whenComplete(() => _armOperationSettled(armOperation))
            .timeout(deviceCallTimeout);
        if (!_attemptCanCommit(invocation, attemptEpoch, lease) ||
            !armResult.isArmed) {
          throw StateError('dead_man_not_armed');
        }
        deadManReceipt = armResult.receipt!;
      } on Object {
        try {
          await _cancelAndDrainArm();
        } on Object {
          _auditCompromised = true;
        }
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'dead_man_arm_failed',
        );
        await _requireStop(MotionStopReason.manual);
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'dead_man_arm_failed',
        );
      }
      if (!_attemptCanCommit(invocation, attemptEpoch, lease)) {
        final stopping = _requireStop(MotionStopReason.manual);
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'execution_fence_failed_after_dead_man_arm',
        );
        await stopping;
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'execution_fence_failed_after_dead_man_arm',
        );
      }
      late final EmbodiedDeviceResult deviceResult;
      try {
        final operation = _facade.beginMotion(opaqueCapability, deadManReceipt);
        _activeMotionOperation = operation;
        if (operation.capabilityId != opaqueCapability.id) {
          throw StateError('motion_operation_capability_mismatch');
        }
        final resultFuture = operation.result.whenComplete(
          () => _motionOperationSettled(operation),
        );
        deviceResult = await resultFuture.timeout(deviceCallTimeout);
      } on Object {
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'device_failed',
        );
        await _requireStop(MotionStopReason.manual);
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.failed,
          code: 'device_failed',
        );
      }

      if (!_attemptCanCommit(invocation, attemptEpoch, lease)) {
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'stale_after_motion_result',
        );
        await _requireStop(MotionStopReason.manual);
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'execution_fence_failed_after_motion_result',
        );
      }
      final succeeded = _validDeviceResult(
        deviceResult,
        lease.motion.capability,
      );
      final audited = await _appendAudit(
        invocation: invocation,
        stage: EmbodiedMotionAuditStage.result,
        actionId: actionId,
        fingerprint: fingerprint,
        code: succeeded ? 'succeeded' : 'device_${deviceResult.status.name}',
      );
      if (audited && !_attemptCanCommit(invocation, attemptEpoch, lease)) {
        final stopping = _requireStop(MotionStopReason.manual);
        await _appendAudit(
          invocation: invocation,
          stage: EmbodiedMotionAuditStage.result,
          actionId: actionId,
          fingerprint: fingerprint,
          code: 'execution_fence_failed_after_result_audit',
        );
        await stopping;
        return const EmbodiedSupervisorResult(
          outcome: EmbodiedSupervisorOutcome.unavailable,
          code: 'execution_fence_failed_after_result_audit',
        );
      }
      if (!succeeded || !audited) {
        await _requireStop(MotionStopReason.manual);
      }
      return EmbodiedSupervisorResult(
        outcome: succeeded && audited
            ? EmbodiedSupervisorOutcome.executed
            : EmbodiedSupervisorOutcome.failed,
        code: succeeded && audited ? 'executed' : 'execution_failed',
        deviceResult: deviceResult,
      );
    } finally {
      _confirmationInFlight = false;
    }
  }

  Future<bool> onDisconnected() => _requireStop(MotionStopReason.disconnected);

  Future<bool> onBackgrounded() => _requireStop(MotionStopReason.backgrounded);

  Future<bool> stop() => _requireStop(MotionStopReason.manual);

  Future<void> retireAndDrain() =>
      _beginRetirement(requireCurrentAuthorityAtCompletion: true);

  /// Host account-teardown path used after the storage mount has already been
  /// revoked. The exact facade identity prevents a different account graph
  /// from retiring this supervisor while allowing revocation itself to remain
  /// the first teardown fence.
  Future<void> retireRevokedAccountAndDrain({
    required String accountId,
    required int facadeGeneration,
  }) {
    if (accountId != _facade.accountId ||
        facadeGeneration != _facade.facadeGeneration) {
      return Future<void>.error(
        StateError('embodied_device_retire_identity_mismatch'),
      );
    }
    return _beginRetirement(requireCurrentAuthorityAtCompletion: false);
  }

  Future<void> _beginRetirement({
    required bool requireCurrentAuthorityAtCompletion,
  }) {
    if (_lifecycle == _EmbodiedSupervisorLifecycle.retired) {
      return Future<void>.value();
    }
    final current = _retireFuture;
    if (current != null) return current;
    _lifecycle = _EmbodiedSupervisorLifecycle.retiring;
    _attemptEpoch += 1;
    _cancelWatchdog();
    late final Future<void> retiring;
    retiring =
        _retireOnce(
          requireCurrentAuthorityAtCompletion:
              requireCurrentAuthorityAtCompletion,
        ).whenComplete(() {
          if (identical(_retireFuture, retiring)) _retireFuture = null;
        });
    _retireFuture = retiring;
    return retiring;
  }

  Future<void> _retireOnce({
    required bool requireCurrentAuthorityAtCompletion,
  }) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    Object? facadeError;
    StackTrace? facadeStackTrace;
    late final Future<void> facadeRetirement;
    try {
      final stopFuture = _requireStop(
        MotionStopReason.accountRetired,
        invalidateAttempt: false,
      );
      final armCancellationFuture = _cancelAndDrainArm();
      final cancellationFuture = _safeCancelConfirmations();
      try {
        // Calling this before the first await establishes the facade's
        // permanent admission fence synchronously, even when this supervisor
        // never admitted a motion invocation.
        facadeRetirement = _facade.retireAndDrain().then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            facadeError = error;
            facadeStackTrace = stackTrace;
          },
        );
      } on Object catch (error, stackTrace) {
        facadeError = error;
        facadeStackTrace = stackTrace;
        facadeRetirement = Future<void>.value();
      }
      var stopped = await stopFuture.timeout(retireTimeout);
      await armCancellationFuture.timeout(retireTimeout);
      await cancellationFuture.timeout(retireTimeout);
      await _waitForOperations().timeout(retireTimeout);
      if (!await _drainPendingStopOperations(timeout: retireTimeout)) {
        throw StateError('embodied_device_stop_drain_failed');
      }
      if (!stopped && _policy.stopRequirement != null) {
        stopped = await _executeRequiredStop();
      }
      if (!stopped || _policy.stopRequirement != null) {
        throw StateError('embodied_device_stop_failed');
      }
      final authority = _lastAuthorizedInvocation;
      if (requireCurrentAuthorityAtCompletion &&
          authority != null &&
          !_authorityCurrent(authority)) {
        throw StateError('embodied_device_retire_authority_stale');
      }
    } on Object catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await facadeRetirement.timeout(retireTimeout);
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (facadeError != null) {
      firstError ??= facadeError;
      firstStackTrace ??= facadeStackTrace;
    }
    if (firstError != null) {
      _lifecycle = _EmbodiedSupervisorLifecycle.failedRetire;
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
    _lifecycle = _EmbodiedSupervisorLifecycle.retired;
  }

  Future<bool> _requireStop(
    MotionStopReason reason, {
    bool invalidateAttempt = true,
  }) async {
    if (invalidateAttempt) _attemptEpoch += 1;
    final hadLease = _policy.activeLease != null;
    final now = _clock().toUtc();
    final requirement = switch (reason) {
      MotionStopReason.disconnected => _policy.onDisconnected(now),
      MotionStopReason.backgrounded => _policy.onBackgrounded(now),
      MotionStopReason.accountRetired => _policy.retireAccount(now),
      _ => _policy.requireStop(reason: reason, now: now),
    };
    _cancelWatchdog();
    if (!hadLease &&
        _activeMotionOperation == null &&
        _stopOperations.isEmpty) {
      return _policy.markStopped(
        stopRequirementId: requirement.id,
        accountId: requirement.accountId,
        facadeGeneration: requirement.facadeGeneration,
      );
    }
    // [_executeRequiredStop] invokes the physical stop synchronously up to its
    // first await. Cancellation is then fenced without delaying emergency stop.
    final stopping = _executeRequiredStop();
    final draining = _beginMotionCancellation();
    if (draining != null) {
      unawaited(
        draining.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    return stopping;
  }

  Future<bool> _executeRequiredStop() {
    final existing = _stopInFlight;
    if (existing != null) return existing;
    _cancelStopRetry();
    late final Future<bool> stopping;
    stopping = _executeStopWithRetries()
        .then<bool>((stopped) {
          if (stopped) {
            _cancelStopRetry();
          } else {
            _scheduleStopRetry();
          }
          return stopped;
        })
        .whenComplete(() {
          if (identical(_stopInFlight, stopping)) _stopInFlight = null;
        });
    _stopInFlight = stopping;
    return stopping;
  }

  Future<bool> _executeStopWithRetries() async {
    for (var attempt = 1; attempt <= maximumStopAttempts; attempt++) {
      if (await _executeStopOnce()) return true;
      if (attempt < maximumStopAttempts) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
    return false;
  }

  Future<bool> _executeStopOnce() async {
    final requirement = _policy.stopRequirement;
    if (requirement == null) return true;
    final authority = _lastAuthorizedInvocation;
    if (authority == null || !_authorityCurrent(authority)) {
      await _recordFailedStop(
        fingerprint: requirement.id,
        code: 'stop_authority_stale',
      );
      return false;
    }
    if (_stopOperations.isNotEmpty && !await _drainPendingStopOperations()) {
      await _recordFailedStop(
        fingerprint: requirement.id,
        code: 'stop_prior_drain_failed',
      );
      return false;
    }
    if (!_authorityCurrent(authority)) {
      await _recordFailedStop(
        fingerprint: requirement.id,
        code: 'stop_authority_stale',
      );
      return false;
    }
    final fingerprint = requirement.id;
    late final EmbodiedStopOperation stopOperation;
    late final _TrackedStopOperation trackedStop;
    try {
      stopOperation = _facade.beginStop();
      trackedStop = _TrackedStopOperation(stopOperation);
      _stopOperations.add(trackedStop);
    } on Object {
      await _recordFailedStop(fingerprint: fingerprint, code: 'stop_failed');
      return false;
    }
    final executedAudit = _appendSystemAudit(
      stage: EmbodiedMotionAuditStage.executed,
      fingerprint: fingerprint,
      code: 'stop_${requirement.reason.name}',
    );

    late final EmbodiedDeviceResult result;
    try {
      result = await stopOperation.result
          .whenComplete(() => _stopOperationSettled(trackedStop))
          .timeout(stopCallTimeout);
    } on Object {
      try {
        await _cancelAndDrainStop(trackedStop);
      } on Object {
        // Keep the stop requirement and operation fence active. A later retry
        // or account retirement must not treat this transport lane as drained.
      }
      await _recordFailedStop(
        fingerprint: fingerprint,
        code: 'stop_failed',
        executedAudit: executedAudit,
      );
      return false;
    }
    if (!_authorityCurrent(authority)) {
      await _recordFailedStop(
        fingerprint: fingerprint,
        code: 'stop_authority_stale',
        executedAudit: executedAudit,
      );
      return false;
    }
    if (!_validDeviceResult(result, EmbodiedDeviceCapability.stop)) {
      await _recordFailedStop(
        fingerprint: fingerprint,
        code: 'stop_invalid_result',
        executedAudit: executedAudit,
      );
      return false;
    }
    if (!await _drainPendingStopOperations()) {
      await _recordFailedStop(
        fingerprint: fingerprint,
        code: 'stop_drain_failed',
        executedAudit: executedAudit,
      );
      return false;
    }
    if (!await _awaitMotionDrain()) {
      await _recordFailedStop(
        fingerprint: fingerprint,
        code: 'motion_drain_failed',
        executedAudit: executedAudit,
      );
      return false;
    }
    if (!await executedAudit) _auditCompromised = true;
    final marked = _policy.markStopped(
      stopRequirementId: requirement.id,
      accountId: requirement.accountId,
      facadeGeneration: requirement.facadeGeneration,
    );
    final resultAudit = await _appendSystemAudit(
      stage: EmbodiedMotionAuditStage.result,
      fingerprint: fingerprint,
      code: marked ? 'stop_succeeded' : 'stop_fence_failed',
    );
    if (!resultAudit) {
      _auditCompromised = true;
    }
    return marked;
  }

  Future<void> _recordFailedStop({
    required String fingerprint,
    required String code,
    Future<bool>? executedAudit,
  }) async {
    if (executedAudit != null && !await executedAudit) {
      _auditCompromised = true;
    }
    if (!await _appendSystemAudit(
      stage: EmbodiedMotionAuditStage.result,
      fingerprint: fingerprint,
      code: code,
    )) {
      _auditCompromised = true;
    }
  }

  Future<void> _cancelAndDrainStop(_TrackedStopOperation tracked) async {
    if (!_stopOperations.contains(tracked)) return;
    var drain = tracked.cancellationDrain;
    if (drain == null) {
      try {
        drain = tracked.operation.cancelAndDrain();
      } on Object catch (error, stackTrace) {
        drain = Future<void>.error(error, stackTrace);
      }
      tracked.cancellationDrain = drain;
    }
    await drain.timeout(deviceCallTimeout);
    _stopOperations.remove(tracked);
  }

  Future<bool> _drainPendingStopOperations({Duration? timeout}) async {
    for (final tracked in _stopOperations.toList(growable: false)) {
      try {
        await _cancelAndDrainStop(
          tracked,
        ).timeout(timeout ?? deviceCallTimeout);
      } on Object {
        return false;
      }
    }
    return _stopOperations.isEmpty;
  }

  void _stopOperationSettled(_TrackedStopOperation tracked) {
    _stopOperations.remove(tracked);
  }

  void _scheduleStopRetry() {
    if (_policy.stopRequirement == null || _stopRetryWatchdog != null) return;
    final generation = ++_stopRetryGeneration;
    try {
      _stopRetryWatchdog = _scheduleWatchdog(
        const Duration(milliseconds: 100),
        () => unawaited(_handleStopRetry(generation)),
      );
    } on Object {
      _auditCompromised = true;
    }
  }

  Future<void> _handleStopRetry(int generation) async {
    if (generation != _stopRetryGeneration) return;
    _stopRetryWatchdog = null;
    if (_policy.stopRequirement != null) await _executeRequiredStop();
  }

  void _cancelStopRetry() {
    _stopRetryGeneration += 1;
    _stopRetryWatchdog?.cancel();
    _stopRetryWatchdog = null;
  }

  Future<String?> _shadowRejectionReason(
    EmbodiedMotionInvocation invocation,
    EmbodiedDeviceCapability capability, {
    required int expectedAttemptEpoch,
    required FeatureRolloutMode expectedMode,
  }) async {
    final snapshots = await _safeCapabilities(
      invocation,
      expectedAttemptEpoch: expectedAttemptEpoch,
      expectedMode: expectedMode,
    );
    if (snapshots == null) return 'device_state_unavailable';
    final snapshot = _snapshotFor(snapshots, capability);
    final stop = _snapshotFor(snapshots, EmbodiedDeviceCapability.stop);
    final telemetry = await _safeTelemetry(
      invocation,
      expectedAttemptEpoch: expectedAttemptEpoch,
      expectedMode: expectedMode,
    );
    if (snapshot == null || stop == null || telemetry == null) {
      return 'device_state_unavailable';
    }
    if (!snapshot.supported) return 'capability_unsupported';
    if (!stop.supported || !_snapshotFresh(stop)) {
      return 'stop_capability_unavailable';
    }
    return _telemetryRejection(snapshot, stop, telemetry);
  }

  Future<String?> _enforcePreflight(
    EmbodiedMotionInvocation invocation,
    EmbodiedDeviceCapability capability, {
    required int expectedAttemptEpoch,
    required FeatureRolloutMode expectedMode,
  }) async {
    final snapshots = await _safeCapabilities(
      invocation,
      expectedAttemptEpoch: expectedAttemptEpoch,
      expectedMode: expectedMode,
    );
    if (snapshots == null) return 'device_state_unavailable';
    final snapshot = _snapshotFor(snapshots, capability);
    final stop = _snapshotFor(snapshots, EmbodiedDeviceCapability.stop);
    final telemetry = await _safeTelemetry(
      invocation,
      expectedAttemptEpoch: expectedAttemptEpoch,
      expectedMode: expectedMode,
    );
    if (snapshot == null || stop == null || telemetry == null) {
      return 'device_state_unavailable';
    }
    if (!snapshot.supported) return 'capability_unsupported';
    if (!stop.supported || !_snapshotFresh(stop)) {
      return 'stop_capability_unavailable';
    }
    return _telemetryRejection(snapshot, stop, telemetry);
  }

  String? _telemetryRejection(
    EmbodiedCapabilitySnapshot capability,
    EmbodiedCapabilitySnapshot stopCapability,
    EmbodiedDeviceTelemetry telemetry,
  ) {
    if (!_snapshotFresh(capability) ||
        !_snapshotFresh(stopCapability) ||
        !_telemetryFresh(telemetry)) {
      return 'telemetry_stale';
    }
    if (capability.accountId != _facade.accountId ||
        capability.facadeGeneration != _facade.facadeGeneration ||
        stopCapability.accountId != _facade.accountId ||
        stopCapability.facadeGeneration != _facade.facadeGeneration ||
        telemetry.accountId != _facade.accountId ||
        telemetry.facadeGeneration != _facade.facadeGeneration) {
      return 'account_or_generation_mismatch';
    }
    if (!telemetry.connected) return 'device_disconnected';
    if (telemetry.backgrounded) return 'app_backgrounded';
    return null;
  }

  bool _snapshotFresh(EmbodiedCapabilitySnapshot snapshot) =>
      _fresh(capturedAt: snapshot.capturedAt, freshness: snapshot.freshness);

  bool _telemetryFresh(EmbodiedDeviceTelemetry telemetry) =>
      _fresh(capturedAt: telemetry.capturedAt, freshness: telemetry.freshness);

  bool _fresh({
    required DateTime capturedAt,
    required EmbodiedFreshness freshness,
  }) {
    final now = _clock().toUtc();
    final captured = capturedAt.toUtc();
    return freshness == EmbodiedFreshness.fresh &&
        !captured.isAfter(now) &&
        now.difference(captured) <= PhysicalMotionPolicy.maxTelemetryAge;
  }

  Future<List<EmbodiedCapabilitySnapshot>?> _safeCapabilities(
    EmbodiedMotionInvocation invocation, {
    required int expectedAttemptEpoch,
    required FeatureRolloutMode expectedMode,
  }) async {
    if (!_readContextCurrent(
      invocation,
      expectedAttemptEpoch: expectedAttemptEpoch,
      expectedMode: expectedMode,
    )) {
      return null;
    }
    try {
      final result = await _facade.capabilities().timeout(deviceCallTimeout);
      return _readContextCurrent(
            invocation,
            expectedAttemptEpoch: expectedAttemptEpoch,
            expectedMode: expectedMode,
          )
          ? result
          : null;
    } on Object {
      return null;
    }
  }

  Future<EmbodiedDeviceTelemetry?> _safeTelemetry(
    EmbodiedMotionInvocation invocation, {
    required int expectedAttemptEpoch,
    required FeatureRolloutMode expectedMode,
  }) async {
    if (!_readContextCurrent(
      invocation,
      expectedAttemptEpoch: expectedAttemptEpoch,
      expectedMode: expectedMode,
    )) {
      return null;
    }
    try {
      final result = await _facade.telemetry().timeout(deviceCallTimeout);
      return _readContextCurrent(
            invocation,
            expectedAttemptEpoch: expectedAttemptEpoch,
            expectedMode: expectedMode,
          )
          ? result
          : null;
    } on Object {
      return null;
    }
  }

  bool _readContextCurrent(
    EmbodiedMotionInvocation invocation, {
    required int expectedAttemptEpoch,
    required FeatureRolloutMode expectedMode,
  }) =>
      expectedAttemptEpoch == _attemptEpoch &&
      _safeRolloutMode() == expectedMode &&
      _stillCurrent(invocation);

  static EmbodiedCapabilitySnapshot? _snapshotFor(
    List<EmbodiedCapabilitySnapshot>? snapshots,
    EmbodiedDeviceCapability capability,
  ) {
    if (snapshots == null) return null;
    for (final snapshot in snapshots) {
      if (snapshot.capability == capability) return snapshot;
    }
    return null;
  }

  Future<EmbodiedMotionConfirmationResult> _confirm(
    EmbodiedMotionConfirmationRequest request,
  ) async {
    try {
      final remaining = request.expiresAt.difference(_clock().toUtc());
      if (remaining <= Duration.zero) {
        return const EmbodiedMotionConfirmationResult(
          outcome: EmbodiedConfirmationOutcome.unavailable,
        );
      }
      return await _confirmation.confirm(request).timeout(remaining);
    } on Object {
      return const EmbodiedMotionConfirmationResult(
        outcome: EmbodiedConfirmationOutcome.unavailable,
      );
    }
  }

  String _newChallengeNonce(DateTime issuedAt) {
    _challengeSequence += 1;
    return '${_facade.facadeGeneration}-$_challengeSequence-'
        '${issuedAt.microsecondsSinceEpoch}-'
        '${_nonceRandom.nextInt(0x7fffffff)}';
  }

  _ConfirmationGrantDisposition _consumeConfirmationGrant(
    EmbodiedMotionConfirmationRequest request,
    EmbodiedMotionConfirmationGrant grant,
  ) {
    final receipt = grant.receipt;
    final now = _clock().toUtc();
    final idValid = receipt.id.isNotEmpty && receipt.id.length <= 128;
    final exact =
        grant.challengeNonce == request.challengeNonce &&
        grant.accountId == request.invocation.accountId &&
        grant.facadeGeneration == request.invocation.facadeGeneration &&
        grant.agentId == request.invocation.agentId &&
        grant.runtimeGeneration == request.invocation.runtimeGeneration &&
        grant.callId == request.invocation.callId &&
        grant.actionId == request.actionId &&
        grant.target == request.target &&
        grant.motionFingerprint == request.motionFingerprint &&
        grant.issuedAt.toUtc() == request.issuedAt.toUtc() &&
        grant.expiresAt.toUtc() == request.expiresAt.toUtc() &&
        receipt.accountId == request.invocation.accountId &&
        receipt.facadeGeneration == request.invocation.facadeGeneration &&
        receipt.motionFingerprint == request.motionFingerprint &&
        receipt.issuedAt.toUtc() == request.issuedAt.toUtc() &&
        receipt.expiresAt.toUtc() == request.expiresAt.toUtc() &&
        !request.issuedAt.isAfter(now) &&
        request.expiresAt.isAfter(now);
    _consumedConfirmations.removeWhere(
      (_, expiresAt) => !expiresAt.isAfter(now),
    );
    if (!idValid || !exact) {
      return _ConfirmationGrantDisposition.mismatch;
    }
    if (_consumedConfirmations.containsKey(receipt.id)) {
      return _ConfirmationGrantDisposition.replayed;
    }
    _consumedConfirmations[receipt.id] = request.expiresAt.toUtc();
    return _ConfirmationGrantDisposition.accepted;
  }

  bool _attemptCanCommit(
    EmbodiedMotionInvocation invocation,
    int attemptEpoch,
    MotionLease lease,
  ) =>
      attemptEpoch == _attemptEpoch &&
      _safeRolloutMode() == FeatureRolloutMode.enforce &&
      _stillCurrent(invocation) &&
      identical(_policy.activeLease, lease) &&
      lease.expiresAt.isAfter(_clock().toUtc());

  bool _validDeviceResult(
    EmbodiedDeviceResult result,
    EmbodiedDeviceCapability capability,
  ) =>
      result.status == EmbodiedResultStatus.ok &&
      result.capability == capability &&
      result.accountId == _facade.accountId &&
      result.facadeGeneration == _facade.facadeGeneration &&
      _fresh(capturedAt: result.capturedAt, freshness: result.freshness);

  Future<bool> _appendAudit({
    required EmbodiedMotionInvocation invocation,
    required EmbodiedMotionAuditStage stage,
    required String actionId,
    required String fingerprint,
    required String code,
  }) async {
    final event = EmbodiedMotionAuditEvent(
      stage: stage,
      accountId: invocation.accountId,
      facadeGeneration: invocation.facadeGeneration,
      agentId: invocation.agentId,
      runtimeGeneration: invocation.runtimeGeneration,
      callId: invocation.callId,
      actionId: actionId,
      motionFingerprint: fingerprint,
      outcomeCode: _boundedCode(code),
      occurredAt: _clock().toUtc(),
    );
    try {
      final appended = await _audit
          .append(event, transientTarget: _deviceTarget)
          .timeout(auditTimeout);
      if (!appended) {
        _auditCompromised = true;
      }
      return appended;
    } on Object {
      _auditCompromised = true;
      return false;
    }
  }

  Future<bool> _appendSystemAudit({
    required EmbodiedMotionAuditStage stage,
    required String fingerprint,
    required String code,
  }) async => _appendAudit(
    invocation: EmbodiedMotionInvocation(
      accountId: _facade.accountId,
      facadeGeneration: _facade.facadeGeneration,
      agentId: 'system',
      runtimeGeneration: 0,
      callId: fingerprint,
    ),
    stage: stage,
    actionId: 'device.motion.stop',
    fingerprint: fingerprint,
    code: code,
  );

  Future<void> _cancelAndDrainArm() async {
    final operation = _activeArmOperation;
    if (operation == null) return;
    var drain = _armDrain;
    if (drain == null) {
      try {
        drain = operation.cancelAndDrain();
      } on Object catch (error, stackTrace) {
        drain = Future<void>.error(error, stackTrace);
      }
      _armDrain = drain;
    }
    await drain.timeout(deviceCallTimeout);
    if (identical(_activeArmOperation, operation)) {
      _activeArmOperation = null;
      _armDrain = null;
    }
  }

  void _armOperationSettled(EmbodiedDeadManArmOperation operation) {
    if (identical(_activeArmOperation, operation)) {
      _activeArmOperation = null;
      _armDrain = null;
    }
  }

  Future<void>? _beginMotionCancellation() {
    final operation = _activeMotionOperation;
    if (operation == null) return null;
    final existing = _motionDrain;
    if (existing != null) return existing;
    late final Future<void> drain;
    try {
      drain = operation.cancelAndDrain();
    } on Object catch (error, stackTrace) {
      drain = Future<void>.error(error, stackTrace);
    }
    late final Future<void> tracked;
    tracked = drain.then<void>(
      (_) {
        if (identical(_motionDrain, tracked)) _motionDrain = null;
        if (identical(_activeMotionOperation, operation)) {
          _activeMotionOperation = null;
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          Error.throwWithStackTrace(error, stackTrace),
    );
    _motionDrain = tracked;
    return tracked;
  }

  Future<bool> _awaitMotionDrain() async {
    final drain = _motionDrain ?? _beginMotionCancellation();
    if (drain == null) return true;
    try {
      await drain.timeout(deviceCallTimeout);
      return true;
    } on Object {
      return false;
    }
  }

  void _motionOperationSettled(EmbodiedMotionOperation operation) {
    if (identical(_activeMotionOperation, operation)) {
      _activeMotionOperation = null;
      _motionDrain = null;
    }
  }

  bool _armWatchdog(MotionLease lease) {
    _cancelWatchdog();
    final delay = lease.expiresAt.difference(_clock().toUtc());
    final generation = ++_watchdogGeneration;
    try {
      _watchdog = _scheduleWatchdog(
        delay.isNegative ? Duration.zero : delay,
        () => unawaited(_handleWatchdog(generation)),
      );
      return true;
    } on Object {
      _watchdog = null;
      return false;
    }
  }

  Future<void> _handleWatchdog(int generation) async {
    if (generation != _watchdogGeneration) return;
    _watchdog = null;
    // The timer delay is the dead-man authority. Wall-clock rollback or an
    // early scheduler callback must never discard the only physical stop.
    await _requireStop(MotionStopReason.leaseTimeout);
  }

  void _cancelWatchdog() {
    _watchdogGeneration += 1;
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _track(Future<Object?> operation) {
    late final Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _operations.remove(tracked));
    _operations.add(tracked);
  }

  Future<void> _waitForOperations() async {
    while (_operations.isNotEmpty) {
      await Future.wait<void>(_operations.toList(growable: false));
    }
  }

  Future<void> _safeCancelConfirmations() async {
    try {
      await _confirmation.cancelAll();
    } on Object {
      // A stale confirmation can no longer write because lifecycle admission
      // was synchronously fenced before this call.
    }
  }

  FeatureRolloutMode _safeRolloutMode() {
    try {
      return _rolloutMode();
    } on Object {
      return FeatureRolloutMode.off;
    }
  }

  bool get _active =>
      _lifecycle == _EmbodiedSupervisorLifecycle.active && !isClosed;

  bool _matchesInvocation(EmbodiedMotionInvocation invocation) =>
      invocation.accountId == _facade.accountId &&
      invocation.facadeGeneration == _facade.facadeGeneration;

  bool _stillCurrent(EmbodiedMotionInvocation invocation) {
    if (!_active) return false;
    return _authorityCurrent(invocation);
  }

  bool _authorityCurrent(EmbodiedMotionInvocation invocation) {
    if (!_matchesInvocation(invocation)) return false;
    try {
      return _authorityIsCurrent(invocation);
    } on Object {
      return false;
    }
  }

  @override
  void onClose() {
    unawaited(retireAndDrain().catchError((Object _, StackTrace _) {}));
    super.onClose();
  }

  static EmbodiedWatchdogHandle _scheduleTimerWatchdog(
    Duration delay,
    void Function() callback,
  ) => _TimerWatchdogHandle(Timer(delay, callback));
}

final class _TimerWatchdogHandle implements EmbodiedWatchdogHandle {
  _TimerWatchdogHandle(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

final class _TrackedStopOperation {
  _TrackedStopOperation(this.operation);

  final EmbodiedStopOperation operation;
  Future<void>? cancellationDrain;
}

String _boundedIdentifier(String value, String field, int maximumLength) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximumLength ||
      RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(normalized)) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

String _boundedCode(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty ||
      normalized.length > 96 ||
      !RegExp(r'^[a-z0-9_.:-]+$').hasMatch(normalized)) {
    return 'invalid_code';
  }
  return normalized;
}
