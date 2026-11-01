import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';

void main() {
  const enabledRollout = AgentCapabilityRollout(
    requestLazyHostActivation: true,
    requestPageSkillDefaults: true,
    requestPageAgentControl: true,
  );

  test('disabled rollout rejects new UI-control leases', () async {
    final rollout = AgentCapabilityRolloutService();
    final coordinator = AgentUiControlCoordinator(
      isControlEnabled: () => rollout.current.pageAgentControlEnabled,
      controlEnabledChanges: rollout.changes.map(
        (value) => value.pageAgentControlEnabled,
      ),
    );
    addTearDown(rollout.onClose);
    addTearDown(coordinator.dispose);

    final result = coordinator.begin(
      sessionId: 'disabled-session',
      purpose: 'must not control the page',
    );

    expect(result.status, AgentUiControlResultStatus.invalidState);
    expect(coordinator.snapshot.phase, AgentUiControlPhase.idle);
  });

  test(
    'dynamic kill switch pauses immediately and aborts awaited continuation',
    () async {
      final rollout = AgentCapabilityRolloutService(initial: enabledRollout);
      final coordinator = AgentUiControlCoordinator(
        isControlEnabled: () => rollout.current.pageAgentControlEnabled,
        controlEnabledChanges: rollout.changes.map(
          (value) => value.pageAgentControlEnabled,
        ),
      );
      addTearDown(rollout.onClose);
      addTearDown(coordinator.dispose);
      final lease = coordinator
          .begin(sessionId: 'active-session', purpose: 'prepare a draft')
          .value!;
      final started = Completer<void>();
      final release = Completer<void>();
      final inFlight = coordinator.runStep<String>(
        lease: lease,
        stepId: 'fill-editor',
        command: (context) async {
          started.complete();
          await context.guardedAwait(release.future);
          return 'must-not-commit';
        },
      );
      await started.future;

      rollout.disableAll();

      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
      expect(coordinator.snapshot.pauseReason, 'rollout_disabled');
      expect(
        coordinator.resume(lease).status,
        AgentUiControlResultStatus.invalidState,
      );
      release.complete();
      expect((await inFlight).reason, 'paused_by_user');

      rollout.update(enabledRollout);
      final resumed = coordinator.resume(lease);
      expect(resumed.isSuccess, isTrue);
      expect(resumed.value!.generation, greaterThan(lease.generation));
    },
  );

  test('kill switch is rechecked while consent is pending', () async {
    final rollout = AgentCapabilityRolloutService(initial: enabledRollout);
    final coordinator = AgentUiControlCoordinator(
      isControlEnabled: () => rollout.current.pageAgentControlEnabled,
      controlEnabledChanges: rollout.changes.map(
        (value) => value.pageAgentControlEnabled,
      ),
    );
    addTearDown(rollout.onClose);
    addTearDown(coordinator.dispose);
    final lease = coordinator
        .begin(
          sessionId: 'consent-session',
          purpose: 'wait for consent',
          requiresConsent: true,
        )
        .value!;

    rollout.disableAll();

    expect(
      coordinator.grantConsent(lease).status,
      AgentUiControlResultStatus.invalidState,
    );
    expect(coordinator.snapshot.phase, AgentUiControlPhase.failed);
    expect(coordinator.snapshot.failureMessage, 'rollout_disabled');
  });
}
