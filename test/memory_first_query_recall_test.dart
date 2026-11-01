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

const _scopeA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _scopeB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
var _sequence = 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'first synonym query uses a fast provider within the recall budget',
    () async {
      final provider = _Embedding(Future.value([1, 0]));
      final h = await _Recall.open(provider);
      addTearDown(h.close);
      final result = await h.gate.recall('beverage preference');
      expect(provider.calls, 1);
      expect(result.status, MemoryRecallStatus.complete);
      expect(result.directCount, 1);
      expect(result.promptBlock, contains('oolong tea'));
    },
  );

  test(
    'the first query embedding starts before waiting for cold candidates',
    () async {
      final provider = _Embedding(Future.value([1, 0]));
      final h = await _Recall.open(
        provider,
        recallFault: (point) async {
          if (point == EpisodeRecallIndexFaultPoint.beforeCandidateRead) {
            await provider.started.future;
          }
        },
      );
      addTearDown(h.close);
      final result = await h.gate.recall('beverage preference');
      expect(result.status, MemoryRecallStatus.complete);
      expect(result.promptBlock, contains('oolong tea'));
    },
  );

  test(
    'a slow semantic provider cannot hold recall beyond its fixed deadline',
    () async {
      final pending = Completer<List<double>?>();
      final provider = _Embedding(pending.future);
      final h = await _Recall.open(provider);
      try {
        final result = await h.gate
            .recall('beverage preference')
            .timeout(const Duration(milliseconds: 100));
        expect(pending.isCompleted, isFalse);
        // Semantic fallback can finish with no hits, or the whole gate can
        // exhaust its remaining budget under scheduler contention. Both must
        // return without waiting for the provider and without emitting memory.
        expect(
          result.status,
          anyOf(MemoryRecallStatus.empty, MemoryRecallStatus.timedOut),
        );
        expect(result.promptBlock, isEmpty);
        expect(result.directCount, 0);
        expect(result.entangledCount, 0);
        expect(provider.calls, 1);
        pending.complete([1, 0]);
        await h.store.waitForIdle();
        expect(
          (await h.gate.recall('beverage preference')).promptBlock,
          contains('oolong tea'),
        );
      } finally {
        if (!pending.isCompleted) pending.complete(null);
        await h.close();
      }
    },
  );

  test(
    'keyword hits return while the remote semantic query is still pending',
    () async {
      final pending = Completer<List<double>?>();
      final h = await _Recall.open(_Embedding(pending.future));
      try {
        final result = await h.gate
            .recall('oolong')
            .timeout(const Duration(milliseconds: 100));
        expect(pending.isCompleted, isFalse);
        expect(result.promptBlock, contains('oolong tea'));
      } finally {
        pending.complete(null);
        await h.close();
      }
    },
  );

  test(
    'same-query recalls join one embedding and revalidate governance afterwards',
    () async {
      final pending = Completer<List<double>?>();
      final provider = _Embedding(pending.future);
      final h = await _Recall.open(provider);
      final first = h.gate.recall('beverage preference');
      final second = h.gate.recall('beverage preference');
      await provider.started.future;
      await MemoryGovernanceStores.episodeGovernance.record(h.id).update(h.db, {
        'current': false,
      });
      pending.complete([1, 0]);
      final results = await Future.wait([first, second]);
      expect(provider.calls, 1);
      expect(results.every((result) => result.promptBlock.isEmpty), isTrue);
      await h.close();
    },
  );

  test(
    'account retirement drains the old query without publishing it into new scope',
    () async {
      final pending = Completer<List<double>?>();
      final provider = _Embedding(pending.future);
      final old = await _Recall.open(provider);
      final oldResult = old.gate.recall('beverage preference');
      await provider.started.future;
      var drained = false;
      final oldDrain = Future.wait([
        old.gate.deactivateAndDrain(),
        old.store.deactivateAndDrain(),
      ]).then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      final current = await _Recall.open(
        _Embedding(Future.value([0, 1])),
        scope: _scopeB,
        what: 'jasmine selection',
        vector: [0, 1],
      );
      pending.complete([1, 0]);
      await oldDrain;
      expect((await oldResult).promptBlock, isEmpty);
      final currentResult = await current.gate.recall('beverage preference');
      expect(currentResult.promptBlock, contains('jasmine selection'));
      expect(currentResult.promptBlock, isNot(contains('oolong')));
      await old.close();
      await current.close();
    },
  );
}

class _Recall {
  _Recall(this.db, this.store, this.gate, this.id);
  final Database db;
  final EpisodeStore store;
  final MemoryRecallSafetyGate gate;
  final int id;
  static Future<_Recall> open(
    EmbeddingService embedding, {
    String scope = _scopeA,
    String what = 'oolong tea',
    List<double> vector = const [1, 0],
    EpisodeRecallIndexFaultInjector? recallFault,
  }) async {
    final db = await databaseFactoryMemory.openDatabase(
      'first-query-${_sequence++}',
    );
    appServices.put<EmbeddingService>(embedding, overrideAbstract: true);
    final store = EpisodeStore(
      database: db,
      accountScopeDigest: scope,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      recallIndexFaultInjector: recallFault,
    );
    final episode = Episode(
      when: DateTime.now().toUtc(),
      what: what,
      embedding: vector,
      reviewState: EpisodeReviewState.accepted,
    );
    final id = await MemoryGovernanceStores.episodes.add(db, episode.toJson());
    await MemoryGovernanceStores.episodeGovernance.record(id).put(db, {
      'schemaVersion': 1,
      'episodeId': id,
      'accountScopeDigest': scope,
      'current': true,
      'reviewState': 'accepted',
    });
    await MemoryGovernanceStores.episodeEmbeddingSpaces.record(id).put(db, {
      'schemaVersion': 1,
      'accountScopeDigest': scope,
      'spaceId': embedding.embeddingSpaceId,
      'vectorDigest': sha256
          .convert(utf8.encode(jsonEncode(vector)))
          .toString(),
    });
    await store.prepareRecallIndex();
    return _Recall(db, store, MemoryRecallSafetyGate(episodeStore: store), id);
  }

  Future<void> close() async {
    await gate.deactivateAndDrain();
    await store.deactivateAndDrain();
    await db.close();
  }
}

class _Embedding extends EmbeddingService {
  _Embedding(this.result);
  final Future<List<double>?> result;
  final started = Completer<void>();
  int calls = 0;
  @override
  bool get isAvailable => true;
  @override
  Future<List<double>?> embed(String text) {
    calls++;
    if (!started.isCompleted) started.complete();
    return result;
  }
}
