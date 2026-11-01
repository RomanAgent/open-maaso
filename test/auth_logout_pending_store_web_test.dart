@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/auth_logout_pending_store_web.dart';
import 'package:web/web.dart' as web;

const String _databaseName = 'maaso_auth_logout_fence_v1';
const String _storeName = 'fences';
const _ownerFingerprint =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  test(
    'strict web transaction persists mark and CAS clear across reopen',
    () async {
      final environmentKey = _uniqueEnvironment('roundtrip');
      final first = IndexedDbAuthLogoutPendingStore();
      final missing = await first.read(environmentKey);
      expect(missing.pending, isTrue);

      final baseline = await first.clearPending(
        environmentKey,
        expected: missing,
      );
      expect(baseline?.pending, isFalse);

      final reopened = IndexedDbAuthLogoutPendingStore();
      expect(
        (await reopened.read(environmentKey)).sameVersion(baseline!),
        isTrue,
      );

      final pending = await first.markPending(
        environmentKey,
        ownerFingerprint: _ownerFingerprint,
      );
      expect(
        (await reopened.read(environmentKey)).sameVersion(pending),
        isTrue,
      );
      expect(
        await reopened.clearPending(environmentKey, expected: baseline),
        isNull,
      );

      final cleared = await reopened.clearPending(
        environmentKey,
        expected: pending,
      );
      expect(cleared?.pending, isFalse);
      expect((await first.read(environmentKey)).sameVersion(cleared!), isTrue);
    },
  );

  test(
    'corrupt IndexedDB value fails closed and can be repaired by CAS',
    () async {
      final environmentKey = _uniqueEnvironment('corrupt');
      final store = IndexedDbAuthLogoutPendingStore();
      final missing = await store.read(environmentKey);
      final baseline = await store.clearPending(
        environmentKey,
        expected: missing,
      );
      expect(baseline?.pending, isFalse);

      final database = await _openFenceDatabase();
      addTearDown(() => database.close());
      await _putRaw(database, environmentKey, '{"truncated":');

      final corrupt = await store.read(environmentKey);
      expect(corrupt.pending, isTrue);
      final repaired = await store.clearPending(
        environmentKey,
        expected: corrupt,
      );
      expect(repaired?.pending, isFalse);
    },
  );

  test(
    'transaction abort reports once and never commits the pending value',
    () async {
      final environmentKey = _uniqueEnvironment('abort');
      final normal = IndexedDbAuthLogoutPendingStore();
      final missing = await normal.read(environmentKey);
      final baseline = await normal.clearPending(
        environmentKey,
        expected: missing,
      );
      final zoneErrors = <Object>[];
      final aborting = IndexedDbAuthLogoutPendingStore(
        abortMutationAfterWriteForTesting: () => true,
      );

      await runZonedGuarded<Future<void>>(() async {
        await expectLater(
          aborting.markPending(
            environmentKey,
            ownerFingerprint: _ownerFingerprint,
          ),
          throwsA(anything),
        );
        await Future<void>.delayed(Duration.zero);
      }, (error, _) => zoneErrors.add(error));

      expect(zoneErrors, isEmpty);
      expect(
        (await normal.read(environmentKey)).sameVersion(baseline!),
        isTrue,
      );
    },
  );

  test('failed database open is not cached and a retry can succeed', () async {
    final environmentKey = _uniqueEnvironment('open-retry');
    var attempts = 0;
    final databases = <web.IDBDatabase>[];
    addTearDown(() {
      for (final database in databases) {
        database.close();
      }
    });
    final store = IndexedDbAuthLogoutPendingStore(
      openDatabaseForTesting: () async {
        attempts++;
        if (attempts == 1) throw StateError('open failed once');
        final database = await _openFenceDatabase();
        databases.add(database);
        return database;
      },
    );

    await expectLater(store.read(environmentKey), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect((await store.read(environmentKey)).pending, isTrue);
    expect(attempts, 2);
  });
}

String _uniqueEnvironment(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}';

Future<web.IDBDatabase> _openFenceDatabase() {
  final completer = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(_databaseName, 1);
  request.onupgradeneeded = ((web.Event _) {
    final database = request.result as web.IDBDatabase;
    if (!database.objectStoreNames.contains(_storeName)) {
      database.createObjectStore(_storeName);
    }
  }).toJS;
  request.onsuccess = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.complete(request.result as web.IDBDatabase);
    }
  }).toJS;
  request.onerror = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        request.error ?? StateError('IndexedDB test open failed.'),
      );
    }
  }).toJS;
  request.onblocked = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('IndexedDB test open blocked.'));
    }
  }).toJS;
  return completer.future;
}

Future<void> _putRaw(
  web.IDBDatabase database,
  String environmentKey,
  String value,
) {
  final completer = Completer<void>();
  final transaction = database.transaction(
    _storeName.toJS,
    'readwrite',
    web.IDBTransactionOptions(durability: 'strict'),
  );
  transaction.oncomplete = ((web.Event _) {
    if (!completer.isCompleted) completer.complete();
  }).toJS;
  transaction.onabort = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        transaction.error ?? StateError('IndexedDB test transaction aborted.'),
      );
    }
  }).toJS;
  transaction.onerror = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        transaction.error ?? StateError('IndexedDB test transaction failed.'),
      );
    }
  }).toJS;
  transaction.objectStore(_storeName).put(value.toJS, environmentKey.toJS);
  return completer.future;
}
