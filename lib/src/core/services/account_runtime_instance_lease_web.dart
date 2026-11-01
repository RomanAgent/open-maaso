import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'account_runtime_instance_lease.dart';

const String _runtimeInstanceLockName = 'maaso.account.runtime.instance.v1';

AccountRuntimeInstanceLeaseGate
createPlatformAccountRuntimeInstanceLeaseGate() =>
    WebAccountRuntimeInstanceLeaseGate();

/// Same-origin lifetime gate backed by the Web Locks API.
///
/// `ifAvailable` makes a second tab fail immediately. The callback returns the
/// lease's release Future as a Promise, so the browser holds the lock for the
/// complete mounted-account lifetime rather than only for acquisition.
final class WebAccountRuntimeInstanceLeaseGate
    implements AccountRuntimeInstanceLeaseGate {
  @override
  Future<AccountRuntimeInstanceLease> acquire() async {
    late final web.LockManager lockManager;
    try {
      lockManager = web.window.navigator.locks;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AccountRuntimeInstanceLockFailure(error),
        stackTrace,
      );
    }

    final acquired = Completer<AccountRuntimeInstanceLease>();
    final state = _WebAccountRuntimeInstanceRequestState();
    var callbackStarted = false;
    final callback = ((JSAny? lock) {
      callbackStarted = true;
      if (lock == null) {
        acquired.completeError(const AccountRuntimeInstanceUnavailable());
        return Future<JSAny?>.value(null).toJS;
      }
      final lease = _WebAccountRuntimeInstanceLease(state);
      acquired.complete(lease);
      // The request Promise cannot settle until this release Promise does.
      return state.releaseRequested.future.then<JSAny?>((_) => null).toJS;
    }).toJS;

    late final JSPromise<JSAny?> requested;
    try {
      requested = lockManager.request(
        _runtimeInstanceLockName,
        web.LockOptions(mode: 'exclusive', ifAvailable: true),
        callback,
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AccountRuntimeInstanceLockFailure(error),
        stackTrace,
      );
    }

    unawaited(
      requested.toDart.then<void>(
        (_) {
          state.completeRequest();
          if (!callbackStarted && !acquired.isCompleted) {
            acquired.completeError(const AccountRuntimeInstanceUnavailable());
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          state.completeRequest(error: error, stackTrace: stackTrace);
          if (!acquired.isCompleted) {
            acquired.completeError(
              AccountRuntimeInstanceLockFailure(error),
              stackTrace,
            );
          }
        },
      ),
    );
    return acquired.future;
  }
}

final class _WebAccountRuntimeInstanceRequestState {
  final releaseRequested = Completer<void>();
  final requestSettled = Completer<void>();
  Object? requestError;
  StackTrace? requestStackTrace;

  void completeRequest({Object? error, StackTrace? stackTrace}) {
    requestError = error;
    requestStackTrace = stackTrace;
    if (!requestSettled.isCompleted) requestSettled.complete();
  }
}

final class _WebAccountRuntimeInstanceLease
    implements AccountRuntimeInstanceLease {
  _WebAccountRuntimeInstanceLease(this._state);

  final _WebAccountRuntimeInstanceRequestState _state;
  Future<void>? _inFlight;
  bool _released = false;

  @override
  Future<void> release() {
    if (_released) return Future<void>.value();
    return _inFlight ??= _releaseOnce();
  }

  Future<void> _releaseOnce() async {
    try {
      if (!_state.releaseRequested.isCompleted) {
        _state.releaseRequested.complete();
      }
      await _state.requestSettled.future;
      final error = _state.requestError;
      if (error != null) {
        Error.throwWithStackTrace(
          AccountRuntimeInstanceLockFailure(error),
          _state.requestStackTrace!,
        );
      }
      _released = true;
    } finally {
      _inFlight = null;
    }
  }
}
