import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
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
  setUp(() => appServices.reset());
  tearDown(() => appServices.reset());

  test(
    'accepted owner memory keeps audited material, deduplicates, and does not echo',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final payload = _accepted();
      await h.receive(payload);
      final entries = await h.current();
      expect(entries, hasLength(1));
      final episode = entries.single.episode;
      expect(episode.reviewState, EpisodeReviewState.accepted);
      expect(episode.what, '用户喜欢乌龙茶');
      expect(episode.sourceRefs, hasLength(1));
      final source = await h.ledger.sourceTranscript(episode.sourceRefs.single);
      expect(source.status, MemorySourceTranscriptStatus.verified);
      final material = jsonDecode(source.content!) as Map;
      expect((material['sources'] as List).single['material'], '用户明确说：我喜欢乌龙茶。');
      final count = await MemoryGovernanceStores.episodes.count(h.db);
      await h.receive(payload);
      await h.receive(
        Map<String, Object?>.fromEntries(payload.entries.toList().reversed),
      );
      expect(await MemoryGovernanceStores.episodes.count(h.db), count);
      expect(
        await h.ledger.exportOnlineMemoryChange(
          episode.id!,
          () => 'unexpected-echo',
        ),
        isNull,
      );
      await expectLater(
        h.receive({...payload, 'what': 'changed without new revision'}),
        throwsFormatException,
      );
    },
  );

  test(
    'only the owner admits accepted facts and source hashes and fields are validated',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await expectLater(
        h.receive(_accepted(), owner: false),
        throwsFormatException,
      );
      final cases = <Map<String, Object?>>[
        {
          ..._accepted(),
          'sources': [
            {
              'sourceId': 'chat_message:7',
              'hash': '0' * 64,
              'material': 'changed',
            },
          ],
        },
        {..._accepted(), 'sources': []},
        {
          ..._accepted(),
          'sources': [
            {'sourceId': '', 'hash': _digest('x'), 'material': 'x'},
          ],
        },
        {..._accepted(), 'kind': 'install_remote_master'},
        {..._accepted(), 'when': 123},
        {..._accepted(), 'when': '2026-09-15T10:00:00'},
        {..._accepted(), 'master.md': 'injected'},
        {..._accepted(), 'what': 'x' * 4097},
      ];
      for (final input in cases) {
        await expectLater(h.receive(input), throwsFormatException);
      }
      expect(await h.current(), isEmpty);
      expect(await MemoryGovernanceStores.episodes.count(h.db), 0);
      await h.receive(_accepted());
      expect(await h.current(), hasLength(1));
    },
  );

  test(
    'a non-owner may delete, and stale or newer accepted replays never revive a tombstone',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.receive(_accepted());
      final tombstone = _deleted(2);
      await h.receive(tombstone, owner: false);
      expect(await h.current(), isEmpty);
      await h.receive(_accepted());
      await h.receive(_accepted(revision: 3));
      await h.receive(tombstone, owner: false);
      expect(await h.current(), isEmpty);
      await expectLater(
        h.receive({
          'state': 'tombstoned',
          'revision': 2,
          'id': 'memory-origin-1',
          'what': 'body',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'tombstone replay completes a deletion interrupted after its durable marker',
    () async {
      var fail = false;
      final h = await _Harness.open(
        fault: (point, _) {
          if (fail && point == MemoryWriteFaultPoint.beforeCommit) {
            throw StateError('simulated crash before governance delete');
          }
        },
      );
      addTearDown(h.close);
      await h.receive(_accepted());
      fail = true;
      await expectLater(h.receive(_deleted(2), owner: false), throwsStateError);
      expect(await h.current(), hasLength(1));
      fail = false;
      await h.receive(_deleted(2), owner: false);
      expect(await h.current(), isEmpty);
      await h.receive(_accepted(revision: 3));
      expect(await h.current(), isEmpty);
    },
  );

  test(
    'remote tombstone follows the latest local edit and propagates in both directions',
    () async {
      final a = await _Harness.open(), b = await _Harness.open();
      addTearDown(a.close);
      addTearDown(b.close);
      final local = await a.write('用户喜欢乌龙茶');
      final accepted = await a.ledger.exportOnlineMemoryChange(
        local.id!,
        () => 'shared-origin-123',
      );
      expect(accepted, isNotNull);
      await b.receive(accepted!);
      final imported = (await b.current()).single;
      final edited = await b.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.edit,
          targetEpisodeId: imported.episode.id!,
          expectedHeadEpisodeId: imported.episode.id!,
          expectedRevision: imported.episode.revision,
          edit: const MemoryEpisodeEdit(what: '用户偏好焙火乌龙茶'),
        ),
      );
      expect(edited.status, MemoryGovernanceStatus.applied);
      await b.receive({
        'id': accepted['id'],
        'revision': 2,
        'state': 'tombstoned',
      }, owner: false);
      expect(await b.current(), isEmpty);
      // A deletion made locally on a peer preserves the shared origin for the owner.
      final c = await _Harness.open();
      addTearDown(c.close);
      await c.receive(accepted);
      final peer = (await c.current()).single;
      final removed = await c.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: peer.episode.id!,
          expectedHeadEpisodeId: peer.episode.id!,
          expectedRevision: peer.episode.revision,
        ),
      );
      final deletion = await c.ledger.exportOnlineMemoryChange(
        removed.episodeId!,
        () => 'must-not-create-origin',
      );
      expect(deletion, {
        'id': accepted['id'],
        'revision': 2,
        'state': 'tombstoned',
      });
      await a.receive(deletion!, owner: false);
      expect(await a.current(), isEmpty);
    },
  );

  test(
    'account retirement and shared-database mirror keys cannot cross accounts',
    () async {
      final a = await _Harness.open();
      addTearDown(a.close);
      final b = await _Harness.open(database: a.db, digest: 'b' * 64);
      addTearDown(b.close);
      await a.receive(_deleted(2), owner: false);
      await b.receive(_accepted());
      expect(await b.current(), hasLength(1));
      expect(await a.current(), isEmpty);
      await expectLater(
        a.ledger.importOnlineMemoryChange(
          _accepted(),
          sourceInstallationId: 'remote-installation',
          sourceIsOwner: true,
          isCurrent: () => false,
        ),
        throwsStateError,
      );
      expect(await a.current(), isEmpty);
    },
  );

  test(
    'an import and its DB notification export serialize, avoiding a new origin echo',
    () async {
      final reached = Completer<void>(), release = Completer<void>();
      var block = true;
      final h = await _Harness.open(
        fault: (point, _) async {
          if (block && point == MemoryWriteFaultPoint.afterCommit) {
            block = false;
            reached.complete();
            await release.future;
          }
        },
      );
      addTearDown(h.close);
      final importing = h.receive(_accepted());
      await reached.future;
      final rows = await MemoryGovernanceStores.episodes.find(h.db);
      expect(rows, hasLength(1));
      var exportDone = false;
      final exporting = h.ledger
          .exportOnlineMemoryChange(rows.single.key, () => 'loop-origin')
          .then((value) {
            exportDone = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(exportDone, isFalse);
      release.complete();
      await importing;
      expect(await exporting, isNull);
      await Future.wait([
        h.receive(_accepted(revision: 2)),
        h.receive(_deleted(3), owner: false),
      ]);
      expect(await h.current(), isEmpty);
    },
  );

  test('pending and unaudited local records are not exported', () async {
    final h = await _Harness.open();
    addTearDown(h.close);
    final pending = await h.writer.write(
      MemoryWriteDraft.event(what: 'pending', when: DateTime.utc(2026, 9, 15)),
      source: MemoryWriteSource.imported(
        sourceKind: 'test',
        sourceKey: 'pending',
        canonicalMaterial: 'pending',
      ),
      authority: MemoryWriteAuthority.inherited,
    );
    expect(
      await h.ledger.exportOnlineMemoryChange(
        pending.episodeId!,
        () => 'pending-origin',
      ),
      isNull,
    );
    expect(
      await h.ledger.exportOnlineMemoryChange(99999, () => 'missing-origin'),
      isNull,
    );
  });
}

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();
Map<String, Object?> _accepted({int revision = 1}) => {
  'id': 'memory-origin-1',
  'revision': revision,
  'state': 'accepted',
  'what': '用户喜欢乌龙茶',
  'when': '2026-09-15T10:00:00.000Z',
  'kind': 'preference',
  'sources': [
    {
      'sourceId': 'chat_message:7',
      'hash': _digest('用户明确说：我喜欢乌龙茶。'),
      'material': '用户明确说：我喜欢乌龙茶。',
    },
  ],
};
Map<String, Object?> _deleted(int revision) => {
  'id': 'memory-origin-1',
  'revision': revision,
  'state': 'tombstoned',
};

final class _Harness {
  _Harness(this.db, this.store, this.writer, this.ledger, this.ownsDB);
  final Database db;
  final EpisodeStore store;
  final MemoryWriteCoordinator writer;
  final MemoryLedgerService ledger;
  final bool ownsDB;
  static Future<_Harness> open({
    Database? database,
    String? digest,
    MemoryWriteFaultInjector? fault,
  }) async {
    final db =
        database ??
        await databaseFactoryMemory.openDatabase(
          'live-memory-${DateTime.now().microsecondsSinceEpoch}.db',
        );
    final account = digest ?? 'a' * 64;
    final store = EpisodeStore(
      database: db,
      accountScopeDigest: account,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
    );
    final writer = MemoryWriteCoordinator(
      database: db,
      episodeStore: store,
      accountScopeDigest: account,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      faultInjector: fault,
    );
    final ledger = MemoryLedgerService(
      database: db,
      coordinator: writer,
      accountScopeDigest: account,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
    );
    return _Harness(db, store, writer, ledger, database == null);
  }

  Future<void> receive(Map<String, Object?> payload, {bool owner = true}) =>
      ledger.importOnlineMemoryChange(
        payload,
        sourceInstallationId: 'remote-installation',
        sourceIsOwner: owner,
        isCurrent: () => true,
      );
  Future<List<MemoryLedgerEntry>> current() async => (await ledger.list(
    limit: 50,
  )).entries.where((entry) => entry.current).toList();
  Future<Episode> write(String what) async => (await writer.write(
    MemoryWriteDraft.event(what: what, when: DateTime.utc(2026, 9, 15)),
    source: MemoryWriteSource.imported(
      sourceKind: 'local-test',
      sourceKey: what,
      canonicalMaterial: what,
    ),
    authority: MemoryWriteAuthority.verifiedHost,
  )).episode!;
  Future<void> close() async {
    await ledger.deactivateAndDrain();
    await writer.deactivateAndDrain();
    await store.deactivateAndDrain();
    ledger.closeLifecycle();
    writer.closeLifecycle();
    store.closeLifecycle();
    if (ownsDB) await db.close();
  }
}
