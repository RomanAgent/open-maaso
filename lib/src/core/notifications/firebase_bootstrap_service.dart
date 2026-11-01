import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

class FirebaseProjectContract {
  static const projectId = 'masso-app-prod';
  static const projectNumber = '214440851723';

  static String? validate({
    required String projectId,
    required String messagingSenderId,
  }) {
    if (projectId.trim() != FirebaseProjectContract.projectId) {
      return 'unexpected Firebase project: ${projectId.trim()}';
    }
    if (messagingSenderId.trim() != FirebaseProjectContract.projectNumber) {
      return 'unexpected Firebase sender: ${messagingSenderId.trim()}';
    }
    return null;
  }
}

abstract final class FirebaseRemoteDeliveryContract {
  /// OS-rendered notification payloads bypass Dart account/environment checks
  /// while the app is backgrounded. Production senders must therefore send
  /// data-only messages; a `notification` block is a contract violation.
  static const payloadMode = 'data-only';

  /// Background delivery remains disabled until consent and active account /
  /// environment scope are available from a durable, isolate-safe store.
  static const backgroundDeliveryMode = 'fail-closed';

  static const requiredDataClaims = <String>{
    'accountUuid',
    'environmentKey',
    'kind',
  };

  static bool isDataOnly(RemoteMessage message) => message.notification == null;

  static bool hasCanonicalClaims(Map<String, dynamic> data) {
    for (final claim in requiredDataClaims) {
      final value = data[claim];
      if (value is! String || value.isEmpty || value != value.trim()) {
        return false;
      }
    }
    return true;
  }
}

class FirebasePushMessage {
  const FirebasePushMessage({
    required this.messageId,
    required this.title,
    required this.body,
    required this.data,
  });

  final String messageId;
  final String? title;
  final String? body;
  final Map<String, Object?> data;
}

abstract interface class FirebaseMessagingGateway {
  Stream<FirebasePushMessage> get foregroundMessages;
  Stream<FirebasePushMessage> get openedMessages;
  Stream<String> get tokenRefreshes;

  Future<FirebasePushMessage?> getInitialMessage();
  Future<String?> getAPNSToken();
  Future<String?> getToken();
  Future<void> deleteToken();
  Future<bool> requestPermission();
  Future<void> setAutoInitEnabled(bool enabled);
}

/// FlutterFire cannot delete an iOS/macOS FCM token until APNs has delivered
/// the native device token. This is a temporary platform prerequisite, not a
/// failed Firebase delete request.
final class FirebaseMessagingApnsTokenUnavailable implements Exception {
  const FirebaseMessagingApnsTokenUnavailable();

  @override
  String toString() => 'APNs token is not available yet';
}

class FlutterFireMessagingGateway implements FirebaseMessagingGateway {
  FlutterFireMessagingGateway(this._messaging);

  final FirebaseMessaging _messaging;

  @override
  Stream<FirebasePushMessage> get foregroundMessages =>
      FirebaseMessaging.onMessage.map(_mapMessage);

  @override
  Stream<FirebasePushMessage> get openedMessages =>
      FirebaseMessaging.onMessageOpenedApp.map(_mapMessage);

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Future<FirebasePushMessage?> getInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _mapMessage(message);
  }

  @override
  Future<String?> getAPNSToken() => _messaging.getAPNSToken();

  @override
  Future<String?> getToken() => _messaging.getToken();

  @override
  Future<void> deleteToken() async {
    try {
      await _messaging.deleteToken();
    } on FirebaseException catch (error, stackTrace) {
      if (error.plugin == 'firebase_messaging' &&
          error.code == 'apns-token-not-set') {
        Error.throwWithStackTrace(
          const FirebaseMessagingApnsTokenUnavailable(),
          stackTrace,
        );
      }
      rethrow;
    }
  }

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<void> setAutoInitEnabled(bool enabled) =>
      _messaging.setAutoInitEnabled(enabled);

  FirebasePushMessage _mapMessage(RemoteMessage message) => FirebasePushMessage(
    messageId:
        message.messageId ??
        '${message.sentTime?.millisecondsSinceEpoch ?? 0}:${message.hashCode}',
    title: message.notification?.title,
    body: message.notification?.body,
    data: message.data.map<String, Object?>(
      (key, value) => MapEntry(key, value),
    ),
  );
}

/// Firebase is optional until the native console files have been installed.
/// A missing or wrong project never prevents the rest of Maaso from starting.
class FirebaseBootstrapService extends AppService {
  final ready = false.obs;
  final error = RxnString();

  FirebaseMessagingGateway? messaging;

  Future<FirebaseBootstrapService> init() async {
    try {
      final app = Firebase.apps.isEmpty
          ? await Firebase.initializeApp()
          : Firebase.app();
      final mismatch = FirebaseProjectContract.validate(
        projectId: app.options.projectId,
        messagingSenderId: app.options.messagingSenderId,
      );
      if (mismatch != null) {
        error.value = mismatch;
        Log.w('[Firebase] $mismatch; messaging disabled');
        return this;
      }
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      messaging = FlutterFireMessagingGateway(FirebaseMessaging.instance);
      ready.value = true;
      error.value = null;
      Log.i('[Firebase] connected to ${FirebaseProjectContract.projectId}');
    } catch (exception) {
      error.value = exception.toString();
      ready.value = false;
      Log.w(
        '[Firebase] native configuration unavailable; messaging disabled: '
        '$exception',
      );
    }
    return this;
  }
}

/// Runs in Firebase's background isolate and deliberately fails closed.
///
/// It validates the transport shape for diagnostics, but cannot prove current
/// consent/session/environment from isolate-safe durable state yet. Therefore
/// even a well-formed data-only message is not promoted into a local
/// notification. A `notification` payload may already have been displayed by
/// the OS before this callback; production senders are contractually forbidden
/// from sending one.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (!FirebaseRemoteDeliveryContract.isDataOnly(message) ||
      !FirebaseRemoteDeliveryContract.hasCanonicalClaims(message.data)) {
    return;
  }
  // Fail closed: do not initialize app services or display a local message.
}
