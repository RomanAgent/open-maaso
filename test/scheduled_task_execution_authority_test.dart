import 'dart:async';
// Deterministic test clock supplied by flutter_test's existing locked dependency.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/scheduled_task_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('companion can browse saved tasks without timers or OS execution', () {
    fakeAsync((clock) {
      late _Fixture f;
      _Fixture.create().then((value) => f = value);
      clock.flushMicrotasks();
      final events = <SystemStatusEvent>[];
      final subscription = EventBus().on<SystemStatusEvent>().listen(
        events.add,
      );
      f.service.schedule(when: '10:01', prompt: 'saved task');
      clock.flushMicrotasks();
      Map<String, Object?>? list;
      f.service.list().then((value) => list = value);
      clock.flushMicrotasks();
      expect(list!['tasks'], hasLength(1));
      expect(f.delivery.active, isEmpty);
      clock.elapse(const Duration(minutes: 2));
      clock.flushMicrotasks();
      expect(events.where((e) => e.triggerType == 'scheduled_task'), isEmpty);
      f.service.list().then((value) => list = value);
      clock.flushMicrotasks();
      expect(list!['tasks'], hasLength(1));
      subscription.cancel();
      f.close();
      clock.flushMicrotasks();
    });
  });

  test(
    'same account owner loss cancels OS delivery and owner return rearms',
    () async {
      final f = await _Fixture.create();
      await f.service.schedule(when: '11:00', prompt: 'daily', repeat: 'daily');
      f.owner.value = true;
      await f.service.list();
      expect(f.delivery.active, hasLength(1));
      final id = f.delivery.active.single;
      f.owner.value = false;
      await f.service.list();
      expect(f.delivery.active, isEmpty);
      expect(f.delivery.cancelled, contains(id));
      expect((await f.service.list())['tasks'], hasLength(1));
      f.owner.value = true;
      await f.service.list();
      expect(f.delivery.active, contains(id));
      f.close();
    },
  );

  test(
    'legacy account drain does not permanently poison same-account ownership return',
    () async {
      final f = await _Fixture.create();
      f.owner.value = true;
      await f.service.list();
      await f.service.schedule(
        when: '11:00',
        prompt: 'keep across handoff',
        repeat: 'daily',
      );
      f.owner.value = false;
      await f.service.deactivateAccountAndDrain();
      expect(f.delivery.active, isEmpty);
      expect(
        (await f.service.list())['tasks'],
        hasLength(1),
        reason: 'The app remains available while the Agent is elsewhere.',
      );
      f.owner.value = true;
      await f.service.list();
      expect(f.delivery.active, hasLength(1));
      f.close();
    },
  );

  test(
    'revocation during an OS schedule compensates the late completion',
    () async {
      final f = await _Fixture.create();
      f.owner.value = true;
      await f.service.list();
      final gate = Completer<void>();
      f.delivery.gate = gate;
      final operation = f.service.schedule(
        when: '11:00',
        prompt: 'must not execute after lease loss',
      );
      await f.delivery.started.future;
      f.owner.value = false;
      gate.complete();
      final result = await operation;
      expect(result['error'], 'execution_authority_changed');
      expect(result['rollback'], 'completed');
      await f.service.list();
      expect(f.delivery.active, isEmpty);
      f.close();
    },
  );

  test(
    'old authority notifier and closed service cannot rearm another mount',
    () async {
      final f = await _Fixture.create();
      await f.service.schedule(when: '11:00', prompt: 'new binding');
      final nextOwner = ValueNotifier(false);
      await f.service.bindExecutionAuthority(
        allowed: () => nextOwner.value,
        changes: nextOwner,
      );
      f.owner.value = true;
      await f.service.list();
      expect(f.delivery.active, isEmpty);
      f.service.onClose();
      nextOwner.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(f.delivery.active, isEmpty);
      nextOwner.dispose();
      f.owner.dispose();
    },
  );

  test(
    'already queued timer cannot fire after immediate authority revocation',
    () {
      fakeAsync((clock) {
        late _Fixture f;
        _Fixture.create().then((value) => f = value);
        clock.flushMicrotasks();
        final events = <SystemStatusEvent>[];
        final subscription = EventBus().on<SystemStatusEvent>().listen(
          events.add,
        );
        f.owner.value = true;
        clock.flushMicrotasks();
        f.service.schedule(when: '10:01', prompt: 'one owner only');
        clock.flushMicrotasks();
        f.owner.value = false;
        clock.elapse(const Duration(minutes: 1));
        clock.flushMicrotasks();
        expect(events.where((e) => e.triggerType == 'scheduled_task'), isEmpty);
        expect(f.delivery.active, isEmpty);
        subscription.cancel();
        f.close();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'account switch never reschedules old account tasks under new ownership',
    () async {
      final f = await _Fixture.create();
      f.owner.value = true;
      await f.service.list();
      await f.service.schedule(when: '11:00', prompt: 'account A only');
      f.owner.value = false;
      f.session.value = _session('account-b');
      await f.service.list();
      f.owner.value = true;
      final list = await f.service.list();
      expect(list['tasks'], isEmpty);
      expect(f.delivery.active, isEmpty);
      f.close();
    },
  );
}

MaasoAuthSession _session(String id) => MaasoAuthSession(
  accountUuid: id,
  accessToken: 'fixture-access',
  refreshToken: 'fixture-refresh',
  expiresAt: DateTime(2099),
);

class _Fixture {
  _Fixture(this.service, this.delivery, this.owner, this.session);
  final ScheduledTaskService service;
  final _Delivery delivery;
  final ValueNotifier<bool> owner;
  final Rxn<MaasoAuthSession> session;
  static Future<_Fixture> create() async {
    final prefs = await SharedPreferences.getInstance();
    final preferences = await NotificationPreferencesService.forTesting(
      preferences: prefs,
    ).init();
    await preferences.setConsent(enabled: true, permissionGranted: true);
    final delivery = _Delivery();
    final owner = ValueNotifier(false);
    final session = Rxn<MaasoAuthSession>(_session('account-a'));
    final service = await ScheduledTaskService(
      delivery: delivery,
      notificationPreferences: preferences,
      sharedPreferences: prefs,
      session: session,
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      executionAllowed: () => false,
    ).init();
    await service.bindExecutionAuthority(
      allowed: () => owner.value,
      changes: owner,
    );
    return _Fixture(service, delivery, owner, session);
  }

  void close() {
    service.onClose();
    owner.dispose();
  }
}

class _Delivery
    implements NotificationDelivery, ScheduledNotificationQuarantine {
  final active = <String>{};
  final cancelled = <String>[];
  Completer<void>? gate;
  final started = Completer<void>();
  @override
  bool get isAvailable => true;
  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show(MaasoNotification notification) async {}
  @override
  NotificationInteraction? takeInitialInteraction() => null;
  @override
  Future<ScheduledNotificationQuarantineResult>
  quarantinePendingScheduledNotifications() async {
    active.clear();
    return ScheduledNotificationQuarantineResult.swept;
  }

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) async {
    if (!started.isCompleted) started.complete();
    await gate?.future;
    active.add(notification.deliveryId);
  }

  @override
  Future<void> cancel(String id) async {
    active.remove(id);
    cancelled.add(id);
  }
}
