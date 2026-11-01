import 'activity_evidence_privacy.dart';

final class ActivityScope {
  ActivityScope({required String accountId, required this.facadeGeneration})
    : accountId = _boundedText(accountId, 'accountId', maxLength: 256) {
    if (facadeGeneration < 1) {
      throw ArgumentError.value(facadeGeneration, 'facadeGeneration');
    }
  }

  final String accountId;
  final int facadeGeneration;

  bool matches(ActivityScope other) =>
      accountId == other.accountId &&
      facadeGeneration == other.facadeGeneration;
}

enum ActivityCadence { daily, challenge, surprise }

enum ActivityTaskState { available, evidenceSubmitted, completed, expired }

final class ActivityTaskTemplate {
  ActivityTaskTemplate({
    required String id,
    required this.scope,
    required String title,
    required this.cadence,
    required this.defaultAwardPoints,
    List<String> tags = const <String>[],
  }) : id = _boundedText(id, 'id'),
       title = _boundedText(title, 'title', maxLength: 200),
       tags = List<String>.unmodifiable(
         tags.map((tag) => _boundedText(tag, 'tag', maxLength: 64)),
       ) {
    _requirePoints(defaultAwardPoints, 'defaultAwardPoints');
  }

  final String id;
  final ActivityScope scope;
  final String title;
  final ActivityCadence cadence;
  final int defaultAwardPoints;
  final List<String> tags;
}

/// Immutable occurrence generated from a separately stored task template.
final class ActivityTask {
  ActivityTask({
    required String id,
    required String templateId,
    required this.scope,
    required this.cadence,
    required String title,
    required this.awardPoints,
    required this.availableAt,
    required this.dueAt,
    this.state = ActivityTaskState.available,
  }) : id = _boundedText(id, 'id'),
       templateId = _boundedText(templateId, 'templateId'),
       title = _boundedText(title, 'title', maxLength: 200) {
    _requirePoints(awardPoints, 'awardPoints');
    if (dueAt.isBefore(availableAt)) {
      throw ArgumentError('dueAt must not be before availableAt');
    }
  }

  final String id;
  final String templateId;
  final ActivityScope scope;
  final ActivityCadence cadence;
  final String title;
  final int awardPoints;
  final DateTime availableAt;
  final DateTime dueAt;
  final ActivityTaskState state;

  ActivityTask withState(ActivityTaskState next) => ActivityTask(
    id: id,
    templateId: templateId,
    scope: scope,
    cadence: cadence,
    title: title,
    awardPoints: awardPoints,
    availableAt: availableAt,
    dueAt: dueAt,
    state: next,
  );
}

enum ActivityEvidenceReviewState { pending, approved, rejected }

enum ActivityEvidenceAdmissionStatus { accepted, rejected }

final class ActivityEvidenceAdmission {
  const ActivityEvidenceAdmission._({
    required this.status,
    this.evidence,
    this.reason,
  });

  const ActivityEvidenceAdmission.accepted(ActivityEvidence evidence)
    : this._(
        status: ActivityEvidenceAdmissionStatus.accepted,
        evidence: evidence,
      );

  const ActivityEvidenceAdmission.rejected(String reason)
    : this._(status: ActivityEvidenceAdmissionStatus.rejected, reason: reason);

  final ActivityEvidenceAdmissionStatus status;
  final ActivityEvidence? evidence;
  final String? reason;
}

/// Immutable reference to a privacy-transformed evidence artifact.
final class ActivityEvidence {
  ActivityEvidence._({
    required this.id,
    required this.taskId,
    required this.scope,
    required this.artifact,
    required this.privacyReceiptId,
    required this.submittedAt,
    required this.reviewState,
    this.reviewedAt,
  });

  final String id;
  final String taskId;
  final ActivityScope scope;
  final ActivityEvidenceArtifact artifact;
  final String privacyReceiptId;
  final DateTime submittedAt;
  final ActivityEvidenceReviewState reviewState;
  final DateTime? reviewedAt;

  static ActivityEvidenceAdmission admit({
    required String id,
    required ActivityTask task,
    required ActivityScope scope,
    required ActivityEvidenceArtifact artifact,
    required ActivityEvidencePrivacyReceipt privacyReceipt,
    required DateTime submittedAt,
    ActivityEvidencePrivacyPolicy privacyPolicy =
        const ActivityEvidencePrivacyPolicy(),
  }) {
    if (!scope.matches(task.scope)) {
      return const ActivityEvidenceAdmission.rejected(
        'activity_scope_mismatch',
      );
    }
    final privacyIssue = privacyPolicy.diagnoseArtifact(artifact);
    if (privacyIssue != null) {
      return ActivityEvidenceAdmission.rejected(privacyIssue);
    }
    try {
      return ActivityEvidenceAdmission.accepted(
        ActivityEvidence._(
          id: _boundedText(id, 'id'),
          taskId: task.id,
          scope: scope,
          artifact: artifact,
          privacyReceiptId: privacyReceipt.id,
          submittedAt: submittedAt,
          reviewState: ActivityEvidenceReviewState.pending,
        ),
      );
    } on ArgumentError {
      return const ActivityEvidenceAdmission.rejected('evidence_id_invalid');
    }
  }

  /// Rehydrates metadata that already crossed the service's transactional
  /// privacy-verification boundary. This does not convey mutation authority.
  static ActivityEvidence restorePersisted({
    required String id,
    required String taskId,
    required ActivityScope scope,
    required ActivityEvidenceArtifact artifact,
    required String privacyReceiptId,
    required DateTime submittedAt,
    required ActivityEvidenceReviewState reviewState,
    DateTime? reviewedAt,
  }) => ActivityEvidence._(
    id: _boundedText(id, 'id'),
    taskId: _boundedText(taskId, 'taskId'),
    scope: scope,
    artifact: artifact,
    privacyReceiptId: _boundedText(privacyReceiptId, 'privacyReceiptId'),
    submittedAt: submittedAt.toUtc(),
    reviewState: reviewState,
    reviewedAt: reviewedAt?.toUtc(),
  );

  ActivityEvidence review({
    required ActivityScope scope,
    required ActivityEvidenceReviewState decision,
    required DateTime reviewedAt,
  }) {
    if (!scope.matches(this.scope)) {
      throw StateError('activity_scope_mismatch');
    }
    if (decision == ActivityEvidenceReviewState.pending) {
      throw ArgumentError.value(decision, 'decision');
    }
    if (reviewState != ActivityEvidenceReviewState.pending) {
      throw StateError('evidence_already_reviewed');
    }
    if (reviewedAt.isBefore(submittedAt)) {
      throw ArgumentError.value(reviewedAt, 'reviewedAt');
    }
    return ActivityEvidence._(
      id: id,
      taskId: taskId,
      scope: this.scope,
      artifact: artifact,
      privacyReceiptId: privacyReceiptId,
      submittedAt: submittedAt,
      reviewState: decision,
      reviewedAt: reviewedAt,
    );
  }
}

String _boundedText(String value, String field, {int maxLength = 128}) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

void _requirePoints(int value, String field) {
  if (value < 1 || value > 1000000) {
    throw ArgumentError.value(value, field);
  }
}
