import 'dart:async';

import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_observability.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';

typedef AvatarSelectionLocalPreview = FutureOr<void> Function();
typedef AvatarSelectionLocalApply =
    FutureOr<void> Function(AvatarSelectionSnapshot snapshot);
typedef AvatarSelectionCompensationDecision =
    FutureOr<bool> Function(AvatarSelectionReceipt receipt);
typedef AvatarSelectionRecoveryDecision =
    FutureOr<AvatarSelectionRecoveryResolution> Function(
      AvatarSelectionOutboxEntry entry,
    );
typedef AvatarSelectionRetryDelay = FutureOr<void> Function(int attempt);

enum AvatarSelectionRecoveryResolution { rollForward, compensate }

enum AvatarSelectionRecoveryOperation { setReplay, compensation }

enum AvatarSelectionRecoveryOutcome {
  reconciledCurrent,
  rolledForward,
  compensated,
  superseded,
}

/// A coordinator-issued, account/generation-fenced recovery request.
///
/// The private constructor prevents UI/runtime callers from turning an
/// arbitrary request into a teardown-authorized replay.
final class AvatarSelectionRecoveryClaim {
  const AvatarSelectionRecoveryClaim._({
    required this.accountScopeDigest,
    required this.agentScopeDigest,
    required this.ownerGeneration,
    required this.recordRevision,
    required this.operation,
    required this.request,
  });

  final String accountScopeDigest;
  final String agentScopeDigest;
  final int ownerGeneration;
  final int recordRevision;
  final AvatarSelectionRecoveryOperation operation;
  final AvatarSelectionCommitRequest request;
}

/// Captured old-account lane used only for exact replay or compensation.
///
/// It deliberately has no GET and no public recovery flag. A production
/// implementation validates every claim against its captured account token.
abstract interface class AvatarSelectionRecoveryTransport {
  Future<AvatarSelectionCommitResult> replay(
    AvatarSelectionRecoveryClaim claim,
  );
}

final class AvatarSelectionLocalPhases {
  const AvatarSelectionLocalPhases({
    this.preview,
    this.commit,
    this.restore,
    this.shouldCompensate,
  });

  final AvatarSelectionLocalPreview? preview;
  final AvatarSelectionLocalApply? commit;
  final AvatarSelectionLocalApply? restore;
  final AvatarSelectionCompensationDecision? shouldCompensate;

  Future<void> previewTarget() async {
    await preview?.call();
  }

  Future<void> commitAuthoritative(AvatarSelectionSnapshot snapshot) async {
    await commit?.call(snapshot);
  }

  Future<void> restoreAuthoritative(AvatarSelectionSnapshot snapshot) async {
    await restore?.call(snapshot);
  }

  Future<bool> compensationRequired(AvatarSelectionReceipt receipt) async =>
      await shouldCompensate?.call(receipt) ?? false;
}

final class AvatarSelectionRecoveryResult {
  const AvatarSelectionRecoveryResult({
    required this.outcome,
    required this.current,
    this.committedSelection,
  });

  final AvatarSelectionRecoveryOutcome outcome;
  final AvatarSelectionSnapshot current;
  final AvatarSelectionCommittedSelection? committedSelection;
}

/// Coordinator-issued evidence for retiring one exact committed selection.
///
/// The constructor is private and the issuer token is verified again by
/// [AvatarSelectionCoordinator.retireCommittedSelection]. Callers cannot
/// synthesize a model/version tuple and ask the coordinator to overwrite it.
final class AvatarSelectionCommittedSelection {
  const AvatarSelectionCommittedSelection._({
    required Object issuer,
    required this.request,
    required this.receipt,
    required this.compensationKey,
  }) : _issuer = issuer;

  final Object _issuer;
  final AvatarSelectionCommitRequest request;
  final AvatarSelectionReceipt receipt;
  final String compensationKey;

  AvatarSelectionSnapshot get current => AvatarSelectionSnapshot(
    selection: receipt.selection,
    asset: receipt.asset,
    selectionAvailable: receipt.selectionAvailable,
  );
}

final class AvatarSelectionRetirementResult {
  const AvatarSelectionRetirementResult({
    required this.outcome,
    required this.current,
  });

  final AvatarSelectionRecoveryOutcome outcome;
  final AvatarSelectionSnapshot current;
}

final class AvatarSelectionCoordinatorDrainResult {
  const AvatarSelectionCoordinatorDrainResult({
    required this.coordinatorDrained,
    required this.outboxDrained,
  });

  final bool coordinatorDrained;
  final bool outboxDrained;

  bool get fullyDrained => coordinatorDrained && outboxDrained;
}

sealed class AvatarSelectionCoordinatorException implements Exception {
  const AvatarSelectionCoordinatorException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class AvatarSelectionCoordinatorUnavailableException
    extends AvatarSelectionCoordinatorException {
  const AvatarSelectionCoordinatorUnavailableException()
    : super('avatar_selection_coordinator_inactive');
}

final class AvatarSelectionOutstandingObligationException
    extends AvatarSelectionCoordinatorException {
  const AvatarSelectionOutstandingObligationException(this.stage)
    : super('avatar_selection_outstanding_obligation');

  final AvatarSelectionOutboxStage stage;
}

final class AvatarSelectionLocalCommitCompensatedException
    extends AvatarSelectionCoordinatorException {
  const AvatarSelectionLocalCommitCompensatedException({
    required this.localError,
    required this.appliedReceipt,
    required this.compensationReceipt,
  }) : super('avatar_selection_local_commit_compensated');

  final Object localError;
  final AvatarSelectionReceipt appliedReceipt;
  final AvatarSelectionReceipt compensationReceipt;
}

final class AvatarSelectionCompensatedException
    extends AvatarSelectionCoordinatorException {
  const AvatarSelectionCompensatedException({
    required this.appliedReceipt,
    required this.compensationReceipt,
  }) : super('avatar_selection_commit_compensated');

  final AvatarSelectionReceipt appliedReceipt;
  final AvatarSelectionReceipt compensationReceipt;
}

final class AvatarSelectionCompensationSupersededException
    extends AvatarSelectionCoordinatorException {
  const AvatarSelectionCompensationSupersededException({
    required this.appliedReceipt,
    required this.current,
    this.localError,
  }) : super('avatar_selection_compensation_superseded');

  final AvatarSelectionReceipt appliedReceipt;
  final AvatarSelectionSnapshot current;
  final Object? localError;
}

/// Serializes all authoritative Avatar selection work for one account/agent.
///
/// The caller owns local renderer policy through [AvatarSelectionLocalPhases].
/// Network replay and compensation intentionally have no capability callback:
/// once a durable obligation exists, cleanup must remain available even after
/// the Remote Avatar capability has been revoked.
final class AvatarSelectionCoordinator {
  AvatarSelectionCoordinator({
    required AvatarSelectionTransport transport,
    required AvatarSelectionRecoveryTransport recoveryTransport,
    required AvatarSelectionOutbox outbox,
    String Function()? idempotencyKeyFactory,
    AvatarSelectionRetryDelay? retryDelay,
    AvatarSelectionObservability? observability,
    this.maxAmbiguousAttempts = 3,
  }) : _transport = transport,
       _recoveryTransport = recoveryTransport,
       _outbox = outbox,
       _observability = observability ?? AvatarSelectionObservability(),
       _idempotencyKeyFactory =
           idempotencyKeyFactory ?? AvatarSelectionIdempotencyKey.generate,
       _retryDelay = retryDelay ?? _noRetryDelay {
    if (maxAmbiguousAttempts <= 0) {
      throw ArgumentError.value(
        maxAmbiguousAttempts,
        'maxAmbiguousAttempts',
        'must be positive',
      );
    }
  }

  final AvatarSelectionTransport _transport;
  final AvatarSelectionRecoveryTransport _recoveryTransport;
  final AvatarSelectionOutbox _outbox;
  final AvatarSelectionObservability _observability;
  final String Function() _idempotencyKeyFactory;
  final AvatarSelectionRetryDelay _retryDelay;

  final int maxAmbiguousAttempts;
  final StreamController<AvatarSelectionSnapshot> _snapshots =
      StreamController<AvatarSelectionSnapshot>.broadcast(sync: true);
  final Object _evidenceIssuer = Object();
  final Set<AvatarSelectionCommittedSelection> _retiredEvidence =
      <AvatarSelectionCommittedSelection>{};

  Future<void> _tail = Future<void>.value();
  AvatarSelectionSnapshot? _current;
  bool _currentProven = false;
  bool _sealed = false;
  Future<AvatarSelectionCoordinatorDrainResult>? _drainFuture;

  String get agentId => _outbox.agentScope.agentId;

  int get ownerGeneration => _outbox.ownerGeneration;

  AvatarSelectionSnapshot? get current => _current;

  bool get isReady => _currentProven;

  bool get isSealed => _sealed;

  Stream<AvatarSelectionSnapshot> get snapshots => _snapshots.stream;

  AvatarSelectionObservabilitySnapshot get observabilitySnapshot =>
      _observability.snapshot;

  AvatarSelectionObservability get observability => _observability;

  Future<AvatarSelectionSnapshot> ensureCurrent({
    AvatarSelectionAssetOptions assetOptions =
        const AvatarSelectionAssetOptions.none(),
  }) => _serialize(AvatarSelectionObservedOperation.currentRead, () async {
    await _requireNoOutstandingObligation();
    return _ensureCurrentInternal(assetOptions);
  });

  /// Forces an authoritative GET even when the cached snapshot is proven.
  ///
  /// World joins use this immediately before matching so their version fence
  /// cannot silently reuse a snapshot proven by an earlier interaction. Like
  /// every other coordinator entry point, the refresh is serialized with
  /// mutations and rejects work after account teardown has sealed the lane.
  Future<AvatarSelectionSnapshot> refreshCurrent({
    AvatarSelectionAssetOptions assetOptions =
        const AvatarSelectionAssetOptions.none(),
  }) => _serialize(AvatarSelectionObservedOperation.currentRead, () async {
    await _requireNoOutstandingObligation();
    final authoritative = await _readCurrent(assetOptions);
    _publish(authoritative);
    return authoritative;
  });

  Future<AvatarSelectionCommittedSelection> commit({
    required int? modelId,
    required AvatarSelectionAssetOptions assetOptions,
    String? expectedAssetVersionDigest,
    AvatarSelectionLocalPhases local = const AvatarSelectionLocalPhases(),
  }) => _serialize(AvatarSelectionObservedOperation.selectionCommit, () async {
    await _requireNoOutstandingObligation();
    final previous = await _ensureCurrentInternal(assetOptions);
    try {
      await local.previewTarget();
    } on Object {
      await local.restoreAuthoritative(previous);
      rethrow;
    }

    late String compensationKey;
    late AvatarSelectionCommitRequest request;
    late AvatarSelectionOutboxEntry entry;
    try {
      final operationKey = _newKey();
      compensationKey = _newKey();
      if (operationKey == compensationKey) {
        throw const FormatException(
          'avatar_selection_coordinator_duplicate_keys',
        );
      }
      request = AvatarSelectionCommitRequest(
        agentId: agentId,
        modelId: modelId,
        expectedVersion: previous.selection.version,
        idempotencyKey: operationKey,
        assetOptions: assetOptions,
        expectedAssetVersionDigest: expectedAssetVersionDigest,
      );
      entry = _observeOutbox(
        await _outbox.prepare(
          request: request,
          previousSelection: previous.selection,
          compensationKey: compensationKey,
        ),
      );
    } on Object {
      await local.restoreAuthoritative(previous);
      rethrow;
    }
    _markCurrentUnproven();

    late final AvatarSelectionCommitResult result;
    try {
      result = await _commitExact(
        entry: entry,
        request: request,
        operation: AvatarSelectionRecoveryOperation.setReplay,
        dispatchInitial: true,
      );
    } on AvatarSelectionVersionChangedException catch (error) {
      entry = _observeOutbox(
        await _outbox.markSuperseded(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
          reason: AvatarSelectionSupersededReason.setVersionConflict,
        ),
      );
      await local.restoreAuthoritative(error.currentSelection);
      await _outbox.completeSuperseded(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
      );
      _observeOutbox(null);
      _publish(error.currentSelection);
      rethrow;
    } on AvatarSelectionException catch (error) {
      if (_isDefinitelyUncommitted(error)) {
        await _outbox.discardDefinitelyUncommitted(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
        _observeOutbox(null);
        await local.restoreAuthoritative(previous);
        _publish(previous);
      } else {
        await local.restoreAuthoritative(previous);
      }
      rethrow;
    }

    result.receipt.validateAgainst(request);
    entry = _observeOutbox(
      await _outbox.recordApplied(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
        receipt: result.receipt,
      ),
    );
    final applied = _snapshotFromReceipt(result.receipt);

    if (await local.compensationRequired(result.receipt)) {
      entry = _observeOutbox(
        await _outbox.requestCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        ),
      );
      await local.restoreAuthoritative(previous);
      final compensation = await _compensate(entry, local);
      if (compensation.$2) {
        throw AvatarSelectionCompensationSupersededException(
          appliedReceipt: result.receipt,
          current: compensation.$3,
        );
      }
      throw AvatarSelectionCompensatedException(
        appliedReceipt: result.receipt,
        compensationReceipt: compensation.$1!,
      );
    }

    try {
      await local.commitAuthoritative(applied);
    } on Object catch (localError) {
      entry = _observeOutbox(
        await _outbox.requestCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        ),
      );
      await local.restoreAuthoritative(previous);
      final compensation = await _compensate(entry, local);
      if (compensation.$2) {
        throw AvatarSelectionCompensationSupersededException(
          appliedReceipt: result.receipt,
          current: compensation.$3,
          localError: localError,
        );
      }
      throw AvatarSelectionLocalCommitCompensatedException(
        localError: localError,
        appliedReceipt: result.receipt,
        compensationReceipt: compensation.$1!,
      );
    }

    await _outbox.completeLocalCommit(
      operationKey: entry.operationKey,
      expectedRevision: entry.recordRevision,
    );
    _observeOutbox(null);
    _publish(applied);
    return _issueCommittedSelection(
      request: request,
      receipt: result.receipt,
      compensationKey: compensationKey,
    );
  });

  Future<AvatarSelectionRetirementResult> retireCommittedSelection(
    AvatarSelectionCommittedSelection committed, {
    AvatarSelectionLocalPhases local = const AvatarSelectionLocalPhases(),
  }) => _serialize(AvatarSelectionObservedOperation.retirement, () async {
    _validateCommittedSelection(committed);
    if (_retiredEvidence.contains(committed)) {
      throw StateError('avatar_selection_evidence_already_retired');
    }

    final inspected = _observeOutbox(await _outbox.inspectForRecovery());
    late AvatarSelectionOutboxEntry entry;
    if (inspected == null) {
      entry = _observeOutbox(
        await _outbox.prepare(
          request: committed.request,
          previousSelection: committed.receipt.previousSelection,
          compensationKey: committed.compensationKey,
        ),
      );
    } else {
      entry = inspected;
      _requireMatchingEvidence(entry, committed);
      if (entry.ownerGeneration != ownerGeneration) {
        throw const AvatarSelectionOutboxConflictException(
          'avatar_selection_retirement_generation_mismatch',
        );
      }
    }
    _markCurrentUnproven();

    if (entry.stage == AvatarSelectionOutboxStage.prepared) {
      entry = _observeOutbox(
        await _outbox.recordApplied(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
          receipt: committed.receipt,
        ),
      );
    }
    if (entry.stage == AvatarSelectionOutboxStage.applied) {
      entry = _observeOutbox(
        await _outbox.requestCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        ),
      );
    }
    if (entry.stage != AvatarSelectionOutboxStage.compensateNeeded &&
        entry.stage != AvatarSelectionOutboxStage.compensating) {
      throw StateError('avatar_selection_retirement_not_compensatable');
    }

    // This phase lets AvatarConfigService switch to a bundled/prior fallback
    // only after the compensation obligation is durable, but before network.
    await local.previewTarget();
    final compensation = await _compensate(entry, local);
    _retiredEvidence.add(committed);
    return AvatarSelectionRetirementResult(
      outcome: compensation.$2
          ? AvatarSelectionRecoveryOutcome.superseded
          : AvatarSelectionRecoveryOutcome.compensated,
      current: compensation.$3,
    );
  });

  Future<AvatarSelectionRecoveryResult> recover({
    required AvatarSelectionRecoveryDecision decide,
    AvatarSelectionAssetOptions assetOptions =
        const AvatarSelectionAssetOptions.none(),
    AvatarSelectionLocalPhases local = const AvatarSelectionLocalPhases(),
  }) => _serialize(AvatarSelectionObservedOperation.recovery, () async {
    final inspected = _observeOutbox(await _outbox.inspectForRecovery());
    if (inspected == null) {
      final authoritative = await _ensureCurrentInternal(assetOptions);
      return AvatarSelectionRecoveryResult(
        outcome: AvatarSelectionRecoveryOutcome.reconciledCurrent,
        current: authoritative,
      );
    }
    _markCurrentUnproven();
    var entry = inspected;
    if (entry.ownerGeneration != ownerGeneration) {
      entry = _observeOutbox(
        await _outbox.adoptForRecovery(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        ),
      );
    }

    if (entry.stage == AvatarSelectionOutboxStage.superseded) {
      final authoritative = await _readCurrent(assetOptions);
      await local.restoreAuthoritative(authoritative);
      await _outbox.completeSuperseded(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
      );
      _observeOutbox(null);
      _publish(authoritative);
      return AvatarSelectionRecoveryResult(
        outcome: AvatarSelectionRecoveryOutcome.superseded,
        current: authoritative,
      );
    }

    if (entry.stage == AvatarSelectionOutboxStage.prepared) {
      try {
        final result = await _commitExact(
          entry: entry,
          request: entry.request,
          operation: AvatarSelectionRecoveryOperation.setReplay,
        );
        result.receipt.validateAgainst(entry.request);
        entry = _observeOutbox(
          await _outbox.recordApplied(
            operationKey: entry.operationKey,
            expectedRevision: entry.recordRevision,
            receipt: result.receipt,
          ),
        );
      } on AvatarSelectionVersionChangedException catch (error) {
        entry = _observeOutbox(
          await _outbox.markSuperseded(
            operationKey: entry.operationKey,
            expectedRevision: entry.recordRevision,
            reason: AvatarSelectionSupersededReason.setVersionConflict,
          ),
        );
        await local.restoreAuthoritative(error.currentSelection);
        await _outbox.completeSuperseded(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
        _observeOutbox(null);
        _publish(error.currentSelection);
        return AvatarSelectionRecoveryResult(
          outcome: AvatarSelectionRecoveryOutcome.superseded,
          current: error.currentSelection,
        );
      } on AvatarSelectionException catch (error) {
        if (!_isDefinitelyUncommitted(error)) rethrow;
        await _outbox.discardDefinitelyUncommitted(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
        _observeOutbox(null);
        final authoritative = await _readCurrent(assetOptions);
        await local.restoreAuthoritative(authoritative);
        _publish(authoritative);
        return AvatarSelectionRecoveryResult(
          outcome: AvatarSelectionRecoveryOutcome.reconciledCurrent,
          current: authoritative,
        );
      }
    }

    if (entry.stage == AvatarSelectionOutboxStage.applied) {
      final applied = _snapshotFromReceipt(entry.appliedReceipt!);
      final authoritative = await _readCurrent(assetOptions);
      if (!authoritative.hasSameSemanticValue(applied)) {
        entry = _observeOutbox(
          await _outbox.markSuperseded(
            operationKey: entry.operationKey,
            expectedRevision: entry.recordRevision,
            reason: AvatarSelectionSupersededReason.currentChanged,
          ),
        );
        await local.restoreAuthoritative(authoritative);
        await _outbox.completeSuperseded(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
        _observeOutbox(null);
        _publish(authoritative);
        return AvatarSelectionRecoveryResult(
          outcome: AvatarSelectionRecoveryOutcome.superseded,
          current: authoritative,
        );
      }
      final resolution = await decide(entry);
      if (resolution == AvatarSelectionRecoveryResolution.rollForward) {
        try {
          await local.commitAuthoritative(applied);
        } on Object {
          entry = _observeOutbox(
            await _outbox.requestCompensation(
              operationKey: entry.operationKey,
              expectedRevision: entry.recordRevision,
            ),
          );
          await local.previewTarget();
          final compensation = await _compensate(entry, local);
          return AvatarSelectionRecoveryResult(
            outcome: compensation.$2
                ? AvatarSelectionRecoveryOutcome.superseded
                : AvatarSelectionRecoveryOutcome.compensated,
            current: compensation.$3,
          );
        }
        await _outbox.completeLocalCommit(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
        _observeOutbox(null);
        _publish(applied);
        return AvatarSelectionRecoveryResult(
          outcome: AvatarSelectionRecoveryOutcome.rolledForward,
          current: applied,
          committedSelection: _issueCommittedSelection(
            request: entry.request,
            receipt: entry.appliedReceipt!,
            compensationKey: entry.compensationKey,
          ),
        );
      }
      entry = _observeOutbox(
        await _outbox.requestCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        ),
      );
    }

    if (entry.stage == AvatarSelectionOutboxStage.compensateNeeded ||
        entry.stage == AvatarSelectionOutboxStage.compensating) {
      await local.previewTarget();
      final compensation = await _compensate(entry, local);
      return AvatarSelectionRecoveryResult(
        outcome: compensation.$2
            ? AvatarSelectionRecoveryOutcome.superseded
            : AvatarSelectionRecoveryOutcome.compensated,
        current: compensation.$3,
      );
    }

    throw StateError('avatar_selection_recovery_unreachable');
  });

  Future<AvatarSelectionRecoveryResult> compensateOutstanding({
    AvatarSelectionLocalPhases local = const AvatarSelectionLocalPhases(),
  }) => _serialize(AvatarSelectionObservedOperation.recovery, () async {
    final inspected = _observeOutbox(await _outbox.read());
    if (inspected == null) {
      final current = _current;
      if (!_currentProven || current == null) {
        throw StateError('avatar_selection_no_outstanding_operation');
      }
      return AvatarSelectionRecoveryResult(
        outcome: AvatarSelectionRecoveryOutcome.reconciledCurrent,
        current: current,
      );
    }
    var entry = inspected;
    _markCurrentUnproven();
    if (entry.stage == AvatarSelectionOutboxStage.prepared ||
        entry.stage == AvatarSelectionOutboxStage.applied) {
      entry = _observeOutbox(
        await _outbox.requestCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        ),
      );
    }
    if (entry.stage == AvatarSelectionOutboxStage.prepared) {
      try {
        final result = await _commitExact(
          entry: entry,
          request: entry.request,
          operation: AvatarSelectionRecoveryOperation.setReplay,
        );
        result.receipt.validateAgainst(entry.request);
        entry = _observeOutbox(
          await _outbox.recordApplied(
            operationKey: entry.operationKey,
            expectedRevision: entry.recordRevision,
            receipt: result.receipt,
          ),
        );
      } on AvatarSelectionVersionChangedException catch (error) {
        entry = _observeOutbox(
          await _outbox.markSuperseded(
            operationKey: entry.operationKey,
            expectedRevision: entry.recordRevision,
            reason: AvatarSelectionSupersededReason.setVersionConflict,
          ),
        );
        await local.restoreAuthoritative(error.currentSelection);
        await _outbox.completeSuperseded(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
        _observeOutbox(null);
        _publish(error.currentSelection);
        return AvatarSelectionRecoveryResult(
          outcome: AvatarSelectionRecoveryOutcome.superseded,
          current: error.currentSelection,
        );
      }
    }
    await local.previewTarget();
    final compensation = await _compensate(entry, local);
    return AvatarSelectionRecoveryResult(
      outcome: compensation.$2
          ? AvatarSelectionRecoveryOutcome.superseded
          : AvatarSelectionRecoveryOutcome.compensated,
      current: compensation.$3,
    );
  });

  Future<AvatarSelectionCoordinatorDrainResult> deactivateAndDrain({
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    final existing = _drainFuture;
    if (existing != null) return existing;
    _sealed = true;
    _observability.observeLifecycle(
      AvatarSelectionObservabilityLifecycle.sealing,
    );
    final observation = _observability.begin(
      AvatarSelectionObservedOperation.drain,
    );
    final draining = _runDrainAttempt(timeout).then(
      (result) {
        _observability.end(
          observation,
          outcome: result.fullyDrained
              ? AvatarSelectionObservedOutcome.succeeded
              : AvatarSelectionObservedOutcome.timedOut,
        );
        return result;
      },
      onError: (Object error, StackTrace stackTrace) {
        _observability.end(observation, outcome: _observedOutcome(error));
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _drainFuture = draining;
    return draining;
  }

  Future<AvatarSelectionCoordinatorDrainResult> _runDrainAttempt(
    Duration timeout,
  ) async {
    try {
      final result = await _drain(timeout);
      if (result.fullyDrained) {
        _observability.observeLifecycle(
          AvatarSelectionObservabilityLifecycle.retired,
        );
      }
      if (!result.fullyDrained) _drainFuture = null;
      return result;
    } catch (_) {
      _drainFuture = null;
      rethrow;
    }
  }

  Future<AvatarSelectionCoordinatorDrainResult> _drain(Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    var coordinatorDrained = true;
    try {
      await _tail.timeout(timeout);
    } on TimeoutException {
      coordinatorDrained = false;
    }

    final outboxDrain = _outbox.deactivateAndDrain();
    final remaining = timeout - stopwatch.elapsed;
    var outboxDrained = true;
    if (remaining <= Duration.zero) {
      outboxDrained = false;
    } else {
      try {
        await outboxDrain.timeout(remaining);
      } on TimeoutException {
        outboxDrained = false;
      }
    }
    return AvatarSelectionCoordinatorDrainResult(
      coordinatorDrained: coordinatorDrained,
      outboxDrained: outboxDrained,
    );
  }

  Future<AvatarSelectionSnapshot> _ensureCurrentInternal(
    AvatarSelectionAssetOptions assetOptions,
  ) async {
    final current = _current;
    if (_currentProven && current != null) return current;
    final authoritative = await _readCurrent(assetOptions);
    _publish(authoritative);
    return authoritative;
  }

  Future<void> _requireNoOutstandingObligation() async {
    final outstanding = _observeOutbox(await _outbox.inspectForRecovery());
    if (outstanding != null) {
      _markCurrentUnproven();
      throw AvatarSelectionOutstandingObligationException(outstanding.stage);
    }
  }

  Future<AvatarSelectionSnapshot> _readCurrent(
    AvatarSelectionAssetOptions assetOptions,
  ) async {
    final snapshot = await _transport.current(
      agentId: agentId,
      assetOptions: assetOptions,
    );
    _validateSnapshotAgent(snapshot);
    return snapshot;
  }

  Future<AvatarSelectionCommitResult> _commitExact({
    required AvatarSelectionOutboxEntry entry,
    required AvatarSelectionCommitRequest request,
    required AvatarSelectionRecoveryOperation operation,
    bool dispatchInitial = false,
  }) async {
    final claim = _recoveryClaim(
      entry: entry,
      request: request,
      operation: operation,
    );
    final observation = _observability.begin(
      AvatarSelectionObservedOperation.exactReplay,
    );
    var resultIsHistoricallyUnknown = !dispatchInitial;
    for (var attempt = 1; attempt <= maxAmbiguousAttempts; attempt += 1) {
      try {
        final result = dispatchInitial && attempt == 1
            ? await _transport.commit(request)
            : await _recoveryTransport.replay(claim);
        result.receipt.validateAgainst(request);
        _observability.end(
          observation,
          outcome: AvatarSelectionObservedOutcome.succeeded,
        );
        return result;
      } on AvatarSelectionVersionChangedException {
        // A typed CAS conflict proves this exact request does not own the
        // current head, even if an earlier response was lost.
        _observability.end(
          observation,
          outcome: AvatarSelectionObservedOutcome.versionConflict,
        );
        rethrow;
      } on AvatarSelectionAmbiguousTransportException {
        resultIsHistoricallyUnknown = true;
        if (attempt == maxAmbiguousAttempts || _sealed) {
          _observability.end(
            observation,
            outcome: AvatarSelectionObservedOutcome.ambiguousFailure,
          );
          rethrow;
        }
        _observability.retry(observation);
        try {
          await _retryDelay(attempt);
        } on Object catch (error, stackTrace) {
          _observability.end(observation, outcome: _observedOutcome(error));
          Error.throwWithStackTrace(error, stackTrace);
        }
      } on Object catch (error, stackTrace) {
        if (resultIsHistoricallyUnknown &&
            error is AvatarSelectionException &&
            _isDefinitelyUncommittedReplayResponse(error)) {
          _observability.end(
            observation,
            outcome: AvatarSelectionObservedOutcome.rejected,
          );
          rethrow;
        }
        if (!resultIsHistoricallyUnknown) {
          _observability.end(observation, outcome: _observedOutcome(error));
          rethrow;
        }
        _observability.end(
          observation,
          outcome: AvatarSelectionObservedOutcome.ambiguousFailure,
        );
        Error.throwWithStackTrace(
          AvatarSelectionAmbiguousTransportException(cause: error),
          stackTrace,
        );
      }
    }
    _observability.end(
      observation,
      outcome: AvatarSelectionObservedOutcome.failed,
    );
    throw StateError('avatar_selection_retry_unreachable');
  }

  Future<(AvatarSelectionReceipt?, bool, AvatarSelectionSnapshot)> _compensate(
    AvatarSelectionOutboxEntry entry,
    AvatarSelectionLocalPhases local,
  ) async {
    final observation = _observability.begin(
      AvatarSelectionObservedOperation.compensation,
    );
    try {
      if (entry.stage == AvatarSelectionOutboxStage.compensateNeeded) {
        entry = _observeOutbox(
          await _outbox.beginCompensation(
            operationKey: entry.operationKey,
            expectedRevision: entry.recordRevision,
          ),
        );
      }
      if (entry.stage != AvatarSelectionOutboxStage.compensating) {
        throw StateError('avatar_selection_compensation_not_ready');
      }

      final request = entry.compensationRequest;
      try {
        final result = await _commitExact(
          entry: entry,
          request: request,
          operation: AvatarSelectionRecoveryOperation.compensation,
        );
        result.receipt.validateAgainst(request);
        final authoritative = _snapshotFromReceipt(result.receipt);
        await local.restoreAuthoritative(authoritative);
        await _outbox.completeCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
          receipt: result.receipt,
        );
        _observeOutbox(null);
        _publish(authoritative);
        _observability.end(
          observation,
          outcome: AvatarSelectionObservedOutcome.compensated,
        );
        return (result.receipt, false, authoritative);
      } on AvatarSelectionVersionChangedException catch (error) {
        entry = _observeOutbox(
          await _outbox.markSuperseded(
            operationKey: entry.operationKey,
            expectedRevision: entry.recordRevision,
            reason: AvatarSelectionSupersededReason.compensationVersionConflict,
          ),
        );
        await local.restoreAuthoritative(error.currentSelection);
        await _outbox.completeSuperseded(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
        _observeOutbox(null);
        _publish(error.currentSelection);
        _observability.end(
          observation,
          outcome: AvatarSelectionObservedOutcome.superseded,
        );
        return (null, true, error.currentSelection);
      }
    } on Object catch (error, stackTrace) {
      _observability.end(observation, outcome: _observedOutcome(error));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  AvatarSelectionRecoveryClaim _recoveryClaim({
    required AvatarSelectionOutboxEntry entry,
    required AvatarSelectionCommitRequest request,
    required AvatarSelectionRecoveryOperation operation,
  }) {
    final valid = switch (operation) {
      AvatarSelectionRecoveryOperation.setReplay =>
        entry.stage == AvatarSelectionOutboxStage.prepared &&
            entry.request.hasSameSemanticValue(request),
      AvatarSelectionRecoveryOperation.compensation =>
        entry.stage == AvatarSelectionOutboxStage.compensating &&
            entry.compensationRequest.hasSameSemanticValue(request),
    };
    if (!valid ||
        entry.ownerGeneration != ownerGeneration ||
        request.agentId != agentId) {
      throw const AvatarSelectionOutboxConflictException(
        'avatar_selection_recovery_claim_invalid',
      );
    }
    return AvatarSelectionRecoveryClaim._(
      accountScopeDigest: entry.accountScopeDigest,
      agentScopeDigest: entry.agentScopeDigest,
      ownerGeneration: entry.ownerGeneration,
      recordRevision: entry.recordRevision,
      operation: operation,
      request: request,
    );
  }

  AvatarSelectionSnapshot _snapshotFromReceipt(
    AvatarSelectionReceipt receipt,
  ) => AvatarSelectionSnapshot(
    selection: receipt.selection,
    asset: receipt.asset,
    selectionAvailable: receipt.selectionAvailable,
  );

  void _publish(AvatarSelectionSnapshot snapshot) {
    _validateSnapshotAgent(snapshot);
    _current = snapshot;
    _currentProven = true;
    _observability.observeCurrent(
      proven: true,
      version: snapshot.selection.version,
    );
    _snapshots.add(snapshot);
  }

  void _markCurrentUnproven() {
    _currentProven = false;
    _observability.observeCurrent(
      proven: false,
      version: _current?.selection.version,
    );
  }

  T _observeOutbox<T extends AvatarSelectionOutboxEntry?>(T entry) {
    _observability.observeOutbox(entry);
    return entry;
  }

  void _validateSnapshotAgent(AvatarSelectionSnapshot snapshot) {
    if (snapshot.selection.agentId != agentId) {
      throw const FormatException(
        'avatar_selection_coordinator_agent_mismatch',
      );
    }
  }

  AvatarSelectionCommittedSelection _issueCommittedSelection({
    required AvatarSelectionCommitRequest request,
    required AvatarSelectionReceipt receipt,
    required String compensationKey,
  }) {
    receipt.validateAgainst(request);
    AvatarSelectionIdempotencyKey.validate(compensationKey);
    if (request.agentId != agentId ||
        compensationKey == request.idempotencyKey) {
      throw const FormatException(
        'avatar_selection_committed_evidence_invalid',
      );
    }
    return AvatarSelectionCommittedSelection._(
      issuer: _evidenceIssuer,
      request: request,
      receipt: receipt,
      compensationKey: compensationKey,
    );
  }

  void _validateCommittedSelection(AvatarSelectionCommittedSelection value) {
    if (!identical(value._issuer, _evidenceIssuer) ||
        value.request.agentId != agentId ||
        value.compensationKey == value.request.idempotencyKey) {
      throw const FormatException(
        'avatar_selection_committed_evidence_invalid',
      );
    }
    AvatarSelectionIdempotencyKey.validate(value.compensationKey);
    value.receipt.validateAgainst(value.request);
  }

  void _requireMatchingEvidence(
    AvatarSelectionOutboxEntry entry,
    AvatarSelectionCommittedSelection committed,
  ) {
    if (!entry.request.hasSameSemanticValue(committed.request) ||
        entry.compensationKey != committed.compensationKey ||
        !entry.previousSelection.hasSameSemanticValue(
          committed.receipt.previousSelection,
        ) ||
        (entry.appliedReceipt != null &&
            !entry.appliedReceipt!.hasSameSemanticValue(committed.receipt))) {
      throw const AvatarSelectionOutboxConflictException(
        'avatar_selection_retirement_evidence_mismatch',
      );
    }
  }

  String _newKey() =>
      AvatarSelectionIdempotencyKey.validate(_idempotencyKeyFactory());

  Future<T> _serialize<T>(
    AvatarSelectionObservedOperation observedOperation,
    Future<T> Function() operation,
  ) {
    if (_sealed) {
      _observability.record(
        operation: observedOperation,
        outcome: AvatarSelectionObservedOutcome.rejected,
        latency: Duration.zero,
      );
      return Future<T>.error(
        const AvatarSelectionCoordinatorUnavailableException(),
      );
    }
    final observation = _observability.begin(observedOperation);
    final result = _tail
        .then<T>((_) => operation())
        .then<T>(
          (value) {
            _observability.end(
              observation,
              outcome: _successfulObservedOutcome(value),
            );
            return value;
          },
          onError: (Object error, StackTrace stackTrace) {
            _observability.end(observation, outcome: _observedOutcome(error));
            Error.throwWithStackTrace(error, stackTrace);
          },
        );
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

AvatarSelectionObservedOutcome _observedOutcome(Object error) {
  if (error is AvatarSelectionVersionChangedException) {
    return AvatarSelectionObservedOutcome.versionConflict;
  }
  if (error is AvatarSelectionAmbiguousTransportException) {
    return AvatarSelectionObservedOutcome.ambiguousFailure;
  }
  if (error is AvatarSelectionCompensatedException ||
      error is AvatarSelectionLocalCommitCompensatedException) {
    return AvatarSelectionObservedOutcome.compensated;
  }
  if (error is AvatarSelectionCompensationSupersededException) {
    return AvatarSelectionObservedOutcome.superseded;
  }
  if (error is AvatarSelectionCoordinatorUnavailableException ||
      error is AvatarSelectionOutstandingObligationException) {
    return AvatarSelectionObservedOutcome.rejected;
  }
  if (error is TimeoutException) {
    return AvatarSelectionObservedOutcome.timedOut;
  }
  return AvatarSelectionObservedOutcome.failed;
}

AvatarSelectionObservedOutcome _successfulObservedOutcome(Object? value) {
  final recoveryOutcome = switch (value) {
    AvatarSelectionRecoveryResult result => result.outcome,
    AvatarSelectionRetirementResult result => result.outcome,
    _ => null,
  };
  return switch (recoveryOutcome) {
    AvatarSelectionRecoveryOutcome.reconciledCurrent =>
      AvatarSelectionObservedOutcome.noChange,
    AvatarSelectionRecoveryOutcome.rolledForward =>
      AvatarSelectionObservedOutcome.rolledForward,
    AvatarSelectionRecoveryOutcome.compensated =>
      AvatarSelectionObservedOutcome.compensated,
    AvatarSelectionRecoveryOutcome.superseded =>
      AvatarSelectionObservedOutcome.superseded,
    null => AvatarSelectionObservedOutcome.succeeded,
  };
}

bool _isDefinitelyUncommitted(AvatarSelectionException error) =>
    error is AvatarSelectionValidationException ||
    error is AvatarSelectionNotFoundException ||
    error is AvatarSelectionAuthorizationException ||
    error is AvatarSelectionVersionExhaustedException ||
    error is AvatarSelectionContractUnavailableException;

bool _isDefinitelyUncommittedReplayResponse(AvatarSelectionException error) =>
    error is AvatarSelectionValidationException ||
    error is AvatarSelectionNotFoundException ||
    error is AvatarSelectionVersionExhaustedException;

Future<void> _noRetryDelay(int _) async {}
