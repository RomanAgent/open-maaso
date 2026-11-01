import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/companion_activity/domain/activity_evidence_privacy.dart';
import 'package:maaso/src/features/companion_activity/domain/activity_points_ledger.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';

void main() {
  final now = DateTime.utc(2026, 8, 30, 12);
  final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 7);

  test('template and occurrence are separate immutable snapshots', () {
    final sourceTags = <String>['wellbeing'];
    final template = ActivityTaskTemplate(
      id: 'template-walk',
      scope: scope,
      title: 'Walk together',
      cadence: ActivityCadence.daily,
      defaultAwardPoints: 20,
      tags: sourceTags,
    );
    sourceTags.add('mutated');
    final task = _task(scope, now);
    final completed = task.withState(ActivityTaskState.completed);

    expect(template.tags, <String>['wellbeing']);
    expect(() => template.tags.add('x'), throwsUnsupportedError);
    expect(task.templateId, template.id);
    expect(task.state, ActivityTaskState.available);
    expect(completed.state, ActivityTaskState.completed);
    expect(task.state, ActivityTaskState.available);
  });

  test('photo evidence accepts only bounded derived-thumbnail metadata', () {
    final task = _task(scope, now);
    final artifact = _artifact();
    final accepted = ActivityEvidence.admit(
      id: 'evidence-1',
      task: task,
      scope: scope,
      artifact: artifact,
      privacyReceipt: _privacyReceipt(scope, now),
      submittedAt: now,
    );
    expect(accepted.status, ActivityEvidenceAdmissionStatus.accepted);
    expect(
      accepted.evidence!.artifact.storageClass,
      ActivityEvidenceStorageClass.localDerivedThumbnail,
    );
    expect(accepted.evidence!.artifact.derivedSha256, _derivedDigest);
  });

  test('opaque privacy verifier fences scope and consumes once', () {
    final task = _task(scope, now);
    final authority = ActivityEvidencePrivacyAuthority.create();
    final staleScope = ActivityScope(
      accountId: 'account-a',
      facadeGeneration: 6,
    );
    final staleReceipt = _privacyReceipt(
      staleScope,
      now,
      issuer: authority.issuer,
    );
    expect(
      authority.verifier.consume(
        receipt: staleReceipt,
        artifact: _artifact(),
        accountId: scope.accountId,
        facadeGeneration: scope.facadeGeneration,
        admittedAt: now,
      ),
      isFalse,
    );
    final valid = _privacyReceipt(scope, now, issuer: authority.issuer);
    expect(
      authority.verifier.consume(
        receipt: valid,
        artifact: _artifact(),
        accountId: scope.accountId,
        facadeGeneration: scope.facadeGeneration,
        admittedAt: now,
      ),
      isTrue,
    );
    expect(
      authority.verifier.consume(
        receipt: valid,
        artifact: _artifact(),
        accountId: scope.accountId,
        facadeGeneration: scope.facadeGeneration,
        admittedAt: now,
      ),
      isFalse,
    );

    final wrongAccount = ActivityEvidence.admit(
      id: 'evidence-1',
      task: task,
      scope: ActivityScope(accountId: 'account-b', facadeGeneration: 7),
      artifact: _artifact(),
      privacyReceipt: _privacyReceipt(scope, now),
      submittedAt: now,
    );
    expect(wrongAccount.reason, 'activity_scope_mismatch');
  });

  test('points ledger is append-only and task award is idempotent', () {
    final task = _task(scope, now);
    final evidence = _approvedEvidence(scope, task, now);
    final empty = ActivityPointsLedger.empty(scope);
    final award = empty.award(
      operationId: 'award-1',
      scope: scope,
      task: task,
      evidence: evidence,
      recordedAt: now.add(const Duration(minutes: 1)),
    );

    expect(award.status, ActivityLedgerMutationStatus.applied);
    expect(empty.balance, 0);
    expect(empty.entries, isEmpty);
    expect(award.ledger.balance, task.awardPoints);
    expect(() => award.ledger.entries.clear(), throwsUnsupportedError);

    final replay = award.ledger.award(
      operationId: 'award-1',
      scope: scope,
      task: task,
      evidence: evidence,
      recordedAt: now.add(const Duration(minutes: 2)),
    );
    expect(replay.status, ActivityLedgerMutationStatus.alreadyApplied);
    expect(replay.ledger.entries, hasLength(1));

    final duplicateWithNewOperation = award.ledger.award(
      operationId: 'award-2',
      scope: scope,
      task: task,
      evidence: evidence,
      recordedAt: now.add(const Duration(minutes: 3)),
    );
    expect(
      duplicateWithNewOperation.status,
      ActivityLedgerMutationStatus.rejected,
    );
    expect(
      duplicateWithNewOperation.reason,
      'task_or_evidence_already_awarded',
    );
    expect(duplicateWithNewOperation.ledger, same(award.ledger));
  });

  test('award cannot precede the evidence review timestamp', () {
    final task = _task(scope, now);
    final evidence = _approvedEvidence(scope, task, now);
    final result = ActivityPointsLedger.empty(scope).award(
      operationId: 'award-early',
      scope: scope,
      task: task,
      evidence: evidence,
      recordedAt: now,
    );

    expect(result.status, ActivityLedgerMutationStatus.rejected);
    expect(result.reason, 'award_before_evidence_review');
    expect(result.ledger.entries, isEmpty);
  });

  test(
    'virtual redemption debits atomically and replays without double spend',
    () {
      final task = _task(scope, now);
      final evidence = _approvedEvidence(scope, task, now);
      final credited = ActivityPointsLedger.empty(scope)
          .award(
            operationId: 'award-1',
            scope: scope,
            task: task,
            evidence: evidence,
            recordedAt: now.add(const Duration(minutes: 1)),
          )
          .ledger;
      final reward = VirtualReward(
        id: 'badge-kindness',
        title: 'Kindness badge',
        kind: VirtualRewardKind.badge,
        costPoints: 15,
      );
      final request = VirtualRewardRedemptionRequest(
        id: 'redemption-1',
        operationId: 'redeem-1',
        scope: scope,
        rewardId: reward.id,
        requestedAt: now.add(const Duration(minutes: 2)),
      );
      final redeemed = credited.redeem(request: request, reward: reward);

      expect(redeemed.status, ActivityRedemptionStatus.redeemed);
      expect(credited.balance, 20);
      expect(redeemed.ledger.balance, 5);
      expect(redeemed.ledger.entries, hasLength(2));
      expect(redeemed.receipt!.fulfillment, RewardFulfillmentKind.virtualOnly);

      final replay = redeemed.ledger.redeem(request: request, reward: reward);
      expect(replay.status, ActivityRedemptionStatus.alreadyRedeemed);
      expect(replay.ledger.balance, 5);
      expect(replay.ledger.entries, hasLength(2));

      final mismatchedReplay = redeemed.ledger.redeem(
        request: VirtualRewardRedemptionRequest(
          id: 'redemption-other',
          operationId: request.operationId,
          scope: scope,
          rewardId: reward.id,
          requestedAt: request.requestedAt,
        ),
        reward: reward,
      );
      expect(mismatchedReplay.status, ActivityRedemptionStatus.rejected);
      expect(mismatchedReplay.reason, 'operation_replay_mismatch');
      expect(mismatchedReplay.ledger, same(redeemed.ledger));
    },
  );

  test('rejected redemption leaves the exact ledger snapshot unchanged', () {
    final ledger = ActivityPointsLedger.empty(scope);
    final reward = VirtualReward(
      id: 'theme-sunrise',
      title: 'Sunrise theme',
      kind: VirtualRewardKind.surfaceTheme,
      costPoints: 10,
    );
    final insufficient = ledger.redeem(
      request: VirtualRewardRedemptionRequest(
        id: 'redemption-1',
        operationId: 'redeem-1',
        scope: scope,
        rewardId: reward.id,
        requestedAt: now,
      ),
      reward: reward,
    );
    expect(insufficient.reason, 'insufficient_points');
    expect(insufficient.ledger, same(ledger));
    expect(insufficient.receipt, isNull);

    final wrongGeneration = ledger.redeem(
      request: VirtualRewardRedemptionRequest(
        id: 'redemption-2',
        operationId: 'redeem-2',
        scope: ActivityScope(accountId: 'account-a', facadeGeneration: 8),
        rewardId: reward.id,
        requestedAt: now,
      ),
      reward: reward,
    );
    expect(wrongGeneration.reason, 'activity_scope_mismatch');
    expect(wrongGeneration.ledger, same(ledger));
  });

  test('reward contract has virtual fulfillment only', () {
    expect(RewardFulfillmentKind.values, <RewardFulfillmentKind>[
      RewardFulfillmentKind.virtualOnly,
    ]);
    expect(
      VirtualRewardKind.values,
      containsAll(<VirtualRewardKind>[
        VirtualRewardKind.badge,
        VirtualRewardKind.avatarCosmetic,
        VirtualRewardKind.surfaceTheme,
        VirtualRewardKind.celebration,
      ]),
    );
  });

  test('evidence domain exposes metadata references rather than image bytes', () {
    final source = File(
      'lib/src/features/companion_activity/domain/activity_evidence_privacy.dart',
    ).readAsStringSync();
    for (final rawTransportType in <String>[
      'Uint8List',
      'ByteData',
      'List<int>',
      'filePath',
    ]) {
      expect(
        source,
        isNot(contains(rawTransportType)),
        reason: rawTransportType,
      );
    }
  });
}

const _sourceDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _derivedDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

ActivityTask _task(ActivityScope scope, DateTime now) => ActivityTask(
  id: 'task-2026-08-30',
  templateId: 'template-walk',
  scope: scope,
  cadence: ActivityCadence.daily,
  title: 'Walk together',
  awardPoints: 20,
  availableAt: now,
  dueAt: now.add(const Duration(hours: 12)),
);

ActivityEvidenceArtifact _artifact() => ActivityEvidenceArtifact(
  localObjectId: 'thumbnail-1',
  derivedSha256: _derivedDigest,
  mimeType: 'image/jpeg',
  byteLength: 24000,
  pixelWidth: 640,
  pixelHeight: 480,
);

ActivityEvidencePrivacyReceipt _privacyReceipt(
  ActivityScope scope,
  DateTime now, {
  ActivityEvidencePrivacyReceiptIssuer? issuer,
}) => (issuer ?? ActivityEvidencePrivacyAuthority.create().issuer).issue(
  id: 'privacy-1',
  accountId: scope.accountId,
  facadeGeneration: scope.facadeGeneration,
  sourceSha256: _sourceDigest,
  derivedSha256: _derivedDigest,
  transformedAt: now.subtract(const Duration(seconds: 1)),
);

ActivityEvidence _approvedEvidence(
  ActivityScope scope,
  ActivityTask task,
  DateTime now,
) {
  final admitted = ActivityEvidence.admit(
    id: 'evidence-1',
    task: task,
    scope: scope,
    artifact: _artifact(),
    privacyReceipt: _privacyReceipt(scope, now),
    submittedAt: now,
  ).evidence!;
  return admitted.review(
    scope: scope,
    decision: ActivityEvidenceReviewState.approved,
    reviewedAt: now.add(const Duration(seconds: 1)),
  );
}
