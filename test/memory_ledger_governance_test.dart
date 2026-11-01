import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  test(
    'accept edit delete and restore append revisions and atomically move the head',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      final pending = await harness.writePending('用户喜欢乌龙茶');

      final accepted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: pending.id!,
          expectedHeadEpisodeId: pending.id!,
          expectedRevision: 1,
        ),
      );

      expect(accepted.status, MemoryGovernanceStatus.applied);
      expect(accepted.episode!.reviewState, EpisodeReviewState.accepted);
      expect(accepted.episode!.revision, 2);
      expect(accepted.episode!.supersedesId, pending.id);
      expect(await harness.store.isRecallEligible(pending), isFalse);
      expect(await harness.store.isRecallEligible(accepted.episode!), isTrue);
      expect(harness.linked, <int>[accepted.episodeId!]);
      expect(harness.milestoned, <int>[accepted.episodeId!]);

      final edited = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.edit,
          targetEpisodeId: accepted.episodeId!,
          expectedHeadEpisodeId: accepted.episodeId!,
          expectedRevision: 2,
          edit: const MemoryEpisodeEdit(what: '用户最喜欢焙火乌龙茶'),
        ),
      );
      expect(edited.status, MemoryGovernanceStatus.applied);
      expect(edited.episode!.what, '用户最喜欢焙火乌龙茶');
      expect(edited.episode!.revision, 3);
      expect(edited.episode!.supersedesId, accepted.episodeId);
      expect(harness.unlinked, contains(accepted.episodeId));
      expect(harness.linked, contains(edited.episodeId));

      final diff = await harness.ledger.diff(
        accepted.episodeId!,
        edited.episodeId!,
      );
      expect(diff.sameLineage, isTrue);
      expect(
        diff.changes,
        contains(
          const MemoryRevisionFieldChange(
            field: 'what',
            before: '用户喜欢乌龙茶',
            after: '用户最喜欢焙火乌龙茶',
          ),
        ),
      );

      final deleted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: edited.episodeId!,
          expectedHeadEpisodeId: edited.episodeId!,
          expectedRevision: 3,
        ),
      );
      expect(deleted.status, MemoryGovernanceStatus.applied);
      expect(deleted.episode!.reviewState, EpisodeReviewState.tombstoned);
      expect(await harness.store.isRecallEligible(deleted.episode!), isFalse);

      final restored = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.restore,
          targetEpisodeId: deleted.episodeId!,
          expectedHeadEpisodeId: deleted.episodeId!,
          expectedRevision: 4,
        ),
      );
      expect(restored.status, MemoryGovernanceStatus.applied);
      expect(restored.episode!.reviewState, EpisodeReviewState.accepted);
      expect(restored.episode!.revision, 5);
      expect(restored.episode!.what, '用户最喜欢焙火乌龙茶');
      expect(restored.episode!.supersedesId, deleted.episodeId);

      final originalRaw = await MemoryGovernanceStores.episodes
          .record(pending.id!)
          .get(harness.database);
      expect(originalRaw?['reviewState'], EpisodeReviewState.pending.name);
      expect(originalRaw?['revision'], 1);
      final head = await MemoryGovernanceStores.revisionHeads
          .record(pending.id!)
          .get(harness.database);
      expect(head?['headEpisodeId'], restored.episodeId);
      expect(head?['revision'], 5);

      final page = await harness.ledger.list(limit: 3);
      expect(page.entries, hasLength(3));
      expect(page.entries.first.episode.id, restored.episodeId);
      expect(page.nextBeforeEpisodeId, isNotNull);
      final revisions = await harness.ledger.revisions(restored.episodeId!);
      expect(revisions.map((entry) => entry.episode.revision), <int>[
        5,
        4,
        3,
        2,
        1,
      ]);
    },
  );

  test('reject appends a non-recallable revision', () async {
    final harness = await _LedgerHarness.open();
    addTearDown(harness.close);
    final pending = await harness.writePending('未经确认的自动摘要');

    final rejected = await harness.ledger.review(
      MemoryGovernanceCommand(
        action: MemoryGovernanceAction.reject,
        targetEpisodeId: pending.id!,
        expectedHeadEpisodeId: pending.id!,
        expectedRevision: pending.revision,
      ),
    );

    expect(rejected.status, MemoryGovernanceStatus.applied);
    expect(rejected.episode!.reviewState, EpisodeReviewState.rejected);
    expect(rejected.episode!.supersedesId, pending.id);
    expect(await harness.store.isRecallEligible(rejected.episode!), isFalse);
  });

  test(
    'expired retention cannot be cleared by delete or reject before restore',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      for (final seed in <(EpisodeReviewState, MemoryGovernanceAction)>[
        (EpisodeReviewState.accepted, MemoryGovernanceAction.delete),
        (EpisodeReviewState.pending, MemoryGovernanceAction.reject),
      ]) {
        final original = await harness.seedGovernedEpisode(
          what: 'expired-${seed.$1.name}',
          reviewState: seed.$1,
          expiresAt: DateTime.parse(_now).subtract(const Duration(minutes: 1)),
        );
        final inactive = await harness.ledger.review(
          MemoryGovernanceCommand(
            action: seed.$2,
            targetEpisodeId: original.id!,
            expectedHeadEpisodeId: original.id!,
            expectedRevision: original.revision,
          ),
        );
        expect(inactive.status, MemoryGovernanceStatus.applied);
        expect(inactive.episode!.expiresAt, isNull);

        final restore = await harness.ledger.review(
          MemoryGovernanceCommand(
            action: MemoryGovernanceAction.restore,
            targetEpisodeId: inactive.episodeId!,
            expectedHeadEpisodeId: inactive.episodeId!,
            expectedRevision: inactive.revision!,
          ),
        );

        expect(restore.status, MemoryGovernanceStatus.invalid);
        expect(restore.reason, 'expired_memory_cannot_activate');
      }
    },
  );

  test(
    'accept appends a reviewed revision for an accepted legacy head',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      final legacyRaw = Episode(
        when: DateTime.parse(_now),
        what: '旧版本长期记忆',
      ).toLegacyJson();
      final legacyId = await MemoryGovernanceStores.episodes.add(
        harness.database,
        legacyRaw,
      );

      final accepted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: legacyId,
          expectedHeadEpisodeId: legacyId,
          expectedRevision: 1,
        ),
      );

      expect(accepted.status, MemoryGovernanceStatus.applied);
      expect(accepted.episode!.reviewState, EpisodeReviewState.accepted);
      expect(accepted.episode!.sourceType, EpisodeSourceType.runtimeUnknown);
      expect(accepted.episode!.supersedesId, legacyId);
      expect(accepted.episode!.revision, 2);
      expect(
        await MemoryGovernanceStores.episodes
            .record(legacyId)
            .get(harness.database),
        legacyRaw,
      );
    },
  );

  test(
    'bounded ledger pages have no gaps when limit is below read batch',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      final inserted = <int>[];
      for (var index = 0; index < 70; index++) {
        inserted.add(
          await MemoryGovernanceStores.episodes.add(
            harness.database,
            Episode(
              when: DateTime.utc(2026, 8, 30, 10, index),
              what: 'legacy-$index',
            ).toLegacyJson(),
          ),
        );
      }

      final first = await harness.ledger.list(limit: 20);
      final second = await harness.ledger.list(
        beforeEpisodeId: first.nextBeforeEpisodeId,
        limit: 20,
      );

      final expected = inserted.reversed.take(40).toList();
      final actual = <int>[
        ...first.entries.map((entry) => entry.episode.id!),
        ...second.entries.map((entry) => entry.episode.id!),
      ];
      expect(actual, expected);
      expect(actual.toSet(), hasLength(40));
    },
  );

  test('stale expected head conflicts without appending or auditing', () async {
    final harness = await _LedgerHarness.open();
    addTearDown(harness.close);
    final pending = await harness.writePending('需要审核');
    final first = await harness.ledger.review(
      MemoryGovernanceCommand(
        action: MemoryGovernanceAction.accept,
        targetEpisodeId: pending.id!,
        expectedHeadEpisodeId: pending.id!,
        expectedRevision: 1,
      ),
    );
    final beforeEpisodes = await MemoryGovernanceStores.episodes.count(
      harness.database,
    );
    final beforeAudits = await MemoryGovernanceStores.audit.count(
      harness.database,
    );

    final stale = await harness.ledger.review(
      MemoryGovernanceCommand(
        action: MemoryGovernanceAction.delete,
        targetEpisodeId: pending.id!,
        expectedHeadEpisodeId: pending.id!,
        expectedRevision: 1,
      ),
    );

    expect(first.status, MemoryGovernanceStatus.applied);
    expect(stale.status, MemoryGovernanceStatus.conflict);
    expect(stale.reason, 'stale_memory_revision');
    expect(
      await MemoryGovernanceStores.episodes.count(harness.database),
      beforeEpisodes,
    );
    expect(
      await MemoryGovernanceStores.audit.count(harness.database),
      beforeAudits,
    );
  });

  test(
    'editing removes stale content fingerprints so replay cannot return the old non-current row',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      final pending = await harness.writePending('旧文本');
      final accepted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: pending.id!,
          expectedHeadEpisodeId: pending.id!,
          expectedRevision: 1,
        ),
      );
      final edited = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.edit,
          targetEpisodeId: accepted.episodeId!,
          expectedHeadEpisodeId: accepted.episodeId!,
          expectedRevision: 2,
          edit: const MemoryEpisodeEdit(what: '新文本'),
        ),
      );

      final replay = await harness.writePendingResult('旧文本');
      final editedReplay = await harness.writePendingResult('新文本');

      expect(edited.status, MemoryGovernanceStatus.applied);
      expect(replay.disposition, isNot(MemoryWriteDisposition.duplicate));
      expect(replay.episodeId, isNot(accepted.episodeId));
      expect(replay.episode!.reviewState, EpisodeReviewState.pending);
      expect(editedReplay.disposition, MemoryWriteDisposition.duplicate);
      expect(editedReplay.episodeId, edited.episodeId);
    },
  );

  test(
    'accepted governance retries incomplete milestone projection on exact replay',
    () async {
      var failMilestoneOnce = true;
      final harness = await _LedgerHarness.open(
        projectMilestone: (episode) async {
          if (failMilestoneOnce) {
            failMilestoneOnce = false;
            throw StateError('injected_milestone_failure');
          }
        },
      );
      addTearDown(harness.close);
      final pending = await harness.writePending('需要补偿里程碑');

      final accepted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: pending.id!,
          expectedHeadEpisodeId: pending.id!,
          expectedRevision: pending.revision,
        ),
      );
      final incomplete = await MemoryGovernanceStores.episodeGovernance
          .record(accepted.episodeId!)
          .get(harness.database);

      expect(accepted.status, MemoryGovernanceStatus.applied);
      expect(accepted.projected, isFalse);
      expect(incomplete?['projectionLinkComplete'], isTrue);
      expect(incomplete?['projectionMilestoneComplete'], isFalse);

      final replay = await harness.writeAcceptedEventResult('需要补偿里程碑');
      final repaired = await MemoryGovernanceStores.episodeGovernance
          .record(accepted.episodeId!)
          .get(harness.database);

      expect(replay.disposition, MemoryWriteDisposition.duplicate);
      expect(replay.episodeId, accepted.episodeId);
      expect(replay.projected, isTrue);
      expect(repaired?['projectionLinkComplete'], isTrue);
      expect(repaired?['projectionMilestoneComplete'], isTrue);
      expect(harness.linked, <int>[accepted.episodeId!]);
      expect(harness.milestoned, <int>[accepted.episodeId!]);
    },
  );

  test(
    'accepted governance retries predecessor unlink on exact replay',
    () async {
      var removeAttempts = 0;
      final harness = await _LedgerHarness.open(
        removeEpisodeLinks: (_) async {
          removeAttempts++;
          if (removeAttempts == 1) {
            throw StateError('injected_unlink_failure');
          }
        },
      );
      addTearDown(harness.close);
      final pending = await harness.writePending('需要补偿旧图边');

      final accepted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: pending.id!,
          expectedHeadEpisodeId: pending.id!,
          expectedRevision: pending.revision,
        ),
      );
      final incompletePredecessor = await MemoryGovernanceStores
          .episodeGovernance
          .record(pending.id!)
          .get(harness.database);

      expect(accepted.status, MemoryGovernanceStatus.applied);
      expect(accepted.projected, isFalse);
      expect(incompletePredecessor?['projectionUnlinkComplete'], isFalse);
      expect(removeAttempts, 1);
      expect(harness.unlinked, isEmpty);

      final replay = await harness.writeAcceptedEventResult('需要补偿旧图边');
      final repairedPredecessor = await MemoryGovernanceStores.episodeGovernance
          .record(pending.id!)
          .get(harness.database);

      expect(replay.disposition, MemoryWriteDisposition.duplicate);
      expect(replay.episodeId, accepted.episodeId);
      expect(replay.projected, isTrue);
      expect(repairedPredecessor?['projectionUnlinkComplete'], isTrue);
      expect(removeAttempts, 2);
      expect(harness.unlinked, <int>[pending.id!]);
    },
  );

  test('adjacent revision diff remains available after revision 64', () async {
    final harness = await _LedgerHarness.open();
    addTearDown(harness.close);
    final pending = await harness.writePending('revision-1');
    var current = (await harness.ledger.review(
      MemoryGovernanceCommand(
        action: MemoryGovernanceAction.accept,
        targetEpisodeId: pending.id!,
        expectedHeadEpisodeId: pending.id!,
        expectedRevision: pending.revision,
      ),
    )).episode!;
    late Episode previous;
    for (var revision = 3; revision <= 65; revision++) {
      previous = current;
      current = (await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.edit,
          targetEpisodeId: current.id!,
          expectedHeadEpisodeId: current.id!,
          expectedRevision: current.revision,
          edit: MemoryEpisodeEdit(what: 'revision-$revision'),
        ),
      )).episode!;
    }

    final diff = await harness.ledger.diff(previous.id!, current.id!);

    expect(previous.revision, 64);
    expect(current.revision, 65);
    expect(diff.sameLineage, isTrue);
    expect(
      diff.changes,
      contains(
        const MemoryRevisionFieldChange(
          field: 'what',
          before: 'revision-64',
          after: 'revision-65',
        ),
      ),
    );
  });

  test(
    'an exact source replay cannot implicitly restore a deleted memory',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      final accepted = await harness.writeAcceptedEventResult('待删除文本');
      final deleted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: accepted.episodeId!,
          expectedHeadEpisodeId: accepted.episodeId!,
          expectedRevision: 1,
        ),
      );
      final countAfterDelete = await MemoryGovernanceStores.episodes.count(
        harness.database,
      );

      final replay = await harness.writeAcceptedEventResult('待删除文本');

      expect(deleted.status, MemoryGovernanceStatus.applied);
      expect(replay.disposition, MemoryWriteDisposition.duplicate);
      expect(replay.created, isFalse);
      expect(replay.episodeId, deleted.episodeId);
      expect(
        await MemoryGovernanceStores.episodes.count(harness.database),
        countAfterDelete,
      );
      expect(await harness.store.isRecallEligible(replay.episode!), isFalse);
    },
  );

  test(
    'normal claim writes advance the governed lineage head transactionally',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      final initial = await harness.writeAcceptedClaim(
        slot: 'favorite-color',
        value: 'blue',
        what: '用户喜欢蓝色',
      );
      final deleted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: initial.id!,
          expectedHeadEpisodeId: initial.id!,
          expectedRevision: 1,
        ),
      );
      final restored = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.restore,
          targetEpisodeId: deleted.episodeId!,
          expectedHeadEpisodeId: deleted.episodeId!,
          expectedRevision: 2,
        ),
      );

      final changed = await harness.writeAcceptedClaim(
        slot: 'favorite-color',
        value: 'green',
        what: '用户喜欢绿色',
      );

      expect(changed.revision, 4);
      expect(changed.supersedesId, restored.episodeId);
      final head = await MemoryGovernanceStores.revisionHeads
          .record(initial.id!)
          .get(harness.database);
      expect(head?['headEpisodeId'], changed.id);
      expect(head?['revision'], 4);
      final changedGovernance = await MemoryGovernanceStores.episodeGovernance
          .record(changed.id!)
          .get(harness.database);
      expect(changedGovernance?['lineageId'], initial.id);

      final reviewed = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: changed.id!,
          expectedHeadEpisodeId: changed.id!,
          expectedRevision: 4,
        ),
      );
      expect(reviewed.status, MemoryGovernanceStatus.applied);
      expect(reviewed.episode!.revision, 5);
    },
  );

  test('governance command enforces safe ids and bounded edit text', () {
    const unsafeInteger = 0x20000000000000;
    expect(
      () => MemoryGovernanceCommand(
        action: MemoryGovernanceAction.delete,
        targetEpisodeId: unsafeInteger,
        expectedHeadEpisodeId: 1,
        expectedRevision: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => MemoryGovernanceCommand(
        action: MemoryGovernanceAction.delete,
        targetEpisodeId: 1,
        expectedHeadEpisodeId: unsafeInteger,
        expectedRevision: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => MemoryGovernanceCommand(
        action: MemoryGovernanceAction.delete,
        targetEpisodeId: 1,
        expectedHeadEpisodeId: 1,
        expectedRevision: unsafeInteger,
      ),
      throwsArgumentError,
    );
    expect(
      () => MemoryGovernanceCommand(
        action: MemoryGovernanceAction.edit,
        targetEpisodeId: 1,
        expectedHeadEpisodeId: 1,
        expectedRevision: 1,
        edit: MemoryEpisodeEdit(what: List<String>.filled(4097, 'x').join()),
      ),
      throwsArgumentError,
    );
    expect(
      () => MemoryGovernanceCommand(
        action: MemoryGovernanceAction.edit,
        targetEpisodeId: 1,
        expectedHeadEpisodeId: 1,
        expectedRevision: 1,
        edit: const MemoryEpisodeEdit(what: '   '),
      ),
      throwsArgumentError,
    );
  });

  test(
    'claim semantic edit fails closed without changing the claim head',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      final claim = await harness.writeAcceptedClaim(
        slot: 'favorite_color',
        value: 'blue',
        what: '用户最喜欢蓝色',
      );
      final governanceBefore = await MemoryGovernanceStores.episodeGovernance
          .record(claim.id!)
          .get(harness.database);
      final slotFingerprint =
          governanceBefore?['claimSlotFingerprint'] as String;
      final headBefore = await MemoryGovernanceStores.claimHeads
          .record(slotFingerprint)
          .get(harness.database);

      final result = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.edit,
          targetEpisodeId: claim.id!,
          expectedHeadEpisodeId: claim.id!,
          expectedRevision: 1,
          edit: const MemoryEpisodeEdit(what: '用户最喜欢绿色'),
        ),
      );

      expect(result.status, MemoryGovernanceStatus.invalid);
      expect(result.reason, 'claim_semantic_edit_requires_structured_claim');
      expect(await MemoryGovernanceStores.episodes.count(harness.database), 1);
      expect(
        await MemoryGovernanceStores.claimHeads
            .record(slotFingerprint)
            .get(harness.database),
        headBefore,
      );
    },
  );

  test(
    'review transaction rolls back payload governance index head and audit',
    () async {
      var failReview = false;
      final harness = await _LedgerHarness.open(
        faultInjector: (point, fingerprint) {
          if (failReview && point == MemoryWriteFaultPoint.beforeCommit) {
            throw StateError('injected_review_failure');
          }
        },
      );
      addTearDown(harness.close);
      final pending = await harness.writePending('事务必须完整');
      final beforeEpisodes = await MemoryGovernanceStores.episodes.count(
        harness.database,
      );
      final beforeAudits = await MemoryGovernanceStores.audit.count(
        harness.database,
      );
      final beforeHeads = await MemoryGovernanceStores.revisionHeads.count(
        harness.database,
      );
      failReview = true;

      await expectLater(
        harness.ledger.review(
          MemoryGovernanceCommand(
            action: MemoryGovernanceAction.accept,
            targetEpisodeId: pending.id!,
            expectedHeadEpisodeId: pending.id!,
            expectedRevision: 1,
          ),
        ),
        throwsA(isA<StateError>()),
      );

      expect(
        await MemoryGovernanceStores.episodes.count(harness.database),
        beforeEpisodes,
      );
      expect(
        await MemoryGovernanceStores.audit.count(harness.database),
        beforeAudits,
      );
      expect(
        await MemoryGovernanceStores.revisionHeads.count(harness.database),
        beforeHeads,
      );
      final governance = await MemoryGovernanceStores.episodeGovernance
          .record(pending.id!)
          .get(harness.database);
      expect(governance?['supersededByEpisodeId'], isNull);
    },
  );

  test(
    'source transcript verifies imported and conversation source hashes',
    () async {
      final harness = await _LedgerHarness.open();
      addTearDown(harness.close);
      final imported = await harness.writePending('导入来源原文');
      final importedSource = imported.sourceRefs.single;

      final verifiedImported = await harness.ledger.sourceTranscript(
        importedSource,
      );
      expect(verifiedImported.status, MemorySourceTranscriptStatus.verified);
      expect(verifiedImported.content, '导入来源原文');

      final wrongImportedSession = EpisodeSourceRef(
        sourceId: importedSource.sourceId,
        sessionId: 'memory_manager_facts_v1:wrong-source-identity',
        origin: importedSource.origin,
        contentHash: importedSource.contentHash,
      );
      expect(
        (await harness.ledger.sourceTranscript(wrongImportedSession)).status,
        MemorySourceTranscriptStatus.integrityFailure,
      );

      final material = await MemoryGovernanceStores.sourceMaterial
          .record(importedSource.sourceId)
          .get(harness.database);
      await MemoryGovernanceStores.sourceMaterial
          .record(importedSource.sourceId)
          .put(harness.database, <String, Object?>{
            ...material!,
            'sourceKind': List<String>.filled(65, 'x').join(),
          });
      expect(
        (await harness.ledger.sourceTranscript(importedSource)).status,
        MemorySourceTranscriptStatus.integrityFailure,
      );
      await MemoryGovernanceStores.sourceMaterial
          .record(importedSource.sourceId)
          .put(harness.database, <String, Object?>{
            ...material,
            'canonicalMaterial': 'tampered',
          });
      expect(
        (await harness.ledger.sourceTranscript(importedSource)).status,
        MemorySourceTranscriptStatus.integrityFailure,
      );

      final messageId = await harness.persistHumanMessage('这是精确聊天来源');
      final conversation = await harness.writeConversation(messageId, '聊天摘要');
      final verifiedConversation = await harness.ledger.sourceTranscript(
        conversation.sourceRefs.single,
      );
      expect(
        verifiedConversation.status,
        MemorySourceTranscriptStatus.verified,
      );
      expect(verifiedConversation.content, '这是精确聊天来源');
    },
  );

  test(
    'ledger retirement fences new reads and drains admitted review work',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var blockReview = false;
      final harness = await _LedgerHarness.open(
        faultInjector: (point, fingerprint) async {
          if (blockReview && point == MemoryWriteFaultPoint.beforeCommit) {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
        },
      );
      addTearDown(harness.close);
      final pending = await harness.writePending('排空中的审核');
      blockReview = true;
      final review = harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: pending.id!,
          expectedHeadEpisodeId: pending.id!,
          expectedRevision: 1,
        ),
      );
      await entered.future;

      var drained = false;
      final drain = harness.ledger.deactivateAndDrain().then(
        (_) => drained = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(harness.ledger.acceptsRequests, isFalse);
      await expectLater(
        harness.ledger.list(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'memory_ledger_service_retired',
          ),
        ),
      );

      release.complete();
      expect((await review).status, MemoryGovernanceStatus.applied);
      await drain;
      expect(drained, isTrue);
    },
  );
}

const _accountDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _now = '2026-08-30T10:00:00.000Z';

final class _LedgerHarness {
  _LedgerHarness({
    required this.database,
    required this.store,
    required this.coordinator,
    required this.ledger,
    required this.linked,
    required this.unlinked,
    required this.milestoned,
  });

  final Database database;
  final EpisodeStore store;
  final MemoryWriteCoordinator coordinator;
  final MemoryLedgerService ledger;
  final List<int> linked;
  final List<int> unlinked;
  final List<int> milestoned;

  static Future<_LedgerHarness> open({
    MemoryWriteFaultInjector? faultInjector,
    Future<void> Function(Episode episode)? projectMilestone,
    Future<void> Function(int episodeId)? removeEpisodeLinks,
  }) async {
    final database = await databaseFactoryMemory.openDatabase(
      'memory-ledger-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final store = EpisodeStore(
      database: database,
      accountScopeDigest: _accountDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      clock: () => DateTime.parse(_now),
    );
    final linked = <int>[];
    final unlinked = <int>[];
    final milestoned = <int>[];
    final coordinator = MemoryWriteCoordinator(
      database: database,
      episodeStore: store,
      accountScopeDigest: _accountDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      clock: () => DateTime.parse(_now),
      linkEpisode: (episode) async => linked.add(episode.id!),
      removeEpisodeLinks: (episodeId) async {
        await removeEpisodeLinks?.call(episodeId);
        unlinked.add(episodeId);
      },
      projectMilestone: (episode) async {
        await projectMilestone?.call(episode);
        milestoned.add(episode.id!);
      },
      faultInjector: faultInjector,
    );
    final ledger = MemoryLedgerService(
      database: database,
      coordinator: coordinator,
      accountScopeDigest: _accountDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      clock: () => DateTime.parse(_now),
    );
    return _LedgerHarness(
      database: database,
      store: store,
      coordinator: coordinator,
      ledger: ledger,
      linked: linked,
      unlinked: unlinked,
      milestoned: milestoned,
    );
  }

  Future<Episode> seedGovernedEpisode({
    required String what,
    required EpisodeReviewState reviewState,
    required DateTime expiresAt,
  }) async {
    final episode = Episode(
      when: expiresAt.subtract(const Duration(days: 1)),
      what: what,
      reviewState: reviewState,
      expiresAt: expiresAt,
    );
    final id = await MemoryGovernanceStores.episodes.add(
      database,
      episode.toJson(),
    );
    episode.id = id;
    await MemoryGovernanceStores.episodeGovernance
        .record(id)
        .put(database, <String, Object?>{
          'schemaVersion': 1,
          'accountScopeDigest': _accountDigest,
          'episodeId': id,
          'current': reviewState == EpisodeReviewState.accepted,
          'reviewState': reviewState.name,
          'lineageId': id,
          'supersededByEpisodeId': null,
          'projectionLinkComplete': reviewState == EpisodeReviewState.accepted,
          'projectionMilestoneComplete':
              reviewState == EpisodeReviewState.accepted,
          'writtenAt': episode.createdAt.millisecondsSinceEpoch,
          'updatedAt': episode.updatedAt.millisecondsSinceEpoch,
        });
    await MemoryGovernanceStores.revisionHeads
        .record(id)
        .put(database, <String, Object?>{
          'schemaVersion': 1,
          'accountScopeDigest': _accountDigest,
          'lineageId': id,
          'headEpisodeId': id,
          'revision': episode.revision,
          'reviewState': reviewState.name,
          'updatedAt': episode.updatedAt.millisecondsSinceEpoch,
        });
    return episode;
  }

  Future<Episode> writePending(String what) async {
    final result = await writePendingResult(what);
    return result.episode!;
  }

  Future<MemoryWriteResult> writePendingResult(String what) =>
      coordinator.write(
        MemoryWriteDraft.event(what: what, when: DateTime.parse(_now)),
        source: MemoryWriteSource.imported(
          sourceKind: 'ledger-test',
          sourceKey: what,
          canonicalMaterial: what,
        ),
        authority: MemoryWriteAuthority.inherited,
      );

  Future<MemoryWriteResult> writeAcceptedEventResult(String what) =>
      coordinator.write(
        MemoryWriteDraft.event(what: what, when: DateTime.parse(_now)),
        source: MemoryWriteSource.imported(
          sourceKind: 'ledger-test',
          sourceKey: what,
          canonicalMaterial: what,
        ),
        authority: MemoryWriteAuthority.verifiedHost,
      );

  Future<Episode> writeAcceptedClaim({
    required String slot,
    required String value,
    required String what,
  }) async {
    final result = await coordinator.write(
      MemoryWriteDraft.claim(
        slot: slot,
        value: value,
        summary: what,
        when: DateTime.parse(_now),
      ),
      source: MemoryWriteSource.imported(
        sourceKind: 'ledger-test',
        sourceKey: '$slot:$value',
        canonicalMaterial: what,
      ),
      authority: MemoryWriteAuthority.verifiedHost,
    );
    return result.episode!;
  }

  Future<int> persistHumanMessage(String content) async {
    final message = ChatMessage(
      sessionId: 'self',
      senderId: 'user',
      receiverId: 'agent-a',
      content: content,
      timestamp: DateTime.parse(_now),
      isUserMessage: true,
      turnOrigin: ChatMessageTurnOrigins.user,
    );
    return MemoryGovernanceStores.chatMessages.add(database, message.toJson());
  }

  Future<Episode> writeConversation(int messageId, String what) async {
    return coordinator.runWithPersistedChatSource(
      messageRecordId: messageId,
      sessionId: 'self',
      agentId: 'agent-a',
      operation: () async {
        final result = await coordinator.write(
          MemoryWriteDraft.event(what: what, when: DateTime.parse(_now)),
          authority: MemoryWriteAuthority.verifiedHost,
        );
        return result.episode!;
      },
    );
  }

  Future<void> close() async {
    await ledger.deactivateAndDrain();
    await coordinator.deactivateAndDrain();
    await store.deactivateAndDrain();
    ledger.closeLifecycle();
    coordinator.closeLifecycle();
    store.closeLifecycle();
    await database.close();
  }
}
