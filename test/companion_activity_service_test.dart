import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_host_authority.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_service.dart';
import 'package:maaso/src/features/companion_activity/data/companion_activity_store.dart';
import 'package:maaso/src/features/companion_activity/domain/activity_evidence_privacy.dart';
import 'package:maaso/src/features/companion_activity/domain/activity_points_ledger.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  group('CompanionActivityService', () {
    test(
      'runs template through reward as one idempotent state machine',
      () async {
        final harness = _Harness();
        expect(
          (await harness.register()).status,
          CompanionActivityMutationStatus.applied,
        );
        final occurrence = await harness.occurrence(
          operationId: 'occurrence-1',
          date: ActivityLocalDate(2026, 8, 30),
        );
        final task = occurrence.value!;
        final submittedAt = task.availableAt.add(const Duration(minutes: 30));
        expect(
          (await harness.submit(task, submittedAt: submittedAt)).status,
          CompanionActivityMutationStatus.applied,
        );

        final reviewedAt = submittedAt.add(const Duration(minutes: 1));
        final review = await harness.service.reviewEvidence(
          hostGrant: harness.reviewGrant(
            operationId: 'review-1',
            evidenceId: 'evidence-1',
            decision: ActivityEvidenceReviewState.approved,
            reviewedAt: reviewedAt,
          ),
          operationId: 'review-1',
          evidenceId: 'evidence-1',
          decision: ActivityEvidenceReviewState.approved,
          reviewedAt: reviewedAt,
        );
        final replay = await harness.service.reviewEvidence(
          hostGrant: harness.reviewGrant(
            operationId: 'review-1',
            evidenceId: 'evidence-1',
            decision: ActivityEvidenceReviewState.approved,
            reviewedAt: reviewedAt,
          ),
          operationId: 'review-1',
          evidenceId: 'evidence-1',
          decision: ActivityEvidenceReviewState.approved,
          reviewedAt: reviewedAt,
        );

        expect(review.status, CompanionActivityMutationStatus.applied);
        expect(replay.status, CompanionActivityMutationStatus.alreadyApplied);
        var snapshot = await harness.service.snapshot();
        expect(snapshot.tasks.single.state, ActivityTaskState.completed);
        expect(
          snapshot.evidence.single.reviewState,
          ActivityEvidenceReviewState.approved,
        );
        expect(snapshot.ledger.balance, 20);
        expect(snapshot.ledger.entries, hasLength(1));

        final reward = VirtualReward(
          id: 'badge-kindness',
          title: 'Kindness badge',
          kind: VirtualRewardKind.badge,
          costPoints: 15,
        );
        final request = VirtualRewardRedemptionRequest(
          id: 'redemption-1',
          operationId: 'redeem-1',
          scope: harness.scope,
          rewardId: reward.id,
          requestedAt: reviewedAt.add(const Duration(minutes: 1)),
        );
        final redeemed = await harness.service.redeem(
          hostGrant: harness.redeemGrant(request: request, reward: reward),
          request: request,
          reward: reward,
        );
        final redeemedReplay = await harness.service.redeem(
          hostGrant: harness.redeemGrant(request: request, reward: reward),
          request: request,
          reward: reward,
        );

        expect(redeemed.status, CompanionActivityMutationStatus.applied);
        expect(
          redeemedReplay.status,
          CompanionActivityMutationStatus.alreadyApplied,
        );
        expect(redeemed.value!.fulfillment, RewardFulfillmentKind.virtualOnly);
        snapshot = await harness.service.snapshot();
        expect(snapshot.ledger.balance, 5);
        expect(snapshot.ledger.entries, hasLength(2));
      },
    );

    test('same operation id with different payload is rejected', () async {
      final harness = _Harness();
      await harness.register();
      await harness.occurrence(
        operationId: 'occurrence-replay',
        date: ActivityLocalDate(2026, 8, 30),
      );

      final mismatch = await harness.occurrence(
        operationId: 'occurrence-replay',
        date: ActivityLocalDate(2026, 8, 31),
      );

      expect(mismatch.status, CompanionActivityMutationStatus.rejected);
      expect(mismatch.reason, 'activity_operation_replay_mismatch');
      expect((await harness.service.snapshot()).tasks, hasLength(1));
    });

    test(
      'operation id whitespace alias is rejected before transaction',
      () async {
        final harness = _Harness();
        await harness.register();
        final first = await harness.occurrence(
          operationId: 'occurrence-canonical',
          date: ActivityLocalDate(2026, 8, 30),
        );
        final alias = await harness.occurrence(
          operationId: ' occurrence-canonical ',
          date: ActivityLocalDate(2026, 8, 31),
        );

        expect(first.status, CompanionActivityMutationStatus.applied);
        expect(alias.status, CompanionActivityMutationStatus.rejected);
        expect(alias.reason, 'activity_operation_id_invalid');
        expect((await harness.service.snapshot()).tasks, hasLength(1));
      },
    );

    test('concurrent exact replay commits one occurrence only', () async {
      final harness = _Harness();
      await harness.register();
      final results = await Future.wait(
        <Future<CompanionActivityMutationResult<ActivityTask>>>[
          harness.occurrence(
            operationId: 'occurrence-concurrent',
            date: ActivityLocalDate(2026, 8, 30),
          ),
          harness.occurrence(
            operationId: 'occurrence-concurrent',
            date: ActivityLocalDate(2026, 8, 30),
          ),
        ],
      );

      expect(
        results.map((result) => result.status),
        containsAll(<CompanionActivityMutationStatus>[
          CompanionActivityMutationStatus.applied,
          CompanionActivityMutationStatus.alreadyApplied,
        ]),
      );
      expect((await harness.service.snapshot()).tasks, hasLength(1));
    });

    test('IANA is authoritative across DST gap and overlap', () {
      final recurrence = ActivityRecurrenceRule(
        timeZoneId: 'America/New_York',
        offsetAtCreationMinutes: -300,
        localStartMinute: 2 * 60 + 30,
        firstLocalDate: ActivityLocalDate(2026, 3, 7),
      );
      final location = tz.getLocation('America/New_York');

      final before = recurrence.resolve(
        ActivityLocalDate(2026, 3, 7),
        tz.getLocation,
      );
      final gap = recurrence.resolve(
        ActivityLocalDate(2026, 3, 8),
        tz.getLocation,
      );
      final overlapRule = ActivityRecurrenceRule(
        timeZoneId: 'America/New_York',
        offsetAtCreationMinutes: -240,
        localStartMinute: 90,
        firstLocalDate: ActivityLocalDate(2026, 10, 31),
      );
      final overlap = overlapRule.resolve(
        ActivityLocalDate(2026, 11, 1),
        tz.getLocation,
      );

      expect(before.availableAt, DateTime.utc(2026, 3, 7, 7, 30));
      expect(before.offsetMinutes, -300);
      expect(gap.availableAt, DateTime.utc(2026, 3, 8, 7, 30));
      expect(gap.resolvedLocalHour, 3);
      expect(gap.resolvedLocalMinute, 30);
      expect(overlap.availableAt, DateTime.utc(2026, 11, 1, 5, 30));
      expect(overlap.offsetMinutes, -240);
      expect(tz.TZDateTime.from(overlap.availableAt, location).hour, 1);
    });

    test(
      'registration fences unavailable IANA zone and wrong first offset',
      () async {
        final harness = _Harness();
        final wrongOffset = await harness.register(offsetMinutes: 60);
        expect(wrongOffset.status, CompanionActivityMutationStatus.rejected);
        expect(wrongOffset.reason, 'activity_timezone_offset_mismatch');

        final unavailable = CompanionActivityService(
          store: _MemoryCompanionActivityStore(harness.scope),
          timeZoneResolver: (_) => throw StateError('missing'),
          rolloutMode: _enforcedActivityRollout,
        );
        final result = await unavailable.registerTemplate(
          operationId: 'template-1',
          template: harness.template,
          recurrence: harness.recurrence(),
        );
        expect(result.status, CompanionActivityMutationStatus.rejected);
        expect(result.reason, 'activity_timezone_unavailable');
      },
    );

    test(
      'make-up deadline is inclusive and one microsecond later is closed',
      () async {
        final acceptedHarness = _Harness(
          availabilityWindow: const Duration(hours: 1),
          makeUpWindow: const Duration(hours: 2),
        );
        await acceptedHarness.register();
        final acceptedTask = (await acceptedHarness.occurrence(
          operationId: 'occurrence-1',
          date: ActivityLocalDate(2026, 8, 30),
        )).value!;
        final deadline = acceptedTask.dueAt.add(const Duration(hours: 2));
        final accepted = await acceptedHarness.submit(
          acceptedTask,
          submittedAt: deadline,
        );
        expect(accepted.status, CompanionActivityMutationStatus.applied);

        final rejectedHarness = _Harness(
          availabilityWindow: const Duration(hours: 1),
          makeUpWindow: const Duration(hours: 2),
        );
        await rejectedHarness.register();
        final rejectedTask = (await rejectedHarness.occurrence(
          operationId: 'occurrence-1',
          date: ActivityLocalDate(2026, 8, 30),
        )).value!;
        final rejected = await rejectedHarness.submit(
          rejectedTask,
          submittedAt: rejectedTask.dueAt
              .add(const Duration(hours: 2))
              .add(const Duration(microseconds: 1)),
        );
        expect(rejected.status, CompanionActivityMutationStatus.rejected);
        expect(rejected.reason, 'activity_makeup_window_closed');
      },
    );

    test(
      'off and shadow modes expose no state and perform no writes',
      () async {
        for (final mode in <FeatureRolloutMode>[
          FeatureRolloutMode.off,
          FeatureRolloutMode.shadow,
        ]) {
          final store = _MemoryCompanionActivityStore(
            ActivityScope(
              accountId: 'account-a',
              facadeGeneration: mode.index + 1,
            ),
          );
          final service = CompanionActivityService(
            store: store,
            rolloutMode: () => mode,
          );
          final result = await service.registerTemplate(
            operationId: 'template-${mode.name}',
            template: ActivityTaskTemplate(
              id: 'template-${mode.name}',
              scope: store.scope,
              title: 'Hidden activity',
              cadence: ActivityCadence.daily,
              defaultAwardPoints: 10,
            ),
            recurrence: ActivityRecurrenceRule(
              timeZoneId: 'Etc/UTC',
              offsetAtCreationMinutes: 0,
              localStartMinute: 8 * 60,
              firstLocalDate: ActivityLocalDate(2026, 8, 30),
            ),
          );

          expect(result.status, CompanionActivityMutationStatus.unavailable);
          expect(result.reason, 'companion_activity_rollout_disabled');
          expect(store.writeCount, 0);
          await expectLater(service.snapshot(), throwsA(isA<StateError>()));
        }
      },
    );

    test(
      'rollout revocation at transaction fence prevents queued write',
      () async {
        var mode = FeatureRolloutMode.enforce;
        final store = _MemoryCompanionActivityStore(
          ActivityScope(accountId: 'account-a', facadeGeneration: 7),
        );
        final service = CompanionActivityService(
          store: store,
          rolloutMode: () => mode,
        );
        final gate = store.blockNextTransaction();
        final pending = service.registerTemplate(
          operationId: 'template-revoked',
          template: ActivityTaskTemplate(
            id: 'template-revoked',
            scope: store.scope,
            title: 'Revoked activity',
            cadence: ActivityCadence.daily,
            defaultAwardPoints: 10,
          ),
          recurrence: ActivityRecurrenceRule(
            timeZoneId: 'Etc/UTC',
            offsetAtCreationMinutes: 0,
            localStartMinute: 8 * 60,
            firstLocalDate: ActivityLocalDate(2026, 8, 30),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        mode = FeatureRolloutMode.off;
        gate.complete();

        final result = await pending;
        expect(result.status, CompanionActivityMutationStatus.unavailable);
        expect(result.reason, 'companion_activity_rollout_disabled');
        expect(store.writeCount, 0);
      },
    );

    test(
      'rollout revocation at final store fence prevents late physical write',
      () async {
        var mode = FeatureRolloutMode.enforce;
        var generation = 1;
        final store = _MemoryCompanionActivityStore(
          ActivityScope(accountId: 'account-a', facadeGeneration: 8),
        );
        final service = CompanionActivityService(
          store: store,
          rolloutMode: () => mode,
          rolloutGeneration: () => generation,
        );
        final commitGate = store.blockNextCommit();
        final pending = service.registerTemplate(
          operationId: 'template-final-fence',
          template: ActivityTaskTemplate(
            id: 'template-final-fence',
            scope: store.scope,
            title: 'Late revoked activity',
            cadence: ActivityCadence.daily,
            defaultAwardPoints: 10,
          ),
          recurrence: ActivityRecurrenceRule(
            timeZoneId: 'Etc/UTC',
            offsetAtCreationMinutes: 0,
            localStartMinute: 8 * 60,
            firstLocalDate: ActivityLocalDate(2026, 8, 30),
          ),
        );
        await commitGate.entered;
        mode = FeatureRolloutMode.off;
        generation += 1;
        commitGate.release.complete();

        final fenced = await pending;
        expect(fenced.status, CompanionActivityMutationStatus.unavailable);
        expect(store.writeCount, 0);

        mode = FeatureRolloutMode.enforce;
        generation += 1;
        final retried = await service.registerTemplate(
          operationId: 'template-final-fence',
          template: ActivityTaskTemplate(
            id: 'template-final-fence',
            scope: store.scope,
            title: 'Late revoked activity',
            cadence: ActivityCadence.daily,
            defaultAwardPoints: 10,
          ),
          recurrence: ActivityRecurrenceRule(
            timeZoneId: 'Etc/UTC',
            offsetAtCreationMinutes: 0,
            localStartMinute: 8 * 60,
            firstLocalDate: ActivityLocalDate(2026, 8, 30),
          ),
        );
        expect(retried.status, CompanionActivityMutationStatus.applied);
        expect(store.writeCount, 1);
      },
    );

    test(
      'off then enforce rejects host grant from old rollout epoch',
      () async {
        var mode = FeatureRolloutMode.enforce;
        var generation = 4;
        final harness = _Harness(
          rolloutMode: () => mode,
          rolloutGeneration: () => generation,
        );
        await harness.register();
        final task = (await harness.occurrence(
          operationId: 'occurrence-1',
          date: ActivityLocalDate(2026, 8, 30),
        )).value!;
        final submittedAt = task.availableAt.add(const Duration(minutes: 1));
        final privacyReceipt = harness.privacyReceipt(submittedAt);
        final oldGrant = harness.grant(
          harness.service.submitEvidenceBinding(
            operationId: 'submit-old-rollout',
            evidenceId: 'evidence-old-rollout',
            taskId: task.id,
            artifact: harness.artifact,
            privacyReceipt: privacyReceipt,
            submittedAt: submittedAt,
          ),
        );
        final writesBefore =
            (harness.store as _MemoryCompanionActivityStore).writeCount;

        mode = FeatureRolloutMode.off;
        generation += 1;
        mode = FeatureRolloutMode.enforce;
        generation += 1;
        final rejected = await harness.service.submitEvidence(
          hostGrant: oldGrant,
          operationId: 'submit-old-rollout',
          evidenceId: 'evidence-old-rollout',
          taskId: task.id,
          artifact: harness.artifact,
          privacyReceipt: privacyReceipt,
          submittedAt: submittedAt,
        );

        expect(rejected.status, CompanionActivityMutationStatus.rejected);
        expect(rejected.reason, 'activity_host_authority_invalid');
        expect(
          (harness.store as _MemoryCompanionActivityStore).writeCount,
          writesBefore,
        );
      },
    );

    test(
      'streak credits scheduled local day and accepts bounded backfill',
      () async {
        final harness = _Harness(makeUpWindow: const Duration(hours: 48));
        await harness.register();
        final tasks = <ActivityTask>[];
        for (var day = 30; day <= 32; day++) {
          final date = DateTime.utc(2026, 8, day);
          tasks.add(
            (await harness.occurrence(
              operationId: 'occurrence-$day',
              date: ActivityLocalDate(date.year, date.month, date.day),
            )).value!,
          );
        }
        for (var index = 0; index < tasks.length; index++) {
          final task = tasks[index];
          final submittedAt = index == 0
              ? task.dueAt.add(const Duration(hours: 48))
              : task.availableAt.add(const Duration(minutes: 5));
          await harness.submit(
            task,
            evidenceId: 'evidence-${index + 1}',
            operationId: 'submit-${index + 1}',
            submittedAt: submittedAt,
          );
          await harness.service.reviewEvidence(
            hostGrant: harness.reviewGrant(
              operationId: 'review-${index + 1}',
              evidenceId: 'evidence-${index + 1}',
              decision: ActivityEvidenceReviewState.approved,
              reviewedAt: submittedAt.add(const Duration(minutes: 1)),
            ),
            operationId: 'review-${index + 1}',
            evidenceId: 'evidence-${index + 1}',
            decision: ActivityEvidenceReviewState.approved,
            reviewedAt: submittedAt.add(const Duration(minutes: 1)),
          );
        }

        final streak = await harness.service.streak(
          asOf: ActivityLocalDate(2026, 9, 1),
        );
        expect(streak.current, 3);
        expect(streak.longest, 3);
        expect(streak.completedDates.map((date) => date.toString()), <String>[
          '2026-08-30',
          '2026-08-31',
          '2026-09-01',
        ]);
      },
    );

    test('pending timely evidence survives expiration sweep', () async {
      final harness = _Harness(makeUpWindow: Duration.zero);
      await harness.register();
      final task = (await harness.occurrence(
        operationId: 'occurrence-1',
        date: ActivityLocalDate(2026, 8, 30),
      )).value!;
      await harness.submit(task, submittedAt: task.dueAt);

      final expired = await harness.service.expireDueTasks(
        operationId: 'expire-1',
        at: task.dueAt.add(const Duration(days: 1)),
      );

      expect(expired.value, 0);
      expect(
        (await harness.service.snapshot()).tasks.single.state,
        ActivityTaskState.evidenceSubmitted,
      );
    });

    test('scope, generation, and privacy receipt are fenced', () async {
      final harness = _Harness();
      final wrongScopeTemplate = ActivityTaskTemplate(
        id: 'template-wrong',
        scope: ActivityScope(accountId: 'account-a', facadeGeneration: 2),
        title: 'Wrong scope',
        cadence: ActivityCadence.daily,
        defaultAwardPoints: 20,
      );
      final wrongScope = await harness.service.registerTemplate(
        operationId: 'wrong-scope',
        template: wrongScopeTemplate,
        recurrence: harness.recurrence(),
      );
      expect(wrongScope.reason, 'activity_scope_mismatch');

      await harness.register();
      final task = (await harness.occurrence(
        operationId: 'occurrence-1',
        date: ActivityLocalDate(2026, 8, 30),
      )).value!;
      final staleReceipt = harness.privacyReceipt(
        task.availableAt,
        scope: ActivityScope(accountId: 'account-a', facadeGeneration: 2),
      );
      final staleSubmittedAt = task.availableAt.add(const Duration(minutes: 1));
      final stale = await harness.service.submitEvidence(
        hostGrant: harness.grant(
          harness.service.submitEvidenceBinding(
            operationId: 'submit-stale',
            evidenceId: 'evidence-stale',
            taskId: task.id,
            artifact: harness.artifact,
            privacyReceipt: staleReceipt,
            submittedAt: staleSubmittedAt,
          ),
        ),
        operationId: 'submit-stale',
        evidenceId: 'evidence-stale',
        taskId: task.id,
        artifact: harness.artifact,
        privacyReceipt: staleReceipt,
        submittedAt: staleSubmittedAt,
      );
      expect(stale.reason, 'activity_host_authority_invalid');
    });

    test('privacy transform receipt is consumed exactly once', () async {
      final harness = _Harness();
      await harness.register();
      final firstTask = (await harness.occurrence(
        operationId: 'occurrence-1',
        date: ActivityLocalDate(2026, 8, 30),
      )).value!;
      final secondTask = (await harness.occurrence(
        operationId: 'occurrence-2',
        date: ActivityLocalDate(2026, 8, 31),
      )).value!;
      final submittedAt = firstTask.availableAt.add(const Duration(minutes: 1));
      final receipt = harness.privacyReceipt(submittedAt, id: 'privacy-shared');

      final first = await harness.service.submitEvidence(
        hostGrant: harness.grant(
          harness.service.submitEvidenceBinding(
            operationId: 'submit-1',
            evidenceId: 'evidence-1',
            taskId: firstTask.id,
            artifact: harness.artifact,
            privacyReceipt: receipt,
            submittedAt: submittedAt,
          ),
        ),
        operationId: 'submit-1',
        evidenceId: 'evidence-1',
        taskId: firstTask.id,
        artifact: harness.artifact,
        privacyReceipt: receipt,
        submittedAt: submittedAt,
      );
      final secondSubmittedAt = secondTask.availableAt.add(
        const Duration(minutes: 1),
      );
      final replayed = await harness.service.submitEvidence(
        hostGrant: harness.grant(
          harness.service.submitEvidenceBinding(
            operationId: 'submit-2',
            evidenceId: 'evidence-2',
            taskId: secondTask.id,
            artifact: harness.artifact,
            privacyReceipt: receipt,
            submittedAt: secondSubmittedAt,
          ),
        ),
        operationId: 'submit-2',
        evidenceId: 'evidence-2',
        taskId: secondTask.id,
        artifact: harness.artifact,
        privacyReceipt: receipt,
        submittedAt: secondSubmittedAt,
      );

      expect(first.status, CompanionActivityMutationStatus.applied);
      expect(replayed.status, CompanionActivityMutationStatus.rejected);
      expect(replayed.reason, 'activity_host_authority_invalid');
    });

    test(
      'exact submit retry remains idempotent with fresh host authority',
      () async {
        final harness = _Harness();
        await harness.register();
        final task = (await harness.occurrence(
          operationId: 'occurrence-1',
          date: ActivityLocalDate(2026, 8, 30),
        )).value!;
        final submittedAt = task.availableAt.add(const Duration(minutes: 1));

        final first = await harness.submit(task, submittedAt: submittedAt);
        final replay = await harness.submit(task, submittedAt: submittedAt);

        expect(first.status, CompanionActivityMutationStatus.applied);
        expect(replay.status, CompanionActivityMutationStatus.alreadyApplied);
        expect((await harness.service.snapshot()).evidence, hasLength(1));
      },
    );

    test(
      'persistence contains metadata references but no image payload or path',
      () async {
        final store = _MemoryCompanionActivityStore(
          ActivityScope(accountId: 'account-a', facadeGeneration: 1),
        );
        final harness = _Harness(store: store);
        await harness.register();
        final task = (await harness.occurrence(
          operationId: 'occurrence-1',
          date: ActivityLocalDate(2026, 8, 30),
        )).value!;
        await harness.submit(
          task,
          submittedAt: task.availableAt.add(const Duration(minutes: 1)),
        );

        final encoded = jsonEncode(store.document);
        expect(encoded, contains('thumbnail-object-1'));
        expect(encoded, contains(_derivedDigest));
        for (final forbidden in <String>[
          'filePath',
          'originalPath',
          'sourceBytes',
          'Uint8List',
          '/tmp/',
        ]) {
          expect(encoded, isNot(contains(forbidden)), reason: forbidden);
        }
      },
    );

    test('deactivate drains and fences admitted and stale writes', () async {
      final store = _MemoryCompanionActivityStore(
        ActivityScope(accountId: 'account-a', facadeGeneration: 1),
      );
      final harness = _Harness(store: store);
      final gate = store.blockNextTransaction();
      final admitted = harness.register();
      await pumpEventQueue();

      final draining = harness.service.deactivateAndDrain();
      gate.complete();
      await draining;
      expect(
        (await admitted).status,
        CompanionActivityMutationStatus.unavailable,
      );

      final stale = await harness.service.registerTemplate(
        operationId: 'template-2',
        template: ActivityTaskTemplate(
          id: 'template-2',
          scope: harness.scope,
          title: 'Stale write',
          cadence: ActivityCadence.daily,
          defaultAwardPoints: 10,
        ),
        recurrence: harness.recurrence(),
      );
      expect(stale.status, CompanionActivityMutationStatus.unavailable);
      expect(store.writeCount, 0);
    });
  });
}

final class _Harness {
  _Harness({
    CompanionActivityStore? store,
    this.availabilityWindow = const Duration(hours: 12),
    this.makeUpWindow = const Duration(hours: 24),
    CompanionActivityRolloutReader? rolloutMode,
    CompanionActivityRolloutGenerationReader? rolloutGeneration,
  }) : scope =
           store?.scope ??
           ActivityScope(accountId: 'account-a', facadeGeneration: 1),
       store =
           store ??
           _MemoryCompanionActivityStore(
             ActivityScope(accountId: 'account-a', facadeGeneration: 1),
           ) {
    hostAuthority = CompanionActivityHostAuthority.create();
    privacyAuthority = ActivityEvidencePrivacyAuthority.create();
    service = CompanionActivityService(
      store: this.store,
      rolloutMode: rolloutMode ?? _enforcedActivityRollout,
      rolloutGeneration: rolloutGeneration,
      hostGrantVerifier: hostAuthority.verifier,
      privacyReceiptVerifier: privacyAuthority.verifier,
      clock: () => DateTime.utc(2026, 8, 30, 7),
    );
  }

  final ActivityScope scope;
  final CompanionActivityStore store;
  final Duration availabilityWindow;
  final Duration makeUpWindow;
  late final CompanionActivityService service;
  late final CompanionActivityHostAuthority hostAuthority;
  late final ActivityEvidencePrivacyAuthority privacyAuthority;

  ActivityTaskTemplate get template => ActivityTaskTemplate(
    id: 'template-walk',
    scope: scope,
    title: 'Walk together',
    cadence: ActivityCadence.daily,
    defaultAwardPoints: 20,
    tags: const <String>['wellbeing'],
  );

  ActivityRecurrenceRule recurrence({int offsetMinutes = 0}) =>
      ActivityRecurrenceRule(
        timeZoneId: 'Etc/UTC',
        offsetAtCreationMinutes: offsetMinutes,
        localStartMinute: 8 * 60,
        firstLocalDate: ActivityLocalDate(2026, 8, 30),
        availabilityWindow: availabilityWindow,
        makeUpWindow: makeUpWindow,
      );

  Future<CompanionActivityMutationResult<ActivityTaskTemplate>> register({
    int offsetMinutes = 0,
  }) => service.registerTemplate(
    operationId: 'template-1',
    template: template,
    recurrence: recurrence(offsetMinutes: offsetMinutes),
  );

  Future<CompanionActivityMutationResult<ActivityTask>> occurrence({
    required String operationId,
    required ActivityLocalDate date,
  }) => service.createOccurrence(
    operationId: operationId,
    templateId: template.id,
    localDate: date,
  );

  ActivityEvidenceArtifact get artifact => ActivityEvidenceArtifact(
    localObjectId: 'thumbnail-object-1',
    derivedSha256: _derivedDigest,
    mimeType: 'image/jpeg',
    byteLength: 24000,
    pixelWidth: 640,
    pixelHeight: 480,
  );

  ActivityEvidencePrivacyReceipt privacyReceipt(
    DateTime submittedAt, {
    ActivityScope? scope,
    String id = 'privacy-1',
  }) {
    final receiptScope = scope ?? this.scope;
    return privacyAuthority.issuer.issue(
      id: id,
      accountId: receiptScope.accountId,
      facadeGeneration: receiptScope.facadeGeneration,
      sourceSha256: _sourceDigest,
      derivedSha256: _derivedDigest,
      transformedAt: submittedAt.subtract(const Duration(seconds: 1)),
    );
  }

  CompanionActivityHostGrant grant(
    CompanionActivityHostMutationBinding binding,
  ) => hostAuthority.issuer.issue(
    binding: binding,
    expiresAt: DateTime.utc(2026, 8, 31),
  );

  CompanionActivityHostGrant reviewGrant({
    required String operationId,
    required String evidenceId,
    required ActivityEvidenceReviewState decision,
    required DateTime reviewedAt,
  }) => grant(
    service.reviewEvidenceBinding(
      operationId: operationId,
      evidenceId: evidenceId,
      decision: decision,
      reviewedAt: reviewedAt,
    ),
  );

  CompanionActivityHostGrant redeemGrant({
    required VirtualRewardRedemptionRequest request,
    required VirtualReward reward,
  }) => grant(service.redeemBinding(request: request, reward: reward));

  Future<CompanionActivityMutationResult<ActivityEvidence>> submit(
    ActivityTask task, {
    required DateTime submittedAt,
    String evidenceId = 'evidence-1',
    String operationId = 'submit-1',
  }) {
    final receipt = privacyReceipt(submittedAt, id: 'privacy-$evidenceId');
    return service.submitEvidence(
      hostGrant: grant(
        service.submitEvidenceBinding(
          operationId: operationId,
          evidenceId: evidenceId,
          taskId: task.id,
          artifact: artifact,
          privacyReceipt: receipt,
          submittedAt: submittedAt,
        ),
      ),
      operationId: operationId,
      evidenceId: evidenceId,
      taskId: task.id,
      artifact: artifact,
      privacyReceipt: receipt,
      submittedAt: submittedAt,
    );
  }
}

final class _MemoryCompanionActivityStore implements CompanionActivityStore {
  _MemoryCompanionActivityStore(this.scope);

  @override
  final ActivityScope scope;

  Map<String, Object?>? document;
  int writeCount = 0;
  bool _active = true;
  Future<void> _tail = Future<void>.value();
  Completer<void>? _nextGate;
  Completer<void>? _nextCommitGate;
  Completer<void>? _nextCommitEntered;

  Completer<void> blockNextTransaction() {
    final gate = Completer<void>();
    _nextGate = gate;
    return gate;
  }

  ({Future<void> entered, Completer<void> release}) blockNextCommit() {
    final entered = Completer<void>();
    final release = Completer<void>();
    _nextCommitEntered = entered;
    _nextCommitGate = release;
    return (entered: entered.future, release: release);
  }

  @override
  Future<T> transaction<T>(CompanionActivityStoreTransaction<T> mutation) {
    if (!_active) {
      return Future<T>.error(StateError('companion_activity_store_inactive'));
    }
    final completer = Completer<T>();
    final gate = _nextGate;
    _nextGate = null;
    _tail = _tail.then((_) async {
      if (gate != null) await gate.future;
      try {
        final result = await mutation(_copy(document));
        if (result.write) {
          final commitGate = _nextCommitGate;
          final commitEntered = _nextCommitEntered;
          _nextCommitGate = null;
          _nextCommitEntered = null;
          if (commitGate != null) {
            commitEntered?.complete();
            await commitGate.future;
          }
          if (result.finalWriteFence?.call() == false) {
            throw StateError('companion_activity_final_write_fenced');
          }
          document = _copy(result.document);
          writeCount += 1;
        }
        completer.complete(result.value);
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  Future<Map<String, Object?>?> read() async {
    if (!_active) throw StateError('companion_activity_store_inactive');
    await _tail;
    return _copy(document);
  }

  @override
  Future<void> deactivateAndDrain() async {
    _active = false;
    await _tail;
  }

  static Map<String, Object?>? _copy(Map<String, Object?>? source) =>
      source == null
      ? null
      : Map<String, Object?>.from(
          jsonDecode(jsonEncode(source)) as Map<String, dynamic>,
        );
}

const _sourceDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _derivedDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

FeatureRolloutMode _enforcedActivityRollout() => FeatureRolloutMode.enforce;
