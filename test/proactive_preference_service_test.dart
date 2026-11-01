import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const accountB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  setUp(() async {
    resetAppProviderContainerForTest();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(resetAppProviderContainerForTest);

  test('codec is strict and canonical quiet boundary is 22:00-07:00', () {
    const snapshot = ProactivePreferenceSnapshot.defaults(generation: 7);

    expect(snapshot.revision, 1);
    expect(snapshot.dailyBudget, 1);
    expect(snapshot.isQuietAt(DateTime(2026, 8, 28, 21, 59)), isFalse);
    expect(snapshot.isQuietAt(DateTime(2026, 8, 28, 22)), isTrue);
    expect(snapshot.isQuietAt(DateTime(2026, 8, 29, 6, 59)), isTrue);
    expect(snapshot.isQuietAt(DateTime(2026, 8, 29, 7)), isFalse);

    final restored = ProactivePreferenceSnapshot.fromStorageJson(
      snapshot.toStorageJson(),
      generation: 9,
    );
    expect(restored.generation, 9);
    expect(restored.quietStartMinutes, 22 * 60);
    expect(restored.frequency, ProactiveContactFrequency.balanced);

    final unknown = Map<String, Object?>.from(snapshot.toStorageJson())
      ..['unknown'] = true;
    expect(
      () => ProactivePreferenceSnapshot.fromStorageJson(unknown, generation: 1),
      throwsFormatException,
    );
    final widenedBudget = Map<String, Object?>.from(snapshot.toStorageJson())
      ..['dailyBudget'] = 4;
    expect(
      () => ProactivePreferenceSnapshot.fromStorageJson(
        widenedBudget,
        generation: 1,
      ),
      throwsFormatException,
    );
  });

  test(
    'legacy claim migrates only quiet and bounded budget to one account',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPreferencesProactivePreferenceLegacyMigration.legacyStorageKey:
            jsonEncode(<String, Object?>{
              'enabled': false,
              'permissionGranted': false,
              'greetingsEnabled': false,
              'randomCheckInsEnabled': false,
              'scheduledTasksEnabled': false,
              'quietStartMinutes': 23 * 60,
              'quietEndMinutes': 8 * 60,
              'dailyProactiveBudget': 4,
            }),
      });
      final shared = await SharedPreferences.getInstance();
      final migration = SharedPreferencesProactivePreferenceLegacyMigration(
        shared,
      );
      final storeA = _MemoryPreferenceStore();
      final serviceA = await ProactivePreferenceService(
        store: storeA,
        accountScopeDigest: accountA,
        generation: 1,
        legacyMigration: migration,
      ).init();

      final migrated = serviceA.effectiveSnapshot;
      expect(migrated.hardMuted, isFalse);
      expect(migrated.foregroundEnabled, isFalse);
      expect(migrated.needsConsentReview, isTrue);
      expect(migrated.osOutreachEnabled, isFalse);
      expect(migrated.quietStartMinutes, 23 * 60);
      expect(migrated.quietEndMinutes, 8 * 60);
      expect(migrated.dailyBudget, 3);
      expect(storeA.rows, hasLength(1));

      final journal =
          jsonDecode(
                shared.getString(
                  SharedPreferencesProactivePreferenceLegacyMigration
                      .journalStorageKey,
                )!,
              )
              as Map<String, dynamic>;
      expect(journal['ownerScopeDigest'], accountA);
      expect(journal['complete'], isTrue);

      final serviceB = await ProactivePreferenceService(
        store: _MemoryPreferenceStore(),
        accountScopeDigest: accountB,
        generation: 2,
        legacyMigration: migration,
      ).init();
      expect(serviceB.effectiveSnapshot.quietStartMinutes, 22 * 60);
      expect(serviceB.effectiveSnapshot.quietEndMinutes, 7 * 60);
      expect(serviceB.effectiveSnapshot.dailyBudget, 1);
    },
  );

  test(
    'migration claim survives target write failure for owner retry',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPreferencesProactivePreferenceLegacyMigration.legacyStorageKey:
            jsonEncode(<String, Object?>{
              'quietStartMinutes': 21 * 60,
              'quietEndMinutes': 6 * 60,
              'dailyProactiveBudget': 2,
            }),
      });
      final shared = await SharedPreferences.getInstance();
      final migration = SharedPreferencesProactivePreferenceLegacyMigration(
        shared,
      );
      final failing = _MemoryPreferenceStore()..failWrites = true;
      final first = await ProactivePreferenceService(
        store: failing,
        accountScopeDigest: accountA,
        generation: 1,
        legacyMigration: migration,
      ).init();

      expect(first.effectiveSnapshot.hardMuted, isTrue);
      final claimed =
          jsonDecode(
                shared.getString(
                  SharedPreferencesProactivePreferenceLegacyMigration
                      .journalStorageKey,
                )!,
              )
              as Map<String, dynamic>;
      expect(claimed['ownerScopeDigest'], accountA);
      expect(claimed['complete'], isFalse);
      expect(claimed['quietStartMinutes'], 21 * 60);
      expect(claimed['quietEndMinutes'], 6 * 60);
      expect(claimed['dailyBudget'], 2);

      await shared.setString(
        SharedPreferencesProactivePreferenceLegacyMigration.legacyStorageKey,
        jsonEncode(<String, Object?>{
          'enabled': true,
          'permissionGranted': true,
          'greetingsEnabled': false,
          'randomCheckInsEnabled': true,
          'scheduledTasksEnabled': false,
          'quietStartMinutes': 21 * 60,
          'quietEndMinutes': 6 * 60,
          'dailyProactiveBudget': 2,
        }),
      );

      final blockedB = await ProactivePreferenceService(
        store: _MemoryPreferenceStore(),
        accountScopeDigest: accountB,
        generation: 2,
        legacyMigration: migration,
      ).init();
      expect(blockedB.effectiveSnapshot.quietStartMinutes, 22 * 60);
      await shared.remove(
        SharedPreferencesProactivePreferenceLegacyMigration.legacyStorageKey,
      );

      final retriedA = await ProactivePreferenceService(
        store: _MemoryPreferenceStore(),
        accountScopeDigest: accountA,
        generation: 3,
        legacyMigration: migration,
      ).init();
      expect(retriedA.effectiveSnapshot.quietStartMinutes, 21 * 60);
      expect(retriedA.effectiveSnapshot.quietEndMinutes, 6 * 60);
      expect(retriedA.effectiveSnapshot.dailyBudget, 2);
    },
  );

  test(
    'updates are durable before publish and revisions are serialized',
    () async {
      final writeGate = Completer<void>();
      final store = _MemoryPreferenceStore()..writeGate = writeGate.future;
      final service = ProactivePreferenceService(
        store: store,
        accountScopeDigest: accountA,
        generation: 1,
      );

      final initialization = service.init();
      await Future<void>.delayed(Duration.zero);
      writeGate.complete();
      await initialization;
      store.writeGate = Completer<void>().future;

      final quiet = service.setQuietHours(start: 20 * 60, end: 6 * 60);
      final budget = service.setDailyBudget(2);
      await Future<void>.delayed(Duration.zero);

      expect(service.effectiveSnapshot.quietStartMinutes, 22 * 60);
      expect(service.effectiveSnapshot.dailyBudget, 1);
      (store.writeGate as Future<void>); // Keep the gated future strongly held.
      store.releaseWrites();
      await Future.wait<void>(<Future<void>>[quiet, budget]);

      expect(service.effectiveSnapshot.quietStartMinutes, 20 * 60);
      expect(service.effectiveSnapshot.dailyBudget, 2);
      expect(service.effectiveSnapshot.revision, 3);
      expect(store.writtenRevisions, <int>[2, 3]);
    },
  );

  test('failed ordinary write is not published', () async {
    final store = _MemoryPreferenceStore();
    final service = await ProactivePreferenceService(
      store: store,
      accountScopeDigest: accountA,
      generation: 1,
    ).init();
    store.failWrites = true;

    await expectLater(service.setDailyBudget(1), throwsStateError);
    expect(service.effectiveSnapshot.dailyBudget, 1);
    expect(service.effectiveSnapshot.revision, 1);
  });

  test(
    'failed hard mute remains fail closed and later write persists it',
    () async {
      final store = _MemoryPreferenceStore();
      final service = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: accountA,
        generation: 1,
      ).init();
      store.failWrites = true;

      final mute = service.setHardMuted(true);
      expect(service.effectiveSnapshot.hardMuted, isTrue);
      await expectLater(mute, throwsStateError);
      expect(service.effectiveSnapshot.hardMuted, isTrue);

      store.failWrites = false;
      await service.setQuietHours(start: 21 * 60, end: 7 * 60);
      expect(service.effectiveSnapshot.hardMuted, isTrue);
      expect(store.rows.single['hardMuted'], isTrue);
    },
  );

  test(
    'overlapping unmute then mute never publishes an unmuted state',
    () async {
      final store = _SequencedPreferenceStore(
        row: const ProactivePreferenceSnapshot.defaults(
          generation: 1,
        ).copyWith(hardMuted: true).toStorageJson(),
      );
      final service = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: accountA,
        generation: 1,
      ).init();
      final emitted = <bool>[service.effectiveSnapshot.hardMuted];
      final subscription = service.state.listen(
        (snapshot) => emitted.add(snapshot.hardMuted),
      );
      addTearDown(subscription.cancel);

      final unmuteWrite = store.gateNextWrite();
      final unmute = service.setHardMuted(false);
      await unmuteWrite.started.future;
      final muteWrite = store.gateNextWrite();
      final mute = service.setHardMuted(true);

      expect(service.effectiveSnapshot.hardMuted, isTrue);
      unmuteWrite.release();
      await unmute;
      await muteWrite.started.future;
      expect(service.effectiveSnapshot.hardMuted, isTrue);
      expect(emitted, everyElement(isTrue));

      muteWrite.release();
      await mute;
      expect(store.row?['hardMuted'], isTrue);
      expect(store.writtenRevisions, <int>[2, 3]);
      expect(emitted, everyElement(isTrue));
    },
  );

  test(
    'mute publication admits its write before a listener re-enters to unmute',
    () async {
      final store = _MemoryPreferenceStore();
      final service = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: accountA,
        generation: 1,
      ).init();
      Future<void>? reentrantUnmute;
      final subscription = service.state.listen((snapshot) {
        if (snapshot.hardMuted && reentrantUnmute == null) {
          reentrantUnmute = service.setHardMuted(false);
        }
      });
      addTearDown(subscription.cancel);

      await service.setHardMuted(true);
      await reentrantUnmute;

      expect(store.writtenRevisions, <int>[2, 3]);
      expect(service.effectiveSnapshot.hardMuted, isFalse);
      expect(store.rows.single['hardMuted'], isFalse);
    },
  );

  test('failed trailing mute survives an earlier overlapping unmute', () async {
    final store = _SequencedPreferenceStore(
      row: const ProactivePreferenceSnapshot.defaults(
        generation: 1,
      ).copyWith(hardMuted: true).toStorageJson(),
    );
    final service = await ProactivePreferenceService(
      store: store,
      accountScopeDigest: accountA,
      generation: 1,
    ).init();
    final unmuteWrite = store.gateNextWrite();
    final unmute = service.setHardMuted(false);
    await unmuteWrite.started.future;
    final muteWrite = store.gateNextWrite(fail: true);
    final mute = service.setHardMuted(true);

    unmuteWrite.release();
    await unmute;
    await muteWrite.started.future;
    muteWrite.release();
    await expectLater(mute, throwsStateError);
    expect(service.effectiveSnapshot.hardMuted, isTrue);

    await service.setDailyBudget(2);
    expect(store.row?['hardMuted'], isTrue);
    expect(store.row?['dailyBudget'], 2);
  });

  test(
    'mute admitted during a stable snapshot linearizes after the boundary',
    () async {
      final store = _SequencedPreferenceStore(
        row: const ProactivePreferenceSnapshot.defaults(
          generation: 1,
        ).toStorageJson(),
      );
      final service = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: accountA,
        generation: 1,
      ).init();
      final entered = Completer<void>();
      final release = Completer<void>();
      final muteWrite = store.gateNextWrite();

      final stable = service.runWithStableSnapshot((snapshot) async {
        expect(snapshot.hardMuted, isFalse);
        final nested = await service.runWithStableSnapshot(
          (nestedSnapshot) async => nestedSnapshot,
        );
        expect(identical(nested, snapshot), isTrue);
        entered.complete();
        await release.future;
        expect(snapshot.hardMuted, isFalse);
      });
      await entered.future;
      final mute = service.setHardMuted(true);

      expect(service.effectiveSnapshot.hardMuted, isFalse);
      expect(muteWrite.started.isCompleted, isFalse);
      release.complete();
      await stable;
      await muteWrite.started.future;
      expect(service.effectiveSnapshot.hardMuted, isTrue);

      muteWrite.release();
      await mute;
      expect(store.row?['hardMuted'], isTrue);
    },
  );

  test(
    'retirement fences and drains a stable boundary plus admitted mutation',
    () async {
      final store = _SequencedPreferenceStore(
        row: const ProactivePreferenceSnapshot.defaults(
          generation: 1,
        ).toStorageJson(),
      );
      final service = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: accountA,
        generation: 1,
      ).init();
      final entered = Completer<void>();
      final releaseStable = Completer<void>();
      final stable = service.runWithStableSnapshot((_) async {
        entered.complete();
        await releaseStable.future;
      });
      await entered.future;
      final budgetWrite = store.gateNextWrite();
      final budget = service.setDailyBudget(2);
      var drained = false;
      final drain = service.deactivateAndDrain().whenComplete(
        () => drained = true,
      );

      expect(service.effectiveSnapshot.hardMuted, isTrue);
      expect(() => service.setDailyBudget(1), throwsStateError);
      expect(
        () => service.runWithStableSnapshot((_) async {}),
        throwsStateError,
      );
      expect(drained, isFalse);

      releaseStable.complete();
      await stable;
      await budgetWrite.started.future;
      expect(drained, isFalse);
      budgetWrite.release();
      await Future.wait<void>(<Future<void>>[budget, drain]);
      expect(drained, isTrue);
      expect(service.effectiveSnapshot.hardMuted, isTrue);
      expect(store.row?['dailyBudget'], 2);
    },
  );

  test('read failure degrades to mute and rejects setters', () async {
    final service = await ProactivePreferenceService(
      store: _MemoryPreferenceStore()..failReads = true,
      accountScopeDigest: accountA,
      generation: 1,
    ).init();

    expect(service.effectiveSnapshot.hardMuted, isTrue);
    expect(service.effectiveSnapshot.dailyBudget, 0);
    expect(() => service.setDailyBudget(2), throwsStateError);
  });

  test(
    'retirement fences stale references and drains accepted writes',
    () async {
      final store = _MemoryPreferenceStore();
      final service = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: accountA,
        generation: 1,
      ).init();
      final gate = Completer<void>();
      store.writeGate = gate.future;

      final accepted = service.setDailyBudget(2);
      final drain = service.deactivateAndDrain();
      expect(service.effectiveSnapshot.hardMuted, isTrue);
      expect(service.effectiveSnapshot.dailyBudget, 0);
      expect(() => service.setDailyBudget(1), throwsStateError);

      gate.complete();
      await Future.wait<void>(<Future<void>>[accepted, drain]);
      expect(service.effectiveSnapshot.hardMuted, isTrue);
      expect(store.rows.single['dailyBudget'], 2);
      expect(store.rows.single['hardMuted'], isFalse);

      final remounted = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: accountA,
        generation: 2,
      ).init();
      expect(remounted.effectiveSnapshot.hardMuted, isFalse);
      expect(remounted.effectiveSnapshot.dailyBudget, 2);
    },
  );

  test('retirement waits for an admitted initialization write', () async {
    final shared = await SharedPreferences.getInstance();
    await shared.setString(
      SharedPreferencesProactivePreferenceLegacyMigration.legacyStorageKey,
      jsonEncode({'quietStartMinutes': 21 * 60, 'dailyProactiveBudget': 2}),
    );
    final gate = Completer<void>();
    final store = _MemoryPreferenceStore()..writeGate = gate.future;
    final service = ProactivePreferenceService(
      store: store,
      accountScopeDigest: accountA,
      generation: 1,
      legacyMigration: SharedPreferencesProactivePreferenceLegacyMigration(
        shared,
      ),
    );

    final initialization = service.init();
    await store.writeStarted.future;
    var drainCompleted = false;
    final drain = service.deactivateAndDrain().whenComplete(
      () => drainCompleted = true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(drainCompleted, isFalse);
    expect(service.effectiveSnapshot.hardMuted, isTrue);
    gate.complete();
    await initialization;
    await drain;

    expect(drainCompleted, isTrue);
    expect(service.effectiveSnapshot.hardMuted, isTrue);
    expect(store.rows.single['hardMuted'], isFalse);
    expect(store.rows.single['quietStartMinutes'], 21 * 60);
    expect(() => service.setDailyBudget(1), throwsStateError);
  });

  test('Sembast persistence is isolated by account database', () async {
    const pathA = 'proactive-preferences-a.db';
    const pathB = 'proactive-preferences-b.db';
    final databaseA = await DBService().init(
      factory: databaseFactoryMemory,
      path: pathA,
    );
    final databaseB = await DBService().init(
      factory: databaseFactoryMemory,
      path: pathB,
    );
    addTearDown(() async {
      await databaseA.close();
      await databaseB.close();
      await databaseFactoryMemory.deleteDatabase(pathA);
      await databaseFactoryMemory.deleteDatabase(pathB);
    });

    final firstA = await ProactivePreferenceService(
      store: SembastProactivePreferenceStore(
        databaseA,
        accountScopeDigest: accountA,
      ),
      accountScopeDigest: accountA,
      generation: 1,
    ).init();
    await firstA.setHardMuted(true);
    await firstA.setDailyBudget(1);

    final restoredA = await ProactivePreferenceService(
      store: SembastProactivePreferenceStore(
        databaseA,
        accountScopeDigest: accountA,
      ),
      accountScopeDigest: accountA,
      generation: 2,
    ).init();
    final freshB = await ProactivePreferenceService(
      store: SembastProactivePreferenceStore(
        databaseB,
        accountScopeDigest: accountB,
      ),
      accountScopeDigest: accountB,
      generation: 3,
    ).init();

    expect(restoredA.effectiveSnapshot.hardMuted, isTrue);
    expect(restoredA.effectiveSnapshot.dailyBudget, 1);
    expect(freshB.effectiveSnapshot.hardMuted, isFalse);
    expect(freshB.effectiveSnapshot.dailyBudget, 1);
  });

  test('policy adapter reads the latest immutable snapshot', () async {
    final service = await ProactivePreferenceService(
      store: _MemoryPreferenceStore(),
      accountScopeDigest: accountA,
      generation: 1,
    ).init();
    final policy = ProactivePreferencePolicyAdapter(service);

    expect(policy.config.foregroundDailyLimit, 0);
    await service.setContactAgreement(
      enabled: true,
      scope: ProactiveConversationScope.everyday,
    );
    expect(policy.config.quietStartMinutes, 22 * 60);
    await service.setDailyBudget(1);
    expect(policy.config.foregroundDailyLimit, 1);
    await service.setHardMuted(true);
    expect(policy.config.foregroundDailyLimit, 0);
    await service.deactivateAndDrain();
    expect(policy.config.foregroundDailyLimit, 0);
  });

  test(
    'policy adapter revalidates hard mute and quiet before draft commit',
    () async {
      final service = await ProactivePreferenceService(
        store: _MemoryPreferenceStore(),
        accountScopeDigest: accountA,
        generation: 1,
      ).init();
      final policy = ProactivePreferencePolicyAdapter(service);
      await service.setContactAgreement(
        enabled: true,
        scope: ProactiveConversationScope.everyday,
      );
      const candidate = ProactiveTopicCandidate(
        kind: ProactiveTopicKind.quietPresence,
        topicKey: 'presence.quiet',
        sourceEventId: 'source-1',
      );

      final allowed = policy.evaluateDraft(
        now: DateTime(2026, 8, 28, 12),
        candidate: candidate,
        draft: '今天也一起慢慢来。',
      );
      expect(allowed.isAccepted, isTrue);

      await service.setQuietHours(start: 11 * 60, end: 13 * 60);
      final quiet = policy.evaluateDraft(
        now: DateTime(2026, 8, 28, 12),
        candidate: candidate,
        draft: '今天也一起慢慢来。',
      );
      expect(quiet.reason, ProactiveSilenceReason.quietHours);

      await service.setHardMuted(true);
      final muted = policy.evaluateDraft(
        now: DateTime(2026, 8, 28, 14),
        candidate: candidate,
        draft: '今天也一起慢慢来。',
      );
      expect(muted.reason, ProactiveSilenceReason.dailyBudgetExhausted);
    },
  );
}

final class _MemoryPreferenceStore implements ProactivePreferenceStore {
  _MemoryPreferenceStore({Map<String, Object?>? row})
    : rows = row == null
          ? <Map<String, Object?>>[]
          : <Map<String, Object?>>[Map<String, Object?>.from(row)];

  final List<Map<String, Object?>> rows;
  bool failReads = false;
  bool failWrites = false;
  Future<void>? readGate;
  Future<void>? writeGate;
  Completer<void>? _writeRelease;
  final Completer<void> writeStarted = Completer<void>();
  final List<int> writtenRevisions = <int>[];

  @override
  Future<Map<String, Object?>?> read() async {
    await readGate;
    if (failReads) throw StateError('injected_read_failure');
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  @override
  Future<void> write(ProactivePreferenceSnapshot snapshot) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    final gate = writeGate;
    if (gate != null) {
      _writeRelease ??= Completer<void>();
      await Future.any<void>(<Future<void>>[gate, _writeRelease!.future]);
    }
    if (failWrites) throw StateError('injected_write_failure');
    rows
      ..clear()
      ..add(snapshot.toStorageJson());
    writtenRevisions.add(snapshot.revision);
  }

  void releaseWrites() {
    _writeRelease?.complete();
    _writeRelease = null;
    writeGate = null;
  }
}

final class _SequencedPreferenceStore implements ProactivePreferenceStore {
  _SequencedPreferenceStore({required Map<String, Object?> row})
    : row = Map<String, Object?>.from(row);

  Map<String, Object?>? row;
  final List<_SequencedWrite> _writes = <_SequencedWrite>[];
  final List<int> writtenRevisions = <int>[];

  _SequencedWrite gateNextWrite({bool fail = false}) {
    final write = _SequencedWrite(fail: fail);
    _writes.add(write);
    return write;
  }

  @override
  Future<Map<String, Object?>?> read() async =>
      row == null ? null : Map<String, Object?>.from(row!);

  @override
  Future<void> write(ProactivePreferenceSnapshot snapshot) async {
    final write = _writes.isEmpty ? null : _writes.removeAt(0);
    write?.started.complete();
    if (write != null) await write._release.future;
    if (write?.fail == true) throw StateError('injected_write_failure');
    row = Map<String, Object?>.from(snapshot.toStorageJson());
    writtenRevisions.add(snapshot.revision);
  }
}

final class _SequencedWrite {
  _SequencedWrite({required this.fail});

  final bool fail;
  final Completer<void> started = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void release() => _release.complete();
}
