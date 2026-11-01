import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/embedding_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  test('enforce add persists the canonical Episode v2 payload', () async {
    final database = await _openDatabase('episode-store-enforce');
    addTearDown(database.close);
    final store = EpisodeStore(
      database: database,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
    );
    addTearDown(store.deactivateAndDrain);

    final episode = _episode('canonical');
    final id = await store.add(episode);
    final persisted = await _episodeRecords.record(id).get(database);

    expect(episode.id, id);
    expect(persisted, episode.toJson());
    expect(persisted?['schemaVersion'], Episode.currentSchemaVersion);
    expect(persisted?['sourceType'], EpisodeSourceType.runtimeUnknown.name);
  });

  test(
    'off add preserves the exact rollback-compatible legacy shape',
    () async {
      final database = await _openDatabase('episode-store-off');
      addTearDown(database.close);
      final store = EpisodeStore(
        database: database,
        accountScopeDigest: _accountScopeDigest,
        memoryV2Mode: () => FeatureRolloutMode.off,
      );
      addTearDown(store.deactivateAndDrain);
      final episode = _episode(
        'legacy',
        sourceType: EpisodeSourceType.explicitSave,
        sourceRefs: <EpisodeSourceRef>[
          EpisodeSourceRef(
            sourceId: 'turn-1',
            sessionId: 'session-1',
            origin: EpisodeSourceOrigin.user,
            contentHash: 'b' * 64,
          ),
        ],
      );

      final id = await store.add(episode);
      final persisted = await _episodeRecords.record(id).get(database);

      expect(persisted, episode.toLegacyJson());
      expect(persisted, isNot(contains('schemaVersion')));
      expect(
        persisted?.keys,
        unorderedEquals(<String>['when', 'what', 'entities', 'salience']),
      );
    },
  );

  test(
    'embedding backfill patches only embedding after concurrent governance update',
    () async {
      final database = await _openDatabase('episode-store-embedding-patch');
      addTearDown(database.close);
      final embedding = _GatedEmbeddingService();
      appServices.put<EmbeddingService>(embedding);
      final store = EpisodeStore(
        database: database,
        accountScopeDigest: _accountScopeDigest,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      );
      addTearDown(store.deactivateAndDrain);
      final episode = _episode('patch-only');

      final id = await store.add(episode);
      await embedding.started.future;
      final concurrentUpdatedAt = DateTime.utc(2026, 8, 29, 13, 0);
      await _episodeRecords.record(id).update(database, <String, Object?>{
        'confidence': 0.91,
        'reviewState': EpisodeReviewState.rejected.name,
        'revision': 7,
        'updatedAt': concurrentUpdatedAt.millisecondsSinceEpoch,
      });

      embedding.release(const <double>[0.25, 0.5, 0.75]);
      await store.waitForIdle();
      final persisted = await _episodeRecords.record(id).get(database);

      expect(persisted?['embedding'], <double>[0.25, 0.5, 0.75]);
      expect(persisted?['confidence'], 0.91);
      expect(persisted?['reviewState'], EpisodeReviewState.rejected.name);
      expect(persisted?['revision'], 7);
      expect(
        persisted?['updatedAt'],
        concurrentUpdatedAt.millisecondsSinceEpoch,
      );
    },
  );

  test(
    'deactivateAndDrain waits for admitted background work and fences add',
    () async {
      final database = await _openDatabase('episode-store-drain');
      addTearDown(database.close);
      final embedding = _GatedEmbeddingService();
      appServices.put<EmbeddingService>(embedding);
      final store = EpisodeStore(
        database: database,
        accountScopeDigest: _accountScopeDigest,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      );
      addTearDown(store.deactivateAndDrain);

      await store.add(_episode('admitted'));
      await embedding.started.future;
      var drainCompleted = false;
      final drain = store.deactivateAndDrain().whenComplete(
        () => drainCompleted = true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(drainCompleted, isFalse);
      await expectLater(
        store.add(_episode('late')),
        throwsA(isA<StateError>()),
      );

      embedding.release(const <double>[1, 0]);
      await drain;
      expect(drainCompleted, isTrue);
    },
  );

  test('retired store rejects a new migration run', () async {
    final database = await _openDatabase('episode-store-retired-migration');
    addTearDown(database.close);
    final store = EpisodeStore(
      database: database,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
    );
    addTearDown(store.deactivateAndDrain);

    await store.deactivateAndDrain();

    await expectLater(
      store.migrateLegacyEpisodes(),
      throwsA(isA<StateError>()),
    );
  });
}

const String _accountScopeDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final StoreRef<int, Map<String, Object?>> _episodeRecords = intMapStoreFactory
    .store('episodes');
var _databaseSequence = 0;

Future<Database> _openDatabase(String label) =>
    databaseFactoryMemory.openDatabase('$label-${_databaseSequence++}.db');

Episode _episode(
  String what, {
  EpisodeSourceType sourceType = EpisodeSourceType.runtimeUnknown,
  List<EpisodeSourceRef> sourceRefs = const <EpisodeSourceRef>[],
}) => Episode(
  when: DateTime.utc(2026, 8, 29, 12),
  what: what,
  entities: const <String>['Maaso'],
  sourceType: sourceType,
  sourceRefs: sourceRefs,
);

final class _GatedEmbeddingService extends EmbeddingService {
  final Completer<String> started = Completer<String>();
  final Completer<List<double>?> _result = Completer<List<double>?>();

  @override
  bool get isAvailable => true;

  @override
  Future<List<double>?> embed(String text) {
    if (!started.isCompleted) started.complete(text);
    return _result.future;
  }

  void release(List<double>? vector) {
    if (!_result.isCompleted) _result.complete(vector);
  }
}
