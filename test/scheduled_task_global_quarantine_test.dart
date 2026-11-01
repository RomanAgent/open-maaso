import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/scheduled_task_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('startup cancels and migrates orphan v3 before activating B', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-orphan';
    const accountB = 'account-b-current';
    const taskId = 't4';
    final legacyKey = _legacyStorageKey(environmentKey, accountA);
    final legacyDeliveryId = _legacyDeliveryId(
      environmentKey,
      accountA,
      taskId,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      legacyKey: jsonEncode(<Map<String, Object?>>[
        _legacyTask(
          environmentKey: environmentKey,
          accountUuid: accountA,
          taskId: taskId,
          prompt: 'A private reminder',
          systemScheduled: false,
        ),
      ]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();
    final session = Rxn<MaasoAuthSession>();

    final service = await ScheduledTaskService(
      delivery: delivery,
      sharedPreferences: shared,
      session: session,
      environmentSignal: MaasoEnvironment.test.obs,
      clock: () => DateTime(2026, 8, 20, 10),
    ).init();

    expect(delivery.cancelled, contains(legacyDeliveryId));
    expect(shared.get(legacyKey), isNull);
    final migrated = jsonDecode(
      shared.getString(
        ScheduledTaskService.storageKeyForScope(
          environmentKey: environmentKey,
          accountUuid: accountA,
        ),
      )!,
    );
    expect((migrated as List).single['systemScheduled'], isFalse);
    expect(migrated.single['prompt'], 'A private reminder');
    session.value = _validSession(accountB);
    expect((await service.list())['tasks'], isEmpty);

    service.onClose();
  });

  test(
    'cancel failure blocks B and a later retry completes quarantine',
    () async {
      const environmentKey = 'test';
      const accountA = 'account-a-retry';
      const accountB = 'account-b-retry';
      const taskId = 't8';
      final legacyKey = _legacyStorageKey(environmentKey, accountA);
      final legacyDeliveryId = _legacyDeliveryId(
        environmentKey,
        accountA,
        taskId,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        legacyKey: jsonEncode(<Map<String, Object?>>[
          _legacyTask(
            environmentKey: environmentKey,
            accountUuid: accountA,
            taskId: taskId,
            prompt: 'retry private reminder',
          ),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()..failCancels = true;
      final session = Rxn<MaasoAuthSession>();
      final service = await ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: session,
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      ).init();

      session.value = _validSession(accountB);
      expect((await service.list())['error'], 'global_quarantine_failed');
      expect(shared.get(legacyKey), isNotNull);
      expect(
        shared.getString(
          ScheduledTaskService.storageKeyForScope(
            environmentKey: environmentKey,
            accountUuid: accountB,
          ),
        ),
        isNull,
      );
      expect(
        jsonDecode(
          shared.getString('scheduled_tasks.pending_cancellations.v1')!,
        ),
        contains(legacyDeliveryId),
      );

      delivery.failCancels = false;
      final retried = await service.list();

      expect(retried['tasks'], isEmpty);
      expect(shared.get(legacyKey), isNull);
      expect(
        shared.getString('scheduled_tasks.pending_cancellations.v1'),
        isNull,
      );

      service.onClose();
    },
  );

  test('malformed v3 is cancelled and scrubbed without reaching B', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-malformed';
    const accountB = 'account-b-malformed';
    const taskId = 't2';
    const secretPrompt = 'A malformed private prompt';
    final legacyKey = _legacyStorageKey(environmentKey, accountA);
    final legacyDeliveryId = _legacyDeliveryId(
      environmentKey,
      accountA,
      taskId,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      legacyKey: jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'taskId': taskId,
          'deliveryId': legacyDeliveryId,
          'systemScheduled': 'not-a-bool',
          'prompt': secretPrompt,
        },
      ]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();
    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect(delivery.cancelled, contains(legacyDeliveryId));
    expect(shared.get(legacyKey), isNull);
    expect((await service.list())['tasks'], isEmpty);
    for (final key in shared.getKeys()) {
      expect('${shared.get(key)}', isNot(contains(secretPrompt)));
    }
    expect(
      shared.getString(
        ScheduledTaskService.storageKeyForScope(
          environmentKey: environmentKey,
          accountUuid: accountA,
        ),
      ),
      isNull,
    );

    service.onClose();
  });

  test('failed malformed cancel keeps a scrubbed marker for restart', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-malformed-retry';
    const accountB = 'account-b-malformed-retry';
    const taskId = 't6';
    const secretPrompt = 'scrub before retrying this private prompt';
    final legacyKey = _legacyStorageKey(environmentKey, accountA);
    final legacyDeliveryId = _legacyDeliveryId(
      environmentKey,
      accountA,
      taskId,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      legacyKey: jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'taskId': taskId,
          'deliveryId': legacyDeliveryId,
          'systemScheduled': 'corrupt',
          'prompt': secretPrompt,
        },
      ]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery()..failCancels = true;
    final first = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect((await first.list())['error'], 'global_quarantine_failed');
    final scrubbed = shared.getString(legacyKey);
    expect(scrubbed, isNotNull);
    expect(scrubbed, contains('maaso_scheduled_task_v3_scrubbed'));
    expect(scrubbed, contains(legacyDeliveryId));
    expect(scrubbed, isNot(contains(secretPrompt)));
    first.onClose();

    delivery.failCancels = false;
    final restarted = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect((await restarted.list())['tasks'], isEmpty);
    expect(shared.get(legacyKey), isNull);
    expect(delivery.cancelled, contains(legacyDeliveryId));

    restarted.onClose();
  });

  test(
    'unresolvable v3 prompt is scrubbed and durably blocks scopes',
    () async {
      const environmentKey = 'test';
      const accountA = 'account-a-unresolvable';
      const accountB = 'account-b-unresolvable';
      const secretPrompt = 'A prompt with no recoverable delivery id';
      final legacyKey = _legacyStorageKey(environmentKey, accountA);
      SharedPreferences.setMockInitialValues(<String, Object>{
        legacyKey: jsonEncode(<String, Object?>{
          'prompt': secretPrompt,
          'corrupted': true,
        }),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery();
      final first = await _service(
        shared: shared,
        delivery: delivery,
        accountUuid: accountB,
      );

      expect((await first.list())['error'], 'global_quarantine_failed');
      final scrubbed = shared.getString(legacyKey);
      expect(scrubbed, isNotNull);
      expect(scrubbed, contains('maaso_scheduled_task_v3_scrubbed'));
      expect(scrubbed, isNot(contains(secretPrompt)));
      final faultMarker = shared.getString(
        'scheduled_tasks.legacy_quarantine_fault.v1',
      );
      expect(faultMarker, isNotNull);
      expect(faultMarker, isNot(contains(secretPrompt)));
      expect(faultMarker, isNot(contains(accountA)));
      expect(faultMarker, isNot(contains(_legacyEncode(accountA))));
      first.onClose();

      final restarted = await _service(
        shared: shared,
        delivery: delivery,
        accountUuid: accountB,
      );
      expect((await restarted.list())['error'], 'global_quarantine_failed');
      expect(shared.getString(legacyKey), isNot(contains(secretPrompt)));
      expect(delivery.cancelled, isEmpty);

      restarted.onClose();
    },
  );

  test('orphan v4 delivery is cancelled before B scope activates', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-orphan';
    const accountB = 'account-b-v4-current';
    const taskId = 't12';
    const prompt = 'Keep this task for A to restore later';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    final deliveryId = _v4DeliveryId(storageKey, taskId);
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[
        _v4Task(
          environmentKey: environmentKey,
          accountUuid: accountA,
          storageKey: storageKey,
          taskId: taskId,
          prompt: prompt,
        ),
      ]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();

    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect(delivery.cancelled, contains(deliveryId));
    final retained = (jsonDecode(shared.getString(storageKey)!) as List).single;
    expect(retained['systemScheduled'], isFalse);
    expect(retained['prompt'], prompt);
    expect((await service.list())['tasks'], isEmpty);
    expect(
      shared.getString(
        ScheduledTaskService.storageKeyForScope(
          environmentKey: environmentKey,
          accountUuid: accountB,
        ),
      ),
      isNull,
    );

    service.onClose();
  });

  test('orphan v4 cancel failure blocks B and retry preserves A', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-retry';
    const accountB = 'account-b-v4-retry';
    const taskId = 't18';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    final deliveryId = _v4DeliveryId(storageKey, taskId);
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[
        _v4Task(
          environmentKey: environmentKey,
          accountUuid: accountA,
          storageKey: storageKey,
          taskId: taskId,
          prompt: 'Retry this A-only delivery cleanup',
        ),
      ]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery()..failCancels = true;
    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    final blocked = await service.list();
    expect(blocked['error'], 'global_quarantine_failed');
    expect(blocked['cause'], 'delivery_cancel_failed');
    expect(
      (jsonDecode(shared.getString(storageKey)!) as List)
          .single['systemScheduled'],
      isTrue,
    );
    expect(
      jsonDecode(shared.getString('scheduled_tasks.pending_cancellations.v1')!),
      contains(deliveryId),
    );

    delivery.failCancels = false;
    final retried = await service.list();

    expect(retried['tasks'], isEmpty);
    expect(
      delivery.cancelled.where((id) => id == deliveryId).length,
      greaterThan(1),
    );
    expect(
      (jsonDecode(shared.getString(storageKey)!) as List)
          .single['systemScheduled'],
      isFalse,
    );
    expect(
      shared.getString('scheduled_tasks.pending_cancellations.v1'),
      isNull,
    );

    service.onClose();
  });

  for (final corrupt in <String, String>{
    'invalid JSON': '{not-json',
    'non-list JSON': jsonEncode(<String, Object?>{'deliveryId': 'lost'}),
  }.entries) {
    test(
      'corrupt cancellation journal (${corrupt.key}) fails closed',
      () async {
        const accountB = 'account-b-corrupt-journal';
        SharedPreferences.setMockInitialValues(<String, Object>{
          'scheduled_tasks.pending_cancellations.v1': corrupt.value,
        });
        final shared = await SharedPreferences.getInstance();
        final delivery = _QuarantineDelivery();
        final service = await _service(
          shared: shared,
          delivery: delivery,
          accountUuid: accountB,
        );

        final blocked = await service.list();
        expect(blocked['error'], 'global_quarantine_failed');
        expect(blocked['cause'], 'cleanup_journal_corrupt');
        expect(
          shared.getString(
            ScheduledTaskService.storageKeyForScope(
              environmentKey: 'test',
              accountUuid: accountB,
            ),
          ),
          isNull,
        );

        await shared.setString(
          'scheduled_tasks.pending_cancellations.v1',
          '[]',
        );
        expect((await service.list())['tasks'], isEmpty);

        service.onClose();
      },
    );
  }

  test('unresolvable orphan v4 keeps B in global quarantine', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-malformed';
    const accountB = 'account-b-v4-malformed';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    const secretPrompt = 'Malformed A task must never be admitted to B';
    final malformed = <String, Object?>{'prompt': secretPrompt};
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[malformed]),
    });
    final shared = await SharedPreferences.getInstance();
    final service = await _service(
      shared: shared,
      delivery: _QuarantineDelivery(),
      accountUuid: accountB,
    );

    final blocked = await service.list();
    expect(blocked['error'], 'global_quarantine_failed');
    expect(blocked['cause'], 'orphan_v4_malformed');
    expect(
      shared.getString(storageKey),
      contains('maaso_scheduled_task_v4_scrubbed'),
    );
    expect(shared.getString(storageKey), isNot(contains(secretPrompt)));

    service.onClose();
  });

  test('recoverable malformed v4 is scrubbed and cancelled for A', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-active-malformed';
    const taskId = 't24';
    const secretPrompt = 'Malformed active A prompt';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    final deliveryId = _v4DeliveryId(storageKey, taskId);
    final malformed = _v4Task(
      environmentKey: environmentKey,
      accountUuid: accountA,
      storageKey: storageKey,
      taskId: taskId,
      prompt: secretPrompt,
    )..['repeat'] = 'sometimes';
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[malformed]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();
    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountA,
    );

    expect(delivery.cancelled, contains(deliveryId));
    expect((await service.list())['tasks'], isEmpty);
    expect(shared.getString(storageKey), isNot(contains(secretPrompt)));

    service.onClose();
  });

  test('mixed orphan v4 keeps valid task and cancels malformed id', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-mixed';
    const accountB = 'account-b-v4-mixed';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    final valid = _v4Task(
      environmentKey: environmentKey,
      accountUuid: accountA,
      storageKey: storageKey,
      taskId: 't25',
      prompt: 'Valid A task survives quarantine',
    );
    const malformedPrompt = 'Malformed mixed A prompt is scrubbed';
    final malformed = _v4Task(
      environmentKey: environmentKey,
      accountUuid: accountA,
      storageKey: storageKey,
      taskId: 't26',
      prompt: malformedPrompt,
    )..['when'] = 'not-a-time';
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[valid, malformed]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();
    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect(delivery.cancelled, contains(_v4DeliveryId(storageKey, 't25')));
    expect(delivery.cancelled, contains(_v4DeliveryId(storageKey, 't26')));
    final retained = jsonDecode(shared.getString(storageKey)!) as List;
    expect(retained, hasLength(1));
    expect(retained.single['taskId'], 't25');
    expect(retained.single['systemScheduled'], isFalse);
    expect(retained.single['prompt'], 'Valid A task survives quarantine');
    expect(shared.getString(storageKey), isNot(contains(malformedPrompt)));
    expect((await service.list())['tasks'], isEmpty);

    service.onClose();
  });

  test('failed malformed v4 cancel restarts from scrubbed authority', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-marker-retry';
    const accountB = 'account-b-v4-marker-retry';
    const taskId = 't27';
    const secretPrompt = 'Scrub malformed v4 before failed cancel';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    final deliveryId = _v4DeliveryId(storageKey, taskId);
    final malformed = _v4Task(
      environmentKey: environmentKey,
      accountUuid: accountA,
      storageKey: storageKey,
      taskId: taskId,
      prompt: secretPrompt,
    )..['repeat'] = 'invalid';
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[malformed]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery()..failCancels = true;
    final first = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect((await first.list())['error'], 'global_quarantine_failed');
    expect(
      shared.getString(storageKey),
      contains('maaso_scheduled_task_v4_scrubbed'),
    );
    expect(shared.getString(storageKey), isNot(contains(secretPrompt)));
    first.onClose();

    delivery.failCancels = false;
    final restarted = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect((await restarted.list())['tasks'], isEmpty);
    expect(delivery.cancelled, contains(deliveryId));
    expect(jsonDecode(shared.getString(storageKey)!), isEmpty);

    restarted.onClose();
  });

  test('native orphan v4 false is still cancelled defensively', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-false';
    const accountB = 'account-b-v4-false';
    const taskId = 't28';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    final deliveryId = _v4DeliveryId(storageKey, taskId);
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[
        _v4Task(
          environmentKey: environmentKey,
          accountUuid: accountA,
          storageKey: storageKey,
          taskId: taskId,
          prompt: 'Historical false is not proof on native',
          systemScheduled: false,
        ),
      ]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();
    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect(delivery.cancelled, contains(deliveryId));
    expect((await service.list())['tasks'], isEmpty);

    service.onClose();
  });

  test(
    'Windows orphan false does not require unavailable OS delivery',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const environmentKey = 'test';
      const accountA = 'account-a-windows-foreground';
      const accountB = 'account-b-windows-foreground';
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: environmentKey,
        accountUuid: accountA,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        storageKey: jsonEncode(<Map<String, Object?>>[
          _v4Task(
            environmentKey: environmentKey,
            accountUuid: accountA,
            storageKey: storageKey,
            taskId: 't29',
            prompt: 'Windows foreground-only task',
            systemScheduled: false,
          ),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()..available = false;
      final service = await _service(
        shared: shared,
        delivery: delivery,
        accountUuid: accountB,
      );

      expect(delivery.cancelled, isEmpty);
      expect((await service.list())['tasks'], isEmpty);
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isFalse,
      );

      service.onClose();
    },
  );

  test(
    'mixed corrupt journal salvages safe id and repair forces false',
    () async {
      const environmentKey = 'test';
      const accountB = 'account-b-corrupt-target';
      const taskId = 't30';
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: environmentKey,
        accountUuid: accountB,
      );
      final deliveryId = _v4DeliveryId(storageKey, taskId);
      SharedPreferences.setMockInitialValues(<String, Object>{
        storageKey: jsonEncode(<Map<String, Object?>>[
          _v4Task(
            environmentKey: environmentKey,
            accountUuid: accountB,
            storageKey: storageKey,
            taskId: taskId,
            prompt: 'Target must be rearmed after journal repair',
          ),
        ]),
        'scheduled_tasks.pending_cancellations.v1': jsonEncode(<Object?>[
          deliveryId,
          'unsafe-entry',
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery();
      final first = await _service(
        shared: shared,
        delivery: delivery,
        accountUuid: accountB,
      );

      expect((await first.list())['error'], 'global_quarantine_failed');
      expect(delivery.cancelled, contains(deliveryId));
      expect(
        jsonDecode(
          shared.getString('scheduled_tasks.pending_cancellations.v1')!,
        ),
        contains('unsafe-entry'),
      );
      expect(
        jsonDecode(
          shared.getString('scheduled_tasks.corrupt_journal_salvage.v1')!,
        ),
        contains(deliveryId),
      );
      first.onClose();

      await shared.setString('scheduled_tasks.pending_cancellations.v1', '[]');
      final restarted = await _service(
        shared: shared,
        delivery: delivery,
        accountUuid: accountB,
      );
      final tasks = (await restarted.list())['tasks']! as List;

      expect(tasks, hasLength(1));
      expect(tasks.single['systemScheduled'], isFalse);
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isFalse,
      );
      expect(
        shared.getString('scheduled_tasks.corrupt_journal_salvage.v1'),
        isNull,
      );

      restarted.onClose();
    },
  );

  test('invalid v4 JSON taskId is recovered and scrubbed', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-invalid-json';
    const accountB = 'account-b-v4-invalid-json';
    const taskId = 't31';
    const secretPrompt = 'invalid json secret';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: '[{"taskId":"$taskId","prompt":"$secretPrompt"',
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();
    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect(delivery.cancelled, contains(_v4DeliveryId(storageKey, taskId)));
    expect((await service.list())['tasks'], isEmpty);
    expect(shared.getString(storageKey), isNot(contains(secretPrompt)));

    service.onClose();
  });

  test('malformed v4 cancels derived v4 and provided legacy id', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v4-mismatch';
    const accountOther = 'account-other-v4-mismatch';
    const accountB = 'account-b-v4-mismatch';
    final storageKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountA,
    );
    final derivedId = _v4DeliveryId(storageKey, 't32');
    final providedId = _legacyDeliveryId(environmentKey, accountOther, 't33');
    final malformed = _v4Task(
      environmentKey: environmentKey,
      accountUuid: accountA,
      storageKey: storageKey,
      taskId: 't32',
      prompt: 'mismatched delivery',
    )..['deliveryId'] = providedId;
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[malformed]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();
    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect(delivery.cancelled, containsAll(<String>[derivedId, providedId]));
    expect((await service.list())['tasks'], isEmpty);

    service.onClose();
  });

  test('malformed v3 cancels derived legacy and provided v4 id', () async {
    const environmentKey = 'test';
    const accountA = 'account-a-v3-mismatch';
    const accountOther = 'account-other-v3-mismatch';
    const accountB = 'account-b-v3-mismatch';
    final storageKey = _legacyStorageKey(environmentKey, accountA);
    final derivedId = _legacyDeliveryId(environmentKey, accountA, 't34');
    final otherKey = ScheduledTaskService.storageKeyForScope(
      environmentKey: environmentKey,
      accountUuid: accountOther,
    );
    final providedId = _v4DeliveryId(otherKey, 't35');
    final malformed = _legacyTask(
      environmentKey: environmentKey,
      accountUuid: accountA,
      taskId: 't34',
      prompt: 'legacy mismatched delivery',
    )..['deliveryId'] = providedId;
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode(<Map<String, Object?>>[malformed]),
    });
    final shared = await SharedPreferences.getInstance();
    final delivery = _QuarantineDelivery();
    final service = await _service(
      shared: shared,
      delivery: delivery,
      accountUuid: accountB,
    );

    expect(delivery.cancelled, containsAll(<String>[derivedId, providedId]));
    expect((await service.list())['tasks'], isEmpty);

    service.onClose();
  });

  test(
    'prepareAccountScope blocks mount admission and retries cleanup',
    () async {
      const environmentKey = 'test';
      const accountA = 'account-a-prepare-gate';
      const accountB = 'account-b-prepare-gate';
      final legacyKey = _legacyStorageKey(environmentKey, accountA);
      SharedPreferences.setMockInitialValues(<String, Object>{
        legacyKey: jsonEncode(<Map<String, Object?>>[
          _legacyTask(
            environmentKey: environmentKey,
            accountUuid: accountA,
            taskId: 't36',
            prompt: 'prepare gate cleanup',
          ),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()..failCancels = true;
      final service = await ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      ).init();

      await expectLater(
        service.prepareAccountScope(
          environmentKey: environmentKey,
          accountUuid: accountB,
        ),
        throwsA(isA<ScheduledTaskAccountScopePreparationFailure>()),
      );

      delivery.failCancels = false;
      await service.prepareAccountScope(
        environmentKey: environmentKey,
        accountUuid: accountB,
      );

      service.onClose();
    },
  );

  test(
    'prepare cancels an OS-authoritative task with no prefs authority',
    () async {
      const orphanDeliveryId =
          'scheduled-task:v4:'
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd:t9';
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()
        ..supportsPlatformSweep = true
        ..platformPending.add(orphanDeliveryId);
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      );

      await service.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: 'account-b-platform-orphan',
      );

      expect(delivery.cancelled, contains(orphanDeliveryId));
      expect(delivery.platformSweepAttempts, 1);
      service.onClose();
    },
  );

  test(
    'platform sweep rewrites target and active v4 authority false',
    () async {
      const accountB = 'account-b-platform-target';
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );
      final deliveryId = _v4DeliveryId(storageKey, 't10');
      SharedPreferences.setMockInitialValues(<String, Object>{
        storageKey: jsonEncode(<Map<String, Object?>>[
          _v4Task(
            environmentKey: 'test',
            accountUuid: accountB,
            storageKey: storageKey,
            taskId: 't10',
            prompt: 'target prompt is rescheduled only after mount',
            systemScheduled: true,
          ),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()
        ..supportsPlatformSweep = true
        ..platformPending.add(deliveryId);
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      );

      await service.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );

      final stored = jsonDecode(shared.getString(storageKey)!) as List;
      expect(stored.single['systemScheduled'], isFalse);
      expect(delivery.cancelled, contains(deliveryId));
      service.onClose();
    },
  );

  test(
    'platform enumeration failure blocks admission and retry succeeds',
    () async {
      const accountB = 'account-b-platform-retry';
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        storageKey: jsonEncode(<Map<String, Object?>>[
          _v4Task(
            environmentKey: 'test',
            accountUuid: accountB,
            storageKey: storageKey,
            taskId: 't11',
            prompt: 'retry platform enumeration',
            systemScheduled: true,
          ),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()
        ..supportsPlatformSweep = true
        ..platformSweepFailuresRemaining = 1;
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      );

      await expectLater(
        service.prepareAccountScope(
          environmentKey: 'test',
          accountUuid: accountB,
        ),
        throwsA(isA<ScheduledTaskAccountScopePreparationFailure>()),
      );
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isTrue,
      );

      await service.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isFalse,
      );
      expect(delivery.platformSweepAttempts, 2);
      service.onClose();
    },
  );

  test(
    'authoritative sweep repairs corrupt journal and unresolved source fault',
    () async {
      const accountA = 'account-a-authoritative-repair';
      const accountB = 'account-b-authoritative-repair';
      const secretPrompt = 'unresolved A prompt must be scrubbed';
      final legacyKey = _legacyStorageKey('test', accountA);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'scheduled_tasks.pending_cancellations.v1': '{not-json',
        'scheduled_tasks.corrupt_journal_salvage.v1': jsonEncode(<String>[
          'scheduled-task:v4:'
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:t7',
        ]),
        'scheduled_tasks.legacy_quarantine_fault.v1': jsonEncode(<String>[
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ]),
        legacyKey: jsonEncode(<Map<String, Object?>>[
          <String, Object?>{'prompt': secretPrompt},
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()..supportsPlatformSweep = true;
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      );

      await service.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );

      expect(delivery.platformSweepAttempts, 1);
      expect(shared.get(legacyKey), isNull);
      expect(
        shared.getString('scheduled_tasks.pending_cancellations.v1'),
        anyOf(isNull, '[]'),
      );
      expect(
        shared.getString('scheduled_tasks.corrupt_journal_salvage.v1'),
        anyOf(isNull, '[]'),
      );
      expect(
        shared.getString('scheduled_tasks.legacy_quarantine_fault.v1'),
        anyOf(isNull, '[]'),
      );
      for (final key in shared.getKeys()) {
        expect('${shared.get(key)}', isNot(contains(secretPrompt)));
      }
      service.onClose();
    },
  );

  test(
    'no-platform authority repairs corrupt journal and malformed v4',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const accountA = 'account-a-windows-no-authority';
      const accountB = 'account-b-windows-no-authority';
      const secretPrompt = 'Windows malformed A prompt';
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: accountA,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'scheduled_tasks.pending_cancellations.v1': '{not-json',
        storageKey: jsonEncode(<Map<String, Object?>>[
          <String, Object?>{'prompt': secretPrompt},
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()..hasNoPlatformAuthority = true;
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
      );

      await service.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );

      expect(delivery.platformSweepAttempts, 1);
      expect(delivery.cancelled, isEmpty);
      expect(shared.getString(storageKey), anyOf(isNull, '[]'));
      for (final key in shared.getKeys()) {
        expect('${shared.get(key)}', isNot(contains(secretPrompt)));
      }
      service.onClose();
    },
  );

  test(
    'sweep marker repair failure blocks admission and repeats sweep on retry',
    () async {
      const accountB = 'account-b-authoritative-repair-retry';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'scheduled_tasks.pending_cancellations.v1': '{not-json',
        'scheduled_tasks.legacy_quarantine_fault.v1': jsonEncode(<String>[
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery()..supportsPlatformSweep = true;
      var failFaultRepair = true;
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
        preferenceWriter: (key, value) {
          if (failFaultRepair &&
              key == 'scheduled_tasks.legacy_quarantine_fault.v1' &&
              value == '[]') {
            return Future<bool>.value(false);
          }
          return shared.setString(key, value);
        },
      );

      await expectLater(
        service.prepareAccountScope(
          environmentKey: 'test',
          accountUuid: accountB,
        ),
        throwsA(
          isA<ScheduledTaskAccountScopePreparationFailure>().having(
            (error) => error.cause,
            'cause',
            'authoritative_sweep_marker_cleanup_failed',
          ),
        ),
      );
      expect(delivery.platformSweepAttempts, 1);
      expect(
        shared.getString('scheduled_tasks.legacy_quarantine_fault.v1'),
        isNot('[]'),
      );

      failFaultRepair = false;
      await service.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );

      expect(delivery.platformSweepAttempts, 2);
      expect(
        shared.getString('scheduled_tasks.legacy_quarantine_fault.v1'),
        anyOf(isNull, '[]'),
      );
      service.onClose();
    },
  );

  test(
    'v4 journal write failure still cancels and retains source for retry',
    () async {
      const accountA = 'account-a-v4-journal-fail';
      const accountB = 'account-b-v4-journal-fail';
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: accountA,
      );
      final deliveryId = _v4DeliveryId(storageKey, 't12');
      SharedPreferences.setMockInitialValues(<String, Object>{
        storageKey: jsonEncode(<Map<String, Object?>>[
          _v4Task(
            environmentKey: 'test',
            accountUuid: accountA,
            storageKey: storageKey,
            taskId: 't12',
            prompt: 'source authority retained',
          ),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery();
      var failJournal = true;
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
        preferenceWriter: (key, value) {
          if (failJournal &&
              key == 'scheduled_tasks.pending_cancellations.v1') {
            return Future<bool>.value(false);
          }
          return shared.setString(key, value);
        },
      );

      await expectLater(
        service.prepareAccountScope(
          environmentKey: 'test',
          accountUuid: accountB,
        ),
        throwsA(isA<ScheduledTaskAccountScopePreparationFailure>()),
      );
      expect(delivery.cancelled, contains(deliveryId));
      expect(shared.getString(storageKey), isNotNull);
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isTrue,
      );

      failJournal = false;
      await service.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );
      expect(
        (jsonDecode(shared.getString(storageKey)!) as List)
            .single['systemScheduled'],
        isFalse,
      );
      service.onClose();
    },
  );

  test(
    'v3 journal write failure still cancels and retains source for retry',
    () async {
      const accountA = 'account-a-v3-journal-fail';
      const accountB = 'account-b-v3-journal-fail';
      final storageKey = _legacyStorageKey('test', accountA);
      final deliveryId = _legacyDeliveryId('test', accountA, 't13');
      SharedPreferences.setMockInitialValues(<String, Object>{
        storageKey: jsonEncode(<Map<String, Object?>>[
          _legacyTask(
            environmentKey: 'test',
            accountUuid: accountA,
            taskId: 't13',
            prompt: 'legacy source authority retained',
          ),
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery();
      var failJournal = true;
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
        preferenceWriter: (key, value) {
          if (failJournal &&
              key == 'scheduled_tasks.pending_cancellations.v1') {
            return Future<bool>.value(false);
          }
          return shared.setString(key, value);
        },
      );

      await expectLater(
        service.prepareAccountScope(
          environmentKey: 'test',
          accountUuid: accountB,
        ),
        throwsA(isA<ScheduledTaskAccountScopePreparationFailure>()),
      );
      expect(delivery.cancelled, contains(deliveryId));
      expect(shared.getString(storageKey), isNotNull);

      failJournal = false;
      await service.prepareAccountScope(
        environmentKey: 'test',
        accountUuid: accountB,
      );
      expect(shared.get(storageKey), isNull);
      service.onClose();
    },
  );

  test(
    'fault persistence failure still cancels recoverable malformed v4 id',
    () async {
      const accountA = 'account-a-v4-fault-write';
      const accountB = 'account-b-v4-fault-write';
      const secretPrompt = 'must be scrubbed before the fault write';
      final storageKey = ScheduledTaskService.storageKeyForScope(
        environmentKey: 'test',
        accountUuid: accountA,
      );
      final deliveryId = _v4DeliveryId(storageKey, 't14');
      SharedPreferences.setMockInitialValues(<String, Object>{
        storageKey: jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'taskId': 't14',
            'deliveryId': 'foreign:unsafe',
            'prompt': secretPrompt,
          },
        ]),
      });
      final shared = await SharedPreferences.getInstance();
      final delivery = _QuarantineDelivery();
      final service = ScheduledTaskService(
        delivery: delivery,
        sharedPreferences: shared,
        session: Rxn<MaasoAuthSession>(),
        environmentSignal: MaasoEnvironment.test.obs,
        clock: () => DateTime(2026, 8, 20, 10),
        preferenceWriter: (key, value) {
          if (key == 'scheduled_tasks.legacy_quarantine_fault.v1') {
            return Future<bool>.value(false);
          }
          return shared.setString(key, value);
        },
      );

      await expectLater(
        service.prepareAccountScope(
          environmentKey: 'test',
          accountUuid: accountB,
        ),
        throwsA(isA<ScheduledTaskAccountScopePreparationFailure>()),
      );

      expect(delivery.cancelled, contains(deliveryId));
      final scrubbed = shared.getString(storageKey);
      expect(scrubbed, isNotNull);
      expect(scrubbed, isNot(contains(secretPrompt)));
      expect(scrubbed, contains(deliveryId));
      service.onClose();
    },
  );
}

Future<ScheduledTaskService> _service({
  required SharedPreferences shared,
  required NotificationDelivery delivery,
  required String accountUuid,
}) => ScheduledTaskService(
  delivery: delivery,
  sharedPreferences: shared,
  session: Rxn<MaasoAuthSession>(_validSession(accountUuid)),
  environmentSignal: MaasoEnvironment.test.obs,
  clock: () => DateTime(2026, 8, 20, 10),
).init();

MaasoAuthSession _validSession(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime(2099),
);

Map<String, Object?> _legacyTask({
  required String environmentKey,
  required String accountUuid,
  required String taskId,
  required String prompt,
  bool systemScheduled = true,
}) => <String, Object?>{
  'environmentKey': environmentKey,
  'accountUuid': accountUuid,
  'taskId': taskId,
  'when': '11:30',
  'repeat': 'daily',
  'prompt': prompt,
  'targetAt': DateTime(2099, 1, 1, 11, 30).toUtc().toIso8601String(),
  'timezone': 'UTC',
  'timezoneOffsetMinutes': 0,
  'deliveryId': _legacyDeliveryId(environmentKey, accountUuid, taskId),
  'systemScheduled': systemScheduled,
  'status': 'scheduled',
};

Map<String, Object?> _v4Task({
  required String environmentKey,
  required String accountUuid,
  required String storageKey,
  required String taskId,
  required String prompt,
  bool systemScheduled = true,
}) => <String, Object?>{
  'environmentKey': environmentKey,
  'accountUuid': accountUuid,
  'taskId': taskId,
  'when': '11:30',
  'repeat': 'daily',
  'prompt': prompt,
  'targetAt': DateTime(2099, 1, 1, 11, 30).toUtc().toIso8601String(),
  'timezone': 'UTC',
  'timezoneOffsetMinutes': 0,
  'deliveryId': _v4DeliveryId(storageKey, taskId),
  'systemScheduled': systemScheduled,
  'status': 'scheduled',
};

String _v4DeliveryId(String storageKey, String taskId) =>
    'scheduled-task:v4:${storageKey.split('.').last}:$taskId';

String _legacyStorageKey(String environmentKey, String accountUuid) =>
    'scheduled_tasks.v3.${_legacyEncode(environmentKey)}.'
    '${_legacyEncode(accountUuid)}';

String _legacyDeliveryId(
  String environmentKey,
  String accountUuid,
  String taskId,
) =>
    'scheduled-task:${_legacyEncode(environmentKey)}:'
    '${_legacyEncode(accountUuid)}:$taskId';

String _legacyEncode(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

final class _QuarantineDelivery
    implements NotificationDelivery, ScheduledNotificationQuarantine {
  final List<String> cancelled = <String>[];
  final Set<String> platformPending = <String>{};
  bool failCancels = false;
  bool supportsPlatformSweep = false;
  bool hasNoPlatformAuthority = false;
  int platformSweepFailuresRemaining = 0;
  int platformSweepAttempts = 0;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  Stream<NotificationInteraction> get interactions => const Stream.empty();

  @override
  Future<void> cancel(String deliveryId) async {
    cancelled.add(deliveryId);
    if (failCancels) throw StateError('cancel_failed');
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<ScheduledNotificationQuarantineResult>
  quarantinePendingScheduledNotifications() async {
    platformSweepAttempts++;
    if (hasNoPlatformAuthority) {
      return ScheduledNotificationQuarantineResult.noPlatformAuthority;
    }
    if (!supportsPlatformSweep) {
      return ScheduledNotificationQuarantineResult.notAuthoritative;
    }
    if (platformSweepFailuresRemaining > 0) {
      platformSweepFailuresRemaining--;
      throw StateError('platform_sweep_failed');
    }
    cancelled.addAll(platformPending);
    platformPending.clear();
    return ScheduledNotificationQuarantineResult.swept;
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> schedule({
    required MaasoNotification notification,
    required DateTime target,
    required bool repeatsDaily,
  }) async {}

  @override
  Future<void> show(MaasoNotification notification) async {}

  @override
  NotificationInteraction? takeInitialInteraction() => null;
}
