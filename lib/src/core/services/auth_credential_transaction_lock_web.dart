import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'auth_credential_transaction_lock.dart';

const String _credentialLockName = 'maaso.auth.credentials.v1';

AuthCredentialTransactionLock createPlatformAuthCredentialTransactionLock() =>
    WebAuthCredentialTransactionLock();

/// Cross-tab credential transaction lock backed by the Web Locks API.
///
/// The callback returns the action Promise itself. The browser therefore keeps
/// the exclusive lease until every secure-storage and logout-fence operation
/// in the Dart transaction has completed.
final class WebAuthCredentialTransactionLock
    implements AuthCredentialTransactionLock {
  @override
  Future<T> synchronized<T>(Future<T> Function() action) async {
    final actionSettled = Completer<void>();
    T? actionResult;
    Object? actionError;
    StackTrace? actionStackTrace;
    var callbackStarted = false;

    late final web.LockManager lockManager;
    try {
      lockManager = web.window.navigator.locks;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        StateError('Web Locks API is unavailable: $error'),
        stackTrace,
      );
    }

    final callback = ((web.Lock _) {
      callbackStarted = true;
      late final Future<T> operation;
      try {
        operation = Future<T>.sync(action);
      } catch (error, stackTrace) {
        operation = Future<T>.error(error, stackTrace);
      }
      unawaited(
        operation.then<void>(
          (value) {
            actionResult = value;
            if (!actionSettled.isCompleted) actionSettled.complete();
          },
          onError: (Object error, StackTrace stackTrace) {
            actionError = error;
            actionStackTrace = stackTrace;
            if (!actionSettled.isCompleted) actionSettled.complete();
          },
        ),
      );
      return operation.then<JSAny?>((_) => null).toJS;
    }).toJS;

    late final JSPromise<JSAny?> requested;
    try {
      requested = lockManager.request(
        _credentialLockName,
        web.LockOptions(mode: 'exclusive'),
        callback,
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        StateError('Web credential lock request failed: $error'),
        stackTrace,
      );
    }

    try {
      await requested.toDart;
    } catch (error, stackTrace) {
      if (callbackStarted) {
        await actionSettled.future;
        if (actionError != null) {
          Error.throwWithStackTrace(actionError!, actionStackTrace!);
        }
      }
      Error.throwWithStackTrace(
        StateError('Web credential lock request failed: $error'),
        stackTrace,
      );
    }
    if (!callbackStarted) {
      throw StateError('Web credential lock was not granted.');
    }
    await actionSettled.future;
    if (actionError != null) {
      Error.throwWithStackTrace(actionError!, actionStackTrace!);
    }
    return actionResult as T;
  }
}
