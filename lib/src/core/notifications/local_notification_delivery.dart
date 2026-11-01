import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'notification_delivery.dart';
import 'notification_models.dart';

class LocalNotificationDelivery extends AppService
    implements
        NotificationDelivery,
        ScheduledNotificationDeliveryCapabilities,
        ScheduledNotificationQuarantine {
  LocalNotificationDelivery({
    FlutterLocalNotificationsPlugin? plugin,
    @visibleForTesting
    Future<List<PendingNotificationRequest>> Function()? pendingRequestLoader,
    @visibleForTesting
    Future<List<ActiveNotification>> Function()? activeNotificationLoader,
    @visibleForTesting Future<void> Function(int id)? pendingRequestCanceller,
    @visibleForTesting Future<void> Function()? activeNotificationClearer,
    @visibleForTesting
    Future<void> Function(
      MaasoNotification notification,
      DateTime target,
      bool repeatsDaily,
    )?
    scheduledRequestDispatcher,
    @visibleForTesting
    Duration scheduledMutationTailTimeout = const Duration(seconds: 5),
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _pendingRequestLoader = pendingRequestLoader,
       _activeNotificationLoader = activeNotificationLoader,
       _pendingRequestCanceller = pendingRequestCanceller,
       _activeNotificationClearer = activeNotificationClearer,
       _scheduledRequestDispatcher = scheduledRequestDispatcher,
       _scheduledMutationTailTimeout = scheduledMutationTailTimeout,
       assert(scheduledMutationTailTimeout > Duration.zero);

  static const _companionChannel = 'maaso_companion';
  static const _taskChannel = 'maaso_scheduled_tasks';

  final FlutterLocalNotificationsPlugin _plugin;
  final Future<List<PendingNotificationRequest>> Function()?
  _pendingRequestLoader;
  final Future<List<ActiveNotification>> Function()? _activeNotificationLoader;
  final Future<void> Function(int id)? _pendingRequestCanceller;
  final Future<void> Function()? _activeNotificationClearer;
  final Future<void> Function(
    MaasoNotification notification,
    DateTime target,
    bool repeatsDaily,
  )?
  _scheduledRequestDispatcher;
  final Duration _scheduledMutationTailTimeout;
  final _interactions = StreamController<NotificationInteraction>.broadcast();
  Future<void> _scheduledMutationTail = Future<void>.value();
  Future<void> _scheduledQuarantineTail = Future<void>.value();
  Completer<void> _scheduledMutationInvalidation = Completer<void>();
  final Set<_ScheduledPlatformOperation> _scheduledPlatformOperations = {};
  int _scheduledMutationGeneration = 0;

  bool _initialized = false;
  NotificationInteraction? _initialInteraction;
  String? lastError;

  @override
  bool get isAvailable => _initialized;

  @override
  bool get supportsLocalScheduling => _supportsLocalScheduling;

  @override
  Stream<NotificationInteraction> get interactions => _interactions.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      tz_data.initializeTimeZones();
      try {
        final timezone = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(timezone.identifier));
      } catch (error) {
        Log.w('[Notifications] device timezone unavailable: $error');
      }

      final initialized = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_maaso'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _onResponse,
      );
      // Darwin returns false when initialization deliberately skips the
      // permission prompt. The method channel is still fully initialized and
      // permission can be requested later through requestPermission().
      _initialized = switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.macOS => initialized != null,
        _ => initialized ?? false,
      };

      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        _initialInteraction = NotificationInteraction.fromPayload(
          launchDetails?.notificationResponse?.payload,
        );
      }
    } catch (error) {
      lastError = error.toString();
      _initialized = false;
      Log.w('[Notifications] local delivery unavailable: $error');
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_initialized) await initialize();
    if (!_initialized) return false;
    try {
      if (kIsWeb) return false;
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin
                  >()
                  ?.requestNotificationsPermission() ??
              true;
        case TargetPlatform.iOS:
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin
                  >()
                  ?.requestPermissions(alert: true, badge: true, sound: true) ??
              false;
        case TargetPlatform.macOS:
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin
                  >()
                  ?.requestPermissions(alert: true, badge: true, sound: true) ??
              false;
        case TargetPlatform.fuchsia:
        case TargetPlatform.linux:
        case TargetPlatform.windows:
          return true;
      }
    } catch (error) {
      lastError = error.toString();
      Log.w('[Notifications] permission request failed: $error');
      return false;
    }
  }

  @override
  Future<void> show(MaasoNotification notification) async {
    if (!_initialized) return;
    try {
      await _plugin.show(
        id: _numericId(notification.deliveryId),
        title: notification.title,
        body: notification.body,
        notificationDetails: _details(notification.kind),
        payload: notification.toPayload(),
      );
    } catch (error) {
      lastError = error.toString();
      Log.w('[Notifications] show failed: $error');
    }
  }

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) {
    final mutationGeneration = _scheduledMutationGeneration;
    final mutationInvalidated = _scheduledMutationInvalidation.future;
    final requiresTransactionalDelivery = switch (notification.kind) {
      MaasoNotificationKind.scheduledTask ||
      MaasoNotificationKind.morningGreeting ||
      MaasoNotificationKind.middayGreeting ||
      MaasoNotificationKind.eveningGreeting ||
      MaasoNotificationKind.randomCheckIn => true,
      MaasoNotificationKind.remote => false,
    };
    return _runScheduledMutation(
      () async {
        if (mutationGeneration != _scheduledMutationGeneration) {
          if (requiresTransactionalDelivery) {
            throw StateError('notification_schedule_invalidated_by_sweep');
          }
          return;
        }
        if ((_initialized == false && _scheduledRequestDispatcher == null) ||
            (requiresTransactionalDelivery && !_supportsLocalScheduling)) {
          if (requiresTransactionalDelivery) {
            throw StateError('notification_delivery_unavailable');
          }
          return;
        }
        try {
          final injectedDispatcher = _scheduledRequestDispatcher;
          late final Future<void> platformOperation;
          if (injectedDispatcher != null) {
            platformOperation = injectedDispatcher(
              notification,
              target,
              repeatsDaily,
            );
          } else {
            final localTarget = tz.TZDateTime(
              tz.local,
              target.year,
              target.month,
              target.day,
              target.hour,
              target.minute,
              target.second,
            );
            platformOperation = _plugin.zonedSchedule(
              id: _numericId(notification.deliveryId),
              title: notification.title,
              body: notification.body,
              scheduledDate: localTarget,
              notificationDetails: _details(notification.kind),
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              payload: notification.toPayload(),
              matchDateTimeComponents: repeatsDaily
                  ? DateTimeComponents.time
                  : null,
            );
          }
          final trackedOperation = _ScheduledPlatformOperation(
            mutationGeneration,
          );
          _scheduledPlatformOperations.add(trackedOperation);
          _watchScheduleCompletionAcrossQuarantine(
            platformOperation: platformOperation,
            deliveryId: notification.deliveryId,
            trackedOperation: trackedOperation,
          );
          try {
            await platformOperation;
          } finally {
            _scheduledPlatformOperations.remove(trackedOperation);
            trackedOperation.settle();
          }
        } catch (error) {
          lastError = error.toString();
          Log.w('[Notifications] schedule failed: $error');
          // Governed schedulers own rollback/scope isolation and must see the
          // platform failure. Immediate remote display retains best-effort
          // behavior because its delivery is not persisted for later execution.
          if (requiresTransactionalDelivery) rethrow;
        }
      },
      predecessorInvalidation: mutationInvalidated,
      onPredecessorInvalidated: () {
        if (requiresTransactionalDelivery) {
          throw StateError('notification_schedule_invalidated_by_sweep');
        }
      },
    );
  }

  void _watchScheduleCompletionAcrossQuarantine({
    required Future<void> platformOperation,
    required String deliveryId,
    required _ScheduledPlatformOperation trackedOperation,
  }) {
    unawaited(
      platformOperation.then<void>((_) {
        if (!trackedOperation.quarantineBypassed ||
            trackedOperation.mutationGeneration ==
                _scheduledMutationGeneration) {
          return;
        }
        _queueLateScheduleCancellation(deliveryId);
      }, onError: (Object _, StackTrace _) {}),
    );
  }

  void _queueLateScheduleCancellation(String deliveryId) {
    unawaited(
      _runScheduledMutation(() async {
        try {
          await (_pendingRequestCanceller?.call(_numericId(deliveryId)) ??
                  _plugin.cancel(id: _numericId(deliveryId)))
              .timeout(_scheduledMutationTailTimeout);
        } catch (error) {
          lastError = error.toString();
          Log.w('[Notifications] late schedule cleanup failed: $error');
        }
      }),
    );
  }

  @override
  Future<ScheduledNotificationQuarantineResult>
  quarantinePendingScheduledNotifications() {
    // Fence every schedule admitted before this call immediately. A platform
    // Future may never settle, so this authoritative sweep bypasses only the
    // pre-sweep tail after a bounded wait. Ordinary schedules remain strictly
    // serialized; if an old platform operation later succeeds, the watcher
    // above enqueues compensation behind this sweep.
    _scheduledMutationGeneration++;
    final invalidation = _scheduledMutationInvalidation;
    _scheduledMutationInvalidation = Completer<void>();
    invalidation.complete();
    final preQuarantinePlatformOperations = _scheduledPlatformOperations
        .where(
          (operation) =>
              operation.mutationGeneration != _scheduledMutationGeneration,
        )
        .toList(growable: false);
    final previousQuarantine = _scheduledQuarantineTail;
    final sweep = _runScheduledMutation(
      () async {
        if (!_supportsLocalScheduling) {
          return ScheduledNotificationQuarantineResult.noPlatformAuthority;
        }
        if (!_initialized && _pendingRequestLoader == null) {
          throw StateError('notification_delivery_unavailable');
        }

        final requests =
            await (_pendingRequestLoader?.call() ??
                    _plugin.pendingNotificationRequests())
                .timeout(const Duration(seconds: 5));
        Object? firstError;
        StackTrace? firstStackTrace;
        for (final request in requests) {
          try {
            // At an account boundary every pending local request belongs to the
            // retiring account. Cancel the authoritative platform id, including
            // valid proactive requests whose preference authority may have been
            // lost before a crash. The admitted account reschedules from its own
            // scoped preferences after its session is published.
            await (_pendingRequestCanceller?.call(request.id) ??
                    _plugin.cancel(id: request.id))
                .timeout(const Duration(seconds: 5));
          } catch (error, stackTrace) {
            firstError ??= error;
            firstStackTrace ??= stackTrace;
          }
        }
        try {
          final active =
              await (_activeNotificationLoader?.call() ??
                      _plugin.getActiveNotifications())
                  .timeout(const Duration(seconds: 5));
          if (active.any((notification) => notification.id == null)) {
            // Some platform-delivered notifications (notably FCM entries) do
            // not expose a numeric id. At an account boundary every active app
            // notification belongs to the retiring account, so cancelAll is the
            // only authoritative way to clear that otherwise-unaddressable row.
            await (_activeNotificationClearer?.call() ?? _plugin.cancelAll())
                .timeout(const Duration(seconds: 5));
          } else {
            for (final notification in active) {
              final id = notification.id!;
              try {
                // Clear all numeric ids, including remote and proactive entries,
                // so Notification Center cannot retain the retiring account.
                await (_pendingRequestCanceller?.call(id) ??
                        _plugin.cancel(id: id))
                    .timeout(const Duration(seconds: 5));
              } catch (error, stackTrace) {
                firstError ??= error;
                firstStackTrace ??= stackTrace;
              }
            }
          }
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
        if (firstError != null) {
          Error.throwWithStackTrace(firstError, firstStackTrace!);
        }
        return ScheduledNotificationQuarantineResult.swept;
      },
      requiredPredecessor: previousQuarantine,
      boundedPredecessor: Future.wait<void>(
        preQuarantinePlatformOperations.map(
          (operation) => operation.quarantineBarrier,
        ),
      ),
      predecessorTimeout: _scheduledMutationTailTimeout,
      onPredecessorTimeout: () {
        for (final operation in preQuarantinePlatformOperations) {
          operation.markQuarantineBypassed();
        }
        Log.w(
          '[Notifications] quarantine bypassed a stalled schedule operation',
        );
      },
    );
    _scheduledQuarantineTail = sweep.then<void>((_) {}, onError: (_, _) {});
    return sweep;
  }

  @override
  Future<void> cancel(String deliveryId) async {
    final requiresTransactionalDelivery =
        deliveryId.startsWith('scheduled-task:') ||
        deliveryId.startsWith('proactive:');
    if (!_initialized ||
        (requiresTransactionalDelivery && !_supportsLocalScheduling)) {
      if (requiresTransactionalDelivery) {
        throw StateError('notification_delivery_unavailable');
      }
      return;
    }
    try {
      await _plugin.cancel(id: _numericId(deliveryId));
    } catch (error) {
      lastError = error.toString();
      Log.w('[Notifications] cancel failed: $error');
      if (requiresTransactionalDelivery) rethrow;
    }
  }

  @override
  NotificationInteraction? takeInitialInteraction() {
    final value = _initialInteraction;
    _initialInteraction = null;
    return value;
  }

  void _onResponse(NotificationResponse response) {
    final interaction = NotificationInteraction.fromPayload(response.payload);
    if (interaction != null && !_interactions.isClosed) {
      _interactions.add(interaction);
    }
  }

  NotificationDetails _details(MaasoNotificationKind kind) {
    final scheduled = kind == MaasoNotificationKind.scheduledTask;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        scheduled ? _taskChannel : _companionChannel,
        scheduled ? 'Scheduled tasks' : 'Agent messages',
        channelDescription: scheduled
            ? 'Reminders explicitly scheduled by the user'
            : 'Low-frequency greetings and Agent updates',
        importance: scheduled ? Importance.high : Importance.defaultImportance,
        priority: scheduled ? Priority.high : Priority.defaultPriority,
        category: scheduled
            ? AndroidNotificationCategory.reminder
            : AndroidNotificationCategory.message,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }

  int _numericId(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  bool get _supportsLocalScheduling {
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

  Future<T> _runScheduledMutation<T>(
    Future<T> Function() operation, {
    Future<void>? requiredPredecessor,
    Future<void>? boundedPredecessor,
    Duration? predecessorTimeout,
    void Function()? onPredecessorTimeout,
    Future<void>? predecessorInvalidation,
    FutureOr<T> Function()? onPredecessorInvalidated,
  }) {
    final predecessor = _scheduledMutationTail;
    final admitted = () async {
      try {
        await requiredPredecessor;
      } catch (_) {
        // Quarantine failures must not poison a later authoritative retry.
      }
      if (predecessorTimeout == null) {
        if (predecessorInvalidation == null) {
          try {
            await predecessor;
          } catch (_) {
            // Keep the queue available after an earlier operation failed.
          }
        } else {
          final predecessorCompleted = await Future.any<bool>(<Future<bool>>[
            predecessor.then((_) => true, onError: (_, _) => true),
            predecessorInvalidation.then((_) => false),
          ]);
          if (!predecessorCompleted) {
            return onPredecessorInvalidated!();
          }
        }
      } else {
        try {
          await Future.wait<void>(<Future<void>>[
            predecessor,
            ?boundedPredecessor,
          ]).timeout(predecessorTimeout);
        } on TimeoutException {
          onPredecessorTimeout?.call();
        } catch (_) {
          // Keep the queue available after an earlier operation failed.
        }
      }
      return operation();
    }();
    _scheduledMutationTail = admitted.then<void>((_) {}, onError: (_, _) {});
    return admitted;
  }

  @override
  void onClose() {
    unawaited(_interactions.close());
    super.onClose();
  }
}

final class _ScheduledPlatformOperation {
  _ScheduledPlatformOperation(this.mutationGeneration);

  final int mutationGeneration;
  final Completer<void> _quarantineBarrier = Completer<void>();
  bool quarantineBypassed = false;

  Future<void> get quarantineBarrier => _quarantineBarrier.future;

  void markQuarantineBypassed() {
    quarantineBypassed = true;
    if (!_quarantineBarrier.isCompleted) _quarantineBarrier.complete();
  }

  void settle() {
    if (!_quarantineBarrier.isCompleted) _quarantineBarrier.complete();
  }
}
