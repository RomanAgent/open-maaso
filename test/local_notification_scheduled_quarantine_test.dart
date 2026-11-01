import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/notifications/local_notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('exposes local scheduling support as an optional capability', () {
    final delivery = LocalNotificationDelivery();
    final capabilities = delivery as ScheduledNotificationDeliveryCapabilities;

    expect(capabilities.supportsLocalScheduling, isTrue);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(capabilities.supportsLocalScheduling, isFalse);
  });

  test(
    'macOS initialization without a permission prompt remains available',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      MacOSFlutterLocalNotificationsPlugin.registerWith();

      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      const timezoneChannel = MethodChannel('flutter_timezone');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        timezoneChannel,
        (_) async => 'Etc/UTC',
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'initialize' => false,
          'getNotificationAppLaunchDetails' => <String, Object?>{
            'notificationLaunchedApp': false,
          },
          'pendingNotificationRequests' ||
          'getActiveNotifications' => <Map<String, Object?>>[],
          _ => null,
        };
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(timezoneChannel, null);
      });

      final delivery = LocalNotificationDelivery();
      await delivery.initialize().timeout(const Duration(seconds: 3));

      expect(delivery.isAvailable, isTrue);
      expect(
        await delivery.quarantinePendingScheduledNotifications().timeout(
          const Duration(seconds: 3),
        ),
        ScheduledNotificationQuarantineResult.swept,
      );
      expect(
        calls,
        containsAll(<String>[
          'initialize',
          'getNotificationAppLaunchDetails',
          'pendingNotificationRequests',
          'getActiveNotifications',
        ]),
      );
    },
  );

  test(
    'authoritative account sweep clears every pending and active request',
    () async {
      final validProactive = _proactiveRequest(
        id: 'proactive:v2:dGVzdA.YWNjb3VudC1h:morning',
        kind: MaasoNotificationKind.morningGreeting,
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final scheduled = _pending(
        4101,
        MaasoNotification(
          deliveryId:
              'scheduled-task:v4:'
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:t1',
          kind: MaasoNotificationKind.scheduledTask,
          title: 'title',
          body: 'body',
          prompt: 'private A prompt',
        ).toPayload(),
      );
      final numericClaimConflict = _pending(
        99123,
        MaasoNotification(
          deliveryId:
              'scheduled-task:v4:'
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:t2',
          kind: MaasoNotificationKind.scheduledTask,
          title: 'title',
          body: 'body',
          prompt: 'private B prompt',
        ).toPayload(),
      );
      final nullPayload = _pending(4103, null);
      final malformedPayload = _pending(4104, '{not-json');
      const conflictingProactiveId = 'proactive:v2:dGVzdA.YWNjb3VudC1i:morning';
      final conflictingProactive = _pending(
        _numericId(conflictingProactiveId),
        jsonEncode(<String, Object?>{
          'deliveryId': conflictingProactiveId,
          'kind': MaasoNotificationKind.scheduledTask.key,
          'prompt': 'claim conflict',
          'environmentKey': 'test',
          'accountUuid': 'account-b',
        }),
      );
      final active = <ActiveNotification>[
        const ActiveNotification(id: 4201, payload: '{malformed-active'),
        ActiveNotification(
          id: 4202,
          payload: MaasoNotification(
            deliveryId: 'remote:old-account',
            kind: MaasoNotificationKind.remote,
            title: 'old remote',
            body: 'old body',
          ).toPayload(),
        ),
        ActiveNotification(id: 4203, payload: validProactive.payload),
      ];
      final cancelled = <int>[];
      final delivery = LocalNotificationDelivery(
        pendingRequestLoader: () async => <PendingNotificationRequest>[
          validProactive,
          scheduled,
          numericClaimConflict,
          nullPayload,
          malformedPayload,
          conflictingProactive,
        ],
        activeNotificationLoader: () async => active,
        pendingRequestCanceller: (id) async => cancelled.add(id),
      );

      expect(
        await delivery.quarantinePendingScheduledNotifications(),
        ScheduledNotificationQuarantineResult.swept,
      );

      expect(
        cancelled,
        containsAll(<int>[
          scheduled.id,
          numericClaimConflict.id,
          nullPayload.id,
          malformedPayload.id,
          conflictingProactive.id,
          validProactive.id,
          4201,
          4202,
          4203,
        ]),
      );
    },
  );

  test(
    'enumeration and cancellation failures block and remain retryable',
    () async {
      final request = _pending(5101, null);
      var loadAttempts = 0;
      var cancelAttempts = 0;
      final delivery = LocalNotificationDelivery(
        pendingRequestLoader: () async {
          loadAttempts++;
          return <PendingNotificationRequest>[request];
        },
        activeNotificationLoader: () async => const <ActiveNotification>[],
        pendingRequestCanceller: (_) async {
          cancelAttempts++;
          if (cancelAttempts == 1) throw StateError('cancel failed');
        },
      );

      await expectLater(
        delivery.quarantinePendingScheduledNotifications(),
        throwsStateError,
      );
      expect(
        await delivery.quarantinePendingScheduledNotifications(),
        ScheduledNotificationQuarantineResult.swept,
      );
      expect(loadAttempts, 2);
      expect(cancelAttempts, 2);
    },
  );

  test('unsupported desktop platform does not require a local sweep', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var enumerated = false;
    var activeEnumerated = false;
    final delivery = LocalNotificationDelivery(
      pendingRequestLoader: () async {
        enumerated = true;
        return const <PendingNotificationRequest>[];
      },
      activeNotificationLoader: () async {
        activeEnumerated = true;
        return const <ActiveNotification>[];
      },
    );

    expect(
      await delivery.quarantinePendingScheduledNotifications(),
      ScheduledNotificationQuarantineResult.noPlatformAuthority,
    );
    expect(enumerated, isFalse);
    expect(activeEnumerated, isFalse);
    await expectLater(
      delivery.cancel(
        'scheduled-task:v4:'
        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:t1',
      ),
      throwsStateError,
    );
    await expectLater(
      delivery.schedule(
        notification: const MaasoNotification(
          deliveryId:
              'scheduled-task:v4:'
              'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:t1',
          kind: MaasoNotificationKind.scheduledTask,
          title: 'title',
          body: 'body',
        ),
        target: DateTime(2099),
        repeatsDaily: false,
      ),
      throwsStateError,
    );
  });

  test(
    'sweep waits for an already-admitted schedule then cancels its numeric id',
    () async {
      final scheduleStarted = Completer<void>();
      final releaseSchedule = Completer<void>();
      final pending = <PendingNotificationRequest>[];
      final active = <ActiveNotification>[];
      final cancelled = <int>[];
      var enumerated = false;
      final notification = MaasoNotification(
        deliveryId:
            'scheduled-task:v4:'
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc:t7',
        kind: MaasoNotificationKind.scheduledTask,
        title: 'title',
        body: 'body',
        prompt: 'late A prompt',
      );
      final delivery = LocalNotificationDelivery(
        scheduledRequestDispatcher: (value, _, _) async {
          scheduleStarted.complete();
          await releaseSchedule.future;
          pending.add(_pending(6107, value.toPayload()));
        },
        pendingRequestLoader: () async {
          enumerated = true;
          return List<PendingNotificationRequest>.of(pending);
        },
        activeNotificationLoader: () async =>
            List<ActiveNotification>.of(active),
        pendingRequestCanceller: (id) async {
          cancelled.add(id);
          if (id == 6107 && active.isEmpty) {
            pending.clear();
            active.add(const ActiveNotification(id: 6107));
          }
        },
      );

      final schedule = delivery.schedule(
        notification: notification,
        target: DateTime(2099),
        repeatsDaily: true,
      );
      await scheduleStarted.future;
      final sweep = delivery.quarantinePendingScheduledNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(enumerated, isFalse);

      releaseSchedule.complete();
      await schedule;
      expect(await sweep, ScheduledNotificationQuarantineResult.swept);
      expect(cancelled, <int>[6107, 6107]);
    },
  );

  test(
    'permanently pending schedule cannot block an authoritative sweep',
    () async {
      final scheduleStarted = Completer<void>();
      final releaseSchedule = Completer<void>();
      final pending = <PendingNotificationRequest>[];
      final cancelled = <int>[];
      const deliveryId =
          'scheduled-task:v4:'
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff:t1';
      const queuedDeliveryId =
          'scheduled-task:v4:'
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff:t2';
      var dispatchCount = 0;
      final delivery = LocalNotificationDelivery(
        scheduledMutationTailTimeout: const Duration(milliseconds: 20),
        scheduledRequestDispatcher: (notification, _, _) async {
          dispatchCount++;
          scheduleStarted.complete();
          await releaseSchedule.future;
          pending.add(
            _pending(
              _numericId(notification.deliveryId),
              notification.toPayload(),
            ),
          );
        },
        pendingRequestLoader: () async =>
            List<PendingNotificationRequest>.of(pending),
        activeNotificationLoader: () async => const <ActiveNotification>[],
        pendingRequestCanceller: (id) async {
          cancelled.add(id);
          pending.removeWhere((request) => request.id == id);
        },
      );

      var scheduleSettled = false;
      final schedule = delivery
          .schedule(
            notification: const MaasoNotification(
              deliveryId: deliveryId,
              kind: MaasoNotificationKind.scheduledTask,
              title: 'title',
              body: 'body',
            ),
            target: DateTime(2099),
            repeatsDaily: false,
          )
          .whenComplete(() => scheduleSettled = true);
      await scheduleStarted.future;
      final queuedScheduleExpectation = expectLater(
        delivery.schedule(
          notification: const MaasoNotification(
            deliveryId: queuedDeliveryId,
            kind: MaasoNotificationKind.scheduledTask,
            title: 'queued title',
            body: 'queued body',
          ),
          target: DateTime(2099),
          repeatsDaily: false,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'notification_schedule_invalidated_by_sweep',
          ),
        ),
      );

      final stopwatch = Stopwatch()..start();
      expect(
        await delivery.quarantinePendingScheduledNotifications().timeout(
          const Duration(milliseconds: 500),
        ),
        ScheduledNotificationQuarantineResult.swept,
      );
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
      await queuedScheduleExpectation.timeout(
        const Duration(milliseconds: 100),
      );
      expect(dispatchCount, 1);
      expect(scheduleSettled, isFalse);
      expect(pending, isEmpty);

      releaseSchedule.complete();
      await schedule;
      for (var attempt = 0; attempt < 100 && cancelled.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(cancelled, <int>[_numericId(deliveryId)]);
      expect(pending, isEmpty);
    },
  );

  test(
    'a stalled schedule cannot reorder a later schedule without a sweep',
    () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final dispatched = <String>[];
      final delivery = LocalNotificationDelivery(
        scheduledMutationTailTimeout: const Duration(milliseconds: 20),
        scheduledRequestDispatcher: (notification, _, _) async {
          dispatched.add(notification.deliveryId);
          if (notification.deliveryId == 'first') {
            firstStarted.complete();
            await releaseFirst.future;
          }
        },
      );

      final first = delivery.schedule(
        notification: const MaasoNotification(
          deliveryId: 'first',
          kind: MaasoNotificationKind.scheduledTask,
          title: 'first',
          body: 'first',
        ),
        target: DateTime(2099),
        repeatsDaily: false,
      );
      await firstStarted.future;
      final second = delivery.schedule(
        notification: const MaasoNotification(
          deliveryId: 'second',
          kind: MaasoNotificationKind.scheduledTask,
          title: 'second',
          body: 'second',
        ),
        target: DateTime(2099),
        repeatsDaily: false,
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(dispatched, <String>['first']);

      releaseFirst.complete();
      await Future.wait<void>(<Future<void>>[first, second]);
      expect(dispatched, <String>['first', 'second']);
    },
  );

  test('active enumeration failure blocks and remains retryable', () async {
    var attempts = 0;
    final cancelled = <int>[];
    final delivery = LocalNotificationDelivery(
      pendingRequestLoader: () async => const <PendingNotificationRequest>[],
      activeNotificationLoader: () async {
        attempts++;
        if (attempts == 1) throw StateError('active enumerate failed');
        return const <ActiveNotification>[
          ActiveNotification(id: 7201, payload: '{unknown'),
        ];
      },
      pendingRequestCanceller: (id) async => cancelled.add(id),
    );

    await expectLater(
      delivery.quarantinePendingScheduledNotifications(),
      throwsStateError,
    );
    expect(
      await delivery.quarantinePendingScheduledNotifications(),
      ScheduledNotificationQuarantineResult.swept,
    );
    expect(cancelled, <int>[7201]);
  });

  test('active cancellation failure blocks and remains retryable', () async {
    var cancelAttempts = 0;
    final delivery = LocalNotificationDelivery(
      pendingRequestLoader: () async => const <PendingNotificationRequest>[],
      activeNotificationLoader: () async => const <ActiveNotification>[
        ActiveNotification(id: 7301, payload: '{malformed-active'),
      ],
      pendingRequestCanceller: (_) async {
        cancelAttempts++;
        if (cancelAttempts == 1) throw StateError('active cancel failed');
      },
    );

    await expectLater(
      delivery.quarantinePendingScheduledNotifications(),
      throwsStateError,
    );
    expect(
      await delivery.quarantinePendingScheduledNotifications(),
      ScheduledNotificationQuarantineResult.swept,
    );
    expect(cancelAttempts, 2);
  });

  test('null active id uses authoritative platform-wide clear', () async {
    var clearAttempts = 0;
    final cancelled = <int>[];
    final delivery = LocalNotificationDelivery(
      pendingRequestLoader: () async => const <PendingNotificationRequest>[],
      activeNotificationLoader: () async => const <ActiveNotification>[
        ActiveNotification(id: null, payload: '{fcm-active'),
        ActiveNotification(id: 7401, payload: '{numeric-active'),
      ],
      pendingRequestCanceller: (id) async => cancelled.add(id),
      activeNotificationClearer: () async => clearAttempts++,
    );

    expect(
      await delivery.quarantinePendingScheduledNotifications(),
      ScheduledNotificationQuarantineResult.swept,
    );
    expect(clearAttempts, 1);
    expect(cancelled, isEmpty);
  });

  test('platform-wide active clear failure blocks and retries', () async {
    var clearAttempts = 0;
    final delivery = LocalNotificationDelivery(
      pendingRequestLoader: () async => const <PendingNotificationRequest>[],
      activeNotificationLoader: () async => const <ActiveNotification>[
        ActiveNotification(id: null, payload: '{fcm-active'),
      ],
      activeNotificationClearer: () async {
        clearAttempts++;
        if (clearAttempts == 1) throw StateError('cancelAll failed');
      },
    );

    await expectLater(
      delivery.quarantinePendingScheduledNotifications(),
      throwsStateError,
    );
    expect(
      await delivery.quarantinePendingScheduledNotifications(),
      ScheduledNotificationQuarantineResult.swept,
    );
    expect(clearAttempts, 2);
  });
}

PendingNotificationRequest _proactiveRequest({
  required String id,
  required MaasoNotificationKind kind,
  required String environmentKey,
  required String accountUuid,
}) => _pending(
  _numericId(id),
  MaasoNotification(
    deliveryId: id,
    kind: kind,
    title: 'title',
    body: 'body',
    prompt: 'safe proactive prompt',
    data: <String, Object?>{
      'environmentKey': environmentKey,
      'accountUuid': accountUuid,
    },
  ).toPayload(),
);

PendingNotificationRequest _pending(int id, String? payload) =>
    PendingNotificationRequest(id, 'title', 'body', payload);

int _numericId(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash == 0 ? 1 : hash;
}
