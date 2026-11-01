import 'action_definition.dart';
import 'action_definition_registry.dart';
import 'agent_action_envelope.dart';

/// Model-callable channels recognized by the Action Contract V2 boundary.
enum ActionContractChannel {
  structured,
  nativeTool,
  localAgent,
  delayedTool,
  realtime,
  appControl,
  surface,
  synthetic,
}

/// Maximum enforcement level supported by one production definition.
///
/// `domainAuthorized` requires a concrete domain adapter. The same-account
/// DeviceHandoff adapter is limited to its bound skill methods in a self chat;
/// unrelated domain actions remain unavailable through the generic callback.
enum ActionEnforcementEligibility {
  readOnly,
  reversibleLocal,
  domainAuthorized,
  unsupported,
}

/// Production rollout metadata layered over an existing [ActionDefinition].
///
/// The definition's handler is never called by this catalog or by the V2
/// service. It remains compatibility metadata until existing call sites are
/// individually wired through the legacy adapter.
final class ProductionActionDefinition {
  ProductionActionDefinition({
    required this.definition,
    required Set<ActionContractChannel> channels,
    required this.enforcementEligibility,
  }) : channels = Set<ActionContractChannel>.unmodifiable(channels) {
    if (this.channels.isEmpty) {
      throw ArgumentError.value(channels, 'channels', 'must not be empty');
    }
  }

  final ActionDefinition definition;
  final Set<ActionContractChannel> channels;
  final ActionEnforcementEligibility enforcementEligibility;

  bool allowsChannel(ActionContractChannel channel) =>
      channels.contains(channel);
}

/// Registration-order production catalog for V2 contract metadata.
final class ProductionActionDefinitionCatalog {
  ProductionActionDefinitionCatalog();

  factory ProductionActionDefinitionCatalog.intrinsics() {
    final catalog = ProductionActionDefinitionCatalog();
    catalog.register(
      ProductionActionDefinition(
        definition: ActionDefinition(
          id: 'voice.fallback',
          inputSchema: const <String, dynamic>{
            'type': 'object',
            'properties': <String, Object?>{
              'text': <String, Object?>{
                'type': 'string',
                'minLength': 1,
                'maxLength': 16384,
              },
            },
            'required': <String>['text'],
            'additionalProperties': false,
          },
          outputSchema: _emptyObjectSchema,
          scopes: const <AgentActionScope>{
            AgentActionScope.chat,
            AgentActionScope.proactivePresence,
            AgentActionScope.notificationInteraction,
          },
          risk: ActionRisk.localMutation,
          consequencePolicy: ActionConsequencePolicy.reversible,
          targetResolver: (_) => 'voice:presentation',
          handler: _definitionHandlerMustNotRun,
        ),
        channels: const <ActionContractChannel>{
          ActionContractChannel.synthetic,
        },
        enforcementEligibility: ActionEnforcementEligibility.reversibleLocal,
      ),
    );
    catalog.register(
      ProductionActionDefinition(
        definition: ActionDefinition(
          id: 'avatar.auto_react',
          inputSchema: const <String, dynamic>{
            'type': 'object',
            'additionalProperties': true,
          },
          outputSchema: _emptyObjectSchema,
          scopes: const <AgentActionScope>{AgentActionScope.chat},
          risk: ActionRisk.localMutation,
          consequencePolicy: ActionConsequencePolicy.reversible,
          targetResolver: (_) => 'avatar:presentation',
          handler: _definitionHandlerMustNotRun,
        ),
        channels: const <ActionContractChannel>{
          ActionContractChannel.synthetic,
        },
        enforcementEligibility: ActionEnforcementEligibility.reversibleLocal,
      ),
    );
    return catalog;
  }

  final ActionDefinitionRegistry _registry = ActionDefinitionRegistry();
  final Map<String, ProductionActionDefinition> _production =
      <String, ProductionActionDefinition>{};
  final Set<String> _conflictedIds = <String>{};
  int _revision = 0;

  int get revision => _revision;

  List<ProductionActionDefinition> get definitions =>
      List<ProductionActionDefinition>.unmodifiable(_production.values);

  ProductionActionDefinition? find(String id) => _production[id.trim()];

  /// Enforcement lookup that fails closed after any identity collision.
  ProductionActionDefinition? findExact(String id) {
    final normalized = id.trim();
    return _conflictedIds.contains(normalized) ? null : _production[normalized];
  }

  bool isConflicted(String id) => _conflictedIds.contains(id.trim());

  /// Permanently marks an action id ambiguous for this account-owned catalog.
  ///
  /// There is deliberately no clear API: a later registration cannot prove
  /// that an earlier sanitized-name collision disappeared from every channel.
  void markConflict(String id) {
    final normalized = _validatedActionId(id);
    if (_conflictedIds.add(normalized)) _revision += 1;
  }

  void register(ProductionActionDefinition productionDefinition) {
    final definition = productionDefinition.definition;
    final existing = _production[definition.id];
    if (existing != null) {
      if (!identical(existing, productionDefinition)) {
        markConflict(definition.id);
      }
      throw StateError('Duplicate action definition: ${definition.id}');
    }
    _registry.register(definition);
    _production[definition.id] = productionDefinition;
    _revision += 1;
  }
}

String _validatedActionId(String raw) {
  final id = raw.trim();
  if (id.isEmpty ||
      id.length > 128 ||
      !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(id)) {
    throw ArgumentError.value(
      raw,
      'id',
      'must use 1-128 ASCII identifier characters',
    );
  }
  return id;
}

const Map<String, dynamic> _emptyObjectSchema = <String, dynamic>{
  'type': 'object',
  'properties': <String, Object?>{},
  'additionalProperties': false,
};

Object? _definitionHandlerMustNotRun(Map<String, dynamic> _) =>
    throw StateError('action_definition_handler_is_metadata_only');
