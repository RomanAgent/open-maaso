import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/app_foreground_service.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/notifications/proactive_category_persona_memory.dart';
import 'package:maaso/src/core/notifications/proactive_system_notification_scheduler.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'scheduler consumes remembered account categories while mute and quiet remain authoritative',
    () async {
      final shared = await SharedPreferences.getInstance();
      final database = await databaseFactoryMemory.openDatabase(
        'scheduler-persona-categories.db',
      );
      addTearDown(database.close);
      final memory = SembastProactiveCategoryPersonaMemoryStore(
        database: database,
        accountScopeDigest: 'a' * 64,
      );
      await memory.write(
        const ProactiveCategoryPersonaMemory(
          greetings: false,
          randomCheckIns: false,
          greetingsSource: 'user_choice',
          randomCheckInsSource: 'user_choice',
        ),
      );
      final preferences = await NotificationPreferencesService(
        preferences: shared,
      ).init();
      addTearDown(preferences.deactivatePersonaMemoryAndDrain);
      await preferences.bindPersonaMemory(memory);
      await preferences.setConsent(enabled: true, permissionGranted: true);
      final proactive = _defaultProactivePreferences();
      final now = DateTime(2026, 8, 10, 10);
      final delivery = _FakeDelivery();
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        proactivePreferences: proactive,
      );
      addTearDown(scheduler.onClose);
      await scheduler.activate();
      expect(delivery.scheduled, isEmpty);
      await preferences.setGreetingsEnabled(true);
      await scheduler.sync();
      expect(delivery.scheduled, hasLength(1));
      expect(
        delivery.scheduled.single.notification.kind,
        MaasoNotificationKind.morningGreeting,
      );
      expect((await memory.read())!.greetings, isTrue);
      proactive.value = proactive.value.copyWith(hardMuted: true);
      await scheduler.sync();
      expect(
        delivery.cancelled,
        contains(delivery.scheduled.single.notification.deliveryId),
      );
      expect(delivery.scheduled, hasLength(1));
      proactive.value = proactive.value.copyWith(
        hardMuted: false,
        quietStartMinutes: 0,
        quietEndMinutes: 1439,
      );
      await scheduler.sync();
      expect(delivery.scheduled, hasLength(1));
      expect(preferences.state.value.greetingsEnabled, isTrue);
      final device =
          jsonDecode(shared.getString('notification_preferences.v1')!) as Map;
      expect(device.containsKey('greetingsEnabled'), isFalse);
      expect(device.containsKey('randomCheckInsEnabled'), isFalse);
    },
  );

  test(
    'ordinary OS contact queues once and waits before another topic',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final now = DateTime(2026, 8, 10, 10);
      var feedbackNudges = 0;
      late _TestAccountRuntime runtime;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        onOutreachLedgerChanged: () async {
          feedbackNudges += 1;
        },
        onRuntime: (value) => runtime = value,
      );
      await scheduler.activate();

      expect(delivery.scheduled, hasLength(1));
      expect(feedbackNudges, 1);
      expect(
        delivery.scheduled.single.notification.kind,
        MaasoNotificationKind.morningGreeting,
      );

      for (final call in delivery.scheduled) {
        expect(call.repeatsDaily, isFalse);
        expect(call.notification.deliveryId, startsWith('proactive:v3:'));
        expect(call.notification.data['environmentKey'], 'test');
        expect(call.notification.data['accountUuid'], 'account-a');
        expect(call.notification.data['outreachId'], isNotEmpty);
        expect(call.notification.data['sourceEventId'], isNotEmpty);
        final outreachId = call.notification.data['outreachId']! as String;
        final record = await runtime.coordinator.getOutreach(outreachId);
        expect(record?.deliveryId, call.notification.deliveryId);
        expect(record?.sourceEventId, call.notification.data['sourceEventId']);
        expect(record?.topicKey, call.notification.data['topicKey']);
        expect(record?.scheduledFor, call.target.toUtc());
        expect(record?.state, OutreachState.scheduledOs);
        final interaction = NotificationInteraction.fromPayload(
          call.notification.toPayload(),
        );
        expect(interaction?.data['environmentKey'], 'test');
        expect(interaction?.data['accountUuid'], 'account-a');
      }

      final scheduledCount = delivery.scheduled.length;
      await scheduler.sync();
      expect(delivery.scheduled, hasLength(scheduledCount));

      scheduler.onClose();
    },
  );

  test('larger budget cannot queue an unanswered follow-up', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    await preferences.setDailyProactiveBudget(2);
    final delivery = _FakeDelivery();
    final scheduler = await _scheduler(
      shared: shared,
      preferences: preferences,
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environment: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(3),
    );

    await scheduler.activate();

    expect(delivery.scheduled, hasLength(1));
    expect(
      delivery.scheduled.map((entry) => entry.notification.kind),
      <MaasoNotificationKind>[MaasoNotificationKind.morningGreeting],
    );
    scheduler.onClose();
  });

  test(
    'quiet hours and consent changes cancel scoped ineligible delivery',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final proactivePreferences = _proactivePreferencesFrom(preferences);
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(11),
        proactivePreferences: proactivePreferences,
      );
      await scheduler.activate();
      final eveningId = delivery.scheduled
          .singleWhere(
            (entry) =>
                entry.notification.kind ==
                MaasoNotificationKind.morningGreeting,
          )
          .notification
          .deliveryId;

      proactivePreferences.value = proactivePreferences.value.copyWith(
        revision: proactivePreferences.value.revision + 1,
        quietStartMinutes: 7 * 60,
        quietEndMinutes: 10 * 60,
      );
      await scheduler.sync();
      expect(delivery.cancelled, contains(eveningId));

      final scopedIds = delivery.scheduled
          .map((entry) => entry.notification.deliveryId)
          .toSet();
      await preferences.setConsent(enabled: false, permissionGranted: true);
      await scheduler.sync();
      expect(delivery.cancelled, containsAll(scopedIds));

      scheduler.onClose();
    },
  );

  test('account hard mute cancels every scoped OS occurrence', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final proactivePreferences = _proactivePreferencesFrom(preferences);
    final delivery = _FakeDelivery();
    var feedbackNudges = 0;
    late _TestAccountRuntime runtime;
    final scheduler = await _scheduler(
      shared: shared,
      preferences: preferences,
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environment: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(13),
      proactivePreferences: proactivePreferences,
      onOutreachLedgerChanged: () async {
        feedbackNudges += 1;
      },
      onRuntime: (value) => runtime = value,
    );
    await scheduler.activate();
    final scopedIds = delivery.activeDeliveryIds.toSet();
    final schedulingNudges = feedbackNudges;
    expect(scopedIds, hasLength(1));

    proactivePreferences.value = proactivePreferences.value.copyWith(
      revision: proactivePreferences.value.revision + 1,
      hardMuted: true,
    );
    await scheduler.sync();

    expect(delivery.activeDeliveryIds, isEmpty);
    expect(delivery.cancelled, containsAll(scopedIds));
    expect(feedbackNudges, greaterThan(schedulingNudges));
    expect(
      (await runtime.ledger.recent(
        limit: 8,
      )).every((record) => record.state == OutreachState.cancelled),
      isTrue,
    );
    scheduler.onClose();
  });

  test(
    'hard mute during ledger journaling never reaches native schedule',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      final proactivePreferences = _proactivePreferencesFrom(preferences);
      final delivery = _FakeDelivery();
      final gate = _PreferenceWriteGate(
        shared,
        matches: (key, value) =>
            key == 'notification.proactive.operations.v3' &&
            value.contains('"state":"ledgerReserved"'),
      );
      late _TestAccountRuntime runtime;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 7, 59),
        random: Random(13),
        proactivePreferences: proactivePreferences,
        preferenceWriter: gate.write,
        onRuntime: (value) => runtime = value,
      );

      final activation = scheduler.activate();
      await gate.started.future;
      proactivePreferences.value = proactivePreferences.value.copyWith(
        revision: proactivePreferences.value.revision + 1,
        hardMuted: true,
      );
      gate.release(persist: true);
      await activation;

      expect(delivery.scheduleAttemptIds, isEmpty);
      expect(delivery.activeDeliveryIds, isEmpty);
      expect(
        (await runtime.ledger.recent(
          limit: 8,
        )).every((record) => record.state == OutreachState.cancelled),
        isTrue,
      );
      scheduler.onClose();
    },
  );

  test(
    'hard mute during native schedule cancels before scheduled journal commit',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      final proactivePreferences = _proactivePreferencesFrom(preferences);
      final delivery = _FakeDelivery()..gateSchedule = true;
      var scheduledJournalWritten = false;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 7, 59),
        random: Random(13),
        proactivePreferences: proactivePreferences,
        preferenceWriter: (key, value) {
          if (key == 'notification.proactive.operations.v3' &&
              value.contains('"state":"scheduled"')) {
            scheduledJournalWritten = true;
          }
          return shared.setString(key, value);
        },
      );

      final activation = scheduler.activate();
      await delivery.scheduleStarted.future;
      final deliveryId = delivery.gatedScheduleDeliveryId!;
      proactivePreferences.value = proactivePreferences.value.copyWith(
        revision: proactivePreferences.value.revision + 1,
        hardMuted: true,
      );
      delivery.releaseSchedule();
      await activation;

      expect(scheduledJournalWritten, isFalse);
      expect(delivery.cancelled, contains(deliveryId));
      expect(delivery.activeDeliveryIds, isEmpty);
      scheduler.onClose();
    },
  );

  test('no valid session fails closed and never schedules outreach', () async {
    final shared = await SharedPreferences.getInstance();
    final delivery = _FakeDelivery();
    final scheduler = await _scheduler(
      shared: shared,
      preferences: await _enabledPreferences(shared),
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(),
      environment: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(5),
    );

    await scheduler.activate();

    expect(delivery.scheduled, isEmpty);
    scheduler.onClose();
  });

  test(
    'A sign-out then B cancels A and ignores stale A preference signals',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final aPreferences = _defaultProactivePreferences();
      final scheduler = await _scheduler(
        shared: shared,
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        session: session,
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
        proactivePreferences: aPreferences,
      );
      await scheduler.activate();
      final aIds = delivery.scheduled
          .map((entry) => entry.notification.deliveryId)
          .toSet();

      session.value = null;
      await scheduler.sync();
      expect(delivery.cancelled, containsAll(aIds));

      final beforeB = delivery.scheduled.length;
      final bPreferences = _defaultProactivePreferences();
      await _bindSchedulerAccount(
        scheduler,
        environmentKey: 'test',
        accountUuid: 'account-b',
        clock: () => DateTime(2026, 8, 10, 10),
        proactivePreferences: bPreferences,
      );
      session.value = _validSession('account-b');
      await scheduler.sync();
      final bCalls = _uniqueCallsByDeliveryId(delivery.scheduled.skip(beforeB));
      expect(bCalls, hasLength(1));
      expect(
        bCalls.every(
          (entry) => entry.notification.data['accountUuid'] == 'account-b',
        ),
        isTrue,
      );
      expect(
        bCalls
            .map((entry) => entry.notification.deliveryId)
            .toSet()
            .intersection(aIds),
        isEmpty,
      );

      final bIds = bCalls.map((entry) => entry.notification.deliveryId).toSet();
      final cancellationsBeforeStaleSignal = delivery.cancelled.length;
      aPreferences.value = aPreferences.value.copyWith(
        revision: aPreferences.value.revision + 1,
        hardMuted: true,
      );
      await Future<void>.delayed(Duration.zero);
      await scheduler.sync();

      expect(bPreferences.value.hardMuted, isFalse);
      expect(delivery.activeDeliveryIds, containsAll(bIds));
      expect(delivery.cancelled, hasLength(cancellationsBeforeStaleSignal));
      scheduler.onClose();
    },
  );

  test(
    'test to prod cancels old scope and waits for matching session',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final environment = MaasoEnvironment.test.obs;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        session: session,
        environment: environment,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
      );
      await scheduler.activate();
      final testIds = delivery.scheduled
          .map((entry) => entry.notification.deliveryId)
          .toSet();
      final beforeSwitch = delivery.scheduled.length;

      environment.value = MaasoEnvironment.production;
      await scheduler.sync();
      expect(delivery.cancelled, containsAll(testIds));
      expect(delivery.scheduled, hasLength(beforeSwitch));

      await _bindSchedulerAccount(
        scheduler,
        environmentKey: 'prod',
        accountUuid: 'account-a',
        clock: () => DateTime(2026, 8, 10, 10),
      );
      session.value = _validSession('account-a');
      await scheduler.sync();
      final prodCalls = _uniqueCallsByDeliveryId(
        delivery.scheduled.skip(beforeSwitch),
      );
      expect(prodCalls, hasLength(1));
      expect(
        prodCalls.every(
          (entry) => entry.notification.data['environmentKey'] == 'prod',
        ),
        isTrue,
      );
      scheduler.onClose();
    },
  );

  test(
    'persisted A scope is cancelled before B schedules after restart',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final preferences = await _enabledPreferences(shared);
      final first = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
      );
      await first.activate();
      final aIds = delivery.scheduled
          .map((entry) => entry.notification.deliveryId)
          .toSet();
      first.onClose();

      final beforeB = delivery.scheduled.length;
      final second = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-b')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
      );
      await second.activate();

      expect(delivery.cancelled, containsAll(aIds));
      expect(
        delivery.scheduled
            .skip(beforeB)
            .every(
              (entry) => entry.notification.data['accountUuid'] == 'account-b',
            ),
        isTrue,
      );
      second.onClose();
    },
  );

  test(
    'scope cleanup timeout blocks B schedules until cancellation succeeds',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final scheduler = await _scheduler(
        shared: shared,
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        session: session,
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
        deliveryTimeout: const Duration(milliseconds: 30),
      );
      await scheduler.activate();
      final beforeB = delivery.scheduled.length;
      delivery.hangCancel = true;
      session.value = _validSession('account-b');
      final stopwatch = Stopwatch()..start();

      await scheduler.sync();

      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(delivery.scheduled, hasLength(beforeB));

      delivery.hangCancel = false;
      await _bindSchedulerAccount(
        scheduler,
        environmentKey: 'test',
        accountUuid: 'account-b',
        clock: () => DateTime(2026, 8, 10, 10),
      );
      await scheduler.activate();
      final bCalls = _uniqueCallsByDeliveryId(
        delivery.scheduled
            .skip(beforeB)
            .where(
              (entry) => entry.notification.data['accountUuid'] == 'account-b',
            ),
      );
      expect(bCalls, hasLength(1));
      scheduler.onClose();
    },
  );

  test(
    'same-scope opt-out journals failed OS cancellations and retries',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
        cancellationRetryDelay: const Duration(milliseconds: 10),
      );
      await scheduler.activate();
      expect(delivery.activeDeliveryIds, isNotEmpty);

      delivery.failCancel = true;
      await preferences.setConsent(enabled: false, permissionGranted: true);
      await scheduler.sync();
      expect(delivery.activeDeliveryIds, isNotEmpty);
      expect(
        shared.getString('notification.proactive.operations.v3'),
        isNotNull,
      );

      delivery.failCancel = false;
      await _eventually(() => delivery.activeDeliveryIds.isEmpty);
      await _eventually(
        () => shared.getString('notification.proactive.operations.v3') == null,
      );

      scheduler.onClose();
    },
  );

  test(
    'failed opt-out cancellation survives restart and drains first',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final first = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
        cancellationRetryDelay: const Duration(hours: 1),
      );
      await first.activate();
      final originalIds = Set<String>.from(delivery.activeDeliveryIds);

      delivery.failCancel = true;
      await preferences.setConsent(enabled: false, permissionGranted: true);
      await first.sync();
      expect(delivery.activeDeliveryIds, containsAll(originalIds));
      expect(
        shared.getString('notification.proactive.operations.v3'),
        isNotNull,
      );
      first.onClose();

      // Account bootstrap performs an authoritative platform sweep before it
      // acknowledges the journal. Mirror that external boundary in this fake.
      delivery.activeDeliveryIds.clear();
      delivery.failCancel = false;
      final scheduledBeforeRestart = delivery.scheduled.length;
      final second = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
      );
      await second.activate();

      expect(delivery.activeDeliveryIds, isEmpty);
      expect(delivery.scheduled, hasLength(scheduledBeforeRestart));
      expect(
        shared.getString('notification.proactive.pending_cancellations.v2'),
        isNull,
      );
      second.onClose();
    },
  );

  test(
    'account preparation waits for gated A cancellation before B activation',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final scheduler = await _scheduler(
        shared: shared,
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        session: session,
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
      );
      await scheduler.activate();
      final aIds = Set<String>.from(delivery.activeDeliveryIds);
      delivery.gateCancel = true;
      var prepared = false;

      ProactiveNotificationAccountMountToken? bMountToken;
      final preparation = scheduler
          .prepareAccountScope(environmentKey: 'test', accountUuid: 'account-b')
          .then((token) {
            bMountToken = token;
            prepared = true;
          });
      await delivery.cancelStarted.future;
      await Future<void>.delayed(Duration.zero);

      expect(prepared, isFalse);
      expect(delivery.activeDeliveryIds, containsAll(aIds));

      delivery.releaseCancel();
      await preparation;
      expect(delivery.activeDeliveryIds, isEmpty);

      await scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: bMountToken!,
      );
      final bRuntime = await _newTestAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        clock: () => DateTime(2026, 8, 10, 10),
      );
      await scheduler.bindAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: bMountToken!,
        coordinator: bRuntime.coordinator,
        proactivePreferences: _defaultProactivePreferences(),
      );
      session.value = _validSession('account-b');
      await scheduler.sync();
      expect(
        delivery.scheduled
            .where(
              (call) => call.notification.data['accountUuid'] == 'account-b',
            )
            .map((call) => call.notification.deliveryId)
            .toSet(),
        hasLength(1),
      );
      scheduler.onClose();
    },
  );

  test('account drain failure remains fenced and retries cleanup', () async {
    final shared = await SharedPreferences.getInstance();
    final delivery = _FakeDelivery();
    final scheduler = await _scheduler(
      shared: shared,
      preferences: await _enabledPreferences(shared),
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environment: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(7),
    );
    await scheduler.activate();
    delivery.failCancel = true;

    await expectLater(
      scheduler.deactivateAccountAndDrain(),
      throwsA(isA<ProactiveNotificationAccountDrainFailure>()),
    );
    expect(delivery.activeDeliveryIds, isNotEmpty);

    delivery.failCancel = false;
    await scheduler.deactivateAccountAndDrain();

    expect(delivery.activeDeliveryIds, isEmpty);
    expect(
      shared.getString('notification.proactive.pending_cancellations.v2'),
      isNull,
    );
    scheduler.onClose();
  });

  test('account drain waits for and compensates a late schedule', () async {
    final shared = await SharedPreferences.getInstance();
    final delivery = _FakeDelivery()..gateSchedule = true;
    late _TestAccountRuntime runtime;
    final scheduler = await _scheduler(
      shared: shared,
      preferences: await _enabledPreferences(shared),
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environment: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(7),
      deliveryTimeout: const Duration(milliseconds: 20),
      onRuntime: (value) => runtime = value,
    );

    final activation = scheduler.activate();
    await delivery.scheduleStarted.future;
    var drained = false;
    final firstDrain = scheduler.deactivateAccountAndDrain();
    final concurrentDrain = scheduler.deactivateAccountAndDrain();
    expect(identical(firstDrain, concurrentDrain), isTrue);
    final observedDrain = firstDrain.then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(drained, isFalse);

    final lateDeliveryId = delivery.gatedScheduleDeliveryId;
    delivery.releaseSchedule();
    await activation;
    await Future.wait<void>(<Future<void>>[observedDrain, concurrentDrain]);

    expect(lateDeliveryId, isNotNull);
    expect(delivery.activeDeliveryIds, isEmpty);
    expect(delivery.cancelled, contains(lateDeliveryId));
    expect(
      delivery.cancelled.where((value) => value == lateDeliveryId),
      hasLength(greaterThanOrEqualTo(2)),
    );
    final records = await runtime.ledger.recent(limit: 16);
    expect(
      records
          .where((record) => record.deliveryId == lateDeliveryId)
          .single
          .state,
      OutreachState.cancelled,
    );
    scheduler.onClose();
  });

  test(
    'post-grace late schedule cannot reacquire the retired account binding',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      final delivery = _FakeDelivery()..gateSchedule = true;
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final scopeCleanupGate = _PreferenceWriteGate(
        shared,
        matches: (key, _) =>
            key == 'notification.proactive.pending_cancellations.v2',
      );
      var gateScopeCleanup = false;
      final now = DateTime(2026, 8, 10, 7, 59);
      late _TestAccountRuntime accountA;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: session,
        environment: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        deliveryTimeout: const Duration(milliseconds: 10),
        accountDrainGrace: const Duration(milliseconds: 20),
        rollingHorizonDays: 1,
        preferenceWriter: (key, value) => gateScopeCleanup
            ? scopeCleanupGate.write(key, value)
            : shared.setString(key, value),
        onRuntime: (value) => accountA = value,
      );

      await scheduler.activate();
      final oldDeliveryId = delivery.gatedScheduleDeliveryId!;
      gateScopeCleanup = true;
      final drain = scheduler.deactivateAccountAndDrain();
      await scopeCleanupGate.started.future;

      // Scope cleanup has already snapshotted and skipped the ambiguous native
      // operation. Its completion must not regain account-A DB authority.
      delivery.releaseSchedule();
      await _eventually(() {
        final raw = shared.getString('notification.proactive.operations.v3');
        if (raw == null) return false;
        final operations = jsonDecode(raw) as List;
        return operations.any(
          (value) =>
              value is Map &&
              value['deliveryId'] == oldDeliveryId &&
              value['state'] == 'ledgerReleasePending',
        );
      });
      expect(delivery.activeDeliveryIds, isNot(contains(oldDeliveryId)));
      expect(
        (await accountA.ledger.recent(
          limit: 8,
        )).singleWhere((record) => record.deliveryId == oldDeliveryId).state,
        OutreachState.scheduledOs,
      );

      scopeCleanupGate.release(persist: true);
      await drain;
      await accountA.database.close();

      delivery.gateSchedule = false;
      final accountBToken = await scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      await scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: accountBToken,
      );
      final accountB = await _newTestAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        clock: () => now,
      );
      await scheduler.bindAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: accountBToken,
        coordinator: accountB.coordinator,
        proactivePreferences: _defaultProactivePreferences(),
      );
      session.value = _validSession('account-b');
      await scheduler.activate();

      expect(
        delivery.scheduled.any(
          (call) => call.notification.data['accountUuid'] == 'account-b',
        ),
        isTrue,
      );
      scheduler.onClose();
    },
  );

  test(
    'full drain wins after a same-scope preserve pass has started',
    () async {
      const activeScopeKey = 'notification.proactive.scope.v2';
      const pendingCancellationKey =
          'notification.proactive.pending_cancellations.v2';
      SharedPreferences.setMockInitialValues(<String, Object>{
        activeScopeKey: jsonEncode(<String, Object>{
          'environmentKey': 'test',
          'accountUuid': 'account-a',
        }),
        pendingCancellationKey: jsonEncode(<String>[
          'proactive:pending:account-a',
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery()..gateCancel = true;
      final scheduler = await ProactiveSystemNotificationScheduler(
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        foreground: AppForegroundService(),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
        rollingHorizonDays: 1,
      ).init();

      final preservedPreparation = scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      await delivery.cancelStarted.future;
      final fullDrain = scheduler.deactivateAccountAndDrain();
      delivery.releaseCancel();

      await expectLater(
        preservedPreparation,
        throwsA(
          isA<ProactiveNotificationAccountDrainFailure>().having(
            (error) => error.code,
            'code',
            'stale_account_mount',
          ),
        ),
      );
      await fullDrain;

      expect(shared.getString(activeScopeKey), isNull);
      expect(shared.getString(pendingCancellationKey), isNull);
      expect(
        delivery.cancelled,
        contains('proactive:v2:dGVzdA.YWNjb3VudC1h:morning'),
      );
      scheduler.onClose();
    },
  );

  test('ledger budget rejection never reaches platform scheduling', () async {
    final shared = await SharedPreferences.getInstance();
    final delivery = _FakeDelivery();
    final scheduler = await _scheduler(
      shared: shared,
      preferences: await _enabledPreferences(shared),
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environment: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(7),
      policyConfig: const ProactivePolicyConfig(foregroundDailyLimit: 0),
    );

    await scheduler.activate();

    expect(delivery.scheduled, isEmpty);
    expect(shared.getString('notification.proactive.operations.v3'), isNull);
    scheduler.onClose();
  });

  test(
    'immediate platform failure cancels ledger before releasing budget',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery()..failSchedule = true;
      late _TestAccountRuntime runtime;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
        onRuntime: (value) => runtime = value,
      );

      await scheduler.activate();

      expect(delivery.scheduled, isEmpty);
      expect(
        delivery.cancelled.where((id) => id.startsWith('proactive:v3:')),
        hasLength(3),
      );
      final records = await runtime.ledger.recent(limit: 16);
      expect(records, hasLength(3));
      expect(
        records.every((record) => record.state == OutreachState.cancelled),
        isTrue,
      );
      expect(shared.getString('notification.proactive.operations.v3'), isNull);
      scheduler.onClose();
    },
  );

  test(
    'past target cancellation remains counted as assumed delivery',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      var now = DateTime(2026, 8, 10, 7, 59);
      final delivery = _FakeDelivery();
      late _TestAccountRuntime runtime;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        onRuntime: (value) => runtime = value,
      );
      await scheduler.activate();
      final call = delivery.scheduled.single;
      final outreachId = call.notification.data['outreachId']! as String;

      now = DateTime(2026, 8, 10, 8, 1);
      await preferences.setGreetingsEnabled(false);
      await scheduler.sync();

      expect(delivery.cancelled, contains(call.notification.deliveryId));
      expect(
        (await runtime.coordinator.getOutreach(outreachId))?.state,
        OutreachState.scheduledOs,
      );

      now = DateTime(2026, 8, 10, 12, 1);
      await scheduler.sync();
      expect(
        (await runtime.coordinator.getOutreach(outreachId))?.state,
        OutreachState.assumedDelivered,
      );
      expect(shared.getString('notification.proactive.operations.v3'), isNull);
      scheduler.onClose();
    },
  );

  test(
    'corrupt operation journal stays silent until authoritative sweep',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'notification.proactive.operations.v3': '{broken',
      });
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final environment = MaasoEnvironment.test.obs;
      final now = DateTime(2026, 8, 10, 10);
      final scheduler = await ProactiveSystemNotificationScheduler(
        preferences: preferences,
        delivery: delivery,
        foreground: AppForegroundService(),
        sharedPreferences: shared,
        session: session,
        environmentSignal: environment,
        clock: () => now,
        random: Random(7),
        rollingHorizonDays: 1,
      ).init();

      await scheduler.activate();
      expect(delivery.scheduled, isEmpty);

      await _bindSchedulerAccount(
        scheduler,
        environmentKey: 'test',
        accountUuid: 'account-a',
        clock: () => now,
      );
      await scheduler.activate();

      expect(delivery.scheduled, hasLength(1));
      expect(delivery.scheduled.every((call) => !call.repeatsDaily), isTrue);
      scheduler.onClose();
    },
  );

  test(
    'rolling horizon cannot send again while yesterday remains unanswered',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      var now = DateTime(2026, 8, 10, 7);
      final delivery = _FakeDelivery();
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        rollingHorizonDays: 7,
      );
      await scheduler.activate();
      expect(delivery.scheduled, hasLength(1));
      expect(delivery.scheduled.single.target, DateTime(2026, 8, 10, 8));
      expect(delivery.scheduled.single.repeatsDaily, isFalse);
      await scheduler.sync();
      now = DateTime(2026, 8, 11, 7);
      await scheduler.sync();
      expect(delivery.scheduled, hasLength(1));
      scheduler.onClose();
    },
  );

  test('random journal entries beyond seven-day horizon are evicted', () async {
    final now = DateTime(2026, 8, 10, 10);
    final horizonEnd = DateTime(2026, 8, 17);
    final retained = _scheduledRandomOperationJson(
      target: DateTime(2026, 8, 16, 15),
      outreachId: 'random-retained',
    );
    final outside = _scheduledRandomOperationJson(
      target: DateTime(2026, 8, 17, 15),
      outreachId: 'random-outside-horizon',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'notification.proactive.operations.v3': jsonEncode(<Object?>[
        retained,
        outside,
      ]),
    });
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    await preferences.setGreetingsEnabled(false);
    await preferences.setDailyProactiveBudget(1);
    final delivery = _FakeDelivery();
    final scheduler = await _scheduler(
      shared: shared,
      preferences: preferences,
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environment: MaasoEnvironment.test.obs,
      clock: () => now,
      random: Random(7),
      rollingHorizonDays: 7,
    );

    await scheduler.activate();

    expect(
      delivery.scheduled.map((call) => call.notification.deliveryId),
      contains(retained['deliveryId']),
    );
    expect(
      shared.getString('notification.proactive.operations.v3'),
      isNot(contains(outside['deliveryId'])),
    );
    expect(
      delivery.scheduled.every((call) => call.target.isBefore(horizonEnd)),
      isTrue,
    );
    scheduler.onClose();
  });

  test(
    'shorter random horizon evicts previously valid journal entry',
    () async {
      final now = DateTime(2026, 8, 10, 10);
      final horizonEnd = DateTime(2026, 8, 15);
      final previouslyValid = _scheduledRandomOperationJson(
        target: DateTime(2026, 8, 15, 15),
        outreachId: 'random-previously-valid',
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'notification.proactive.operations.v3': jsonEncode(<Object?>[
          previouslyValid,
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setGreetingsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      final delivery = _FakeDelivery();
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        rollingHorizonDays: 5,
      );

      await scheduler.activate();

      expect(
        delivery.scheduled.map((call) => call.notification.deliveryId),
        isNot(contains(previouslyValid['deliveryId'])),
      );
      expect(
        shared.getString('notification.proactive.operations.v3'),
        isNot(contains(previouslyValid['deliveryId'])),
      );
      expect(delivery.scheduled, isNotEmpty);
      expect(
        delivery.scheduled.every((call) => call.target.isBefore(horizonEnd)),
        isTrue,
      );
      scheduler.onClose();
    },
  );

  test(
    'same-scope restart preserves the exact random occurrence chain',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final delivery = _FakeDelivery();
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final environment = MaasoEnvironment.test.obs;
      final now = DateTime(2026, 8, 10, 10);
      final first = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: session,
        environment: environment,
        clock: () => now,
        random: Random(1),
        rollingHorizonDays: 7,
      );
      await first.activate();
      final firstIds = delivery.scheduled
          .map((call) => call.notification.deliveryId)
          .toSet();
      first.onClose();

      // ScheduledTaskService owns this authoritative sweep in production.
      delivery.activeDeliveryIds.clear();
      final beforeRestart = delivery.scheduled.length;
      late _TestAccountRuntime secondRuntime;
      final second = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: session,
        environment: environment,
        clock: () => now,
        random: Random(999),
        rollingHorizonDays: 7,
        onRuntime: (value) => secondRuntime = value,
      );
      await second.activate();
      final restartedIds = delivery.scheduled
          .skip(beforeRestart)
          .map((call) => call.notification.deliveryId)
          .toSet();

      expect(restartedIds, firstIds);
      for (final call in delivery.scheduled.skip(beforeRestart)) {
        final outreachId = call.notification.data['outreachId']! as String;
        final record = await secondRuntime.coordinator.getOutreach(outreachId);
        expect(record?.deliveryId, call.notification.deliveryId);
        expect(record?.sourceEventId, call.notification.data['sourceEventId']);
      }
      second.onClose();
    },
  );

  test('stale same-scope mount tokens cannot acknowledge or bind', () async {
    final shared = await SharedPreferences.getInstance();
    final scheduler = await ProactiveSystemNotificationScheduler(
      preferences: await _enabledPreferences(shared),
      delivery: _FakeDelivery(),
      foreground: AppForegroundService(),
      sharedPreferences: shared,
      session: Rxn<MaasoAuthSession>(),
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(7),
      rollingHorizonDays: 1,
    ).init();
    final stale = await scheduler.prepareAccountScope(
      environmentKey: 'test',
      accountUuid: 'account-a',
    );
    final current = await scheduler.prepareAccountScope(
      environmentKey: 'test',
      accountUuid: 'account-a',
    );

    await expectLater(
      scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: stale,
      ),
      throwsA(isA<ProactiveNotificationAccountDrainFailure>()),
    );
    await scheduler.acknowledgePlatformSweep(
      environmentKey: 'test',
      accountUuid: 'account-a',
      mountToken: current,
    );
    final runtime = await _newTestAccountRuntime(
      environmentKey: 'test',
      accountUuid: 'account-a',
      clock: () => DateTime(2026, 8, 10, 10),
    );
    await expectLater(
      scheduler.bindAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: stale,
        coordinator: runtime.coordinator,
        proactivePreferences: _defaultProactivePreferences(),
      ),
      throwsStateError,
    );
    await scheduler.bindAccountRuntime(
      environmentKey: 'test',
      accountUuid: 'account-a',
      mountToken: current,
      coordinator: runtime.coordinator,
      proactivePreferences: _defaultProactivePreferences(),
    );
    scheduler.onClose();
  });

  test(
    'gated same-scope sweep cannot acknowledge a stale mount generation',
    () async {
      final storedOperation = _validScheduledOperationJson();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'notification.proactive.operations.v3': jsonEncode(<Object?>[
          storedOperation,
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final gate = _PreferenceWriteGate(
        shared,
        matches: (key, _) => key == 'notification.proactive.operations.v3',
      );
      final now = DateTime(2026, 8, 10, 10);
      final scheduler = await ProactiveSystemNotificationScheduler(
        preferences: await _enabledPreferences(shared),
        delivery: _FakeDelivery(),
        foreground: AppForegroundService(),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        rollingHorizonDays: 1,
        preferenceWriter: gate.write,
      ).init();
      final stale = await scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final staleAck = scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: stale,
      );
      await gate.started.future;

      final current = await scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      gate.release(persist: true);

      await expectLater(
        staleAck,
        throwsA(
          isA<ProactiveNotificationAccountDrainFailure>().having(
            (error) => error.code,
            'code',
            'platform_sweep_scope_mismatch',
          ),
        ),
      );
      await scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: current,
      );
      final runtime = await _newTestAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-a',
        clock: () => now,
      );
      await scheduler.bindAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: current,
        coordinator: runtime.coordinator,
        proactivePreferences: _defaultProactivePreferences(),
      );

      final journal =
          jsonDecode(shared.getString('notification.proactive.operations.v3')!)
              as List;
      expect((journal.single as Map)['state'], 'ledgerReserved');
      expect((journal.single as Map)['revision'], 1);
      scheduler.onClose();
    },
  );

  test(
    'gated old-scope sweep cannot overwrite the new mount journal or token',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'notification.proactive.operations.v3': jsonEncode(<Object?>[
          _validScheduledOperationJson(),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final gate = _PreferenceWriteGate(
        shared,
        matches: (key, _) => key == 'notification.proactive.operations.v3',
      );
      final now = DateTime(2026, 8, 10, 10);
      final scheduler = await ProactiveSystemNotificationScheduler(
        preferences: await _enabledPreferences(shared),
        delivery: _FakeDelivery(),
        foreground: AppForegroundService(),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        rollingHorizonDays: 1,
        preferenceWriter: gate.write,
      ).init();
      final stale = await scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final staleAck = scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: stale,
      );
      await gate.started.future;

      final current = await scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      gate.release(persist: true);

      await expectLater(
        staleAck,
        throwsA(
          isA<ProactiveNotificationAccountDrainFailure>().having(
            (error) => error.code,
            'code',
            'platform_sweep_scope_mismatch',
          ),
        ),
      );
      await scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: current,
      );
      final runtime = await _newTestAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        clock: () => now,
      );
      await scheduler.bindAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: current,
        coordinator: runtime.coordinator,
        proactivePreferences: _defaultProactivePreferences(),
      );

      final journal =
          jsonDecode(shared.getString('notification.proactive.operations.v3')!)
              as List;
      expect((journal.single as Map)['state'], 'ledgerReleasePending');
      expect((journal.single as Map)['releaseLedger'], isTrue);
      expect((journal.single as Map)['revision'], 1);
      scheduler.onClose();
    },
  );

  test(
    'concurrent account preparations retain only the newest scope',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final scheduler = await _scheduler(
        shared: shared,
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
      );
      await scheduler.activate();
      delivery.gateCancel = true;

      final stalePreparation = scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      await delivery.cancelStarted.future;
      final currentPreparation = scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-c',
      );
      delivery.releaseCancel();

      await expectLater(
        stalePreparation,
        throwsA(
          isA<ProactiveNotificationAccountDrainFailure>().having(
            (error) => error.code,
            'code',
            'stale_account_mount',
          ),
        ),
      );
      final current = await currentPreparation;
      expect(delivery.activeDeliveryIds, isEmpty);
      await scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-c',
        mountToken: current,
      );
      scheduler.onClose();
    },
  );

  test('typed and semantically corrupt journals fail closed', () async {
    final valid = _validScheduledOperationJson();
    final target = DateTime.parse(valid['target']! as String);
    final epoch = target.toUtc().millisecondsSinceEpoch;
    const coercedScope = 'NDI.YWNjb3VudC1h';
    final invalidValues = <Object>[
      42,
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'title': 42},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'evidenceKey': 42},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'outreachId': 42},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'reason': 42},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{
          ...valid,
          'scope': <String, Object?>{
            'environmentKey': 42,
            'accountUuid': 'account-a',
          },
          'deliveryId': 'proactive:v3:$coercedScope:morning:$epoch',
          'sourceEventId': 'os:v3:$coercedScope:morning:$epoch',
        },
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'deliveryId': 'proactive:v3:forged'},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'sourceEventId': 'os:v3:forged'},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{
          ...valid,
          'expiresAt': DateTime.parse(
            valid['target']! as String,
          ).subtract(const Duration(minutes: 1)).toIso8601String(),
        },
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'outreachId': null},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'releaseLedger': 'false'},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'releaseLedger': true},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'kind': 'eveningGreeting'},
      ]),
      jsonEncode(<Object?>[
        <String, Object?>{...valid, 'revision': -1},
      ]),
    ];

    for (final stored in invalidValues) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'notification.proactive.operations.v3': stored,
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final scheduler = await ProactiveSystemNotificationScheduler(
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        foreground: AppForegroundService(),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
        rollingHorizonDays: 1,
      ).init();

      await scheduler.activate();
      expect(delivery.scheduled, isEmpty);
      final token = await scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      await scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: token,
      );
      expect(shared.getString('notification.proactive.operations.v3'), isNull);
      scheduler.onClose();
    }

    SharedPreferences.setMockInitialValues(<String, Object>{
      'notification.proactive.operations.v3': jsonEncode(<Object?>[valid]),
    });
    final shared = await SharedPreferences.getInstance();
    final scheduler = await ProactiveSystemNotificationScheduler(
      preferences: await _enabledPreferences(shared),
      delivery: _FakeDelivery(),
      foreground: AppForegroundService(),
      sharedPreferences: shared,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(7),
      rollingHorizonDays: 1,
    ).init();
    final token = await scheduler.prepareAccountScope(
      environmentKey: 'test',
      accountUuid: 'account-a',
    );
    await scheduler.acknowledgePlatformSweep(
      environmentKey: 'test',
      accountUuid: 'account-a',
      mountToken: token,
    );
    expect(shared.getString('notification.proactive.operations.v3'), isNotNull);
    scheduler.onClose();
  });

  test(
    'permanently pending native schedule leaves one durable tombstone',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      final delivery = _FakeDelivery()..gateSchedule = true;
      late _TestAccountRuntime runtime;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 7, 59),
        random: Random(7),
        deliveryTimeout: const Duration(milliseconds: 10),
        accountDrainGrace: const Duration(milliseconds: 20),
        rollingHorizonDays: 7,
        onRuntime: (value) => runtime = value,
      );

      await scheduler.activate();
      expect(delivery.scheduleAttemptIds, hasLength(1));
      await scheduler.sync();
      expect(delivery.scheduleAttemptIds, hasLength(1));

      final stopwatch = Stopwatch()..start();
      await scheduler.deactivateAccountAndDrain();
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(
        jsonDecode(shared.getString('notification.proactive.operations.v3')!),
        hasLength(1),
      );
      expect(
        (await runtime.ledger.recent(limit: 8)).single.state,
        OutreachState.scheduledOs,
      );
      scheduler.onClose();
    },
  );

  test(
    'late success is cancelled while timeout tombstone persistence is gated',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      final delivery = _FakeDelivery()..gateSchedule = true;
      final gate = _PreferenceWriteGate(
        shared,
        matches: (key, value) =>
            key == 'notification.proactive.operations.v3' &&
            value.contains('"state":"scheduleAmbiguous"'),
      );
      late _TestAccountRuntime runtime;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 7, 59),
        random: Random(7),
        deliveryTimeout: const Duration(milliseconds: 10),
        preferenceWriter: gate.write,
        onRuntime: (value) => runtime = value,
      );

      final activation = scheduler.activate();
      await gate.started.future;
      final deliveryId = delivery.gatedScheduleDeliveryId!;
      delivery.releaseSchedule();

      await _eventually(() => delivery.cancelled.contains(deliveryId));
      expect(delivery.activeDeliveryIds, isNot(contains(deliveryId)));
      await preferences.setGreetingsEnabled(false);
      gate.release(persist: false);
      await activation;
      await _eventually(() {
        final raw = shared.getString('notification.proactive.operations.v3');
        return raw == null || !raw.contains(deliveryId);
      });
      final records = await runtime.ledger.recent(limit: 8);
      expect(
        records.any(
          (record) =>
              record.deliveryId == deliveryId &&
              record.state == OutreachState.cancelled,
        ),
        isTrue,
      );
      scheduler.onClose();
    },
  );

  test(
    'tombstone write failure still releases ledger after late native error',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      final delivery = _FakeDelivery()..gateSchedule = true;
      late _TestAccountRuntime runtime;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 7, 59),
        random: Random(7),
        deliveryTimeout: const Duration(milliseconds: 10),
        preferenceWriter: (key, value) {
          if (key == 'notification.proactive.operations.v3' &&
              value.contains('"state":"scheduleAmbiguous"')) {
            return Future<bool>.value(false);
          }
          return shared.setString(key, value);
        },
        onRuntime: (value) => runtime = value,
      );
      await scheduler.activate();
      final deliveryId = delivery.gatedScheduleDeliveryId!;
      final outreachId = (await runtime.ledger.recent(
        limit: 8,
      )).singleWhere((record) => record.deliveryId == deliveryId).outreachId;

      delivery.releaseScheduleWithError();

      await _eventually(
        () => delivery.cancelled.where((id) => id == deliveryId).length >= 2,
      );
      await _eventually(() {
        final raw = shared.getString('notification.proactive.operations.v3');
        return raw == null || !raw.contains(deliveryId);
      });
      expect(
        (await runtime.coordinator.getOutreach(outreachId))?.state,
        OutreachState.cancelled,
      );
      scheduler.onClose();
    },
  );

  test(
    'tombstone write failure late success is cancelled after account switch',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      final delivery = _FakeDelivery()..gateSchedule = true;
      final session = Rxn<MaasoAuthSession>(_validSession('account-a'));
      final now = DateTime(2026, 8, 10, 7, 59);
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: session,
        environment: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        deliveryTimeout: const Duration(milliseconds: 10),
        accountDrainGrace: const Duration(milliseconds: 20),
        preferenceWriter: (key, value) {
          if (key == 'notification.proactive.operations.v3' &&
              value.contains('"state":"scheduleAmbiguous"')) {
            return Future<bool>.value(false);
          }
          return shared.setString(key, value);
        },
      );
      await scheduler.activate();
      final oldDeliveryId = delivery.gatedScheduleDeliveryId!;

      delivery.gateSchedule = false;
      final current = await scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      await scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: current,
      );
      final runtime = await _newTestAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        clock: () => now,
      );
      await scheduler.bindAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-b',
        mountToken: current,
        coordinator: runtime.coordinator,
        proactivePreferences: _defaultProactivePreferences(),
      );
      session.value = _validSession('account-b');
      await scheduler.activate();

      delivery.releaseSchedule();

      await _eventually(
        () => delivery.scheduled.any(
          (call) => call.notification.deliveryId == oldDeliveryId,
        ),
      );
      await _eventually(
        () => !delivery.activeDeliveryIds.contains(oldDeliveryId),
      );
      expect(delivery.cancelled, contains(oldDeliveryId));
      expect(
        delivery.activeDeliveryIds.every((id) => !id.contains('YWNjb3VudC1h')),
        isTrue,
      );
      scheduler.onClose();
    },
  );

  test('late native error releases ledger even after target time', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    await preferences.setRandomCheckInsEnabled(false);
    await preferences.setDailyProactiveBudget(1);
    var now = DateTime(2026, 8, 10, 7, 59);
    final delivery = _FakeDelivery()..gateSchedule = true;
    late _TestAccountRuntime runtime;
    final scheduler = await _scheduler(
      shared: shared,
      preferences: preferences,
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environment: MaasoEnvironment.test.obs,
      clock: () => now,
      random: Random(7),
      deliveryTimeout: const Duration(milliseconds: 10),
      onRuntime: (value) => runtime = value,
    );
    await scheduler.activate();
    now = DateTime(2026, 8, 10, 8, 1);
    final outreachId =
        ((jsonDecode(shared.getString('notification.proactive.operations.v3')!)
                        as List)
                    .single
                as Map)['outreachId']!
            as String;

    delivery.releaseScheduleWithError();
    await _eventually(() => delivery.cancelled.length >= 2);
    await _eventually(
      () => shared.getString('notification.proactive.operations.v3') == null,
    );
    expect(
      (await runtime.coordinator.getOutreach(outreachId))?.state,
      OutreachState.cancelled,
    );
    scheduler.onClose();
  });

  test(
    'late native success after target remains conservatively counted',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setRandomCheckInsEnabled(false);
      await preferences.setDailyProactiveBudget(1);
      var now = DateTime(2026, 8, 10, 7, 59);
      final delivery = _FakeDelivery()..gateSchedule = true;
      late _TestAccountRuntime runtime;
      final scheduler = await _scheduler(
        shared: shared,
        preferences: preferences,
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        deliveryTimeout: const Duration(milliseconds: 10),
        onRuntime: (value) => runtime = value,
      );
      await scheduler.activate();
      now = DateTime(2026, 8, 10, 8, 1);
      final lateDeliveryId = delivery.gatedScheduleDeliveryId!;
      final outreachId =
          ((jsonDecode(
                            shared.getString(
                              'notification.proactive.operations.v3',
                            )!,
                          )
                          as List)
                      .single
                  as Map)['outreachId']!
              as String;

      delivery.releaseSchedule();
      await _eventually(
        () => delivery.scheduled.any(
          (call) => call.notification.deliveryId == lateDeliveryId,
        ),
      );
      await _eventually(
        () => !delivery.activeDeliveryIds.contains(lateDeliveryId),
      );
      expect(
        (await runtime.coordinator.getOutreach(outreachId))?.state,
        OutreachState.scheduledOs,
      );

      now = DateTime(2026, 8, 10, 12, 1);
      await preferences.setGreetingsEnabled(false);
      await scheduler.sync();
      expect(
        (await runtime.coordinator.getOutreach(outreachId))?.state,
        OutreachState.assumedDelivered,
      );
      expect(shared.getString('notification.proactive.operations.v3'), isNull);
      scheduler.onClose();
    },
  );

  test(
    'platform sweep reconciles future orphans at the captured time',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      await preferences.setGreetingsEnabled(false);
      await preferences.setRandomCheckInsEnabled(false);
      var now = DateTime(2026, 8, 10, 10);
      final scheduler = await ProactiveSystemNotificationScheduler(
        preferences: preferences,
        delivery: _FakeDelivery(),
        foreground: AppForegroundService(),
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => now,
        random: Random(7),
        rollingHorizonDays: 1,
      ).init();
      final token = await scheduler.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      await scheduler.acknowledgePlatformSweep(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: token,
      );
      final runtime = await _newTestAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-a',
        clock: () => now,
      );
      final future = await runtime.ledger.tryScheduleOs(
        sourceEventId: 'future-source',
        deliveryId: 'future-delivery',
        topicKey: 'presence.quiet',
        scheduledFor: DateTime(2026, 8, 10, 10, 30),
        expiresAt: DateTime(2026, 8, 10, 12),
        dailyBudgetLimit: 3,
        now: DateTime(2026, 8, 10, 9),
      );
      final elapsed = await runtime.ledger.tryScheduleOs(
        sourceEventId: 'elapsed-source',
        deliveryId: 'elapsed-delivery',
        topicKey: 'presence.quiet',
        scheduledFor: DateTime(2026, 8, 10, 9, 30),
        expiresAt: DateTime(2026, 8, 10, 12),
        dailyBudgetLimit: 3,
        now: DateTime(2026, 8, 10, 9),
      );
      now = DateTime(2026, 8, 10, 11);
      await scheduler.bindAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-a',
        mountToken: token,
        coordinator: runtime.coordinator,
        proactivePreferences: _defaultProactivePreferences(),
      );
      await scheduler.activate();

      expect(
        (await runtime.coordinator.getOutreach(future!.outreachId))?.state,
        OutreachState.cancelled,
      );
      expect(
        (await runtime.coordinator.getOutreach(elapsed!.outreachId))?.state,
        OutreachState.scheduledOs,
      );
      scheduler.onClose();
    },
  );

  test(
    'device owner loss cancels a queued OS contact and denies new schedules',
    () async {
      final shared = await SharedPreferences.getInstance();
      final delivery = _FakeDelivery();
      final allowed = ValueNotifier(true);
      final scheduler = await _scheduler(
        shared: shared,
        preferences: await _enabledPreferences(shared),
        delivery: delivery,
        session: Rxn<MaasoAuthSession>(_validSession('account-a')),
        environment: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 10, 10),
        random: Random(7),
      );
      await scheduler.bindExecutionAuthority(
        allowed: () => allowed.value,
        changes: allowed,
      );
      await scheduler.activate();
      expect(delivery.activeDeliveryIds, hasLength(1));
      allowed.value = false;
      await scheduler.sync();
      expect(delivery.activeDeliveryIds, isEmpty);
      expect(delivery.scheduled, hasLength(1));
      scheduler.onClose();
      allowed.dispose();
    },
  );

  test(
    'one-time source uses stable identity, survives scheduler restart, then closes',
    () async {
      final shared = await SharedPreferences.getInstance();
      final now = DateTime(2026, 8, 10, 10);
      final runtime = await _newTestAccountRuntime(
        environmentKey: 'test',
        accountUuid: 'account-a',
        clock: () => now,
      );
      final writer = appServices.put(
        MemoryWriteCoordinator(
          database: runtime.database.raw,
          accountScopeDigest: 'a' * 64,
        ),
      );
      final prefs = appServices.put(
        await ProactivePreferenceService(
          store: SembastProactivePreferenceStore(
            runtime.database,
            accountScopeDigest: 'a' * 64,
          ),
          accountScopeDigest: 'a' * 64,
          generation: 1,
          clock: () => now,
        ).init(),
      );
      addTearDown(() async {
        await prefs.deactivateAndDrain();
        await writer.deactivateAndDrain();
        appServices.delete<ProactivePreferenceService>();
        appServices.delete<MemoryWriteCoordinator>();
      });
      final source = await MemoryGovernanceStores.chatMessages.add(
        runtime.database.raw,
        ChatMessage(
          sessionId: 'private',
          senderId: 'user',
          receiverId: 'self',
          content: '明天15点问我面试结果',
          timestamp: now,
          isUserMessage: true,
          turnOrigin: ChatMessageTurnOrigins.user,
          deliveryStatus: 'published',
        ).toJson(),
      );
      await writer.runWithPersistedChatSource(
        messageRecordId: source,
        sessionId: 'private',
        agentId: 'self',
        operation: prefs.observeCurrentTurn,
      );
      final delivery = _FakeDelivery();
      final devicePrefs = await _enabledPreferences(shared);
      Future<ProactiveSystemNotificationScheduler> create() async {
        final scheduler = await ProactiveSystemNotificationScheduler(
          preferences: devicePrefs,
          delivery: delivery,
          foreground: AppForegroundService(),
          sharedPreferences: shared,
          session: Rxn<MaasoAuthSession>(_validSession('account-a')),
          environmentSignal: MaasoEnvironment.test.obs,
          clock: () => now,
        ).init();
        final token = await scheduler.prepareAccountScope(
          environmentKey: 'test',
          accountUuid: 'account-a',
        );
        await scheduler.acknowledgePlatformSweep(
          environmentKey: 'test',
          accountUuid: 'account-a',
          mountToken: token,
        );
        await scheduler.bindAccountRuntime(
          environmentKey: 'test',
          accountUuid: 'account-a',
          mountToken: token,
          coordinator: runtime.coordinator,
          proactivePreferences: prefs.state,
        );
        await scheduler.activate();
        return scheduler;
      }

      final first = await create();
      expect(delivery.activeDeliveryIds, hasLength(1));
      final notification = delivery.scheduled.single.notification;
      expect(
        notification.data['sourceEventId'],
        'conversation-followup:${prefs.effectiveSnapshot.topics.single.id}',
      );
      expect(notification.body, isNot(contains('面试')));
      first.onClose();
      final second = await create();
      expect(delivery.activeDeliveryIds, contains(notification.deliveryId));
      expect(
        delivery.scheduled.map((call) => call.notification.deliveryId).toSet(),
        {notification.deliveryId},
      );
      await MemoryGovernanceStores.chatMessages
          .record(source)
          .delete(runtime.database.raw);
      await prefs.refreshContactSources();
      await second.sync();
      expect(delivery.activeDeliveryIds, isEmpty);
      expect(
        prefs.effectiveSnapshot.topics.single.status,
        ProactiveTopicStatus.revoked,
      );
      second.onClose();
    },
  );

  test('delivery without local scheduling authority remains idle', () async {
    final shared = await SharedPreferences.getInstance();
    final delivery = _NonSchedulingDelivery();
    late _TestAccountRuntime runtime;
    final scheduler = await _scheduler(
      shared: shared,
      preferences: await _enabledPreferences(shared),
      delivery: delivery,
      session: Rxn<MaasoAuthSession>(_validSession('account-a')),
      environment: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 10, 10),
      random: Random(7),
      onRuntime: (value) => runtime = value,
    );

    await scheduler.activate();
    await scheduler.sync();

    expect(delivery.scheduleAttemptIds, isEmpty);
    expect(await runtime.ledger.recent(limit: 8), isEmpty);
    expect(shared.getString('notification.proactive.operations.v3'), isNull);
    expect(
      shared.getString('notification.proactive.pending_cancellations.v2'),
      isNull,
    );
    scheduler.onClose();
  });
}

Map<String, Object?> _validScheduledOperationJson() {
  final target = DateTime(2026, 8, 11, 8);
  final epoch = target.toUtc().millisecondsSinceEpoch;
  const encodedScope = 'dGVzdA.YWNjb3VudC1h';
  return <String, Object?>{
    'scope': <String, Object?>{
      'environmentKey': 'test',
      'accountUuid': 'account-a',
    },
    'deliveryId': 'proactive:v3:$encodedScope:morning:$epoch',
    'sourceEventId': 'os:v3:$encodedScope:morning:$epoch',
    'key': 'morning',
    'kind': 'morningGreeting',
    'topicKey': 'presence.time.morning',
    'evidenceKey': null,
    'title': '早上好',
    'body': '测试通知',
    'prompt': '测试提示',
    'target': target.toUtc().toIso8601String(),
    'expiresAt': target.add(const Duration(hours: 4)).toUtc().toIso8601String(),
    'state': 'scheduled',
    'updatedAt': DateTime(2026, 8, 10, 10).toUtc().toIso8601String(),
    'revision': 0,
    'outreachId': 'scheduled-control',
    'releaseLedger': false,
    'reason': null,
  };
}

Map<String, Object?> _scheduledRandomOperationJson({
  required DateTime target,
  required String outreachId,
}) {
  final epoch = target.toUtc().millisecondsSinceEpoch;
  const encodedScope = 'dGVzdA.YWNjb3VudC1h';
  return <String, Object?>{
    'scope': <String, Object?>{
      'environmentKey': 'test',
      'accountUuid': 'account-a',
    },
    'deliveryId': 'proactive:v3:$encodedScope:random:$epoch',
    'sourceEventId': 'os:v3:$encodedScope:random:$epoch',
    'key': 'random',
    'kind': 'randomCheckIn',
    'topicKey': 'presence.quiet',
    'evidenceKey': null,
    'title': 'Maaso 想起了你',
    'body': '测试随机关心',
    'prompt': '测试随机提示',
    'target': target.toUtc().toIso8601String(),
    'expiresAt': target.add(const Duration(hours: 6)).toUtc().toIso8601String(),
    'state': 'scheduled',
    'updatedAt': DateTime(2026, 8, 10, 10).toUtc().toIso8601String(),
    'revision': 0,
    'outreachId': outreachId,
    'releaseLedger': false,
    'reason': null,
  };
}

var _databaseSequence = 0;

Future<ProactiveSystemNotificationScheduler> _scheduler({
  required SharedPreferences shared,
  required NotificationPreferencesService preferences,
  required _FakeDelivery delivery,
  required AppReactiveValue<MaasoAuthSession?> session,
  required AppReactiveValue<MaasoEnvironment> environment,
  required DateTime Function() clock,
  required Random random,
  Duration deliveryTimeout = const Duration(seconds: 5),
  Duration accountDrainGrace = const Duration(seconds: 2),
  Duration cancellationRetryDelay = const Duration(seconds: 15),
  int rollingHorizonDays = 1,
  ProactivePolicyConfig policyConfig = const ProactivePolicyConfig(),
  Rx<ProactivePreferenceSnapshot>? proactivePreferences,
  Future<bool> Function(String key, String value)? preferenceWriter,
  Future<void> Function()? onOutreachLedgerChanged,
  void Function(_TestAccountRuntime runtime)? onRuntime,
}) async {
  final scheduler = await ProactiveSystemNotificationScheduler(
    preferences: preferences,
    delivery: delivery,
    foreground: AppForegroundService(),
    sharedPreferences: shared,
    session: session,
    environmentSignal: environment,
    clock: clock,
    random: random,
    deliveryTimeout: deliveryTimeout,
    accountDrainGrace: accountDrainGrace,
    cancellationRetryDelay: cancellationRetryDelay,
    rollingHorizonDays: rollingHorizonDays,
    preferenceWriter: preferenceWriter,
  ).init();
  final current = session.value;
  if (current != null && current.isValid) {
    final runtime = await _bindSchedulerAccount(
      scheduler,
      environmentKey: environment.value.key,
      accountUuid: current.accountUuid,
      clock: clock,
      policyConfig: policyConfig,
      proactivePreferences:
          proactivePreferences ?? _proactivePreferencesFrom(preferences),
      onOutreachLedgerChanged: onOutreachLedgerChanged,
    );
    onRuntime?.call(runtime);
  }
  return scheduler;
}

Future<_TestAccountRuntime> _bindSchedulerAccount(
  ProactiveSystemNotificationScheduler scheduler, {
  required String environmentKey,
  required String accountUuid,
  required DateTime Function() clock,
  ProactivePolicyConfig policyConfig = const ProactivePolicyConfig(),
  Rx<ProactivePreferenceSnapshot>? proactivePreferences,
  Future<void> Function()? onOutreachLedgerChanged,
}) async {
  final runtime = await _newTestAccountRuntime(
    environmentKey: environmentKey,
    accountUuid: accountUuid,
    clock: clock,
    policyConfig: policyConfig,
  );
  final mountToken = await scheduler.prepareAccountScope(
    environmentKey: environmentKey,
    accountUuid: accountUuid,
  );
  await scheduler.acknowledgePlatformSweep(
    environmentKey: environmentKey,
    accountUuid: accountUuid,
    mountToken: mountToken,
  );
  await scheduler.bindAccountRuntime(
    environmentKey: environmentKey,
    accountUuid: accountUuid,
    mountToken: mountToken,
    coordinator: runtime.coordinator,
    proactivePreferences:
        proactivePreferences ?? _defaultProactivePreferences(),
    onOutreachLedgerChanged: onOutreachLedgerChanged,
  );
  return runtime;
}

Future<_TestAccountRuntime> _newTestAccountRuntime({
  required String environmentKey,
  required String accountUuid,
  required DateTime Function() clock,
  ProactivePolicyConfig policyConfig = const ProactivePolicyConfig(),
}) async {
  final database = await DBService().init(
    factory: databaseFactoryMemory,
    path: 'proactive-scheduler-${_databaseSequence++}.db',
  );
  addTearDown(database.close);
  final ledger = ProactiveOutreachLedger(accountDatabase: database);
  final coordinator = ProactiveOutreachCoordinator(
    policy: ProactiveCompanionPolicy(config: policyConfig),
    ledger: ledger,
    accountKey: '$environmentKey:$accountUuid',
    clock: clock,
  );
  return _TestAccountRuntime(
    database: database,
    ledger: ledger,
    coordinator: coordinator,
  );
}

final class _TestAccountRuntime {
  const _TestAccountRuntime({
    required this.database,
    required this.ledger,
    required this.coordinator,
  });

  final DBService database;
  final ProactiveOutreachLedger ledger;
  final ProactiveOutreachCoordinator coordinator;
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

Rx<ProactivePreferenceSnapshot> _defaultProactivePreferences() =>
    const ProactivePreferenceSnapshot.defaults(generation: 1)
        .copyWith(
          foregroundEnabled: true,
          osOutreachEnabled: true,
          consentRecorded: true,
          contactScope: ProactiveConversationScope.everyday,
          dailyBudget: 3,
        )
        .obs;

Rx<ProactivePreferenceSnapshot> _proactivePreferencesFrom(
  NotificationPreferencesService preferences,
) {
  final legacy = preferences.state.value;
  return ProactivePreferenceSnapshot.defaults(generation: 1)
      .copyWith(
        foregroundEnabled: true,
        osOutreachEnabled: true,
        consentRecorded: true,
        contactScope: ProactiveConversationScope.everyday,
        quietStartMinutes: legacy.quietStartMinutes,
        quietEndMinutes: legacy.quietEndMinutes,
        dailyBudget: legacy.dailyProactiveBudget.clamp(1, 3),
      )
      .obs;
}

MaasoAuthSession _validSession(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime(2099),
);

List<_ScheduledCall> _uniqueCallsByDeliveryId(Iterable<_ScheduledCall> calls) =>
    <String, _ScheduledCall>{
      for (final call in calls) call.notification.deliveryId: call,
    }.values.toList();

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
}

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

class _FakeDelivery implements NotificationDelivery {
  final scheduled = <_ScheduledCall>[];
  final scheduleAttemptIds = <String>[];
  final cancelled = <String>[];
  final activeDeliveryIds = <String>{};
  bool hangCancel = false;
  bool failCancel = false;
  bool gateCancel = false;
  bool gateSchedule = false;
  bool failSchedule = false;
  final Completer<void> cancelStarted = Completer<void>();
  final Completer<void> scheduleStarted = Completer<void>();
  final Completer<void> _cancelRelease = Completer<void>();
  final Completer<void> _scheduleRelease = Completer<void>();
  String? gatedScheduleDeliveryId;

  @override
  bool get isAvailable => true;

  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();

  @override
  Future<void> cancel(String deliveryId) async {
    cancelled.add(deliveryId);
    if (gateCancel) {
      if (!cancelStarted.isCompleted) cancelStarted.complete();
      await _cancelRelease.future;
    }
    if (hangCancel) return Completer<void>().future;
    if (failCancel) throw StateError('cancel failed');
    activeDeliveryIds.remove(deliveryId);
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
    scheduleAttemptIds.add(notification.deliveryId);
    if (failSchedule) throw StateError('schedule failed');
    if (gateSchedule) {
      gatedScheduleDeliveryId ??= notification.deliveryId;
      if (!scheduleStarted.isCompleted) scheduleStarted.complete();
      await _scheduleRelease.future;
    }
    activeDeliveryIds.add(notification.deliveryId);
    scheduled.add(
      _ScheduledCall(
        notification: notification,
        target: target,
        repeatsDaily: repeatsDaily,
      ),
    );
  }

  @override
  Future<void> show(MaasoNotification notification) async {}

  @override
  NotificationInteraction? takeInitialInteraction() => null;

  void releaseCancel() {
    if (!_cancelRelease.isCompleted) _cancelRelease.complete();
  }

  void releaseSchedule() {
    if (!_scheduleRelease.isCompleted) _scheduleRelease.complete();
  }

  void releaseScheduleWithError() {
    if (!_scheduleRelease.isCompleted) {
      _scheduleRelease.completeError(
        StateError('late schedule failed'),
        StackTrace.current,
      );
    }
  }
}

final class _NonSchedulingDelivery extends _FakeDelivery
    implements ScheduledNotificationDeliveryCapabilities {
  @override
  bool get supportsLocalScheduling => false;
}

final class _PreferenceWriteGate {
  _PreferenceWriteGate(this._preferences, {required this.matches});

  final SharedPreferences _preferences;
  final bool Function(String key, String value) matches;
  final Completer<void> started = Completer<void>();
  final Completer<bool> _release = Completer<bool>();
  bool _consumed = false;

  Future<bool> write(String key, String value) async {
    if (!_consumed && matches(key, value)) {
      _consumed = true;
      started.complete();
      final persist = await _release.future;
      if (!persist) return false;
    }
    return _preferences.setString(key, value);
  }

  void release({required bool persist}) {
    if (!_release.isCompleted) _release.complete(persist);
  }
}
