import 'dart:convert';

enum MaasoNotificationKind {
  scheduledTask('scheduled_task'),
  morningGreeting('morning_greeting'),
  middayGreeting('midday_greeting'),
  eveningGreeting('evening_greeting'),
  randomCheckIn('random_check_in'),
  remote('remote');

  const MaasoNotificationKind(this.key);

  final String key;

  static MaasoNotificationKind fromKey(String? key) {
    for (final value in values) {
      if (value.key == key) return value;
    }
    return MaasoNotificationKind.remote;
  }
}

class MaasoNotification {
  const MaasoNotification({
    required this.deliveryId,
    required this.kind,
    required this.title,
    required this.body,
    this.prompt,
    this.data = const <String, Object?>{},
  });

  final String deliveryId;
  final MaasoNotificationKind kind;
  final String title;
  final String body;
  final String? prompt;
  final Map<String, Object?> data;

  String toPayload() {
    final normalizedPrompt = prompt?.trim();
    return jsonEncode(<String, Object?>{
      ...data,
      'deliveryId': deliveryId,
      'kind': kind.key,
      'prompt': normalizedPrompt?.isNotEmpty == true ? normalizedPrompt : null,
    });
  }
}

class NotificationInteraction {
  const NotificationInteraction({
    required this.deliveryId,
    required this.kind,
    this.prompt,
    this.data = const <String, Object?>{},
  });

  final String deliveryId;
  final MaasoNotificationKind kind;
  final String? prompt;
  final Map<String, Object?> data;

  static NotificationInteraction? fromPayload(String? payload) {
    if (payload == null || payload.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final data = decoded.cast<String, Object?>();
      final deliveryId = data['deliveryId']?.toString().trim() ?? '';
      if (deliveryId.isEmpty) return null;
      final prompt = data['prompt']?.toString().trim();
      return NotificationInteraction(
        deliveryId: deliveryId,
        kind: MaasoNotificationKind.fromKey(data['kind']?.toString()),
        prompt: prompt == null || prompt.isEmpty ? null : prompt,
        data: data,
      );
    } catch (_) {
      return null;
    }
  }
}
