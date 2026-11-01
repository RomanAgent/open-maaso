import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/action_definition_registry.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';

void main() {
  test('explicit registration rejects ambiguous action ids', () {
    final registry = ActionDefinitionRegistry();
    final first = _definition('skill.demo.run');

    registry.register(first);

    expect(registry.require(first.id), same(first));
    expect(
      () => registry.register(_definition(first.id)),
      throwsA(isA<StateError>()),
    );
  });

  test('compatibility registration preserves first-match semantics', () {
    final registry = ActionDefinitionRegistry();
    final first = _definition('skill.demo.run');
    final second = _definition('skill.demo.run');

    expect(registry.registerIfAbsent(first), isTrue);
    expect(registry.registerIfAbsent(second), isFalse);
    expect(registry.find(first.id), same(first));
    expect(registry.definitions, <ActionDefinition>[first]);
  });

  test('registration snapshots are immutable by generation', () {
    final registry = ActionDefinitionRegistry();
    final first = _definition('one');
    final second = _definition('two');
    registry.register(first);
    final initial = registry.definitions;

    expect(() => initial.add(second), throwsUnsupportedError);
    registry.register(second);

    expect(initial, <ActionDefinition>[first]);
    expect(registry.definitions, <ActionDefinition>[first, second]);
  });

  test('risk and consequence policies require approval monotonically', () {
    expect(_definition('read').requiresApproval, isFalse);
    expect(
      _definition('external', risk: ActionRisk.externalWrite).requiresApproval,
      isTrue,
    );
    expect(
      _definition(
        'commit',
        consequence: ActionConsequencePolicy.exactTextCommit,
      ).requiresApproval,
      isTrue,
    );
  });

  test('invalid identifiers fail closed', () {
    final registry = ActionDefinitionRegistry();

    expect(
      () => registry.register(_definition('  ')),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => registry.register(_definition('contains spaces')),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('definition snapshots top-level schemas and scopes', () {
    final input = <String, dynamic>{'type': 'object'};
    final scopes = <AgentActionScope>{AgentActionScope.chat};
    final definition = ActionDefinition(
      id: 'snapshot',
      inputSchema: input,
      scopes: scopes,
      risk: ActionRisk.readOnly,
      consequencePolicy: ActionConsequencePolicy.reversible,
      handler: (arguments) => arguments,
    );

    input['type'] = 'array';
    scopes.clear();

    expect(definition.inputSchema['type'], 'object');
    expect(definition.scopes, <AgentActionScope>{AgentActionScope.chat});
    expect(
      () => definition.inputSchema['type'] = 'string',
      throwsUnsupportedError,
    );
    expect(() => definition.scopes.clear(), throwsUnsupportedError);
  });
}

ActionDefinition _definition(
  String id, {
  ActionRisk risk = ActionRisk.readOnly,
  ActionConsequencePolicy consequence = ActionConsequencePolicy.reversible,
}) => ActionDefinition(
  id: id,
  inputSchema: const <String, dynamic>{'type': 'object'},
  scopes: const <AgentActionScope>{AgentActionScope.chat},
  risk: risk,
  consequencePolicy: consequence,
  handler: (arguments) => arguments,
);
