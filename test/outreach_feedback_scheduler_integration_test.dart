import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/app_foreground_service.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/notifications/proactive_system_notification_scheduler.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'scheduler cancellation callback retracts unclaimed inferred OS feedback',
    () async {
      final harness = await _SchedulerFeedbackHarness.create(
        'feedback-scheduler-unclaimed.db',
      );
      addTearDown(harness.close);
      final scheduled = harness.delivery.scheduled.single;
      final outreachId = scheduled.notification.data['outreachId']! as String;
      final ledgerRecord = (await harness.ledger.get(outreachId))!;

      await harness.collector.reconcile(
        now: ledgerRecord.expiresAt!
            .add(harness.collector.responseWindow)
            .add(const Duration(seconds: 1)),
      );
      expect(
        (await harness.collector.get(outreachId))?.outcome,
        OutreachFeedbackOutcome.ignored,
      );
      expect(harness.collector.posterior.unavailableMass, 5.25);
      final callbacksBeforeCancellation = harness.completedCallbacks;

      await harness.preferences.setHardMuted(true);
      await harness.scheduler.sync();
      await _eventually(() async {
        final record = await harness.ledger.get(outreachId);
        return record?.state == OutreachState.cancelled &&
            harness.completedCallbacks > callbacksBeforeCancellation;
      });
      await harness.collector.waitForIdle();

      expect(await harness.collector.get(outreachId), isNull);
      expect(harness.collector.posterior.availableMass, 1);
      expect(harness.collector.posterior.unavailableMass, 4);
      expect(harness.collector.state.value.posteriorSamples, 0);
      expect(
        harness.delivery.cancelled,
        contains(scheduled.notification.deliveryId),
      );
    },
  );

  test(
    'scheduler cancellation callback retains claimed and opened OS feedback',
    () async {
      final harness = await _SchedulerFeedbackHarness.create(
        'feedback-scheduler-claimed.db',
      );
      addTearDown(harness.close);
      final scheduled = harness.delivery.scheduled.single;
      final data = scheduled.notification.data;
      final outreachId = data['outreachId']! as String;

      expect(
        await harness.ledger.claimOsNotificationInteraction(
          outreachId: outreachId,
          deliveryId: scheduled.notification.deliveryId,
          sourceEventId: data['sourceEventId']! as String,
          now: scheduled.target,
        ),
        isTrue,
      );
      expect(
        await harness.collector.recordOpened(outreachId: outreachId),
        OutreachFeedbackMutationResult.recorded,
      );
      final openedBeforeCancellation = await harness.collector.get(outreachId);
      expect(openedBeforeCancellation?.openedAt, scheduled.target.toUtc());
      final callbacksBeforeCancellation = harness.completedCallbacks;

      await harness.preferences.setHardMuted(true);
      await harness.scheduler.sync();
      await _eventually(() async {
        final record = await harness.ledger.get(outreachId);
        return record?.state == OutreachState.cancelled &&
            harness.completedCallbacks > callbacksBeforeCancellation;
      });
      await harness.collector.waitForIdle();

      final retained = await harness.collector.get(outreachId);
      expect(retained, isNotNull);
      expect(retained?.openedAt, scheduled.target.toUtc());
      expect(retained?.outcome, isNull);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.opened],
        1,
      );
      expect(
        harness.delivery.cancelled,
        contains(scheduled.notification.deliveryId),
      );
    },
  );
}

var _databaseSequence = 0;

final class _SchedulerFeedbackHarness {
  const _SchedulerFeedbackHarness({
    required this.database,
    required this.flags,
    required this.preferences,
    required this.ledger,
    required this.collector,
    required this.scheduler,
    required this.delivery,
    required this.callbackCounter,
  });

  final DBService database;
  final MaasoFeatureFlagService flags;
  final ProactivePreferenceService preferences;
  final ProactiveOutreachLedger ledger;
  final OutreachFeedbackCollector collector;
  final ProactiveSystemNotificationScheduler scheduler;
  final _FakeDelivery delivery;
  final _CallbackCounter callbackCounter;

  int get completedCallbacks => callbackCounter.completed;

  static Future<_SchedulerFeedbackHarness> create(String path) async {
    final clock = _MutableClock(DateTime(2026, 8, 10, 7, 59));
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: '$path-${_databaseSequence++}',
    );
    final flags = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(database),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
      clock: () => clock.now,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: clock.now.add(const Duration(days: 30)),
    );
    final preferences = await ProactivePreferenceService(
      store: SembastProactivePreferenceStore(
        database,
        accountScopeDigest: 'b' * 64,
      ),
      accountScopeDigest: 'b' * 64,
      generation: 1,
    ).init();
    await preferences.setContactAgreement(
      enabled: true,
      scope: ProactiveConversationScope.everyday,
    );
    await preferences.setDailyBudget(1);
    final ledger = ProactiveOutreachLedger(
      accountDatabase: database,
      clock: () => clock.now,
    );
    final collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: () => clock.now,
    ).init();
    final coordinator = ProactiveOutreachCoordinator(
      policy: const ProactiveCompanionPolicy(),
      ledger: ledger,
      accountKey: 'test:account-a',
      clock: () => clock.now,
    );
    final shared = await SharedPreferences.getInstance();
    final notificationPreferences =
        await NotificationPreferencesService.forTesting(
          preferences: shared,
        ).init();
    await notificationPreferences.setConsent(
      enabled: true,
      permissionGranted: true,
    );
    await notificationPreferences.setRandomCheckInsEnabled(false);
    final delivery = _FakeDelivery();
    final callbackCounter = _CallbackCounter();
    final scheduler = await ProactiveSystemNotificationScheduler(
      preferences: notificationPreferences,
      delivery: delivery,
      foreground: AppForegroundService(),
      sharedPreferences: shared,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => clock.now,
      random: Random(17),
      rollingHorizonDays: 1,
    ).init();
    final mountToken = await scheduler.prepareAccountScope(
      environmentKey: MaasoEnvironment.test.key,
      accountUuid: 'account-a',
    );
    await scheduler.acknowledgePlatformSweep(
      environmentKey: MaasoEnvironment.test.key,
      accountUuid: 'account-a',
      mountToken: mountToken,
    );
    await scheduler.bindAccountRuntime(
      environmentKey: MaasoEnvironment.test.key,
      accountUuid: 'account-a',
      mountToken: mountToken,
      coordinator: coordinator,
      proactivePreferences: preferences.state,
      onOutreachLedgerChanged: () async {
        await collector.reconcile(now: clock.now);
        callbackCounter.completed += 1;
      },
    );
    await scheduler.activate();
    await _eventually(
      () => callbackCounter.completed >= delivery.scheduled.length,
    );
    await collector.waitForIdle();
    return _SchedulerFeedbackHarness(
      database: database,
      flags: flags,
      preferences: preferences,
      ledger: ledger,
      collector: collector,
      scheduler: scheduler,
      delivery: delivery,
      callbackCounter: callbackCounter,
    );
  }

  Future<void> close() async {
    scheduler.onClose();
    await collector.deactivateAndDrain();
    await preferences.deactivateAndDrain();
    await flags.deactivateAndDrain();
    await database.close();
  }
}

final class _CallbackCounter {
  int completed = 0;
}

final class _MutableClock {
  _MutableClock(this.now);

  DateTime now;
}

final class _ScheduledCall {
  const _ScheduledCall({required this.notification, required this.target});

  final MaasoNotification notification;
  final DateTime target;
}

final class _FakeDelivery implements NotificationDelivery {
  final List<_ScheduledCall> scheduled = <_ScheduledCall>[];
  final List<String> cancelled = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();

  @override
  Future<void> cancel(String deliveryId) async {
    cancelled.add(deliveryId);
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
    scheduled.add(_ScheduledCall(notification: notification, target: target));
  }

  @override
  Future<void> show(MaasoNotification notification) async {}

  @override
  NotificationInteraction? takeInitialInteraction() => null;
}

MaasoAuthSession _validSession(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime(2099),
);

Future<void> _eventually(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
}
