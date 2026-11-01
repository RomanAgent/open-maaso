import 'dart:convert';

import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';

import 'agent_skill.dart';

/// Face / mood control skill.
///
/// `setEmotion(json)` supports semantic labels with intensity and an optional
/// secondary emotion. The renderer interpolates continuous emotion parameters.
class FaceSkill extends AgentSkill {
  FaceSkill({this.agentId});

  /// Which agent's face. null = global/default.
  final String? agentId;

  @override
  String get skillName => 'FaceControl';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Finely control your own expression with a set of continuous emotion '
      'parameters. Pick any one semantic label from happy/sad/angry/'
      'surprised/shy/thinking/sleeping/love/wink/bored/excited/confused/'
      'fear/calm + an intensity, or pass low-level params directly (eye '
      'open/close, brow angle, mouth curve, cheek flush, body hue, tremor, '
      'etc.). You can layer a secondary emotion to get composites like '
      '"a bit happy but also a little confused".';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'setEmotion': _setEmotion,
  };

  // ————— new continuous emotion path —————

  dynamic _setEmotion(List<dynamic> args) {
    if (args.isEmpty) return '{"error":"missing_args"}';
    try {
      // AI sometimes passes a JSON string ('{"emotion":"happy"}'), other
      // times a JS object literal — accept both.
      final raw = args[0];
      dynamic json;
      if (raw is String) {
        json = jsonDecode(raw);
      } else if (raw is Map) {
        json = raw;
      } else {
        json = jsonDecode(raw.toString());
      }
      final params = EmotionParams.fromJson(json);
      final label = (json is Map) ? json['emotion']?.toString() : null;
      EventBus().fire(
        EmotionStateEvent(
          params,
          semanticLabel: label,
          duration:
              json is Map &&
                  json['durationMs'] is num &&
                  (json['durationMs'] as num).isFinite &&
                  (json['durationMs'] as num) > 0
              ? Duration(
                  milliseconds: (json['durationMs'] as num)
                      .clamp(1, 30000)
                      .round(),
                )
              : null,
          persistent: json is Map && json['persistent'] == true,
          agentId: agentId,
        ),
      );
      return '{"status":"success"}';
    } catch (_) {
      return '{"error":"invalid_json"}';
    }
  }
}
