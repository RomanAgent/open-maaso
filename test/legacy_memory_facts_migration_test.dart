import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await appServices.reset();
  });

  test(
    'scoped legacy facts migrate through imported provenance and keep old key read-only',
    () async {
      const namespace = 'maaso.account.v1.agent-a';
      final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
      SharedPreferences.setMockInitialValues(<String, Object>{
        scopedKey: <String>['我喜欢蓝色', '门禁码是 AB  12'],
        MemoryLedgerService.unscopedLegacyFactsStorageKey: <String>[
          '不应被当前账号认领',
        ],
      });
      final harness = await _MigrationHarness.open();
      addTearDown(harness.close);
      final preferences = await SharedPreferences.getInstance();

      final first = await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
      );

      expect(first.imported, 2);
      expect(first.alreadyMigrated, 0);
      expect(first.failed, 0);
      expect(first.complete, isTrue);
      expect(preferences.getStringList(scopedKey), <String>[
        '我喜欢蓝色',
        '门禁码是 AB  12',
      ]);
      expect(
        preferences.getStringList(
          MemoryLedgerService.unscopedLegacyFactsStorageKey,
        ),
        <String>['不应被当前账号认领'],
      );

      final rows = await MemoryGovernanceStores.episodes.find(harness.database);
      expect(rows, hasLength(2));
      for (final row in rows) {
        final episode = Episode.fromJson(row.value)..id = row.key;
        expect(episode.kind, EpisodeKind.fact);
        expect(episode.reviewState, EpisodeReviewState.pending);
        expect(episode.sourceType, EpisodeSourceType.inherited);
        expect(await harness.store.isRecallEligible(episode), isFalse);
      }
      expect(
        await MemoryGovernanceStores.legacyFactMigrations.count(
          harness.database,
        ),
        2,
      );
    },
  );

  test('retry is idempotent even when the per-fact journal was lost', () async {
    const namespace = 'maaso.account.v1.agent-retry';
    final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
    SharedPreferences.setMockInitialValues(<String, Object>{
      scopedKey: <String>['可恢复事实'],
    });
    final harness = await _MigrationHarness.open();
    addTearDown(harness.close);
    final preferences = await SharedPreferences.getInstance();
    final first = await harness.ledger.migrateLegacyFacts(
      preferences: preferences,
      storageNamespace: namespace,
    );
    expect(first.imported, 1);
    final journalRows = await MemoryGovernanceStores.legacyFactMigrations.find(
      harness.database,
    );
    expect(journalRows, hasLength(1));
    await MemoryGovernanceStores.legacyFactMigrations
        .record(journalRows.single.key)
        .delete(harness.database);
    final retry = await harness.ledger.migrateLegacyFacts(
      preferences: preferences,
      storageNamespace: namespace,
    );

    expect(retry.imported, 0);
    expect(retry.alreadyMigrated, 1);
    expect(await MemoryGovernanceStores.episodes.count(harness.database), 1);
    expect(
      await MemoryGovernanceStores.legacyFactMigrations.count(harness.database),
      1,
    );
  });

  test('complete journal recreates a missing target episode', () async {
    const namespace = 'maaso.account.v1.agent-missing-episode';
    final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
    SharedPreferences.setMockInitialValues(<String, Object>{
      scopedKey: <String>['必须恢复的事实'],
    });
    final harness = await _MigrationHarness.open();
    addTearDown(harness.close);
    final preferences = await SharedPreferences.getInstance();
    expect(
      (await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
      )).imported,
      1,
    );
    final journal = (await MemoryGovernanceStores.legacyFactMigrations.find(
      harness.database,
    )).single;
    final missingEpisodeId = journal.value['episodeId'] as int;
    await MemoryGovernanceStores.episodes
        .record(missingEpisodeId)
        .delete(harness.database);

    final retry = await harness.ledger.migrateLegacyFacts(
      preferences: preferences,
      storageNamespace: namespace,
    );
    final repairedJournal =
        (await MemoryGovernanceStores.legacyFactMigrations.find(
          harness.database,
        )).single.value;

    expect(retry.imported, 1);
    expect(retry.complete, isTrue);
    expect(repairedJournal['episodeId'], isNot(missingEpisodeId));
    expect(
      await MemoryGovernanceStores.episodes
          .record(repairedJournal['episodeId'] as int)
          .get(harness.database),
      isNotNull,
    );
  });

  test(
    'complete journal recreates missing governance and source evidence',
    () async {
      const namespace = 'maaso.account.v1.agent-missing-sidecars';
      final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
      SharedPreferences.setMockInitialValues(<String, Object>{
        scopedKey: <String>['需要完整凭据的事实'],
      });
      final harness = await _MigrationHarness.open();
      addTearDown(harness.close);
      final preferences = await SharedPreferences.getInstance();
      await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
      );
      final firstJournal =
          (await MemoryGovernanceStores.legacyFactMigrations.find(
            harness.database,
          )).single.value;
      final firstEpisodeId = firstJournal['episodeId'] as int;
      final firstEpisodeRaw = await MemoryGovernanceStores.episodes
          .record(firstEpisodeId)
          .get(harness.database);
      final sourceId = (Episode.fromJson(
        firstEpisodeRaw!,
      )..id = firstEpisodeId).sourceRefs.single.sourceId;
      await MemoryGovernanceStores.episodeGovernance
          .record(firstEpisodeId)
          .delete(harness.database);
      await MemoryGovernanceStores.sourceMaterial
          .record(sourceId)
          .delete(harness.database);

      final retry = await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
      );
      final repairedJournal =
          (await MemoryGovernanceStores.legacyFactMigrations.find(
            harness.database,
          )).single.value;
      final repairedEpisodeId = repairedJournal['episodeId'] as int;

      expect(retry.imported, 1);
      expect(retry.complete, isTrue);
      expect(repairedEpisodeId, isNot(firstEpisodeId));
      expect(
        await MemoryGovernanceStores.episodeGovernance
            .record(repairedEpisodeId)
            .get(harness.database),
        isNotNull,
      );
      expect(
        await MemoryGovernanceStores.sourceMaterial
            .record(sourceId)
            .get(harness.database),
        isNotNull,
      );
    },
  );

  test('complete journal rejects a different valid imported episode', () async {
    const namespace = 'maaso.account.v1.agent-wrong-episode';
    final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
    SharedPreferences.setMockInitialValues(<String, Object>{
      scopedKey: <String>['日志必须绑定的事实'],
    });
    final harness = await _MigrationHarness.open();
    addTearDown(harness.close);
    final preferences = await SharedPreferences.getInstance();
    await harness.ledger.migrateLegacyFacts(
      preferences: preferences,
      storageNamespace: namespace,
    );
    final journalRow = (await MemoryGovernanceStores.legacyFactMigrations.find(
      harness.database,
    )).single;
    final expectedEpisodeId = journalRow.value['episodeId'] as int;
    final unrelated = await harness.bus.writeImportedEpisode(
      Episode(
        when: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        what: '同源但错误的事实摘要',
        kind: EpisodeKind.fact,
        retentionClass: EpisodeRetentionClass.durable,
      ),
      sourceKind: 'memory_manager_facts_v1',
      sourceKey: journalRow.value['sourceKey'] as String,
      canonicalMaterial: '日志必须绑定的事实',
    );
    expect(unrelated.created, isTrue);
    await MemoryGovernanceStores.legacyFactMigrations
        .record(journalRow.key)
        .put(harness.database, <String, Object?>{
          ...journalRow.value,
          'episodeId': unrelated.episodeId,
        });

    final retry = await harness.ledger.migrateLegacyFacts(
      preferences: preferences,
      storageNamespace: namespace,
    );
    final repairedJournal =
        (await MemoryGovernanceStores.legacyFactMigrations.find(
          harness.database,
        )).single.value;

    expect(retry.imported, 0);
    expect(retry.alreadyMigrated, 1);
    expect(retry.complete, isTrue);
    expect(repairedJournal['episodeId'], expectedEpisodeId);
    expect(repairedJournal['episodeId'], isNot(unrelated.episodeId));
  });

  test('off mode does not consume or journal legacy facts', () async {
    const namespace = 'maaso.account.v1.agent-off';
    final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
    SharedPreferences.setMockInitialValues(<String, Object>{
      scopedKey: <String>['等待 enforce 的事实'],
    });
    final harness = await _MigrationHarness.open(mode: FeatureRolloutMode.off);
    addTearDown(harness.close);
    final preferences = await SharedPreferences.getInstance();

    final report = await harness.ledger.migrateLegacyFacts(
      preferences: preferences,
      storageNamespace: namespace,
    );

    expect(report.imported, 0);
    expect(report.remaining, 1);
    expect(report.complete, isFalse);
    expect(report.skippedReason, 'memory_v2_not_enforced');
    expect(await MemoryGovernanceStores.episodes.count(harness.database), 0);
    expect(
      await MemoryGovernanceStores.legacyFactMigrations.count(harness.database),
      0,
    );
    expect(preferences.getStringList(scopedKey), <String>['等待 enforce 的事实']);
  });

  test(
    'migration work is bounded and resumes from completed fact journals',
    () async {
      const namespace = 'maaso.account.v1.agent-bounded';
      final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
      SharedPreferences.setMockInitialValues(<String, Object>{
        scopedKey: <String>['事实一', '事实二', '事实三'],
      });
      final harness = await _MigrationHarness.open();
      addTearDown(harness.close);
      final preferences = await SharedPreferences.getInstance();

      final first = await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
        limit: 2,
      );
      expect(first.imported, 2);
      expect(first.complete, isFalse);
      expect(first.remaining, 1);
      final stateAfterFirst =
          (await MemoryGovernanceStores.legacyFactMigrationState.find(
            harness.database,
          )).single.value;
      expect(stateAfterFirst['nextIndex'], 2);

      final second = await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
        limit: 2,
      );
      expect(second.imported, 1);
      expect(second.alreadyMigrated, 0);
      expect(second.complete, isTrue);
      expect(await MemoryGovernanceStores.episodes.count(harness.database), 3);
    },
  );

  test(
    'rollback pauses legacy facts before the next admission and resumes cleanly',
    () async {
      const namespace = 'maaso.account.v1.agent-rollback';
      final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
      SharedPreferences.setMockInitialValues(<String, Object>{
        scopedKey: <String>['事实一', '事实二', '事实三'],
      });
      var mode = FeatureRolloutMode.enforce;
      var revoked = false;
      final harness = await _MigrationHarness.open(
        modeProvider: () => mode,
        faultInjector: (point, _) {
          if (!revoked && point == MemoryWriteFaultPoint.beforeCommit) {
            revoked = true;
            mode = FeatureRolloutMode.off;
          }
        },
      );
      addTearDown(harness.close);
      final preferences = await SharedPreferences.getInstance();

      final paused = await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
        limit: 3,
      );

      expect(paused.imported, 1);
      expect(paused.alreadyMigrated, 0);
      expect(paused.failed, 0);
      expect(paused.remaining, 2);
      expect(paused.complete, isFalse);
      expect(paused.skippedReason, 'memory_v2_not_enforced');
      expect(await MemoryGovernanceStores.episodes.count(harness.database), 1);
      expect(
        await MemoryGovernanceStores.legacyFactMigrations.count(
          harness.database,
        ),
        1,
      );
      final pausedState =
          (await MemoryGovernanceStores.legacyFactMigrationState.find(
            harness.database,
          )).single.value;
      expect(pausedState['nextIndex'], 1);
      expect(pausedState['cycleFailures'], 0);

      final offRetry = await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
        limit: 3,
      );

      expect(offRetry.imported, 0);
      expect(offRetry.alreadyMigrated, 0);
      expect(offRetry.failed, 0);
      expect(offRetry.complete, isFalse);
      expect(offRetry.skippedReason, 'memory_v2_not_enforced');
      expect(await MemoryGovernanceStores.episodes.count(harness.database), 1);
      expect(
        await MemoryGovernanceStores.legacyFactMigrations.count(
          harness.database,
        ),
        1,
      );

      mode = FeatureRolloutMode.enforce;
      final completed = await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
        limit: 3,
      );

      expect(completed.imported, 2);
      expect(completed.alreadyMigrated, 0);
      expect(completed.failed, 0);
      expect(completed.remaining, 0);
      expect(completed.complete, isTrue);
      expect(completed.skippedReason, isNull);
      expect(await MemoryGovernanceStores.episodes.count(harness.database), 3);
      expect(
        await MemoryGovernanceStores.legacyFactMigrations.count(
          harness.database,
        ),
        3,
      );
      final rows = await MemoryGovernanceStores.episodes.find(harness.database);
      expect(
        rows.every(
          (row) => row.value['schemaVersion'] == Episode.currentSchemaVersion,
        ),
        isTrue,
      );
      expect(preferences.getStringList(scopedKey), <String>[
        '事实一',
        '事实二',
        '事实三',
      ]);
    },
  );

  test(
    'malformed fact writes a digest-only failure receipt and does not block the next item',
    () async {
      const namespace = 'maaso.account.v1.agent-malformed';
      final scopedKey = MemoryLedgerService.legacyFactsStorageKey(namespace);
      final oversized =
          'PRIVATE_SECRET_${List<String>.filled(65537, 'x').join()}';
      SharedPreferences.setMockInitialValues(<String, Object>{
        scopedKey: <String>[oversized, '后续有效事实'],
      });
      final harness = await _MigrationHarness.open();
      addTearDown(harness.close);
      final preferences = await SharedPreferences.getInstance();

      final report = await harness.ledger.migrateLegacyFacts(
        preferences: preferences,
        storageNamespace: namespace,
        limit: 2,
      );

      expect(report.imported, 1);
      expect(report.failed, 1);
      expect(report.complete, isFalse);
      final receipts = await MemoryGovernanceStores.legacyFactMigrations.find(
        harness.database,
      );
      expect(receipts, hasLength(2));
      expect(
        receipts.where((row) => row.value['complete'] == false),
        hasLength(1),
      );
      for (final receipt in receipts) {
        final encoded = receipt.value.toString();
        expect(encoded, isNot(contains('PRIVATE_SECRET')));
        expect(receipt.value['factHash'], isA<String>());
        expect(receipt.value['index'], isA<int>());
        expect(receipt.value['attempt'], isA<int>());
      }
      expect(await MemoryGovernanceStores.episodes.count(harness.database), 1);
    },
  );
}

const _accountDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final class _MigrationHarness {
  _MigrationHarness({
    required this.database,
    required this.store,
    required this.coordinator,
    required this.bus,
    required this.ledger,
  });

  final Database database;
  final EpisodeStore store;
  final MemoryWriteCoordinator coordinator;
  final MemoryBus bus;
  final MemoryLedgerService ledger;

  static Future<_MigrationHarness> open({
    FeatureRolloutMode mode = FeatureRolloutMode.enforce,
    FeatureRolloutMode Function()? modeProvider,
    MemoryWriteFaultInjector? faultInjector,
  }) async {
    final effectiveMode = modeProvider ?? () => mode;
    final database = await databaseFactoryMemory.openDatabase(
      'legacy-facts-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final store = EpisodeStore(
      database: database,
      accountScopeDigest: _accountDigest,
      memoryV2Mode: effectiveMode,
      clock: () => DateTime.utc(2026, 8, 30),
    );
    final coordinator = MemoryWriteCoordinator(
      database: database,
      episodeStore: store,
      accountScopeDigest: _accountDigest,
      memoryV2Mode: effectiveMode,
      clock: () => DateTime.utc(2026, 8, 30),
      linkEpisode: (_) async {},
      removeEpisodeLinks: (_) async {},
      projectMilestone: (_) async {},
      faultInjector: faultInjector,
    );
    final bus = MemoryBus(memoryV2Mode: effectiveMode);
    appServices.put<EpisodeStore>(store);
    appServices.put<MemoryWriteCoordinator>(coordinator);
    final ledger = MemoryLedgerService(
      database: database,
      coordinator: coordinator,
      memoryBus: bus,
      accountScopeDigest: _accountDigest,
      memoryV2Mode: effectiveMode,
      clock: () => DateTime.utc(2026, 8, 30),
    );
    return _MigrationHarness(
      database: database,
      store: store,
      coordinator: coordinator,
      bus: bus,
      ledger: ledger,
    );
  }

  Future<void> close() async {
    await ledger.deactivateAndDrain();
    await coordinator.deactivateAndDrain();
    await store.deactivateAndDrain();
    ledger.closeLifecycle();
    bus.closeLifecycle();
    coordinator.closeLifecycle();
    store.closeLifecycle();
    await database.close();
  }
}
