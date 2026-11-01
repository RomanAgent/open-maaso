import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_execution_context.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/scheduled_task_service.dart';
import 'package:maaso/src/features/agent/application/skills/scheduled_task_skill.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pendingCancellationStorageKey =
    'scheduled_tasks.pending_cancellations.v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'persists an account/environment scoped target and awaits OS delivery',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final environment = MaasoEnvironment.test.obs;
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: preferences,
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => DateTime(2026, 8, 10, 10),
      ).init();

      final result = await service.schedule(
        when: '11:15',
        prompt: '喝水',
        repeat: 'daily',
      );

      expect(result['status'], 'scheduled');
      expect(result['delivery'], 'system_and_foreground');
      expect(result['targetAt'], '2026-08-10T11:15:00.000');
      expect(delivery.scheduled, hasLength(1));
      final scheduled = delivery.scheduled.single;
      expect(scheduled.repeatsDaily, isTrue);
      expect(scheduled.notification.prompt, '喝水');
      expect(scheduled.notification.data, <String, Object?>{
        'taskId': 't1',
        'environmentKey': 'test',
        'accountUuid': 'account-a',
      });
      expect(scheduled.notification.deliveryId, startsWith('scheduled-task:'));
      final task = ((await service.list())['tasks']! as List).single as Map;
      expect(task['environmentKey'], 'test');
      expect(task['accountUuid'], 'account-a');
      expect(task['deliveryId'], scheduled.notification.deliveryId);
      expect(task['systemScheduled'], isTrue);
      expect(
        DateTime.parse(task['targetAt']! as String).toLocal(),
        DateTime(2026, 8, 10, 11, 15),
      );

      final scopedStorageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      expect(shared.getString(scopedStorageKey), isNotNull);
      expect(shared.getString('scheduled_tasks.v2'), isNull);

      final cancelled = await service.cancel('t1');
      expect(cancelled['status'], 'cancelled');
      expect(delivery.cancelled, contains(scheduled.notification.deliveryId));
      expect(jsonDecode(shared.getString(scopedStorageKey)!), isEmpty);
      service.onClose();
    },
  );

  test(
    'revoked capability fence compensates an in-flight OS schedule',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _GatedScheduleDelivery(gateFirstSchedule: true);
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(seconds: 2),
      ).init();
      var capabilityCurrent = true;

      final scheduling = service.schedule(
        when: '11:15',
        prompt: 'must be compensated',
        commitFenceIsCurrent: () => capabilityCurrent,
      );
      await delivery.gatedScheduleStarted.future;
      capabilityCurrent = false;
      delivery.releaseGatedSchedule();

      final result = await scheduling;
      final deliveryId = delivery.scheduled.single.notification.deliveryId;
      expect(result['error'], 'capability_unavailable');
      expect(result['rollback'], 'completed');
      expect(delivery.cancelled, contains(deliveryId));
      expect(delivery.active, isNot(contains(deliveryId)));
      expect((await service.list())['tasks'], isEmpty);
      service.onClose();
    },
  );

  test(
    'snapshot refresh during OS cancel restores the exact task and surfaces stale',
    () async {
      appServices.testMode = true;
      addTearDown(appServices.reset);
      final shared = await SharedPreferences.getInstance();
      final delivery = _GatedScheduleDelivery(gateFirstCancel: true);
      final service = appServices.put<ScheduledTaskService>(
        await ScheduledTaskService(
          delivery: delivery,
          notificationPreferences: await _enabledPreferences(shared),
          sharedPreferences: shared,
          session: Rxn<MaasoAuthSession>(_validSession('account-a')),
          environmentSignal: MaasoEnvironment.test.obs,
          clock: () => DateTime(2026, 8, 10, 10),
          deliveryTimeout: const Duration(seconds: 2),
        ).init(),
      );
      final scheduled = await service.schedule(
        when: '11:15',
        prompt: 'keep this exact reminder',
        repeat: 'daily',
      );
      final taskId = scheduled['taskId']! as String;
      final originalCall = delivery.scheduled.single;
      final deliveryId = originalCall.notification.deliveryId;
      final snapshots = AppCapabilitySnapshotService(
        resolver: AppPlatformCapabilitySnapshotResolver(
          routeIds: const <String>{},
          skillIds: const <String>{'scheduled_task'},
        ),
        initialContext: AppCapabilitySnapshotContext(
          hostPlatform: AppHostPlatform.macos,
          rolloutGeneration: 0,
        ),
      );
      addTearDown(snapshots.closeLifecycle);
      final lease = snapshots.acquireLease(<AppCapabilityKey>{
        AppCapabilityKey.skill('scheduled_task'),
      }).lease!;
      final skill = ScheduledTaskSkill(agentId: 'self');

      final cancelling = AppCapabilityExecutionContext.run<String>(
        service: snapshots,
        lease: lease,
        operation: () async =>
            await skill.methods['cancelTask']!(<dynamic>[
                  jsonEncode(<String, Object?>{'taskId': taskId}),
                ])
                as String,
      );
      await delivery.gatedCancelStarted.future;
      snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
      delivery.releaseGatedCancel();

      await expectLater(
        cancelling,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'capability_snapshot_stale',
          ),
        ),
      );
      final tasks = (await service.list())['tasks']! as List;
      expect(tasks, hasLength(1));
      expect((tasks.single as Map)['taskId'], taskId);
      expect(tasks.single['systemScheduled'], isTrue);
      expect(delivery.active, contains(deliveryId));
      expect(delivery.scheduled, hasLength(2));
      final restoredCall = delivery.scheduled.last;
      expect(restoredCall.notification.deliveryId, deliveryId);
      expect(
        restoredCall.notification.prompt,
        originalCall.notification.prompt,
      );
      expect(restoredCall.notification.data, originalCall.notification.data);
      expect(restoredCall.target, originalCall.target);
      expect(restoredCall.repeatsDaily, originalCall.repeatsDaily);
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      expect((jsonDecode(shared.getString(storageKey)!) as List), hasLength(1));
    },
  );

  test(
    'restored overdue one-time task is marked missed, not replayed',
    () async {
      final shared = await SharedPreferences.getInstance();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final environment = MaasoEnvironment.test.obs;
      final writer = await ScheduledTaskService(
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => DateTime(2026, 8, 10, 8),
      ).init();
      expect(
        (await writer.schedule(when: '09:00', prompt: '旧提醒'))['status'],
        'scheduled',
      );
      writer.onClose();

      final reader = await ScheduledTaskService(
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => DateTime(2026, 8, 10, 10),
      ).init();

      final tasks = (await reader.list())['tasks']! as List;
      expect(tasks, hasLength(1));
      expect((tasks.single as Map)['status'], 'missed');
      reader.onClose();
    },
  );

  test(
    'unscoped legacy records are never assigned to a signed-in user',
    () async {
      final legacy = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'taskId': 't4',
          'when': '09:00',
          'repeat': 'once',
          'prompt': '不应归属给新账号',
        },
      ]);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'scheduled_tasks.v1': legacy,
        'scheduled_tasks.v2': legacy,
      });
      final shared = await SharedPreferences.getInstance();
      final service = await ScheduledTaskService(
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
      ).init();

      expect((await service.list())['tasks'], isEmpty);
      expect(shared.getString('scheduled_tasks.v1'), legacy);
      expect(shared.getString('scheduled_tasks.v2'), legacy);
      service.onClose();
    },
  );

  test(
    'no valid session fails closed without loading or writing tasks',
    () async {
      final shared = await SharedPreferences.getInstance();
      final service = await ScheduledTaskService(
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
      ).init();

      expect((await service.list())['error'], 'sign_in_required');
      expect(
        (await service.schedule(when: '11:00', prompt: '不可创建'))['error'],
        'sign_in_required',
      );
      expect((await service.cancel('t1'))['error'], 'sign_in_required');
      expect(
        shared.getKeys().where((key) => key.startsWith('scheduled_tasks.v3')),
        isEmpty,
      );
      service.onClose();
    },
  );

  test(
    'A sign-out then B isolates storage, timers, OS ids and payloads',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final environment = MaasoEnvironment.test.obs;
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: preferences,
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => DateTime(2026, 8, 10, 10),
      ).init();

      expect(
        (await service.schedule(when: '11:00', prompt: 'A 的提醒'))['status'],
        'scheduled',
      );
      final aDelivery = delivery.scheduled.last.notification;

      session.value = null;
      expect((await service.list())['error'], 'sign_in_required');
      expect(delivery.cancelled, contains(aDelivery.deliveryId));

      session.value = _validSession('account-b');
      expect((await service.list())['tasks'], isEmpty);
      expect(
        (await service.schedule(when: '12:00', prompt: 'B 的提醒'))['status'],
        'scheduled',
      );
      final bDelivery = delivery.scheduled.last.notification;
      expect(bDelivery.deliveryId, isNot(aDelivery.deliveryId));
      expect(bDelivery.data['accountUuid'], 'account-b');
      expect(bDelivery.data['environmentKey'], 'test');

      session.value = _validSession('account-a');
      final restoredA = (await service.list())['tasks']! as List;
      expect(restoredA, hasLength(1));
      expect((restoredA.single as Map)['prompt'], 'A 的提醒');
      expect((restoredA.single as Map)['accountUuid'], 'account-a');
      service.onClose();
    },
  );

  test(
    'account drain waits for a late A schedule and compensates before B',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _GatedScheduleDelivery(gateFirstSchedule: true);
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: session,
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(milliseconds: 20),
      ).init();

      final aResult = await service.schedule(when: '11:00', prompt: 'A 的延迟提醒');
      final aDeliveryId = delivery.scheduled.single.notification.deliveryId;
      expect(aResult['error'], 'delivery_timeout');
      expect(aResult['rollback'], 'pending');

      var drainCompleted = false;
      final drain = service.deactivateAccountAndDrain().then((_) {
        drainCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(drainCompleted, isFalse);

      session.value = _validSession('account-b');
      delivery.releaseGatedSchedule();
      await drain;

      expect(delivery.active, isNot(contains(aDeliveryId)));
      expect(delivery.cancelled.where((id) => id == aDeliveryId).length, 2);
      final bResult = await service.schedule(when: '12:00', prompt: 'B 的提醒');
      expect(bResult['status'], 'scheduled');
      expect(
        delivery.scheduled.last.notification.data['accountUuid'],
        'account-b',
      );
      expect(delivery.active, isNot(contains(aDeliveryId)));
      service.onClose();
    },
  );

  test(
    'account drain failure propagates and its cleanup is retryable',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _GatedScheduleDelivery()..cancelFailuresRemaining = 1;
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(milliseconds: 20),
      ).init();
      await service.schedule(when: '11:00', prompt: 'A 的提醒');
      final deliveryId = delivery.scheduled.single.notification.deliveryId;

      await expectLater(
        service.deactivateAccountAndDrain(),
        throwsA(
          isA<ScheduledTaskAccountDrainFailure>()
              .having((failure) => failure.code, 'code', 'scope_cleanup_failed')
              .having(
                (failure) => failure.cause,
                'cause',
                'delivery_cancel_failed',
              ),
        ),
      );
      expect(delivery.active, contains(deliveryId));

      await service.deactivateAccountAndDrain();

      expect(delivery.cancelled.where((id) => id == deliveryId).length, 2);
      expect(delivery.active, isNot(contains(deliveryId)));
      expect(delivery.scheduled, hasLength(1));
      service.onClose();
    },
  );

  test(
    'test to production waits for the matching session before loading',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final environment = MaasoEnvironment.test.obs;
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: preferences,
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => DateTime(2026, 8, 10, 10),
      ).init();

      await service.schedule(when: '11:00', prompt: '测试环境提醒');
      final testDeliveryId = delivery.scheduled.last.notification.deliveryId;

      environment.value = MaasoEnvironment.production;
      expect((await service.list())['error'], 'sign_in_required');
      expect(delivery.cancelled, contains(testDeliveryId));

      // Mirrors AuthSessionService.activateCurrentEnvironment publishing the
      // session belonging to the new environment.
      session.value = _validSession('account-a');
      expect((await service.list())['tasks'], isEmpty);
      await service.schedule(when: '12:00', prompt: '生产环境提醒');
      final prodDelivery = delivery.scheduled.last.notification;
      expect(prodDelivery.deliveryId, isNot(testDeliveryId));
      expect(prodDelivery.data['environmentKey'], 'prod');

      environment.value = MaasoEnvironment.test;
      expect((await service.list())['error'], 'sign_in_required');
      session.value = _validSession('account-a');
      final restoredTest = (await service.list())['tasks']! as List;
      expect(restoredTest, hasLength(1));
      expect((restoredTest.single as Map)['prompt'], '测试环境提醒');
      service.onClose();
    },
  );

  test('an A timer cannot fire after sign-out and B activation', () async {
    final shared = await SharedPreferences.getInstance();
    final delivery = _FakeDelivery();
    final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
    final events = <SystemStatusEvent>[];
    final subscription = EventBus().on<SystemStatusEvent>().listen(events.add);
    final service = await ScheduledTaskService(
      delivery: delivery,
      sharedPreferences: shared,
      session: session,
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10, 59, 59),
      isForeground: () => true,
    ).init();
    await service.schedule(when: '11:00', prompt: 'A 私有提醒');

    session.value = null;
    expect((await service.list())['error'], 'sign_in_required');
    session.value = _validSession('account-b');
    expect((await service.list())['tasks'], isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(events, isEmpty);
    await subscription.cancel();
    service.onClose();
  });

  test(
    'delivery scheduling failure is rolled back with a stable error',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery()..throwOnSchedule = true;
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(milliseconds: 30),
      ).init();

      final result = await service.schedule(when: '11:00', prompt: '不会残留');

      expect(result['error'], 'delivery_schedule_failed');
      expect((await service.list())['tasks'], isEmpty);
      expect(delivery.cancelled, hasLength(1));
      service.onClose();
    },
  );

  test('hung delivery is bounded and does not persist a task', () async {
    final shared = await SharedPreferences.getInstance();
    final delivery = _FakeDelivery()..hangSchedule = true;
    final service = await ScheduledTaskService(
      delivery: delivery,
      notificationPreferences: await _enabledPreferences(shared),
      sharedPreferences: shared,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      deliveryTimeout: const Duration(milliseconds: 30),
    ).init();
    final stopwatch = Stopwatch()..start();

    final result = await service.schedule(when: '11:00', prompt: '超时回滚');

    stopwatch.stop();
    expect(result['error'], 'delivery_timeout');
    expect(result['rollback'], 'pending');
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(delivery.cancelled, hasLength(1));
    final deliveryId = delivery.scheduled.single.notification.deliveryId;
    expect(
      jsonDecode(shared.getString(_pendingCancellationStorageKey)!),
      contains(deliveryId),
    );
    expect((await service.list())['error'], 'scope_cleanup_failed');

    // A timed-out plugin Future can still finish later. It must trigger a
    // second compensating cancellation rather than orphaning an OS reminder.
    delivery.completeHungSchedule();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(delivery.cancelled, hasLength(2));
    expect((await service.list())['tasks'], isEmpty);
    expect(shared.getString(_pendingCancellationStorageKey), isNull);
    service.onClose();
  });

  test(
    'restart drains a late schedule journal left through service teardown',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery()..hangSchedule = true;
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final environment = MaasoEnvironment.test.obs;
      final writer = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: preferences,
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(milliseconds: 30),
      ).init();

      final result = await writer.schedule(when: '11:00', prompt: '重启后清理');
      final deliveryId = delivery.scheduled.single.notification.deliveryId;

      expect(result['error'], 'delivery_timeout');
      expect(result['rollback'], 'pending');
      expect(
        jsonDecode(shared.getString(_pendingCancellationStorageKey)!),
        contains(deliveryId),
      );

      writer.onClose();
      delivery.throwOnCancel = true;
      delivery.completeHungSchedule();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(delivery.cancelled, hasLength(2));
      expect(
        jsonDecode(shared.getString(_pendingCancellationStorageKey)!),
        contains(deliveryId),
      );

      delivery.throwOnCancel = false;
      final reader = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: preferences,
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(milliseconds: 30),
      ).init();

      expect(delivery.cancelled, hasLength(3));
      expect(shared.getString(_pendingCancellationStorageKey), isNull);
      expect((await reader.list())['tasks'], isEmpty);
      reader.onClose();
    },
  );

  test(
    'failed cancel leaves the task intact and reports a stable error',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(milliseconds: 30),
      ).init();
      await service.schedule(when: '11:00', prompt: '保留提醒');
      delivery.throwOnCancel = true;

      final result = await service.cancel('t1');

      expect(result['error'], 'delivery_cancel_failed');
      expect((await service.list())['tasks'], hasLength(1));
      service.onClose();
    },
  );

  test(
    'scope cleanup timeout blocks B until old OS cancellation succeeds',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: session,
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(milliseconds: 30),
      ).init();
      await service.schedule(when: '11:00', prompt: 'A 私有提醒');
      delivery.hangCancel = true;
      session.value = null;
      session.value = _validSession('account-b');
      final stopwatch = Stopwatch()..start();

      final blocked = await service.list();

      stopwatch.stop();
      expect(blocked['error'], 'scope_cleanup_failed');
      expect(blocked['cause'], 'delivery_timeout');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(
        (await service.schedule(when: '12:00', prompt: 'B 暂不可创建'))['error'],
        'scope_cleanup_failed',
      );

      delivery.hangCancel = false;
      expect((await service.list())['tasks'], isEmpty);
      expect(
        (await service.schedule(when: '12:00', prompt: 'B 可创建'))['status'],
        'scheduled',
      );
      service.onClose();
    },
  );

  test(
    'a timer that fires in background never reaches EventBus runtime path',
    () async {
      final shared = await SharedPreferences.getInstance();
      final events = <SystemStatusEvent>[];
      final subscription = EventBus().on<SystemStatusEvent>().listen(
        events.add,
      );
      final service = await ScheduledTaskService(
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10, 59, 59),
        isForeground: () => false,
      ).init();

      await service.schedule(when: '11:00', prompt: '后台提醒');
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(events, isEmpty);
      await subscription.cancel();
      service.onClose();
    },
  );

  test('preference off to on sync journals before OS dispatch', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await NotificationPreferencesService.forTesting(
      preferences: shared,
    ).init();
    final delivery = _FakeDelivery();
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: 'test',
      accountUuid: 'account-sync-toggle',
    );
    final service = await ScheduledTaskService(
      delivery: delivery,
      notificationPreferences: preferences,
      sharedPreferences: shared,
      session: Rxn<MaasoAuthSession>(_validSession('account-sync-toggle')),
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
    ).init();
    final scheduled = await service.schedule(
      when: '11:00',
      prompt: 'Enable OS delivery later',
    );
    expect(scheduled['delivery'], 'foreground_only');

    final dispatchObserved = Completer<void>();
    delivery.onSchedule = (notification) async {
      expect(
        jsonDecode(shared.getString(_pendingCancellationStorageKey)!),
        contains(notification.deliveryId),
      );
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isFalse,
      );
      dispatchObserved.complete();
    };

    await preferences.setConsent(enabled: true, permissionGranted: true);
    await dispatchObserved.future;
    final tasks = (await service.list())['tasks']! as List;

    expect(tasks.single['systemScheduled'], isTrue);
    expect(
      (jsonDecode(shared.getString(storageKey)!) as List)
          .single['systemScheduled'],
      isTrue,
    );
    expect(shared.getString(_pendingCancellationStorageKey), isNull);

    service.onClose();
  });

  test('sync persistence failure stays false and restart cancels A', () async {
    const accountA = 'account-sync-persist-a';
    const accountB = 'account-sync-persist-b';
    const taskId = 't1';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: 'test',
      accountUuid: accountA,
    );
    final deliveryId = _v4DeliveryIdForTest(storageKey, taskId);
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[
        _storedV4Task(
          accountUuid: accountA,
          storageKey: storageKey,
          taskId: taskId,
          prompt: 'Persist-failure reminder',
          systemScheduled: false,
        ),
      ]),
    });
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final delivery = _FakeDelivery()..throwOnCancel = true;
    var failTruePersistence = true;
    delivery.onSchedule = (notification) async {
      expect(notification.deliveryId, deliveryId);
      expect(
        jsonDecode(shared.getString(_pendingCancellationStorageKey)!),
        contains(deliveryId),
      );
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isFalse,
      );
    };
    final first = await ScheduledTaskService(
      delivery: delivery,
      notificationPreferences: preferences,
      sharedPreferences: shared,
      session: Rxn<MaasoAuthSession>(_validSession(accountA)),
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      preferenceWriter: (key, value) async {
        if (key == storageKey &&
            failTruePersistence &&
            value.contains('"systemScheduled":true')) {
          failTruePersistence = false;
          return false;
        }
        return shared.setString(key, value);
      },
    ).init();

    expect(delivery.scheduled, hasLength(1));
    expect(delivery.cancelled, contains(deliveryId));
    expect(
      (jsonDecode(shared.getString(storageKey)!) as List)
          .single['systemScheduled'],
      isFalse,
    );
    expect(
      jsonDecode(shared.getString(_pendingCancellationStorageKey)!),
      contains(deliveryId),
    );
    first.onClose();

    final cleanupDelivery = _FakeDelivery();
    final restarted = await ScheduledTaskService(
      delivery: cleanupDelivery,
      notificationPreferences: await _enabledPreferences(shared),
      sharedPreferences: shared,
      session: Rxn<MaasoAuthSession>(_validSession(accountB)),
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
    ).init();

    expect(cleanupDelivery.cancelled, contains(deliveryId));
    expect((await restarted.list())['tasks'], isEmpty);
    expect(shared.getString(_pendingCancellationStorageKey), isNull);
    expect(
      (jsonDecode(shared.getString(storageKey)!) as List)
          .single['systemScheduled'],
      isFalse,
    );

    restarted.onClose();
  });

  test(
    'active-scope platform sweep resets memory before rescheduling',
    () async {
      const accountA = 'account-active-sweep';
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: accountA,
      );
      final deliveryId = _v4DeliveryIdForTest(storageKey, 't1');
      SharedPreferences.setMockInitialValues(<String, Object>{
        storageKey: jsonEncode(<Map<String, Object?>>[
          _storedV4Task(
            accountUuid: accountA,
            storageKey: storageKey,
            taskId: 't1',
            prompt: 'active task must be rearmed',
            systemScheduled: true,
          ),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final service = await ScheduledTaskService(
        delivery: delivery,
        notificationPreferences: await _enabledPreferences(shared),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession(accountA)),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        deliveryTimeout: const Duration(milliseconds: 20),
      ).init();
      expect(delivery.scheduled, isEmpty);

      delivery
        ..supportsPlatformSweep = true
        ..hangSchedule = true;
      expect(
        (await service.schedule(
          when: '12:00',
          prompt: 'force cache miss',
        ))['error'],
        'delivery_timeout',
      );
      expect((await service.list())['error'], 'scope_cleanup_failed');

      delivery.completeHungSchedule();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      delivery
        ..hangSchedule = false
        ..scheduled.clear()
        ..onSchedule = (notification) async {
          expect(notification.deliveryId, deliveryId);
          expect(
            (jsonDecode(shared.getString(storageKey)!) as List)
                .single['systemScheduled'],
            isFalse,
          );
        };

      final listed = await service.list();

      expect(delivery.platformSweepAttempts, greaterThan(0));
      expect(delivery.scheduled, hasLength(1));
      expect((listed['tasks']! as List).single['systemScheduled'], isTrue);
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isTrue,
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

Map<String, Object?> _storedV4Task({
  required String accountUuid,
  required String storageKey,
  required String taskId,
  required String prompt,
  required bool systemScheduled,
}) => <String, Object?>{
  'environmentKey': 'test',
  'accountUuid': accountUuid,
  'taskId': taskId,
  'when': '11:00',
  'repeat': 'daily',
  'prompt': prompt,
  'targetAt': DateTime(2099, 1, 1, 11).toUtc().toIso8601String(),
  'timezone': 'UTC',
  'timezoneOffsetMinutes': 0,
  'deliveryId': _v4DeliveryIdForTest(storageKey, taskId),
  'systemScheduled': systemScheduled,
  'status': 'scheduled',
};

String _v4DeliveryIdForTest(String storageKey, String taskId) =>
    'scheduled-task:v4:${storageKey.split('.').last}:$taskId';

class _ScheduledCall {
  const _ScheduledCall({
    required this.notification,
    required this.target,
    required this.repeatsDaily,
  });

  final MaasoNotification notification;
  final DateTime target;
  final bool repeatsDaily;
}

class _GatedScheduleDelivery implements NotificationDelivery {
  _GatedScheduleDelivery({
    this.gateFirstSchedule = false,
    this.gateFirstCancel = false,
  });

  final bool gateFirstSchedule;
  final bool gateFirstCancel;
  final List<_ScheduledCall> scheduled = <_ScheduledCall>[];
  final List<String> cancelled = <String>[];
  final Map<String, MaasoNotification> active = <String, MaasoNotification>{};
  final Completer<void> gatedScheduleStarted = Completer<void>();
  final Completer<void> _gatedScheduleRelease = Completer<void>();
  final Completer<void> gatedCancelStarted = Completer<void>();
  final Completer<void> _gatedCancelRelease = Completer<void>();
  int cancelFailuresRemaining = 0;
  bool _firstScheduleSeen = false;
  bool _firstCancelSeen = false;

  @override
  bool get isAvailable => true;

  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();

  @override
  Future<void> cancel(String deliveryId) async {
    cancelled.add(deliveryId);
    if (gateFirstCancel && !_firstCancelSeen) {
      _firstCancelSeen = true;
      if (!gatedCancelStarted.isCompleted) gatedCancelStarted.complete();
      await _gatedCancelRelease.future;
    } else {
      _firstCancelSeen = true;
    }
    if (cancelFailuresRemaining > 0) {
      cancelFailuresRemaining--;
      throw StateError('platform_cancel_failed');
    }
    active.remove(deliveryId);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => true;

  void releaseGatedSchedule() {
    if (!_gatedScheduleRelease.isCompleted) _gatedScheduleRelease.complete();
  }

  void releaseGatedCancel() {
    if (!_gatedCancelRelease.isCompleted) _gatedCancelRelease.complete();
  }

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) async {
    scheduled.add(
      _ScheduledCall(
        notification: notification,
        target: target,
        repeatsDaily: repeatsDaily,
      ),
    );
    if (gateFirstSchedule && !_firstScheduleSeen) {
      _firstScheduleSeen = true;
      if (!gatedScheduleStarted.isCompleted) gatedScheduleStarted.complete();
      await _gatedScheduleRelease.future;
    } else {
      _firstScheduleSeen = true;
    }
    active[notification.deliveryId] = notification;
  }

  @override
  Future<void> show(MaasoNotification notification) async {}

  @override
  NotificationInteraction? takeInitialInteraction() => null;
}

class _FakeDelivery
    implements NotificationDelivery, ScheduledNotificationQuarantine {
  final scheduled = <_ScheduledCall>[];
  final cancelled = <String>[];
  bool throwOnSchedule = false;
  bool hangSchedule = false;
  bool throwOnCancel = false;
  bool hangCancel = false;
  bool supportsPlatformSweep = false;
  int platformSweepAttempts = 0;
  Future<void> Function(MaasoNotification notification)? onSchedule;
  Completer<void>? _scheduleGate;

  @override
  bool get isAvailable => true;

  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<ScheduledNotificationQuarantineResult>
  quarantinePendingScheduledNotifications() async {
    platformSweepAttempts++;
    return supportsPlatformSweep
        ? ScheduledNotificationQuarantineResult.swept
        : ScheduledNotificationQuarantineResult.notAuthoritative;
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(MaasoNotification notification) async {}

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) async {
    await onSchedule?.call(notification);
    scheduled.add(
      _ScheduledCall(
        notification: notification,
        target: target,
        repeatsDaily: repeatsDaily,
      ),
    );
    if (throwOnSchedule) throw StateError('platform_schedule_failed');
    if (hangSchedule) {
      _scheduleGate ??= Completer<void>();
      return _scheduleGate!.future;
    }
  }

  void completeHungSchedule() {
    final gate = _scheduleGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> cancel(String deliveryId) async {
    cancelled.add(deliveryId);
    if (throwOnCancel) throw StateError('platform_cancel_failed');
    if (hangCancel) return Completer<void>().future;
  }

  @override
  NotificationInteraction? takeInitialInteraction() => null;
}
