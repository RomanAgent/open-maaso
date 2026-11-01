import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';
import 'package:maaso/src/core/services/memory_recall_safety_gate.dart';
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
    'runtime rollback stops v2 writes without losing governed revisions',
    () async {
      final harness = await _RollbackHarness.open();
      addTearDown(harness.close);

      final pending = await harness.writeFromHumanMessage(
        source: 'Today I chose the rollback-v2-anchor notebook.',
        memory: 'I chose the rollback-v2-anchor notebook.',
      );
      expect(pending.disposition, MemoryWriteDisposition.quarantined);
      expect(pending.episode!.reviewState, EpisodeReviewState.pending);

      final accepted = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: pending.episodeId!,
          expectedHeadEpisodeId: pending.episodeId!,
          expectedRevision: pending.episode!.revision,
        ),
      );
      expect(accepted.status, MemoryGovernanceStatus.applied);
      expect(accepted.episode!.revision, 2);
      expect(accepted.episode!.supersedesId, pending.episodeId);

      final pendingRawBefore = Map<String, Object?>.from(
        (await MemoryGovernanceStores.episodes
            .record(pending.episodeId!)
            .get(harness.database))!,
      );
      final acceptedRawBefore = Map<String, Object?>.from(
        (await MemoryGovernanceStores.episodes
            .record(accepted.episodeId!)
            .get(harness.database))!,
      );
      final sidecarsBefore = await _governanceSnapshot(harness.database);
      final episodeCountBeforeRollback = await MemoryGovernanceStores.episodes
          .count(harness.database);

      harness.mode = FeatureRolloutMode.off;
      final legacy = await harness.bus.writeEpisodeWithResult(
        Episode(
          when: _now.add(const Duration(minutes: 1)),
          what: 'rollback-legacy-anchor remains writable',
          entities: const <String>['rollback'],
          salience: 0.6,
        ),
      );

      expect(legacy.disposition, MemoryWriteDisposition.legacy);
      expect(legacy.created, isTrue);
      expect(legacy.projected, isTrue);
      final legacyRaw = await MemoryGovernanceStores.episodes
          .record(legacy.episodeId!)
          .get(harness.database);
      expect(legacyRaw, legacy.episode!.toLegacyJson());
      expect(legacyRaw, isNot(contains('schemaVersion')));
      expect(legacyRaw, isNot(contains('sourceRefs')));
      expect(
        await MemoryGovernanceStores.episodeGovernance
            .record(legacy.episodeId!)
            .get(harness.database),
        isNull,
      );
      expect(
        await MemoryGovernanceStores.episodes.count(harness.database),
        episodeCountBeforeRollback + 1,
      );

      final detail = await harness.ledger.getDetail(accepted.episodeId!);
      expect(detail, isNotNull);
      expect(detail!.entry.episode.sourceRefs, hasLength(1));
      expect(detail.entry.episode.confidence, accepted.episode!.confidence);
      expect(
        detail.revisions.map((revision) => revision.episode.revision),
        <int>[2, 1],
      );
      final diff = await harness.ledger.diff(
        pending.episodeId!,
        accepted.episodeId!,
      );
      expect(diff.sameLineage, isTrue);
      expect(
        diff.changes,
        contains(
          const MemoryRevisionFieldChange(
            field: 'reviewState',
            before: 'pending',
            after: 'accepted',
          ),
        ),
      );

      final recall = await harness.bus.l2RecallResult('rollback-v2-anchor');
      expect(recall.status, MemoryRecallStatus.complete);
      expect(recall.directCount, greaterThanOrEqualTo(1));
      expect(recall.promptBlock, contains('rollback-v2-anchor'));

      expect(
        await MemoryGovernanceStores.episodes
            .record(pending.episodeId!)
            .get(harness.database),
        pendingRawBefore,
      );
      expect(
        await MemoryGovernanceStores.episodes
            .record(accepted.episodeId!)
            .get(harness.database),
        acceptedRawBefore,
      );
      expect(await _governanceSnapshot(harness.database), sidecarsBefore);

      final countBeforeRejectedReview = await MemoryGovernanceStores.episodes
          .count(harness.database);
      final rejectedReview = await harness.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: accepted.episodeId!,
          expectedHeadEpisodeId: accepted.episodeId!,
          expectedRevision: accepted.episode!.revision,
        ),
      );
      expect(rejectedReview.status, MemoryGovernanceStatus.invalid);
      expect(rejectedReview.reason, 'memory_v2_not_enforced');
      expect(
        await MemoryGovernanceStores.episodes.count(harness.database),
        countBeforeRejectedReview,
      );
      expect(await _governanceSnapshot(harness.database), sidecarsBefore);

      harness.mode = FeatureRolloutMode.enforce;
      final resumed = await harness.writeFromHumanMessage(
        source: 'Today I opened the rollback-v2-resumed notebook.',
        memory: 'I opened the rollback-v2-resumed notebook.',
      );
      expect(resumed.disposition, MemoryWriteDisposition.quarantined);
      final resumedRaw = await MemoryGovernanceStores.episodes
          .record(resumed.episodeId!)
          .get(harness.database);
      expect(resumedRaw?['schemaVersion'], Episode.currentSchemaVersion);
      expect(resumedRaw?['reviewState'], EpisodeReviewState.pending.name);
      expect(
        await MemoryGovernanceStores.episodeGovernance
            .record(resumed.episodeId!)
            .get(harness.database),
        isNotNull,
      );
      expect(
        await MemoryGovernanceStores.episodes
            .record(pending.episodeId!)
            .get(harness.database),
        pendingRawBefore,
      );
      expect(
        await MemoryGovernanceStores.episodes
            .record(accepted.episodeId!)
            .get(harness.database),
        acceptedRawBefore,
      );
    },
  );
}

const String _accountScopeDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final DateTime _now = DateTime.utc(2026, 8, 30, 12);
var _databaseSequence = 0;

final class _RollbackHarness {
  _RollbackHarness({
    required this.database,
    required this.store,
    required this.coordinator,
    required this.recallGate,
    required this.bus,
    required this.ledger,
  });

  final Database database;
  final EpisodeStore store;
  final MemoryWriteCoordinator coordinator;
  final MemoryRecallSafetyGate recallGate;
  final MemoryBus bus;
  final MemoryLedgerService ledger;
  FeatureRolloutMode mode = FeatureRolloutMode.enforce;

  static Future<_RollbackHarness> open() async {
    final database = await databaseFactoryMemory.openDatabase(
      'memory-v2-rollback-${_databaseSequence++}.db',
    );
    late _RollbackHarness harness;
    FeatureRolloutMode effectiveMode() => harness.mode;
    final store = EpisodeStore(
      database: database,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: effectiveMode,
      clock: () => _now,
    );
    final coordinator = MemoryWriteCoordinator(
      database: database,
      episodeStore: store,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: effectiveMode,
      clock: () => _now,
      linkEpisode: (_) async {},
      removeEpisodeLinks: (_) async {},
      projectMilestone: (_) async {},
    );
    final recallGate = MemoryRecallSafetyGate(
      episodeStore: store,
      budget: const Duration(seconds: 1),
    );
    final bus = MemoryBus(
      memoryV2Mode: effectiveMode,
      recallSafetyGate: recallGate,
    );
    final ledger = MemoryLedgerService(
      database: database,
      coordinator: coordinator,
      memoryBus: bus,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: effectiveMode,
      clock: () => _now,
    );
    harness = _RollbackHarness(
      database: database,
      store: store,
      coordinator: coordinator,
      recallGate: recallGate,
      bus: bus,
      ledger: ledger,
    );
    appServices.put<EpisodeStore>(store);
    appServices.put<MemoryWriteCoordinator>(coordinator);
    appServices.put<MemoryRecallSafetyGate>(recallGate);
    appServices.put<MemoryBus>(bus);
    return harness;
  }

  Future<MemoryWriteResult> writeFromHumanMessage({
    required String source,
    required String memory,
  }) async {
    final messageId = await MemoryGovernanceStores.chatMessages.add(
      database,
      ChatMessage(
        sessionId: 'self',
        senderId: 'user',
        receiverId: 'agent-a',
        content: source,
        timestamp: _now,
        isUserMessage: true,
        turnOrigin: ChatMessageTurnOrigins.user,
      ).toJson(),
    );
    return coordinator.runWithPersistedChatSource(
      messageRecordId: messageId,
      sessionId: 'self',
      agentId: 'agent-a',
      operation: () => bus.writeEpisodeWithResult(
        Episode(when: _now, what: memory, salience: 0.7),
      ),
    );
  }

  Future<void> close() async {
    await ledger.deactivateAndDrain();
    await recallGate.deactivateAndDrain();
    await coordinator.deactivateAndDrain();
    await store.deactivateAndDrain();
    await database.close();
  }
}

Future<Map<String, Object?>> _governanceSnapshot(Database database) async =>
    <String, Object?>{
      'episodeGovernance': await _intStoreSnapshot(
        MemoryGovernanceStores.episodeGovernance,
        database,
      ),
      'revisionHeads': await _intStoreSnapshot(
        MemoryGovernanceStores.revisionHeads,
        database,
      ),
      'exactDedup': await _stringStoreSnapshot(
        MemoryGovernanceStores.exactDedup,
        database,
      ),
      'semanticDedup': await _stringStoreSnapshot(
        MemoryGovernanceStores.semanticDedup,
        database,
      ),
      'claimHeads': await _stringStoreSnapshot(
        MemoryGovernanceStores.claimHeads,
        database,
      ),
      'sourceMaterial': await _stringStoreSnapshot(
        MemoryGovernanceStores.sourceMaterial,
        database,
      ),
      'governedProjections': await _intStoreSnapshot(
        MemoryGovernanceStores.governedProjections,
        database,
      ),
      'governedProjectionHeads': await _stringStoreSnapshot(
        MemoryGovernanceStores.governedProjectionHeads,
        database,
      ),
      'governedProjectionRollbackOverrides': await _stringStoreSnapshot(
        MemoryGovernanceStores.governedProjectionRollbackOverrides,
        database,
      ),
      'audit': await _intStoreSnapshot(MemoryGovernanceStores.audit, database),
    };

Future<Map<int, Map<String, Object?>>> _intStoreSnapshot(
  StoreRef<int, Map<String, Object?>> store,
  Database database,
) async => <int, Map<String, Object?>>{
  for (final row in await store.find(database))
    row.key: Map<String, Object?>.from(row.value),
};

Future<Map<String, Map<String, Object?>>> _stringStoreSnapshot(
  StoreRef<String, Map<String, Object?>> store,
  Database database,
) async => <String, Map<String, Object?>>{
  for (final row in await store.find(database))
    row.key: Map<String, Object?>.from(row.value),
};
