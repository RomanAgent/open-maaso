import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/app_foreground_service.dart';
import 'package:maaso/src/core/notifications/local_notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/notifications/proactive_system_notification_scheduler.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/core/services/scheduled_task_service.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'OS-only A proactive is swept before B publishes and only B is rescheduled',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await NotificationPreferencesService.forTesting(
        preferences: shared,
      ).init();
      await preferences.setConsent(enabled: true, permissionGranted: true);

      const oldDeliveryId = 'proactive:v2:dGVzdA.YWNjb3VudC1h:morning';
      final oldNotification = MaasoNotification(
        deliveryId: oldDeliveryId,
        kind: MaasoNotificationKind.morningGreeting,
        title: 'old A title',
        body: 'old A body',
        prompt: 'private account A prompt',
        data: const <String, Object?>{
          'environmentKey': 'test',
          'accountUuid': 'account-a',
        },
      );
      final oldNumericId = _numericId(oldDeliveryId);
      final cancelledNumericIds = <int>[];
      final newlyScheduled = <_ScheduledDispatch>[];
      final delivery = _AvailableLocalDelivery(
        pendingRequestLoader: () async => <PendingNotificationRequest>[
          PendingNotificationRequest(
            oldNumericId,
            oldNotification.title,
            oldNotification.body,
            oldNotification.toPayload(),
          ),
        ],
        activeNotificationLoader: () async => <ActiveNotification>[],
        cancelNumericId: (id) async => cancelledNumericIds.add(id),
        scheduledRequestDispatcher: (notification, target, repeatsDaily) async {
          newlyScheduled.add(
            _ScheduledDispatch(
              notification: notification,
              target: target,
              repeatsDaily: repeatsDaily,
            ),
          );
        },
      );
      final session = Rxn<MaasoAuthSession>();
      final environment = MaasoEnvironment.test.obs;
      final proactive = await ProactiveSystemNotificationScheduler(
        preferences: preferences,
        delivery: delivery,
        foreground: AppForegroundService(),
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
        rollingHorizonDays: 1,
      ).init();
      final scheduledTasks = ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: preferences,
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
      );

      final mountToken = await proactive.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      await scheduledTasks.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      await proactive.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: mountToken,
      );
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'proactive-os-orphan-account-b.db',
      );
      final ledger = ProactiveOutreachLedger(accountDatabase: database);
      final coordinator = ProactiveOutreachCoordinator(
        policy: const ProactiveCompanionPolicy(),
        ledger: ledger,
        accountKey: 'test:account-b',
        clock: () => DateTime(2026, 8, 10, 10),
      );
      await proactive.bindAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: mountToken,
        coordinator: coordinator,
        proactivePreferences:
            const ProactivePreferenceSnapshot.defaults(generation: 1)
                .copyWith(
                  foregroundEnabled: true,
                  osOutreachEnabled: true,
                  consentRecorded: true,
                  contactScope: ProactiveConversationScope.everyday,
                )
                .obs,
      );

      expect(cancelledNumericIds, contains(oldNumericId));
      expect(newlyScheduled, isEmpty);

      session.value = _validSession('account-b');
      await proactive.sync();

      expect(
        newlyScheduled
            .map((dispatch) => dispatch.notification.deliveryId)
            .toSet(),
        hasLength(1),
      );
      expect(
        newlyScheduled.every(
          (dispatch) =>
              !dispatch.repeatsDaily &&
              dispatch.notification.deliveryId.startsWith('proactive:v3:') &&
              dispatch.notification.data['accountUuid'] == 'account-b' &&
              dispatch.notification.data['environmentKey'] == 'test',
        ),
        isTrue,
      );
      expect(
        newlyScheduled.any(
          (dispatch) =>
              dispatch.notification.data['accountUuid'] == 'account-a' ||
              dispatch.notification.prompt == oldNotification.prompt,
        ),
        isFalse,
      );

      await proactive.deactivateAccountAndDrain();
      proactive.onClose();
      scheduledTasks.onClose();
      preferences.onClose();
      await database.close();
    },
  );
}

final class _ScheduledDispatch {
  const _ScheduledDispatch({
    required this.notification,
    required this.target,
    required this.repeatsDaily,
  });

  final MaasoNotification notification;
  final DateTime target;
  final bool repeatsDaily;
}

class _AvailableLocalDelivery extends LocalNotificationDelivery {
  _AvailableLocalDelivery({
    required Future<List<PendingNotificationRequest>> Function()
    pendingRequestLoader,
    required Future<List<ActiveNotification>> Function()
    activeNotificationLoader,
    required Future<void> Function(int id) cancelNumericId,
    required Future<void> Function(
      MaasoNotification notification,
      DateTime target,
      bool repeatsDaily,
    )
    scheduledRequestDispatcher,
  }) : _cancelNumericId = cancelNumericId,
       super(
         pendingRequestLoader: pendingRequestLoader,
         activeNotificationLoader: activeNotificationLoader,
         pendingRequestCanceller: cancelNumericId,
         scheduledRequestDispatcher: scheduledRequestDispatcher,
       );

  final Future<void> Function(int id) _cancelNumericId;

  @override
  bool get isAvailable => true;

  @override
  Future<void> cancel(String deliveryId) =>
      _cancelNumericId(_numericId(deliveryId));
}

MaasoAuthSession _validSession(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime(2099),
);

int _numericId(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash == 0 ? 1 : hash;
}
