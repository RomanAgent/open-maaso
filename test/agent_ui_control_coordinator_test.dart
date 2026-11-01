import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';

void main() {
  group('AgentUiControlCoordinator', () {
    late AgentUiControlCoordinator coordinator;

    setUp(() {
      coordinator = AgentUiControlCoordinator();
    });

    tearDown(() async {
      await coordinator.dispose();
    });

    test(
      'enforces one lease and exposes the complete state lifecycle',
      () async {
        expect(coordinator.snapshot.phase, AgentUiControlPhase.idle);

        final started = coordinator.begin(
          sessionId: 'session-1',
          purpose: 'write a draft',
          targetRoute: '/creator',
          requiresConsent: true,
        );
        expect(started.isSuccess, isTrue);
        final lease = started.value!;
        expect(coordinator.snapshot.phase, AgentUiControlPhase.awaitingConsent);
        expect(coordinator.snapshot.sessionId, 'session-1');
        expect(coordinator.snapshot.generation, lease.generation);

        final competing = coordinator.begin(
          sessionId: 'session-2',
          purpose: 'competing action',
        );
        expect(competing.status, AgentUiControlResultStatus.busy);

        expect(coordinator.grantConsent(lease).isSuccess, isTrue);
        expect(coordinator.snapshot.phase, AgentUiControlPhase.navigating);
        expect(coordinator.enterNavigating(lease).isSuccess, isTrue);

        final command = await coordinator.runStep<String>(
          lease: lease,
          stepId: 'open-editor',
          command: (context) async {
            expect(coordinator.snapshot.phase, AgentUiControlPhase.operating);
            expect(coordinator.snapshot.stepId, 'open-editor');
            context.checkpoint();
            return 'opened';
          },
        );
        expect(command.isSuccess, isTrue);
        expect(command.value, 'opened');
        expect(coordinator.snapshot.phase, AgentUiControlPhase.operating);
        expect(coordinator.snapshot.stepId, isNull);

        expect(coordinator.complete(lease).isSuccess, isTrue);
        expect(coordinator.snapshot.phase, AgentUiControlPhase.completed);
        coordinator.settle();
        expect(coordinator.snapshot.phase, AgentUiControlPhase.idle);

        final failingLease = coordinator
            .begin(sessionId: 'session-3', purpose: 'failing action')
            .value!;
        final failed = await coordinator.runStep<void>(
          lease: failingLease,
          stepId: 'fail',
          command: (_) async => throw StateError('broken adapter'),
        );
        expect(failed.status, AgentUiControlResultStatus.executionFailed);
        expect(coordinator.snapshot.phase, AgentUiControlPhase.failed);
        expect(coordinator.snapshot.failureMessage, contains('broken adapter'));
      },
    );

    test('runs UI commands strictly in submission order', () async {
      final lease = coordinator
          .begin(sessionId: 'serial', purpose: 'serialize commands')
          .value!;
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var secondStarted = false;
      final order = <String>[];

      final first = coordinator.runStep<void>(
        lease: lease,
        stepId: 'first',
        command: (context) async {
          order.add('first-start');
          firstStarted.complete();
          await context.guardedAwait(releaseFirst.future);
          order.add('first-end');
        },
      );
      final second = coordinator.runStep<void>(
        lease: lease,
        stepId: 'second',
        command: (_) async {
          secondStarted = true;
          order.add('second');
        },
      );

      await firstStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(secondStarted, isFalse);
      releaseFirst.complete();

      expect((await first).isSuccess, isTrue);
      expect((await second).isSuccess, isTrue);
      expect(order, <String>['first-start', 'first-end', 'second']);
    });

    test(
      'user takeover pauses only the UI lease until explicit resume',
      () async {
        final oldLease = coordinator
            .begin(sessionId: 'takeover', purpose: 'operate page')
            .value!;
        final started = Completer<void>();
        final release = Completer<void>();

        final inFlight = coordinator.runStep<String>(
          lease: oldLease,
          stepId: 'await-page',
          command: (context) async {
            started.complete();
            await context.guardedAwait(release.future);
            return 'must-not-commit';
          },
        );
        await started.future;

        expect(
          coordinator.pauseForUserActivity(reason: 'pointer_down'),
          isTrue,
        );
        expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
        expect(coordinator.checkLease(oldLease).reason, 'paused_by_user');

        final resumed = coordinator.resume(oldLease);
        expect(resumed.isSuccess, isTrue);
        final newLease = resumed.value!;
        expect(newLease.sessionId, oldLease.sessionId);
        expect(newLease.generation, greaterThan(oldLease.generation));

        release.complete();
        final staleCompletion = await inFlight;
        expect(staleCompletion.reason, 'stale_session');

        final oldCommand = await coordinator.runStep<void>(
          lease: oldLease,
          stepId: 'old-generation',
          command: (_) async {},
        );
        expect(oldCommand.reason, 'stale_session');

        final resumedCommand = await coordinator.runStep<String>(
          lease: newLease,
          stepId: 'new-generation',
          command: (_) async => 'committed',
        );
        expect(resumedCommand.isSuccess, isTrue);
        expect(resumedCommand.value, 'committed');
      },
    );

    test('a paused lease cannot execute without resume', () async {
      final lease = coordinator
          .begin(sessionId: 'paused', purpose: 'wait for user')
          .value!;
      expect(coordinator.pauseForUserActivity(), isTrue);

      var invoked = false;
      final result = await coordinator.runStep<void>(
        lease: lease,
        stepId: 'blocked',
        command: (_) async {
          invoked = true;
        },
      );

      expect(result.reason, 'paused_by_user');
      expect(invoked, isFalse);
      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
    });

    test(
      'trusted consent input is absorbed but route changes cancel the lease',
      () {
        final lease = coordinator
            .begin(
              sessionId: 'consent-input',
              purpose: 'confirm a consequential action',
              requiresConsent: true,
            )
            .value!;

        expect(
          coordinator.pauseForUserActivity(reason: 'pointer_down'),
          isFalse,
        );
        expect(
          coordinator.pauseForUserActivity(reason: 'keyboard_input'),
          isFalse,
        );
        expect(coordinator.snapshot.phase, AgentUiControlPhase.awaitingConsent);
        expect(coordinator.checkLease(lease).isSuccess, isTrue);

        expect(
          coordinator.pauseForUserActivity(reason: 'unexpected_route_change'),
          isTrue,
        );
        expect(coordinator.snapshot.phase, AgentUiControlPhase.failed);
        expect(
          coordinator.checkLease(lease).status,
          AgentUiControlResultStatus.staleSession,
        );
      },
    );
  });
}
