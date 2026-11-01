import 'dart:convert';

import 'package:maaso/src/core/security/action_schema_validator.dart';

const surfaceAgentProtocolProfile = 'maaso.agent.protocol.v2';
const surfaceAgentProtocolVersion = 2;
const surfacePlayRoles = ['player1', 'player2', 'spectator'];
const cooperativeDodgeConfig = <String, Object?>{
  'tickHz': 30,
  'roundTicks': 1800,
  'decisionWindowTicks': 150,
  'checkpointIntervalTicks': 30,
  'targetPerRole': 3,
  'teamLives': 6,
};

/// A content contract, never a permission grant or proof of runtime validation.
final class SurfacePlayProtocol {
  SurfacePlayProtocol._(Map<String, Object?> json)
    : _json = Map<String, Object?>.unmodifiable(json);
  final Map<String, Object?> _json;
  String get projectId => _json['projectId']! as String;
  String get revisionId => _json['revisionId']! as String;
  String get projectKind => _json['projectKind']! as String;
  List<String> get modes => List<String>.from(_json['modes']! as List);
  List<String> get roles => List<String>.from(_json['roles']! as List);
  bool get isTrustedGame => _json['play'] != null;
  bool get isRealtime => playObject(_json['capabilities'])['realtime'] == true;
  String? get rulesId =>
      isTrustedGame ? playObject(_json['play'])['rulesId']! as String : null;
  Map<String, Object?> get rulesConfig => isTrustedGame
      ? playObject(playObject(_json['play'])['rulesConfig'])
      : const {};
  List<Map<String, Object?>> get actions =>
      (_json['actions']! as List).map(playObject).toList(growable: false);
  List<String> get events => List<String>.from(_json['events']! as List);
  Map<String, Object?> toJson() => _json;

  factory SurfacePlayProtocol.fromJson(Map<String, Object?> raw) {
    final data = playObject(playSnapshot(raw, maximumBytes: 64 * 1024));
    playKeys(
      data,
      {
        'protocolVersion',
        'profile',
        'projectId',
        'revisionId',
        'projectKind',
        'modes',
        'roles',
        'actions',
        'events',
        'capabilities',
      },
      optional: {'play'},
    );
    if (data['protocolVersion'] is! int ||
        data['protocolVersion'] != 2 ||
        data['profile'] != surfaceAgentProtocolProfile ||
        !{'applet', 'game'}.contains(data['projectKind'])) {
      throw const FormatException('unsupported_agent_protocol');
    }
    playIdentifier(data['projectId']);
    playIdentifier(data['revisionId']);
    final modes = _strings(data['modes'], max: 4);
    final roles = _strings(data['roles'], max: 3);
    final events = _strings(data['events'], max: 32);
    if (roles.isEmpty ||
        !roles.every(surfacePlayRoles.contains) ||
        modes.isEmpty ||
        !modes.every(
          {'operate', 'versus', 'cooperative', 'spectate'}.contains,
        )) {
      throw const FormatException('invalid_agent_protocol_roles');
    }
    final capabilities = playObject(data['capabilities']);
    playKeys(capabilities, {'turnBased', 'realtime', 'checkpoint'});
    if (capabilities.values.any((v) => v is! bool)) {
      throw const FormatException('invalid_agent_protocol_capabilities');
    }
    final rawActions = data['actions'];
    if (rawActions is! List || rawActions.isEmpty || rawActions.length > 32) {
      throw const FormatException('invalid_agent_protocol_actions');
    }
    final actionIds = <String>{};
    for (final item in rawActions) {
      final action = playObject(item);
      playKeys(action, {'id', 'roles', 'argsSchema', 'precondition', 'effect'});
      final id = playIdentifier(action['id']);
      final allowedRoles = _strings(action['roles'], max: 3);
      if (!actionIds.add(id) ||
          allowedRoles.isEmpty ||
          !allowedRoles.every(roles.contains) ||
          !{'localGameState', 'localAppState'}.contains(action['effect'])) {
        throw const FormatException('invalid_agent_protocol_action');
      }
      playIdentifier(action['precondition']);
      final schema = playObject(action['argsSchema']);
      validateBoundedAgentSchema(schema);
    }
    if (data['projectKind'] == 'game') {
      final play = playObject(data['play']);
      playKeys(play, {'sdkVersion', 'rulesId', 'rulesConfig'});
      if (play['sdkVersion'] is! int || play['sdkVersion'] != 2) {
        throw const FormatException('unsupported_play_sdk');
      }
      final expected = SurfacePlayProtocol.trustedGame(
        projectId: data['projectId']! as String,
        revisionId: data['revisionId']! as String,
        rulesId: play['rulesId']! as String,
        config: playObject(play['rulesConfig']),
      );
      if (playCanonicalJson(data) != playCanonicalJson(expected.toJson())) {
        throw const FormatException('play_rules_contract_mismatch');
      }
    } else if (data['play'] != null ||
        modes.any((mode) => !{'operate', 'spectate'}.contains(mode)) ||
        capabilities['turnBased'] != false ||
        capabilities['realtime'] != false) {
      throw const FormatException('applet_cannot_claim_game_modes');
    }
    if (events.any(
      (event) => !RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,95}$').hasMatch(event),
    )) {
      throw const FormatException('invalid_agent_protocol_event');
    }
    return SurfacePlayProtocol._(data);
  }

  /// Produces the exact content contract of a host-registered ruleset. This does
  /// not issue control authority or a verification report.
  factory SurfacePlayProtocol.trustedGame({
    required String projectId,
    required String revisionId,
    required String rulesId,
    required Map<String, Object?> config,
  }) {
    playIdentifier(projectId);
    playIdentifier(revisionId);
    validateTrustedRulesConfig(rulesId, config);
    if (rulesId == 'cooperative-dodge.v1') {
      Map<String, Object?> action(
        String id,
        List<String> roles,
        Map<String, Object?> properties,
        String condition,
      ) => {
        'id': id,
        'roles': roles,
        'argsSchema': {
          'type': 'object',
          'properties': properties,
          'required': properties.keys.toList(),
          'additionalProperties': false,
        },
        'precondition': condition,
        'effect': 'localGameState',
      };
      return SurfacePlayProtocol._(
        playObject(
          playSnapshot({
            'protocolVersion': 2,
            'profile': surfaceAgentProtocolProfile,
            'projectId': projectId,
            'revisionId': revisionId,
            'projectKind': 'game',
            'modes': ['cooperative', 'spectate'],
            'roles': surfacePlayRoles,
            'play': {
              'sdkVersion': 2,
              'rulesId': rulesId,
              'rulesConfig': config,
            },
            'actions': [
              action('game.start', ['player1'], {}, 'playerOneAndReadyMatch'),
              action(
                'game.input',
                ['player1', 'player2'],
                {
                  'policy': {
                    'type': 'string',
                    'enum': ['left', 'right', 'idle', 'collect', 'dodge'],
                    'maxLength': 7,
                  },
                  'windowId': {
                    'type': 'string',
                    'minLength': 1,
                    'maxLength': 64,
                  },
                  'validThroughTick': _integerSchema(0, 1800),
                  'durationTicks': _integerSchema(1, 150),
                },
                'currentWindowAndActiveMatch',
              ),
            ],
            'events': [
              'game.started',
              'input.accepted',
              'decision.window_opened',
              'item.collected',
              'player.hit',
              'game.ended',
            ],
            'capabilities': {
              'turnBased': false,
              'realtime': true,
              'checkpoint': true,
            },
          }, maximumBytes: 64 * 1024),
        ),
      );
    }
    late String actionId;
    late Map<String, Object?> properties;
    late String precondition;
    late List<String> events;
    final cooperative = rulesId == 'cooperative-switches.v1';
    switch (rulesId) {
      case 'gomoku.v1':
        actionId = 'game.place';
        precondition = 'currentTurnAndEmptyCell';
        properties = {
          'x': _integerSchema(0, (config['boardSize']! as int) - 1),
          'y': _integerSchema(0, (config['boardSize']! as int) - 1),
        };
        events = ['move.accepted', 'turn.changed', 'game.ended'];
      case 'cooperative-switches.v1':
        actionId = 'game.toggle';
        precondition = 'ownedSwitchAndActiveMatch';
        properties = {
          'switch': _integerSchema(
            0,
            (config['switchesPerRole']! as int) * 2 - 1,
          ),
        };
        events = ['switch.toggled', 'game.ended'];
      case 'private-cards.v1':
        actionId = 'game.choose';
        precondition = 'ownUnselectedCard';
        properties = {
          'card': _integerSchema(0, (config['cardsPerRole']! as int) - 1),
        };
        events = ['card.selected', 'game.ended'];
      default:
        throw const FormatException('unregistered_play_rules');
    }
    return SurfacePlayProtocol._(
      playObject(
        playSnapshot({
          'protocolVersion': 2,
          'profile': surfaceAgentProtocolProfile,
          'projectId': projectId,
          'revisionId': revisionId,
          'projectKind': 'game',
          'modes': [cooperative ? 'cooperative' : 'versus', 'spectate'],
          'roles': surfacePlayRoles,
          'play': {'sdkVersion': 2, 'rulesId': rulesId, 'rulesConfig': config},
          'actions': [
            {
              'id': actionId,
              'roles': ['player1', 'player2'],
              'argsSchema': {
                'type': 'object',
                'properties': properties,
                'required': properties.keys.toList(),
                'additionalProperties': false,
              },
              'precondition': precondition,
              'effect': 'localGameState',
            },
          ],
          'events': events,
          'capabilities': {
            'turnBased': true,
            'realtime': false,
            'checkpoint': true,
          },
        }, maximumBytes: 64 * 1024),
      ),
    );
  }

  bool allowsAction(String seatId, String actionId, Object? args) {
    for (final action in actions) {
      if (action['id'] == actionId &&
          (action['roles']! as List).contains(seatId)) {
        return const ActionSchemaValidator(
          maxDepth: 12,
          maxNodes: 512,
        ).validate(schema: action['argsSchema'], value: args).isValid;
      }
    }
    return false;
  }
}

SurfacePlayProtocol validateAgentProtocol(
  Map<String, Object?> data, {
  required String projectId,
  required String revisionId,
}) {
  final protocol = SurfacePlayProtocol.fromJson(data);
  if (protocol.projectId != projectId || protocol.revisionId != revisionId) {
    throw const FormatException('agent_protocol_revision_mismatch');
  }
  return protocol;
}

void validateBoundedAgentSchema(Map<String, Object?> schema) {
  if (schema['type'] != 'object' ||
      !_boundedSchema(schema, 0) ||
      !const ActionSchemaValidator(
        maxDepth: 12,
        maxNodes: 512,
      ).validate(schema: schema, value: const {}).schemaValid) {
    throw const FormatException('unbounded_agent_action_schema');
  }
}

void validateTrustedRulesConfig(String id, Map<String, Object?> config) {
  switch (id) {
    case 'cooperative-dodge.v1':
      playKeys(config, cooperativeDodgeConfig.keys.toSet());
      for (final entry in cooperativeDodgeConfig.entries) {
        if (config[entry.key] is! int || config[entry.key] != entry.value) {
          throw const FormatException('unsupported_realtime_rules_config');
        }
      }
    case 'gomoku.v1':
      playKeys(config, {'boardSize', 'winLength'});
      final size = playInteger(config['boardSize'], min: 5, max: 15);
      playInteger(config['winLength'], min: 3, max: size < 5 ? size : 5);
    case 'cooperative-switches.v1':
      playKeys(config, {'switchesPerRole', 'goalMask'});
      final count = playInteger(config['switchesPerRole'], min: 2, max: 4);
      final goal = playInteger(
        config['goalMask'],
        min: 1,
        max: (1 << (count * 2)) - 1,
      );
      final seatMask = (1 << count) - 1;
      if (goal & seatMask == 0 || (goal >> count) & seatMask == 0) {
        throw const FormatException('cooperative_goal_requires_both_roles');
      }
    case 'private-cards.v1':
      playKeys(config, {'cardsPerRole'});
      if (config['cardsPerRole'] is! int || config['cardsPerRole'] != 3) {
        throw const FormatException('unsupported_private_card_count');
      }
    default:
      throw const FormatException('unregistered_play_rules');
  }
}

Map<String, Object?> _integerSchema(int min, int max) => {
  'type': 'integer',
  'minimum': min,
  'maximum': max,
};

bool _boundedSchema(Map<String, Object?> schema, int depth) {
  if (depth > 8) return false;
  bool keys(Set<String> required, [Set<String> optional = const {}]) =>
      required.every(schema.containsKey) &&
      schema.keys.every(
        (key) => required.contains(key) || optional.contains(key),
      );
  bool count(Object? value, int upper) =>
      value is int && value >= 0 && value <= upper;
  switch (schema['type']) {
    case 'object':
      if (!keys({'type', 'properties', 'required', 'additionalProperties'})) {
        return false;
      }
      final fields = schema['properties'], required = schema['required'];
      return schema['additionalProperties'] == false &&
          fields is Map &&
          fields.length <= 32 &&
          fields.keys.every((key) => key is String) &&
          required is List &&
          required.length <= 32 &&
          required.toSet().length == required.length &&
          required.every((key) => key is String && fields.containsKey(key)) &&
          fields.values.every(
            (value) =>
                value is Map && _boundedSchema(playObject(value), depth + 1),
          );
    case 'array':
      return keys({'type', 'items', 'maxItems'}, {'minItems'}) &&
          count(schema['maxItems'], 128) &&
          (!schema.containsKey('minItems') ||
              count(schema['minItems'], schema['maxItems']! as int)) &&
          schema['items'] is Map &&
          _boundedSchema(playObject(schema['items']), depth + 1);
    case 'string':
      if (!keys({'type'}, {'maxLength', 'minLength', 'enum'})) return false;
      if (schema.containsKey('maxLength') &&
          !count(schema['maxLength'], 2048)) {
        return false;
      }
      if (schema.containsKey('minLength') &&
          (!schema.containsKey('maxLength') ||
              !count(schema['minLength'], schema['maxLength']! as int))) {
        return false;
      }
      final values = schema['enum'];
      if (schema.containsKey('enum') &&
          (values is! List ||
              values.isEmpty ||
              values.length > 128 ||
              values.toSet().length != values.length ||
              values.any((v) => v is! String || v.runes.length > 2048))) {
        return false;
      }
      return schema.containsKey('maxLength') || schema.containsKey('enum');
    case 'integer':
    case 'number':
      final min = schema['minimum'], max = schema['maximum'];
      return keys({'type', 'minimum', 'maximum'}) &&
          min is num &&
          max is num &&
          min.isFinite &&
          max.isFinite &&
          min >= -1000000 &&
          max <= 1000000 &&
          min <= max;
    case 'boolean':
      return keys({'type'});
    default:
      return false;
  }
}

List<String> _strings(Object? value, {required int max}) {
  if (value is! List ||
      value.length > max ||
      value.any((item) => item is! String) ||
      value.toSet().length != value.length) {
    throw const FormatException('invalid_protocol_list');
  }
  return List<String>.from(value);
}

Map<String, Object?> playObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('invalid_play_object');
  }
  return Map<String, Object?>.from(value);
}

void playKeys(
  Map<String, Object?> data,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (!required.every(data.containsKey) ||
      data.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    throw const FormatException('invalid_play_fields');
  }
}

String playIdentifier(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$').hasMatch(value)) {
    throw const FormatException('invalid_play_identifier');
  }
  return value;
}

int playInteger(Object? value, {int min = 0, int max = 9007199254740991}) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('invalid_play_integer');
  }
  return value;
}

Object? playSnapshot(Object? value, {int maximumBytes = 32768}) {
  final encoded = jsonEncode(value);
  if (utf8.encode(encoded).length > maximumBytes) {
    throw const FormatException('play_payload_too_large');
  }
  Object? freeze(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.unmodifiable(
        value.map((key, v) => MapEntry(key! as String, freeze(v))),
      );
    }
    if (value is List) return List<Object?>.unmodifiable(value.map(freeze));
    return value;
  }

  return freeze(jsonDecode(encoded));
}

String playCanonicalJson(Object? value) {
  Object? order(Object? value) {
    if (value is Map) {
      final map = playObject(value);
      final keys = map.keys.toList()..sort();
      return {for (final key in keys) key: order(map[key])};
    }
    if (value is List) return value.map(order).toList(growable: false);
    return value;
  }

  return jsonEncode(order(value));
}
