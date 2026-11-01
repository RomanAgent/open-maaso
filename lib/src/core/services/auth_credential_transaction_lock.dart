import 'dart:async';

import 'auth_credential_transaction_lock_stub.dart'
    if (dart.library.io) 'auth_credential_transaction_lock_io.dart'
    if (dart.library.js_interop) 'auth_credential_transaction_lock_web.dart'
    as implementation;

/// Serializes one complete credential/fence transaction across app instances.
///
/// Credential records and the durable logout fence live in different storage
/// backends. Callers must therefore hold this lock across both backends rather
/// than locking individual secure-storage keys.
abstract interface class AuthCredentialTransactionLock {
  Future<T> synchronized<T>(Future<T> Function() action);
}

/// Process-local implementation used by tests and unsupported Dart runtimes.
///
/// The tail is static so separate [AuthSessionService] instances in one test
/// isolate exercise the same serialization contract as tabs/processes do in
/// production.
final class InProcessAuthCredentialTransactionLock
    implements AuthCredentialTransactionLock {
  static Future<void> _tail = Future<void>.value();

  @override
  Future<T> synchronized<T>(Future<T> Function() action) {
    final completion = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completion.complete(await Future<T>.sync(action));
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }
}

AuthCredentialTransactionLock createDefaultAuthCredentialTransactionLock() =>
    implementation.createPlatformAuthCredentialTransactionLock();
