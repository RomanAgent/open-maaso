import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/scheduled_task_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'scope keys and delivery ids do not expose reversible account ids',
    () async {
      const accountUuid = 'account-private-0192837465';
      final shared = await SharedPreferences.getInstance();
      final delivery = _RecordingDelivery();
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession(accountUuid)),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      ).init();

      expect(
        (await service.schedule(
          when: '11:00',
          prompt: 'private reminder',
        ))['status'],
        'scheduled',
      );
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: accountUuid,
      );
      final deliveryId = delivery.scheduled.single.deliveryId;
      final encodedAccount = _legacyEncode(accountUuid);

      expect(storageKey, startsWith('scheduled_tasks.v4.'));
      expect(storageKey, isNot(contains(accountUuid)));
      expect(storageKey, isNot(contains(encodedAccount)));
      expect(deliveryId, startsWith('scheduled-task:v4:'));
      expect(deliveryId, isNot(contains(accountUuid)));
      expect(deliveryId, isNot(contains(encodedAccount)));

      service.onClose();
    },
  );

  test(
    'v3 records cancel legacy OS ids before migrating to hashed v4',
    () async {
      const environmentKey = 'test';
      const accountUuid = 'account-a';
      const taskId = 't7';
      final legacyStorageKey =
          'scheduled_tasks.v3.${_legacyEncode(environmentKey)}.'
          '${_legacyEncode(accountUuid)}';
      final legacyDeliveryId =
          'scheduled-task:${_legacyEncode(environmentKey)}:'
          '${_legacyEncode(accountUuid)}:$taskId';
      SharedPreferences.setMockInitialValues(<String, Object>{
        legacyStorageKey: jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'environmentKey': environmentKey,
            'accountUuid': accountUuid,
            'taskId': taskId,
            'when': '11:30',
            'repeat': 'daily',
            'prompt': 'migrated reminder',
            'targetAt': DateTime(2099, 1, 1, 11, 30).toUtc().toIso8601String(),
            'timezone': 'UTC',
            'timezoneOffsetMinutes': 0,
            'deliveryId': legacyDeliveryId,
            'systemScheduled': true,
            'status': 'scheduled',
          },
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _RecordingDelivery();
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession(accountUuid)),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      ).init();

      expect(delivery.cancelled, contains(legacyDeliveryId));
      expect(delivery.scheduled, hasLength(1));
      final migratedDeliveryId = delivery.scheduled.single.deliveryId;
      expect(migratedDeliveryId, startsWith('scheduled-task:v4:'));
      expect(migratedDeliveryId, isNot(legacyDeliveryId));
      expect(shared.getString(legacyStorageKey), isNull);

      final v4StorageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: environmentKey,
        accountUuid: accountUuid,
      );
      expect(shared.getString(v4StorageKey), isNotNull);
      final restored = (await service.list())['tasks']! as List;
      expect(restored, hasLength(1));
      expect((restored.single as Map)['deliveryId'], migratedDeliveryId);
      expect((restored.single as Map)['systemScheduled'], isTrue);

      service.onClose();
    },
  );

  test(
    'failed legacy cancellation keeps v3 state and retries migration',
    () async {
      const environmentKey = 'test';
      const accountUuid = 'account-retry';
      const taskId = 't3';
      final legacyStorageKey =
          'scheduled_tasks.v3.${_legacyEncode(environmentKey)}.'
          '${_legacyEncode(accountUuid)}';
      final legacyDeliveryId =
          'scheduled-task:${_legacyEncode(environmentKey)}:'
          '${_legacyEncode(accountUuid)}:$taskId';
      SharedPreferences.setMockInitialValues(<String, Object>{
        legacyStorageKey: jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'environmentKey': environmentKey,
            'accountUuid': accountUuid,
            'taskId': taskId,
            'when': '12:15',
            'repeat': 'daily',
            'prompt': 'retry migration',
            'targetAt': DateTime(2099, 1, 1, 12, 15).toUtc().toIso8601String(),
            'timezone': 'UTC',
            'timezoneOffsetMinutes': 0,
            'deliveryId': legacyDeliveryId,
            'systemScheduled': true,
            'status': 'scheduled',
          },
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _RecordingDelivery()..cancelFailuresRemaining = 1;
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession(accountUuid)),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      ).init();
      final v4StorageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: environmentKey,
        accountUuid: accountUuid,
      );

      expect(shared.getString(legacyStorageKey), isNotNull);
      expect(shared.getString(v4StorageKey), isNull);
      expect(
        jsonDecode(
          shared.getString('scheduled_tasks.pending_cancellations.v1')!,
        ),
        contains(legacyDeliveryId),
      );

      final retried = (await service.list())['tasks']! as List;
      expect(retried, hasLength(1));
      expect(shared.getString(legacyStorageKey), isNull);
      expect(shared.getString(v4StorageKey), isNotNull);
      expect(
        delivery.cancelled.where((id) => id == legacyDeliveryId).length,
        3,
      );

      service.onClose();
    },
  );
}

Future<NotificationPreferencesService> _enabledPreferences(
  SharedPreferences shared,
) async {
  final preferences = await NotificationPreferencesService.forTesting(
    preferences: shared,
  ).init();
  await preferences.setConsent(enabled: true, permissionGranted: true);
  return preferences;
}

MaasoAuthSession _validSession(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime(2099),
);

String _legacyEncode(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

final class _RecordingDelivery implements NotificationDelivery {
  final List<MaasoNotification> scheduled = <MaasoNotification>[];
  final List<String> cancelled = <String>[];
  int cancelFailuresRemaining = 0;

  @override
  bool get isAvailable => true;

  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();

  @override
  Future<void> cancel(String deliveryId) async {
    cancelled.add(deliveryId);
    if (cancelFailuresRemaining > 0) {
      cancelFailuresRemaining -= 1;
      throw StateError('legacy_cancel_failed');
    }
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) async {
    scheduled.add(notification);
  }

  @override
  Future<void> show(MaasoNotification notification) async {}

  @override
  NotificationInteraction? takeInitialInteraction() => null;
}
