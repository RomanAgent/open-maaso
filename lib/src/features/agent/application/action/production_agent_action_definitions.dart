import 'action_definition.dart';
import 'agent_action_envelope.dart';
import 'production_action_definition_catalog.dart';

/// Registers the host-owned metadata for the fixed structured action types.
///
/// These definitions never execute effects. Existing owners remain behind the
/// legacy callback, while Action Contract V2 uses this catalog only to freeze
/// schema, scope, channel, target, and risk before that callback can run.
void registerProductionAgentActionDefinitions(
  ProductionActionDefinitionCatalog catalog,
) {
  for (final definition in _fixedAgentActionDefinitions) {
    catalog.register(definition);
  }
}

final List<ProductionActionDefinition> _fixedAgentActionDefinitions =
    <ProductionActionDefinition>[
      _definition(
        id: 'creation.intent',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'mode': <String, Object?>{
              'type': 'string',
              'enum': <String>[
                'none',
                'create',
                'propose',
                'confirm',
                'edit',
                'cancel',
                'retry',
                'status',
              ],
            },
            'kind': <String, Object?>{
              'type': 'string',
              'enum': <String>['game', 'utility'],
            },
            'requirements': <String, Object?>{'type': 'string'},
            'proposalId': <String, Object?>{'type': 'string'},
            'projectId': <String, Object?>{'type': 'string'},
            'taskId': <String, Object?>{'type': 'string'},
          },
          'required': <String>['mode'],
          'additionalProperties': false,
        },
        scopes: const <AgentActionScope>{AgentActionScope.chat},
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
        target: 'creation:intent',
        eligibility: ActionEnforcementEligibility.reversibleLocal,
        channels: const <ActionContractChannel>{
          ActionContractChannel.structured,
        },
      ),
      _definition(
        id: 'emotion.set',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'emotion': _boundedText,
            'label': _boundedText,
            'intensity': <String, Object?>{
              'type': 'number',
              'minimum': 0,
              'maximum': 1,
            },
            'params': <String, Object?>{'type': 'object'},
            'durationMs': <String, Object?>{
              'type': 'integer',
              'minimum': 1,
              'maximum': 30000,
            },
            'persistent': <String, Object?>{'type': 'boolean'},
          },
          'additionalProperties': false,
        },
        scopes: const <AgentActionScope>{
          AgentActionScope.chat,
          AgentActionScope.proactivePresence,
          AgentActionScope.notificationInteraction,
        },
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
        target: 'avatar:emotion',
        eligibility: ActionEnforcementEligibility.reversibleLocal,
      ),
      _definition(
        id: 'voice.speak',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{'text': _spokenText},
          'required': <String>['text'],
          'additionalProperties': false,
        },
        scopes: const <AgentActionScope>{
          AgentActionScope.chat,
          AgentActionScope.notificationInteraction,
        },
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
        target: 'voice:presentation',
        eligibility: ActionEnforcementEligibility.reversibleLocal,
      ),
      _definition(
        id: 'surface.show',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'surface': <String, Object?>{'type': 'object'},
            'catalogSummary': <String, Object?>{
              'type': 'string',
              'maxLength': 16384,
            },
          },
          'required': <String>['surface'],
          'additionalProperties': false,
        },
        scopes: const <AgentActionScope>{AgentActionScope.chat},
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.prepareOnly,
        target: 'surface:presentation',
        eligibility: ActionEnforcementEligibility.domainAuthorized,
        channels: const <ActionContractChannel>{
          ActionContractChannel.surface,
          ActionContractChannel.realtime,
        },
      ),
      _definition(
        id: 'surface.call',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'action': _boundedIdentifier,
            'data': <String, Object?>{},
          },
          'required': <String>['action'],
          'additionalProperties': false,
        },
        scopes: const <AgentActionScope>{AgentActionScope.chat},
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
        target: 'surface:active',
        eligibility: ActionEnforcementEligibility.domainAuthorized,
        channels: const <ActionContractChannel>{
          ActionContractChannel.surface,
          ActionContractChannel.realtime,
        },
      ),
      _definition(
        id: 'avatar.motion',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'additionalProperties': true,
        },
        scopes: const <AgentActionScope>{AgentActionScope.chat},
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
        target: 'avatar:motion',
        eligibility: ActionEnforcementEligibility.reversibleLocal,
      ),
      _definition(
        id: 'avatar.act',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'additionalProperties': true,
        },
        scopes: const <AgentActionScope>{
          AgentActionScope.chat,
          AgentActionScope.proactivePresence,
        },
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
        target: 'avatar:behavior',
        eligibility: ActionEnforcementEligibility.reversibleLocal,
      ),
      _definition(
        id: 'avatar.react',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'additionalProperties': true,
        },
        scopes: const <AgentActionScope>{
          AgentActionScope.chat,
          AgentActionScope.proactivePresence,
        },
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
        target: 'avatar:behavior',
        eligibility: ActionEnforcementEligibility.reversibleLocal,
      ),
    ];

ProductionActionDefinition _definition({
  required String id,
  required Map<String, Object?> inputSchema,
  required Set<AgentActionScope> scopes,
  required ActionRisk risk,
  required ActionConsequencePolicy consequencePolicy,
  required String target,
  required ActionEnforcementEligibility eligibility,
  Set<ActionContractChannel> channels = const <ActionContractChannel>{
    ActionContractChannel.structured,
    ActionContractChannel.realtime,
  },
}) => ProductionActionDefinition(
  definition: ActionDefinition(
    id: id,
    inputSchema: Map<String, dynamic>.from(inputSchema),
    outputSchema: const <String, dynamic>{},
    scopes: scopes,
    risk: risk,
    consequencePolicy: consequencePolicy,
    targetResolver: (_) => target,
    handler: _metadataOnly,
  ),
  channels: channels,
  enforcementEligibility: eligibility,
);

const Map<String, Object?> _boundedText = <String, Object?>{
  'type': 'string',
  'minLength': 1,
  'maxLength': 256,
};

const Map<String, Object?> _spokenText = <String, Object?>{
  'type': 'string',
  'minLength': 1,
  'maxLength': 16384,
};

const Map<String, Object?> _boundedIdentifier = <String, Object?>{
  'type': 'string',
  'minLength': 1,
  'maxLength': 128,
  'pattern': r'^[a-zA-Z0-9._:-]+$',
};

Object? _metadataOnly(Map<String, dynamic> _) =>
    throw StateError('production_action_definition_is_metadata_only');
