import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/foundation/app_services.dart';

final class _CapabilitySnapshotNotifier extends ChangeNotifier {
  void notifySnapshotChanged() => notifyListeners();
}

final class AppCapabilitySnapshotLease {
  const AppCapabilitySnapshotLease._({
    required this.snapshot,
    required this.authorityEpoch,
    required Object owner,
    required this.requiredKeys,
    required this.requireVisible,
    required Future<void> whenInvalidated,
  }) : _owner = owner,
       _whenInvalidated = whenInvalidated;

  final AppCapabilitySnapshot snapshot;
  final int authorityEpoch;
  final Set<AppCapabilityKey> requiredKeys;
  final bool requireVisible;
  final Object _owner;
  final Future<void> _whenInvalidated;

  int get generation => snapshot.generation;
  String get cacheKey => '$authorityEpoch:${snapshot.cacheKey}';
  Future<void> get whenInvalidated => _whenInvalidated;
}

final class AppCapabilityLeaseAcquisition {
  const AppCapabilityLeaseAcquisition._({
    required this.lease,
    required this.rejected,
  });

  final AppCapabilitySnapshotLease? lease;
  final Map<AppCapabilityKey, Set<String>> rejected;

  bool get isGranted => lease != null && rejected.isEmpty;
}

/// Permanent owner of the process-wide, immutable capability decision plane.
final class AppCapabilitySnapshotService extends AppService
    implements ValueListenable<AppCapabilitySnapshot> {
  AppCapabilitySnapshotService({
    required AppCapabilitySnapshotResolver resolver,
    required AppCapabilitySnapshotContext initialContext,
  }) : _resolver = resolver,
       _context = initialContext,
       _authorityEpoch = ++_nextAuthorityEpoch,
       _value = AppCapabilitySnapshot.materialize(
         generation: 0,
         draft: resolver.resolve(initialContext),
       );

  static int _nextAuthorityEpoch = 0;

  final AppCapabilitySnapshotResolver _resolver;
  final _CapabilitySnapshotNotifier _notifier = _CapabilitySnapshotNotifier();
  final Object _owner = Object();
  final int _authorityEpoch;
  AppCapabilitySnapshotContext _context;
  AppCapabilitySnapshot _value;
  Completer<void> _generationInvalidated = Completer<void>.sync();
  StreamSubscription<dynamic>? _rolloutSubscription;
  bool _closed = false;

  @override
  AppCapabilitySnapshot get value => _value;

  AppCapabilitySnapshotContext get context => _context;

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  AppCapabilitySnapshot refresh(AppCapabilitySnapshotContext nextContext) {
    _requireOpen();
    final draft = _resolver.resolve(nextContext);
    return _publish(draft);
  }

  AppCapabilitySnapshot activateAccount({
    required String accountScopeDigest,
    required int accountGeneration,
  }) => refresh(
    _context.copyWith(
      accountScopeDigest: accountScopeDigest,
      accountGeneration: accountGeneration,
    ),
  );

  bool deactivateAccount({required int accountGeneration}) {
    _requireOpen();
    if (_context.accountGeneration != accountGeneration) return false;
    refresh(_context.copyWith(clearAccount: true));
    return true;
  }

  void bindRollout<T>({
    required Stream<T> changes,
    required int Function() generation,
  }) {
    _requireOpen();
    unawaited(_rolloutSubscription?.cancel());
    refresh(_context.copyWith(rolloutGeneration: generation()));
    _rolloutSubscription = changes.listen((_) {
      if (_closed) return;
      refresh(_context.copyWith(rolloutGeneration: generation()));
    });
  }

  AppCapabilitySnapshotLease capture({
    Iterable<AppCapabilityKey> requiredKeys = const <AppCapabilityKey>[],
    bool requireVisible = false,
  }) {
    _requireOpen();
    return AppCapabilitySnapshotLease._(
      snapshot: _value,
      authorityEpoch: _authorityEpoch,
      owner: _owner,
      requiredKeys: Set<AppCapabilityKey>.unmodifiable(requiredKeys),
      requireVisible: requireVisible,
      whenInvalidated: _generationInvalidated.future,
    );
  }

  AppCapabilityLeaseAcquisition acquireLease(
    Iterable<AppCapabilityKey> requiredKeys, {
    bool requireVisible = false,
  }) {
    final keys = Set<AppCapabilityKey>.unmodifiable(requiredKeys);
    final lease = capture(requiredKeys: keys, requireVisible: requireVisible);
    final rejected = lease.snapshot.rejected(
      keys,
      requireVisible: requireVisible,
    );
    return AppCapabilityLeaseAcquisition._(
      lease: rejected.isEmpty ? lease : null,
      rejected: rejected,
    );
  }

  bool isCurrent(AppCapabilitySnapshotLease lease) {
    if (_closed || !identical(lease._owner, _owner)) return false;
    if (lease.authorityEpoch != _authorityEpoch ||
        lease.generation != _value.generation ||
        lease.snapshot.revision != _value.revision) {
      return false;
    }
    return lease.snapshot
        .rejected(lease.requiredKeys, requireVisible: lease.requireVisible)
        .isEmpty;
  }

  void requireCurrent(AppCapabilitySnapshotLease lease) {
    if (!isCurrent(lease)) {
      throw StateError('capability_snapshot_stale');
    }
  }

  AppCapabilitySnapshot _publish(AppCapabilitySnapshotDraft draft) {
    final candidate = AppCapabilitySnapshot.materialize(
      generation: _value.generation + 1,
      draft: draft,
    );
    if (candidate.revision == _value.revision) {
      _context = draft.context;
      return _value;
    }

    final previousInvalidation = _generationInvalidated;
    _generationInvalidated = Completer<void>.sync();
    _context = draft.context;
    _value = candidate;
    if (!previousInvalidation.isCompleted) previousInvalidation.complete();
    _notifier.notifySnapshotChanged();
    return _value;
  }

  void _requireOpen() {
    if (_closed) throw StateError('capability_snapshot_service_closed');
  }

  @override
  void onClose() {
    if (_closed) return;
    _closed = true;
    unawaited(_rolloutSubscription?.cancel());
    if (!_generationInvalidated.isCompleted) {
      _generationInvalidated.complete();
    }
    _notifier.dispose();
    super.onClose();
  }
}
