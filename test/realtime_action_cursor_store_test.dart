import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/realtime_action_cursor_store.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test(
    'cursor commits monotonically for one exact session authority',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'realtime-cursor-monotonic.db',
      );
      addTearDown(database.close);
      final store = SembastRealtimeActionCursorStore(accountDatabase: database);
      final key = RealtimeActionCursorKey(
        sessionId: 'ms_session_1',
        leaseEpoch: 7,
        rtcGeneration: 3,
      );

      expect(await store.read(key), 0);
      await Future.wait<void>(<Future<void>>[
        store.commit(key, 12),
        store.commit(key, 4),
        store.commit(key, 9),
      ]);
      expect(await store.read(key), 12);

      expect(await store.claim(key, 13), isTrue);
      expect(await store.claim(key, 13), isFalse);
      expect(await store.claim(key, 8), isFalse);
      expect(await store.read(key), 13);

      await store.commit(key, 14);
      await store.commit(key, 2);
      expect(await store.read(key), 14);
    },
  );

  test(
    'cursor key isolates session, lease epoch, and RTC generation',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'realtime-cursor-identity.db',
      );
      addTearDown(database.close);
      final store = SembastRealtimeActionCursorStore(accountDatabase: database);
      final original = RealtimeActionCursorKey(
        sessionId: 'ms_session_1',
        leaseEpoch: 7,
        rtcGeneration: 3,
      );
      await store.commit(original, 42);

      expect(
        await store.read(
          RealtimeActionCursorKey(
            sessionId: 'ms_session_2',
            leaseEpoch: 7,
            rtcGeneration: 3,
          ),
        ),
        0,
      );
      expect(
        await store.read(
          RealtimeActionCursorKey(
            sessionId: 'ms_session_1',
            leaseEpoch: 8,
            rtcGeneration: 3,
          ),
        ),
        0,
      );
      expect(
        await store.read(
          RealtimeActionCursorKey(
            sessionId: 'ms_session_1',
            leaseEpoch: 7,
            rtcGeneration: 4,
          ),
        ),
        0,
      );
    },
  );

  test(
    'separate account database cannot observe another account cursor',
    () async {
      final firstDatabase = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'realtime-cursor-account-a.db',
      );
      final secondDatabase = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'realtime-cursor-account-b.db',
      );
      addTearDown(firstDatabase.close);
      addTearDown(secondDatabase.close);
      final first = SembastRealtimeActionCursorStore(
        accountDatabase: firstDatabase,
      );
      final second = SembastRealtimeActionCursorStore(
        accountDatabase: secondDatabase,
      );
      final key = RealtimeActionCursorKey(
        sessionId: 'ms_session_1',
        leaseEpoch: 7,
        rtcGeneration: 3,
      );

      await first.commit(key, 21);

      expect(await first.read(key), 21);
      expect(await second.read(key), 0);
    },
  );

  test('corrupt cursor fails closed', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'realtime-cursor-corrupt.db',
    );
    addTearDown(database.close);
    final key = RealtimeActionCursorKey(
      sessionId: 'ms_session_1',
      leaseEpoch: 7,
      rtcGeneration: 3,
    );
    final rawStore = StoreRef<String, Map<String, Object?>>(
      'realtime_action_cursors.v1',
    );
    await rawStore.record(key.storageKey).put(database.raw, <String, Object?>{
      'sessionId': key.sessionId,
      'leaseEpoch': key.leaseEpoch,
      'rtcGeneration': key.rtcGeneration,
      'sequence': -1,
    });
    final store = SembastRealtimeActionCursorStore(accountDatabase: database);

    await expectLater(store.read(key), throwsFormatException);
  });

  test('a durable claim is visible after store reconstruction', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'realtime-cursor-claim-reconstruction.db',
    );
    addTearDown(database.close);
    final key = RealtimeActionCursorKey(
      sessionId: 'ms_session_1',
      leaseEpoch: 7,
      rtcGeneration: 3,
    );
    final first = SembastRealtimeActionCursorStore(accountDatabase: database);

    expect(await first.claim(key, 21), isTrue);
    final reconstructed = SembastRealtimeActionCursorStore(
      accountDatabase: database,
    );

    expect(await reconstructed.read(key), 21);
    expect(await reconstructed.claim(key, 21), isFalse);
    expect(await reconstructed.claim(key, 20), isFalse);
  });
}
