import 'package:maaso/src/core/foundation/app_framework.dart';

import 'firebase_bootstrap_service.dart';
import 'notification_delivery.dart';
import 'notification_preferences_service.dart';

class NotificationConsentService extends AppService {
  NotificationConsentService({
    required NotificationPreferencesService preferences,
    required NotificationDelivery delivery,
    FirebaseMessagingGateway? messaging,
  }) : _preferences = preferences,
       _delivery = delivery,
       _messaging = messaging;

  final NotificationPreferencesService _preferences;
  final NotificationDelivery _delivery;
  final FirebaseMessagingGateway? _messaging;

  final isUpdating = false.obs;

  Future<bool> setEnabled(bool enabled) async {
    if (isUpdating.value) return _preferences.state.value.canNotify;
    isUpdating.value = true;
    try {
      if (!enabled) {
        await _preferences.setConsent(
          enabled: false,
          permissionGranted: _preferences.state.value.permissionGranted,
        );
        await _messaging?.setAutoInitEnabled(false);
        return false;
      }

      await _delivery.initialize();
      final localGranted = await _delivery.requestPermission();
      final remoteGranted = _messaging == null
          ? true
          : await _messaging.requestPermission();
      final granted = localGranted && remoteGranted;
      await _preferences.setConsent(
        enabled: granted,
        permissionGranted: granted,
      );
      await _messaging?.setAutoInitEnabled(granted);
      return granted;
    } finally {
      isUpdating.value = false;
    }
  }
}
