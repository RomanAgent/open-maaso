import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/embedding_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_recall_safety_gate.dart';
import 'package:sembast/sembast_memory.dart';

const _scope =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _spaceA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _spaceB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _what = 'oolong tea';
const _query = 'beverage preference';
var _sequence = 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  for (final legacyCodec in [false, true]) {
    test(
      'unlabelled vectors stay keyword-only until background repair: legacy=$legacyCodec',
      () async {
        final backend = _Backend()..episodePending = Completer<List<double>?>();
        final h = await _Harness.open(
          backend,
          labelled: false,
          legacyCodec: legacyCodec,
        );
        try {
          final before = await MemoryGovernanceStores.episodes
              .record(h.episode.id!)
              .get(h.db);
          final governance = await MemoryGovernanceStores.episodeGovernance
              .record(h.episode.id!)
              .get(h.db);
          expect((await h.gate.recall(_query)).promptBlock, isEmpty);
          expect((await h.store.search('oolong')).single.what, _what);
          backend.episodePending!.complete([1, 0]);
          await h.store.waitForIdle();
          final metadata = await h.metadata();
          expect(metadata?['spaceId'], _spaceA);
          expect(metadata?['vectorDigest'], _digest([1, 0]));
          expect(
            await MemoryGovernanceStores.episodes
                .record(h.episode.id!)
                .get(h.db),
            before,
          );
          expect(
            await MemoryGovernanceStores.episodeGovernance
                .record(h.episode.id!)
                .get(h.db),
            governance,
          );
          expect((await h.gate.recall(_query)).promptBlock, contains(_what));
        } finally {
          if (!backend.episodePending!.isCompleted)
            backend.episodePending!.complete(null);
          await h.close();
        }
      },
    );
  }

  test(
    'same-account provider change invalidates query cache and refuses old-space vectors',
    () async {
      final backend = _Backend();
      final h = await _Harness.open(backend, labelled: true);
      try {
        expect((await h.gate.recall(_query)).promptBlock, contains(_what));
        expect(backend.queryCalls, 1);
        backend.currentSpace = _spaceB;
        backend.episodePending = Completer<List<double>?>();
        expect((await h.gate.recall(_query)).promptBlock, isEmpty);
        expect(backend.queryCalls, 2);
        expect((await h.metadata())?['spaceId'], _spaceA);
        backend.episodePending!.complete([1, 0]);
        await h.store.waitForIdle();
        expect((await h.metadata())?['spaceId'], _spaceB);
        expect((await h.gate.recall(_query)).promptBlock, contains(_what));
      } finally {
        if (backend.episodePending != null &&
            !backend.episodePending!.isCompleted)
          backend.episodePending!.complete(null);
        await h.close();
      }
    },
  );

  test(
    'late old-space embedding cannot overwrite the episode or label a new space',
    () async {
      final backend = _Backend()..episodePending = Completer<List<double>?>();
      final h = await _Harness.open(backend, labelled: false);
      h.store.scheduleEmbedding(h.episode);
      await backend.episodeStarted.future;
      backend.currentSpace = _spaceB;
      backend.episodePending!.complete([0, 1]);
      await h.store.waitForIdle();
      expect(await h.metadata(), isNull);
      final persisted = await MemoryGovernanceStores.episodes
          .record(h.episode.id!)
          .get(h.db);
      expect(persisted?['embedding'], [1, 0]);
      backend.episodePending = null;
      h.store.scheduleEmbedding(h.episode);
      await h.store.waitForIdle();
      expect((await h.metadata())?['spaceId'], _spaceB);
      await h.close();
    },
  );

  test(
    'a mismatched vector digest fails closed and is repaired without changing facts',
    () async {
      final backend = _Backend()..episodePending = Completer<List<double>?>();
      final h = await _Harness.open(backend, labelled: true);
      await MemoryGovernanceStores.episodeEmbeddingSpaces
          .record(h.episode.id!)
          .update(h.db, {'vectorDigest': 'incorrect'});
      expect((await h.gate.recall(_query)).promptBlock, isEmpty);
      backend.episodePending!.complete([1, 0]);
      await h.store.waitForIdle();
      expect((await h.metadata())?['vectorDigest'], _digest([1, 0]));
      await h.close();
    },
  );
}

String _digest(List<double> vector) =>
    sha256.convert(utf8.encode(jsonEncode(vector))).toString();

class _Harness {
  _Harness(this.db, this.store, this.gate, this.episode);
  final Database db;
  final EpisodeStore store;
  final MemoryRecallSafetyGate gate;
  final Episode episode;
  static Future<_Harness> open(
    _Backend backend, {
    required bool labelled,
    bool legacyCodec = false,
    // These tests check embedding provenance and governance. The independent
    // recall deadline tests continue to use the default 45/50 ms budgets.
    Duration gateBudget = const Duration(seconds: 2),
  }) async {
    final db = await databaseFactoryMemory.openDatabase(
      'embedding-space-${_sequence++}',
    );
    appServices.put<EmbeddingService>(
      EmbeddingService(backend: backend, contextKey: () => 'same-account'),
      overrideAbstract: true,
    );
    final store = EpisodeStore(
      database: db,
      accountScopeDigest: _scope,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
    );
    final episode = Episode(
      when: DateTime.now().toUtc(),
      what: _what,
      embedding: const [1, 0],
    );
    episode.id = await MemoryGovernanceStores.episodes.add(
      db,
      legacyCodec ? episode.toLegacyJson() : episode.toJson(),
    );
    await MemoryGovernanceStores.episodeGovernance.record(episode.id!).put(db, {
      'schemaVersion': 1,
      'episodeId': episode.id,
      'accountScopeDigest': _scope,
      'current': true,
      'reviewState': 'accepted',
    });
    if (labelled)
      await MemoryGovernanceStores.episodeEmbeddingSpaces
          .record(episode.id!)
          .put(db, {
            'schemaVersion': 1,
            'accountScopeDigest': _scope,
            'spaceId': backend.spaceId,
            'vectorDigest': _digest([1, 0]),
          });
    await store.prepareRecallIndex();
    return _Harness(
      db,
      store,
      MemoryRecallSafetyGate(episodeStore: store, budget: gateBudget),
      episode,
    );
  }

  Future<Map<String, Object?>?> metadata() =>
      MemoryGovernanceStores.episodeEmbeddingSpaces.record(episode.id!).get(db);
  Future<void> close() async {
    await gate.deactivateAndDrain();
    await store.deactivateAndDrain();
    await db.close();
  }
}

class _Backend extends EmbeddingBackend {
  String currentSpace = _spaceA;
  int queryCalls = 0;
  Completer<List<double>?>? episodePending;
  final episodeStarted = Completer<void>();
  @override
  String get spaceId => currentSpace;
  @override
  bool get isAvailable => true;
  @override
  Future<List<double>?> embed(String text) async {
    if (text == _what) {
      if (!episodeStarted.isCompleted) episodeStarted.complete();
      return episodePending?.future ?? Future.value([1, 0]);
    }
    if (text == _query) queryCalls++;
    return [1, 0];
  }
}
