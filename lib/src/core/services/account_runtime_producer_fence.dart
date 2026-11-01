import 'dart:async';

typedef AccountRuntimeProducerDrainStarter = Future<void> Function();

/// Holds the synchronous admission fence for the account graph currently
/// being mounted. Lifecycle watchdogs can start this drain before the runtime
/// builder has returned its disposal lease.
final class AccountRuntimeProducerFenceController {
  AccountRuntimeProducerFenceHandle? _active;

  bool get hasActiveMount => _active != null;

  AccountRuntimeProducerFenceHandle install(
    AccountRuntimeProducerDrainStarter startDrain,
  ) {
    if (_active != null) {
      throw StateError('An account producer fence is already installed.');
    }
    final handle = AccountRuntimeProducerFenceHandle._(this, startDrain);
    _active = handle;
    return handle;
  }

  Future<void> fenceAndDrain() =>
      _active?.fenceAndDrain() ?? Future<void>.value();

  void _release(AccountRuntimeProducerFenceHandle handle) {
    if (!identical(_active, handle)) {
      throw StateError('A stale account producer fence cannot be released.');
    }
    _active = null;
  }
}

final class AccountRuntimeProducerFenceHandle {
  AccountRuntimeProducerFenceHandle._(this._owner, this._startDrain);

  final AccountRuntimeProducerFenceController _owner;
  final AccountRuntimeProducerDrainStarter _startDrain;
  Future<void>? _inFlight;
  bool _drained = false;
  bool _completed = false;

  bool get isDrained => _drained;

  Future<void> fenceAndDrain() {
    if (_completed || _drained) return Future<void>.value();
    return _inFlight ??= _drainOnce();
  }

  Future<void> _drainOnce() async {
    try {
      await Future<void>.sync(_startDrain);
      _drained = true;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> complete() async {
    if (_completed) return;
    await fenceAndDrain();
    _completed = true;
    _owner._release(this);
  }
}
