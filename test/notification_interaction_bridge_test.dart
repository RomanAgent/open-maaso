import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/app_foreground_service.dart';
import 'package:maaso/src/core/notifications/firebase_bootstrap_service.dart';
import 'package:maaso/src/core/notifications/firebase_notification_bridge.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('notification payload canonical fields cannot be overridden', () {
    final interaction = NotificationInteraction.fromPayload(
      const MaasoNotification(
        deliveryId: 'proactive:v3:test.account-a:morning:1',
        kind: MaasoNotificationKind.morningGreeting,
        title: 'title',
        body: 'body',
        prompt: 'canonical prompt',
        data: <String, Object?>{
          'deliveryId': 'forged-delivery',
          'kind': 'remote',
          'prompt': 'forged prompt',
          'outreachId': 'outreach-1',
        },
      ).toPayload(),
    );

    expect(interaction, isNotNull);
    expect(interaction!.deliveryId, 'proactive:v3:test.account-a:morning:1');
    expect(interaction.kind, MaasoNotificationKind.morningGreeting);
    expect(interaction.prompt, 'canonical prompt');
    expect(interaction.data['outreachId'], 'outreach-1');

    final blankPrompt = NotificationInteraction.fromPayload(
      const MaasoNotification(
        deliveryId: 'scheduled-task:blank-prompt',
        kind: MaasoNotificationKind.scheduledTask,
        title: 'title',
        body: 'body',
        prompt: '   ',
        data: <String, Object?>{'prompt': 'forged prompt'},
      ).toPayload(),
    );
    expect(blankPrompt?.prompt, isNull);
    expect(blankPrompt?.data['prompt'], isNull);
  });

  test(
    'cold-start interaction waits for runtime consumer then replays once',
    () async {
      final preferences = await NotificationPreferencesService.forTesting()
          .init();
      var consumerReady = false;
      final delivery = _FakeDelivery(
        initialInteraction: const NotificationInteraction(
          deliveryId: 'scheduled-task:cold-start',
          kind: MaasoNotificationKind.scheduledTask,
          prompt: '喝水',
          data: <String, Object?>{
            'accountUuid': 'account-a',
            'environmentKey': 'test',
          },
        ),
      );
      final foreground = AppForegroundService()..isForeground.value = true;
      final events = <SystemStatusEvent>[];
      final eventSubscription = EventBus().on<SystemStatusEvent>().listen(
        events.add,
      );
      final bridge = await FirebaseNotificationBridge(
        preferences: preferences,
        delivery: delivery,
        foreground: foreground,
        session: Rxn<MaasoAuthSession>(_session()),
        environmentSignal: MaasoEnvironment.test.obs,
        interactionConsumerReady: () => consumerReady,
        consumerReadyPollInterval: const Duration(milliseconds: 5),
      ).init();

      bridge.activateForegroundBridge();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, isEmpty);

      consumerReady = true;
      await _eventually(() => events.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.single.payload?['deliveryId'], 'scheduled-task:cold-start');

      bridge.onClose();
      await eventSubscription.cancel();
      await delivery.close();
    },
  );

  test(
    'local notification taps bridge without Firebase configuration',
    () async {
      final preferences = await NotificationPreferencesService.forTesting()
          .init();
      final delivery = _FakeDelivery();
      final foreground = AppForegroundService()..isForeground.value = true;
      final events = <SystemStatusEvent>[];
      final eventSubscription = EventBus().on<SystemStatusEvent>().listen(
        events.add,
      );
      final bridge = await FirebaseNotificationBridge(
        preferences: preferences,
        delivery: delivery,
        foreground: foreground,
        session: Rxn<MaasoAuthSession>(_session()),
        environmentSignal: MaasoEnvironment.test.obs,
        interactionConsumerReady: () => true,
      ).init();
      bridge.activateForegroundBridge();

      delivery.add(
        const NotificationInteraction(
          deliveryId: 'scheduled-task:t1',
          kind: MaasoNotificationKind.scheduledTask,
          prompt: '喝水',
          data: <String, Object?>{
            'accountUuid': 'account-a',
            'environmentKey': 'test',
            'deliveryId': 'forged-delivery',
            'kind': 'remote',
            'prompt': 'forged prompt',
            'outreachId': 'outreach-1',
            'sourceEventId': 'os:v3:test.account-a:morning:1',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.triggerType, 'notification_opened');
      expect(events.single.payload?['deliveryId'], 'scheduled-task:t1');
      expect(events.single.payload?['kind'], 'scheduled_task');
      expect(events.single.payload?['prompt'], '喝水');
      expect(events.single.payload?['outreachId'], 'outreach-1');
      expect(
        events.single.payload?['sourceEventId'],
        'os:v3:test.account-a:morning:1',
      );

      bridge.onClose();
      await eventSubscription.cancel();
      await delivery.close();
    },
  );

  test(
    'background interaction waits until foreground before EventBus',
    () async {
      final preferences = await NotificationPreferencesService.forTesting()
          .init();
      final delivery = _FakeDelivery();
      final foreground = AppForegroundService()..isForeground.value = false;
      final events = <SystemStatusEvent>[];
      final eventSubscription = EventBus().on<SystemStatusEvent>().listen(
        events.add,
      );
      final bridge = await FirebaseNotificationBridge(
        preferences: preferences,
        delivery: delivery,
        foreground: foreground,
        session: Rxn<MaasoAuthSession>(_session()),
        environmentSignal: MaasoEnvironment.test.obs,
        interactionConsumerReady: () => true,
      ).init();
      bridge.activateForegroundBridge();

      delivery.add(
        const NotificationInteraction(
          deliveryId: 'proactive:morning',
          kind: MaasoNotificationKind.morningGreeting,
          data: <String, Object?>{
            'accountUuid': 'account-a',
            'environmentKey': 'test',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      foreground.isForeground.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));

      bridge.onClose();
      await eventSubscription.cancel();
      await delivery.close();
    },
  );

  test('local interactions without exact scope claims fail closed', () async {
    final preferences = await NotificationPreferencesService.forTesting()
        .init();
    final delivery = _FakeDelivery();
    final foreground = AppForegroundService()..isForeground.value = true;
    final events = <SystemStatusEvent>[];
    final eventSubscription = EventBus().on<SystemStatusEvent>().listen(
      events.add,
    );
    final bridge = await FirebaseNotificationBridge(
      preferences: preferences,
      delivery: delivery,
      foreground: foreground,
      session: Rxn<MaasoAuthSession>(_session()),
      environmentSignal: MaasoEnvironment.test.obs,
      interactionConsumerReady: () => true,
    ).init();
    bridge.activateForegroundBridge();

    delivery.add(
      const NotificationInteraction(
        deliveryId: 'legacy-missing-scope',
        kind: MaasoNotificationKind.scheduledTask,
      ),
    );
    delivery.add(
      const NotificationInteraction(
        deliveryId: 'wrong-account',
        kind: MaasoNotificationKind.scheduledTask,
        data: <String, Object?>{
          'accountUuid': 'account-b',
          'environmentKey': 'test',
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(events, isEmpty);

    bridge.onClose();
    await eventSubscription.cancel();
    await delivery.close();
  });

  test('pending local interaction is revalidated after scope switch', () async {
    final preferences = await NotificationPreferencesService.forTesting()
        .init();
    final delivery = _FakeDelivery();
    final foreground = AppForegroundService()..isForeground.value = false;
    final environment = MaasoEnvironment.test.obs;
    final events = <SystemStatusEvent>[];
    final eventSubscription = EventBus().on<SystemStatusEvent>().listen(
      events.add,
    );
    final bridge = await FirebaseNotificationBridge(
      preferences: preferences,
      delivery: delivery,
      foreground: foreground,
      session: Rxn<MaasoAuthSession>(_session()),
      environmentSignal: environment,
      interactionConsumerReady: () => true,
    ).init();
    bridge.activateForegroundBridge();

    delivery.add(
      const NotificationInteraction(
        deliveryId: 'stale-test-scope',
        kind: MaasoNotificationKind.scheduledTask,
        data: <String, Object?>{
          'accountUuid': 'account-a',
          'environmentKey': 'test',
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    environment.value = MaasoEnvironment.production;
    foreground.isForeground.value = true;
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);

    bridge.onClose();
    await eventSubscription.cancel();
    await delivery.close();
  });

  test(
    'foreground FCM requires exact active account and environment',
    () async {
      final preferences = await _enabledPreferences();
      final delivery = _FakeDelivery();
      final messaging = _FakeMessagingGateway();
      final foreground = AppForegroundService()..isForeground.value = true;
      final bridge = await FirebaseNotificationBridge(
        messaging: messaging,
        preferences: preferences,
        delivery: delivery,
        foreground: foreground,
        session: Rxn<MaasoAuthSession>(_session()),
        environmentSignal: MaasoEnvironment.test.obs,
        interactionConsumerReady: () => true,
      ).init();

      messaging.addForeground(
        _message('missing', data: const <String, Object?>{}),
      );
      messaging.addForeground(
        _message(
          'wrong-account',
          data: const <String, Object?>{
            'accountUuid': 'account-b',
            'environmentKey': 'test',
          },
        ),
      );
      messaging.addForeground(
        _message(
          'wrong-env',
          data: const <String, Object?>{
            'accountUuid': 'account-a',
            'environmentKey': 'prod',
          },
        ),
      );
      messaging.addForeground(
        _message(
          'missing-kind',
          data: const <String, Object?>{
            'accountUuid': 'account-a',
            'environmentKey': 'test',
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(delivery.shown, isEmpty);

      messaging.addForeground(
        _message(
          'exact',
          data: const <String, Object?>{
            'accountUuid': 'account-a',
            'environmentKey': 'test',
            'kind': 'remote',
          },
        ),
      );
      await _eventually(() => delivery.shown.length == 1);
      expect(delivery.shown.single.deliveryId, 'fcm:exact');

      bridge.onClose();
      await messaging.close();
      await delivery.close();
    },
  );

  test(
    'account drain waits for admitted A show and cancels it without touching B',
    () async {
      final preferences = await _enabledPreferences();
      final delivery = _GatedForegroundDelivery('fcm:a-gated');
      final messaging = _FakeMessagingGateway();
      final foreground = AppForegroundService()..isForeground.value = true;
      final session = Rxn<MaasoAuthSession>(_session());
      final bridge = await FirebaseNotificationBridge(
        messaging: messaging,
        preferences: preferences,
        delivery: delivery,
        foreground: foreground,
        session: session,
        environmentSignal: MaasoEnvironment.test.obs,
        interactionConsumerReady: () => true,
      ).init();

      messaging.addForeground(
        _message(
          'a-gated',
          data: const <String, Object?>{
            'accountUuid': 'account-a',
            'environmentKey': 'test',
            'kind': 'remote',
          },
        ),
      );
      await delivery.gatedShowStarted.future;

      var drainCompleted = false;
      final drain = bridge.deactivateAccountAndDrain().then((_) {
        drainCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(drainCompleted, isFalse);

      session.value = _sessionForAccount('account-b');
      messaging.addForeground(
        _message(
          'stale-a',
          data: const <String, Object?>{
            'accountUuid': 'account-a',
            'environmentKey': 'test',
            'kind': 'remote',
          },
        ),
      );
      messaging.addForeground(
        _message(
          'b-current',
          data: const <String, Object?>{
            'accountUuid': 'account-b',
            'environmentKey': 'test',
            'kind': 'remote',
          },
        ),
      );
      await _eventually(() => delivery.visible.containsKey('fcm:b-current'));

      delivery.releaseGatedShow();
      await drain;

      expect(delivery.visible, isNot(contains('fcm:a-gated')));
      expect(delivery.visible, isNot(contains('fcm:stale-a')));
      expect(delivery.visible, contains('fcm:b-current'));
      expect(delivery.cancelled, contains('fcm:a-gated'));

      bridge.onClose();
      await messaging.close();
      await delivery.close();
    },
  );

  test(
    'remote proactive kinds are rejected and scheduled toggle is honored',
    () async {
      final preferences = await _enabledPreferences();
      await preferences.setScheduledTasksEnabled(false);
      final delivery = _FakeDelivery();
      final messaging = _FakeMessagingGateway();
      final foreground = AppForegroundService()..isForeground.value = true;
      final bridge = await FirebaseNotificationBridge(
        messaging: messaging,
        preferences: preferences,
        delivery: delivery,
        foreground: foreground,
        session: Rxn<MaasoAuthSession>(_session()),
        environmentSignal: MaasoEnvironment.test.obs,
        interactionConsumerReady: () => true,
      ).init();
      const scope = <String, Object?>{
        'accountUuid': 'account-a',
        'environmentKey': 'test',
      };

      for (final kind in <MaasoNotificationKind>[
        MaasoNotificationKind.morningGreeting,
        MaasoNotificationKind.middayGreeting,
        MaasoNotificationKind.eveningGreeting,
        MaasoNotificationKind.randomCheckIn,
      ]) {
        messaging.addForeground(
          _message(
            kind.key,
            data: <String, Object?>{...scope, 'kind': kind.key},
          ),
        );
      }
      messaging.addForeground(
        _message(
          'scheduled-off',
          data: <String, Object?>{
            ...scope,
            'kind': MaasoNotificationKind.scheduledTask.key,
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(delivery.shown, isEmpty);

      await preferences.setScheduledTasksEnabled(true);
      messaging.addForeground(
        _message(
          'scheduled-on',
          data: <String, Object?>{
            ...scope,
            'kind': MaasoNotificationKind.scheduledTask.key,
          },
        ),
      );
      await _eventually(() => delivery.shown.length == 1);
      expect(delivery.shown.single.kind, MaasoNotificationKind.scheduledTask);

      bridge.onClose();
      await messaging.close();
      await delivery.close();
    },
  );

  test('wrong-scope opened FCM cannot enter EventBus', () async {
    final preferences = await _enabledPreferences();
    final delivery = _FakeDelivery();
    final messaging = _FakeMessagingGateway();
    final foreground = AppForegroundService()..isForeground.value = true;
    final events = <SystemStatusEvent>[];
    final eventSubscription = EventBus().on<SystemStatusEvent>().listen(
      events.add,
    );
    final bridge = await FirebaseNotificationBridge(
      messaging: messaging,
      preferences: preferences,
      delivery: delivery,
      foreground: foreground,
      session: Rxn<MaasoAuthSession>(_session()),
      environmentSignal: MaasoEnvironment.test.obs,
      interactionConsumerReady: () => true,
    ).init();
    bridge.activateForegroundBridge();

    messaging.addOpened(
      _message(
        'wrong',
        data: const <String, Object?>{
          'accountUuid': 'account-b',
          'environmentKey': 'test',
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);

    messaging.addOpened(
      _message(
        'exact',
        data: const <String, Object?>{
          'accountUuid': 'account-a',
          'environmentKey': 'test',
          'kind': 'remote',
        },
      ),
    );
    await _eventually(() => events.length == 1);
    expect(events.single.payload?['deliveryId'], 'fcm:exact');

    bridge.onClose();
    await eventSubscription.cancel();
    await messaging.close();
    await delivery.close();
  });
}

Future<NotificationPreferencesService> _enabledPreferences() async {
  final preferences = await NotificationPreferencesService.forTesting().init();
  await preferences.setConsent(enabled: true, permissionGranted: true);
  await preferences.setQuietHours(start: 0, end: 0);
  return preferences;
}

MaasoAuthSession _session() => MaasoAuthSession(
  accountUuid: 'account-a',
  accessToken: 'access-a',
  refreshToken: 'refresh-a',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);

MaasoAuthSession _sessionForAccount(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);

FirebasePushMessage _message(String id, {required Map<String, Object?> data}) =>
    FirebasePushMessage(
      messageId: id,
      title: 'title',
      body: 'body',
      data: data,
    );

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
}

class _FakeDelivery implements NotificationDelivery {
  _FakeDelivery({NotificationInteraction? initialInteraction})
    : _initialInteraction = initialInteraction;

  final _interactions = StreamController<NotificationInteraction>.broadcast();
  final shown = <MaasoNotification>[];
  NotificationInteraction? _initialInteraction;

  @override
  bool get isAvailable => true;

  @override
  Stream<NotificationInteraction> get interactions => _interactions.stream;

  void add(NotificationInteraction interaction) =>
      _interactions.add(interaction);

  Future<void> close() => _interactions.close();

  @override
  Future<void> cancel(String deliveryId) async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) async {}

  @override
  Future<void> show(MaasoNotification notification) async {
    shown.add(notification);
  }

  @override
  NotificationInteraction? takeInitialInteraction() {
    final interaction = _initialInteraction;
    _initialInteraction = null;
    return interaction;
  }
}

class _GatedForegroundDelivery implements NotificationDelivery {
  _GatedForegroundDelivery(this.gatedDeliveryId);

  final String gatedDeliveryId;
  final Completer<void> gatedShowStarted = Completer<void>();
  final Completer<void> _gatedShowRelease = Completer<void>();
  final Map<String, MaasoNotification> visible = <String, MaasoNotification>{};
  final List<String> cancelled = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();

  @override
  Future<void> cancel(String deliveryId) async {
    cancelled.add(deliveryId);
    visible.remove(deliveryId);
  }

  Future<void> close() async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => true;

  void releaseGatedShow() {
    if (!_gatedShowRelease.isCompleted) _gatedShowRelease.complete();
  }

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) async {}

  @override
  Future<void> show(MaasoNotification notification) async {
    if (notification.deliveryId == gatedDeliveryId) {
      if (!gatedShowStarted.isCompleted) gatedShowStarted.complete();
      await _gatedShowRelease.future;
    }
    visible[notification.deliveryId] = notification;
  }

  @override
  NotificationInteraction? takeInitialInteraction() => null;
}

class _FakeMessagingGateway implements FirebaseMessagingGateway {
  final _foreground = StreamController<FirebasePushMessage>.broadcast();
  final _opened = StreamController<FirebasePushMessage>.broadcast();
  final _refreshes = StreamController<String>.broadcast();

  void addForeground(FirebasePushMessage message) => _foreground.add(message);

  void addOpened(FirebasePushMessage message) => _opened.add(message);

  @override
  Stream<FirebasePushMessage> get foregroundMessages => _foreground.stream;

  @override
  Stream<FirebasePushMessage> get openedMessages => _opened.stream;

  @override
  Stream<String> get tokenRefreshes => _refreshes.stream;

  @override
  Future<void> deleteToken() async {}

  @override
  Future<String?> getAPNSToken() async => 'apns-a';

  @override
  Future<FirebasePushMessage?> getInitialMessage() async => null;

  @override
  Future<String?> getToken() async => 'fcm-a';

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {}

  Future<void> close() async {
    await _foreground.close();
    await _opened.close();
    await _refreshes.close();
  }
}
