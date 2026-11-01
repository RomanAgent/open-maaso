import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_companion_call_ledger.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_budget.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  late SurfaceCompanionCallLedger ledger;
  late DateTime now;
  var current = true;
  SurfaceCompanionCallLedger create([String scope = 'scope']) =>
      SurfaceCompanionCallLedger(
        database: db,
        scopeKey: scope,
        isCurrent: () => current,
        now: () => now,
      );
  Future<SurfacePlayCallReservation> reserve(
    String id, {
    String agent = 'agent',
    String? digest,
    SurfaceCompanionCallLedger? using,
    SurfacePlayCallBudget budget = const SurfacePlayCallBudget(),
  }) => (using ?? ledger).reserve(
    agentId: agent,
    invocationId: id,
    requestDigest: digest ?? 'a' * 64,
    isAuthorized: () => true,
    budget: budget,
  );
  Future<void> settle(
    String id,
    SurfaceCompanionCallOutcome outcome, {
    String agent = 'agent',
  }) => ledger.settle(
    agentId: agent,
    invocationId: id,
    requestDigest: 'a' * 64,
    outcome: outcome,
  );
  setUp(() async {
    current = true;
    now = DateTime.utc(2026, 10, 1);
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'budget-${DateTime.now().microsecondsSinceEpoch}',
    );
    ledger = create();
  });
  tearDown(() async => db.close());
  test(
    'independent consumers share rate window; original identity is durable across recreation',
    () async {
      final preview = create();
      for (var i = 0; i < 8; i++) {
        expect(
          (await reserve(
            'i-$i',
            using: i.isEven ? ledger : preview,
          )).isReserved,
          isTrue,
        );
        await settle('i-$i', SurfaceCompanionCallOutcome.unknown);
      }
      final result = await reserve('ninth', using: create());
      expect(result.status, SurfacePlayCallReservationStatus.rateLimited);
      expect(result.nextAllowedAt, now.add(const Duration(minutes: 1)));
      await expectLater(reserve('i-0', digest: 'b' * 64), throwsStateError);
      expect(
        (await reserve('i-0', using: create())).status,
        SurfacePlayCallReservationStatus.duplicate,
      );
      now = now.add(const Duration(minutes: 1));
      expect((await reserve('ninth', using: preview)).isReserved, isTrue);
      await expectLater(
        settle('i-0', SurfaceCompanionCallOutcome.notDispatched),
        throwsStateError,
      );
    },
  );
  test(
    'not-dispatched releases admission but never enables same-nonce replay',
    () async {
      const budget = SurfacePlayCallBudget(maximumCalls: 1);
      expect((await reserve('a', budget: budget)).isReserved, isTrue);
      await settle('a', SurfaceCompanionCallOutcome.notDispatched);
      expect(
        (await reserve('a', budget: budget)).status,
        SurfacePlayCallReservationStatus.duplicate,
      );
      expect((await reserve('b', budget: budget)).isReserved, isTrue);
      await settle('b', SurfaceCompanionCallOutcome.unknown);
      await expectLater(
        settle('b', SurfaceCompanionCallOutcome.notDispatched),
        throwsStateError,
      );
    },
  );
  test(
    'fixed 30-minute total rolls completed calls but retains every unknown hold',
    () async {
      final initial = now;
      for (var i = 0; i < 64; i++) {
        if (i > 0 && i % 8 == 0) now = now.add(const Duration(minutes: 1));
        expect((await reserve('call-$i')).isReserved, isTrue);
        await settle(
          'call-$i',
          i == 0
              ? SurfaceCompanionCallOutcome.unknown
              : SurfaceCompanionCallOutcome.completed,
        );
      }
      final exhausted = await reserve('extra');
      expect(exhausted.status, SurfacePlayCallReservationStatus.rateLimited);
      expect(exhausted.nextAllowedAt, initial.add(const Duration(minutes: 30)));
      now = initial.add(const Duration(minutes: 30));
      expect((await reserve('next-period')).isReserved, isTrue);
      await settle('next-period', SurfaceCompanionCallOutcome.completed);
      const one = SurfacePlayCallBudget(maximumCalls: 1);
      expect(
        (await reserve('held-is-still-counted', budget: one)).status,
        SurfacePlayCallReservationStatus.totalExhausted,
      );
    },
  );
  test(
    'account and Agent isolation and authorization are independent of durable identity',
    () async {
      const budget = SurfacePlayCallBudget(maximumCalls: 1);
      await reserve('first', budget: budget);
      expect(
        (await reserve(
          'other-agent',
          agent: 'other',
          budget: budget,
        )).isReserved,
        isTrue,
      );
      expect(
        (await reserve(
          'other-scope',
          using: create('other-scope'),
          budget: budget,
        )).isReserved,
        isTrue,
      );
      expect(
        (await ledger.reserve(
          agentId: 'agent',
          invocationId: 'denied',
          requestDigest: 'a' * 64,
          isAuthorized: () => false,
        )).status,
        SurfacePlayCallReservationStatus.unavailable,
      );
      current = false;
      await expectLater(reserve('late'), throwsStateError);
      await expectLater(
        settle('first', SurfaceCompanionCallOutcome.completed),
        throwsStateError,
      );
    },
  );
  test('concurrent consumers cannot both pass the last slot', () async {
    const budget = SurfacePlayCallBudget(maximumCalls: 1);
    final results = await Future.wait([
      reserve('a', budget: budget),
      reserve('b', using: create(), budget: budget),
    ]);
    expect(results.where((r) => r.isReserved), hasLength(1));
  });
  test(
    'legacy formal and preview holds preserve account pool without fabricating Agent attribution',
    () async {
      final matches = stringMapStoreFactory.store('surface_play_matches.v2');
      for (final scope in ['scope', 'scope|preview']) {
        await matches.record(scope).put(db.raw, {
          'scopeKey': scope,
          'matchId': 'legacy-match',
          'modelCalls': [
            {
              'invocationId': 'old',
              'seatId': 'player2',
              'at': now.subtract(const Duration(minutes: 5)).toIso8601String(),
              'outcome': 'unknown',
            },
          ],
        });
      }
      const budget = SurfacePlayCallBudget(maximumCalls: 2);
      expect(
        (await reserve('new', budget: budget)).status,
        SurfacePlayCallReservationStatus.rateLimited,
      );
      now = now.add(const Duration(minutes: 31));
      expect(
        (await reserve('new-agent', agent: 'other', budget: budget)).status,
        SurfacePlayCallReservationStatus.totalExhausted,
      );
    },
  );
}
