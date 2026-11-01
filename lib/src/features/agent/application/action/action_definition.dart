import 'dart:async';

import 'agent_action_envelope.dart';

/// Coarse host-side risk classification for an agent-invocable action.
///
/// This metadata narrows an existing scope/grant. It never grants authority on
/// its own; callers must still enforce their route, turn, account, and runtime
/// generation boundaries before execution.
enum ActionRisk {
  readOnly,
  localMutation,
  externalWrite,
  physicalAction,
  destructive;

  bool get requiresApproval => switch (this) {
    ActionRisk.readOnly || ActionRisk.localMutation => false,
    ActionRisk.externalWrite ||
    ActionRisk.physicalAction ||
    ActionRisk.destructive => true,
  };
}

/// Describes how visible or reversible an action's consequence is.
enum ActionConsequencePolicy {
  reversible,
  prepareOnly,
  exactTextCommit,
  destructive;

  bool get requiresApproval => switch (this) {
    ActionConsequencePolicy.reversible ||
    ActionConsequencePolicy.prepareOnly => false,
    ActionConsequencePolicy.exactTextCommit ||
    ActionConsequencePolicy.destructive => true,
  };
}

typedef ActionHandler =
    FutureOr<Object?> Function(Map<String, dynamic> arguments);
typedef ActionTargetResolver = String? Function(Map<String, dynamic> arguments);

/// Immutable execution contract for one host-owned semantic action.
///
/// [inputSchema] and [outputSchema] use the bounded JSON Schema subset enforced
/// by `ActionSchemaValidator`. The registry and schema do not replace existing
/// grants; they make an already-authorized operation precise and auditable.
class ActionDefinition {
  ActionDefinition({
    required String id,
    required Map<String, dynamic> inputSchema,
    required this.handler,
    required Set<AgentActionScope> scopes,
    required this.risk,
    required this.consequencePolicy,
    Map<String, dynamic>? outputSchema,
    this.targetResolver,
  }) : id = id.trim(),
       inputSchema = Map<String, dynamic>.unmodifiable(inputSchema),
       outputSchema = outputSchema == null
           ? null
           : Map<String, dynamic>.unmodifiable(outputSchema),
       scopes = Set<AgentActionScope>.unmodifiable(scopes) {
    if (this.id.isEmpty ||
        this.id.length > 128 ||
        !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(this.id)) {
      throw ArgumentError.value(
        id,
        'id',
        'must use 1-128 ASCII identifier characters',
      );
    }
    if (this.scopes.isEmpty) {
      throw ArgumentError.value(scopes, 'scopes', 'must not be empty');
    }
  }

  final String id;
  final Map<String, dynamic> inputSchema;
  final Map<String, dynamic>? outputSchema;
  final Set<AgentActionScope> scopes;
  final ActionRisk risk;
  final ActionConsequencePolicy consequencePolicy;
  final ActionTargetResolver? targetResolver;
  final ActionHandler handler;

  bool get requiresApproval =>
      risk.requiresApproval || consequencePolicy.requiresApproval;

  bool allowsScope(AgentActionScope scope) => scopes.contains(scope);

  String? resolveTarget(Map<String, dynamic> arguments) {
    final target = targetResolver?.call(arguments)?.trim();
    return target == null || target.isEmpty ? null : target;
  }

  Future<Object?> execute(Map<String, dynamic> arguments) =>
      Future<Object?>.sync(() => handler(arguments));
}
