import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';

/// Lets the LLM tune its own proactive-feedback parameters at runtime in
/// response to what the user says.  Example use cases:
///
/// * "You're too chatty, talk less" → bump `faceProactiveCooldown` from 45 → 180
/// * "Why have you been ignoring me lately" → restore defaults via setDefaults()
///
/// Parameter names (all values are *seconds*):
///   • absentReactDelay      — wait this long before reacting to "they walked away"
///   • faceProactiveCooldown — min gap between two face-driven reactions
///   • sustainedMoodCooldown — re-emit a held expression after this long
///   • envProactiveCooldown  — min gap for non-face env cues (battery/etc)
class BehaviorSkill extends AgentSkill {
  BehaviorSkill({this.agentId});

  final String? agentId;

  AgentBehaviorConfig get _cfg => appServices.find<AgentBehaviorConfig>();

  @override
  String get skillName => 'BehaviorConfig';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Adjust proactive feedback behavior. When the owner explicitly says "don\'t bother me", '
      '"stop contacting me", or equivalent, call setProactiveHardMuted with muted=true; '
      'never pass muted=false because only the owner can resume proactive contact from '
      'My Agent > Agent Persona > Proactive companionship. '
      'Use threshold parameters only for softer requests such as "talk less" or "call me later". '
      'All threshold parameter values are in seconds.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'setBehaviorParam': _setParam,
    'getBehaviorParam': _getParam,
    'getAllBehaviorParams': _getAll,
    'setMultiStep': _setMultiStep,
    'setProactiveHardMuted': _setProactiveHardMuted,
    'resetBehaviorDefaults': _reset,
  };

  Future<String> _setProactiveHardMuted(List<dynamic> args) async {
    final muted = _strictBoolArgument(args, 'muted');
    if (muted == null) return '{"error":"invalid_muted"}';
    if (!muted) return '{"error":"resume_requires_user_control"}';
    final preferences = appServices.maybeFind<ProactivePreferenceService>();
    if (preferences == null || preferences.effectiveSnapshot.revision == 0) {
      return '{"error":"proactive_preferences_unavailable"}';
    }
    try {
      final wasMuted = preferences.effectiveSnapshot.hardMuted;
      final collector = appServices.maybeFind<OutreachFeedbackCollector>();
      await preferences.setHardMuted(true);
      final durable = preferences.effectiveSnapshot;
      if (!wasMuted && durable.hardMuted) {
        if (collector != null) {
          unawaited(
            collector.recordMuted(preferenceRevision: durable.revision),
          );
        }
      }
      return jsonEncode(<String, Object?>{
        'status': 'ok',
        'hardMuted': preferences.effectiveSnapshot.hardMuted,
      });
    } on Object {
      return '{"error":"proactive_preferences_unavailable"}';
    }
  }

  dynamic _setMultiStep(List<dynamic> args) {
    if (args.isEmpty) return '{"error":"missing_enabled"}';
    final v = args[0];
    final enabled = v is bool
        ? v
        : (v is num ? v != 0 : v.toString().toLowerCase() == 'true');
    _cfg.setMultiStep(enabled);
    return jsonEncode({'status': 'ok', 'multiStepEnabled': enabled});
  }

  dynamic _setParam(List<dynamic> args) {
    if (args.length < 2) {
      return '{"error":"missing_args"}';
    }
    final name = args[0].toString();
    final seconds = _asInt(args[1]);
    if (seconds == null) return '{"error":"invalid_seconds"}';
    final applied = _cfg.setParam(name, seconds);
    if (applied == null) {
      return jsonEncode({'error': 'unknown_parameter', 'name': name});
    }
    return jsonEncode({'status': 'ok', 'name': name, 'seconds': applied});
  }

  dynamic _getParam(List<dynamic> args) {
    if (args.isEmpty) return '{"error":"missing_name"}';
    final name = args[0].toString();
    final v = _cfg.getParam(name);
    if (v == null) {
      return jsonEncode({'error': 'unknown_parameter', 'name': name});
    }
    return jsonEncode({'name': name, 'seconds': v});
  }

  dynamic _getAll(List<dynamic> _) => jsonEncode(_cfg.snapshot());

  dynamic _reset(List<dynamic> _) {
    _cfg.setParam('absentReactDelay', 10);
    _cfg.setParam('faceProactiveCooldown', 45);
    _cfg.setParam('sustainedMoodCooldown', 120);
    _cfg.setParam('envProactiveCooldown', 240);
    return jsonEncode({'status': 'ok', 'reset': _cfg.snapshot()});
  }

  int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  bool? _strictBoolArgument(List<dynamic> args, String name) {
    if (args.isEmpty) return null;
    final first = args.first;
    if (first is bool) return first;
    if (first is Map) return first[name] is bool ? first[name] as bool : null;
    if (first is! String) return null;
    try {
      final decoded = jsonDecode(first);
      return decoded is Map && decoded[name] is bool
          ? decoded[name] as bool
          : null;
    } on FormatException {
      return null;
    }
  }
}
