import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_host_authority.dart';
import 'package:maaso/src/features/companion_activity/data/companion_activity_store.dart';
import 'package:maaso/src/features/companion_activity/domain/activity_evidence_privacy.dart';
import 'package:maaso/src/features/companion_activity/domain/activity_points_ledger.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';
import 'package:timezone/timezone.dart' as tz;

typedef ActivityTimeZoneResolver = tz.Location Function(String timeZoneId);
typedef CompanionActivityRolloutReader = FeatureRolloutMode Function();
typedef CompanionActivityRolloutGenerationReader = int Function();

enum CompanionActivityMutationStatus {
  applied,
  alreadyApplied,
  rejected,
  unavailable,
}

final class CompanionActivityMutationResult<T> {
  const CompanionActivityMutationResult({
    required this.status,
    this.value,
    this.reason,
  });

  final CompanionActivityMutationStatus status;
  final T? value;
  final String? reason;
}

final class ActivityLocalDate implements Comparable<ActivityLocalDate> {
  ActivityLocalDate(this.year, this.month, this.day) {
    final checked = DateTime.utc(year, month, day);
    if (checked.year != year || checked.month != month || checked.day != day) {
      throw ArgumentError.value(toString(), 'localDate');
    }
  }

  factory ActivityLocalDate.parse(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) throw FormatException('invalid activity local date');
    return ActivityLocalDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  final int year;
  final int month;
  final int day;

  ActivityLocalDate addDays(int days) {
    final next = DateTime.utc(year, month, day).add(Duration(days: days));
    return ActivityLocalDate(next.year, next.month, next.day);
  }

  @override
  int compareTo(ActivityLocalDate other) => DateTime.utc(
    year,
    month,
    day,
  ).compareTo(DateTime.utc(other.year, other.month, other.day));

  @override
  bool operator ==(Object other) =>
      other is ActivityLocalDate &&
      year == other.year &&
      month == other.month &&
      day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

/// Daily wall-clock schedule with an explicit IANA-first timezone policy.
///
/// [offsetAtCreationMinutes] is an audit/fence value for the first occurrence,
/// never a fixed-offset recurrence rule. Future occurrences always resolve
/// through [timeZoneId], so DST changes are preserved. A missing IANA zone
/// fails closed. A spring-forward gap is normalized to the first representable
/// wall time chosen by `timezone`; a fall-back overlap chooses the earlier UTC
/// instant matching the requested wall time.
final class ActivityRecurrenceRule {
  ActivityRecurrenceRule({
    required String timeZoneId,
    required this.offsetAtCreationMinutes,
    required this.localStartMinute,
    required this.firstLocalDate,
    this.availabilityWindow = const Duration(hours: 12),
    this.makeUpWindow = const Duration(hours: 24),
  }) : timeZoneId = _boundedText(timeZoneId, 'timeZoneId', 128) {
    if (!RegExp(r'^[A-Za-z0-9_+\-/]+$').hasMatch(this.timeZoneId)) {
      throw ArgumentError.value(timeZoneId, 'timeZoneId');
    }
    if (offsetAtCreationMinutes < -14 * 60 ||
        offsetAtCreationMinutes > 14 * 60) {
      throw ArgumentError.value(
        offsetAtCreationMinutes,
        'offsetAtCreationMinutes',
      );
    }
    if (localStartMinute < 0 || localStartMinute >= 24 * 60) {
      throw ArgumentError.value(localStartMinute, 'localStartMinute');
    }
    if (availabilityWindow < const Duration(minutes: 1) ||
        availabilityWindow > const Duration(days: 1)) {
      throw ArgumentError.value(availabilityWindow, 'availabilityWindow');
    }
    if (makeUpWindow.isNegative || makeUpWindow > maxMakeUpWindow) {
      throw ArgumentError.value(makeUpWindow, 'makeUpWindow');
    }
  }

  static const Duration maxMakeUpWindow = Duration(hours: 48);

  final String timeZoneId;
  final int offsetAtCreationMinutes;
  final int localStartMinute;
  final ActivityLocalDate firstLocalDate;
  final Duration availabilityWindow;
  final Duration makeUpWindow;

  ActivityOccurrenceWindow resolve(
    ActivityLocalDate date,
    ActivityTimeZoneResolver resolver,
  ) {
    late final tz.Location location;
    try {
      location = resolver(timeZoneId);
    } on Object {
      throw StateError('activity_timezone_unavailable');
    }
    final hour = localStartMinute ~/ 60;
    final minute = localStartMinute % 60;
    final direct = tz.TZDateTime(
      location,
      date.year,
      date.month,
      date.day,
      hour,
      minute,
    );
    final candidates = <tz.TZDateTime>[];
    for (var deltaMinutes = -180; deltaMinutes <= 180; deltaMinutes++) {
      final candidate = tz.TZDateTime.from(
        direct.toUtc().add(Duration(minutes: deltaMinutes)),
        location,
      );
      if (candidate.year == date.year &&
          candidate.month == date.month &&
          candidate.day == date.day &&
          candidate.hour == hour &&
          candidate.minute == minute) {
        candidates.add(candidate);
      }
    }
    candidates.sort((left, right) => left.toUtc().compareTo(right.toUtc()));
    final available = candidates.isEmpty ? direct : candidates.first;
    return ActivityOccurrenceWindow(
      localDate: date,
      timeZoneId: timeZoneId,
      offsetMinutes: available.timeZoneOffset.inMinutes,
      availableAt: available.toUtc(),
      dueAt: available.toUtc().add(availabilityWindow),
      makeUpDeadline: available
          .toUtc()
          .add(availabilityWindow)
          .add(makeUpWindow),
      resolvedLocalHour: available.hour,
      resolvedLocalMinute: available.minute,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'timeZoneId': timeZoneId,
    'offsetAtCreationMinutes': offsetAtCreationMinutes,
    'localStartMinute': localStartMinute,
    'firstLocalDate': firstLocalDate.toString(),
    'availabilityWindowMs': availabilityWindow.inMilliseconds,
    'makeUpWindowMs': makeUpWindow.inMilliseconds,
  };

  factory ActivityRecurrenceRule.fromJson(Map<String, Object?> json) =>
      ActivityRecurrenceRule(
        timeZoneId: _string(json, 'timeZoneId'),
        offsetAtCreationMinutes: _integer(json, 'offsetAtCreationMinutes'),
        localStartMinute: _integer(json, 'localStartMinute'),
        firstLocalDate: ActivityLocalDate.parse(
          _string(json, 'firstLocalDate'),
        ),
        availabilityWindow: Duration(
          milliseconds: _integer(json, 'availabilityWindowMs'),
        ),
        makeUpWindow: Duration(milliseconds: _integer(json, 'makeUpWindowMs')),
      );
}

final class ActivityOccurrenceWindow {
  const ActivityOccurrenceWindow({
    required this.localDate,
    required this.timeZoneId,
    required this.offsetMinutes,
    required this.availableAt,
    required this.dueAt,
    required this.makeUpDeadline,
    required this.resolvedLocalHour,
    required this.resolvedLocalMinute,
  });

  final ActivityLocalDate localDate;
  final String timeZoneId;
  final int offsetMinutes;
  final DateTime availableAt;
  final DateTime dueAt;
  final DateTime makeUpDeadline;
  final int resolvedLocalHour;
  final int resolvedLocalMinute;
}

final class ActivityStreakSnapshot {
  const ActivityStreakSnapshot({
    required this.current,
    required this.longest,
    required this.asOf,
    required this.completedDates,
  });

  final int current;
  final int longest;
  final ActivityLocalDate asOf;
  final List<ActivityLocalDate> completedDates;
}

final class CompanionActivitySnapshot {
  const CompanionActivitySnapshot({
    required this.templates,
    required this.tasks,
    required this.evidence,
    required this.ledger,
  });

  final List<ActivityTaskTemplate> templates;
  final List<ActivityTask> tasks;
  final List<ActivityEvidence> evidence;
  final ActivityPointsLedger ledger;
}

/// Transactional application owner for the companion-activity lifecycle.
final class CompanionActivityService extends AppService {
  CompanionActivityService({
    required CompanionActivityStore store,
    ActivityTimeZoneResolver? timeZoneResolver,
    CompanionActivityRolloutReader? rolloutMode,
    CompanionActivityRolloutGenerationReader? rolloutGeneration,
    CompanionActivityHostGrantVerifier? hostGrantVerifier,
    ActivityEvidencePrivacyReceiptVerifier? privacyReceiptVerifier,
    DateTime Function()? clock,
  }) : _store = store,
       _scope = store.scope,
       _timeZoneResolver = timeZoneResolver ?? tz.getLocation,
       _rolloutMode = rolloutMode ?? _disabledCompanionActivityRollout,
       _rolloutGeneration = rolloutGeneration ?? _initialRolloutGeneration,
       _hostGrantVerifier = hostGrantVerifier,
       _privacyReceiptVerifier = privacyReceiptVerifier,
       _clock = clock ?? DateTime.now;

  final CompanionActivityStore _store;
  final ActivityScope _scope;
  final ActivityTimeZoneResolver _timeZoneResolver;
  final CompanionActivityRolloutReader _rolloutMode;
  final CompanionActivityRolloutGenerationReader _rolloutGeneration;
  final CompanionActivityHostGrantVerifier? _hostGrantVerifier;
  final ActivityEvidencePrivacyReceiptVerifier? _privacyReceiptVerifier;
  final DateTime Function() _clock;
  final Set<Future<void>> _operations = <Future<void>>{};
  bool _active = true;
  Future<void>? _drainFuture;

  ActivityScope get scope => _scope;

  CompanionActivityHostMutationBinding submitEvidenceBinding({
    required String operationId,
    required String evidenceId,
    required String taskId,
    required ActivityEvidenceArtifact artifact,
    required ActivityEvidencePrivacyReceipt privacyReceipt,
    required DateTime submittedAt,
  }) => CompanionActivityHostMutationBinding(
    kind: CompanionActivityHostMutationKind.submitEvidence,
    scope: _scope,
    rolloutGeneration: _safeRolloutGeneration(),
    operationId: operationId,
    payloadDigest: _fingerprint(<Object?>[
      'submitEvidence',
      _boundedId(evidenceId, 'evidenceId'),
      _boundedId(taskId, 'taskId'),
      _artifactJson(artifact),
      privacyReceipt.id,
      privacyReceipt.derivedSha256,
      submittedAt.toUtc().toIso8601String(),
    ]),
  );

  CompanionActivityHostMutationBinding reviewEvidenceBinding({
    required String operationId,
    required String evidenceId,
    required ActivityEvidenceReviewState decision,
    required DateTime reviewedAt,
  }) => CompanionActivityHostMutationBinding(
    kind: CompanionActivityHostMutationKind.reviewEvidence,
    scope: _scope,
    rolloutGeneration: _safeRolloutGeneration(),
    operationId: operationId,
    payloadDigest: _fingerprint(<Object?>[
      'reviewEvidence',
      _boundedId(evidenceId, 'evidenceId'),
      decision.name,
      reviewedAt.toUtc().toIso8601String(),
    ]),
  );

  CompanionActivityHostMutationBinding redeemBinding({
    required VirtualRewardRedemptionRequest request,
    required VirtualReward reward,
  }) => CompanionActivityHostMutationBinding(
    kind: CompanionActivityHostMutationKind.redeemReward,
    scope: _scope,
    rolloutGeneration: _safeRolloutGeneration(),
    operationId: request.operationId,
    payloadDigest: _fingerprint(<Object?>[
      'redeem',
      request.id,
      canonicalActivityOperationId(request.operationId),
      request.rewardId,
      request.requestedAt.toUtc().toIso8601String(),
      reward.id,
      reward.title,
      reward.kind.name,
      reward.costPoints,
    ]),
  );

  Future<CompanionActivityMutationResult<ActivityTaskTemplate>>
  registerTemplate({
    required String operationId,
    required ActivityTaskTemplate template,
    required ActivityRecurrenceRule recurrence,
  }) => _mutate(() {
    if (!_scope.matches(template.scope)) {
      return Future<
        CompanionActivityMutationResult<ActivityTaskTemplate>
      >.value(_rejected('activity_scope_mismatch'));
    }
    late final ActivityOccurrenceWindow first;
    try {
      first = recurrence.resolve(recurrence.firstLocalDate, _timeZoneResolver);
    } on Object {
      return Future<
        CompanionActivityMutationResult<ActivityTaskTemplate>
      >.value(_rejected('activity_timezone_unavailable'));
    }
    if (first.offsetMinutes != recurrence.offsetAtCreationMinutes) {
      return Future<
        CompanionActivityMutationResult<ActivityTaskTemplate>
      >.value(_rejected('activity_timezone_offset_mismatch'));
    }
    final fingerprint = _fingerprint(<Object?>[
      'registerTemplate',
      _templateJson(template),
      recurrence.toJson(),
    ]);
    return _transaction(operationId, fingerprint, (document, canonicalId) {
      final replay = document.replay(canonicalId, fingerprint);
      if (replay != null) {
        return _alreadyApplied(document.template(template.id));
      }
      if (document.templates.containsKey(template.id)) {
        return _rejected('activity_template_exists');
      }
      document.templates[template.id] = _TemplateRecord(
        template: template,
        recurrence: recurrence,
      );
      document.record(canonicalId, fingerprint, 'template', template.id);
      return _applied(template);
    });
  });

  Future<CompanionActivityMutationResult<ActivityTask>> createOccurrence({
    required String operationId,
    required String templateId,
    required ActivityLocalDate localDate,
  }) => _mutate(() {
    final normalizedTemplateId = _boundedId(templateId, 'templateId');
    final fingerprint = _fingerprint(<Object?>[
      'createOccurrence',
      normalizedTemplateId,
      localDate.toString(),
    ]);
    return _transaction(operationId, fingerprint, (document, canonicalId) {
      final templateRecord = document.templates[normalizedTemplateId];
      if (templateRecord == null) {
        return _rejected('activity_template_missing');
      }
      final cadenceIssue = _cadenceIssue(
        templateRecord.template.cadence,
        templateRecord.recurrence.firstLocalDate,
        localDate,
      );
      if (cadenceIssue != null) return _rejected(cadenceIssue);
      final taskId = _occurrenceId(normalizedTemplateId, localDate);
      final replay = document.replay(canonicalId, fingerprint);
      if (replay != null) return _alreadyApplied(document.task(taskId));
      if (document.tasks.containsKey(taskId)) {
        return _rejected('activity_occurrence_exists');
      }
      late final ActivityOccurrenceWindow window;
      try {
        window = templateRecord.recurrence.resolve(
          localDate,
          _timeZoneResolver,
        );
      } on Object {
        return _rejected('activity_timezone_unavailable');
      }
      final task = ActivityTask(
        id: taskId,
        templateId: templateRecord.template.id,
        scope: _scope,
        cadence: templateRecord.template.cadence,
        title: templateRecord.template.title,
        awardPoints: templateRecord.template.defaultAwardPoints,
        availableAt: window.availableAt,
        dueAt: window.dueAt,
      );
      document.tasks[task.id] = _TaskRecord(
        task: task,
        localDate: localDate,
        makeUpDeadline: window.makeUpDeadline,
        timeZoneId: window.timeZoneId,
        offsetMinutes: window.offsetMinutes,
      );
      document.record(canonicalId, fingerprint, 'task', task.id);
      return _applied(task);
    });
  });

  Future<CompanionActivityMutationResult<ActivityEvidence>> submitEvidence({
    required CompanionActivityHostGrant hostGrant,
    required String operationId,
    required String evidenceId,
    required String taskId,
    required ActivityEvidenceArtifact artifact,
    required ActivityEvidencePrivacyReceipt privacyReceipt,
    required DateTime submittedAt,
  }) => _mutate(() {
    final normalizedEvidenceId = _boundedId(evidenceId, 'evidenceId');
    final normalizedTaskId = _boundedId(taskId, 'taskId');
    final submitted = submittedAt.toUtc();
    final binding = submitEvidenceBinding(
      operationId: operationId,
      evidenceId: normalizedEvidenceId,
      taskId: normalizedTaskId,
      artifact: artifact,
      privacyReceipt: privacyReceipt,
      submittedAt: submitted,
    );
    final fingerprint = binding.payloadDigest;
    return _transaction(
      operationId,
      fingerprint,
      (document, canonicalId) {
        final replay = document.replay(canonicalId, fingerprint);
        if (replay != null) {
          return _alreadyApplied(document.evidenceById(normalizedEvidenceId));
        }
        final taskRecord = document.tasks[normalizedTaskId];
        if (taskRecord == null) return _rejected('activity_task_missing');
        if (taskRecord.task.state == ActivityTaskState.completed ||
            taskRecord.task.state == ActivityTaskState.expired) {
          return _rejected('activity_task_not_accepting_evidence');
        }
        if (submitted.isBefore(taskRecord.task.availableAt.toUtc()) ||
            submitted.isAfter(taskRecord.makeUpDeadline.toUtc())) {
          return _rejected('activity_makeup_window_closed');
        }
        if (document.evidence.containsKey(normalizedEvidenceId)) {
          return _rejected('activity_evidence_exists');
        }
        if (document.evidence.values.any(
          (record) => record.privacyReceiptId == privacyReceipt.id,
        )) {
          return _rejected('evidence_privacy_receipt_replayed');
        }
        if (document.evidence.values.any(
          (record) =>
              record.taskId == normalizedTaskId &&
              record.reviewState == ActivityEvidenceReviewState.pending,
        )) {
          return _rejected('activity_evidence_pending');
        }
        final admission = ActivityEvidence.admit(
          id: normalizedEvidenceId,
          task: taskRecord.task,
          scope: _scope,
          artifact: artifact,
          privacyReceipt: privacyReceipt,
          submittedAt: submitted,
        );
        final evidence = admission.evidence;
        if (evidence == null) {
          return _rejected(admission.reason ?? 'activity_evidence_rejected');
        }
        document.evidence[evidence.id] = _EvidenceRecord(
          evidenceId: evidence.id,
          taskId: evidence.taskId,
          artifact: artifact,
          privacyReceiptId: privacyReceipt.id,
          submittedAt: submitted,
          reviewState: ActivityEvidenceReviewState.pending,
        );
        document.tasks[normalizedTaskId] = taskRecord.withState(
          ActivityTaskState.evidenceSubmitted,
        );
        document.record(canonicalId, fingerprint, 'evidence', evidence.id);
        return _applied(evidence);
      },
      authorize: (isReplay) {
        final hostVerifier = _hostGrantVerifier;
        final privacyVerifier = _privacyReceiptVerifier;
        if (hostVerifier == null || privacyVerifier == null) return false;
        if (!hostVerifier.consume(
          grant: hostGrant,
          binding: binding,
          now: _clock(),
        )) {
          return false;
        }
        return isReplay ||
            privacyVerifier.consume(
              receipt: privacyReceipt,
              artifact: artifact,
              accountId: _scope.accountId,
              facadeGeneration: _scope.facadeGeneration,
              admittedAt: submitted,
            );
      },
    );
  });

  Future<CompanionActivityMutationResult<ActivityEvidence>> reviewEvidence({
    required CompanionActivityHostGrant hostGrant,
    required String operationId,
    required String evidenceId,
    required ActivityEvidenceReviewState decision,
    required DateTime reviewedAt,
  }) => _mutate(() {
    if (decision == ActivityEvidenceReviewState.pending) {
      return Future<CompanionActivityMutationResult<ActivityEvidence>>.value(
        _rejected('activity_review_decision_invalid'),
      );
    }
    final normalizedEvidenceId = _boundedId(evidenceId, 'evidenceId');
    final reviewed = reviewedAt.toUtc();
    final binding = reviewEvidenceBinding(
      operationId: operationId,
      evidenceId: normalizedEvidenceId,
      decision: decision,
      reviewedAt: reviewed,
    );
    final fingerprint = binding.payloadDigest;
    return _transaction(
      operationId,
      fingerprint,
      (document, canonicalId) {
        final replay = document.replay(canonicalId, fingerprint);
        if (replay != null) {
          return _alreadyApplied(document.evidenceById(normalizedEvidenceId));
        }
        final evidenceRecord = document.evidence[normalizedEvidenceId];
        if (evidenceRecord == null) {
          return _rejected('activity_evidence_missing');
        }
        if (evidenceRecord.reviewState != ActivityEvidenceReviewState.pending) {
          return _rejected('activity_evidence_already_reviewed');
        }
        final taskRecord = document.tasks[evidenceRecord.taskId];
        if (taskRecord == null ||
            taskRecord.task.state != ActivityTaskState.evidenceSubmitted) {
          return _rejected('activity_task_state_invalid');
        }
        late final ActivityEvidence reviewedEvidence;
        try {
          reviewedEvidence = evidenceRecord
              .toDomain(document, _scope)
              .review(scope: _scope, decision: decision, reviewedAt: reviewed);
        } on Object {
          return _rejected('activity_review_invalid');
        }
        document.evidence[normalizedEvidenceId] = evidenceRecord.reviewed(
          decision,
          reviewed,
        );
        if (decision == ActivityEvidenceReviewState.approved) {
          final ledger = document.buildLedger(_scope);
          final awardOperationId = _derivedOperationId('award', canonicalId);
          final award = ledger.award(
            operationId: awardOperationId,
            scope: _scope,
            task: taskRecord.task,
            evidence: reviewedEvidence,
            recordedAt: reviewed,
          );
          if (award.status != ActivityLedgerMutationStatus.applied) {
            return _rejected(award.reason ?? 'activity_award_rejected');
          }
          document.ledgerOperations.add(
            _AwardRecord(
              operationId: awardOperationId,
              taskId: taskRecord.task.id,
              evidenceId: reviewedEvidence.id,
              recordedAt: reviewed,
            ),
          );
          document.tasks[taskRecord.task.id] = taskRecord.withState(
            ActivityTaskState.completed,
          );
        }
        document.record(
          canonicalId,
          fingerprint,
          'review',
          normalizedEvidenceId,
        );
        return _applied(reviewedEvidence);
      },
      authorize: (_) =>
          _hostGrantVerifier?.consume(
            grant: hostGrant,
            binding: binding,
            now: _clock(),
          ) ??
          false,
    );
  });

  Future<CompanionActivityMutationResult<VirtualRewardRedemptionReceipt>>
  redeem({
    required CompanionActivityHostGrant hostGrant,
    required VirtualRewardRedemptionRequest request,
    required VirtualReward reward,
  }) => _mutate(() {
    if (!_scope.matches(request.scope)) {
      return Future<
        CompanionActivityMutationResult<VirtualRewardRedemptionReceipt>
      >.value(_rejected('activity_scope_mismatch'));
    }
    final binding = redeemBinding(request: request, reward: reward);
    final fingerprint = binding.payloadDigest;
    return _transaction(
      request.operationId,
      fingerprint,
      (document, canonicalId) {
        final replay = document.replay(canonicalId, fingerprint);
        if (replay != null) {
          return _alreadyApplied(
            document.redemptionReceipt(canonicalId, _scope),
          );
        }
        final ledger = document.buildLedger(_scope);
        final result = ledger.redeem(request: request, reward: reward);
        final receipt = result.receipt;
        if (result.status != ActivityRedemptionStatus.redeemed ||
            receipt == null) {
          return _rejected(result.reason ?? 'activity_redemption_rejected');
        }
        document.ledgerOperations.add(
          _RedemptionRecord(request: request, reward: reward),
        );
        document.record(canonicalId, fingerprint, 'redemption', canonicalId);
        return _applied(receipt);
      },
      authorize: (_) =>
          _hostGrantVerifier?.consume(
            grant: hostGrant,
            binding: binding,
            now: _clock(),
          ) ??
          false,
    );
  });

  Future<CompanionActivityMutationResult<int>> expireDueTasks({
    required String operationId,
    required DateTime at,
  }) => _mutate(() {
    final instant = at.toUtc();
    final fingerprint = _fingerprint(<Object?>[
      'expireDueTasks',
      instant.toIso8601String(),
    ]);
    return _transaction(operationId, fingerprint, (document, canonicalId) {
      final replay = document.replay(canonicalId, fingerprint);
      if (replay != null) {
        return _alreadyApplied(int.parse(replay.entityId));
      }
      var expired = 0;
      for (final entry in document.tasks.entries.toList(growable: false)) {
        final task = entry.value;
        if (!instant.isAfter(task.makeUpDeadline.toUtc()) ||
            task.task.state == ActivityTaskState.completed ||
            task.task.state == ActivityTaskState.expired) {
          continue;
        }
        final hasPending = document.evidence.values.any(
          (evidence) =>
              evidence.taskId == task.task.id &&
              evidence.reviewState == ActivityEvidenceReviewState.pending,
        );
        if (hasPending) continue;
        document.tasks[entry.key] = task.withState(ActivityTaskState.expired);
        expired += 1;
      }
      document.record(canonicalId, fingerprint, 'expiredCount', '$expired');
      return _applied(expired);
    });
  });

  Future<CompanionActivitySnapshot> snapshot() async {
    _requireReadable();
    final operation = _store.read().then((json) {
      _requireReadable();
      final document = _ActivityDocument.decode(json, _scope);
      return CompanionActivitySnapshot(
        templates: List<ActivityTaskTemplate>.unmodifiable(
          document.templates.values.map((record) => record.template),
        ),
        tasks: List<ActivityTask>.unmodifiable(
          document.tasks.values.map((record) => record.task),
        ),
        evidence: List<ActivityEvidence>.unmodifiable(
          document.evidence.values.map(
            (record) => record.toDomain(document, _scope),
          ),
        ),
        ledger: document.buildLedger(_scope),
      );
    });
    _track(operation);
    return operation;
  }

  Future<ActivityStreakSnapshot> streak({required ActivityLocalDate asOf}) {
    _requireReadable();
    final operation = _store.read().then((json) {
      _requireReadable();
      final document = _ActivityDocument.decode(json, _scope);
      document.buildLedger(_scope);
      for (final record in document.evidence.values) {
        record.toDomain(document, _scope);
      }
      final completed = <ActivityLocalDate>{};
      for (final record in document.tasks.values) {
        if (record.task.cadence == ActivityCadence.daily &&
            record.task.state == ActivityTaskState.completed) {
          completed.add(record.localDate);
        }
      }
      final dates = completed.toList()..sort();
      var longest = 0;
      var run = 0;
      ActivityLocalDate? previous;
      for (final date in dates) {
        run = previous != null && date == previous.addDays(1) ? run + 1 : 1;
        if (run > longest) longest = run;
        previous = date;
      }
      var currentRun = 0;
      var cursor = asOf;
      if (!completed.contains(cursor)) cursor = cursor.addDays(-1);
      while (completed.contains(cursor)) {
        currentRun += 1;
        cursor = cursor.addDays(-1);
      }
      return ActivityStreakSnapshot(
        current: currentRun,
        longest: longest,
        asOf: asOf,
        completedDates: List<ActivityLocalDate>.unmodifiable(dates),
      );
    });
    _track(operation);
    return operation;
  }

  Future<void> deactivateAndDrain() {
    final existing = _drainFuture;
    if (existing != null) return existing;
    _active = false;
    late final Future<void> draining;
    draining = _deactivateOnce().whenComplete(() {
      if (identical(_drainFuture, draining)) _drainFuture = null;
    });
    _drainFuture = draining;
    return draining;
  }

  Future<void> _deactivateOnce() async {
    await _store.deactivateAndDrain();
    await _waitForOperations();
  }

  Future<CompanionActivityMutationResult<T>> _mutate<T>(
    Future<CompanionActivityMutationResult<T>> Function() operation,
  ) {
    if (!_active || isClosed) {
      return Future<CompanionActivityMutationResult<T>>.value(
        _unavailable('companion_activity_service_inactive'),
      );
    }
    if (!_isEnforced) {
      return Future<CompanionActivityMutationResult<T>>.value(
        _unavailable('companion_activity_rollout_disabled'),
      );
    }
    late final Future<CompanionActivityMutationResult<T>> future;
    try {
      future = operation();
    } on Object {
      return Future<CompanionActivityMutationResult<T>>.value(
        _unavailable('companion_activity_store_unavailable'),
      );
    }
    _track(future);
    return future.catchError(
      (Object _, StackTrace _) =>
          _unavailable<T>('companion_activity_store_unavailable'),
    );
  }

  Future<CompanionActivityMutationResult<T>> _transaction<T>(
    String operationId,
    String fingerprint,
    CompanionActivityMutationResult<T> Function(
      _ActivityDocument document,
      String canonicalOperationId,
    )
    mutation, {
    bool Function(bool isExactReplay)? authorize,
  }) {
    late final String normalizedOperationId;
    try {
      normalizedOperationId = canonicalActivityOperationId(operationId);
    } on ArgumentError {
      return Future<CompanionActivityMutationResult<T>>.value(
        _rejected('activity_operation_id_invalid'),
      );
    }
    final admittedRolloutGeneration = _safeRolloutGeneration();
    return _store.transaction((json) {
      // This is the write linearization fence. A rollout revocation that lands
      // while a transaction is queued must turn the transaction read-only.
      if (!_isEnforced ||
          _safeRolloutGeneration() != admittedRolloutGeneration) {
        return CompanionActivityStoreMutation<
          CompanionActivityMutationResult<T>
        >.readOnly(_unavailable('companion_activity_rollout_disabled'));
      }
      final document = _ActivityDocument.decode(json, _scope);
      final existing = document.receipts[normalizedOperationId];
      if (existing != null && existing.fingerprint != fingerprint) {
        return CompanionActivityStoreMutation<
          CompanionActivityMutationResult<T>
        >.readOnly(_rejected('activity_operation_replay_mismatch'));
      }
      if (authorize != null && !authorize(existing != null)) {
        return CompanionActivityStoreMutation<
          CompanionActivityMutationResult<T>
        >.readOnly(_rejected('activity_host_authority_invalid'));
      }
      final result = mutation(document, normalizedOperationId);
      return CompanionActivityStoreMutation<CompanionActivityMutationResult<T>>(
        value: result,
        document: document.encode(),
        write: result.status == CompanionActivityMutationStatus.applied,
        finalWriteFence: () =>
            _active &&
            !isClosed &&
            _isEnforced &&
            _safeRolloutGeneration() == admittedRolloutGeneration,
      );
    });
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

  bool get _isEnforced => _safeRolloutMode() == FeatureRolloutMode.enforce;

  FeatureRolloutMode _safeRolloutMode() {
    try {
      return _rolloutMode();
    } on Object {
      return FeatureRolloutMode.off;
    }
  }

  int _safeRolloutGeneration() {
    try {
      final generation = _rolloutGeneration();
      return generation >= 0 ? generation : -1;
    } on Object {
      return -1;
    }
  }

  void _requireReadable() {
    if (!_active || isClosed) {
      throw StateError('companion_activity_service_inactive');
    }
    if (!_isEnforced) {
      throw StateError('companion_activity_rollout_disabled');
    }
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain().catchError((Object _, StackTrace _) {}));
    super.onClose();
  }
}

FeatureRolloutMode _disabledCompanionActivityRollout() =>
    FeatureRolloutMode.off;

int _initialRolloutGeneration() => 0;

final class _ActivityDocument {
  _ActivityDocument({required this.scope});

  final ActivityScope scope;
  final Map<String, _TemplateRecord> templates = <String, _TemplateRecord>{};
  final Map<String, _TaskRecord> tasks = <String, _TaskRecord>{};
  final Map<String, _EvidenceRecord> evidence = <String, _EvidenceRecord>{};
  final List<_LedgerOperationRecord> ledgerOperations =
      <_LedgerOperationRecord>[];
  final Map<String, _OperationReceipt> receipts = <String, _OperationReceipt>{};

  factory _ActivityDocument.decode(
    Map<String, Object?>? json,
    ActivityScope scope,
  ) {
    final document = _ActivityDocument(scope: scope);
    if (json == null) return document;
    final schemaVersion = json['schemaVersion'];
    final storedGeneration = json['facadeGeneration'];
    if ((schemaVersion != 1 && schemaVersion != 2) ||
        json['accountId'] != scope.accountId ||
        storedGeneration is! int ||
        storedGeneration < 1 ||
        storedGeneration > scope.facadeGeneration) {
      throw const FormatException('companion activity document invalid');
    }
    if (schemaVersion == 1 &&
        (_map(json, 'evidence').isNotEmpty ||
            _list(json, 'ledgerOperations').isNotEmpty)) {
      throw const FormatException('legacy activity evidence is untrusted');
    }
    final templates = _map(json, 'templates');
    for (final entry in templates.entries) {
      document.templates[entry.key] = _TemplateRecord.fromJson(
        _objectMap(entry.value),
        scope,
      );
    }
    final tasks = _map(json, 'tasks');
    for (final entry in tasks.entries) {
      document.tasks[entry.key] = _TaskRecord.fromJson(
        _objectMap(entry.value),
        scope,
      );
    }
    final evidence = _map(json, 'evidence');
    for (final entry in evidence.entries) {
      document.evidence[entry.key] = _EvidenceRecord.fromJson(
        _objectMap(entry.value),
        scope,
      );
    }
    for (final value in _list(json, 'ledgerOperations')) {
      document.ledgerOperations.add(
        _LedgerOperationRecord.fromJson(_objectMap(value), scope),
      );
    }
    final receipts = _map(json, 'receipts');
    for (final entry in receipts.entries) {
      document.receipts[entry.key] = _OperationReceipt.fromJson(
        _objectMap(entry.value),
      );
    }
    return document;
  }

  Map<String, Object?> encode() => <String, Object?>{
    'schemaVersion': 2,
    'accountId': scope.accountId,
    'facadeGeneration': scope.facadeGeneration,
    'templates': <String, Object?>{
      for (final entry in templates.entries) entry.key: entry.value.toJson(),
    },
    'tasks': <String, Object?>{
      for (final entry in tasks.entries) entry.key: entry.value.toJson(),
    },
    'evidence': <String, Object?>{
      for (final entry in evidence.entries) entry.key: entry.value.toJson(),
    },
    'ledgerOperations': ledgerOperations
        .map((operation) => operation.toJson())
        .toList(growable: false),
    'receipts': <String, Object?>{
      for (final entry in receipts.entries) entry.key: entry.value.toJson(),
    },
  };

  _OperationReceipt? replay(String operationId, String fingerprint) {
    final receipt = receipts[operationId];
    if (receipt == null || receipt.fingerprint != fingerprint) return null;
    return receipt;
  }

  void record(
    String operationId,
    String fingerprint,
    String entityKind,
    String entityId,
  ) {
    receipts[operationId] = _OperationReceipt(
      fingerprint: fingerprint,
      entityKind: entityKind,
      entityId: entityId,
    );
  }

  ActivityTaskTemplate template(String id) =>
      templates[id]?.template ??
      (throw StateError('activity_replay_target_missing'));

  ActivityTask task(String id) =>
      tasks[id]?.task ?? (throw StateError('activity_replay_target_missing'));

  ActivityEvidence evidenceById(String id) =>
      evidence[id]?.toDomain(this, scope) ??
      (throw StateError('activity_replay_target_missing'));

  ActivityPointsLedger buildLedger(ActivityScope scope) {
    var ledger = ActivityPointsLedger.empty(scope);
    for (final operation in ledgerOperations) {
      ledger = operation.apply(this, ledger, scope);
    }
    return ledger;
  }

  VirtualRewardRedemptionReceipt redemptionReceipt(
    String operationId,
    ActivityScope scope,
  ) {
    final record = ledgerOperations.whereType<_RedemptionRecord>().firstWhere(
      (candidate) => candidate.request.operationId == operationId,
      orElse: () => throw StateError('activity_replay_target_missing'),
    );
    return buildLedger(
      scope,
    ).redeem(request: record.request, reward: record.reward).receipt!;
  }
}

final class _TemplateRecord {
  const _TemplateRecord({required this.template, required this.recurrence});

  final ActivityTaskTemplate template;
  final ActivityRecurrenceRule recurrence;

  Map<String, Object?> toJson() => <String, Object?>{
    ..._templateJson(template),
    'recurrence': recurrence.toJson(),
  };

  factory _TemplateRecord.fromJson(
    Map<String, Object?> json,
    ActivityScope scope,
  ) => _TemplateRecord(
    template: ActivityTaskTemplate(
      id: _string(json, 'id'),
      scope: scope,
      title: _string(json, 'title'),
      cadence: ActivityCadence.values.byName(_string(json, 'cadence')),
      defaultAwardPoints: _integer(json, 'defaultAwardPoints'),
      tags: _list(json, 'tags').cast<String>(),
    ),
    recurrence: ActivityRecurrenceRule.fromJson(_objectMap(json['recurrence'])),
  );
}

final class _TaskRecord {
  const _TaskRecord({
    required this.task,
    required this.localDate,
    required this.makeUpDeadline,
    required this.timeZoneId,
    required this.offsetMinutes,
  });

  final ActivityTask task;
  final ActivityLocalDate localDate;
  final DateTime makeUpDeadline;
  final String timeZoneId;
  final int offsetMinutes;

  _TaskRecord withState(ActivityTaskState state) => _TaskRecord(
    task: task.withState(state),
    localDate: localDate,
    makeUpDeadline: makeUpDeadline,
    timeZoneId: timeZoneId,
    offsetMinutes: offsetMinutes,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': task.id,
    'templateId': task.templateId,
    'cadence': task.cadence.name,
    'title': task.title,
    'awardPoints': task.awardPoints,
    'availableAt': task.availableAt.toUtc().toIso8601String(),
    'dueAt': task.dueAt.toUtc().toIso8601String(),
    'state': task.state.name,
    'localDate': localDate.toString(),
    'makeUpDeadline': makeUpDeadline.toUtc().toIso8601String(),
    'timeZoneId': timeZoneId,
    'offsetMinutes': offsetMinutes,
  };

  factory _TaskRecord.fromJson(
    Map<String, Object?> json,
    ActivityScope scope,
  ) => _TaskRecord(
    task: ActivityTask(
      id: _string(json, 'id'),
      templateId: _string(json, 'templateId'),
      scope: scope,
      cadence: ActivityCadence.values.byName(_string(json, 'cadence')),
      title: _string(json, 'title'),
      awardPoints: _integer(json, 'awardPoints'),
      availableAt: _dateTime(json, 'availableAt'),
      dueAt: _dateTime(json, 'dueAt'),
      state: ActivityTaskState.values.byName(_string(json, 'state')),
    ),
    localDate: ActivityLocalDate.parse(_string(json, 'localDate')),
    makeUpDeadline: _dateTime(json, 'makeUpDeadline'),
    timeZoneId: _string(json, 'timeZoneId'),
    offsetMinutes: _integer(json, 'offsetMinutes'),
  );
}

final class _EvidenceRecord {
  const _EvidenceRecord({
    required this.evidenceId,
    required this.taskId,
    required this.artifact,
    required this.privacyReceiptId,
    required this.submittedAt,
    required this.reviewState,
    this.reviewedAt,
  });

  final String evidenceId;
  final String taskId;
  final ActivityEvidenceArtifact artifact;
  final String privacyReceiptId;
  final DateTime submittedAt;
  final ActivityEvidenceReviewState reviewState;
  final DateTime? reviewedAt;

  _EvidenceRecord reviewed(ActivityEvidenceReviewState state, DateTime at) =>
      _EvidenceRecord(
        evidenceId: evidenceId,
        taskId: taskId,
        artifact: artifact,
        privacyReceiptId: privacyReceiptId,
        submittedAt: submittedAt,
        reviewState: state,
        reviewedAt: at,
      );

  ActivityEvidence toDomain(_ActivityDocument document, ActivityScope scope) {
    final task = document.tasks[taskId]?.task;
    if (task == null) throw StateError('activity_evidence_task_missing');
    return ActivityEvidence.restorePersisted(
      id: evidenceId,
      taskId: task.id,
      scope: scope,
      artifact: artifact,
      privacyReceiptId: privacyReceiptId,
      submittedAt: submittedAt,
      reviewState: reviewState,
      reviewedAt: reviewedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'evidenceId': evidenceId,
    'taskId': taskId,
    'artifact': _artifactJson(artifact),
    'privacyReceiptId': privacyReceiptId,
    'submittedAt': submittedAt.toUtc().toIso8601String(),
    'reviewState': reviewState.name,
    'reviewedAt': reviewedAt?.toUtc().toIso8601String(),
  };

  factory _EvidenceRecord.fromJson(
    Map<String, Object?> json,
    ActivityScope scope,
  ) => _EvidenceRecord(
    evidenceId: _string(json, 'evidenceId'),
    taskId: _string(json, 'taskId'),
    artifact: _artifactFromJson(_objectMap(json['artifact'])),
    privacyReceiptId: _string(json, 'privacyReceiptId'),
    submittedAt: _dateTime(json, 'submittedAt'),
    reviewState: ActivityEvidenceReviewState.values.byName(
      _string(json, 'reviewState'),
    ),
    reviewedAt: json['reviewedAt'] == null
        ? null
        : DateTime.parse(json['reviewedAt']! as String).toUtc(),
  );
}

sealed class _LedgerOperationRecord {
  const _LedgerOperationRecord();

  ActivityPointsLedger apply(
    _ActivityDocument document,
    ActivityPointsLedger ledger,
    ActivityScope scope,
  );

  Map<String, Object?> toJson();

  static _LedgerOperationRecord fromJson(
    Map<String, Object?> json,
    ActivityScope scope,
  ) => switch (_string(json, 'kind')) {
    'award' => _AwardRecord.fromJson(json),
    'redemption' => _RedemptionRecord.fromJson(json, scope),
    _ => throw const FormatException('activity ledger operation invalid'),
  };
}

final class _AwardRecord extends _LedgerOperationRecord {
  const _AwardRecord({
    required this.operationId,
    required this.taskId,
    required this.evidenceId,
    required this.recordedAt,
  });

  final String operationId;
  final String taskId;
  final String evidenceId;
  final DateTime recordedAt;

  @override
  ActivityPointsLedger apply(
    _ActivityDocument document,
    ActivityPointsLedger ledger,
    ActivityScope scope,
  ) {
    final task = document.tasks[taskId]?.task;
    final evidence = document.evidence[evidenceId]?.toDomain(document, scope);
    if (task == null || evidence == null) {
      throw StateError('activity_award_reference_missing');
    }
    final result = ledger.award(
      operationId: operationId,
      scope: scope,
      task: task,
      evidence: evidence,
      recordedAt: recordedAt,
    );
    if (result.status != ActivityLedgerMutationStatus.applied) {
      throw StateError('activity_award_replay_invalid');
    }
    return result.ledger;
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'award',
    'operationId': operationId,
    'taskId': taskId,
    'evidenceId': evidenceId,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
  };

  factory _AwardRecord.fromJson(Map<String, Object?> json) => _AwardRecord(
    operationId: _string(json, 'operationId'),
    taskId: _string(json, 'taskId'),
    evidenceId: _string(json, 'evidenceId'),
    recordedAt: _dateTime(json, 'recordedAt'),
  );
}

final class _RedemptionRecord extends _LedgerOperationRecord {
  const _RedemptionRecord({required this.request, required this.reward});

  final VirtualRewardRedemptionRequest request;
  final VirtualReward reward;

  @override
  ActivityPointsLedger apply(
    _ActivityDocument document,
    ActivityPointsLedger ledger,
    ActivityScope scope,
  ) {
    final result = ledger.redeem(request: request, reward: reward);
    if (result.status != ActivityRedemptionStatus.redeemed) {
      throw StateError('activity_redemption_replay_invalid');
    }
    return result.ledger;
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'redemption',
    'requestId': request.id,
    'operationId': request.operationId,
    'rewardId': request.rewardId,
    'requestedAt': request.requestedAt.toUtc().toIso8601String(),
    'rewardTitle': reward.title,
    'rewardKind': reward.kind.name,
    'rewardCostPoints': reward.costPoints,
  };

  factory _RedemptionRecord.fromJson(
    Map<String, Object?> json,
    ActivityScope scope,
  ) {
    final reward = VirtualReward(
      id: _string(json, 'rewardId'),
      title: _string(json, 'rewardTitle'),
      kind: VirtualRewardKind.values.byName(_string(json, 'rewardKind')),
      costPoints: _integer(json, 'rewardCostPoints'),
    );
    return _RedemptionRecord(
      request: VirtualRewardRedemptionRequest(
        id: _string(json, 'requestId'),
        operationId: _string(json, 'operationId'),
        scope: scope,
        rewardId: reward.id,
        requestedAt: _dateTime(json, 'requestedAt'),
      ),
      reward: reward,
    );
  }
}

final class _OperationReceipt {
  const _OperationReceipt({
    required this.fingerprint,
    required this.entityKind,
    required this.entityId,
  });

  final String fingerprint;
  final String entityKind;
  final String entityId;

  Map<String, Object?> toJson() => <String, Object?>{
    'fingerprint': fingerprint,
    'entityKind': entityKind,
    'entityId': entityId,
  };

  factory _OperationReceipt.fromJson(Map<String, Object?> json) =>
      _OperationReceipt(
        fingerprint: _string(json, 'fingerprint'),
        entityKind: _string(json, 'entityKind'),
        entityId: _string(json, 'entityId'),
      );
}

Map<String, Object?> _templateJson(ActivityTaskTemplate template) =>
    <String, Object?>{
      'id': template.id,
      'title': template.title,
      'cadence': template.cadence.name,
      'defaultAwardPoints': template.defaultAwardPoints,
      'tags': template.tags,
    };

Map<String, Object?> _artifactJson(ActivityEvidenceArtifact artifact) =>
    <String, Object?>{
      'localObjectId': artifact.localObjectId,
      'derivedSha256': artifact.derivedSha256,
      'mimeType': artifact.mimeType,
      'byteLength': artifact.byteLength,
      'pixelWidth': artifact.pixelWidth,
      'pixelHeight': artifact.pixelHeight,
      'storageClass': artifact.storageClass.name,
    };

ActivityEvidenceArtifact _artifactFromJson(Map<String, Object?> json) =>
    ActivityEvidenceArtifact(
      localObjectId: _string(json, 'localObjectId'),
      derivedSha256: _string(json, 'derivedSha256'),
      mimeType: _string(json, 'mimeType'),
      byteLength: _integer(json, 'byteLength'),
      pixelWidth: _integer(json, 'pixelWidth'),
      pixelHeight: _integer(json, 'pixelHeight'),
      storageClass: ActivityEvidenceStorageClass.values.byName(
        _string(json, 'storageClass'),
      ),
    );

String? _cadenceIssue(
  ActivityCadence cadence,
  ActivityLocalDate first,
  ActivityLocalDate requested,
) => switch (cadence) {
  ActivityCadence.daily when requested.compareTo(first) < 0 =>
    'activity_recurrence_before_start',
  ActivityCadence.challenge when requested != first =>
    'activity_challenge_is_one_shot',
  ActivityCadence.surprise when requested.compareTo(first) < 0 =>
    'activity_recurrence_before_start',
  _ => null,
};

String _occurrenceId(String templateId, ActivityLocalDate date) =>
    'activity-${_fingerprint(<Object?>[templateId, date.toString()]).substring(0, 24)}';

String _derivedOperationId(String kind, String source) =>
    '$kind-${_fingerprint(<Object?>[source]).substring(0, 32)}';

String _fingerprint(List<Object?> values) =>
    sha256.convert(utf8.encode(jsonEncode(values))).toString();

CompanionActivityMutationResult<T> _applied<T>(T value) =>
    CompanionActivityMutationResult<T>(
      status: CompanionActivityMutationStatus.applied,
      value: value,
    );

CompanionActivityMutationResult<T> _alreadyApplied<T>(T value) =>
    CompanionActivityMutationResult<T>(
      status: CompanionActivityMutationStatus.alreadyApplied,
      value: value,
    );

CompanionActivityMutationResult<T> _rejected<T>(String reason) =>
    CompanionActivityMutationResult<T>(
      status: CompanionActivityMutationStatus.rejected,
      reason: reason,
    );

CompanionActivityMutationResult<T> _unavailable<T>(String reason) =>
    CompanionActivityMutationResult<T>(
      status: CompanionActivityMutationStatus.unavailable,
      reason: reason,
    );

String _boundedId(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 128 ||
      !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(normalized)) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

String _boundedText(String value, String field, int maximumLength) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maximumLength) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) throw const FormatException('expected object');
  return Map<String, Object?>.from(value);
}

Map<String, Object?> _map(Map<String, Object?> json, String field) =>
    _objectMap(json[field]);

List<Object?> _list(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! List) throw FormatException('$field must be a list');
  return List<Object?>.from(value);
}

String _string(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

int _integer(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int) throw FormatException('$field must be an integer');
  return value;
}

DateTime _dateTime(Map<String, Object?> json, String field) =>
    DateTime.parse(_string(json, field)).toUtc();
