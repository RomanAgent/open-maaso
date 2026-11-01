import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout.dart';

void main() {
  test('safe defaults fail closed for every capability', () {
    const rollout = AgentCapabilityRollout.safeDefaults;

    for (final gate in AgentCapabilityGate.values) {
      expect(rollout.isEnabled(gate), isFalse, reason: gate.name);
    }
    expect(rollout.publicWritesEnabled, isFalse);
  });

  test('out-of-order requested gates cannot bypass prerequisites', () {
    const rollout = AgentCapabilityRollout(
      requestPageSkillDefaults: true,
      requestPageAgentControl: true,
      requestPublicDrafts: true,
      requestPublicWrites: true,
    );

    for (final gate in AgentCapabilityGate.values) {
      expect(rollout.isEnabled(gate), isFalse, reason: gate.name);
    }
  });

  test('staged rollout stops before public writes by default', () {
    const rollout = AgentCapabilityRollout(
      requestLazyHostActivation: true,
      requestPageSkillDefaults: true,
      requestPageAgentControl: true,
      requestPublicDrafts: true,
    );

    expect(rollout.lazyHostActivationEnabled, isTrue);
    expect(rollout.pageSkillDefaultsEnabled, isTrue);
    expect(rollout.pageAgentControlEnabled, isTrue);
    expect(rollout.publicDraftsEnabled, isTrue);
    expect(rollout.publicWritesEnabled, isFalse);
  });

  test('public writes require an explicit complete capability chain', () {
    const rollout = AgentCapabilityRollout(
      requestLazyHostActivation: true,
      requestPageSkillDefaults: true,
      requestPageAgentControl: true,
      requestPublicDrafts: true,
      requestPublicWrites: true,
    );

    expect(rollout.publicWritesEnabled, isTrue);
  });

  test('diagnostic export has fixed neutral dimensions', () {
    final export = AgentCapabilityRollout.lazyActivationOnly.toJson();
    final requested = export['requested']! as Map<String, bool>;
    final effective = export['effective']! as Map<String, bool>;

    expect(requested, hasLength(AgentCapabilityGate.values.length));
    expect(effective, hasLength(AgentCapabilityGate.values.length));
    expect(
      requested.keys,
      unorderedEquals(AgentCapabilityGate.values.map((gate) => gate.name)),
    );
    final encoded = jsonEncode(export);
    for (final forbidden in <String>[
      'account',
      'user',
      'locale',
      'language',
      'cohort',
      'experiment',
    ]) {
      expect(encoded, isNot(contains(forbidden)));
    }
  });
}
