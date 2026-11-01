import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout_service.dart';

void main() {
  test('updates kill switches synchronously and keeps public writes off', () {
    final service = AgentCapabilityRolloutService();
    addTearDown(service.onClose);
    final observed = <AgentCapabilityRollout>[];
    final subscription = service.changes.listen(observed.add);
    addTearDown(subscription.cancel);

    expect(service.generation, 0);
    expect(service.current.publicWritesEnabled, isFalse);

    const staged = AgentCapabilityRollout(
      requestLazyHostActivation: true,
      requestPageSkillDefaults: true,
      requestPageAgentControl: true,
      requestPublicDrafts: true,
    );
    service.update(staged);

    expect(service.generation, 1);
    expect(observed, <AgentCapabilityRollout>[staged]);
    expect(service.current.pageAgentControlEnabled, isTrue);
    expect(service.current.publicDraftsEnabled, isTrue);
    expect(service.current.publicWritesEnabled, isFalse);

    service.disableAll();

    expect(service.generation, 2);
    expect(observed, hasLength(2));
    for (final gate in AgentCapabilityGate.values) {
      expect(service.isEnabled(gate), isFalse, reason: gate.name);
    }
  });

  test('out-of-order dynamic updates remain fail closed', () {
    final service = AgentCapabilityRolloutService(
      initial: const AgentCapabilityRollout(
        requestLazyHostActivation: true,
        requestPageSkillDefaults: true,
        requestPageAgentControl: true,
      ),
    );
    addTearDown(service.onClose);

    service.update(
      const AgentCapabilityRollout(
        requestPageSkillDefaults: true,
        requestPageAgentControl: true,
        requestPublicDrafts: true,
        requestPublicWrites: true,
      ),
    );

    for (final gate in AgentCapabilityGate.values) {
      expect(service.isEnabled(gate), isFalse, reason: gate.name);
    }
  });
}
