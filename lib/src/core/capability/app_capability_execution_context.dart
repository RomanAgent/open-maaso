import 'dart:async';

import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';

/// Zone-bound authority for one capability-admitted asynchronous operation.
///
/// Sinks use [current] only as a final commit fence. The context expires when
/// its handler returns, so detached work cannot inherit capability authority.
final class AppCapabilityExecutionContext {
  AppCapabilityExecutionContext._(this._service, this.lease);

  static final Object _zoneKey = Object();

  final AppCapabilitySnapshotService _service;
  final AppCapabilitySnapshotLease lease;
  final Completer<void> _closed = Completer<void>.sync();
  bool _active = true;

  static AppCapabilityExecutionContext? get current =>
      Zone.current[_zoneKey] as AppCapabilityExecutionContext?;

  bool get isCurrent {
    try {
      return _active && _service.isCurrent(lease);
    } catch (_) {
      return false;
    }
  }

  late final Future<void> whenInvalidated = Future.any<void>(<Future<void>>[
    lease.whenInvalidated,
    _closed.future,
  ]);

  static Future<T> run<T>({
    required AppCapabilitySnapshotService service,
    required AppCapabilitySnapshotLease lease,
    required Future<T> Function() operation,
  }) {
    final context = AppCapabilityExecutionContext._(service, lease);
    return runZoned<Future<T>>(() async {
      try {
        if (!context.isCurrent) {
          throw StateError('capability_snapshot_stale');
        }
        final result = await operation();
        if (!context.isCurrent) {
          throw StateError('capability_snapshot_stale');
        }
        return result;
      } finally {
        context._active = false;
        if (!context._closed.isCompleted) context._closed.complete();
      }
    }, zoneValues: <Object, Object>{_zoneKey: context});
  }
}
