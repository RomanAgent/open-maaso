import 'dart:convert';

import 'content_engagement.dart';

/// Public WebView messages are hints only. The immutable host target decides
/// which event is permitted; actor, source, units, and approval are never inputs.
class PublicConsumptionHint {
  const PublicConsumptionHint._(this.progress, this.operation);
  final int? progress;
  final bool operation;

  static PublicConsumptionHint? parse(
    String message,
    ContentConsumptionKind kind,
  ) {
    if (message.length > 256) return null;
    try {
      final value = jsonDecode(message);
      if (value is! Map<String, dynamic>) return null;
      if (kind == ContentConsumptionKind.game &&
          value.length == 2 &&
          value['event'] == 'game_progress' &&
          value['progress'] is int) {
        final progress = value['progress'] as int;
        if (progress >= 0 && progress <= 10000) {
          return PublicConsumptionHint._(progress, false);
        }
      }
      if (kind == ContentConsumptionKind.applet &&
          value.length == 1 &&
          value['event'] == 'applet_operation') {
        return const PublicConsumptionHint._(null, true);
      }
    } catch (_) {
      // Invalid, unknown and oversized messages confer no activity.
    }
    return null;
  }
}
