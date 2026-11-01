import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';

void main() {
  test(
    'voice intent belongs to an admitted owner and mounted account',
    () async {
      final coordinator = VoiceInputRetirementCoordinator();
      final owner = Object(), stale = Object();
      coordinator.mountVoiceSessionScope('account-a');
      coordinator.confirmVoiceSessionIntent(stale, 'account-a');
      expect(coordinator.voiceSessionRequestedFor('account-a'), isFalse);
      await coordinator.acquire(
        owner: owner,
        retireCurrentOwner: () async => coordinator.release(owner),
      );
      coordinator.confirmVoiceSessionIntent(owner, 'wrong-account');
      expect(coordinator.voiceSessionRequestedFor('account-a'), isFalse);
      coordinator.confirmVoiceSessionIntent(owner, 'account-a');
      expect(coordinator.voiceSessionRequestedFor('account-a'), isTrue);
      coordinator.release(owner);
      expect(
        coordinator.voiceSessionRequestedFor('account-a'),
        isTrue,
        reason: 'capture retirement preserves the explicit voice choice',
      );
      coordinator.mountVoiceSessionScope('account-b');
      expect(coordinator.voiceSessionRequestedFor('account-b'), isFalse);
      expect(coordinator.voiceSessionRequestedFor('account-a'), isFalse);
    },
  );

  test('old owners cannot revoke a transferred voice intent', () async {
    final coordinator = VoiceInputRetirementCoordinator();
    coordinator.mountVoiceSessionScope('account-a');
    final old = Object(), next = Object();
    await coordinator.acquire(
      owner: old,
      retireCurrentOwner: () async => coordinator.release(old),
    );
    coordinator.confirmVoiceSessionIntent(old, 'account-a');
    await coordinator.acquire(
      owner: next,
      retireCurrentOwner: () async => coordinator.release(next),
    );
    coordinator.endVoiceSessionIntent(old);
    expect(coordinator.voiceSessionRequestedFor('account-a'), isTrue);
    coordinator.endVoiceSessionIntent(next);
    expect(coordinator.voiceSessionRequestedFor('account-a'), isFalse);
    coordinator.confirmVoiceSessionIntent(next, 'account-a');
    coordinator.clearVoiceSessionIntent();
    coordinator.confirmVoiceSessionIntent(next, 'account-a');
    expect(coordinator.voiceSessionRequestedFor('account-a'), isFalse);
    coordinator.release(next);
  });

  test('input priority belongs only to the current capture lease', () async {
    final coordinator = VoiceInputRetirementCoordinator();
    final first = Object(), next = Object();
    var recognizing = false;
    await coordinator.acquire(
      owner: first,
      retireCurrentOwner: () async => coordinator.release(first),
      hasPendingUserInput: () => recognizing,
    );
    expect(coordinator.hasPendingUserInput, isFalse);
    recognizing = true;
    coordinator.notifyPriorityChanged(first);
    expect(coordinator.hasPendingUserInput, isTrue);
    await coordinator.acquire(
      owner: next,
      retireCurrentOwner: () async => coordinator.release(next),
      hasPendingUserInput: () => false,
    );
    final revision = coordinator.priorityRevision.value;
    coordinator.notifyPriorityChanged(first);
    coordinator.release(first);
    expect(coordinator.priorityRevision.value, revision);
    expect(coordinator.hasPendingUserInput, isFalse);
    coordinator.release(next);
  });
  test('cleanup attempts every step and rethrows the first failure', () async {
    final calls = <String>[];

    await expectLater(
      runVoiceInputCleanupSteps(<FutureOr<void> Function()>[
        () {
          calls.add('subscriptions');
          throw StateError('subscription cleanup failed');
        },
        () async {
          calls.add('vad');
          throw StateError('vad cleanup failed');
        },
        () => calls.add('mic'),
        () => calls.add('asr'),
      ]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'subscription cleanup failed',
        ),
      ),
    );
    expect(calls, <String>['subscriptions', 'vad', 'mic', 'asr']);
  });

  test('resource cancellation unblocks drain before final cleanup', () async {
    final operations = VoiceInputOperationFence();
    final cancellationReachedOperation = Completer<void>();
    final calls = <String>[];
    final operation = operations.track(() async {
      calls.add('operation:start');
      await cancellationReachedOperation.future;
      calls.add('operation:end');
    }());
    await Future<void>.delayed(Duration.zero);

    var retirementPass = 0;
    await retireVoiceInputResourcesWithOperationDrain(
      retireResources: () async {
        retirementPass++;
        calls.add('retire:$retirementPass');
        if (!cancellationReachedOperation.isCompleted) {
          cancellationReachedOperation.complete();
        }
      },
      operations: operations,
    );
    await operation;

    expect(calls, <String>[
      'operation:start',
      'retire:1',
      'operation:end',
      'retire:2',
    ]);
    expect(operations.isActive, isFalse);
  });

  test(
    'segment follow-up starts only after the tracked operation settles',
    () async {
      final operations = VoiceInputOperationFence();
      final releaseSegment = Completer<void>();
      final calls = <String>[];
      late Future<bool> restart;
      final segment = operations.track(() async {
        calls.add('segment:start');
        await Future<void>.delayed(Duration.zero);
        restart = runVoiceInputAfterOperationDrain(
          operations: operations,
          isCurrent: () => true,
          action: () async => calls.add('restart'),
        );
        await releaseSegment.future;
        calls.add('segment:end');
      }());

      await Future<void>.delayed(Duration.zero);
      expect(calls, <String>['segment:start']);

      releaseSegment.complete();
      await segment;
      expect(await restart, isTrue);
      expect(calls, <String>['segment:start', 'segment:end', 'restart']);
      expect(operations.isActive, isFalse);
    },
  );

  test(
    'stale segment follow-up is dropped after the operation settles',
    () async {
      final operations = VoiceInputOperationFence();
      final releaseSegment = Completer<void>();
      var current = true;
      var restartCalls = 0;
      late Future<bool> restart;
      final segment = operations.track(() async {
        await Future<void>.delayed(Duration.zero);
        restart = runVoiceInputAfterOperationDrain(
          operations: operations,
          isCurrent: () => current,
          action: () async => restartCalls++,
        );
        await releaseSegment.future;
      }());

      current = false;
      releaseSegment.complete();
      await segment;

      expect(await restart, isFalse);
      expect(restartCalls, 0);
    },
  );

  test(
    'same owner cannot reenter until tracked realtime leave retries',
    () async {
      final coordinator = VoiceInputRetirementCoordinator();
      final owner = Object();
      var leaveAttempts = 0;

      await coordinator.acquire(
        owner: owner,
        retireCurrentOwner: () async => coordinator.release(owner),
      );
      Future<void> leave() async {
        leaveAttempts++;
        if (leaveAttempts < 3) throw StateError('rtc leave failed');
      }

      coordinator.track(key: Object(), retirement: leave(), retry: leave);
      await expectLater(
        coordinator.acquire(
          owner: owner,
          retireCurrentOwner: () async => coordinator.release(owner),
        ),
        throwsStateError,
      );
      expect(leaveAttempts, 2);
      expect(coordinator.isOwner(owner), isTrue);

      expect(
        await coordinator.acquire(
          owner: owner,
          retireCurrentOwner: () async => coordinator.release(owner),
        ),
        isTrue,
      );
      expect(leaveAttempts, 3);
      expect(coordinator.isOwner(owner), isTrue);
    },
  );

  test('replacement admission waits for an in-flight retirement', () async {
    final coordinator = VoiceInputRetirementCoordinator();
    final stopped = Completer<void>();
    coordinator.track(key: Object(), retirement: stopped.future);
    var admitted = false;

    final waiting = coordinator.waitForIdle().then((_) => admitted = true);
    await Future<void>.delayed(Duration.zero);
    expect(admitted, isFalse);
    expect(coordinator.isRetiring, isTrue);

    stopped.complete();
    await waiting;
    expect(admitted, isTrue);
    expect(coordinator.isRetiring, isFalse);
  });

  test('active owner is retired before the capture lease transfers', () async {
    final coordinator = VoiceInputRetirementCoordinator();
    final oldOwner = Object();
    final newOwner = Object();
    final retirementEntered = Completer<void>();
    final allowRetirement = Completer<void>();

    expect(
      await coordinator.acquire(
        owner: oldOwner,
        retireCurrentOwner: () async {
          retirementEntered.complete();
          await allowRetirement.future;
          coordinator.release(oldOwner);
        },
      ),
      isTrue,
    );
    final handoff = coordinator.acquire(
      owner: newOwner,
      retireCurrentOwner: () async => coordinator.release(newOwner),
    );

    await retirementEntered.future;
    expect(coordinator.isOwner(oldOwner), isTrue);
    expect(coordinator.isOwner(newOwner), isFalse);
    allowRetirement.complete();

    expect(await handoff, isTrue);
    expect(coordinator.isOwner(oldOwner), isFalse);
    expect(coordinator.isOwner(newOwner), isTrue);
  });

  test('failed owner retirement keeps the old capture lease', () async {
    final coordinator = VoiceInputRetirementCoordinator();
    final oldOwner = Object();
    final newOwner = Object();
    var allowRetirement = false;

    Future<void> retireOldOwner() async {
      if (!allowRetirement) throw StateError('mic is still active');
      coordinator.release(oldOwner);
    }

    await coordinator.acquire(
      owner: oldOwner,
      retireCurrentOwner: retireOldOwner,
    );
    await expectLater(
      coordinator.acquire(
        owner: newOwner,
        retireCurrentOwner: () async => coordinator.release(newOwner),
      ),
      throwsStateError,
    );
    expect(coordinator.isOwner(oldOwner), isTrue);
    expect(coordinator.isOwner(newOwner), isFalse);

    allowRetirement = true;
    expect(
      await coordinator.acquire(
        owner: newOwner,
        retireCurrentOwner: () async => coordinator.release(newOwner),
      ),
      isTrue,
    );
    expect(coordinator.isOwner(newOwner), isTrue);
  });

  test('failed cleanup remains fenced and can be retried again', () async {
    final coordinator = VoiceInputRetirementCoordinator();
    final resourceKey = Object();
    var retryCount = 0;

    Future<void> retry() async {
      retryCount++;
      if (retryCount == 1) throw StateError('transient mic stop failure');
    }

    coordinator.track(
      key: resourceKey,
      retirement: Future<void>.error(StateError('initial stop failure')),
      retry: retry,
    );

    await expectLater(coordinator.waitForIdle(), throwsStateError);
    expect(retryCount, 1);
    expect(coordinator.isRetiring, isTrue);

    await coordinator.waitForIdle();
    expect(retryCount, 2);
    expect(coordinator.isRetiring, isFalse);
  });

  test('same tracked resource is replaced without double waiting', () async {
    final coordinator = VoiceInputRetirementCoordinator();
    final resourceKey = Object();
    final stale = Completer<void>();
    final current = Completer<void>();
    coordinator.track(key: resourceKey, retirement: stale.future);
    coordinator.track(key: resourceKey, retirement: current.future);

    var admitted = false;
    final waiting = coordinator.waitForIdle().then((_) => admitted = true);
    stale.complete();
    await Future<void>.delayed(Duration.zero);
    expect(admitted, isFalse);

    current.complete();
    await waiting;
    expect(admitted, isTrue);
    expect(coordinator.isRetiring, isFalse);
  });

  test('non-retryable retirement failure remains fail-closed', () async {
    final coordinator = VoiceInputRetirementCoordinator();
    final resourceKey = Object();
    coordinator.track(
      key: resourceKey,
      retirement: Future<void>.error(StateError('unknown resource state')),
    );

    await expectLater(coordinator.waitForIdle(), throwsStateError);
    expect(coordinator.isRetiring, isTrue);

    coordinator.track(key: resourceKey, retirement: Future<void>.value());
    await coordinator.waitForIdle();
    expect(coordinator.isRetiring, isFalse);
  });

  for (final surface in <String>['core composer', 'feature composer']) {
    test('$surface handoff drains a stale segment before transfer', () async {
      final coordinator = VoiceInputRetirementCoordinator();
      final operations = VoiceInputOperationFence();
      final oldOwner = Object();
      final newOwner = Object();
      final segmentEntered = Completer<void>();
      final releaseSegment = Completer<void>();
      var oldOperationIsCurrent = true;
      var staleMicStopCalls = 0;

      await coordinator.acquire(
        owner: oldOwner,
        retireCurrentOwner: () async {
          oldOperationIsCurrent = false;
          await operations.drain();
          coordinator.release(oldOwner);
        },
      );
      final operation = operations.track(() async {
        segmentEntered.complete();
        await releaseSegment.future;
        if (oldOperationIsCurrent) staleMicStopCalls++;
      }());
      await segmentEntered.future;

      final handoff = coordinator.acquire(
        owner: newOwner,
        retireCurrentOwner: () async => coordinator.release(newOwner),
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.isOwner(oldOwner), isTrue);
      expect(coordinator.isOwner(newOwner), isFalse);

      releaseSegment.complete();
      await operation;
      expect(await handoff, isTrue);
      expect(staleMicStopCalls, 0);
      expect(coordinator.isOwner(newOwner), isTrue);
    });
  }
}
