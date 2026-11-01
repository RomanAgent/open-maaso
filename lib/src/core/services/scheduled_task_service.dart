import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show Listenable, TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/app_foreground_service.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScheduledTaskService extends AppService {
  ScheduledTaskService({
    NotificationDelivery? delivery,
    NotificationPreferencesService? notificationPreferences,
    SharedPreferences? sharedPreferences,
    AppReactiveValue<MaasoAuthSession?>? session,
    AppReactiveValue<MaasoEnvironment>? environmentSignal,
    AuthSessionService? auth,
    AppEnvironmentService? environment,
    DateTime Function()? clock,
    bool Function()? isForeground,
    bool Function()? executionAllowed,
    Duration deliveryTimeout = const Duration(seconds: 5),
    Duration persistenceTimeout = const Duration(seconds: 3),
    Future<bool> Function(String key, String value)? preferenceWriter,
  }) : _injectedDelivery = delivery,
       _injectedNotificationPreferences = notificationPreferences,
       _prefs = sharedPreferences,
       _session =
           session ??
           auth?.session ??
           appServices.maybeFind<AuthSessionService>()?.session,
       _environmentSignal =
           environmentSignal ??
           environment?.environment ??
           appServices.maybeFind<AppEnvironmentService>()?.environment,
       _clock = clock ?? DateTime.now,
       _injectedIsForeground = isForeground,
       _executionAllowedCallback = executionAllowed,
       _deliveryTimeout = deliveryTimeout,
       _persistenceTimeout = persistenceTimeout,
       _injectedPreferenceWriter = preferenceWriter;

  static const _storagePrefix = 'scheduled_tasks.v4';
  static const _legacyStoragePrefix = 'scheduled_tasks.v3';
  static const _pendingCancellationStorageKey =
      'scheduled_tasks.pending_cancellations.v1';
  static const _corruptJournalSalvageStorageKey =
      'scheduled_tasks.corrupt_journal_salvage.v1';
  static const _legacyQuarantineFaultStorageKey =
      'scheduled_tasks.legacy_quarantine_fault.v1';
  static const _legacyScrubbedMarker = 'maaso_scheduled_task_v3_scrubbed';
  static const _v4ScrubbedMarker = 'maaso_scheduled_task_v4_scrubbed';

  /// Exposed for diagnostics and deterministic fixtures. Production callers
  /// should use [list] rather than reading SharedPreferences directly.
  static String storageKeyForScope({
    required String environmentKey,
    required String accountUuid,
  }) => _TaskScope(
    environmentKey: environmentKey,
    accountUuid: accountUuid,
  ).storageKey;

  final NotificationDelivery? _injectedDelivery;
  final NotificationPreferencesService? _injectedNotificationPreferences;
  final AppReactiveValue<MaasoAuthSession?>? _session;
  final AppReactiveValue<MaasoEnvironment>? _environmentSignal;
  final DateTime Function() _clock;
  final bool Function()? _injectedIsForeground;
  final Duration _deliveryTimeout;
  final Duration _persistenceTimeout;
  final Future<bool> Function(String key, String value)?
  _injectedPreferenceWriter;

  final Map<String, _ScheduledTask> _tasks = <String, _ScheduledTask>{};
  final Set<String> _pendingCancellationIds = <String>{};
  final Set<String> _scopedCleanupCancellationIds = <String>{};
  final Set<String> _corruptJournalSalvageIds = <String>{};
  final Set<String> _pendingScheduleCompletionIds = <String>{};
  final Set<Future<void>> _lateScheduleCompensations = <Future<void>>{};
  final Set<String> _unresolvedLegacyQuarantineTokens = <String>{};
  SharedPreferences? _prefs;
  Worker? _notificationPreferencesWorker;
  Worker? _sessionWorker;
  Worker? _environmentWorker;
  Future<void> _operationTail = Future<void>.value();
  Future<void>? _accountDrain;
  _TaskScope? _activeScope;
  _TaskScope? _deactivatedScope;
  _TaskScope? _globalQuarantineScope;
  bool _awaitingSessionForEnvironment = false;
  bool _globalLegacyQuarantineComplete = false;
  bool _legacyQuarantineFaultsRestored = false;
  bool _pendingCancellationJournalRestored = false;
  bool _closed = false;
  int _nextId = 1;
  bool Function()? _executionAllowedCallback;
  Listenable? _executionChanges;
  bool? _lastExecutionAllowed;
  int _executionGeneration = 0;

  /// Binds runtime ownership independently of the signed-in app's task list.
  /// The app can browse/cancel saved tasks while its Agent lives elsewhere.
  Future<void> bindExecutionAuthority({
    required bool Function() allowed,
    required Listenable changes,
  }) {
    if (_closed) {
      return Future<void>.error(StateError('scheduled_task_service_closed'));
    }
    _executionChanges?.removeListener(_executionAuthorityChanged);
    _executionAllowedCallback = allowed;
    _executionChanges = changes;
    _lastExecutionAllowed = null;
    changes.addListener(_executionAuthorityChanged);
    _captureExecutionAuthority();
    return _reconcileExecutionAuthority();
  }

  bool get _executionAllowed {
    if (_closed) return false;
    try {
      return (_executionAllowedCallback?.call() ?? true) &&
          (_deactivatedScope == null || _deactivatedScope != _signalScope);
    } catch (_) {
      return false;
    }
  }

  bool _captureExecutionAuthority() {
    bool allowed;
    try {
      allowed = _executionAllowedCallback?.call() ?? true;
    } catch (_) {
      allowed = false;
    }
    if (_closed || allowed == _lastExecutionAllowed) return false;
    _lastExecutionAllowed = allowed;
    _executionGeneration++;
    if (allowed && _deactivatedScope == _signalScope) {
      _deactivatedScope = null;
    }
    for (final task in _tasks.values) {
      task.timer?.cancel();
      task.timer = null;
    }
    return true;
  }

  void _executionAuthorityChanged() {
    if (!_captureExecutionAuthority()) return;
    unawaited(
      _reconcileExecutionAuthority().catchError((Object error) {
        Log.w(
          '[ScheduledTask] execution authority cleanup deferred: ${error.runtimeType}',
        );
      }),
    );
  }

  Future<void> _reconcileExecutionAuthority() => _runSerialized(() async {
    final failure = await _ensureActiveScopeLocked();
    if (failure != null) return;
    for (final task in _tasks.values) {
      _armTimer(task);
    }
    await _syncSystemSchedulesLocked();
  });

  NotificationDelivery? get _delivery =>
      _injectedDelivery ?? appServices.maybeFind<NotificationDelivery>();

  NotificationPreferencesService? get _notificationPreferences =>
      _injectedNotificationPreferences ??
      appServices.maybeFind<NotificationPreferencesService>();

  Future<ScheduledTaskService> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _runSerialized(() async {
      final quarantineFailure = await _ensureGlobalLegacyQuarantineLocked();
      if (quarantineFailure != null) {
        Log.w(
          '[ScheduledTask] global legacy quarantine deferred: '
          '${quarantineFailure.cause ?? quarantineFailure.code}',
        );
        return;
      }
      final failure = await _ensureActiveScopeLocked();
      if (failure == null) await _syncSystemSchedulesLocked();
    });
    _sessionWorker = _session?.listen((_) {
      _awaitingSessionForEnvironment = false;
      _handleScopeSignalChanged();
      unawaited(_refreshScope());
    });
    _environmentWorker = _environmentSignal?.listen((_) {
      // AppEnvironmentService publishes before AuthSessionService has loaded
      // the session for that environment. Drop to no scope until the matching
      // session signal arrives so an old account is never attributed to it.
      _awaitingSessionForEnvironment = true;
      _handleScopeSignalChanged();
      unawaited(_refreshScope());
    });
    _notificationPreferencesWorker = _notificationPreferences?.state.listen(
      (_) => unawaited(_refreshSystemSchedules()),
    );
    return this;
  }

  /// Clears any detached scheduled-delivery authority before an account graph
  /// is constructed. This does not publish the target scope or arm timers.
  Future<void> prepareAccountScope({
    required String environmentKey,
    required String accountUuid,
  }) => _runSerialized(() async {
    final target = _TaskScope(
      environmentKey: environmentKey.trim(),
      accountUuid: accountUuid.trim(),
    );
    final failure = await _ensureGlobalLegacyQuarantineLocked(
      targetScope: target,
    );
    if (failure != null) {
      throw ScheduledTaskAccountScopePreparationFailure(
        code: failure.code,
        cause: failure.cause,
      );
    }
  });

  Future<Map<String, Object?>> schedule({
    required String when,
    required String prompt,
    String repeat = 'once',
    bool Function()? commitFenceIsCurrent,
  }) => _runSerialized(
    () => _scheduleLocked(
      when,
      prompt,
      repeat,
      commitFenceIsCurrent: commitFenceIsCurrent,
    ),
  );

  Future<Map<String, Object?>> list() => _runSerialized(() async {
    final failure = await _ensureActiveScopeLocked();
    if (failure != null) return failure.toJson();
    final scope = _activeScope!;
    if (!_signalsMatch(scope)) {
      return const _TaskFailure('scope_changed').toJson();
    }
    return <String, Object?>{
      'tasks': _tasks.values.map((task) => task.toJson()).toList(),
    };
  });

  Future<Map<String, Object?>> cancel(
    String taskId, {
    bool Function()? commitFenceIsCurrent,
  }) => _runSerialized(
    () => _cancelLocked(
      taskId.trim(),
      commitFenceIsCurrent: commitFenceIsCurrent,
    ),
  );

  /// Fences the currently published account, removes its timers and OS
  /// schedules, and waits for any timed-out platform schedule to finish and
  /// be compensated before returning.
  ///
  /// Concurrent callers share one drain. A failed cleanup remains journaled;
  /// a later call retries only the cleanup that is still pending.
  Future<void> deactivateAccountAndDrain() {
    final inFlight = _accountDrain;
    if (inFlight != null) return inFlight;

    final scope = _activeScope ?? _signalScope;
    if (scope != null) _deactivatedScope = scope;

    late final Future<void> tracked;
    tracked = _deactivateAccountAndDrainOnce().whenComplete(() {
      if (identical(_accountDrain, tracked)) _accountDrain = null;
    });
    _accountDrain = tracked;
    return tracked;
  }

  Future<void> _deactivateAccountAndDrainOnce() async {
    while (true) {
      final failure = await _runSerialized(() => _switchScopeLocked(null));
      final waitingForLateSchedule =
          failure?.code == 'scope_cleanup_failed' &&
          failure?.cause == 'delivery_schedule_pending';
      if (failure != null && !waitingForLateSchedule) {
        throw ScheduledTaskAccountDrainFailure(
          code: failure.code,
          cause: failure.cause,
        );
      }

      final late = _lateScheduleCompensations.toList(growable: false);
      if (late.isEmpty) {
        if (failure != null) {
          throw ScheduledTaskAccountDrainFailure(
            code: failure.code,
            cause: failure.cause,
          );
        }
        return;
      }
      await Future.wait<void>(late, eagerError: false);
    }
  }

  void _handleScopeSignalChanged() {
    final scope = _signalScope;
    if (_deactivatedScope != null && scope != _deactivatedScope) {
      _deactivatedScope = null;
    }
  }

  Future<Map<String, Object?>> _scheduleLocked(
    String when,
    String prompt,
    String repeat, {
    bool Function()? commitFenceIsCurrent,
  }) async {
    final parsed = _parseWhen(when);
    if (parsed == null) {
      return const _TaskFailure('invalid_when').toJson();
    }
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty) {
      return const _TaskFailure('missing_prompt').toJson();
    }
    final normalizedRepeat = repeat.trim().isEmpty ? 'once' : repeat.trim();
    if (normalizedRepeat != 'once' && normalizedRepeat != 'daily') {
      return const _TaskFailure('invalid_repeat').toJson();
    }

    final scopeFailure = await _ensureActiveScopeLocked();
    if (scopeFailure != null) return scopeFailure.toJson();
    final scope = _activeScope!;

    bool capabilityFenceIsCurrent() {
      try {
        return commitFenceIsCurrent?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    _TaskFailure? currentFenceFailure() {
      if (!_signalsMatch(scope)) return const _TaskFailure('scope_changed');
      if (!capabilityFenceIsCurrent()) {
        return const _TaskFailure('capability_unavailable');
      }
      return null;
    }

    final initialFenceFailure = currentFenceFailure();
    if (initialFenceFailure != null) {
      return initialFenceFailure.toJson();
    }

    final now = _clock().toLocal();
    final targetAt = _nextOccurrence(
      now: now,
      hour: parsed.$1,
      minute: parsed.$2,
    );
    final task = _ScheduledTask(
      scope: scope,
      id: 't${_nextId++}',
      hour: parsed.$1,
      minute: parsed.$2,
      prompt: normalizedPrompt,
      repeat: normalizedRepeat,
      targetAt: targetAt,
      timezoneName: now.timeZoneName,
      timezoneOffsetMinutes: now.timeZoneOffset.inMinutes,
    );

    if (_systemDeliveryEnabled) {
      final journalFailure = await _journalCancellationLocked(task.deliveryId);
      if (journalFailure != null) return journalFailure.toJson();
      final postJournalFenceFailure = currentFenceFailure();
      if (postJournalFenceFailure != null) {
        final rollbackFailure = await _clearCancellationJournalLocked(
          task.deliveryId,
        );
        return postJournalFenceFailure
            .withRollback(rollbackFailure == null ? 'completed' : 'pending')
            .toJson();
      }
      final deliveryFailure = await _scheduleSystem(task);
      if (deliveryFailure != null) {
        final awaitsLateScheduleCompletion =
            deliveryFailure.code == 'delivery_timeout';
        final rollbackFailure = await _compensateScheduledDelivery(
          task.deliveryId,
          clearJournalOnSuccess: !awaitsLateScheduleCompletion,
        );
        return deliveryFailure
            .withRollback(
              awaitsLateScheduleCompletion || rollbackFailure != null
                  ? 'pending'
                  : 'completed',
            )
            .toJson();
      }
      task.systemScheduled = true;
    }

    final postDeliveryFenceFailure = currentFenceFailure();
    if (postDeliveryFenceFailure != null) {
      if (task.systemScheduled) {
        final rollbackFailure = await _compensateScheduledDelivery(
          task.deliveryId,
        );
        return postDeliveryFenceFailure
            .withRollback(rollbackFailure == null ? 'completed' : 'pending')
            .toJson();
      }
      return postDeliveryFenceFailure.toJson();
    }

    _tasks[task.id] = task;
    final persistenceFailure = await _persistActiveTasksLocked(scope);
    if (persistenceFailure != null) {
      _tasks.remove(task.id);
      if (task.systemScheduled) {
        final rollbackFailure = await _compensateScheduledDelivery(
          task.deliveryId,
        );
        return persistenceFailure
            .withRollback(rollbackFailure == null ? 'completed' : 'pending')
            .toJson();
      }
      return persistenceFailure.toJson();
    }

    if (task.systemScheduled) {
      final clearFailure = await _clearCancellationJournalLocked(
        task.deliveryId,
      );
      if (clearFailure != null) {
        _tasks.remove(task.id);
        final rollbackPersistence = await _persistTasksForScope(scope);
        final rollbackDelivery = await _compensateScheduledDelivery(
          task.deliveryId,
        );
        return clearFailure
            .withRollback(
              rollbackPersistence == null && rollbackDelivery == null
                  ? 'completed'
                  : 'pending',
            )
            .toJson();
      }
    }

    final finalFenceFailure = currentFenceFailure();
    if (finalFenceFailure != null) {
      _tasks.remove(task.id);
      final rollbackPersistence = await _persistTasksForScope(scope);
      if (task.systemScheduled) {
        final rollbackDelivery = await _compensateScheduledDelivery(
          task.deliveryId,
        );
        return finalFenceFailure
            .withRollback(
              rollbackPersistence == null && rollbackDelivery == null
                  ? 'completed'
                  : 'pending',
            )
            .toJson();
      }
      return finalFenceFailure
          .withRollback(rollbackPersistence == null ? 'completed' : 'pending')
          .toJson();
    }

    _armTimer(task);
    final normalizedWhen =
        '${parsed.$1.toString().padLeft(2, '0')}:'
        '${parsed.$2.toString().padLeft(2, '0')}';
    Log.i(
      '[ScheduledTask] scheduled ${task.id}: '
      '$normalizedWhen ($normalizedRepeat)',
    );
    return <String, Object?>{
      'taskId': task.id,
      'status': 'scheduled',
      'when': normalizedWhen,
      'targetAt': targetAt.toIso8601String(),
      'timezone': now.timeZoneName,
      'repeat': normalizedRepeat,
      'delivery': task.systemScheduled
          ? 'system_and_foreground'
          : 'foreground_only',
    };
  }

  Future<Map<String, Object?>> _cancelLocked(
    String taskId, {
    bool Function()? commitFenceIsCurrent,
  }) async {
    final scopeFailure = await _ensureActiveScopeLocked();
    if (scopeFailure != null) return scopeFailure.toJson();
    final scope = _activeScope!;
    final task = _tasks[taskId];
    if (task == null) return const _TaskFailure('task_not_found').toJson();

    bool capabilityFenceIsCurrent() {
      try {
        return commitFenceIsCurrent?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    _TaskFailure? currentFenceFailure() {
      if (!_signalsMatch(scope)) return const _TaskFailure('scope_changed');
      if (!capabilityFenceIsCurrent()) {
        return const _TaskFailure('capability_unavailable');
      }
      return null;
    }

    final initialFenceFailure = currentFenceFailure();
    if (initialFenceFailure != null) {
      return initialFenceFailure.toJson();
    }
    final receipt = _TaskCancellationReceipt.capture(task);

    task.timer?.cancel();
    task.timer = null;
    if (task.systemScheduled) {
      final preDeliveryFenceFailure = currentFenceFailure();
      if (preDeliveryFenceFailure != null) {
        _armTimer(task);
        return preDeliveryFenceFailure.toJson();
      }
      final deliveryFailure = await _cancelDelivery(task.deliveryId);
      if (deliveryFailure != null) {
        _armTimer(task);
        return deliveryFailure.toJson();
      }
      task.systemScheduled = false;
      final postDeliveryFenceFailure = currentFenceFailure();
      if (postDeliveryFenceFailure != null) {
        final restored = await _restoreCancellationReceipt(
          receipt,
          taskWasRemoved: false,
        );
        return postDeliveryFenceFailure
            .withRollback(
              restored.superseded
                  ? 'superseded'
                  : restored.failure == null
                  ? 'restored'
                  : 'failed',
            )
            .toJson();
      }
    }

    final prePersistenceFenceFailure = currentFenceFailure();
    if (prePersistenceFenceFailure != null) {
      final restored = await _restoreCancellationReceipt(
        receipt,
        taskWasRemoved: false,
      );
      return prePersistenceFenceFailure
          .withRollback(
            restored.superseded
                ? 'superseded'
                : restored.failure == null
                ? 'restored'
                : 'failed',
          )
          .toJson();
    }
    _tasks.remove(taskId);
    final persistenceFailure = await _persistActiveTasksLocked(scope);
    final finalFenceFailure = currentFenceFailure();
    if (finalFenceFailure != null) {
      final restored = await _restoreCancellationReceipt(
        receipt,
        taskWasRemoved: true,
      );
      return finalFenceFailure
          .withRollback(
            restored.superseded
                ? 'superseded'
                : restored.failure == null
                ? 'restored'
                : 'failed',
          )
          .toJson();
    }
    if (persistenceFailure != null) {
      _tasks[taskId] = task;
      if (_signalsMatch(scope)) {
        final rollbackFailure = await _restoreCancelledTask(task);
        _armTimer(task);
        return persistenceFailure
            .withRollback(rollbackFailure == null ? 'restored' : 'failed')
            .toJson();
      }
      return persistenceFailure.withRollback('scope_changed').toJson();
    }

    Log.i('[ScheduledTask] cancelled $taskId');
    if (!_signalsMatch(scope)) {
      return const _TaskFailure('scope_changed').toJson();
    }
    return <String, Object?>{'status': 'cancelled', 'taskId': taskId};
  }

  Future<({bool superseded, _TaskFailure? failure})>
  _restoreCancellationReceipt(
    _TaskCancellationReceipt receipt, {
    required bool taskWasRemoved,
  }) async {
    final current = _tasks[receipt.taskId];
    if (current != null && !identical(current, receipt.owner)) {
      return (superseded: true, failure: null);
    }
    if (current == null && !taskWasRemoved) {
      return (superseded: true, failure: null);
    }

    final restoredTask = current ?? receipt.restoreTask();
    if (current == null) _tasks[receipt.taskId] = restoredTask;
    restoredTask.systemScheduled = false;
    if (receipt.systemScheduled) {
      final deliveryFailure = await _scheduleSystem(restoredTask);
      if (deliveryFailure != null) {
        _armTimer(restoredTask);
        return (superseded: false, failure: deliveryFailure);
      }
      restoredTask.systemScheduled = true;
    }

    final ownerAfterDelivery = _tasks[receipt.taskId];
    if (!identical(ownerAfterDelivery, restoredTask)) {
      return (superseded: true, failure: null);
    }
    if (taskWasRemoved) {
      final persistenceFailure = await _persistActiveTasksLocked(receipt.scope);
      if (persistenceFailure != null) {
        _armTimer(restoredTask);
        return (superseded: false, failure: persistenceFailure);
      }
    }
    _armTimer(restoredTask);
    return (superseded: false, failure: null);
  }

  void _armTimer(_ScheduledTask task) {
    task.timer?.cancel();
    task.timer = null;
    if (!_executionAllowed) return;
    final now = _clock().toLocal();
    if (task.repeat == 'daily' && !task.targetAt.isAfter(now)) {
      task.targetAt = _nextOccurrence(
        now: now,
        hour: task.hour,
        minute: task.minute,
      );
    }
    if (task.repeat == 'once' && !task.targetAt.isAfter(now)) {
      task.status = 'missed';
      task.timer = null;
      return;
    }

    task.status = 'scheduled';
    final scope = task.scope;
    task.timer = Timer(task.targetAt.difference(now), () {
      unawaited(
        _runSerialized(() => _fireTaskLocked(scope: scope, id: task.id)),
      );
    });
  }

  Future<void> _fireTaskLocked({
    required _TaskScope scope,
    required String id,
  }) async {
    if (_closed || !_executionAllowed) return;
    final executionGeneration = _executionGeneration;
    final scopeFailure = await _ensureActiveScopeLocked();
    if (scopeFailure != null ||
        !_executionAllowed ||
        executionGeneration != _executionGeneration ||
        _activeScope != scope ||
        !_signalsMatch(scope)) {
      return;
    }
    final task = _tasks[id];
    if (task == null || task.scope != scope) return;

    if (_isForeground) {
      EventBus().fire(
        SystemStatusEvent(
          'scheduled_task',
          payload: <String, Object?>{
            'taskId': task.id,
            'prompt': task.prompt,
            'source': 'scheduled_task_service',
            'environmentKey': scope.environmentKey,
            'accountUuid': scope.accountUuid,
          },
        ),
      );
      Log.i('[ScheduledTask] foreground fire ${task.id}');
    } else {
      Log.i('[ScheduledTask] background delivery left to the OS: ${task.id}');
    }

    if (task.repeat == 'daily') {
      final now = _clock().toLocal();
      task.targetAt = _nextOccurrence(
        now: now,
        hour: task.hour,
        minute: task.minute,
      );
      _armTimer(task);
    } else {
      task.timer?.cancel();
      _tasks.remove(id);
    }
    final failure = await _persistActiveTasksLocked(scope);
    if (failure != null) {
      Log.w('[ScheduledTask] timer persistence failed: ${failure.code}');
    }
  }

  Future<void> _refreshScope() => _runSerialized(() async {
    final failure = await _ensureActiveScopeLocked();
    if (failure != null) {
      Log.w('[ScheduledTask] scope refresh deferred: ${failure.code}');
      return;
    }
    await _syncSystemSchedulesLocked();
  });

  Future<void> _refreshSystemSchedules() => _runSerialized(() async {
    final failure = await _ensureActiveScopeLocked();
    if (failure != null) return;
    await _syncSystemSchedulesLocked();
  });

  Future<_TaskFailure?> _ensureActiveScopeLocked() async {
    final quarantineFailure = await _ensureGlobalLegacyQuarantineLocked();
    if (quarantineFailure != null) return quarantineFailure;
    final desired = _desiredScope;
    if (_activeScope != desired || _pendingCancellationIds.isNotEmpty) {
      final failure = await _switchScopeLocked(desired);
      if (failure != null) return failure;
    }
    if (desired == null || _activeScope == null) {
      return const _TaskFailure('sign_in_required');
    }
    return null;
  }

  Future<_TaskFailure?> _switchScopeLocked(_TaskScope? next) async {
    final previous = _activeScope;
    if (previous != null && previous != next) {
      for (final task in _tasks.values) {
        task.timer?.cancel();
        task.timer = null;
        if (task.systemScheduled) {
          _pendingCancellationIds.add(task.deliveryId);
          _scopedCleanupCancellationIds.add(task.deliveryId);
        }
      }
      _tasks.clear();
      _activeScope = null;
      _nextId = 1;
      final journalFailure = await _persistPendingCancellationsLocked();
      if (journalFailure != null) {
        return const _TaskFailure(
          'scope_cleanup_failed',
          cause: 'persistence_failed',
        );
      }
    }

    final cleanupFailure = await _drainPendingCancellationsLocked();
    if (cleanupFailure != null) return cleanupFailure;
    if (next == null) return null;
    if (_activeScope == next) return null;

    final restore = await _restoreScope(next);
    final restoreFailure = restore.failure;
    if (restoreFailure != null) return restoreFailure;
    final restored = restore.tasks;
    _activeScope = next;
    _tasks
      ..clear()
      ..addEntries(restored.map((task) => MapEntry(task.id, task)));
    _nextId = _nextIdFor(restored);
    for (final task in restored) {
      _armTimer(task);
    }
    return null;
  }

  Future<_TaskFailure?> _drainPendingCancellationsLocked() async {
    if (_pendingCancellationIds.isEmpty) return null;
    String? cause;
    for (final deliveryId in _pendingCancellationIds.toList()) {
      if (_pendingScheduleCompletionIds.contains(deliveryId)) {
        cause = 'delivery_schedule_pending';
        continue;
      }
      final failure = await _cancelDelivery(deliveryId);
      if (failure == null) {
        _pendingCancellationIds.remove(deliveryId);
        _scopedCleanupCancellationIds.remove(deliveryId);
      } else {
        cause = failure.code;
      }
    }
    final persistenceFailure = await _persistPendingCancellationsLocked();
    if (persistenceFailure != null) {
      return const _TaskFailure(
        'scope_cleanup_failed',
        cause: 'persistence_failed',
      );
    }
    if (_pendingCancellationIds.isNotEmpty) {
      return _TaskFailure('scope_cleanup_failed', cause: cause);
    }
    return null;
  }

  Future<({List<_ScheduledTask> tasks, _TaskFailure? failure})> _restoreScope(
    _TaskScope scope,
  ) async {
    final currentRaw = _prefs?.getString(scope.storageKey);
    final legacyRaw = _prefs?.getString(scope.legacyStorageKey);

    if (currentRaw != null && currentRaw.isNotEmpty) {
      final current = _decodeScope(currentRaw, scope: scope);
      if (legacyRaw != null && legacyRaw.isNotEmpty) {
        final legacy = _decodeScope(legacyRaw, scope: scope, legacy: true);
        final cleanupFailure = await _cleanupLegacyScopeLocked(scope, legacy);
        if (cleanupFailure != null) {
          return (tasks: <_ScheduledTask>[], failure: cleanupFailure);
        }
        final removalFailure = await _removePreference(scope.legacyStorageKey);
        if (removalFailure != null) {
          return (
            tasks: <_ScheduledTask>[],
            failure: const _TaskFailure(
              'scope_cleanup_failed',
              cause: 'persistence_failed',
            ),
          );
        }
      }
      return (tasks: current, failure: null);
    }

    if (legacyRaw == null || legacyRaw.isEmpty) {
      return (tasks: <_ScheduledTask>[], failure: null);
    }
    final legacy = _decodeScope(legacyRaw, scope: scope, legacy: true);
    final cleanupFailure = await _cleanupLegacyScopeLocked(scope, legacy);
    if (cleanupFailure != null) {
      return (tasks: <_ScheduledTask>[], failure: cleanupFailure);
    }
    for (final task in legacy) {
      task.systemScheduled = false;
    }
    final persistenceFailure = await _persistRestoredScope(scope, legacy);
    if (persistenceFailure != null) {
      return (tasks: <_ScheduledTask>[], failure: persistenceFailure);
    }
    final removalFailure = await _removePreference(scope.legacyStorageKey);
    if (removalFailure != null) {
      return (
        tasks: <_ScheduledTask>[],
        failure: const _TaskFailure(
          'scope_cleanup_failed',
          cause: 'persistence_failed',
        ),
      );
    }
    return (tasks: legacy, failure: null);
  }

  List<_ScheduledTask> _decodeScope(
    String raw, {
    required _TaskScope scope,
    bool legacy = false,
  }) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <_ScheduledTask>[];
      final now = _clock().toLocal();
      final restored = <_ScheduledTask>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final task = _ScheduledTask.fromJson(
          item.cast<String, Object?>(),
          expectedScope: scope,
          now: now,
          expectedDeliveryId: legacy ? scope.legacyDeliveryId : null,
        );
        if (task == null) continue;
        if (task.repeat == 'daily') {
          task.targetAt = _nextOccurrence(
            now: now,
            hour: task.hour,
            minute: task.minute,
          );
        }
        restored.add(task);
      }
      return restored;
    } catch (_) {
      Log.w('[ScheduledTask] scoped restore failed');
      return <_ScheduledTask>[];
    }
  }

  Future<_TaskFailure?> _cleanupLegacyScopeLocked(
    _TaskScope scope,
    List<_ScheduledTask> legacy,
  ) async {
    for (final task in legacy) {
      if (_requiresHistoricalCancellation(task.systemScheduled)) {
        _pendingCancellationIds.add(scope.legacyDeliveryId(task.id));
      }
    }
    final journalFailure = await _persistPendingCancellationsLocked();
    if (journalFailure != null) {
      return const _TaskFailure(
        'scope_cleanup_failed',
        cause: 'persistence_failed',
      );
    }
    return _drainPendingCancellationsLocked();
  }

  Future<_TaskFailure?> _persistRestoredScope(
    _TaskScope scope,
    List<_ScheduledTask> tasks,
  ) {
    final data = tasks.map((task) => task.toJson()).toList(growable: false);
    return _writePreference(scope.storageKey, jsonEncode(data));
  }

  int _nextIdFor(List<_ScheduledTask> tasks) {
    var maxId = 0;
    for (final task in tasks) {
      final value = int.tryParse(task.id.replaceFirst('t', '')) ?? 0;
      if (value > maxId) maxId = value;
    }
    return maxId + 1;
  }

  Future<_TaskFailure?> _restorePendingCancellationsLocked() async {
    if (_pendingCancellationJournalRestored) return null;
    final prefs = _prefs;
    if (prefs == null) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'persistence_unavailable',
      );
    }
    try {
      final raw = prefs.get(_pendingCancellationStorageKey);
      final restored = <String>{};
      final salvageFailure = _restoreCorruptJournalSalvageLocked();
      if (salvageFailure != null) return salvageFailure;
      restored.addAll(_corruptJournalSalvageIds);
      var corrupt = false;
      if (raw == null) {
        // An absent journal is a valid, empty source.
      } else if (raw is String && raw.isNotEmpty) {
        Object? decoded;
        try {
          decoded = jsonDecode(raw);
        } catch (_) {
          corrupt = true;
        }
        if (decoded is List) {
          for (final value in decoded) {
            final id = value is String ? value.trim() : '';
            if (_isSafeScheduledTaskDeliveryId(id)) {
              restored.add(id);
              continue;
            }
            corrupt = true;
            restored.addAll(
              _extractScheduledTaskDeliveryIds(jsonEncode(value)),
            );
          }
        } else {
          corrupt = true;
          restored.addAll(_extractScheduledTaskDeliveryIds(raw));
        }
      } else {
        corrupt = true;
      }

      if (corrupt) {
        _corruptJournalSalvageIds.addAll(restored);
        final salvageFailure = await _persistCorruptJournalSalvageLocked();
        if (salvageFailure != null) {
          return const _TaskFailure(
            'global_quarantine_failed',
            cause: 'cleanup_salvage_persistence_failed',
          );
        }
        _unresolvedLegacyQuarantineTokens.add(_cleanupJournalSourceFaultToken);
        final faultFailure = await _persistQuarantineFaultsLocked();
        if (faultFailure != null) {
          return const _TaskFailure(
            'global_quarantine_failed',
            cause: 'quarantine_fault_persistence_failed',
          );
        }
      } else if (_unresolvedLegacyQuarantineTokens.remove(
        _cleanupJournalSourceFaultToken,
      )) {
        final faultFailure = await _persistQuarantineFaultsLocked();
        if (faultFailure != null) {
          _unresolvedLegacyQuarantineTokens.add(
            _cleanupJournalSourceFaultToken,
          );
          return const _TaskFailure(
            'global_quarantine_failed',
            cause: 'quarantine_fault_persistence_failed',
          );
        }
      }
      _pendingCancellationIds.addAll(restored);
      _pendingCancellationJournalRestored = !corrupt;
      return corrupt
          ? const _TaskFailure(
              'global_quarantine_failed',
              cause: 'cleanup_journal_corrupt',
            )
          : null;
    } catch (_) {
      _unresolvedLegacyQuarantineTokens.add(_cleanupJournalSourceFaultToken);
      final faultFailure = await _persistQuarantineFaultsLocked();
      return _TaskFailure(
        'global_quarantine_failed',
        cause: faultFailure == null
            ? 'cleanup_journal_corrupt'
            : 'quarantine_fault_persistence_failed',
      );
    }
  }

  _TaskFailure? _restoreCorruptJournalSalvageLocked() {
    final prefs = _prefs;
    if (prefs == null) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'persistence_unavailable',
      );
    }
    try {
      final raw = prefs.get(_corruptJournalSalvageStorageKey);
      if (raw == null) return null;
      if (raw is! String || raw.isEmpty) {
        return const _TaskFailure(
          'global_quarantine_failed',
          cause: 'cleanup_salvage_corrupt',
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const _TaskFailure(
          'global_quarantine_failed',
          cause: 'cleanup_salvage_corrupt',
        );
      }
      final restored = <String>{};
      for (final value in decoded) {
        final id = value is String ? value.trim() : '';
        if (!_isSafeScheduledTaskDeliveryId(id)) {
          return const _TaskFailure(
            'global_quarantine_failed',
            cause: 'cleanup_salvage_corrupt',
          );
        }
        restored.add(id);
      }
      _corruptJournalSalvageIds.addAll(restored);
      return null;
    } catch (_) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'cleanup_salvage_corrupt',
      );
    }
  }

  Future<_TaskFailure?> _persistCorruptJournalSalvageLocked() {
    if (_corruptJournalSalvageIds.isEmpty) {
      return _removePreference(_corruptJournalSalvageStorageKey);
    }
    final ids = _corruptJournalSalvageIds.toList()..sort();
    return _writePreference(_corruptJournalSalvageStorageKey, jsonEncode(ids));
  }

  Future<_TaskFailure?> _cancelCorruptJournalIdsLocked(Set<String> ids) async {
    _TaskFailure? firstFailure;
    for (final id in ids) {
      final failure = await _cancelDelivery(id);
      if (failure == null) {
        _pendingCancellationIds.remove(id);
      } else {
        firstFailure ??= _globalQuarantineFailure(failure);
      }
    }
    return firstFailure;
  }

  Future<_TaskFailure?> _ensureGlobalLegacyQuarantineLocked({
    _TaskScope? targetScope,
  }) async {
    final desiredScope = targetScope ?? _desiredScope;
    if (_globalLegacyQuarantineComplete &&
        _globalQuarantineScope == desiredScope &&
        _pendingCancellationIds.isEmpty) {
      return null;
    }
    _globalLegacyQuarantineComplete = false;

    _TaskFailure? firstFailure;
    var platformSweepCompleted = false;
    final delivery = _delivery;
    final platformQuarantine = delivery is ScheduledNotificationQuarantine
        ? delivery as ScheduledNotificationQuarantine
        : null;
    if (platformQuarantine != null) {
      try {
        final result = await platformQuarantine
            .quarantinePendingScheduledNotifications();
        platformSweepCompleted =
            result == ScheduledNotificationQuarantineResult.swept ||
            result == ScheduledNotificationQuarantineResult.noPlatformAuthority;
        if (platformSweepCompleted) {
          for (final task in _tasks.values) {
            task.systemScheduled = false;
          }
          final repairFailure =
              await _repairQuarantineAuthorityAfterSweepLocked();
          if (repairFailure != null) return repairFailure;
        }
      } catch (error) {
        return _TaskFailure(
          'global_quarantine_failed',
          cause: 'platform_pending_sweep_failed:$error',
        );
      }
    }
    final markerFailure = _restoreLegacyQuarantineFaultsLocked();
    if (markerFailure != null) return markerFailure;

    final journalRestoreFailure = await _restorePendingCancellationsLocked();
    if (journalRestoreFailure?.cause == 'quarantine_fault_persistence_failed') {
      return journalRestoreFailure;
    }
    final journalledAtStart = Set<String>.of(_pendingCancellationIds);
    if (journalRestoreFailure?.cause == 'cleanup_journal_corrupt') {
      final salvageFailure = await _cancelCorruptJournalIdsLocked(
        journalledAtStart,
      );
      return salvageFailure ?? journalRestoreFailure;
    }
    if (journalRestoreFailure != null) firstFailure = journalRestoreFailure;

    final pendingWasScoped =
        _activeScope != null ||
        _pendingCancellationIds.any(_scopedCleanupCancellationIds.contains) ||
        _pendingCancellationIds.any(_pendingScheduleCompletionIds.contains);
    final pendingFailure = await _drainPendingCancellationsLocked();
    if (pendingFailure != null) {
      // Preserve scoped cleanup errors for work admitted by this live service,
      // while persisted orphan cleanup remains explicitly global.
      firstFailure ??= pendingWasScoped
          ? pendingFailure
          : _globalQuarantineFailure(pendingFailure);
    }

    final prefs = _prefs;
    if (prefs == null) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'persistence_unavailable',
      );
    }

    late final List<String> legacyKeys;
    try {
      legacyKeys =
          prefs
              .getKeys()
              .where((key) => key.startsWith('$_legacyStoragePrefix.'))
              .toList(growable: false)
            ..sort();
    } catch (_) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'preference_scan_failed',
      );
    }

    for (final key in legacyKeys) {
      Object? stored;
      var preferenceReadFailed = false;
      try {
        stored = prefs.get(key);
      } catch (_) {
        preferenceReadFailed = true;
      }
      final inspection = _inspectLegacyPreference(
        key: key,
        stored: stored,
        desiredScope: desiredScope,
      );
      if (inspection.deferToActiveScope) continue;

      final deliveryIds = platformSweepCompleted
          ? const <String>{}
          : inspection.deliveryIds;
      final hasUnresolvedDelivery =
          !platformSweepCompleted && inspection.hasUnresolvedDelivery;
      var journalReady = true;
      if (deliveryIds.isNotEmpty) {
        _pendingCancellationIds.addAll(deliveryIds);
        final journalFailure = await _persistPendingCancellationsLocked();
        if (journalFailure != null) {
          journalReady = false;
          firstFailure ??= _globalQuarantineFailure(journalFailure);
        }
        // The v3 source record/marker already retains the complete ids. Even
        // when the redundant journal write fails, cancelling those known ids
        // is an idempotent one-way privacy improvement. Keep the source and
        // return the persistence failure so a later admission retries it.
        final cancellationFailure = await _drainPendingCancellationsLocked();
        if (cancellationFailure != null) {
          firstFailure ??= _globalQuarantineFailure(cancellationFailure);
        }
      }

      var unresolvedRecorded = !hasUnresolvedDelivery;
      if (hasUnresolvedDelivery) {
        final unresolvedFailure = await _recordUnresolvedLegacyKeyLocked(key);
        unresolvedRecorded = unresolvedFailure == null;
        if (unresolvedFailure != null) {
          firstFailure ??= _globalQuarantineFailure(unresolvedFailure);
        }
      }

      if (inspection.wellFormed) {
        if (!journalReady ||
            _pendingCancellationIds.any(deliveryIds.contains)) {
          continue;
        }
        final migration = _decodeLegacyQuarantineMigration(key, stored);
        if (migration == null) {
          firstFailure ??= const _TaskFailure(
            'global_quarantine_failed',
            cause: 'legacy_scope_malformed',
          );
          continue;
        }
        final migrationFailure = await _persistLegacyQuarantineMigrationLocked(
          migration,
        );
        if (migrationFailure != null) {
          firstFailure ??= _globalQuarantineFailure(migrationFailure);
          continue;
        }
        final removalFailure = await _removePreference(key);
        if (removalFailure != null) {
          firstFailure ??= _globalQuarantineFailure(removalFailure);
        }
        continue;
      }

      if (preferenceReadFailed) {
        firstFailure ??= const _TaskFailure(
          'global_quarantine_failed',
          cause: 'preference_read_failed',
        );
      }
      final scrubFailure = inspection.scrubbed
          ? null
          : await _scrubLegacyPreferenceLocked(
              key,
              deliveryIds: deliveryIds,
              hasUnresolvedDelivery: hasUnresolvedDelivery,
            );
      if (scrubFailure != null) {
        firstFailure ??= _globalQuarantineFailure(scrubFailure);
      }

      // A malformed record may contain a user prompt, so scrub its value
      // immediately. Keep the scrubbed v3 marker as crash-safe cleanup
      // authority until every recoverable delivery id has actually cancelled;
      // SharedPreferences writes alone are not a durability boundary.
      final hasPendingDelivery = _pendingCancellationIds.any(
        deliveryIds.contains,
      );
      if (journalReady &&
          unresolvedRecorded &&
          !hasUnresolvedDelivery &&
          !hasPendingDelivery) {
        final removalFailure = await _removePreference(key);
        if (removalFailure != null) {
          firstFailure ??= _globalQuarantineFailure(removalFailure);
        }
      }
    }

    final orphanV4Failure = await _quarantineOrphanV4ScopesLocked(
      desiredScope,
      forcedCancellationIds: journalledAtStart,
      platformSweepCompleted: platformSweepCompleted,
    );
    if (orphanV4Failure != null) firstFailure ??= orphanV4Failure;

    if (_unresolvedLegacyQuarantineTokens.isNotEmpty) {
      firstFailure ??= const _TaskFailure(
        'global_quarantine_failed',
        cause: 'unresolved_legacy_delivery',
      );
    }
    if (firstFailure != null) {
      Log.w(
        '[ScheduledTask] global legacy quarantine blocked: '
        '${firstFailure.cause ?? firstFailure.code}',
      );
      return firstFailure;
    }
    if (_corruptJournalSalvageIds.isNotEmpty) {
      final retained = Set<String>.of(_corruptJournalSalvageIds);
      _corruptJournalSalvageIds.clear();
      final salvageRemovalFailure = await _persistCorruptJournalSalvageLocked();
      if (salvageRemovalFailure != null) {
        _corruptJournalSalvageIds.addAll(retained);
        return _globalQuarantineFailure(salvageRemovalFailure);
      }
    }
    if (targetScope == null && _desiredScope != desiredScope) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'scope_changed',
      );
    }

    if (platformSweepCompleted &&
        desiredScope != null &&
        _activeScope == desiredScope &&
        _signalsMatch(desiredScope)) {
      final rescheduleFailure = await _syncSystemSchedulesLocked();
      if (rescheduleFailure != null) return rescheduleFailure;
    }

    _globalQuarantineScope = desiredScope;
    _globalLegacyQuarantineComplete = true;
    return null;
  }

  Future<_TaskFailure?> _quarantineOrphanV4ScopesLocked(
    _TaskScope? desiredScope, {
    required Set<String> forcedCancellationIds,
    required bool platformSweepCompleted,
  }) async {
    final prefs = _prefs;
    if (prefs == null) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'persistence_unavailable',
      );
    }

    late final List<String> scopedKeys;
    try {
      scopedKeys =
          prefs
              .getKeys()
              .where((key) => key.startsWith('$_storagePrefix.'))
              .toList(growable: false)
            ..sort();
    } catch (_) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'preference_scan_failed',
      );
    }

    _TaskFailure? firstFailure;
    for (final key in scopedKeys) {
      final candidateDigest = key.substring('$_storagePrefix.'.length);
      final digest = RegExp(r'^[a-f0-9]{64}$').hasMatch(candidateDigest)
          ? candidateDigest
          : null;
      Object? stored;
      try {
        stored = prefs.get(key);
      } catch (_) {
        firstFailure ??= const _TaskFailure(
          'global_quarantine_failed',
          cause: 'preference_read_failed',
        );
        continue;
      }

      List<Object?>? decoded;
      if (stored is String) {
        try {
          final value = jsonDecode(stored);
          if (value is List) decoded = value.cast<Object?>();
        } catch (_) {
          // The raw value is scrubbed into a marker below.
        }
      }

      final scrubbedItems = <Map<String, Object?>>[];
      final completedItems = <Map<String, Object?>>[];
      final cancellationIds = <String>{};
      var hasMalformed = decoded == null || digest == null;
      var hasUnresolvedDelivery = false;
      var completionReady = true;
      final items = decoded ?? <Object?>[stored];
      for (final item in items) {
        final markerRecovery = _recoverV4Marker(item, key: key, digest: digest);
        if (markerRecovery != null) {
          hasMalformed = true;
          final deliveryIds = platformSweepCompleted
              ? const <String>{}
              : markerRecovery.deliveryIds;
          final unresolved =
              !platformSweepCompleted && markerRecovery.hasUnresolvedDelivery;
          cancellationIds.addAll(deliveryIds);
          hasUnresolvedDelivery |= unresolved;
          final marker = _v4ScrubbedItem(
            key,
            deliveryIds: deliveryIds,
            hasUnresolvedDelivery: unresolved,
          );
          scrubbedItems.add(marker);
          if (unresolved) {
            completedItems.add(
              _v4ScrubbedItem(
                key,
                deliveryIds: const <String>{},
                hasUnresolvedDelivery: true,
              ),
            );
          }
          continue;
        }

        Map<String, Object?>? record;
        if (item is Map) {
          try {
            record = Map<String, Object?>.from(item.cast<String, Object?>());
          } catch (_) {
            // Treat the item as malformed below.
          }
        }
        _TaskScope? recordScope;
        _ScheduledTask? parsed;
        if (record != null && digest != null) {
          final environmentKey = record['environmentKey']?.toString() ?? '';
          final accountUuid = record['accountUuid']?.toString() ?? '';
          if (environmentKey.isNotEmpty && accountUuid.isNotEmpty) {
            recordScope = _TaskScope(
              environmentKey: environmentKey,
              accountUuid: accountUuid,
            );
            parsed = _ScheduledTask.fromJson(
              record,
              expectedScope: recordScope,
              now: _clock().toLocal(),
            );
          }
        }
        final recordIsValid =
            record != null &&
            recordScope?.storageKey == key &&
            record['systemScheduled'] is bool &&
            parsed != null;
        if (recordIsValid) {
          scrubbedItems.add(record);
          final completed = Map<String, Object?>.from(record);
          final belongsToMountedScope =
              key == desiredScope?.storageKey ||
              key == _activeScope?.storageKey;
          final requiresDetachedCancellation =
              forcedCancellationIds.contains(parsed.deliveryId) ||
              (!belongsToMountedScope &&
                  _requiresHistoricalCancellation(
                    record['systemScheduled'] == true,
                  ));
          if (platformSweepCompleted || requiresDetachedCancellation) {
            completed['systemScheduled'] = false;
          }
          if (!platformSweepCompleted && requiresDetachedCancellation) {
            cancellationIds.add(parsed.deliveryId);
          }
          completedItems.add(completed);
          continue;
        }

        hasMalformed = true;
        final recovery = _recoverV4DeliveryIds(item, digest: digest);
        final deliveryIds = platformSweepCompleted
            ? const <String>{}
            : recovery.deliveryIds;
        final unresolved =
            !platformSweepCompleted && recovery.hasUnresolvedDelivery;
        cancellationIds.addAll(deliveryIds);
        hasUnresolvedDelivery |= unresolved;
        final marker = _v4ScrubbedItem(
          key,
          deliveryIds: deliveryIds,
          hasUnresolvedDelivery: unresolved,
        );
        scrubbedItems.add(marker);
        if (unresolved) {
          completedItems.add(
            _v4ScrubbedItem(
              key,
              deliveryIds: const <String>{},
              hasUnresolvedDelivery: true,
            ),
          );
        }
      }

      // Scrub every malformed item before attempting platform cancellation.
      // This makes the marker itself crash-safe cleanup authority and ensures
      // a failed cancel never leaves a user prompt in quarantined storage.
      if (hasMalformed) {
        final scrubFailure = await _writePreference(
          key,
          jsonEncode(scrubbedItems),
        );
        if (scrubFailure != null) {
          firstFailure ??= _globalQuarantineFailure(scrubFailure);
          completionReady = false;
        }
        if (hasUnresolvedDelivery) {
          final faultFailure = await _recordUnresolvedV4KeyLocked(key);
          if (faultFailure != null) {
            firstFailure ??= _globalQuarantineFailure(faultFailure);
            completionReady = false;
          }
        }
      }

      if (cancellationIds.isNotEmpty) {
        _pendingCancellationIds.addAll(cancellationIds);
        final journalFailure = await _persistPendingCancellationsLocked();
        if (journalFailure != null) {
          firstFailure ??= _globalQuarantineFailure(journalFailure);
          completionReady = false;
        }
        // A valid raw record or the scrubbed v4 marker remains independent
        // cleanup authority. Cancel known ids even if the redundant journal
        // cannot be written, then keep that source for the retry.
        final cancellationFailure = await _drainPendingCancellationsLocked();
        if (cancellationFailure != null) {
          firstFailure ??= _globalQuarantineFailure(cancellationFailure);
          completionReady = false;
        }
      }

      if (completionReady &&
          !_pendingCancellationIds.any(cancellationIds.contains) &&
          (platformSweepCompleted ||
              hasMalformed ||
              cancellationIds.isNotEmpty)) {
        final completionFailure = await _writePreference(
          key,
          jsonEncode(completedItems),
        );
        if (completionFailure != null) {
          firstFailure ??= _globalQuarantineFailure(completionFailure);
        }
      }
      if (hasUnresolvedDelivery) {
        firstFailure ??= const _TaskFailure(
          'global_quarantine_failed',
          cause: 'orphan_v4_malformed',
        );
      }
    }
    return firstFailure;
  }

  Future<_TaskFailure?> _repairQuarantineAuthorityAfterSweepLocked() async {
    // The platform sweep is the authority that no scheduled or delivered
    // notification survives. Persist canonical empty sources before clearing
    // memory so a crash or write failure forces the next admission to sweep
    // again rather than trusting a partially-repaired marker.
    for (final key in <String>[
      _pendingCancellationStorageKey,
      _corruptJournalSalvageStorageKey,
      _legacyQuarantineFaultStorageKey,
    ]) {
      final failure = await _writePreference(key, '[]');
      if (failure != null) {
        return _TaskFailure(
          'global_quarantine_failed',
          cause: 'authoritative_sweep_marker_cleanup_failed',
        );
      }
    }

    final liveScheduleIds = _pendingCancellationIds
        .where(_pendingScheduleCompletionIds.contains)
        .toSet();
    _pendingCancellationIds
      ..clear()
      ..addAll(liveScheduleIds);
    _scopedCleanupCancellationIds.removeWhere(
      (id) => !liveScheduleIds.contains(id),
    );
    _corruptJournalSalvageIds.clear();
    _unresolvedLegacyQuarantineTokens.clear();
    _pendingCancellationJournalRestored = true;
    _legacyQuarantineFaultsRestored = true;
    return null;
  }

  _TaskFailure? _restoreLegacyQuarantineFaultsLocked() {
    if (_legacyQuarantineFaultsRestored) return null;
    final prefs = _prefs;
    if (prefs == null) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'persistence_unavailable',
      );
    }
    try {
      final raw = prefs.get(_legacyQuarantineFaultStorageKey);
      if (raw == null) {
        _legacyQuarantineFaultsRestored = true;
        return null;
      }
      if (raw is! String) {
        _unresolvedLegacyQuarantineTokens.add('corrupt_fault_marker');
        _legacyQuarantineFaultsRestored = true;
        return null;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _unresolvedLegacyQuarantineTokens.add('corrupt_fault_marker');
      } else {
        for (final value in decoded) {
          final token = value?.toString().trim() ?? '';
          if (RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
            _unresolvedLegacyQuarantineTokens.add(token);
          } else {
            _unresolvedLegacyQuarantineTokens.add('corrupt_fault_marker');
          }
        }
      }
      _legacyQuarantineFaultsRestored = true;
      return null;
    } catch (_) {
      return const _TaskFailure(
        'global_quarantine_failed',
        cause: 'fault_marker_read_failed',
      );
    }
  }

  Future<_TaskFailure?> _recordUnresolvedLegacyKeyLocked(String key) async {
    final token = _legacyQuarantineToken(key);
    _unresolvedLegacyQuarantineTokens.add(token);
    final failure = await _persistQuarantineFaultsLocked();
    if (failure == null) {
      Log.w(
        '[ScheduledTask] unresolved legacy delivery quarantined: '
        '${token.substring(0, 12)}',
      );
    }
    return failure;
  }

  Future<_TaskFailure?> _recordUnresolvedV4KeyLocked(String key) async {
    final token = _v4QuarantineToken(key);
    _unresolvedLegacyQuarantineTokens.add(token);
    return _persistQuarantineFaultsLocked();
  }

  Future<_TaskFailure?> _persistQuarantineFaultsLocked() {
    final tokens = _unresolvedLegacyQuarantineTokens.toList()..sort();
    return _writePreference(
      _legacyQuarantineFaultStorageKey,
      jsonEncode(tokens),
    );
  }

  ({_TaskScope scope, List<_ScheduledTask> tasks})?
  _decodeLegacyQuarantineMigration(String key, Object? stored) {
    if (stored is! String) return null;
    final scope = _scopeFromLegacyStorageKey(key);
    if (scope == null) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! List) return null;
      final tasks = _decodeScope(stored, scope: scope, legacy: true);
      if (tasks.length != decoded.length) return null;
      return (scope: scope, tasks: tasks);
    } catch (_) {
      return null;
    }
  }

  _TaskScope? _scopeFromLegacyStorageKey(String key) {
    const prefix = '$_legacyStoragePrefix.';
    if (!key.startsWith(prefix)) return null;
    final parts = key.substring(prefix.length).split('.');
    if (parts.length != 2) return null;
    try {
      String decode(String value) {
        final padding = (4 - value.length % 4) % 4;
        return utf8.decode(
          base64Url.decode(value.padRight(value.length + padding, '=')),
        );
      }

      final environmentKey = decode(parts[0]).trim();
      final accountUuid = decode(parts[1]).trim();
      if (environmentKey.isEmpty || accountUuid.isEmpty) return null;
      final scope = _TaskScope(
        environmentKey: environmentKey,
        accountUuid: accountUuid,
      );
      return scope.legacyStorageKey == key ? scope : null;
    } catch (_) {
      return null;
    }
  }

  Future<_TaskFailure?> _persistLegacyQuarantineMigrationLocked(
    ({_TaskScope scope, List<_ScheduledTask> tasks}) migration,
  ) async {
    final scope = migration.scope;
    final merged = <String, _ScheduledTask>{};
    for (final task in migration.tasks) {
      task.systemScheduled = false;
      merged[task.id] = task;
    }

    final currentRaw = _prefs?.getString(scope.storageKey);
    if (currentRaw != null && currentRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(currentRaw);
        if (decoded is! List) {
          return const _TaskFailure('orphan_v4_malformed');
        }
        final current = _decodeScope(currentRaw, scope: scope);
        if (current.length != decoded.length) {
          return const _TaskFailure('orphan_v4_malformed');
        }
        for (final task in current) {
          merged[task.id] = task;
        }
      } catch (_) {
        return const _TaskFailure('orphan_v4_malformed');
      }
    }
    return _writePreference(
      scope.storageKey,
      jsonEncode(merged.values.map((task) => task.toJson()).toList()),
    );
  }

  _LegacyQuarantineInspection _inspectLegacyPreference({
    required String key,
    required Object? stored,
    required _TaskScope? desiredScope,
  }) {
    final suffix = _legacyScopeSuffix(key);
    if (stored is! String || suffix == null) {
      return const _LegacyQuarantineInspection(
        wellFormed: false,
        deferToActiveScope: false,
        scrubbed: false,
        hasUnresolvedDelivery: true,
        deliveryIds: <String>{},
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(stored);
    } catch (_) {
      final extracted = _extractLegacyDeliveryIds(stored, suffix: suffix);
      return _LegacyQuarantineInspection(
        wellFormed: false,
        deferToActiveScope: false,
        scrubbed: false,
        hasUnresolvedDelivery: extracted.isEmpty,
        deliveryIds: extracted,
      );
    }

    if (decoded is Map &&
        decoded['marker'] == _legacyScrubbedMarker &&
        decoded['scopeToken'] == _legacyQuarantineToken(key)) {
      final ids = <String>{};
      final values = decoded['deliveryIds'];
      if (values is List) {
        for (final value in values) {
          final id = value?.toString() ?? '';
          if (_isSafeScheduledTaskDeliveryId(id)) ids.add(id);
        }
      }
      return _LegacyQuarantineInspection(
        wellFormed: false,
        deferToActiveScope: false,
        scrubbed: true,
        hasUnresolvedDelivery: decoded['hasUnresolvedDelivery'] == true,
        deliveryIds: ids,
      );
    }

    if (decoded is! List) {
      final extracted = _extractLegacyDeliveryIds(stored, suffix: suffix);
      return _LegacyQuarantineInspection(
        wellFormed: false,
        deferToActiveScope: false,
        scrubbed: false,
        hasUnresolvedDelivery: extracted.isEmpty,
        deliveryIds: extracted,
      );
    }

    var wellFormed = true;
    var hasUnresolvedDelivery = false;
    final deliveryIds = <String>{};
    for (final item in decoded) {
      if (item is! Map) {
        wellFormed = false;
        hasUnresolvedDelivery = true;
        continue;
      }
      late final Map<String, Object?> values;
      try {
        values = item.cast<String, Object?>();
      } catch (_) {
        wellFormed = false;
        hasUnresolvedDelivery = true;
        continue;
      }
      final taskId = values['taskId']?.toString().trim() ?? '';
      final expectedDeliveryId = RegExp(r'^t\d+$').hasMatch(taskId)
          ? 'scheduled-task:$suffix:$taskId'
          : null;
      final recordWellFormed =
          expectedDeliveryId != null &&
          values['deliveryId'] == expectedDeliveryId &&
          values['systemScheduled'] is bool &&
          (values['prompt']?.toString().isNotEmpty ?? false) &&
          RegExp(
            r'^\d{1,2}:\d{2}$',
          ).hasMatch(values['when']?.toString() ?? '') &&
          (values['repeat'] == 'once' || values['repeat'] == 'daily') &&
          (values['environmentKey']?.toString().isNotEmpty ?? false) &&
          (values['accountUuid']?.toString().isNotEmpty ?? false);
      if (recordWellFormed) {
        if (_requiresHistoricalCancellation(
          values['systemScheduled'] == true,
        )) {
          deliveryIds.add(expectedDeliveryId);
        }
        continue;
      }

      wellFormed = false;
      final provided = values['deliveryId']?.toString().trim() ?? '';
      if (expectedDeliveryId != null) {
        deliveryIds.add(expectedDeliveryId);
        if (provided.isNotEmpty && provided != expectedDeliveryId) {
          if (_isSafeScheduledTaskDeliveryId(provided)) {
            deliveryIds.add(provided);
          } else {
            hasUnresolvedDelivery = true;
          }
        }
      } else {
        if (_isSafeLegacyDeliveryId(provided, suffix: suffix)) {
          deliveryIds.add(provided);
        } else if (_isSafeScheduledTaskDeliveryId(provided)) {
          deliveryIds.add(provided);
        } else {
          hasUnresolvedDelivery = true;
        }
      }
    }

    final migration = wellFormed
        ? _decodeLegacyQuarantineMigration(key, stored)
        : null;
    if (wellFormed && migration == null) {
      wellFormed = false;
    }
    final deferToActiveScope =
        migration != null &&
        desiredScope != null &&
        migration.scope == desiredScope;
    return _LegacyQuarantineInspection(
      wellFormed: wellFormed,
      deferToActiveScope: deferToActiveScope,
      scrubbed: false,
      hasUnresolvedDelivery: hasUnresolvedDelivery,
      deliveryIds: deliveryIds,
    );
  }

  Future<_TaskFailure?> _scrubLegacyPreferenceLocked(
    String key, {
    required Set<String> deliveryIds,
    required bool hasUnresolvedDelivery,
  }) => _writePreference(
    key,
    jsonEncode(<String, Object?>{
      'marker': _legacyScrubbedMarker,
      'scopeToken': _legacyQuarantineToken(key),
      'deliveryIds': deliveryIds.toList()..sort(),
      'hasUnresolvedDelivery': hasUnresolvedDelivery,
    }),
  );

  Set<String> _extractLegacyDeliveryIds(String raw, {String? suffix}) {
    final ids = <String>{};
    final deliveryPattern = suffix == null
        ? RegExp(r'scheduled-task:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+:t\d+')
        : RegExp('scheduled-task:${RegExp.escape(suffix)}:t\\d+');
    ids.addAll(deliveryPattern.allMatches(raw).map((match) => match.group(0)!));
    ids.addAll(_extractScheduledTaskDeliveryIds(raw));
    if (suffix != null) {
      final taskIdPattern = RegExp(r'"taskId"\s*:\s*"(t\d+)"');
      for (final match in taskIdPattern.allMatches(raw)) {
        ids.add('scheduled-task:$suffix:${match.group(1)}');
      }
    }
    return ids;
  }

  _V4DeliveryRecovery? _recoverV4Marker(
    Object? item, {
    required String key,
    required String? digest,
  }) {
    if (item is! Map) return null;
    late final Map<String, Object?> values;
    try {
      values = Map<String, Object?>.from(item.cast<String, Object?>());
    } catch (_) {
      return null;
    }
    if (values['marker'] != _v4ScrubbedMarker ||
        values['scopeToken'] != _v4QuarantineToken(key)) {
      return null;
    }
    final ids = <String>{};
    var unresolved = values['hasUnresolvedDelivery'] == true;
    final rawIds = values['deliveryIds'];
    if (rawIds is! List) {
      unresolved = true;
    } else {
      for (final value in rawIds) {
        final id = value is String ? value.trim() : '';
        final safe = _isSafeScheduledTaskDeliveryId(id);
        if (safe) {
          ids.add(id);
        } else {
          unresolved = true;
        }
      }
    }
    if (ids.isEmpty && !unresolved) unresolved = true;
    return _V4DeliveryRecovery(
      deliveryIds: ids,
      hasUnresolvedDelivery: unresolved,
    );
  }

  _V4DeliveryRecovery _recoverV4DeliveryIds(
    Object? item, {
    required String? digest,
  }) {
    final ids = <String>{};
    var unresolved = digest == null;
    if (item is Map && digest != null) {
      try {
        final values = Map<String, Object?>.from(item.cast<String, Object?>());
        final taskId = values['taskId']?.toString().trim() ?? '';
        if (RegExp(r'^t\d+$').hasMatch(taskId)) {
          ids.add('scheduled-task:v4:$digest:$taskId');
        }
        final provided = values['deliveryId']?.toString().trim() ?? '';
        if (provided.isNotEmpty) {
          if (_isSafeScheduledTaskDeliveryId(provided)) {
            ids.add(provided);
          } else {
            unresolved = true;
          }
        }
      } catch (_) {
        unresolved = true;
      }
    }
    try {
      final raw = item is String ? item : jsonEncode(item);
      if (digest == null) {
        ids.addAll(_extractScheduledTaskDeliveryIds(raw));
        unresolved = ids.isEmpty;
      } else {
        final extracted = _extractScheduledTaskDeliveryIds(raw);
        ids.addAll(extracted);
        final taskIdPattern = RegExp(r'"taskId"\s*:\s*"(t\d+)"');
        for (final match in taskIdPattern.allMatches(raw)) {
          ids.add('scheduled-task:v4:$digest:${match.group(1)}');
        }
      }
    } catch (_) {
      unresolved = true;
    }
    if (ids.isEmpty) unresolved = true;
    return _V4DeliveryRecovery(
      deliveryIds: ids,
      hasUnresolvedDelivery: unresolved,
    );
  }

  Map<String, Object?> _v4ScrubbedItem(
    String key, {
    required Set<String> deliveryIds,
    required bool hasUnresolvedDelivery,
  }) => <String, Object?>{
    'marker': _v4ScrubbedMarker,
    'scopeToken': _v4QuarantineToken(key),
    'deliveryIds': deliveryIds.toList()..sort(),
    'hasUnresolvedDelivery': hasUnresolvedDelivery,
  };

  Set<String> _extractScheduledTaskDeliveryIds(String raw) => RegExp(
    r'scheduled-task:(?:v4:[a-f0-9]{64}|[A-Za-z0-9_-]+:[A-Za-z0-9_-]+):t\d+',
  ).allMatches(raw).map((match) => match.group(0)!).toSet();

  bool _isSafeLegacyDeliveryId(String value, {required String suffix}) =>
      RegExp(
        '^scheduled-task:${RegExp.escape(suffix)}:t\\d+\$',
      ).hasMatch(value);

  bool _isSafeScheduledTaskDeliveryId(String value) => RegExp(
    r'^scheduled-task:(?:v4:[a-f0-9]{64}|[A-Za-z0-9_-]+:[A-Za-z0-9_-]+):t\d+$',
  ).hasMatch(value);

  String? _legacyScopeSuffix(String key) {
    const prefix = '$_legacyStoragePrefix.';
    if (!key.startsWith(prefix)) return null;
    final suffix = key.substring(prefix.length);
    final parts = suffix.split('.');
    if (parts.length != 2 ||
        parts.any(
          (part) => part.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(part),
        )) {
      return null;
    }
    return '${parts[0]}:${parts[1]}';
  }

  String _legacyQuarantineToken(String key) => sha256
      .convert(
        utf8.encode(
          'com.futurpals.maaso.scheduled-task-v3-quarantine.v1\u0000$key',
        ),
      )
      .toString();

  String _v4QuarantineToken(String key) => sha256
      .convert(
        utf8.encode(
          'com.futurpals.maaso.scheduled-task-v4-quarantine.v1\u0000$key',
        ),
      )
      .toString();

  String get _cleanupJournalSourceFaultToken => sha256
      .convert(
        utf8.encode(
          'com.futurpals.maaso.scheduled-task-cleanup-journal-source.v1',
        ),
      )
      .toString();

  _TaskFailure _globalQuarantineFailure(_TaskFailure failure) => _TaskFailure(
    'global_quarantine_failed',
    cause: failure.cause ?? failure.code,
  );

  Future<_TaskFailure?> _persistActiveTasksLocked(_TaskScope scope) {
    if (_activeScope != scope) {
      return Future<_TaskFailure?>.value(const _TaskFailure('scope_changed'));
    }
    return _persistTasksForScope(scope);
  }

  Future<_TaskFailure?> _persistTasksForScope(_TaskScope scope) async {
    final data = _tasks.values
        .where((task) => task.scope == scope)
        .map((task) => task.toJson())
        .toList();
    return _writePreference(scope.storageKey, jsonEncode(data));
  }

  Future<_TaskFailure?> _persistPendingCancellationsLocked() {
    if (_pendingCancellationIds.isEmpty) {
      return _removePreference(_pendingCancellationStorageKey);
    }
    final ids = _pendingCancellationIds.toList()..sort();
    return _writePreference(_pendingCancellationStorageKey, jsonEncode(ids));
  }

  Future<_TaskFailure?> _writePreference(String key, String value) async {
    final prefs = _prefs;
    if (prefs == null) return const _TaskFailure('persistence_failed');
    try {
      final operation =
          _injectedPreferenceWriter?.call(key, value) ??
          prefs.setString(key, value);
      final stored = await operation.timeout(_persistenceTimeout);
      return stored ? null : const _TaskFailure('persistence_failed');
    } on TimeoutException {
      return const _TaskFailure(
        'persistence_failed',
        cause: 'persistence_timeout',
      );
    } catch (_) {
      return const _TaskFailure('persistence_failed');
    }
  }

  Future<_TaskFailure?> _removePreference(String key) async {
    final prefs = _prefs;
    if (prefs == null) return const _TaskFailure('persistence_failed');
    try {
      final removed = await prefs.remove(key).timeout(_persistenceTimeout);
      return removed ? null : const _TaskFailure('persistence_failed');
    } on TimeoutException {
      return const _TaskFailure(
        'persistence_failed',
        cause: 'persistence_timeout',
      );
    } catch (_) {
      return const _TaskFailure('persistence_failed');
    }
  }

  Future<_TaskFailure?> _journalCancellationLocked(String deliveryId) async {
    _pendingCancellationIds.add(deliveryId);
    final failure = await _persistPendingCancellationsLocked();
    if (failure != null) _pendingCancellationIds.remove(deliveryId);
    return failure;
  }

  Future<_TaskFailure?> _clearCancellationJournalLocked(
    String deliveryId,
  ) async {
    _pendingCancellationIds.remove(deliveryId);
    final failure = await _persistPendingCancellationsLocked();
    if (failure != null) _pendingCancellationIds.add(deliveryId);
    return failure;
  }

  Future<_TaskFailure?> _compensateScheduledDelivery(
    String deliveryId, {
    bool clearJournalOnSuccess = true,
  }) async {
    final failure = await _cancelDelivery(deliveryId);
    if (failure == null) {
      if (!clearJournalOnSuccess) {
        _pendingCancellationIds.add(deliveryId);
        return _persistPendingCancellationsLocked();
      }
      return _clearCancellationJournalLocked(deliveryId);
    }
    _pendingCancellationIds.add(deliveryId);
    final journalFailure = await _persistPendingCancellationsLocked();
    return journalFailure ?? failure;
  }

  Future<_TaskFailure?> _restoreCancelledTask(_ScheduledTask task) async {
    if (!_systemDeliveryEnabled) {
      task.systemScheduled = false;
      return null;
    }
    final failure = await _scheduleSystem(task);
    task.systemScheduled = failure == null;
    return failure;
  }

  Future<_TaskFailure?> _scheduleSystem(_ScheduledTask task) async {
    if (!_executionAllowed) {
      return const _TaskFailure('execution_authority_unavailable');
    }
    final executionGeneration = _executionGeneration;
    final delivery = _delivery;
    if (delivery == null || !delivery.isAvailable) {
      return const _TaskFailure('delivery_unavailable');
    }
    final operation = delivery.schedule(
      notification: MaasoNotification(
        deliveryId: task.deliveryId,
        kind: MaasoNotificationKind.scheduledTask,
        title: 'Maaso 定时提醒',
        body: task.prompt.length <= 180
            ? task.prompt
            : task.prompt.substring(0, 180),
        prompt: task.prompt,
        data: <String, Object?>{
          'taskId': task.id,
          'environmentKey': task.scope.environmentKey,
          'accountUuid': task.scope.accountUuid,
        },
      ),
      target: task.targetAt,
      repeatsDaily: task.repeat == 'daily',
    );
    try {
      await operation.timeout(_deliveryTimeout);
      if (!_executionAllowed || executionGeneration != _executionGeneration) {
        return const _TaskFailure('execution_authority_changed');
      }
      return null;
    } on TimeoutException {
      if (!_pendingCancellationIds.contains(task.deliveryId)) {
        final journalFailure = await _journalCancellationLocked(
          task.deliveryId,
        );
        if (journalFailure != null) {
          _pendingCancellationIds.add(task.deliveryId);
          Log.w(
            '[ScheduledTask] late schedule journal deferred: '
            '${journalFailure.code}',
          );
        }
      }
      _pendingScheduleCompletionIds.add(task.deliveryId);
      _cancelIfScheduleCompletesLater(
        operation: operation,
        delivery: delivery,
        deliveryId: task.deliveryId,
      );
      return const _TaskFailure('delivery_timeout');
    } catch (_) {
      return const _TaskFailure('delivery_schedule_failed');
    }
  }

  void _cancelIfScheduleCompletesLater({
    required Future<void> operation,
    required NotificationDelivery delivery,
    required String deliveryId,
  }) {
    late final Future<void> tracked;
    tracked =
        _completeLateScheduleCompensation(
          operation: operation,
          delivery: delivery,
          deliveryId: deliveryId,
        ).whenComplete(() {
          _lateScheduleCompensations.remove(tracked);
        });
    _lateScheduleCompensations.add(tracked);
    unawaited(tracked);
  }

  Future<void> _completeLateScheduleCompensation({
    required Future<void> operation,
    required NotificationDelivery delivery,
    required String deliveryId,
  }) async {
    try {
      await operation;
    } catch (_) {
      if (_closed) return;
      try {
        await _runSerialized(() async {
          _pendingScheduleCompletionIds.remove(deliveryId);
          await _clearCancellationJournalLocked(deliveryId);
        });
      } catch (_) {
        // Teardown leaves the persisted journal for restart cleanup.
      }
      return;
    }
    if (_closed) {
      try {
        await delivery.cancel(deliveryId).timeout(_deliveryTimeout);
      } catch (_) {
        // The persisted cleanup journal remains the restart-safe fallback.
      }
      return;
    }
    try {
      await _runSerialized(() async {
        _pendingScheduleCompletionIds.remove(deliveryId);
        final journalFailure = _pendingCancellationIds.contains(deliveryId)
            ? null
            : await _journalCancellationLocked(deliveryId);
        if (journalFailure == null) {
          await _compensateScheduledDelivery(deliveryId);
        }
      });
    } catch (_) {
      // A concurrent teardown is covered by the persisted cleanup journal.
    }
  }

  Future<_TaskFailure?> _cancelDelivery(String deliveryId) async {
    final delivery = _delivery;
    if (delivery == null || !delivery.isAvailable) {
      return const _TaskFailure('delivery_unavailable');
    }
    try {
      await delivery.cancel(deliveryId).timeout(_deliveryTimeout);
      return null;
    } on TimeoutException {
      return const _TaskFailure('delivery_timeout');
    } catch (_) {
      return const _TaskFailure('delivery_cancel_failed');
    }
  }

  Future<_TaskFailure?> _syncSystemSchedulesLocked() async {
    final scope = _activeScope;
    if (scope == null || !_signalsMatch(scope)) return null;
    _TaskFailure? firstFailure;
    for (final task in _tasks.values) {
      if (task.status != 'scheduled') continue;
      if (_systemDeliveryEnabled) {
        if (task.systemScheduled) continue;
        final failure = await _enableSystemScheduleLocked(scope, task);
        firstFailure ??= failure;
      } else if (task.systemScheduled) {
        final failure = await _disableSystemScheduleLocked(scope, task);
        firstFailure ??= failure;
      }
    }
    if (firstFailure != null) {
      Log.w(
        '[ScheduledTask] OS sync transaction deferred: '
        '${firstFailure.cause ?? firstFailure.code}',
      );
    }
    return firstFailure;
  }

  Future<_TaskFailure?> _enableSystemScheduleLocked(
    _TaskScope scope,
    _ScheduledTask task,
  ) async {
    final journalFailure = await _journalCancellationLocked(task.deliveryId);
    if (journalFailure != null) return journalFailure;

    final scheduleFailure = await _scheduleSystem(task);
    if (scheduleFailure != null) {
      final awaitsLateSchedule = scheduleFailure.code == 'delivery_timeout';
      final rollback = await _compensateScheduledDelivery(
        task.deliveryId,
        clearJournalOnSuccess: !awaitsLateSchedule,
      );
      return scheduleFailure.withRollback(
        awaitsLateSchedule || rollback != null ? 'pending' : 'completed',
      );
    }
    if (!_signalsMatch(scope)) {
      final rollback = await _compensateScheduledDelivery(task.deliveryId);
      return const _TaskFailure(
        'scope_changed',
      ).withRollback(rollback == null ? 'completed' : 'pending');
    }

    task.systemScheduled = true;
    final persistenceFailure = await _persistActiveTasksLocked(scope);
    if (persistenceFailure != null) {
      task.systemScheduled = false;
      final rollbackPersistence = await _persistActiveTasksLocked(scope);
      final rollbackDelivery = await _compensateScheduledDelivery(
        task.deliveryId,
        clearJournalOnSuccess: rollbackPersistence == null,
      );
      return persistenceFailure.withRollback(
        rollbackPersistence == null && rollbackDelivery == null
            ? 'completed'
            : 'pending',
      );
    }

    final clearFailure = await _clearCancellationJournalLocked(task.deliveryId);
    if (clearFailure == null) return null;

    task.systemScheduled = false;
    final rollbackPersistence = await _persistActiveTasksLocked(scope);
    final rollbackDelivery = await _compensateScheduledDelivery(
      task.deliveryId,
      clearJournalOnSuccess: rollbackPersistence == null,
    );
    return clearFailure.withRollback(
      rollbackPersistence == null && rollbackDelivery == null
          ? 'completed'
          : 'pending',
    );
  }

  Future<_TaskFailure?> _disableSystemScheduleLocked(
    _TaskScope scope,
    _ScheduledTask task,
  ) async {
    final journalFailure = await _journalCancellationLocked(task.deliveryId);
    if (journalFailure != null) return journalFailure;
    final cancellationFailure = await _cancelDelivery(task.deliveryId);
    if (cancellationFailure != null) return cancellationFailure;

    task.systemScheduled = false;
    final persistenceFailure = await _persistActiveTasksLocked(scope);
    if (persistenceFailure != null) return persistenceFailure;
    return _clearCancellationJournalLocked(task.deliveryId);
  }

  (int, int)? _parseWhen(String when) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(when.trim());
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return (hour, minute);
  }

  DateTime _nextOccurrence({
    required DateTime now,
    required int hour,
    required int minute,
  }) {
    var target = DateTime(now.year, now.month, now.day, hour, minute);
    if (!target.isAfter(now)) target = target.add(const Duration(days: 1));
    return target;
  }

  _TaskScope? get _signalScope {
    if (_awaitingSessionForEnvironment) return null;
    final session = _session?.value;
    final environment = _environmentSignal?.value;
    final accountUuid = session?.accountUuid.trim() ?? '';
    if (session == null ||
        !session.isValid ||
        accountUuid.isEmpty ||
        environment == null) {
      return null;
    }
    return _TaskScope(
      environmentKey: environment.key,
      accountUuid: accountUuid,
    );
  }

  _TaskScope? get _desiredScope {
    final scope = _signalScope;
    // A bound runtime gate replaces the legacy permanent deactivation latch.
    // Browsing a companion device must not remount the Agent or arm a timer.
    if (_executionAllowedCallback != null) return scope;
    return scope == _deactivatedScope ? null : scope;
  }

  bool _signalsMatch(_TaskScope scope) => _desiredScope == scope;

  bool get _isForeground {
    final injected = _injectedIsForeground;
    if (injected != null) return injected();
    final foreground = appServices.maybeFind<AppForegroundService>();
    return foreground?.isForeground.value ?? true;
  }

  bool get _systemDeliveryEnabled {
    final preferences = _notificationPreferences?.state.value;
    return _executionAllowed &&
        _delivery?.isAvailable == true &&
        preferences?.canNotify == true &&
        preferences?.scheduledTasksEnabled == true;
  }

  bool _requiresHistoricalCancellation(bool systemScheduled) {
    if (systemScheduled) return true;
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.windows => false,
    };
  }

  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      if (_closed) {
        completer.completeError(StateError('scheduled_task_service_closed'));
        return;
      }
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  void onClose() {
    _closed = true;
    _executionChanges?.removeListener(_executionAuthorityChanged);
    _executionChanges = null;
    _notificationPreferencesWorker?.dispose();
    _sessionWorker?.dispose();
    _environmentWorker?.dispose();
    for (final task in _tasks.values) {
      task.timer?.cancel();
    }
    _tasks.clear();
    super.onClose();
  }
}

final class ScheduledTaskAccountDrainFailure implements Exception {
  const ScheduledTaskAccountDrainFailure({required this.code, this.cause});

  final String code;
  final String? cause;

  @override
  String toString() =>
      'Scheduled task account drain failed: $code'
      '${cause == null ? '' : ' ($cause)'}';
}

final class ScheduledTaskAccountScopePreparationFailure implements Exception {
  const ScheduledTaskAccountScopePreparationFailure({
    required this.code,
    this.cause,
  });

  final String code;
  final String? cause;

  @override
  String toString() =>
      'Scheduled task account preparation failed: $code'
      '${cause == null ? '' : ' ($cause)'}';
}

final class _LegacyQuarantineInspection {
  const _LegacyQuarantineInspection({
    required this.wellFormed,
    required this.deferToActiveScope,
    required this.scrubbed,
    required this.hasUnresolvedDelivery,
    required this.deliveryIds,
  });

  final bool wellFormed;
  final bool deferToActiveScope;
  final bool scrubbed;
  final bool hasUnresolvedDelivery;
  final Set<String> deliveryIds;
}

final class _V4DeliveryRecovery {
  const _V4DeliveryRecovery({
    required this.deliveryIds,
    required this.hasUnresolvedDelivery,
  });

  final Set<String> deliveryIds;
  final bool hasUnresolvedDelivery;
}

class _TaskScope {
  const _TaskScope({required this.environmentKey, required this.accountUuid});

  final String environmentKey;
  final String accountUuid;

  String get _scopeDigest => sha256
      .convert(
        utf8.encode(
          'com.futurpals.maaso.scheduled-task-scope.v1\u0000'
          '${environmentKey.trim()}\u0000${accountUuid.trim()}',
        ),
      )
      .toString();

  String get storageKey =>
      '${ScheduledTaskService._storagePrefix}.$_scopeDigest';

  String get legacyStorageKey =>
      '${ScheduledTaskService._legacyStoragePrefix}.'
      '${_encode(environmentKey)}.${_encode(accountUuid)}';

  String deliveryId(String taskId) => 'scheduled-task:v4:$_scopeDigest:$taskId';

  String legacyDeliveryId(String taskId) =>
      'scheduled-task:${_encode(environmentKey)}:'
      '${_encode(accountUuid)}:$taskId';

  static String _encode(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  @override
  bool operator ==(Object other) =>
      other is _TaskScope &&
      other.environmentKey == environmentKey &&
      other.accountUuid == accountUuid;

  @override
  int get hashCode => Object.hash(environmentKey, accountUuid);
}

class _TaskFailure {
  const _TaskFailure(this.code, {this.cause, this.rollback});

  final String code;
  final String? cause;
  final String? rollback;

  _TaskFailure withRollback(String value) =>
      _TaskFailure(code, cause: cause, rollback: value);

  Map<String, Object?> toJson() => <String, Object?>{
    'error': code,
    if (cause != null) 'cause': cause,
    if (rollback != null) 'rollback': rollback,
  };
}

final class _TaskCancellationReceipt {
  _TaskCancellationReceipt._({
    required this.owner,
    required this.scope,
    required this.taskId,
    required this.hour,
    required this.minute,
    required this.prompt,
    required this.repeat,
    required this.targetAt,
    required this.timezoneName,
    required this.timezoneOffsetMinutes,
    required this.status,
    required this.systemScheduled,
  });

  factory _TaskCancellationReceipt.capture(_ScheduledTask task) =>
      _TaskCancellationReceipt._(
        owner: task,
        scope: task.scope,
        taskId: task.id,
        hour: task.hour,
        minute: task.minute,
        prompt: task.prompt,
        repeat: task.repeat,
        targetAt: task.targetAt,
        timezoneName: task.timezoneName,
        timezoneOffsetMinutes: task.timezoneOffsetMinutes,
        status: task.status,
        systemScheduled: task.systemScheduled,
      );

  final _ScheduledTask owner;
  final _TaskScope scope;
  final String taskId;
  final int hour;
  final int minute;
  final String prompt;
  final String repeat;
  final DateTime targetAt;
  final String timezoneName;
  final int timezoneOffsetMinutes;
  final String status;
  final bool systemScheduled;

  _ScheduledTask restoreTask() => _ScheduledTask(
    scope: scope,
    id: taskId,
    hour: hour,
    minute: minute,
    prompt: prompt,
    repeat: repeat,
    targetAt: targetAt,
    timezoneName: timezoneName,
    timezoneOffsetMinutes: timezoneOffsetMinutes,
    status: status,
    systemScheduled: false,
  );
}

class _ScheduledTask {
  _ScheduledTask({
    required this.scope,
    required this.id,
    required this.hour,
    required this.minute,
    required this.prompt,
    required this.repeat,
    required this.targetAt,
    required this.timezoneName,
    required this.timezoneOffsetMinutes,
    this.status = 'scheduled',
    this.systemScheduled = false,
  });

  final _TaskScope scope;
  final String id;
  final int hour;
  final int minute;
  final String prompt;
  final String repeat;
  final String timezoneName;
  final int timezoneOffsetMinutes;
  DateTime targetAt;
  String status;
  bool systemScheduled;
  Timer? timer;

  String get deliveryId => scope.deliveryId(id);

  Map<String, Object?> toJson() => <String, Object?>{
    'environmentKey': scope.environmentKey,
    'accountUuid': scope.accountUuid,
    'taskId': id,
    'when':
        '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}',
    'repeat': repeat,
    'prompt': prompt,
    'targetAt': targetAt.toUtc().toIso8601String(),
    'timezone': timezoneName,
    'timezoneOffsetMinutes': timezoneOffsetMinutes,
    'deliveryId': deliveryId,
    'systemScheduled': systemScheduled,
    'status': status,
  };

  static _ScheduledTask? fromJson(
    Map<String, Object?> json, {
    required _TaskScope expectedScope,
    required DateTime now,
    String Function(String taskId)? expectedDeliveryId,
  }) {
    if (json['environmentKey']?.toString() != expectedScope.environmentKey ||
        json['accountUuid']?.toString() != expectedScope.accountUuid) {
      return null;
    }
    final id = json['taskId']?.toString() ?? '';
    final when = json['when']?.toString() ?? '';
    final prompt = json['prompt']?.toString() ?? '';
    final repeat = json['repeat']?.toString() ?? 'once';
    final parts = when.split(':');
    if (!RegExp(r'^t\d+$').hasMatch(id) ||
        parts.length != 2 ||
        prompt.isEmpty) {
      return null;
    }
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    if (repeat != 'once' && repeat != 'daily') return null;

    var targetAt = DateTime.tryParse(
      json['targetAt']?.toString() ?? '',
    )?.toLocal();
    if (targetAt == null) {
      targetAt = DateTime(now.year, now.month, now.day, hour, minute);
      if (!targetAt.isAfter(now)) {
        targetAt = targetAt.add(const Duration(days: 1));
      }
    }
    final offset = json['timezoneOffsetMinutes'];
    final task = _ScheduledTask(
      scope: expectedScope,
      id: id,
      hour: hour,
      minute: minute,
      prompt: prompt,
      repeat: repeat,
      targetAt: targetAt,
      timezoneName: json['timezone']?.toString() ?? now.timeZoneName,
      timezoneOffsetMinutes: offset is num
          ? offset.toInt()
          : int.tryParse('$offset') ?? now.timeZoneOffset.inMinutes,
      status: json['status']?.toString() ?? 'scheduled',
      systemScheduled: json['systemScheduled'] == true,
    );
    final expectedId = expectedDeliveryId?.call(id) ?? task.deliveryId;
    if (json['deliveryId']?.toString() != expectedId) return null;
    return task;
  }
}
