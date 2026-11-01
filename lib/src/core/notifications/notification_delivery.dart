import 'notification_models.dart';

abstract interface class NotificationDelivery {
  bool get isAvailable;

  Stream<NotificationInteraction> get interactions;

  Future<void> initialize();

  Future<bool> requestPermission();

  Future<void> show(MaasoNotification notification);

  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  });

  Future<void> cancel(String deliveryId);

  NotificationInteraction? takeInitialInteraction();
}

/// Optional capability exposed by deliveries that know whether the current
/// platform can own locally scheduled notification requests.
///
/// Consumers should feature-detect this interface instead of assuming that an
/// initialized [NotificationDelivery] can schedule notifications locally.
abstract interface class ScheduledNotificationDeliveryCapabilities {
  bool get supportsLocalScheduling;
}

/// Optional platform capability used before an account notification scope is
/// admitted. Implementations must enumerate the platform's authoritative
/// pending and delivered requests and cancel all of them. No new account has
/// been published at this boundary, so every local request belongs to the
/// retiring account; the admitted account reschedules from its scoped state.
///
/// Returning normally is the safety boundary: enumeration and every required
/// cancellation have completed. Failures must be propagated so account mount
/// can remain fail-closed and retry the sweep.
abstract interface class ScheduledNotificationQuarantine {
  Future<ScheduledNotificationQuarantineResult>
  quarantinePendingScheduledNotifications();
}

enum ScheduledNotificationQuarantineResult {
  /// Platform pending and delivered notification authorities were cleared.
  swept,

  /// This platform cannot host locally scheduled notification authority.
  noPlatformAuthority,

  /// No authoritative platform assertion was made; persisted quarantine
  /// records must still be inspected and unresolved records remain blocking.
  notAuthoritative,
}
