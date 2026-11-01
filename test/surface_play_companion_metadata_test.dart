import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_companion_call_ledger.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_agent_document.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_budget.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_messages.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';
import 'package:sembast/sembast_memory.dart';

class _SpyStore implements SurfacePlayPersistence {
  _SpyStore(this.delegate);
  final SurfacePlayPersistence delegate;
  int writes = 0;
  @override
  Future<String?> latestMatchId({
    required String projectId,
    required String revisionId,
  }) => delegate.latestMatchId(projectId: projectId, revisionId: revisionId);
  @override
  Future<Map<String, Object?>?> load(String matchId) => delegate.load(matchId);
  @override
  Future<void> commit({
    required String matchId,
    required int? expectedCommitRevision,
    required Map<String, Object?> next,
    required bool Function() isAuthorized,
  }) async {
    writes++;
    await delegate.commit(
      matchId: matchId,
      expectedCommitRevision: expectedCommitRevision,
      next: next,
      isAuthorized: isAuthorized,
    );
  }
}

class _Harness {
  late DBService db;
  late _SpyStore store;
  late SurfacePlayService service;
  late SurfacePlaySession session;
  late SurfaceCompanionCallLedger ledger;
  bool current = true;
  DateTime now = DateTime.utc(2026, 10, 5);
  var nonce = 0;
  Future<void> open({
    String rules = 'gomoku.v1',
    bool withLedger = true,
  }) async {
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'metadata-${DateTime.now().microsecondsSinceEpoch}',
    );
    ledger = SurfaceCompanionCallLedger(
      database: db,
      scopeKey: 'scope',
      isCurrent: () => current,
      now: () => now,
    );
    store = _SpyStore(
      SurfacePlayStore(
        database: db,
        scopeKey: 'scope',
        isCurrent: () => current,
      ),
    );
    service = SurfacePlayService(
      scopeKey: 'scope',
      persistence: store,
      companionCalls: withLedger ? ledger : null,
      isCurrent: () => current,
      authorizeAgentControl: (_, _) async => true,
      now: () => now,
      nonce: () => 'n-${nonce++}',
      seed: () => 17,
    );
    final protocol = SurfacePlayProtocol.trustedGame(
      projectId: 'test-project',
      revisionId: 'test-revision',
      rulesId: rules,
      config: rules == 'gomoku.v1'
          ? {'boardSize': 5, 'winLength': 3}
          : {'cardsPerRole': 3},
    );
    final json = jsonEncode(protocol.toJson());
    session = await service.openSession(
      protocol: protocol,
      sessionId: 'test-session',
      matchId: 'test-match',
      agentId: 'self',
      contentManifestId: 'test-content',
      protocolJson: json,
      agentDocument: buildSurfacePlayAgentDocument(
        protocol: protocol,
        contentManifestId: 'test-content',
        protocolSha256: surfaceProtocolDigest(json),
      ),
      isPresentationCurrent: () => current,
    );
  }

  Future<void> close() async {
    await service.deactivateAndDrain();
    await db.close();
  }

  Future<SurfacePlayCallReservation> reserve(
    String id, {
    String agent = 'self',
    SurfaceCompanionCallLedger? using,
  }) => (using ?? ledger).reserve(
    agentId: agent,
    invocationId: id,
    requestDigest: 'a' * 64,
    isAuthorized: () => true,
  );
  Future<void> settle(String id, SurfaceCompanionCallOutcome outcome) =>
      ledger.settle(
        agentId: 'self',
        invocationId: id,
        requestDigest: 'a' * 64,
        outcome: outcome,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Harness h;
  setUp(() async {
    h = _Harness();
    await h.open();
  });
  tearDown(() async => h.close());

  test(
    'diagnostics expose only three counters and count durable actions once',
    () async {
      final initial = h.session.readDiagnostics();
      expect(initial.keys.toSet(), {
        'status',
        'phase',
        'matchEpoch',
        'decisionRevision',
        'acceptedActionReceiptCount',
      });
      expect(initial, {
        'status': 'available',
        'phase': 'playing',
        'matchEpoch': 1,
        'decisionRevision': 0,
        'acceptedActionReceiptCount': 0,
      });
      final view = h.session.observeHuman();
      final command = view.commandFor(
        view.legalActions.first,
        requestId: 'human-once',
      );
      expect(
        (await h.session.submitHuman(command)).status,
        SurfacePlayReceiptStatus.applied,
      );
      expect(
        (await h.session.submitHuman(command)).status,
        SurfacePlayReceiptStatus.duplicate,
      );
      final after = h.session.readDiagnostics();
      expect(after['acceptedActionReceiptCount'], 1);
      expect(
        after['decisionRevision'],
        greaterThan(initial['decisionRevision']! as int),
      );
      expect(() => after['seed'] = 17, throwsUnsupportedError);
      h.current = false;
      expect(h.session.readDiagnostics, throwsStateError);
    },
  );

  test(
    'revoking an observer fences it immediately and leaves the player game active',
    () async {
      final player = await h.session.grantAgentControl(seatId: 'player2');
      final observer = await h.session.grantAgentControl(seatId: 'spectator');
      final before = h.session.readDiagnostics();
      final retired = h.session.revokeAgentGrant(observer);
      expect(h.session.grantIsCurrent(observer), isFalse);
      expect(h.session.grantIsCurrent(player), isTrue);
      expect(h.session.isPaused, isFalse);
      await retired;
      expect(h.session.readDiagnostics(), before);
      final nextObserver = await h.session.grantAgentControl(
        seatId: 'spectator',
      );
      final writes = h.store.writes;
      await h.session.revokeAgentGrant(observer);
      expect(h.session.grantIsCurrent(nextObserver), isTrue);
      expect(h.store.writes, writes);
    },
  );

  test(
    'inactive observer revocation cannot write or revive on foreground return',
    () async {
      final player = await h.session.grantAgentControl(seatId: 'player2');
      final observer = await h.session.grantAgentControl(seatId: 'spectator');
      final writes = h.store.writes;
      h.current = false;
      await h.session.revokeAgentGrant(observer);
      expect(h.store.writes, writes);
      h.current = true;
      expect(h.session.grantIsCurrent(observer), isFalse);
      expect(h.session.grantIsCurrent(player), isTrue);
      expect(h.session.isPaused, isFalse);
    },
  );

  test(
    'expired old observer and foreign issuer cannot retire a new grant',
    () async {
      final expired = await h.session.grantAgentControl(
        seatId: 'spectator',
        ttl: const Duration(seconds: 1),
      );
      h.now = h.now.add(const Duration(seconds: 2));
      final current = await h.session.grantAgentControl(seatId: 'spectator');
      final writes = h.store.writes;
      await h.session.revokeAgentGrant(expired);
      expect(h.session.grantIsCurrent(current), isTrue);
      expect(h.store.writes, writes);
      final other = _Harness();
      await other.open();
      try {
        final foreign = await other.session.grantAgentControl(
          seatId: 'spectator',
        );
        expect(() => h.session.revokeAgentGrant(foreign), throwsStateError);
        expect(h.session.grantIsCurrent(current), isTrue);
        expect(h.store.writes, writes);
      } finally {
        await other.close();
      }
    },
  );

  test(
    'player grant retirement restores only that seat without pausing humans',
    () async {
      final player = await h.session.grantAgentControl(seatId: 'player2');
      final observer = await h.session.grantAgentControl(seatId: 'spectator');
      await h.session.revokeAgentGrant(player);
      expect(h.session.grantIsCurrent(player), isFalse);
      expect(h.session.grantIsCurrent(observer), isTrue);
      expect(h.session.isPaused, isFalse);
      final human = h.session.observeHuman();
      expect(
        (await h.session.submitHuman(
          human.commandFor(
            human.legalActions.first,
            requestId: 'human-after-stop',
          ),
        )).status,
        SurfacePlayReceiptStatus.applied,
      );
    },
  );

  test(
    'visibility loss while inactive is synchronous, read-only and requires explicit resume',
    () async {
      final grant = await h.session.grantAgentControl(seatId: 'spectator');
      final view = h.session.observeHuman();
      final oldCommand = view.commandFor(
        view.legalActions.first,
        requestId: 'old-human',
      );
      final writes = h.store.writes;
      h.current = false;
      final suspended = h.session.suspendForVisibilityLoss();
      expect(h.session.isPaused, isTrue);
      await suspended;
      expect(h.store.writes, writes);
      h.current = true;
      expect(h.session.grantIsCurrent(grant), isFalse);
      expect(h.session.isPaused, isTrue);
      expect(h.session.observeHuman().legalActions, isEmpty);
      expect(
        (await h.session.submitHuman(oldCommand)).status,
        SurfacePlayReceiptStatus.rejected,
      );
      await h.session.resume();
      expect(h.session.isPaused, isFalse);
      expect(h.session.grantIsCurrent(grant), isFalse);
      final fresh = h.session.observeHuman();
      expect(
        (await h.session.submitHuman(
          fresh.commandFor(
            fresh.legalActions.first,
            requestId: 'resumed-human',
          ),
        )).status,
        SurfacePlayReceiptStatus.applied,
      );
    },
  );

  test(
    'active visibility suspension persists once and remains safe after close',
    () async {
      final epoch = h.session.readDiagnostics()['matchEpoch']! as int;
      final first = h.session.suspendForVisibilityLoss();
      expect(h.session.isPaused, isTrue);
      expect(h.session.readDiagnostics()['matchEpoch'], epoch + 1);
      await first;
      final writes = h.store.writes;
      await h.session.suspendForVisibilityLoss();
      expect(h.store.writes, writes);
      await h.session.close();
      await h.session.suspendForVisibilityLoss();
      expect(h.store.writes, writes);
    },
  );

  test(
    'usage reads only aggregate outcomes and does not mutate journals or admission',
    () async {
      await h.reserve('completed');
      await h.settle('completed', SurfaceCompanionCallOutcome.completed);
      await h.reserve('unknown');
      await h.settle('unknown', SurfaceCompanionCallOutcome.unknown);
      await h.reserve('pending');
      await h.reserve('not-dispatched');
      await h.settle(
        'not-dispatched',
        SurfaceCompanionCallOutcome.notDispatched,
      );
      final expected = {
        'status': 'available',
        'completed': 1,
        'unknown': 1,
        'pending': 1,
        'notDispatched': 1,
      };
      final stores = [
        stringMapStoreFactory.store('surface_companion_calls.v1'),
        stringMapStoreFactory.store('surface_companion_periods.v1'),
        stringMapStoreFactory.store('surface_companion_migration.v1'),
      ];
      final before = [
        for (final store in stores)
          jsonEncode(
            (await store.find(
              h.db.raw,
            )).map((row) => {'key': row.key, 'value': row.value}).toList(),
          ),
      ];
      expect(await h.ledger.readUsageForAgent('self'), expected);
      expect(await h.session.readModelCallUsage(), expected);
      expect(await h.ledger.readUsageForAgent('self'), expected);
      final after = [
        for (final store in stores)
          jsonEncode(
            (await store.find(
              h.db.raw,
            )).map((row) => {'key': row.key, 'value': row.value}).toList(),
          ),
      ];
      expect(after, before);
    },
  );

  test(
    'usage keeps earlier unresolved holds and handles clock rollback without writes',
    () async {
      await h.reserve('old-completed');
      await h.settle('old-completed', SurfaceCompanionCallOutcome.completed);
      await h.reserve('old-unknown');
      await h.settle('old-unknown', SurfaceCompanionCallOutcome.unknown);
      await h.reserve('old-pending');
      h.now = h.now.add(const Duration(minutes: 31));
      expect(await h.ledger.readUsageForAgent('self'), {
        'status': 'available',
        'completed': 0,
        'unknown': 1,
        'pending': 1,
        'notDispatched': 0,
      });
      final result = await h.ledger.reserve(
        agentId: 'self',
        invocationId: 'still-held',
        requestDigest: 'a' * 64,
        isAuthorized: () => true,
        budget: const SurfacePlayCallBudget(maximumCalls: 2),
      );
      expect(result.status, SurfacePlayCallReservationStatus.totalExhausted);
      h.now = DateTime.utc(2026, 10, 4);
      final rollback = await h.ledger.readUsageForAgent('self');
      expect(rollback['pending'], 1);
      expect(rollback['unknown'], 1);
    },
  );

  test(
    'usage is isolated by account scope and Agent and rejects stale reads',
    () async {
      await h.reserve('one');
      await h.reserve('other', agent: 'another-agent');
      final other = SurfaceCompanionCallLedger(
        database: h.db,
        scopeKey: 'other-scope',
        isCurrent: () => h.current,
        now: () => h.now,
      );
      expect((await h.ledger.readUsageForAgent('self'))['pending'], 1);
      expect((await h.ledger.readUsageForAgent('another-agent'))['pending'], 1);
      expect((await other.readUsageForAgent('self'))['pending'], 0);
      final late = h.ledger.readUsageForAgent('self');
      h.current = false;
      await expectLater(late, throwsStateError);
      await expectLater(h.session.readModelCallUsage(), throwsStateError);
    },
  );

  test(
    'corrupt, unattributed legacy or missing ledger evidence is unknown rather than zero',
    () async {
      await h.reserve('valid');
      final calls = stringMapStoreFactory.store('surface_companion_calls.v1');
      await calls.record('broken-metadata').put(h.db.raw, {
        'schemaVersion': 1,
        'scopeKey': 'scope',
        'agentId': 'self',
        'outcome': 'reserved',
        'at': 'invalid',
      });
      expect(
        await h.ledger.readUsageForAgent('self'),
        SurfaceCompanionCallLedger.unknownUsage,
      );
      await calls.record('broken-metadata').delete(h.db.raw);
      await stringMapStoreFactory
          .store('surface_companion_legacy_calls.v1')
          .record('legacy')
          .put(h.db.raw, {
            'scopeKey': 'scope',
            'outcome': 'unknown',
            'at': h.now.toIso8601String(),
          });
      expect(
        await h.ledger.readUsageForAgent('self'),
        SurfaceCompanionCallLedger.unknownUsage,
      );
      final missing = _Harness();
      await missing.open(withLedger: false);
      try {
        expect(
          await missing.session.readModelCallUsage(),
          SurfaceCompanionCallLedger.unknownUsage,
        );
      } finally {
        await missing.close();
      }
    },
  );
}
