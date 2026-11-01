import 'dart:async';

import 'package:flutter_test/flutter_test.dart' hide Finder;
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/episode_v2_migration.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:sembast/sembast_memory.dart';

const String _accountScopeA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _accountScopeB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const int _whenMs = 1735689600000;

final StoreRef<int, Map<String, Object?>> _episodes = intMapStoreFactory.store(
  'episodes',
);

void main() {
  group('EpisodeV2Migrator', () {
    test(
      'migrates mixed rows in place and persists identity mapping and report',
      () async {
        final database = await _openDatabase('episode-v2-mixed.db');
        final legacy = _legacyEpisode(
          what: 'legacy memory',
          entities: const <String>['Mira'],
          emotion: 'warm',
          salience: 0.8,
          embedding: const <double>[0.1, 0.2],
        );
        final current = _currentEpisode(what: 'already current');
        await _episodes.record(7).put(database, legacy);
        await _episodes.record(9).put(database, current);

        final migrator = EpisodeV2Migrator(
          database: database,
          accountScopeDigest: _accountScopeA,
          clock: _fixedClock,
        );
        final step = await migrator.migrateNextBatch();

        expect(step.isComplete, isTrue);
        expect(step.report.phase, EpisodeV2MigrationPhase.completed);
        expect(step.report.highWatermarkId, 9);
        expect(step.report.lastSourceKey, 9);
        expect(step.report.scannedCount, 2);
        expect(step.report.legacyCount, 1);
        expect(step.report.migratedCount, 1);
        expect(step.report.alreadyCurrentCount, 1);
        expect(step.report.failureCount, 0);
        expect(step.report.blockedSourceKeys, isEmpty);
        expect(step.report.preservesRecordKeys, isTrue);

        final rows = await _episodes.find(
          database,
          finder: Finder(sortOrders: <SortOrder>[SortOrder(Field.key)]),
        );
        expect(rows.map((row) => row.key), <int>[7, 9]);
        final migrated = rows.first.value;
        expect(migrated['schemaVersion'], Episode.currentSchemaVersion);
        expect(migrated['what'], 'legacy memory');
        expect(migrated['sourceType'], EpisodeSourceType.legacyUnknown.name);
        expect(migrated['reviewState'], EpisodeReviewState.accepted.name);
        expect(rows.last.value, current);

        final mapping = await migrator.mappingFor(7);
        expect(mapping, isNotNull);
        expect(mapping!.sourceId, 7);
        expect(mapping.targetId, 7);
        expect(mapping.sourceDigest, matches(r'^sha256:[a-f0-9]{64}$'));
        expect(mapping.targetDigest, matches(r'^sha256:[a-f0-9]{64}$'));
        expect(mapping.sourceDigest, isNot(mapping.targetDigest));
        expect(mapping.migratedAt, _fixedClock());
        expect(await migrator.mappingFor(9), isNull);

        final persisted = await migrator.readReport();
        expect(persisted, isNotNull);
        expect(persisted!.revision, step.report.revision);
        expect(persisted.migratedCount, 1);
        expect(persisted.alreadyCurrentCount, 1);
      },
    );

    test('completed migration is idempotent across migrator restart', () async {
      final database = await _openDatabase('episode-v2-idempotent.db');
      await _episodes
          .record(3)
          .put(database, _legacyEpisode(what: 'migrate once'));
      final first = EpisodeV2Migrator(
        database: database,
        accountScopeDigest: _accountScopeA,
        clock: _fixedClock,
      );
      final initial = await first.migrateNextBatch();
      final migratedRow = await _episodes.record(3).get(database);
      final mapping = await first.mappingFor(3);

      final restarted = EpisodeV2Migrator(
        database: database,
        accountScopeDigest: _accountScopeA,
        clock: _fixedClock,
      );
      final repeated = await restarted.migrateNextBatch();

      expect(repeated.report.phase, EpisodeV2MigrationPhase.completed);
      expect(repeated.report.revision, initial.report.revision);
      expect(repeated.report.scannedCount, 1);
      expect(repeated.report.legacyCount, 1);
      expect(repeated.report.migratedCount, 1);
      expect(await _episodes.record(3).get(database), migratedRow);
      final repeatedMapping = await restarted.mappingFor(3);
      expect(repeatedMapping!.sourceDigest, mapping!.sourceDigest);
      expect(repeatedMapping.targetDigest, mapping.targetDigest);
      expect(repeatedMapping.migratedAt, mapping.migratedAt);
    });

    test('batch checkpoint pauses and resumes after store restart', () async {
      final database = await _openDatabase('episode-v2-resume.db');
      for (var key = 1; key <= 3; key++) {
        await _episodes
            .record(key)
            .put(database, _legacyEpisode(what: 'memory $key'));
      }
      final firstStore = EpisodeStore(
        database: database,
        accountScopeDigest: _accountScopeA,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
        clock: _fixedClock,
        migrationBatchSize: 1,
      );

      final paused = await firstStore.migrateLegacyEpisodes(maxBatches: 1);
      expect(paused.phase, EpisodeV2MigrationPhase.paused);
      expect(paused.lastSourceKey, 1);
      expect(paused.scannedCount, 1);
      expect(paused.migratedCount, 1);
      firstStore.closeLifecycle();

      final resumedStore = EpisodeStore(
        database: database,
        accountScopeDigest: _accountScopeA,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
        clock: _fixedClock,
        migrationBatchSize: 1,
      );
      addTearDown(resumedStore.closeLifecycle);
      final completed = await resumedStore.migrateLegacyEpisodes();

      expect(completed.phase, EpisodeV2MigrationPhase.completed);
      expect(completed.lastSourceKey, 3);
      expect(completed.scannedCount, 3);
      expect(completed.legacyCount, 3);
      expect(completed.migratedCount, 3);
      for (var key = 1; key <= 3; key++) {
        expect(
          (await _episodes.record(key).get(database))!['schemaVersion'],
          Episode.currentSchemaVersion,
        );
        expect(await resumedStore.migrationMappingFor(key), isNotNull);
      }
    });

    test(
      'teardown pause waits for the current batch then resumes from checkpoint',
      () async {
        final database = await _openDatabase('episode-v2-teardown-pause.db');
        for (var key = 1; key <= 3; key++) {
          await _episodes
              .record(key)
              .put(database, _legacyEpisode(what: 'teardown memory $key'));
        }
        final batchStarted = Completer<void>();
        final releaseBatch = Completer<void>();
        var blockedFirstBatch = false;
        final firstStore = EpisodeStore(
          database: database,
          accountScopeDigest: _accountScopeA,
          memoryV2Mode: () => FeatureRolloutMode.enforce,
          clock: _fixedClock,
          migrationBatchSize: 1,
          migrationFaultInjector: (point, _) async {
            if (blockedFirstBatch ||
                point != EpisodeV2MigrationFaultPoint.beforeBatchCommit) {
              return;
            }
            blockedFirstBatch = true;
            batchStarted.complete();
            await releaseBatch.future;
          },
        );
        addTearDown(firstStore.closeLifecycle);

        final migration = firstStore.migrateLegacyEpisodes();
        await batchStarted.future;
        firstStore.requestMigrationPause();
        releaseBatch.complete();
        final paused = await migration;

        expect(paused.phase, EpisodeV2MigrationPhase.paused);
        expect(paused.highWatermarkId, 3);
        expect(paused.lastSourceKey, 1);
        expect(paused.scannedCount, 1);
        expect(paused.legacyCount, 1);
        expect(paused.migratedCount, 1);
        final persistedPause = await firstStore.readMigrationReport();
        expect(persistedPause, isNotNull);
        expect(persistedPause!.phase, EpisodeV2MigrationPhase.paused);
        expect(persistedPause.lastSourceKey, 1);
        expect(
          (await _episodes.record(1).get(database))!['schemaVersion'],
          Episode.currentSchemaVersion,
        );
        expect(
          (await _episodes.record(2).get(database))!.containsKey(
            'schemaVersion',
          ),
          isFalse,
        );
        expect(
          (await _episodes.record(3).get(database))!.containsKey(
            'schemaVersion',
          ),
          isFalse,
        );
        expect(await firstStore.migrationMappingFor(1), isNotNull);
        expect(await firstStore.migrationMappingFor(2), isNull);
        await firstStore.deactivateAndDrain();
        firstStore.closeLifecycle();

        final resumedStore = EpisodeStore(
          database: database,
          accountScopeDigest: _accountScopeA,
          memoryV2Mode: () => FeatureRolloutMode.enforce,
          clock: _fixedClock,
          migrationBatchSize: 1,
        );
        addTearDown(resumedStore.closeLifecycle);
        final completed = await resumedStore.migrateLegacyEpisodes();

        expect(completed.phase, EpisodeV2MigrationPhase.completed);
        expect(completed.highWatermarkId, 3);
        expect(completed.lastSourceKey, 3);
        expect(completed.scannedCount, 3);
        expect(completed.legacyCount, 3);
        expect(completed.migratedCount, 3);
        expect(await resumedStore.migrationMappingFor(1), isNotNull);
        expect(await resumedStore.migrationMappingFor(2), isNotNull);
        expect(await resumedStore.migrationMappingFor(3), isNotNull);
      },
    );

    test('before-commit fault rolls back row mapping and journal', () async {
      final database = await _openDatabase('episode-v2-before-fault.db');
      final legacy = _legacyEpisode(what: 'transactional memory');
      await _episodes.record(4).put(database, legacy);
      var injected = false;
      final faulty = EpisodeV2Migrator(
        database: database,
        accountScopeDigest: _accountScopeA,
        clock: _fixedClock,
        faultInjector: (point, _) {
          if (!injected &&
              point == EpisodeV2MigrationFaultPoint.beforeBatchCommit) {
            injected = true;
            throw StateError('before commit fault');
          }
        },
      );

      await expectLater(faulty.migrateNextBatch(), throwsStateError);
      expect(await _episodes.record(4).get(database), legacy);
      expect(await faulty.mappingFor(4), isNull);
      expect(await faulty.readReport(), isNull);

      final recovered = EpisodeV2Migrator(
        database: database,
        accountScopeDigest: _accountScopeA,
        clock: _fixedClock,
      );
      final report = (await recovered.migrateNextBatch()).report;
      expect(report.phase, EpisodeV2MigrationPhase.completed);
      expect(report.scannedCount, 1);
      expect(report.migratedCount, 1);
      expect(await recovered.mappingFor(4), isNotNull);
    });

    test('after-commit fault resumes without duplicate migration', () async {
      final database = await _openDatabase('episode-v2-after-fault.db');
      await _episodes
          .record(5)
          .put(database, _legacyEpisode(what: 'committed memory'));
      var injected = false;
      final faulty = EpisodeV2Migrator(
        database: database,
        accountScopeDigest: _accountScopeA,
        clock: _fixedClock,
        faultInjector: (point, _) {
          if (!injected &&
              point == EpisodeV2MigrationFaultPoint.afterBatchCommit) {
            injected = true;
            throw StateError('after commit fault');
          }
        },
      );

      await expectLater(faulty.migrateNextBatch(), throwsStateError);
      final committedRow = await _episodes.record(5).get(database);
      expect(committedRow!['schemaVersion'], Episode.currentSchemaVersion);
      final committedReport = await faulty.readReport();
      final committedMapping = await faulty.mappingFor(5);
      expect(committedReport!.phase, EpisodeV2MigrationPhase.completed);
      expect(committedReport.migratedCount, 1);
      expect(committedMapping, isNotNull);

      final recovered = EpisodeV2Migrator(
        database: database,
        accountScopeDigest: _accountScopeA,
        clock: _fixedClock,
      );
      final repeated = (await recovered.migrateNextBatch()).report;
      final repeatedMapping = await recovered.mappingFor(5);
      expect(repeated.revision, committedReport.revision);
      expect(repeated.scannedCount, 1);
      expect(repeated.migratedCount, 1);
      expect(await _episodes.record(5).get(database), committedRow);
      expect(repeatedMapping!.sourceDigest, committedMapping!.sourceDigest);
      expect(repeatedMapping.targetDigest, committedMapping.targetDigest);
      expect(repeatedMapping.migratedAt, committedMapping.migratedAt);
    });

    test(
      'invalid legacy and future schema stay intact with audit issues',
      () async {
        final database = await _openDatabase('episode-v2-issues.db');
        final invalidLegacy = <String, Object?>{
          'when': 'not-a-timestamp',
          'what': 'corrupt legacy',
        };
        final futureSchema = <String, Object?>{
          'schemaVersion': Episode.currentSchemaVersion + 1,
          'when': _whenMs,
          'what': 'future episode',
        };
        await _episodes.record(2).put(database, invalidLegacy);
        await _episodes.record(6).put(database, futureSchema);
        final migrator = EpisodeV2Migrator(
          database: database,
          accountScopeDigest: _accountScopeA,
          clock: _fixedClock,
        );

        final report = (await migrator.migrateNextBatch()).report;

        expect(report.phase, EpisodeV2MigrationPhase.completedWithIssues);
        expect(report.scannedCount, 2);
        expect(report.failureCount, 2);
        expect(report.migratedCount, 0);
        expect(report.blockedSourceKeys, <int>[2, 6]);
        expect(await _episodes.record(2).get(database), invalidLegacy);
        expect(await _episodes.record(6).get(database), futureSchema);
        expect(await migrator.mappingFor(2), isNull);
        expect(await migrator.mappingFor(6), isNull);
        final legacyIssue = await migrator.issueFor(2);
        final futureIssue = await migrator.issueFor(6);
        expect(legacyIssue!.code, 'invalid_legacy_episode');
        expect(legacyIssue.sourceId, 2);
        expect(legacyIssue.sourceDigest, matches(r'^sha256:[a-f0-9]{64}$'));
        expect(futureIssue!.code, 'unsupported_episode_schema');
        expect(futureIssue.sourceId, 6);
        expect(futureIssue.sourceDigest, matches(r'^sha256:[a-f0-9]{64}$'));
      },
    );

    test('late legacy key reopens a completed migration', () async {
      final database = await _openDatabase('episode-v2-late-row.db');
      await _episodes.record(1).put(database, _legacyEpisode(what: 'first'));
      final first = EpisodeV2Migrator(
        database: database,
        accountScopeDigest: _accountScopeA,
        clock: _fixedClock,
      );
      final initial = (await first.migrateNextBatch()).report;
      expect(initial.phase, EpisodeV2MigrationPhase.completed);
      expect(initial.highWatermarkId, 1);

      await _episodes.record(8).put(database, _legacyEpisode(what: 'late'));
      final restarted = EpisodeV2Migrator(
        database: database,
        accountScopeDigest: _accountScopeA,
        clock: _fixedClock,
      );
      final reopened = (await restarted.migrateNextBatch()).report;

      expect(reopened.phase, EpisodeV2MigrationPhase.completed);
      expect(reopened.highWatermarkId, 8);
      expect(reopened.lastSourceKey, 8);
      expect(reopened.scannedCount, 2);
      expect(reopened.legacyCount, 2);
      expect(reopened.migratedCount, 2);
      expect(await restarted.mappingFor(1), isNotNull);
      expect(await restarted.mappingFor(8), isNotNull);
      expect(
        (await _episodes.record(8).get(database))!['schemaVersion'],
        Episode.currentSchemaVersion,
      );
    });

    test(
      'separate account databases isolate rows journal and mapping',
      () async {
        final firstDatabase = await _openDatabase('episode-v2-account-a.db');
        final secondDatabase = await _openDatabase('episode-v2-account-b.db');
        final firstLegacy = _legacyEpisode(what: 'account A');
        final secondLegacy = _legacyEpisode(what: 'account B');
        await _episodes.record(1).put(firstDatabase, firstLegacy);
        await _episodes.record(1).put(secondDatabase, secondLegacy);
        final first = EpisodeV2Migrator(
          database: firstDatabase,
          accountScopeDigest: _accountScopeA,
          clock: _fixedClock,
        );
        final second = EpisodeV2Migrator(
          database: secondDatabase,
          accountScopeDigest: _accountScopeB,
          clock: _fixedClock,
        );

        await first.migrateNextBatch();

        expect(
          (await _episodes.record(1).get(firstDatabase))!['schemaVersion'],
          Episode.currentSchemaVersion,
        );
        expect(await first.readReport(), isNotNull);
        expect(await first.mappingFor(1), isNotNull);
        expect(await _episodes.record(1).get(secondDatabase), secondLegacy);
        expect(await second.readReport(), isNull);
        expect(await second.mappingFor(1), isNull);
        expect(await second.issueFor(1), isNull);
      },
    );
  });

  group('EpisodeStore rollout modes', () {
    test(
      'mode rollback lets the current migration batch commit then pauses',
      () async {
        final database = await _openDatabase(
          'episode-v2-rollout-mid-migration-off.db',
        );
        for (var key = 1; key <= 3; key++) {
          await _episodes
              .record(key)
              .put(database, _legacyEpisode(what: 'rollback memory $key'));
        }
        var mode = FeatureRolloutMode.enforce;
        var flipped = false;
        final store = EpisodeStore(
          database: database,
          accountScopeDigest: _accountScopeA,
          memoryV2Mode: () => mode,
          clock: _fixedClock,
          migrationBatchSize: 1,
          migrationFaultInjector: (point, _) {
            if (!flipped &&
                point == EpisodeV2MigrationFaultPoint.afterBatchCommit) {
              flipped = true;
              mode = FeatureRolloutMode.off;
            }
          },
        );
        addTearDown(store.closeLifecycle);

        final paused = await store.migrateLegacyEpisodes();

        expect(flipped, isTrue);
        expect(paused.phase, EpisodeV2MigrationPhase.paused);
        expect(paused.lastSourceKey, 1);
        expect(paused.scannedCount, 1);
        expect(paused.migratedCount, 1);
        expect(
          (await _episodes.record(1).get(database))!['schemaVersion'],
          Episode.currentSchemaVersion,
        );
        expect(
          (await _episodes.record(2).get(database))!.containsKey(
            'schemaVersion',
          ),
          isFalse,
        );
        expect(
          (await _episodes.record(3).get(database))!.containsKey(
            'schemaVersion',
          ),
          isFalse,
        );
        expect(await store.migrationMappingFor(1), isNotNull);
        expect(await store.migrationMappingFor(2), isNull);

        mode = FeatureRolloutMode.enforce;
        final completed = await store.migrateLegacyEpisodes();

        expect(completed.phase, EpisodeV2MigrationPhase.completed);
        expect(completed.lastSourceKey, 3);
        expect(completed.scannedCount, 3);
        expect(completed.migratedCount, 3);
        for (var key = 1; key <= 3; key++) {
          expect(
            (await _episodes.record(key).get(database))!['schemaVersion'],
            Episode.currentSchemaVersion,
          );
          expect(await store.migrationMappingFor(key), isNotNull);
        }
      },
    );

    test('off and shadow write legacy while enforce writes v2', () async {
      final database = await _openDatabase('episode-v2-rollout-writes.db');
      var mode = FeatureRolloutMode.off;
      final store = EpisodeStore(
        database: database,
        accountScopeDigest: _accountScopeA,
        memoryV2Mode: () => mode,
        clock: _fixedClock,
      );
      addTearDown(store.closeLifecycle);

      final offKey = await store.add(_episode(what: 'off write'));
      mode = FeatureRolloutMode.shadow;
      final shadowKey = await store.add(_episode(what: 'shadow write'));
      final beforeScan = await _episodes.find(
        database,
        finder: Finder(sortOrders: <SortOrder>[SortOrder(Field.key)]),
      );
      final beforeMaps = beforeScan
          .map((row) => Map<String, Object?>.from(row.value))
          .toList(growable: false);

      final shadowReport = await store.migrateLegacyEpisodes();

      expect(shadowReport.phase, EpisodeV2MigrationPhase.shadow);
      expect(shadowReport.legacyCount, 2);
      expect(shadowReport.migratedCount, 0);
      expect(await store.readMigrationReport(), isNull);
      final afterScan = await _episodes.find(
        database,
        finder: Finder(sortOrders: <SortOrder>[SortOrder(Field.key)]),
      );
      expect(afterScan.map((row) => row.value), beforeMaps);
      expect(afterScan.first.value.containsKey('schemaVersion'), isFalse);
      expect(afterScan.last.value.containsKey('schemaVersion'), isFalse);

      mode = FeatureRolloutMode.enforce;
      final enforceKey = await store.add(_episode(what: 'enforce write'));
      expect(
        (await _episodes.record(enforceKey).get(database))!['schemaVersion'],
        Episode.currentSchemaVersion,
      );
      expect(
        (await _episodes.record(enforceKey).get(database))!['sourceType'],
        EpisodeSourceType.runtimeUnknown.name,
      );
      expect(
        (await _episodes.record(offKey).get(database))!.containsKey(
          'schemaVersion',
        ),
        isFalse,
      );
      expect(
        (await _episodes.record(shadowKey).get(database))!.containsKey(
          'schemaVersion',
        ),
        isFalse,
      );
    });

    test('off mode returns disabled and leaves legacy row untouched', () async {
      final database = await _openDatabase('episode-v2-rollout-off.db');
      final legacy = _legacyEpisode(what: 'off migration');
      await _episodes.record(2).put(database, legacy);
      final store = EpisodeStore(
        database: database,
        accountScopeDigest: _accountScopeA,
        memoryV2Mode: () => FeatureRolloutMode.off,
        clock: _fixedClock,
      );
      addTearDown(store.closeLifecycle);

      final report = await store.migrateLegacyEpisodes();

      expect(report.phase, EpisodeV2MigrationPhase.disabled);
      expect(await _episodes.record(2).get(database), legacy);
      expect(await store.readMigrationReport(), isNull);
    });
  });
}

DateTime _fixedClock() => DateTime.utc(2025, 1, 2, 3, 4, 5);

Episode _episode({required String what}) => Episode(
  when: DateTime.fromMillisecondsSinceEpoch(_whenMs, isUtc: true),
  what: what,
  entities: const <String>['Maaso'],
  salience: 0.7,
);

Map<String, Object?> _currentEpisode({required String what}) =>
    _episode(what: what).toJson();

Map<String, Object?> _legacyEpisode({
  required String what,
  List<String> entities = const <String>[],
  String? emotion,
  double salience = 0.5,
  List<double>? embedding,
}) => <String, Object?>{
  'when': _whenMs,
  'what': what,
  'entities': entities,
  'emotion': ?emotion,
  'salience': salience,
  'embedding': ?embedding,
};

Future<Database> _openDatabase(String path) async {
  final database = await databaseFactoryMemory.openDatabase(path);
  addTearDown(() async {
    await database.close();
    await databaseFactoryMemory.deleteDatabase(path);
  });
  return database;
}
