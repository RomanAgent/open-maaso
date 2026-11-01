import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'auth_logout_pending_store.dart';
import 'auth_logout_pending_store_codec.dart';

const String _databaseName = 'maaso_auth_logout_fence_v1';
const String _storeName = 'fences';

AuthLogoutPendingStore createPlatformAuthLogoutPendingStore() =>
    IndexedDbAuthLogoutPendingStore();

/// IndexedDB logout fencing with strict transaction durability and token CAS.
final class IndexedDbAuthLogoutPendingStore implements AuthLogoutPendingStore {
  IndexedDbAuthLogoutPendingStore({
    Future<web.IDBDatabase> Function()? openDatabaseForTesting,
    bool Function()? abortMutationAfterWriteForTesting,
  }) : _openDatabaseForTesting = openDatabaseForTesting,
       _abortMutationAfterWriteForTesting = abortMutationAfterWriteForTesting;

  final Future<web.IDBDatabase> Function()? _openDatabaseForTesting;
  final bool Function()? _abortMutationAfterWriteForTesting;
  Future<web.IDBDatabase>? _database;

  @override
  Future<AuthLogoutPendingSnapshot> read(String environmentKey) async {
    final database = await _open();
    final transaction = database.transaction(_storeName.toJS, 'readonly');
    final completion = _transactionCompletion(transaction);
    final request = transaction
        .objectStore(_storeName)
        .get(environmentKey.toJS);
    final encoded = await _requestString(request, completion: completion);
    await completion;
    return authLogoutPendingSnapshotFromSingleRecord(
      environmentKey: environmentKey,
      encoded: encoded,
    );
  }

  @override
  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  }) async {
    final result = await _mutate(environmentKey, (current) {
      return AuthLogoutPendingRecord(
        environmentKey: environmentKey,
        revision: current.revision + 1,
        pending: true,
        token: newAuthLogoutPendingToken(),
        ownerFingerprint: ownerFingerprint,
      );
    });
    if (result == null || !result.pending) {
      throw StateError('Logout-pending web fence did not commit.');
    }
    return result;
  }

  @override
  Future<AuthLogoutPendingSnapshot?> clearPending(
    String environmentKey, {
    required AuthLogoutPendingSnapshot expected,
  }) {
    return _mutate(environmentKey, (current) {
      if (!current.sameVersion(expected)) return null;
      return AuthLogoutPendingRecord(
        environmentKey: environmentKey,
        revision: current.revision + 1,
        pending: false,
        token: newAuthLogoutPendingToken(),
      );
    });
  }

  Future<AuthLogoutPendingSnapshot?> _mutate(
    String environmentKey,
    AuthLogoutPendingRecord? Function(AuthLogoutPendingSnapshot current)
    mutation,
  ) async {
    final database = await _open();
    final transaction = database.transaction(
      _storeName.toJS,
      'readwrite',
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final completion = _transactionCompletion(transaction);
    final request = transaction
        .objectStore(_storeName)
        .get(environmentKey.toJS);
    final result = Completer<AuthLogoutPendingRecord?>();
    unawaited(
      completion.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    request.onsuccess = ((web.Event _) {
      try {
        final raw = request.result;
        final encoded = raw != null && raw.isA<JSString>()
            ? (raw as JSString).toDart
            : null;
        final current = authLogoutPendingSnapshotFromSingleRecord(
          environmentKey: environmentKey,
          encoded: encoded,
        );
        final next = mutation(current);
        if (next != null) {
          transaction
              .objectStore(_storeName)
              .put(next.encode().toJS, environmentKey.toJS);
          if (_abortMutationAfterWriteForTesting?.call() ?? false) {
            transaction.abort();
          }
        }
        result.complete(next);
      } catch (error, stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
        transaction.abort();
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!result.isCompleted) {
        result.completeError(_requestError(request));
      }
    }).toJS;

    final outcomes = await Future.wait<Object?>(<Future<Object?>>[
      result.future,
      completion.then<Object?>((_) => null),
    ], eagerError: false);
    final record = outcomes.first as AuthLogoutPendingRecord?;
    return record?.snapshot;
  }

  Future<web.IDBDatabase> _open() {
    final existing = _database;
    if (existing != null) return existing;
    final opening = _openOnce();
    _database = opening;
    unawaited(
      opening.then<void>(
        (database) {
          database.onversionchange = ((web.Event _) {
            database.close();
            if (identical(_database, opening)) _database = null;
          }).toJS;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_database, opening)) _database = null;
        },
      ),
    );
    return opening;
  }

  Future<web.IDBDatabase> _openOnce() {
    final override = _openDatabaseForTesting;
    if (override != null) return override();
    return _openBrowserDatabase();
  }

  Future<web.IDBDatabase> _openBrowserDatabase() {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_databaseName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      if (!database.objectStoreNames.contains(_storeName)) {
        database.createObjectStore(_storeName);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      if (!completer.isCompleted) {
        completer.complete(database);
      } else {
        database.close();
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(_requestError(request));
      }
    }).toJS;
    request.onblocked = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Logout-fence IndexedDB open was blocked.'),
        );
      }
    }).toJS;
    return completer.future;
  }

  Future<String?> _requestString(
    web.IDBRequest request, {
    required Future<void> completion,
  }) {
    final completer = Completer<String?>();
    unawaited(
      completion.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      ),
    );
    request.onsuccess = ((web.Event _) {
      final raw = request.result;
      if (!completer.isCompleted) {
        completer.complete(
          raw != null && raw.isA<JSString>() ? (raw as JSString).toDart : null,
        );
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(_requestError(request));
      }
    }).toJS;
    return completer.future;
  }

  Future<void> _transactionCompletion(web.IDBTransaction transaction) {
    final completer = Completer<void>();
    transaction.oncomplete = ((web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }).toJS;
    transaction.onabort = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(_transactionError(transaction));
      }
    }).toJS;
    transaction.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(_transactionError(transaction));
      }
    }).toJS;
    return completer.future;
  }

  Object _requestError(web.IDBRequest request) =>
      request.error ?? StateError('Logout-fence IndexedDB request failed.');

  Object _transactionError(web.IDBTransaction transaction) =>
      transaction.error ??
      StateError('Logout-fence IndexedDB transaction failed.');
}
