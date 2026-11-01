import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_camera_director.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';

/// Semantic camera requests for the owner's visible companion.
/// Ownership, automatic framing, and explicit-request expiry stay in the host
/// director; this skill never issues renderer or physical-camera commands.
final class AvatarCameraSkill extends AgentSkill {
  AvatarCameraSkill({this.agentId = 'self', AvatarCameraDirector? director})
    : _director = director;

  final String agentId;
  final AvatarCameraDirector? _director;

  static const modes = <String>['face', 'bust', 'full', 'auto'];
  static const argumentsSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'mode': {
        'type': 'string',
        'enum': modes,
        'description':
            'face: face close-up; bust: upper body; full: full body; '
            'auto: resume automatic conversation framing.',
      },
    },
    'required': ['mode'],
    'additionalProperties': false,
  };

  @override
  String get skillName => 'AvatarCamera';

  @override
  String get description =>
      'Frame your own visible avatar when the owner asks to see your face, '
      'upper body, or full body, or asks for automatic framing. Explicit '
      'framing remains until 45 seconds without interaction or an auto request. '
      'The host handles speaking and idle framing; do not call this every turn. '
      'This does not access the device camera or record media.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'setFraming': _setFraming,
  };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => const {
    'setFraming': argumentsSchema,
  };

  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'setFraming':
        'Apply the requested semantic avatar shot, or return to automatic '
        'framing. Use only when the owner asks to change the shot.',
  };

  Future<String> _setFraming(List<dynamic> args) async {
    if (agentId != 'self') return _error('camera_self_only');
    if (args.length != 1) return _error('invalid_arguments');
    final Object? payload;
    try {
      payload = args.single is String
          ? jsonDecode(args.single as String)
          : args.single;
    } on FormatException {
      return _error('invalid_arguments');
    }
    if (payload is! Map ||
        payload.length != 1 ||
        !payload.containsKey('mode') ||
        payload['mode'] is! String ||
        !modes.contains(payload['mode'])) {
      return _error('invalid_arguments');
    }

    final director = _director ?? appServices.maybeFind<AvatarCameraDirector>();
    if (director == null) return _error('camera_unavailable');
    try {
      return jsonEncode(
        await director.setFraming(payload['mode'] as String, agentId: agentId),
      );
    } on Object {
      return _error('camera_failed');
    }
  }

  static String _error(String code) => jsonEncode({'ok': false, 'error': code});
}
