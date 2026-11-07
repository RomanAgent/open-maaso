import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/offline/offline_reminders.dart';
import 'package:maaso/src/offline/offline_skill.dart';
import 'package:maaso/src/offline/offline_store.dart';
import 'package:sembast/sembast_memory.dart';

class FakeDelivery
    implements NotificationDelivery, ScheduledNotificationDeliveryCapabilities {
  bool ready = false, granted = true, failCancel = false, failSchedule = false;
  int initializations = 0, permissions = 0, schedules = 0;
  final active = <String>{};
  final cancelled = <String>[];
  final entered = Completer<void>();
  Completer<void>? scheduling;
  MaasoNotification? last;
  DateTime? target;
  bool? daily;
  @override
  bool get isAvailable => ready;
  @override
  bool get supportsLocalScheduling => true;
  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();
  @override
  Future<void> initialize() async {
    initializations++;
    ready = true;
  }

  @override
  Future<bool> requestPermission() async {
    permissions++;
    return granted;
  }

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) async {
    schedules++;
    last = notification;
    this.target = target;
    daily = repeatsDaily;
    if (!entered.isCompleted) entered.complete();
    await scheduling?.future;
    if (failSchedule) throw StateError('raw platform diagnostic');
    active.add(notification.deliveryId);
  }

  @override
  Future<void> cancel(String deliveryId) async {
    cancelled.add(deliveryId);
    if (failCancel) throw StateError('raw platform diagnostic');
    active.remove(deliveryId);
  }

  @override
  Future<void> show(MaasoNotification notification) async =>
      throw StateError('immediate display not expected');
  @override
  NotificationInteraction? takeInitialInteraction() => null;
}

void main() {
  late OfflineStore store;
  late OfflineReminderService service;
  late FakeDelivery delivery;
  final now = DateTime.now();
  var count = 0;
  OfflineReminder reminder(
    String id, {
    OfflineReminderStatus status = OfflineReminderStatus.disabled,
    DateTime? at,
    bool daily = false,
  }) => OfflineReminder(
    id: id,
    title: 'Take a break',
    body: 'A local reminder',
    scheduledAt: at ?? now.add(const Duration(hours: 1)),
    createdAt: now,
    updatedAt: now,
    status: status,
    repeatsDaily: daily,
  );
  setUp(() async {
    store = await OfflineStore.open(
      factory: databaseFactoryMemory,
      path: 'reminders-${count++}.db',
      seedSamples: false,
    );
    delivery = FakeDelivery();
    service = OfflineReminderService(
      store: store,
      delivery: delivery,
      schedulingSupported: true,
      clock: () => now,
    );
  });
  tearDown(() async {
    service.dispose();
    await store.close();
  });

  test(
    'opening list and saving a draft never initializes or asks permission',
    () async {
      await service.load();
      await service.save(reminder('draft'));
      expect(delivery.initializations, 0);
      expect(delivery.permissions, 0);
      expect(delivery.schedules, 0);
      expect((await store.listReminders()).single.enabled, false);
    },
  );

  test(
    'explicit scheduling persists a native-only notification without prompt execution',
    () async {
      await service.save(reminder('scheduled'), schedule: true);
      expect(delivery.initializations, 1);
      expect(delivery.permissions, 1);
      expect(delivery.schedules, 1);
      expect(delivery.active, {'scheduled-task:open-maaso:scheduled'});
      expect(delivery.last!.prompt, isNull);
      expect(delivery.last!.data, {'offlineReminderId': 'scheduled'});
      expect(delivery.last!.kind, MaasoNotificationKind.scheduledTask);
      expect(delivery.target!.isAfter(now), true);
      expect((await store.getReminder('scheduled'))!.enabled, true);
      final reopenedService = OfflineReminderService(
        store: store,
        delivery: delivery,
        schedulingSupported: true,
      );
      await reopenedService.load();
      expect(delivery.permissions, 1);
      expect(delivery.schedules, 1);
      reopenedService.dispose();
      expect(delivery.active, isNotEmpty);
    },
  );

  test('permission denial keeps the draft and never schedules', () async {
    delivery.granted = false;
    await expectLater(
      service.save(reminder('denied'), schedule: true),
      throwsA(isA<OfflineReminderException>()),
    );
    expect(delivery.schedules, 0);
    final stored = (await store.getReminder('denied'))!;
    expect(stored.status, OfflineReminderStatus.failed);
    expect(stored.errorCode, 'permission_denied');
  });

  test(
    'disable and remove cancel platform requests before deleting local records',
    () async {
      await service.save(reminder('owned'), schedule: true);
      await service.disable('owned');
      expect(delivery.active, isEmpty);
      expect(
        (await store.getReminder('owned'))!.status,
        OfflineReminderStatus.disabled,
      );
      await service.enable('owned');
      delivery.failCancel = true;
      await expectLater(
        service.remove('owned'),
        throwsA(isA<OfflineReminderException>()),
      );
      expect(
        (await store.getReminder('owned'))!.status,
        OfflineReminderStatus.cancelPending,
      );
      delivery.failCancel = false;
      await service.remove('owned');
      expect(delivery.active, isEmpty);
      expect(await store.getReminder('owned'), isNull);
    },
  );

  test(
    'uncertain crash records recover by cancellation without permission or retry',
    () async {
      await store.upsertReminder(
        reminder('uncertain', status: OfflineReminderStatus.pending),
      );
      delivery.active.add('scheduled-task:open-maaso:uncertain');
      await service.load();
      expect(delivery.permissions, 0);
      expect(delivery.schedules, 0);
      expect(delivery.active, isEmpty);
      expect(
        (await store.getReminder('uncertain'))!.status,
        OfflineReminderStatus.disabled,
      );
    },
  );

  test(
    'scope cancellation during an OS schedule cannot leave a scheduled request',
    () async {
      delivery.scheduling = Completer<void>();
      final scheduling = service.save(reminder('racing'), schedule: true);
      final failure = expectLater(
        scheduling,
        throwsA(isA<OfflineReminderException>()),
      );
      await delivery.entered.future;
      final cancellation = service.cancelAll();
      delivery.scheduling!.complete();
      await failure;
      await cancellation;
      expect(delivery.active, isEmpty);
      expect((await store.getReminder('racing'))!.enabled, false);
    },
  );

  test(
    'timed-out native schedule stays journaled until late completion is revoked',
    () async {
      service.dispose();
      service = OfflineReminderService(
        store: store,
        delivery: delivery,
        schedulingSupported: true,
        clock: () => now,
        operationTimeout: const Duration(milliseconds: 5),
      );
      delivery.scheduling = Completer<void>();
      await expectLater(
        service.save(reminder('late'), schedule: true),
        throwsA(isA<OfflineReminderException>()),
      );
      expect(
        (await store.getReminder('late'))!.status,
        OfflineReminderStatus.cancelPending,
      );
      await expectLater(
        service.cancelAll(),
        throwsA(isA<OfflineReminderException>()),
      );
      delivery.scheduling!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await service.load();
      expect(delivery.active, isEmpty);
      expect(
        (await store.getReminder('late'))!.status,
        OfflineReminderStatus.disabled,
      );
    },
  );

  test(
    'past one-shot times fail before permission; repeating reminders advance locally',
    () async {
      await expectLater(
        service.save(
          reminder('past', at: now.subtract(const Duration(hours: 2))),
          schedule: true,
        ),
        throwsA(isA<OfflineReminderException>()),
      );
      expect(delivery.permissions, 0);
      expect(await store.getReminder('past'), isNull);
      await service.save(
        reminder(
          'daily',
          at: now.subtract(const Duration(days: 2)),
          daily: true,
        ),
        schedule: true,
      );
      expect(delivery.target!.isAfter(now), true);
      expect(delivery.daily, true);
    },
  );

  test(
    'unsupported platforms retain the local list without touching native notification APIs',
    () async {
      service.dispose();
      service = OfflineReminderService(
        store: store,
        delivery: delivery,
        schedulingSupported: false,
      );
      await service.save(reminder('web'));
      await service.load();
      expect(service.reminders.single.id, 'web');
      await expectLater(
        service.enable('web'),
        throwsA(isA<OfflineReminderException>()),
      );
      expect(delivery.initializations, 0);
      expect(delivery.permissions, 0);
      expect(delivery.schedules, 0);
    },
  );

  test(
    'schema3 backup includes skills and reminders but restores reminders disabled',
    () async {
      await service.save(reminder('backup'), schedule: true);
      await store.saveSkill(
        const OfflineSkill(
          id: 'custom',
          name: 'Useful prompt',
          instructions: 'Answer briefly.',
        ),
      );
      final backup = await store.exportJson();
      final document = jsonDecode(backup) as Map;
      expect(document['version'], 3);
      final restored = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: 'reminders-restored-${count++}',
        seedSamples: false,
      );
      addTearDown(restored.close);
      await restored.importJson(backup);
      expect((await restored.listReminders()).single.enabled, false);
      expect(
        (await restored.listReminders()).single.status,
        OfflineReminderStatus.disabled,
      );
      expect(
        (await restored.listSkills()).single.instructions,
        'Answer briefly.',
      );
      final invalid = jsonDecode(backup) as Map<String, dynamic>;
      (invalid['reminders'] as List).first['prompt'] = 'run a model request';
      await expectLater(
        restored.importJson(jsonEncode(invalid), replace: true),
        throwsFormatException,
      );
      expect((await restored.listReminders()).length, 1);
      final duplicates = jsonDecode(backup) as Map<String, dynamic>;
      (duplicates['skills'] as List).add((duplicates['skills'] as List).first);
      await expectLater(
        restored.importJson(jsonEncode(duplicates)),
        throwsFormatException,
      );
      await restored.deleteAccount();
      expect(await restored.listSkills(), isEmpty);
      expect(await restored.listReminders(), isEmpty);
    },
  );

  test(
    'schema2 database migrates additively without re-seeding user works',
    () async {
      final path = 'schema2-reminders-${count++}';
      final database = await databaseFactoryMemory.openDatabase(path);
      await StoreRef<String, Object?>(
        'offline_meta',
      ).record('schemaVersion').put(database, 2);
      await StoreRef<String, Object?>(
        'offline_meta',
      ).record('loggedIn').put(database, true);
      await database.close();
      final migrated = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
      );
      addTearDown(migrated.close);
      expect(await migrated.isLoggedIn(), true);
      expect(await migrated.listWorks(), isEmpty);
      expect(
        (await migrated.listSkills()).length,
        OfflineSkill.defaults.length,
      );
      final v2 =
          jsonDecode(await migrated.exportJson()) as Map<String, dynamic>;
      v2['version'] = 2;
      v2.remove('reminders');
      v2.remove('skills');
      await store.importJson(jsonEncode(v2));
      expect(await store.listReminders(), isEmpty);
    },
  );

  test(
    'reminder parsing rejects executable, oversized and malformed fields',
    () {
      final valid = reminder('bounded').toJson();
      final malformed = <Map<String, Object?>>[
        {...valid, 'id': '../outside'},
        {...valid, 'title': 'x' * 121},
        {...valid, 'body': 'x' * 1001},
        {...valid, 'body': 'hidden\u0000text'},
        {...valid, 'scheduledAt': -1},
        {...valid, 'updatedAt': 0},
        {...valid, 'status': 'execute'},
        {...valid, 'errorCode': 'raw diagnostic'},
        {...valid, 'repeatsDaily': 'yes'},
        {...valid, 'prompt': 'call the network'},
      ];
      for (final json in malformed) {
        expect(() => OfflineReminder.fromJson(json), throwsFormatException);
      }
    },
  );

  test('reminder count and imported skill bounds are atomic', () async {
    for (var i = 0; i < OfflineReminder.maxCount; i++) {
      await store.upsertReminder(reminder('r$i'));
    }
    await expectLater(
      store.upsertReminder(reminder('overflow')),
      throwsFormatException,
    );
    final backup = jsonDecode(await store.exportJson()) as Map<String, dynamic>;
    backup['skills'] = [
      const OfflineSkill(
        id: 'valid',
        name: 'Valid',
        instructions: 'Be concise.',
      ).toJson(),
      {
        'id': 'bad',
        'name': 'Bad',
        'instructions': 'x' * (OfflineSkill.maxInstructionLength + 1),
        'enabled': true,
      },
    ];
    await expectLater(
      store.importJson(jsonEncode(backup), replace: true),
      throwsFormatException,
    );
    expect(await store.listReminders(), hasLength(OfflineReminder.maxCount));
    expect(await store.listSkills(), isEmpty);
  });

  testWidgets('reminder page prompts only after an explicit save action', (
    tester,
  ) async {
    // Create the service's serialized Future chain in the widget test's zone.
    service.dispose();
    service = OfflineReminderService(
      store: store,
      delivery: delivery,
      schedulingSupported: true,
      clock: () => now,
    );
    await tester.pumpWidget(
      MaterialApp(home: OfflineRemindersPage(service: service)),
    );
    await tester.pumpAndSettle();
    expect(find.text('本地提醒'), findsOneWidget);
    expect(delivery.permissions, 0);
    await tester.tap(find.text('添加提醒'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'A user-requested reminder',
    );
    expect(delivery.permissions, 0);
    await tester.tap(find.text('保存提醒'));
    await tester.pumpAndSettle();
    expect(delivery.permissions, 1);
    expect(delivery.schedules, 1);
    expect(find.text('A user-requested reminder'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(delivery.active, isNotEmpty);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(delivery.active, isEmpty);
    expect(find.text('A user-requested reminder'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
