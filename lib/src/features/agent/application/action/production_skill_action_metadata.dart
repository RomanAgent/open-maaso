import 'package:maaso/src/features/agent/application/skills/device_handoff_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/agent/application/skills/avatar_camera_skill.dart';

import 'action_definition.dart';
import 'production_action_definition_catalog.dart';

/// Explicit, source-reviewed allowlist for production Skill methods.
///
/// Everything absent from this table remains `unsupported` in enforce mode.
/// Method names are never interpreted heuristically: adding a new entry
/// requires source review of the concrete handler and its dependencies.
SkillActionContractMetadata? productionSkillActionContractMetadata(
  AgentSkill skill,
  String method,
  Map<String, dynamic> inputSchema,
) => switch ((skill.skillName, method)) {
  ('AppNavigate', 'listPages') => const SkillActionContractMetadata.readOnly(
    outputSchema: _appNavigateListPagesOutputSchema,
  ),
  ('AppControl', 'listCapabilities') =>
    const SkillActionContractMetadata.readOnly(
      outputSchema: _appControlListCapabilitiesOutputSchema,
    ),
  ('DeviceHandoff', 'listDevices') when skill is DeviceHandoffSkill =>
    const SkillActionContractMetadata.readOnly(
      outputSchema: _deviceHandoffListOutputSchema,
    ),
  ('AvatarCamera', 'setFraming') when skill is AvatarCameraSkill =>
    const SkillActionContractMetadata(
      risk: ActionRisk.localMutation,
      consequencePolicy: ActionConsequencePolicy.reversible,
      enforcementEligibility: ActionEnforcementEligibility.reversibleLocal,
      outputSchema: _avatarCameraSetFramingOutputSchema,
    ),
  _ => null,
};

const Map<String, dynamic> _avatarCameraSetFramingOutputSchema = {
  'type': 'object',
  'properties': {
    'ok': {'type': 'boolean', 'const': true},
    'mode': {
      'type': 'string',
      'enum': ['face', 'bust', 'full', 'auto'],
    },
    'framing': {
      'type': 'string',
      'enum': ['head', 'upper_body', 'hero_full_body'],
    },
    'automatic': {'type': 'boolean'},
    'idleTimeoutSeconds': {'type': 'integer', 'const': 45},
  },
  'required': ['ok', 'mode', 'framing', 'automatic', 'idleTimeoutSeconds'],
  'additionalProperties': false,
};

const Map<String, dynamic> _appNavigateListPagesOutputSchema =
    <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'pages': <String, dynamic>{
          'type': 'array',
          'maxItems': 128,
          'items': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'id': <String, dynamic>{
                'type': 'string',
                'minLength': 1,
                'maxLength': 128,
              },
              'title': <String, dynamic>{
                'type': 'string',
                'minLength': 1,
                'maxLength': 256,
              },
            },
            'required': <String>['id', 'title'],
            'additionalProperties': false,
          },
        },
      },
      'required': <String>['pages'],
      'additionalProperties': false,
    };

const Map<String, dynamic> _appControlListCapabilitiesOutputSchema =
    <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'pages': <String, dynamic>{
          'type': 'array',
          'maxItems': 128,
          'items': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'id': <String, dynamic>{
                'type': 'string',
                'minLength': 1,
                'maxLength': 128,
              },
              'route': <String, dynamic>{
                'type': 'string',
                'minLength': 1,
                'maxLength': 1024,
              },
              'variants': <String, dynamic>{
                'type': 'array',
                'maxItems': 32,
                'items': <String, dynamic>{
                  'type': 'object',
                  'properties': <String, dynamic>{
                    'id': <String, dynamic>{
                      'type': 'string',
                      'minLength': 1,
                      'maxLength': 128,
                    },
                    'route': <String, dynamic>{
                      'type': 'string',
                      'minLength': 1,
                      'maxLength': 1024,
                    },
                  },
                  'required': <String>['id', 'route'],
                  'additionalProperties': false,
                },
              },
            },
            'required': <String>['id', 'route', 'variants'],
            'additionalProperties': false,
          },
        },
        'pageActionProtocol': <String, dynamic>{
          'type': 'string',
          'minLength': 1,
          'maxLength': 512,
        },
      },
      'required': <String>['pages', 'pageActionProtocol'],
      'additionalProperties': false,
    };

const _deviceHandoffListOutputSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'ok': {'type': 'boolean', 'const': true},
    'deviceCount': {'type': 'integer', 'minimum': 0},
    'truncated': {'type': 'boolean'},
    'targets': {
      'type': 'array',
      'maxItems': 100,
      'items': {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'minLength': 8,
            'maxLength': 64,
            'pattern': r'^[A-Za-z0-9._:-]+$',
          },
          'label': {'type': 'string', 'minLength': 1, 'maxLength': 80},
          'platform': {
            'type': 'string',
            'enum': [
              'macos',
              'windows',
              'ios',
              'android',
              'linux',
              'web',
              'unknown',
            ],
          },
        },
        'required': ['id', 'label', 'platform'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['ok', 'deviceCount', 'truncated', 'targets'],
  'additionalProperties': false,
};
