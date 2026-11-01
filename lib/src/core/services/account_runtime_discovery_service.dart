import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';

typedef AccountRuntimeDiscoveryTimerFactory =
    Timer Function(Duration delay, void Function() callback);

/// Maintains a proof-free, read-only view of active account runtimes.
///
/// Lifecycle events are treated only as reconciliation hints. The canonical
/// state exposed to callers always comes from [listActivePresences].
class AccountRuntimeDiscoveryService extends AppService implements Listenable {
  AccountRuntimeDiscoveryService({
    required AccountRuntimeDiscoveryGateway gateway,
    required AccountDeviceIdentity identity,
    AccountRuntimeDiscoveryTimerFactory? timerFactory,
    this.pollInterval = const Duration(seconds: 4),
    this.eventPageLimit = 50,
    this.maximumPagesPerPoll = 4,
    this.safetyReconcileEveryPolls = 15,
  }) : _gateway = gateway,
       _identity = _validatedIdentity(identity),
       _timerFactory = timerFactory ?? Timer.new {
    if (pollInterval <= Duration.zero) {
      throw ArgumentError.value(
        pollInterval,
        'pollInterval',
        'must be positive',
      );
    }
    if (eventPageLimit < 1 || eventPageLimit > 100) {
      throw ArgumentError.value(
        eventPageLimit,
        'eventPageLimit',
        'must be between 1 and 100',
      );
    }
    if (maximumPagesPerPoll < 1 || maximumPagesPerPoll > 20) {
      throw ArgumentError.value(
        maximumPagesPerPoll,
        'maximumPagesPerPoll',
        'must be between 1 and 20',
      );
    }
    if (safetyReconcileEveryPolls < 1 || safetyReconcileEveryPolls > 3600) {
      throw ArgumentError.value(
        safetyReconcileEveryPolls,
        'safetyReconcileEveryPolls',
        'must be between 1 and 3600',
      );
    }
  }

  final AccountRuntimeDiscoveryGateway _gateway;
  final AccountDeviceIdentity _identity;
  final AccountRuntimeDiscoveryTimerFactory _timerFactory;
  final _AccountRuntimeDiscoveryNotifier _changes =
      _AccountRuntimeDiscoveryNotifier();

  final Duration pollInterval;
  final int eventPageLimit;
  final int maximumPagesPerPoll;
  final int safetyReconcileEveryPolls;

  MaasoEnvironment? _environment;
  String? _accountUuid;
  AccountDevicePresenceListResult? _snapshot;
  Object? _lastError;
  Timer? _pollTimer;
  int? _eventSequence;
  int _successfulReplayPollsSinceSnapshot = 0;
  int _workerGeneration = 0;
  bool _observing = false;
  bool _changesDisposed = false;

  AccountDevicePresenceListResult? get snapshot => _snapshot;

  List<AccountDevicePresenceView> get presences =>
      _snapshot?.presences ?? const <AccountDevicePresenceView>[];

  AccountDevicePresenceView? get thisRuntimePresence {
    for (final presence in presences) {
      if (presence.installationId == _identity.installationId &&
          presence.runtimeInstanceId == _identity.runtimeInstanceId) {
        return presence;
      }
    }
    return null;
  }

  bool get isObserving => _observing;

  Object? get lastError => _lastError;

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  /// Starts observation without waiting for network I/O.
  void start({
    required MaasoEnvironment environment,
    required String accountUuid,
  }) {
    if (isClosed) {
      throw StateError('Runtime discovery service is closed');
    }
    if (!MaasoEnvironment.values.contains(environment)) {
      throw const FormatException('runtime discovery environment is invalid');
    }
    final normalizedAccountUuid = _validatedAccountUuid(accountUuid);
    if (_observing &&
        _environment == environment &&
        _accountUuid == normalizedAccountUuid) {
      return;
    }

    final workerGeneration = ++_workerGeneration;
    _pollTimer?.cancel();
    _pollTimer = null;
    _environment = environment;
    _accountUuid = normalizedAccountUuid;
    _snapshot = null;
    _eventSequence = null;
    _successfulReplayPollsSinceSnapshot = 0;
    _lastError = null;
    _observing = true;
    _emit();

    unawaited(
      _loadInitialSnapshot(
        environment: environment,
        accountUuid: normalizedAccountUuid,
        workerGeneration: workerGeneration,
      ),
    );
  }

  /// Stops observation synchronously and fences every outstanding response.
  void stop() => _stop(notify: true);

  Future<void> _loadInitialSnapshot({
    required MaasoEnvironment environment,
    required String accountUuid,
    required int workerGeneration,
  }) async {
    await _replaceWithCanonicalSnapshot(
      environment: environment,
      accountUuid: accountUuid,
      workerGeneration: workerGeneration,
    );
    _scheduleNextPoll(
      environment: environment,
      accountUuid: accountUuid,
      workerGeneration: workerGeneration,
    );
  }

  Future<void> _poll({
    required MaasoEnvironment environment,
    required String accountUuid,
    required int workerGeneration,
  }) async {
    if (!_isCurrent(environment, accountUuid, workerGeneration)) return;
    final initialSequence = _eventSequence;
    if (initialSequence == null) {
      await _replaceWithCanonicalSnapshot(
        environment: environment,
        accountUuid: accountUuid,
        workerGeneration: workerGeneration,
      );
      _scheduleNextPoll(
        environment: environment,
        accountUuid: accountUuid,
        workerGeneration: workerGeneration,
      );
      return;
    }

    var sawLifecycleHint = false;
    Object? replayFailure;
    var cursorExpired = false;
    var afterSequence = initialSequence;

    for (var pageIndex = 0; pageIndex < maximumPagesPerPoll; pageIndex++) {
      try {
        final page = await _gateway.replayRuntimeLifecycleEvents(
          environment: environment,
          accountUuid: accountUuid,
          afterSequence: afterSequence,
          limit: eventPageLimit,
        );
        if (!_isCurrent(environment, accountUuid, workerGeneration)) return;
        afterSequence = page.nextSequence;
        _eventSequence = page.nextSequence;
        sawLifecycleHint = sawLifecycleHint || page.events.isNotEmpty;
        if (!page.hasMore) break;
      } on AccountDeviceLeaseRequestException catch (error) {
        if (!_isCurrent(environment, accountUuid, workerGeneration)) return;
        if (error.isEventCursorExpired) {
          cursorExpired = true;
        } else {
          replayFailure = error;
        }
        break;
      } catch (error) {
        if (!_isCurrent(environment, accountUuid, workerGeneration)) return;
        replayFailure = error;
        break;
      }
    }

    if (cursorExpired || sawLifecycleHint) {
      // A failed canonical refresh must be retried as a snapshot read. Do not
      // advance from a hint whose resulting state was never reconciled.
      _eventSequence = null;
      await _replaceWithCanonicalSnapshot(
        environment: environment,
        accountUuid: accountUuid,
        workerGeneration: workerGeneration,
      );
    } else if (replayFailure == null) {
      _successfulReplayPollsSinceSnapshot++;
      if (_successfulReplayPollsSinceSnapshot >= safetyReconcileEveryPolls) {
        await _replaceWithCanonicalSnapshot(
          environment: environment,
          accountUuid: accountUuid,
          workerGeneration: workerGeneration,
        );
      } else {
        _clearLastError(environment, accountUuid, workerGeneration);
      }
    }

    if (replayFailure != null &&
        _isCurrent(environment, accountUuid, workerGeneration)) {
      _recordFailure(replayFailure);
    }

    _scheduleNextPoll(
      environment: environment,
      accountUuid: accountUuid,
      workerGeneration: workerGeneration,
    );
  }

  Future<bool> _replaceWithCanonicalSnapshot({
    required MaasoEnvironment environment,
    required String accountUuid,
    required int workerGeneration,
  }) async {
    try {
      final result = await _gateway.listActivePresences(
        environment: environment,
        accountUuid: accountUuid,
        limit: eventPageLimit,
      );
      if (!_isCurrent(environment, accountUuid, workerGeneration)) return false;
      _snapshot = AccountDevicePresenceListResult(
        presences: List<AccountDevicePresenceView>.unmodifiable(
          result.presences,
        ),
        snapshotAt: result.snapshotAt,
        eventSequence: result.eventSequence,
        truncated: result.truncated,
      );
      _eventSequence = result.eventSequence;
      _successfulReplayPollsSinceSnapshot = 0;
      _lastError = null;
      _emit();
      return true;
    } catch (error) {
      if (_isCurrent(environment, accountUuid, workerGeneration)) {
        _recordFailure(error);
      }
      return false;
    }
  }

  void _scheduleNextPoll({
    required MaasoEnvironment environment,
    required String accountUuid,
    required int workerGeneration,
  }) {
    if (!_isCurrent(environment, accountUuid, workerGeneration) ||
        _pollTimer != null) {
      return;
    }
    try {
      Timer? scheduledTimer;
      scheduledTimer = _timerFactory(pollInterval, () {
        if (!identical(_pollTimer, scheduledTimer)) return;
        _pollTimer = null;
        if (!_isCurrent(environment, accountUuid, workerGeneration)) return;
        unawaited(
          _poll(
            environment: environment,
            accountUuid: accountUuid,
            workerGeneration: workerGeneration,
          ),
        );
      });
      _pollTimer = scheduledTimer;
    } catch (error) {
      if (_isCurrent(environment, accountUuid, workerGeneration)) {
        _recordFailure(error);
      }
    }
  }

  bool _isCurrent(
    MaasoEnvironment environment,
    String accountUuid,
    int workerGeneration,
  ) =>
      !isClosed &&
      _observing &&
      workerGeneration == _workerGeneration &&
      _environment == environment &&
      _accountUuid == accountUuid;

  void _recordFailure(Object error) {
    _lastError = error;
    _emit();
  }

  void _clearLastError(
    MaasoEnvironment environment,
    String accountUuid,
    int workerGeneration,
  ) {
    if (!_isCurrent(environment, accountUuid, workerGeneration) ||
        _lastError == null) {
      return;
    }
    _lastError = null;
    _emit();
  }

  void _stop({required bool notify}) {
    final changed =
        _observing ||
        _environment != null ||
        _accountUuid != null ||
        _snapshot != null ||
        _lastError != null ||
        _eventSequence != null;
    _workerGeneration++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _environment = null;
    _accountUuid = null;
    _snapshot = null;
    _eventSequence = null;
    _successfulReplayPollsSinceSnapshot = 0;
    _lastError = null;
    _observing = false;
    if (changed && notify) _emit();
  }

  void _emit() {
    if (!_changesDisposed) _changes.emit();
  }

  @override
  void onClose() {
    _stop(notify: false);
    _changesDisposed = true;
    _changes.dispose();
    super.onClose();
  }

  static AccountDeviceIdentity _validatedIdentity(
    AccountDeviceIdentity identity,
  ) {
    _validatedIdentifier(identity.installationId, 'installationId');
    _validatedIdentifier(identity.runtimeInstanceId, 'runtimeInstanceId');
    return identity;
  }

  static String _validatedIdentifier(String value, String name) {
    if (value.isEmpty ||
        value != value.trim() ||
        value.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw FormatException('runtime discovery $name is invalid');
    }
    return value;
  }

  static String _validatedAccountUuid(String value) {
    if (value.isEmpty || value != value.trim() || value.length > 128) {
      throw const FormatException('runtime discovery account is invalid');
    }
    return value;
  }
}

class _AccountRuntimeDiscoveryNotifier extends ChangeNotifier {
  void emit() => notifyListeners();
}
