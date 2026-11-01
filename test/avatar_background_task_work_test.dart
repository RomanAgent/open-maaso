import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_background_task_work.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shadow rollout uses the host scene without acquiring projection ownership',
    () async {
      final h = await _HostHarness.start(mode: FeatureRolloutMode.shadow);
      addTearDown(h.close);
      expect(h.authority.phase, AvatarProductionAuthorityPhase.shadow);
      expect(AvatarProductionOwnership.ownsRenderer, isFalse);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      expect(h.sink.commands, isEmpty);
    },
  );

  test(
    'enforce rollout keeps one authority lane without host fallback',
    () async {
      final h = await _HostHarness.start(mode: FeatureRolloutMode.enforce);
      addTearDown(h.close);
      expect(h.authority.phase, AvatarProductionAuthorityPhase.enforcing);
      h.sink.commands.clear();
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, isEmpty);
      expect(
        h.sink.commands.any(
          (dispatch) =>
              dispatch.command is AvatarBodyGestureCommand &&
              (dispatch.command as AvatarBodyGestureCommand).workSessionId ==
                  owner.sessionId,
        ),
        isTrue,
      );
      h.flags.setRuntimeMaximum(
        MaasoFeatureFlag.avatarProjectionV2,
        FeatureRolloutMode.off,
      );
      await h.authority.waitForIdle();
      await h.tick();
      expect(h.controller.activeOwner, isNull);
      expect(
        h.avatar.hostEvents,
        isEmpty,
        reason: 'An admitted authority session never turns into a host replay',
      );
    },
  );

  test('locked authority cannot fall back to the host presentation', () async {
    final h = await _HostHarness.start(mode: FeatureRolloutMode.enforce);
    addTearDown(h.close);
    await h.authority.sealAndDrain();
    expect(AvatarProductionOwnership.ownsRenderer, isTrue);
    expect(h.begin(), isNotNull);
    await h.controller.waitForIdle();
    await h.tick();
    expect(h.avatar.hostEvents, isEmpty);
  });

  for (final mode in [FeatureRolloutMode.off, FeatureRolloutMode.enforce]) {
    test('space return defers only desk presentation in $mode', () async {
      final h = await _HostHarness.start(mode: mode);
      addTearDown(h.close);
      h.sink.commands.clear();
      h.returningHome = true;
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      await h.tick();
      expect(h.controller.activeOwner, same(owner));
      expect(h.controller.hasCurrentWork, isTrue);
      expect(h.jobCurrent, isTrue);
      expect(h.avatar.hostEvents, isEmpty);
      expect(h.sink.commands, isEmpty);
      h.returningHome = false;
      await h.tick();
      if (mode == FeatureRolloutMode.off) {
        expect(h.avatar.hostEvents, [
          (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
        ]);
      } else {
        final work = h.sink.commands.where(
          (dispatch) =>
              dispatch.command is AvatarBodyGestureCommand &&
              (dispatch.command as AvatarBodyGestureCommand).workSessionId ==
                  owner.sessionId,
        );
        expect(work, hasLength(1));
      }
      final hostCount = h.avatar.hostEvents.length;
      final ticketCount = h.sink.commands.length;
      await h.tick();
      expect(h.avatar.hostEvents, hasLength(hostCount));
      expect(h.sink.commands, hasLength(ticketCount));
    });

    test(
      'job ending during space return never starts later in $mode',
      () async {
        final h = await _HostHarness.start(mode: mode);
        addTearDown(h.close);
        h.sink.commands.clear();
        h.returningHome = true;
        final owner = h.begin()!;
        await h.controller.waitForIdle();
        h.jobCurrent = false;
        await h.tick();
        expect(h.controller.activeOwner, isNull);
        h.returningHome = false;
        await h.tick();
        expect(h.avatar.hostEvents, isEmpty);
        expect(h.sink.commands, isEmpty);
        await h.controller.end(owner);
      },
    );
  }

  test(
    'space return starting after reconcile prevents queued native admission',
    () async {
      final h = await _HostHarness.start(mode: FeatureRolloutMode.enforce);
      addTearDown(h.close);
      h.sink.commands.clear();
      final owner = h.begin()!;
      h.returningHome = true;
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, same(owner));
      expect(h.sink.commands, isEmpty);
      h.returningHome = false;
      await h.tick();
      final work = h.sink.commands.where(
        (dispatch) =>
            dispatch.command is AvatarBodyGestureCommand &&
            (dispatch.command as AvatarBodyGestureCommand).workSessionId ==
                owner.sessionId,
      );
      expect(work, hasLength(1));
    },
  );

  test(
    'renderer replacement while waiting retires intent instead of moving the new actor',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.avatar.presentationReady.value = false;
      expect(h.begin(), isNotNull);
      final replacement = _Avatar()..hostSupported = true;
      addTearDown(replacement.states.close);
      h.renderer = replacement;
      await h.tick();
      expect(h.controller.activeOwner, isNull);
      expect(replacement.hostEvents, isEmpty);
      h.renderer = h.avatar;
      h.avatar.presentationReady.value = true;
      await h.tick();
      expect(h.avatar.hostEvents, isEmpty);
    },
  );

  test(
    'normal off rollout uses the host work API without an override',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      expect(
        h.flags.effectiveMode(MaasoFeatureFlag.avatarProjectionV2),
        FeatureRolloutMode.off,
      );
      expect(h.authority.phase, AvatarProductionAuthorityPhase.legacy);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      expect(h.sink.commands, isEmpty);
      expect(h.avatar.prepareCount, 0);
      await h.controller.end(owner);
      expect(h.avatar.hostEvents.last, (
        owner.sessionId,
        AvatarBackgroundTaskWorkPhase.end,
      ));
    },
  );

  test(
    'current job waits for existing model and native presentation',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.avatar.isReady.value = false;
      h.avatar.presentationReady.value = false;
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, isEmpty);
      h.avatar.isReady.value = true;
      await h.authority.waitForIdle();
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, isEmpty);
      h.avatar.presentationReady.value = true;
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      expect(h.avatar.prepareCount, 0);
    },
  );

  test(
    'current Home job may wait for its first renderer without starting one',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.renderer = null;
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, isEmpty);
      h.renderer = h.avatar;
      await h.tick();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      expect(h.avatar.prepareCount, 0);
    },
  );

  test(
    'work protocol capability may arrive after ready without a ready change',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.avatar.hostSupported = false;
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, isEmpty);
      h.avatar.hostSupported = true;
      await h.tick();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
    },
  );

  for (final terminal in ['end', 'job', 'page']) {
    test('$terminal retires readiness intent without a late replay', () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.avatar.presentationReady.value = false;
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      switch (terminal) {
        case 'end':
          await h.controller.end(owner);
        case 'job':
          h.jobCurrent = false;
        case 'page':
          h.visible = false;
      }
      await h.tick();
      expect(h.controller.activeOwner, isNull);
      h.jobCurrent = true;
      h.visible = true;
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      h.avatar.presentationReady.value = true;
      await h.tick();
      expect(h.avatar.hostEvents, isEmpty);
    });
  }

  test(
    'background readiness intent resumes only its still-running job',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.avatar.presentationReady.value = false;
      final owner = h.begin()!;
      h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      h.avatar.presentationReady.value = true;
      await h.tick();
      expect(h.controller.activeOwner, same(owner));
      expect(h.controller.hasCurrentWork, isTrue);
      expect(h.avatar.hostEvents, isEmpty);
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
    },
  );

  test(
    'started work survives inactive paused and hidden without an end',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      h.avatar.hostEvents.clear();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        h.controller.didChangeAppLifecycleState(state);
        await h.tick();
        expect(h.controller.activeOwner, same(owner));
        expect(h.controller.hasCurrentWork, isTrue);
        expect(h.avatar.hostEvents, isEmpty);
      }
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      await h.controller.end(owner);
      expect(h.avatar.hostEvents.last, (
        owner.sessionId,
        AvatarBackgroundTaskWorkPhase.end,
      ));
    },
  );

  for (final terminal in ['completed', 'cancelled']) {
    test(
      'a task $terminal in background resumes only terminal cleanup',
      () async {
        final h = await _HostHarness.start();
        addTearDown(h.close);
        final owner = h.begin()!;
        await h.controller.waitForIdle();
        h.avatar.hostEvents.clear();
        h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        h.jobCurrent = false;
        await h.controller.end(owner);
        await h.tick();
        expect(h.controller.activeOwner, isNull);
        expect(h.avatar.hostEvents, isEmpty);
        h.avatar.presentationReady.value = false;
        h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await h.tick();
        expect(h.avatar.hostEvents, isEmpty);
        h.avatar.presentationReady.value = true;
        await h.tick();
        expect(h.avatar.hostEvents, [
          (owner.sessionId, AvatarBackgroundTaskWorkPhase.end),
        ]);
        await h.tick();
        expect(h.avatar.hostEvents, hasLength(1));
      },
    );
  }

  test(
    'a pending start receipt in background does not retire a live task',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      final receipt = Completer<AvatarBackgroundTaskWorkResult>();
      h.avatar.hostStartGate = receipt;
      final owner = h.begin()!;
      await Future<void>.delayed(Duration.zero);
      h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      receipt.complete(
        const AvatarBackgroundTaskWorkResult(
          AvatarBackgroundTaskWorkDisposition.applied,
        ),
      );
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, same(owner));
      expect(h.avatar.hostEvents.map((event) => event.$2), [
        AvatarBackgroundTaskWorkPhase.start,
      ]);
      h.avatar.hostStartGate = null;
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await h.controller.waitForIdle();
      expect(h.avatar.hostEvents.map((event) => event.$1).toSet(), {
        owner.sessionId,
      });
      expect(h.avatar.hostEvents.map((event) => event.$2), [
        AvatarBackgroundTaskWorkPhase.start,
        AvatarBackgroundTaskWorkPhase.start,
      ]);
    },
  );

  for (final code in [
    'session_ended',
    'deadline_expired',
    'mutation_failed',
    'model_stale',
  ]) {
    for (final resumeBeforeReceipt in [false, true]) {
      test(
        'a $code start crossing suspension retries the same live job (resumed=$resumeBeforeReceipt)',
        () async {
          final h = await _HostHarness.start();
          addTearDown(h.close);
          final receipt = Completer<AvatarBackgroundTaskWorkResult>();
          h.avatar.hostStartGate = receipt;
          final owner = h.begin()!;
          await Future<void>.delayed(Duration.zero);
          h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
          if (resumeBeforeReceipt) {
            h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          }
          receipt.complete(
            AvatarBackgroundTaskWorkResult(
              AvatarBackgroundTaskWorkDisposition.rejected,
              code: code,
            ),
          );
          await h.controller.waitForIdle();
          expect(h.controller.activeOwner, same(owner));
          expect(h.avatar.hostEvents, [
            (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
          ]);
          h.avatar.hostStartGate = null;
          if (!resumeBeforeReceipt) {
            h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          }
          await h.tick();
          expect(h.controller.activeOwner, same(owner));
          expect(h.avatar.hostEvents, [
            (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
            (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
          ]);
        },
      );
    }
  }

  test('suspension never reopens a genuinely ended native session', () async {
    final h = await _HostHarness.start();
    addTearDown(h.close);
    final receipt = Completer<AvatarBackgroundTaskWorkResult>();
    h.avatar.hostStartGate = receipt;
    final owner = h.begin()!;
    await Future<void>.delayed(Duration.zero);
    h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    receipt.complete(
      const AvatarBackgroundTaskWorkResult(
        AvatarBackgroundTaskWorkDisposition.rejected,
        code: 'session_ended',
      ),
    );
    await h.controller.waitForIdle();
    h.avatar.hostStartGate = null;
    h.avatar.hostReplies.add(
      const AvatarBackgroundTaskWorkResult(
        AvatarBackgroundTaskWorkDisposition.rejected,
        code: 'session_ended',
      ),
    );
    h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await h.tick();
    expect(h.controller.activeOwner, isNull);
    expect(h.avatar.hostEvents.map((event) => event.$1).toSet(), {
      owner.sessionId,
    });
    expect(h.avatar.hostEvents.map((event) => event.$2), [
      AvatarBackgroundTaskWorkPhase.start,
      AvatarBackgroundTaskWorkPhase.start,
      AvatarBackgroundTaskWorkPhase.end,
    ]);
    await h.tick();
    expect(h.avatar.hostEvents, hasLength(3));
  });

  for (final ambiguousStart in [false, true]) {
    test(
      'a resume busy reply preserves earlier possible work for end (ambiguous=$ambiguousStart)',
      () async {
        final h = await _HostHarness.start();
        addTearDown(h.close);
        final receipt = ambiguousStart
            ? Completer<AvatarBackgroundTaskWorkResult>()
            : null;
        h.avatar.hostStartGate = receipt;
        final owner = h.begin()!;
        await Future<void>.delayed(Duration.zero);
        if (!ambiguousStart) await h.controller.waitForIdle();
        h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        receipt?.complete(
          const AvatarBackgroundTaskWorkResult(
            AvatarBackgroundTaskWorkDisposition.rejected,
            code: 'mutation_failed',
          ),
        );
        await h.controller.waitForIdle();
        h.avatar.hostStartGate = null;
        h.avatar.hostReplies.add(
          const AvatarBackgroundTaskWorkResult(
            AvatarBackgroundTaskWorkDisposition.waitingForPresentation,
            code: 'presentation_busy',
          ),
        );
        h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await h.controller.waitForIdle();
        h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        h.jobCurrent = false;
        await h.controller.end(owner);
        expect(h.controller.activeOwner, isNull);
        expect(h.avatar.hostEvents.map((event) => event.$2), [
          AvatarBackgroundTaskWorkPhase.start,
          AvatarBackgroundTaskWorkPhase.start,
        ]);
        h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await h.controller.waitForIdle();
        expect(h.avatar.hostEvents, [
          (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
          (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
          (owner.sessionId, AvatarBackgroundTaskWorkPhase.end),
        ]);
      },
    );
  }

  test(
    'terminal cleanup retries a lost end receipt without restarting work',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      h.avatar.hostEvents.clear();
      h.avatar.hostReplies.add(
        const AvatarBackgroundTaskWorkResult(
          AvatarBackgroundTaskWorkDisposition.rejected,
          code: 'mutation_failed',
        ),
      );
      await h.controller.end(owner);
      expect(h.controller.activeOwner, isNull);
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.end),
      ]);
      await h.tick();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.end),
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.end),
      ]);
      await h.tick();
      expect(h.avatar.hostEvents, hasLength(2));
    },
  );

  test('background cleanup never targets a replacement model', () async {
    final h = await _HostHarness.start();
    addTearDown(h.close);
    final owner = h.begin()!;
    await h.controller.waitForIdle();
    h.avatar.hostEvents.clear();
    h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await h.controller.end(owner);
    h.avatar.workEpoch++;
    h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await h.tick();
    expect(h.avatar.hostEvents, isEmpty);
    expect(h.controller.activeOwner, isNull);
  });

  testWidgets(
    'rapid background replacements drain one cleanup and release observers',
    (tester) async {
      final h = _Harness();
      final original = h.begin()!;
      await h.controller.waitForIdle();
      h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await h.controller.end(original);
      for (var attempt = 2; attempt <= 52; attempt++) {
        final replacement = h.begin(attempt: attempt)!;
        await h.controller.end(replacement);
      }
      expect(h.controller.activeOwner, isNull);
      expect(h.events, [
        (original.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await h.controller.waitForIdle();
      await tester.pump(const Duration(seconds: 1));
      expect(h.events, [
        (original.sessionId, AvatarBackgroundTaskWorkPhase.start),
        (original.sessionId, AvatarBackgroundTaskWorkPhase.end),
      ]);
      expect(WidgetsBinding.instance.removeObserver(h.controller), isFalse);
      await h.avatar.states.close();
      // Deliberately do not dispose the controller: the widget test binding also
      // verifies no periodic readiness timer survives ordinary terminal cleanup.
    },
  );

  test(
    'native presentation busy retries the same admitted session once ready',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.avatar.hostReplies.add(
        const AvatarBackgroundTaskWorkResult(
          AvatarBackgroundTaskWorkDisposition.waitingForPresentation,
          code: 'presence_busy',
        ),
      );
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, same(owner));
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      await h.tick();
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      await h.tick();
      expect(
        h.avatar.hostEvents,
        hasLength(2),
        reason: 'Applied work does not restart on polling',
      );
    },
  );

  test('job completion while native is busy prevents a later start', () async {
    final h = await _HostHarness.start();
    addTearDown(h.close);
    h.avatar.hostReplies.add(
      const AvatarBackgroundTaskWorkResult(
        AvatarBackgroundTaskWorkDisposition.waitingForPresentation,
        code: 'presence_busy',
      ),
    );
    final owner = h.begin()!;
    await h.controller.waitForIdle();
    await h.controller.end(owner);
    await h.tick();
    expect(h.controller.activeOwner, isNull);
    expect(h.avatar.hostEvents, [
      (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
    ]);
  });

  test('late applied host start drains before retirement completes', () async {
    final h = await _HostHarness.start();
    addTearDown(h.close);
    h.avatar.hostStartGate = Completer<AvatarBackgroundTaskWorkResult>();
    final owner = h.begin()!;
    await Future<void>.delayed(Duration.zero);
    var ended = false;
    final ending = h.controller.end(owner).then((_) => ended = true);
    await Future<void>.delayed(Duration.zero);
    expect(ended, isFalse);
    h.avatar.hostStartGate!.complete(
      const AvatarBackgroundTaskWorkResult(
        AvatarBackgroundTaskWorkDisposition.applied,
      ),
    );
    await ending;
    expect(h.controller.activeOwner, isNull);
    expect(h.avatar.hostEvents, [
      (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      (owner.sessionId, AvatarBackgroundTaskWorkPhase.end),
    ]);
  });

  test(
    'host model replacement retires old intent and skips stale end',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      h.avatar.workEpoch++;
      await h.tick();
      expect(h.controller.activeOwner, isNull);
      expect(h.avatar.hostEvents, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      await h.tick();
      expect(h.avatar.hostEvents, hasLength(1));
    },
  );

  test(
    'rejected host work is terminal and never changes project job state',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.avatar.hostReplies.add(
        const AvatarBackgroundTaskWorkResult(
          AvatarBackgroundTaskWorkDisposition.rejected,
          code: 'unsupported_avatar',
        ),
      );
      expect(h.begin(), isNotNull);
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, isNull);
      expect(h.jobCurrent, isTrue);
      await h.tick();
      expect(
        h.avatar.hostEvents.where(
          (event) => event.$2 == AvatarBackgroundTaskWorkPhase.start,
        ),
        hasLength(1),
      );
    },
  );

  test('host work metadata is a closed semantic command', () {
    final id = 'a' * 64;
    expect(
      AvatarBodyGestureCommand(
        'work_desk',
        workSessionId: id,
        workPhase: AvatarBackgroundTaskWorkPhase.start,
      ).toCanonicalJson(),
      {
        'channel': 'bodyGesture',
        'gesture': 'work_desk',
        'workSessionId': id,
        'workPhase': 'start',
      },
    );
    expect(AvatarBodyGestureCommand('think').toCanonicalJson(), {
      'channel': 'bodyGesture',
      'gesture': 'think',
    });
    for (final invalid in [
      () => AvatarBodyGestureCommand(
        'think',
        workSessionId: id,
        workPhase: AvatarBackgroundTaskWorkPhase.start,
      ),
      () => AvatarBodyGestureCommand('work_desk', workSessionId: id),
      () => AvatarBodyGestureCommand(
        'work_desk',
        workSessionId: 'coordinates',
        workPhase: AvatarBackgroundTaskWorkPhase.start,
      ),
    ]) {
      expect(invalid, throwsArgumentError);
    }
  });

  test(
    'unready renderer waits only for the current Home job without preparing it',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.avatar.supported = false;
      final unsupported = h.begin();
      expect(unsupported, isNotNull);
      await h.controller.waitForIdle();
      await h.controller.end(unsupported);
      h.avatar.supported = true;
      h.visible = false;
      expect(h.begin(), isNull);
      h.visible = true;
      h.avatar.presentationReady.value = false;
      expect(h.begin(), isNotNull);
      expect(h.events, isEmpty);
      expect(h.avatar.prepareCount, 0);
    },
  );

  test(
    'a remote agent cannot borrow the self-avatar work presentation',
    () async {
      final avatar = _Avatar();
      final controller = AvatarBackgroundTaskWorkController(
        agentId: 'remote-agent',
        runtimeProvider: () => avatar,
        authorityProvider: () => null,
        canPresent: () => true,
        applyWork: (_, _, _) => throw StateError('foreign_actor_dispatch'),
      );
      expect(
        controller.begin(
          jobId: 'remote-job',
          attempt: 1,
          scopeKey: 'same-account',
          isCurrent: () => true,
        ),
        isNull,
      );
      await controller.dispose();
      await avatar.states.close();
    },
  );

  test('a pending cancelled job cannot begin a delayed walk', () async {
    final h = _Harness();
    addTearDown(h.close);
    final owner = h.begin()!;
    h.jobCurrent = false;
    await h.controller.end(owner);
    await h.controller.waitForIdle();
    expect(h.events, isEmpty);
    expect(h.controller.activeOwner, isNull);
  });

  test(
    'a foreign renderer authority cannot admit the visible self actor',
    () async {
      final actor = _Avatar();
      final foreign = _Avatar();
      final authority = AvatarProjectionProductionAuthority(
        accountGeneration: 1,
        featureFlags: MaasoFeatureFlagService(store: _FlagStore()),
        activeAvatarRuntime: ActiveAvatarRuntime()..register(foreign),
        renderer: foreign,
        dispatchSink: _PermitSink(),
        mountIsCurrent: () => true,
      );
      final controller = AvatarBackgroundTaskWorkController(
        runtimeProvider: () => actor,
        authorityProvider: () => authority,
        canPresent: () => true,
        applyWork: (_, _, _) => throw StateError('foreign_renderer_dispatch'),
      );
      expect(
        controller.begin(
          jobId: 'job',
          attempt: 1,
          scopeKey: 'scope',
          isCurrent: () => true,
        ),
        isNull,
      );
      await controller.dispose();
      await actor.states.close();
      await foreign.states.close();
    },
  );

  test(
    'removing an exact retained task lease preserves the user and never revives work',
    () async {
      final sink = _PermitSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        capabilities: AvatarCommandCapabilities(
          supportedChannels: {AvatarCommandChannel.bodyGesture},
          supportedBodyGestures: {'work_desk', 'sit_sofa'},
        ),
      );
      final task = AvatarBodyGestureCommand(
        'work_desk',
        workSessionId: 'a' * 64,
        workPhase: AvatarBackgroundTaskWorkPhase.start,
      );
      await arbiter.acquire(
        AvatarCommandLeaseRequest(
          accountGeneration: 1,
          rendererGeneration: 1,
          commandGeneration: 1,
          leaseId: 'task',
          source: AvatarCommandSource.explicitAgent,
          command: task,
          ttl: const Duration(minutes: 10),
        ),
      );
      await arbiter.acquire(
        AvatarCommandLeaseRequest(
          accountGeneration: 1,
          rendererGeneration: 1,
          commandGeneration: 2,
          leaseId: 'user',
          source: AvatarCommandSource.explicitUser,
          command: AvatarBodyGestureCommand('sit_sofa'),
          ttl: const Duration(minutes: 1),
        ),
      );
      sink.commands.clear();
      await arbiter.release(
        AvatarCommandReleaseRequest(
          accountGeneration: 1,
          rendererGeneration: 1,
          commandGeneration: 1,
          channel: AvatarCommandChannel.bodyGesture,
          source: AvatarCommandSource.explicitAgent,
        ),
      );
      expect(
        sink.commands,
        isEmpty,
        reason: 'Cached task retirement does not clear user posture',
      );
      await arbiter.release(
        AvatarCommandReleaseRequest(
          accountGeneration: 1,
          rendererGeneration: 1,
          commandGeneration: 2,
          channel: AvatarCommandChannel.bodyGesture,
          source: AvatarCommandSource.explicitUser,
        ),
      );
      expect(
        sink.commands.where(
          (c) =>
              c.command is AvatarBodyGestureCommand &&
              (c.command as AvatarBodyGestureCommand).workSessionId != null,
        ),
        isEmpty,
      );
      await arbiter.sealAndDrain();
    },
  );

  test(
    'a job continues independently when the native work presentation rejects',
    () async {
      final h = _Harness()..reject = true;
      addTearDown(h.close);
      expect(h.begin(), isNotNull);
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, isNull);
      expect(h.avatar.prepareCount, 0);
      expect(h.events.map((e) => e.$2), [
        AvatarBackgroundTaskWorkPhase.start,
        AvatarBackgroundTaskWorkPhase.end,
      ]);
    },
  );

  test(
    'only the exact active owner releases a completed task presentation',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      final first = h.begin()!;
      await h.controller.waitForIdle();
      final second = h.begin(attempt: 2)!;
      await h.controller.waitForIdle();
      h.events.clear();
      await h.controller.end(first);
      expect(h.controller.activeOwner, same(second));
      expect(h.events, isEmpty);
      await h.controller.end(second);
      expect(h.events, [(second.sessionId, AvatarBackgroundTaskWorkPhase.end)]);
    },
  );

  test(
    'user furniture takeover retires ownership and never forces stand up',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      h.avatar.observe(AvatarFurniturePhase.working, id: owner.sessionId);
      await Future<void>.delayed(Duration.zero);
      h.avatar.observe(AvatarFurniturePhase.seated, furniture: 'sofa');
      await Future<void>.delayed(Duration.zero);
      h.events.clear();
      await h.controller.end(owner);
      expect(h.controller.activeOwner, isNull);
      expect(h.events, isEmpty);
      expect(h.avatar.furnitureState!.furnitureId, 'sofa');
    },
  );

  for (final phase in [
    AvatarFurniturePhase.standing,
    AvatarFurniturePhase.seated,
  ]) {
    test(
      'foreground $phase observation cannot retire current work or replay it',
      () async {
        final h = _Harness();
        addTearDown(h.close);
        final owner = h.begin()!;
        await h.controller.waitForIdle();
        h.avatar.observe(AvatarFurniturePhase.working, id: owner.sessionId);
        await Future<void>.delayed(Duration.zero);
        h.events.clear();
        h.avatar.observe(
          phase,
          furniture: phase == AvatarFurniturePhase.standing ? '' : 'desk',
        );
        await Future<void>.delayed(Duration.zero);
        expect(h.controller.activeOwner, same(owner));
        expect(h.controller.hasCurrentWork, isTrue);
        expect(h.events, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 260));
        expect(
          h.events,
          isEmpty,
          reason: 'No automatic start replay after input activity',
        );
        h.jobCurrent = false;
        await h.controller.end(owner);
        expect(h.controller.hasCurrentWork, isFalse);
        expect(h.events, [
          (owner.sessionId, AvatarBackgroundTaskWorkPhase.end),
        ]);
      },
    );
  }

  test(
    'model replacement fences stale end before its renderer transport',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      h.events.clear();
      h.avatar.workEpoch++;
      await h.controller.end(owner);
      expect(h.events, isEmpty);
    },
  );

  test(
    'a temporary hidden presentation retains work but leaving Home retires it',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      h.events.clear();
      h.avatar.presentationReady.value = false;
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, same(owner));
      expect(h.events, isEmpty);
      h.avatar.presentationReady.value = true;
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, same(owner));
      expect(h.events, [
        (owner.sessionId, AvatarBackgroundTaskWorkPhase.start),
      ]);
      h.events.clear();
      h.visible = false;
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, isNull);
      expect(h.events, [(owner.sessionId, AvatarBackgroundTaskWorkPhase.end)]);
    },
  );

  test('dispose drains work and blocks all subsequent starts', () async {
    final h = _Harness();
    addTearDown(h.close);
    final owner = h.begin()!;
    await h.controller.waitForIdle();
    h.events.clear();
    await h.controller.dispose();
    expect(h.events, [(owner.sessionId, AvatarBackgroundTaskWorkPhase.end)]);
    expect(h.begin(attempt: 2), isNull);
  });

  test(
    'dispose joins an in-flight begin even when a prior end removed the owner',
    () async {
      final h = _Harness()..startGate = Completer<void>();
      addTearDown(h.close);
      final owner = h.begin()!;
      await Future<void>.delayed(Duration.zero);
      unawaited(h.controller.end(owner));
      var completed = false;
      final draining = h.controller.dispose().then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, false);
      h.startGate!.complete();
      await draining;
      expect(completed, true);
      expect(h.controller.activeOwner, isNull);
      expect(h.events.map((e) => e.$2), [
        AvatarBackgroundTaskWorkPhase.start,
        AvatarBackgroundTaskWorkPhase.end,
      ]);
    },
  );
}

class _HostHarness {
  _HostHarness._(this.flags, this.authority, this.avatar, this.sink) {
    renderer = avatar;
    controller = AvatarBackgroundTaskWorkController(
      runtimeProvider: () => renderer,
      authorityProvider: () => authority,
      canPresent: () => visible,
      isReturningHome: (_) => returningHome,
    );
  }
  static Future<_HostHarness> start({
    FeatureRolloutMode mode = FeatureRolloutMode.off,
  }) async {
    final avatar = _Avatar()..hostSupported = true;
    final active = ActiveAvatarRuntime()..register(avatar);
    final flags = await MaasoFeatureFlagService(
      store: _FlagStore(),
      compileMaximums: mode == FeatureRolloutMode.off
          ? null
          : {MaasoFeatureFlag.avatarProjectionV2: mode},
    ).init();
    if (mode != FeatureRolloutMode.off) {
      await flags.assign(
        flag: MaasoFeatureFlag.avatarProjectionV2,
        mode: mode,
        revision: 1,
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
    }
    final sink = _PermitSink();
    final authority = AvatarProjectionProductionAuthority(
      accountGeneration: 1,
      featureFlags: flags,
      activeAvatarRuntime: active,
      renderer: avatar,
      dispatchSink: sink,
      mountIsCurrent: () => true,
    )..onInit();
    await authority.waitForIdle();
    return _HostHarness._(flags, authority, avatar, sink);
  }

  final MaasoFeatureFlagService flags;
  final AvatarProjectionProductionAuthority authority;
  final _Avatar avatar;
  final _PermitSink sink;
  late final AvatarBackgroundTaskWorkController controller;
  AvatarRuntime? renderer;
  bool visible = true, jobCurrent = true, returningHome = false;
  AvatarBackgroundTaskWorkOwner? begin() => controller.begin(
    jobId: 'job',
    attempt: 1,
    scopeKey: 'account/environment',
    isCurrent: () => jobCurrent,
  );
  Future<void> tick() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await controller.waitForIdle();
  }

  Future<void> close() async {
    await controller.dispose();
    await authority.sealAndDrain();
    authority.onClose();
    flags.onClose();
    await avatar.states.close();
  }
}

class _Harness {
  _Harness() {
    controller = AvatarBackgroundTaskWorkController(
      runtimeProvider: () => avatar,
      authorityProvider: () => null,
      canPresent: () => visible,
      applyWork: (id, phase, admitted) async {
        if (!admitted()) {
          return const AvatarProductionBehaviorResult(
            AvatarProductionBehaviorDisposition.authorityStale,
          );
        }
        events.add((id, phase));
        if (phase == AvatarBackgroundTaskWorkPhase.start) {
          await startGate?.future;
        }
        if (reject) {
          return const AvatarProductionBehaviorResult(
            AvatarProductionBehaviorDisposition.dispatchFailed,
          );
        }
        avatar.observe(
          phase == AvatarBackgroundTaskWorkPhase.start
              ? AvatarFurniturePhase.approaching
              : AvatarFurniturePhase.rising,
          id: phase == AvatarBackgroundTaskWorkPhase.start ? id : null,
        );
        return const AvatarProductionBehaviorResult(
          AvatarProductionBehaviorDisposition.applied,
        );
      },
    );
  }
  final avatar = _Avatar();
  final events = <(String, AvatarBackgroundTaskWorkPhase)>[];
  late final AvatarBackgroundTaskWorkController controller;
  bool visible = true, jobCurrent = true, reject = false;
  Completer<void>? startGate;
  AvatarBackgroundTaskWorkOwner? begin({int attempt = 1}) => controller.begin(
    jobId: 'job',
    attempt: attempt,
    scopeKey: 'account/environment',
    isCurrent: () => jobCurrent,
  );
  Future<void> close() async {
    await controller.dispose();
    await avatar.states.close();
  }
}

class _Avatar extends AvatarRuntime implements AvatarFurnitureRuntime {
  final states = StreamController<AvatarFurnitureState>.broadcast();
  bool supported = true;
  bool hostSupported = false;
  final hostEvents = <(String, AvatarBackgroundTaskWorkPhase)>[];
  final hostReplies = <AvatarBackgroundTaskWorkResult>[];
  Completer<AvatarBackgroundTaskWorkResult>? hostStartGate;
  int workEpoch = 0, prepareCount = 0;
  @override
  final isReady = true.obs;
  @override
  final presentationReady = true.obs;
  @override
  bool get supportsBackgroundTaskWorkPresentation => supported;
  @override
  bool get supportsHostBackgroundTaskWorkPresentation => hostSupported;
  @override
  Future<AvatarBackgroundTaskWorkResult> setBackgroundTaskWork({
    required String sessionId,
    required AvatarBackgroundTaskWorkPhase phase,
  }) async {
    hostEvents.add((sessionId, phase));
    if (phase == AvatarBackgroundTaskWorkPhase.start && hostStartGate != null) {
      return hostStartGate!.future;
    }
    final result = hostReplies.isEmpty
        ? const AvatarBackgroundTaskWorkResult(
            AvatarBackgroundTaskWorkDisposition.applied,
          )
        : hostReplies.removeAt(0);
    if (result.applied) {
      observe(
        phase == AvatarBackgroundTaskWorkPhase.start
            ? AvatarFurniturePhase.approaching
            : AvatarFurniturePhase.rising,
        id: phase == AvatarBackgroundTaskWorkPhase.start ? sessionId : null,
      );
    }
    return result;
  }

  @override
  int get backgroundTaskWorkPresentationEpoch => workEpoch;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  @override
  AvatarFurnitureState? furnitureState;
  @override
  Stream<AvatarFurnitureState> get furnitureStates => states.stream;
  @override
  Future<void> prepareRenderer() async => prepareCount++;
  void observe(
    AvatarFurniturePhase phase, {
    String? id,
    String furniture = 'desk',
  }) {
    furnitureState = AvatarFurnitureState(
      phase: phase,
      furnitureId: furniture,
      sceneId: 'room',
      sequence: (furnitureState?.sequence ?? 0) + 1,
      workSessionId: id,
    );
    states.add(furnitureState!);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PermitSink implements AvatarCommandDispatchSink {
  final commands = <AvatarCommandDispatch>[];
  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async => operation.applyIfCurrent(commands.add)!;
  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async => operation.resetOrDisposeIfCurrent(() {})!;
}

class _FlagStore implements MaasoFeatureFlagAssignmentStore {
  @override
  Future<List<Map<String, Object?>>> readAll() async => [];
  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {}
}
