import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/home/application/home_avatar_entrance_coordinator.dart';

void main() {
  for (final adopted in [false, true]) {
    test(
      '${adopted ? 'adopted' : 'completed'} Home frame survives temporary animation suspension',
      () async {
        final f = _Fixture();
        addTearDown(f.coordinator.dispose);
        if (adopted) {
          expect(f.coordinator.adoptPresentedFrame((_) => true), isTrue);
        } else {
          f.coordinator.begin();
          await f.flush();
          f.renderer.complete(0);
          await f.flush();
          f.renderer.complete(1);
          await f.coordinator.reconcile();
        }
        expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
        expect(f.coordinator.visible, isTrue);
        final commands = List<AvatarPresenceTransition>.of(f.renderer.commands);

        f.eligible = false;
        expect(f.coordinator.visible, isTrue);
        await f.coordinator.reconcile();
        expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
        expect(f.coordinator.visible, isTrue);
        expect(f.renderer.commands, commands);

        f.eligible = true;
        await f.coordinator.reconcile();
        expect(f.coordinator.visible, isTrue);
        expect(f.renderer.commands, commands);
      },
    );
  }

  for (final invalidation in [
    'account',
    'authority',
    'selection',
    'model',
    'renderer',
    'readiness',
    'cancel',
  ]) {
    test(
      'suspended completed Home frame still rejects $invalidation invalidation',
      () async {
        final f = _Fixture();
        addTearDown(f.coordinator.dispose);
        f.coordinator.begin();
        await f.flush();
        f.renderer.complete(0);
        await f.flush();
        f.renderer.complete(1);
        await f.coordinator.reconcile();
        f.eligible = false;
        expect(f.coordinator.visible, isTrue);

        switch (invalidation) {
          case 'account':
            f.epoch++;
          case 'authority':
            f.authorized = false;
          case 'selection':
            f.modelGeneration++;
          case 'model':
            f.renderer.epoch++;
          case 'renderer':
            f.active.register(_Renderer());
          case 'readiness':
            f.renderer.isReady.value = false;
          case 'cancel':
            await f.coordinator.cancel();
        }
        expect(f.coordinator.visible, isFalse);
      },
    );
  }

  test(
    'explicit Home entrance duration preserves its requested timing',
    () async {
      final renderer = _Renderer();
      final active = ActiveAvatarRuntime()..register(renderer);
      final coordinator = HomeAvatarEntranceCoordinator(
        avatar: active,
        captureFence: () => HomeAvatarEntranceFence(isCurrent: () => true),
        canAnimate: () => true,
        consumeEntrance: () => true,
        duration: const Duration(milliseconds: 2400),
      );
      addTearDown(coordinator.dispose);
      coordinator.begin();
      await Future<void>.delayed(Duration.zero);
      renderer.complete(0);
      await Future<void>.delayed(Duration.zero);
      expect(renderer.commands.last.phase, AvatarPresencePhase.enter);
      expect(renderer.commands.last.durationMs, 2400);
      renderer.complete(1);
      await coordinator.reconcile();
      expect(coordinator.phase.value, HomeAvatarEntrancePhase.completed);
    },
  );

  for (final queuedCleanup in [false, true]) {
    test(
      'same-epoch model replacement fences ${queuedCleanup ? 'queued' : 'current'} cleanup',
      () async {
        final f = _Fixture();
        addTearDown(() {
          f.coordinator.dispose();
          for (final receipt in f.renderer.receipts) {
            if (!receipt.isCompleted) receipt.complete();
          }
        });
        f.coordinator.begin();
        await f.flush();
        final previous = f.renderer.commands.single.transitionId;
        final previousModelEpoch = f.renderer.modelLoadEpoch;
        if (queuedCleanup) {
          final cancelled = f.coordinator.cancel();
          f.modelGeneration++;
          await cancelled;
          expect(f.renderer.phases, [AvatarPresencePhase.prepare]);
        } else {
          f.modelGeneration++;
          final recovery = f.coordinator.reconcile();
          await f.flush();
          expect(f.renderer.phases, [
            AvatarPresencePhase.prepare,
            AvatarPresencePhase.prepare,
          ]);
          expect(f.renderer.commands.last.transitionId, isNot(previous));
          f.renderer.complete(1);
          await f.flush();
          f.renderer.complete(2);
          await recovery;
          expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
        }
        expect(f.renderer.modelLoadEpoch, previousModelEpoch);
      },
    );
  }

  test(
    'held hidden recovery never restores an older selection on the same epoch',
    () async {
      final f = _Fixture();
      addTearDown(() {
        f.coordinator.dispose();
        for (final receipt in f.renderer.receipts) {
          if (!receipt.isCompleted) receipt.complete();
        }
      });
      f.coordinator.begin();
      await f.flush();
      f.authorized = false;
      f.renderer.complete(0);
      await f.flush();
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.holdHidden,
      ]);
      f.modelGeneration++;
      f.authorized = true;
      final recovery = f.coordinator.reconcile();
      await f.flush();
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.holdHidden,
        AvatarPresencePhase.prepare,
      ]);
      f.renderer.complete(2);
      await f.flush();
      f.renderer.complete(3);
      await recovery;
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
    },
  );

  test(
    'a new model epoch retires a pending entry even when readiness stays true',
    () async {
      var launchConsumed = false;
      final f = _Fixture(
        consumeEntrance: () {
          if (launchConsumed) return false;
          launchConsumed = true;
          return true;
        },
      );
      addTearDown(() {
        f.coordinator.dispose();
        for (final receipt in f.renderer.receipts) {
          if (!receipt.isCompleted) receipt.complete();
        }
      });
      f.coordinator.begin();
      await f.flush();
      final previous = f.renderer.commands.single.transitionId;
      f.renderer.epoch++;
      final recovery = f.coordinator.reconcile();
      await f.flush();
      expect(f.renderer.commands, hasLength(2));
      expect(f.renderer.commands.last.phase, AvatarPresencePhase.prepare);
      expect(f.renderer.commands.last.transitionId, isNot(previous));
      f.renderer.fail(0, 'stale_request');
      await f.flush();
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.preparing);
      expect(f.coordinator.failureCode, isNull);
      f.renderer.complete(1);
      await recovery;
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.restore,
      ]);
    },
  );

  for (final duringEntry in [false, true]) {
    test(
      'native scene takeover ${duringEntry ? 'during entry' : 'during prepare'} is cancellation before Home notices navigation',
      () async {
        final f = _Fixture();
        f.coordinator.begin();
        await f.flush();
        if (duringEntry) {
          f.renderer.complete(0);
          await f.flush();
        }
        f.renderer.fail(duringEntry ? 1 : 0, 'scene_takeover');
        await f.flush();
        expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.cancelled);
        expect(f.coordinator.visible, isFalse);
        expect(
          f.renderer.commands,
          hasLength(duringEntry ? 2 : 1),
          reason:
              'Native already retired the startup; no late restore may target the new scene.',
        );
        f.coordinator.begin();
        await f.flush();
        expect(f.renderer.phases.last, AvatarPresencePhase.prepare);
        expect(
          f.renderer.commands.last.transitionId,
          isNot(f.renderer.commands.first.transitionId),
        );
        await f.coordinator.cancel();
        f.renderer.complete(duringEntry ? 2 : 1);
        f.coordinator.dispose();
      },
    );
  }

  test(
    'accessibility changes apply next cycle without changing an in-flight entrance',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      await f.flush();
      f.coordinator.reduceMotion = true;
      f.renderer.complete(0);
      await f.flush();
      expect(f.renderer.phases.last, AvatarPresencePhase.enter);
      f.renderer.complete(1);
      await f.coordinator.reconcile();
      f.coordinator.begin();
      await f.flush();
      f.renderer.complete(2);
      await f.coordinator.reconcile();
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.enter,
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.restore,
      ]);
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
      f.coordinator.dispose();
    },
  );

  test(
    'model-ready cycle restores after the launch gate was consumed',
    () async {
      final f = _Fixture(consumeEntrance: () => false);
      f.coordinator.begin();
      await f.flush();
      expect(f.renderer.phases, [AvatarPresencePhase.prepare]);
      f.renderer.complete(0);
      await f.flush();
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.restore,
      ]);
      await f.coordinator.reconcile();
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
      f.coordinator.dispose();
    },
  );

  test('enter waits for the owner after hidden prepare receipt', () async {
    final reveal = Completer<void>();
    final f = _Fixture(revealPreparedAvatar: () => reveal.future);
    f.coordinator.begin();
    await f.flush();
    f.renderer.complete(0);
    await f.flush();
    expect(f.renderer.phases, [AvatarPresencePhase.prepare]);
    expect(f.coordinator.visible, isFalse);
    reveal.complete();
    await f.flush();
    expect(f.renderer.phases.last, AvatarPresencePhase.enter);
    f.renderer.complete(1);
    await f.coordinator.reconcile();
    f.coordinator.dispose();
  });

  test('failed owner reveal never dispatches enter', () async {
    final f = _Fixture(
      revealPreparedAvatar: () async => throw StateError('visibility failed'),
    );
    f.coordinator.begin();
    await f.flush();
    f.renderer.complete(0);
    await f.flush();
    expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.failed);
    expect(f.coordinator.failureCode, 'local_visibility_failed');
    expect(f.coordinator.failureStage, 'reveal');
    expect(f.coordinator.visible, isFalse);
    expect(f.renderer.phases, [
      AvatarPresencePhase.prepare,
      AvatarPresencePhase.restore,
    ]);
    f.coordinator.dispose();
  });

  test(
    'reduced motion restores at center and only reveals after rendered receipt',
    () async {
      final f = _Fixture(reduceMotion: true);
      f.renderer.autoCompleteCleanup = false;
      final observed = <HomeAvatarEntrancePhase>[];
      f.coordinator.phase.addListener(
        () => observed.add(f.coordinator.phase.value),
      );
      f.coordinator.begin();
      await f.flush();
      expect(f.renderer.phases, [AvatarPresencePhase.prepare]);
      f.renderer.complete(0);
      await f.flush();
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.restore,
      ]);
      expect(f.coordinator.visible, isFalse);
      f.renderer.complete(1);
      await f.coordinator.reconcile();
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
      expect(f.coordinator.visible, isTrue);
      expect(observed, isNot(contains(HomeAvatarEntrancePhase.entering)));
      expect(f.renderer.visibilityWrites, isEmpty);
      f.coordinator.dispose();
    },
  );

  test(
    'remote, unresolved, unready and ineligible starts send no commands',
    () async {
      final f = _Fixture()..authorized = false;
      f.coordinator.begin();
      await f.flush();
      expect(f.renderer.commands, isEmpty);
      expect(f.coordinator.visible, isFalse);
      f.authorized = true;
      f.renderer.isReady.value = false;
      await f.coordinator.reconcile();
      expect(f.renderer.commands, isEmpty);
      f.renderer.isReady.value = true;
      f.eligible = false;
      await f.coordinator.reconcile();
      expect(f.renderer.commands, isEmpty);
      f.coordinator.dispose();
    },
  );

  test(
    'reveals only after hidden frame receipt, before the walking completion',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      await f.flush();
      expect(f.renderer.phases, [AvatarPresencePhase.prepare]);
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.preparing);
      expect(f.coordinator.visible, isFalse);
      f.renderer.complete(0);
      await f.flush();
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.entering);
      expect(f.coordinator.visible, isTrue);
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.enter,
      ]);
      expect(f.renderer.commands.last.edge, AvatarPresenceEdge.right);
      expect(f.renderer.commands.last.durationMs, 1565);
      expect(
        f.renderer.commands.every((command) => command.doNotInterrupt),
        isTrue,
      );
      f.renderer.complete(1);
      await f.coordinator.reconcile();
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
      expect(
        f.renderer.visibilityWrites,
        isEmpty,
        reason: 'Only the account owner can grant renderer visibility.',
      );
      f.coordinator.dispose();
    },
  );

  test('a delayed prepare receipt cannot enter after lease loss', () async {
    final f = _Fixture();
    f.coordinator.begin();
    await f.flush();
    f.authorized = false;
    f.renderer.complete(0);
    await f.flush();
    expect(f.coordinator.visible, isFalse);
    expect(f.renderer.phases, [
      AvatarPresencePhase.prepare,
      AvatarPresencePhase.holdHidden,
    ]);
    f.coordinator.dispose();
  });

  test(
    'account or lease replacement cannot inherit a pending preparation',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      await f.flush();
      f.epoch++;
      f.renderer.complete(0);
      await f.flush();
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.holdHidden,
      ]);
      expect(f.coordinator.visible, isFalse);
      f.coordinator.dispose();
    },
  );

  test(
    'authority recheck after phase listener prevents reveal-time entry',
    () async {
      final f = _Fixture();
      f.coordinator.phase.addListener(() {
        if (f.coordinator.phase.value == HomeAvatarEntrancePhase.entering) {
          f.authorized = false;
        }
      });
      f.coordinator.begin();
      await f.flush();
      f.renderer.complete(0);
      await f.flush();
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.holdHidden,
      ]);
      expect(f.coordinator.visible, isFalse);
      f.coordinator.dispose();
    },
  );

  test(
    'route/manual-chat cancellation synchronously covers and cancels only its ID',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      await f.flush();
      f.renderer.complete(0);
      await f.flush();
      expect(f.coordinator.visible, isTrue);
      f.eligible = false;
      final cancelled = f.coordinator.cancel();
      expect(f.coordinator.visible, isFalse);
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.cancelled);
      await cancelled;
      expect(f.renderer.phases.last, AvatarPresencePhase.restore);
      expect(
        f.renderer.commands.map((command) => command.transitionId).toSet(),
        hasLength(1),
      );
      f.renderer.complete(1);
      await f.flush();
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.cancelled);
      f.eligible = true;
      await f.coordinator.reconcile();
      expect(
        f.renderer.commands,
        hasLength(3),
        reason: 'Settings return must not start another foreground cycle.',
      );
      f.coordinator.dispose();
    },
  );

  test(
    'authority revoked mid-walk hides without an unauthorized restore',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      await f.flush();
      f.renderer.complete(0);
      await f.flush();
      f.authorized = false;
      expect(f.coordinator.visible, isFalse);
      await f.coordinator.reconcile();
      await f.flush();
      expect(f.renderer.phases.last, AvatarPresencePhase.holdHidden);
      f.renderer.complete(1);
      await f.flush();
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.waiting);
      f.coordinator.dispose();
    },
  );

  test(
    'new valid lease clears held hidden transaction before preparing again',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      await f.flush();
      f.authorized = false;
      f.renderer.complete(0);
      await f.flush();
      final firstId = f.renderer.commands.first.transitionId;
      f.epoch++;
      f.authorized = true;
      final newEntry = f.coordinator.reconcile();
      await f.flush();
      expect(f.renderer.phases, [
        AvatarPresencePhase.prepare,
        AvatarPresencePhase.holdHidden,
        AvatarPresencePhase.restore,
        AvatarPresencePhase.prepare,
      ]);
      expect(f.renderer.commands[2].transitionId, firstId);
      expect(f.renderer.commands[3].transitionId, isNot(firstId));
      f.renderer.complete(3);
      await f.flush();
      f.renderer.complete(4);
      await newEntry;
      expect(f.coordinator.visible, isTrue);
      f.coordinator.dispose();
    },
  );

  test(
    'renderer replacement never sends old cleanup or entry to the new renderer',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      await f.flush();
      final replacement = _Renderer();
      f.active.register(replacement);
      f.renderer.complete(0);
      await f.flush();
      expect(f.renderer.phases, [AvatarPresencePhase.prepare]);
      expect(replacement.commands, isEmpty);
      expect(f.coordinator.visible, isFalse);
      f.coordinator.dispose();
    },
  );

  test(
    'concurrent readiness notifications reuse one entrance and each resume gets a new ID',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      final first = f.coordinator.reconcile();
      final same = f.coordinator.reconcile();
      await f.flush();
      expect(f.renderer.commands, hasLength(1));
      f.renderer.complete(0);
      await f.flush();
      f.renderer.complete(1);
      await Future.wait([first, same]);
      final previousId = f.renderer.commands.first.transitionId;
      f.coordinator.begin();
      expect(f.coordinator.visible, isFalse);
      await f.flush();
      expect(f.renderer.commands.last.phase, AvatarPresencePhase.prepare);
      expect(f.renderer.commands.last.transitionId, isNot(previousId));
      await f.coordinator.cancel();
      f.renderer.complete(2);
      f.coordinator.dispose();
    },
  );

  test(
    'busy/failed entry never reports visible success or retries on its own',
    () async {
      final f = _Fixture();
      f.coordinator.begin();
      await f.flush();
      f.renderer.fail(0, 'transition_busy');
      await f.flush();
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.failed);
      expect(f.coordinator.failureCode, 'transition_busy');
      expect(f.coordinator.failureStage, 'prepare');
      expect(f.coordinator.visible, isFalse);
      await f.coordinator.reconcile();
      expect(
        f.renderer.phases.where(
          (phase) => phase == AvatarPresencePhase.prepare,
        ),
        hasLength(1),
      );
      f.coordinator.dispose();
    },
  );
  test(
    'adopting a completed return shows Home without native prepare or restore',
    () async {
      var available = true;
      var launchConsumption = 0;
      final f = _Fixture(
        consumeEntrance: () {
          launchConsumption++;
          return false;
        },
      );
      bool consume(AvatarRuntime renderer) {
        expect(renderer, same(f.renderer));
        if (!available) return false;
        available = false;
        return true;
      }

      expect(f.coordinator.adoptPresentedFrame(consume), isTrue);
      expect(f.coordinator.visible, isTrue);
      expect(f.coordinator.phase.value, HomeAvatarEntrancePhase.completed);
      await f.coordinator.reconcile();
      expect(f.coordinator.adoptPresentedFrame(consume), isFalse);
      expect(launchConsumption, 1);
      expect(f.renderer.commands, isEmpty);
      expect(f.renderer.visibilityWrites, isEmpty);
      await f.coordinator.cancel();
      f.coordinator.dispose();
      await f.flush();
      expect(
        f.renderer.commands,
        isEmpty,
        reason: 'An adopted frame owns no native entrance to restore.',
      );
    },
  );

  for (final invalidation in ['account', 'model', 'renderer', 'readiness']) {
    test(
      'adoption rejects $invalidation changes during receipt consumption',
      () {
        final f = _Fixture();
        expect(
          f.coordinator.adoptPresentedFrame((_) {
            switch (invalidation) {
              case 'account':
                f.epoch++;
              case 'model':
                f.renderer.epoch++;
              case 'renderer':
                f.active.register(_Renderer());
              case 'readiness':
                f.renderer.isReady.value = false;
            }
            return true;
          }),
          isFalse,
        );
        expect(f.coordinator.visible, isFalse);
        expect(f.renderer.commands, isEmpty);
        f.coordinator.dispose();
      },
    );
  }

  test('unavailable Home does not consume a pending return proof', () {
    final f = _Fixture()..eligible = false;
    var consumption = 0;
    bool consume(AvatarRuntime _) {
      consumption++;
      return true;
    }

    expect(f.coordinator.adoptPresentedFrame(consume), isFalse);
    expect(consumption, 0);
    f.eligible = true;
    f.authorized = false;
    expect(f.coordinator.adoptPresentedFrame(consume), isFalse);
    expect(consumption, 0);
    f.authorized = true;
    expect(f.coordinator.adoptPresentedFrame(consume), isTrue);
    f.modelGeneration++;
    expect(f.coordinator.visible, isFalse);
    expect(f.renderer.commands, isEmpty);
    f.coordinator.dispose();
  });
}

final class _Fixture {
  final renderer = _Renderer();
  final active = ActiveAvatarRuntime();
  bool authorized = true;
  bool eligible = true;
  int epoch = 1;
  int modelGeneration = 1;
  late final HomeAvatarEntranceCoordinator coordinator;

  _Fixture({
    bool reduceMotion = false,
    bool Function()? consumeEntrance,
    Future<void> Function()? revealPreparedAvatar,
  }) {
    active.register(renderer);
    coordinator = HomeAvatarEntranceCoordinator(
      avatar: active,
      captureFence: () {
        if (!authorized) return null;
        final captured = epoch;
        final capturedModelGeneration = modelGeneration;
        return HomeAvatarEntranceFence(
          isCurrent: () => authorized && captured == epoch,
          modelIsCurrent: () => capturedModelGeneration == modelGeneration,
        );
      },
      canAnimate: () => eligible,
      revealPreparedAvatar: revealPreparedAvatar,
      consumeEntrance: consumeEntrance ?? () => true,
      reduceMotion: reduceMotion,
    );
  }

  Future<void> flush() => Future<void>.delayed(Duration.zero);
}

final class _Renderer extends AvatarRuntime {
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  int epoch = 0;
  @override
  int get modelLoadEpoch => epoch;
  final commands = <AvatarPresenceTransition>[];
  final receipts = <Completer<void>>[];
  final visibilityWrites = <bool>[];
  bool autoCompleteCleanup = true;
  List<AvatarPresencePhase> get phases =>
      commands.map((command) => command.phase).toList();

  @override
  Future<void> setLocalAvatarVisible(bool visible) async =>
      visibilityWrites.add(visible);

  @override
  Future<void> transitionPresence(AvatarPresenceTransition command) {
    commands.add(command);
    final receipt = Completer<void>();
    receipts.add(receipt);
    if (autoCompleteCleanup &&
        (command.phase == AvatarPresencePhase.restore ||
            command.phase == AvatarPresencePhase.holdHidden)) {
      receipt.complete();
    }
    return receipt.future;
  }

  void complete(int index) => receipts[index].complete();
  void fail(int index, String code) =>
      receipts[index].completeError(AvatarPresenceTransitionException(code));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
