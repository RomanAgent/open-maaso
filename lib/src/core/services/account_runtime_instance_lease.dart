import 'dart:async';

import 'account_runtime_instance_lease_stub.dart'
    if (dart.library.io) 'account_runtime_instance_lease_io.dart'
    if (dart.library.js_interop) 'account_runtime_instance_lease_web.dart'
    as implementation;

/// Reports that another app process or browser tab already owns the one
/// account runtime allowed for this installation.
final class AccountRuntimeInstanceUnavailable implements Exception {
  const AccountRuntimeInstanceUnavailable([this.cause]);

  final Object? cause;

  @override
  String toString() => 'Another Maaso window is already running the account.';
}

/// Reports that the platform could not establish or release the instance
/// lease safely. Callers must fail closed instead of mounting without a gate.
final class AccountRuntimeInstanceLockFailure implements Exception {
  const AccountRuntimeInstanceLockFailure(this.cause);

  final Object cause;

  @override
  String toString() => 'The account runtime instance lock failed: $cause';
}

abstract interface class AccountRuntimeInstanceLease {
  /// Releases this installation's active-runtime ownership.
  ///
  /// Implementations must be idempotent and retry-safe.
  Future<void> release();
}

abstract interface class AccountRuntimeInstanceLeaseGate {
  /// Acquires the installation-local lease without waiting for another
  /// process or tab to finish.
  ///
  /// Throws [AccountRuntimeInstanceUnavailable] when another runtime owns it.
  Future<AccountRuntimeInstanceLease> acquire();
}

/// Process-local gate used by tests and platforms without a native primitive.
///
/// The owner and tail are static so independently constructed app graphs in
/// one isolate still contend for the same installation-local lease.
final class InProcessAccountRuntimeInstanceLeaseGate
    implements AccountRuntimeInstanceLeaseGate {
  static Future<void> _tail = Future<void>.value();
  static Object? _owner;

  @override
  Future<AccountRuntimeInstanceLease> acquire() {
    final completion = Completer<AccountRuntimeInstanceLease>();
    _tail = _tail.then((_) async {
      try {
        if (_owner != null) {
          throw const AccountRuntimeInstanceUnavailable();
        }
        final token = Object();
        _owner = token;
        completion.complete(_InProcessAccountRuntimeInstanceLease(token));
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }

  static Future<void> _release(Object token) {
    final completion = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        if (identical(_owner, token)) _owner = null;
        completion.complete();
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }
}

final class _InProcessAccountRuntimeInstanceLease
    implements AccountRuntimeInstanceLease {
  _InProcessAccountRuntimeInstanceLease(this._token);

  final Object _token;
  Future<void>? _inFlight;
  bool _released = false;

  @override
  Future<void> release() {
    if (_released) return Future<void>.value();
    return _inFlight ??= _releaseOnce();
  }

  Future<void> _releaseOnce() async {
    try {
      await InProcessAccountRuntimeInstanceLeaseGate._release(_token);
      _released = true;
    } finally {
      _inFlight = null;
    }
  }
}

AccountRuntimeInstanceLeaseGate
createDefaultAccountRuntimeInstanceLeaseGate() =>
    implementation.createPlatformAccountRuntimeInstanceLeaseGate();
