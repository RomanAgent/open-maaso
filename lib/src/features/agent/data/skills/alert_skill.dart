import 'dart:convert';

import '../events/event_bus.dart';
import 'agent_skill.dart';

/// 🚨 Self-driven UI hijack — lets the AI break out of the normal chat
/// flow and force a high-priority popup onto the user's screen.  Use for
/// genuinely time-sensitive moments only (stock alert, schedule reminder
/// about to lapse, security event) — not for daily small talk.
///
/// Fires an [AlertEvent] into the EventBus; the host app must register a
/// listener (e.g. AlertOverlayService) that renders the actual UI.
class AlertSkill extends AgentSkill {
  AlertSkill({this.agentId});

  final String? agentId;

  @override
  String get skillName => 'AlertUser';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      '🚨 When something is genuinely urgent or important (a watched stock '
      'suddenly plunges, a schedule is about to lapse, an abnormal signal is '
      'detected), you may break out of the normal "chat bubble" flow and force '
      'a high-priority alert card to take over the screen. '
      'Use this very sparingly — never for daily chat / ordinary info.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'alertUser': _alertUser,
  };

  dynamic _alertUser(List<dynamic> args) {
    if (args.isEmpty) return '{"error":"missing_args"}';
    try {
      final raw = args[0];
      final json = raw is String ? jsonDecode(raw) : raw;
      if (json is! Map) return '{"error":"expected_object"}';
      final m = Map<String, Object?>.from(json);

      final title = m['title']?.toString();
      if (title == null || title.isEmpty) {
        return '{"error":"missing_title"}';
      }
      final level = (m['level']?.toString() ?? 'info').toLowerCase();
      final allowedLevels = {'info', 'warning', 'urgent'};
      if (!allowedLevels.contains(level)) {
        return '{"error":"invalid_level"}';
      }

      EventBus().fire(
        AlertEvent(
          title: title,
          message: m['message']?.toString(),
          level: level,
          color: m['color']?.toString(),
          durationMs: (m['durationMs'] as num?)?.toInt() ?? 4000,
          flash: m['flash'] as bool? ?? (level == 'urgent'),
          haptic:
              m['haptic']?.toString() ??
              (level == 'urgent'
                  ? 'heavy'
                  : level == 'warning'
                  ? 'medium'
                  : 'light'),
          agentId: agentId,
        ),
      );

      return '{"status":"ok"}';
    } catch (_) {
      return '{"error":"invalid_alert_spec"}';
    }
  }
}
