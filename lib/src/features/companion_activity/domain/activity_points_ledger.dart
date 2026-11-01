import 'companion_activity_models.dart';

enum ActivityPointsEntryKind { taskAward, virtualRedemption }

final class ActivityPointsEntry {
  const ActivityPointsEntry._({
    required this.id,
    required this.operationId,
    required this.scope,
    required this.kind,
    required this.delta,
    required this.referenceId,
    required this.recordedAt,
    this.taskId,
    this.evidenceId,
    this.redemptionRequestId,
  });

  final String id;
  final String operationId;
  final ActivityScope scope;
  final ActivityPointsEntryKind kind;
  final int delta;
  final String referenceId;
  final DateTime recordedAt;
  final String? taskId;
  final String? evidenceId;
  final String? redemptionRequestId;
}

enum ActivityLedgerMutationStatus { applied, alreadyApplied, rejected }

final class ActivityLedgerMutation {
  const ActivityLedgerMutation({
    required this.status,
    required this.ledger,
    this.entry,
    this.reason,
  });

  final ActivityLedgerMutationStatus status;
  final ActivityPointsLedger ledger;
  final ActivityPointsEntry? entry;
  final String? reason;
}

enum VirtualRewardKind { badge, avatarCosmetic, surfaceTheme, celebration }

enum RewardFulfillmentKind { virtualOnly }

final class VirtualReward {
  VirtualReward({
    required String id,
    required String title,
    required this.kind,
    required this.costPoints,
  }) : id = _boundedId(id, 'id'),
       title = _boundedText(title, 'title') {
    if (costPoints < 1 || costPoints > 1000000) {
      throw ArgumentError.value(costPoints, 'costPoints');
    }
  }

  final String id;
  final String title;
  final VirtualRewardKind kind;
  final int costPoints;
  RewardFulfillmentKind get fulfillment => RewardFulfillmentKind.virtualOnly;
}

final class VirtualRewardRedemptionRequest {
  VirtualRewardRedemptionRequest({
    required String id,
    required String operationId,
    required this.scope,
    required String rewardId,
    required this.requestedAt,
  }) : id = _boundedId(id, 'id'),
       operationId = _canonicalOperationId(operationId),
       rewardId = _boundedId(rewardId, 'rewardId');

  final String id;
  final String operationId;
  final ActivityScope scope;
  final String rewardId;
  final DateTime requestedAt;
}

final class VirtualRewardRedemptionReceipt {
  const VirtualRewardRedemptionReceipt({
    required this.id,
    required this.operationId,
    required this.scope,
    required this.rewardId,
    required this.debitedPoints,
    required this.redeemedAt,
  });

  final String id;
  final String operationId;
  final ActivityScope scope;
  final String rewardId;
  final int debitedPoints;
  final DateTime redeemedAt;
  RewardFulfillmentKind get fulfillment => RewardFulfillmentKind.virtualOnly;
}

enum ActivityRedemptionStatus { redeemed, alreadyRedeemed, rejected }

final class ActivityRedemptionResult {
  const ActivityRedemptionResult({
    required this.status,
    required this.ledger,
    this.receipt,
    this.reason,
  });

  final ActivityRedemptionStatus status;
  final ActivityPointsLedger ledger;
  final VirtualRewardRedemptionReceipt? receipt;
  final String? reason;
}

/// Immutable append-only points ledger.
///
/// Every successful mutation returns a new ledger snapshot. Callers cannot
/// edit existing entries or observe a partial redemption debit.
final class ActivityPointsLedger {
  ActivityPointsLedger._({
    required this.scope,
    required List<ActivityPointsEntry> entries,
  }) : entries = List<ActivityPointsEntry>.unmodifiable(entries);

  factory ActivityPointsLedger.empty(ActivityScope scope) =>
      ActivityPointsLedger._(scope: scope, entries: const []);

  final ActivityScope scope;
  final List<ActivityPointsEntry> entries;

  int get balance => entries.fold<int>(0, (sum, entry) => sum + entry.delta);

  ActivityLedgerMutation award({
    required String operationId,
    required ActivityScope scope,
    required ActivityTask task,
    required ActivityEvidence evidence,
    required DateTime recordedAt,
  }) {
    if (!_matches(scope) ||
        !scope.matches(task.scope) ||
        !scope.matches(evidence.scope)) {
      return ActivityLedgerMutation(
        status: ActivityLedgerMutationStatus.rejected,
        ledger: this,
        reason: 'activity_scope_mismatch',
      );
    }
    if (task.id != evidence.taskId ||
        evidence.reviewState != ActivityEvidenceReviewState.approved) {
      return ActivityLedgerMutation(
        status: ActivityLedgerMutationStatus.rejected,
        ledger: this,
        reason: 'evidence_not_approved_for_task',
      );
    }
    final normalizedOperationId = _canonicalOperationId(operationId);
    final replay = _entryForOperation(normalizedOperationId);
    if (replay != null) {
      final exact =
          replay.kind == ActivityPointsEntryKind.taskAward &&
          replay.taskId == task.id &&
          replay.evidenceId == evidence.id &&
          replay.delta == task.awardPoints;
      return ActivityLedgerMutation(
        status: exact
            ? ActivityLedgerMutationStatus.alreadyApplied
            : ActivityLedgerMutationStatus.rejected,
        ledger: this,
        entry: exact ? replay : null,
        reason: exact ? null : 'operation_replay_mismatch',
      );
    }
    if (_awardForTask(task.id) != null ||
        _awardForEvidence(evidence.id) != null) {
      return ActivityLedgerMutation(
        status: ActivityLedgerMutationStatus.rejected,
        ledger: this,
        reason: 'task_or_evidence_already_awarded',
      );
    }
    if (evidence.reviewedAt == null ||
        recordedAt.isBefore(evidence.reviewedAt!)) {
      return ActivityLedgerMutation(
        status: ActivityLedgerMutationStatus.rejected,
        ledger: this,
        reason: 'award_before_evidence_review',
      );
    }
    final entry = ActivityPointsEntry._(
      id: 'points-${entries.length + 1}',
      operationId: normalizedOperationId,
      scope: this.scope,
      kind: ActivityPointsEntryKind.taskAward,
      delta: task.awardPoints,
      referenceId: task.id,
      recordedAt: recordedAt,
      taskId: task.id,
      evidenceId: evidence.id,
    );
    return ActivityLedgerMutation(
      status: ActivityLedgerMutationStatus.applied,
      ledger: _append(entry),
      entry: entry,
    );
  }

  ActivityRedemptionResult redeem({
    required VirtualRewardRedemptionRequest request,
    required VirtualReward reward,
  }) {
    if (!_matches(request.scope)) {
      return ActivityRedemptionResult(
        status: ActivityRedemptionStatus.rejected,
        ledger: this,
        reason: 'activity_scope_mismatch',
      );
    }
    final replay = _entryForOperation(request.operationId);
    if (replay != null) {
      final exact =
          replay.kind == ActivityPointsEntryKind.virtualRedemption &&
          replay.redemptionRequestId == request.id &&
          replay.referenceId == reward.id &&
          replay.delta == -reward.costPoints &&
          request.rewardId == reward.id;
      return ActivityRedemptionResult(
        status: exact
            ? ActivityRedemptionStatus.alreadyRedeemed
            : ActivityRedemptionStatus.rejected,
        ledger: this,
        receipt: exact ? _receipt(request, replay) : null,
        reason: exact ? null : 'operation_replay_mismatch',
      );
    }
    if (request.rewardId != reward.id) {
      return ActivityRedemptionResult(
        status: ActivityRedemptionStatus.rejected,
        ledger: this,
        reason: 'reward_mismatch',
      );
    }
    if (balance < reward.costPoints) {
      return ActivityRedemptionResult(
        status: ActivityRedemptionStatus.rejected,
        ledger: this,
        reason: 'insufficient_points',
      );
    }
    final entry = ActivityPointsEntry._(
      id: 'points-${entries.length + 1}',
      operationId: request.operationId,
      scope: scope,
      kind: ActivityPointsEntryKind.virtualRedemption,
      delta: -reward.costPoints,
      referenceId: reward.id,
      recordedAt: request.requestedAt,
      redemptionRequestId: request.id,
    );
    final next = _append(entry);
    return ActivityRedemptionResult(
      status: ActivityRedemptionStatus.redeemed,
      ledger: next,
      receipt: next._receipt(request, entry),
    );
  }

  ActivityPointsLedger _append(ActivityPointsEntry entry) =>
      ActivityPointsLedger._(
        scope: scope,
        entries: <ActivityPointsEntry>[...entries, entry],
      );

  ActivityPointsEntry? _entryForOperation(String operationId) {
    for (final entry in entries) {
      if (entry.operationId == operationId) return entry;
    }
    return null;
  }

  ActivityPointsEntry? _awardForTask(String taskId) {
    for (final entry in entries) {
      if (entry.kind == ActivityPointsEntryKind.taskAward &&
          entry.taskId == taskId) {
        return entry;
      }
    }
    return null;
  }

  ActivityPointsEntry? _awardForEvidence(String evidenceId) {
    for (final entry in entries) {
      if (entry.kind == ActivityPointsEntryKind.taskAward &&
          entry.evidenceId == evidenceId) {
        return entry;
      }
    }
    return null;
  }

  VirtualRewardRedemptionReceipt _receipt(
    VirtualRewardRedemptionRequest request,
    ActivityPointsEntry entry,
  ) => VirtualRewardRedemptionReceipt(
    id: request.id,
    operationId: entry.operationId,
    scope: scope,
    rewardId: entry.referenceId,
    debitedPoints: -entry.delta,
    redeemedAt: entry.recordedAt,
  );

  bool _matches(ActivityScope candidate) => scope.matches(candidate);
}

String _boundedId(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 128 ||
      !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(normalized)) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

String _canonicalOperationId(String value) {
  if (value != value.trim() ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'operationId');
  }
  return value;
}

String _boundedText(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 200) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}
