import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_background_task_work.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_lookup_phone_controller.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/body/agent_body_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(() => appServices.reset());

  test('pickup starts immediately without waiting for its animation', () async {
    final h = _Harness();
    final gate = h.actor.readingGate = Completer<void>();
    final end = h.begin();
    expect(end, isNotNull);
    expect(h.actor.phases, [AvatarPhoneInteractionPhase.reading]);
    gate.complete();
    await _flush();
    expect(h.actor.phases, [
      AvatarPhoneInteractionPhase.reading,
      AvatarPhoneInteractionPhase.replying,
    ]);
    end!();
    end();
    expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
    expect(h.actor.calls.map((call) => call.id).toSet(), hasLength(1));
    expect(h.actor.phases, hasLength(3));
    await h.close();
  });

  test(
    'zero minimum releases a fast lookup without a late tapping phase',
    () async {
      final h = _Harness();
      final gate = h.actor.readingGate = Completer<void>();
      final end = h.begin()!;
      end();
      expect(h.actor.phases, [
        AvatarPhoneInteractionPhase.reading,
        AvatarPhoneInteractionPhase.none,
      ]);
      gate.complete();
      await _flush();
      expect(h.actor.phases, hasLength(2));
      await h.close();
    },
  );

  testWidgets(
    'fast normal result returns while phone finishes one visible pickup',
    (tester) async {
      final h = _Harness(
        minimumPresentationDuration: const Duration(milliseconds: 1600),
        now: () => tester.binding.clock.now(),
      );
      final pickedUp = h.actor.readingGate = Completer<void>();
      final end = h.begin()!;
      await tester.pump(const Duration(milliseconds: 400));
      var handlerReturned = false;
      end();
      handlerReturned = true;
      h.current =
          false; // A completed HTTP turn no longer owns runtime admission.
      expect(handlerReturned, isTrue);
      expect(h.actor.phases, [AvatarPhoneInteractionPhase.reading]);
      await tester.pump(const Duration(milliseconds: 650));
      pickedUp.complete();
      await tester.pump();
      expect(h.actor.phases, [
        AvatarPhoneInteractionPhase.reading,
        AvatarPhoneInteractionPhase.replying,
      ]);
      await tester.pump(const Duration(milliseconds: 549));
      expect(h.actor.phases.last, AvatarPhoneInteractionPhase.replying);
      await tester.pump(const Duration(milliseconds: 1));
      expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
      await h.close();
    },
  );

  testWidgets('slow lookup does not add a second minimum after completion', (
    tester,
  ) async {
    final h = _Harness(
      minimumPresentationDuration: const Duration(milliseconds: 1600),
      now: () => tester.binding.clock.now(),
    );
    final end = h.begin()!;
    await tester.pump(const Duration(seconds: 3));
    end();
    expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
    await h.close();
  });

  testWidgets('new lookup cancels the old normal hold without a late stop', (
    tester,
  ) async {
    final h = _Harness(
      minimumPresentationDuration: const Duration(milliseconds: 1600),
      now: () => tester.binding.clock.now(),
    );
    final first = h.begin()!;
    await tester.pump(const Duration(milliseconds: 400));
    first();
    final firstId = h.actor.calls.first.id;
    final second = h.begin()!;
    final secondId = h.actor.calls.last.id;
    expect(
      h.actor.calls.where((call) => call.id == firstId).last.phase,
      AvatarPhoneInteractionPhase.none,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(h.actor.calls.last, (
      id: secondId,
      phase: AvatarPhoneInteractionPhase.replying,
    ));
    second();
    expect(h.actor.calls.last.id, secondId);
    await h.close();
  });

  for (final revoke in ['cancel', 'navigate', 'background', 'retire']) {
    testWidgets('$revoke interrupts the minimum display immediately', (
      tester,
    ) async {
      final h = _Harness(
        minimumPresentationDuration: const Duration(milliseconds: 1600),
        now: () => tester.binding.clock.now(),
      );
      final cancelled = Completer<void>();
      final end = h.controller.begin(
        isCurrent: () => h.current,
        cancelled: cancelled.future,
      )!;
      await tester.pump(const Duration(milliseconds: 400));
      end();
      h.current = false;
      expect(h.actor.phases.last, AvatarPhoneInteractionPhase.replying);
      Future<void>? drain;
      switch (revoke) {
        case 'cancel':
          cancelled.complete();
        case 'navigate':
          h.visible = false;
          h.changes.notifyListeners();
        case 'background':
          h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        case 'retire':
          drain = h.controller.dispose();
      }
      await tester.pump();
      expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
      final count = h.actor.calls.length;
      await tester.pump(const Duration(seconds: 2));
      expect(h.actor.calls, hasLength(count));
      await drain;
      await h.close();
    });
  }

  test(
    'turn cancellation releases before the HTTP handler completes',
    () async {
      final h = _Harness();
      final gate = h.actor.readingGate = Completer<void>();
      final cancelled = Completer<void>();
      final end = h.controller.begin(
        isCurrent: () => h.current,
        cancelled: cancelled.future,
      )!;
      cancelled.complete();
      await _flush();
      expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
      end();
      gate.complete();
      await _flush();
      expect(h.actor.phases, hasLength(2));
      await h.close();
    },
  );

  test('late old completion cannot tap or stop a newer lookup', () async {
    final h = _Harness();
    final firstGate = h.actor.readingGate = Completer<void>();
    final endFirst = h.begin()!;
    final firstId = h.actor.calls.single.id;
    h.actor.readingGate = null;
    final endSecond = h.begin()!;
    final secondId = h.actor.calls.last.id;
    expect(secondId, isNot(firstId));
    await _flush();
    final count = h.actor.calls.length;
    endFirst();
    firstGate.complete();
    await _flush();
    expect(h.actor.calls, hasLength(count));
    expect(h.actor.calls.last, (
      id: secondId,
      phase: AvatarPhoneInteractionPhase.replying,
    ));
    endSecond();
    expect(h.actor.calls.last.id, secondId);
    await h.close();
  });

  test('revoked turn cannot proceed from reading to tapping', () async {
    final h = _Harness();
    final gate = h.actor.readingGate = Completer<void>();
    h.begin();
    h.current = false;
    gate.complete();
    await _flush();
    expect(h.actor.phases, [
      AvatarPhoneInteractionPhase.reading,
      AvatarPhoneInteractionPhase.none,
    ]);
    await h.close();
  });

  test('navigation stops the phone and returning does not replay', () async {
    final h = _Harness();
    h.begin();
    await _flush();
    h.visible = false;
    h.changes.notifyListeners();
    expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
    final count = h.actor.calls.length;
    h.visible = true;
    h.changes.notifyListeners();
    await _flush();
    expect(h.actor.calls, hasLength(count));
    await h.close();
  });

  test('backgrounding stops the phone without resuming stale work', () async {
    final h = _Harness();
    h.begin();
    await _flush();
    h.controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
    final count = h.actor.calls.length;
    h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _flush();
    expect(h.actor.calls, hasLength(count));
    await h.close();
  });

  test('detaching the presentation releases a still-ready renderer', () async {
    final h = _Harness();
    h.begin();
    await _flush();
    h.actor.presentationReady.value = false;
    expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
    final count = h.actor.calls.length;
    h.actor.presentationReady.value = true;
    await _flush();
    expect(h.actor.calls, hasLength(count));
    await h.close();
  });

  test('lost renderer is not sent a queued stop after recovering', () async {
    final h = _Harness();
    final gate = h.actor.readingGate = Completer<void>();
    h.begin();
    h.actor.isReady.value = false;
    h.actor.isReady.value = true;
    gate.complete();
    await _flush();
    expect(h.actor.phases, [AvatarPhoneInteractionPhase.reading]);
    await h.close();
  });

  for (final modelEpoch in [true, false]) {
    test(
      'model ${modelEpoch ? 'load' : 'presentation'} change fences old owner',
      () async {
        final h = _Harness();
        final gate = h.actor.readingGate = Completer<void>();
        final end = h.begin()!;
        if (modelEpoch) {
          h.actor.epoch++;
        } else {
          h.actor.presentationEpoch++;
        }
        h.changes.notifyListeners();
        gate.complete();
        await _flush();
        end();
        expect(h.actor.phases, [AvatarPhoneInteractionPhase.reading]);
        await h.close();
      },
    );
  }

  test(
    'a replacement renderer never receives the old phone commands',
    () async {
      final h = _Harness();
      final gate = h.actor.readingGate = Completer<void>();
      final end = h.begin()!;
      final replacement = _Avatar();
      h.renderer = replacement;
      h.changes.notifyListeners();
      end();
      gate.complete();
      await _flush();
      expect(replacement.calls, isEmpty);
      expect(h.actor.phases, [AvatarPhoneInteractionPhase.reading]);
      await h.close();
    },
  );

  test(
    'registered avatar owner replacement cannot borrow the new account',
    () async {
      final actor = _Avatar();
      final gate = actor.readingGate = Completer<void>();
      appServices.put(ActiveAvatarRuntime()..register(actor));
      final controller = AvatarLookupPhoneController(canPresent: () => true);
      final end = controller.begin(isCurrent: () => true)!;
      final replacement = _Avatar();
      appServices.put<ActiveAvatarRuntime>(
        ActiveAvatarRuntime()..register(replacement),
        overrideAbstract: true,
      );
      await _flush();
      end();
      gate.complete();
      await _flush();
      expect(replacement.calls, isEmpty);
      expect(actor.phases, [AvatarPhoneInteractionPhase.reading]);
      await controller.dispose();
    },
  );

  test(
    'missing, unready, hidden and non-self avatars do not queue work',
    () async {
      final h = _Harness();
      h.renderer = null;
      expect(h.begin(), isNull);
      h.renderer = h.actor;
      h.actor.isReady.value = false;
      expect(h.begin(), isNull);
      h.actor.isReady.value = true;
      h.actor.presentationReady.value = false;
      expect(h.begin(), isNull);
      h.actor.presentationReady.value = true;
      h.visible = false;
      expect(h.begin(), isNull);
      h.visible = true;
      h.current = false;
      expect(h.begin(), isNull);
      final peer = AvatarLookupPhoneController(
        agentId: 'peer',
        runtimeProvider: () => h.actor,
        canPresent: () => true,
      );
      expect(peer.begin(isCurrent: () => true), isNull);
      expect(h.actor.calls, isEmpty);
      await peer.dispose();
      await h.close();
    },
  );

  test('hidden registered avatar is not made visible for a lookup', () async {
    final actor = _Avatar();
    final active = ActiveAvatarRuntime()..register(actor);
    appServices.put(active);
    await active.setLocalAvatarVisible(false);
    final controller = AvatarLookupPhoneController(canPresent: () => true);
    expect(controller.begin(isCurrent: () => true), isNull);
    expect(actor.calls, isEmpty);
    await controller.dispose();
  });

  for (final phase in [
    AvatarPhoneInteractionPhase.reading,
    AvatarPhoneInteractionPhase.replying,
  ]) {
    test(
      'a rejected $phase phase is swallowed without retrying pickup',
      () async {
        final h = _Harness();
        h.actor.failPhase = phase;
        expect(h.begin(), isNotNull);
        await _flush();
        expect(
          h.actor.phases.where(
            (phase) => phase == AvatarPhoneInteractionPhase.reading,
          ),
          hasLength(1),
        );
        expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
        final count = h.actor.calls.length;
        h.changes.notifyListeners();
        await _flush();
        expect(h.actor.calls, hasLength(count));
        await h.close();
      },
    );
  }

  test(
    'synchronous renderer failure and guard failure stay optional',
    () async {
      final h = _Harness();
      h.actor.throwSynchronously = true;
      expect(h.begin(), isNotNull);
      await _flush();
      expect(h.actor.phases, [
        AvatarPhoneInteractionPhase.reading,
        AvatarPhoneInteractionPhase.none,
      ]);
      expect(
        h.controller.begin(isCurrent: () => throw StateError('revoked')),
        isNull,
      );
      await h.close();
    },
  );

  test(
    'disposal revokes immediately and drains only existing receipts',
    () async {
      final h = _Harness();
      final gate = h.actor.readingGate = Completer<void>();
      h.begin();
      final drained = h.controller.dispose();
      expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
      gate.complete();
      await drained;
      expect(h.begin(), isNull);
      expect(h.actor.phases, hasLength(2));
      await h.close();
    },
  );

  test('admitted desk work releases phone and blocks further pickup', () async {
    final h = _Harness();
    final work = AvatarBackgroundTaskWorkController(
      runtimeProvider: () => h.actor,
      authorityProvider: () => null,
      canPresent: () => true,
      isReturningHome: (_) => false,
      isTemporarilyBlocked: h.controller.isReleasingFor,
    );
    final body = AgentBodyController(
      backgroundTaskWork: work,
      lookupPhone: h.controller,
    );
    expect(body.beginLookupPhone(isCurrent: () => true), isNotNull);
    await _flush();
    final owner = body.beginBackgroundTaskWork(
      jobId: 'job',
      attempt: 1,
      scopeKey: 'account-scope',
      isCurrent: () => true,
    );
    expect(owner, isNotNull);
    expect(h.actor.phases.last, AvatarPhoneInteractionPhase.none);
    expect(body.beginLookupPhone(isCurrent: () => true), isNull);
    await body.dispose();
    expect(
      h.actor.workPhases.where(
        (phase) => phase == AvatarBackgroundTaskWorkPhase.start,
      ),
      isEmpty,
      reason: 'Disposal before queued work starts does not revive it',
    );
    await h.close();
  });

  test(
    'desk owner returns immediately and starts only after phone is put away',
    () async {
      final h = _Harness();
      final putAway = h.actor.noneGate = Completer<void>();
      final work = AvatarBackgroundTaskWorkController(
        runtimeProvider: () => h.actor,
        authorityProvider: () => null,
        canPresent: () => true,
        isReturningHome: (_) => false,
        isTemporarilyBlocked: h.controller.isReleasingFor,
      );
      final body = AgentBodyController(
        backgroundTaskWork: work,
        lookupPhone: h.controller,
      );
      body.beginLookupPhone(isCurrent: () => true);
      await _flush();
      final owner = body.beginBackgroundTaskWork(
        jobId: 'job',
        attempt: 1,
        scopeKey: 'scope',
        isCurrent: () => true,
      );
      expect(owner, isNotNull);
      expect(work.hasCurrentWork, isTrue);
      expect(h.controller.isReleasingFor(h.actor), isTrue);
      await work.waitForIdle();
      expect(h.actor.workPhases, isEmpty);
      putAway.complete();
      await _flush();
      expect(h.controller.isReleasingFor(h.actor), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await work.waitForIdle();
      expect(h.actor.workPhases, [AvatarBackgroundTaskWorkPhase.start]);
      await body.dispose();
      await h.close();
    },
  );

  test('ending desk work before phone release never starts it later', () async {
    final h = _Harness();
    final putAway = h.actor.noneGate = Completer<void>();
    final work = AvatarBackgroundTaskWorkController(
      runtimeProvider: () => h.actor,
      authorityProvider: () => null,
      canPresent: () => true,
      isReturningHome: (_) => false,
      isTemporarilyBlocked: h.controller.isReleasingFor,
    );
    final body = AgentBodyController(
      backgroundTaskWork: work,
      lookupPhone: h.controller,
    );
    body.beginLookupPhone(isCurrent: () => true);
    await _flush();
    final owner = body.beginBackgroundTaskWork(
      jobId: 'job',
      attempt: 1,
      scopeKey: 'scope',
      isCurrent: () => true,
    );
    await work.waitForIdle();
    await body.endBackgroundTaskWork(owner);
    putAway.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(h.actor.workPhases, isEmpty);
    await body.dispose();
    await h.close();
  });

  testWidgets('phone release gate expires with the native receipt budget', (
    tester,
  ) async {
    final h = _Harness();
    h.actor.noneGate = Completer<void>();
    final end = h.begin()!;
    await tester.pump();
    end();
    expect(h.controller.isReleasingFor(h.actor), isTrue);
    await tester.pump(const Duration(seconds: 6));
    expect(h.controller.isReleasingFor(h.actor), isFalse);
    await h.close();
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _Harness {
  _Harness({
    Duration minimumPresentationDuration = Duration.zero,
    DateTime Function()? now,
  }) {
    renderer = actor;
    controller = AvatarLookupPhoneController(
      runtimeProvider: () => renderer,
      canPresent: () => visible,
      presentationChanges: changes,
      minimumPresentationDuration: minimumPresentationDuration,
      now: now,
    );
  }
  final actor = _Avatar();
  AvatarRuntime? renderer;
  final changes = ChangeNotifier();
  late final AvatarLookupPhoneController controller;
  bool current = true;
  bool visible = true;

  void Function()? begin() => controller.begin(isCurrent: () => current);

  Future<void> close() async {
    await controller.dispose();
    changes.dispose();
  }
}

class _Avatar extends AvatarRuntime {
  @override
  final isReady = true.obs;
  @override
  final presentationReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  int epoch = 0;
  int presentationEpoch = 0;
  @override
  int get modelLoadEpoch => epoch;
  @override
  int get backgroundTaskWorkPresentationEpoch => presentationEpoch;
  Completer<void>? readingGate;
  Completer<void>? noneGate;
  AvatarPhoneInteractionPhase? failPhase;
  bool throwSynchronously = false;
  final calls = <({String id, AvatarPhoneInteractionPhase phase})>[];
  final workPhases = <AvatarBackgroundTaskWorkPhase>[];
  List<AvatarPhoneInteractionPhase> get phases =>
      calls.map((call) => call.phase).toList();

  @override
  Future<void> setPhoneInteraction({
    required String interactionId,
    required AvatarPhoneInteractionPhase phase,
  }) {
    calls.add((id: interactionId, phase: phase));
    if (throwSynchronously) throw StateError('transport_unavailable');
    if (failPhase == phase) {
      return Future.error(
        const AvatarPhoneInteractionException('presentation_busy'),
      );
    }
    return switch (phase) {
      AvatarPhoneInteractionPhase.reading =>
        readingGate?.future ?? Future<void>.value(),
      AvatarPhoneInteractionPhase.none =>
        noneGate?.future ?? Future<void>.value(),
      _ => Future<void>.value(),
    };
  }

  @override
  bool get supportsHostBackgroundTaskWorkPresentation => true;
  @override
  Future<AvatarBackgroundTaskWorkResult> setBackgroundTaskWork({
    required String sessionId,
    required AvatarBackgroundTaskWorkPhase phase,
  }) async {
    workPhases.add(phase);
    return const AvatarBackgroundTaskWorkResult(
      AvatarBackgroundTaskWorkDisposition.applied,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
