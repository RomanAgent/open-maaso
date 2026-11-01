import 'notification_models.dart';
import 'notification_preferences_service.dart';

class NotificationPolicyLedger {
  const NotificationPolicyLedger({
    this.deliveredKeys = const <String>{},
    this.deliveredAt = const <DateTime>[],
    this.lastRandomAt,
  });

  final Set<String> deliveredKeys;
  final List<DateTime> deliveredAt;
  final DateTime? lastRandomAt;

  int deliveredOn(DateTime day) => deliveredAt.where((item) {
    final local = item.toLocal();
    return local.year == day.year &&
        local.month == day.month &&
        local.day == day.day;
  }).length;

  DateTime? get lastDeliveredAt => deliveredAt.isEmpty
      ? null
      : deliveredAt.reduce((a, b) => a.isAfter(b) ? a : b);
}

class NotificationPolicyDecision {
  const NotificationPolicyDecision({
    required this.dedupKey,
    required this.notification,
  });

  final String dedupKey;
  final MaasoNotification notification;
}

/// Pure policy for foreground companion outreach.
///
/// OS permission, persistence and delivery are kept outside this class so the
/// consent, quiet-hour, budget and de-duplication rules can be tested without
/// platform channels.
class NotificationPolicy {
  const NotificationPolicy({this.randomThreshold = 0.05});

  final double randomThreshold;

  NotificationPolicyDecision? evaluate({
    required DateTime now,
    required NotificationPreferences preferences,
    required NotificationPolicyLedger ledger,
    required double randomValue,
  }) {
    final localNow = now.toLocal();
    if (!preferences.canNotify || preferences.isQuietAt(localNow)) return null;
    if (ledger.deliveredOn(localNow) >= preferences.dailyProactiveBudget) {
      return null;
    }
    final last = ledger.lastDeliveredAt?.toLocal();
    if (last != null && localNow.difference(last) < const Duration(hours: 2)) {
      return null;
    }

    if (preferences.greetingsEnabled) {
      final greeting = _greetingFor(localNow);
      if (greeting != null && !ledger.deliveredKeys.contains(greeting.$1)) {
        return NotificationPolicyDecision(
          dedupKey: greeting.$1,
          notification: greeting.$2,
        );
      }
    }

    if (!preferences.randomCheckInsEnabled || !_inRandomWindow(localNow)) {
      return null;
    }
    final lastRandom = ledger.lastRandomAt?.toLocal();
    if (lastRandom != null &&
        localNow.difference(lastRandom) < const Duration(hours: 36)) {
      return null;
    }
    if (randomValue < 0 || randomValue >= randomThreshold) return null;
    final key =
        '${_dateKey(localNow)}:${MaasoNotificationKind.randomCheckIn.key}';
    if (ledger.deliveredKeys.contains(key)) return null;
    return NotificationPolicyDecision(
      dedupKey: key,
      notification: MaasoNotification(
        deliveryId: key,
        kind: MaasoNotificationKind.randomCheckIn,
        title: 'Maaso 想起了你',
        body: '不着急回复，我只是想来看看你今天过得怎么样。',
        prompt: '用一句自然、低打扰的中文关心用户近况，不要连续追问。',
      ),
    );
  }

  (String, MaasoNotification)? _greetingFor(DateTime now) {
    final minute = now.hour * 60 + now.minute;
    final date = _dateKey(now);
    if (minute >= 7 * 60 && minute < 9 * 60 + 30) {
      final key = '$date:${MaasoNotificationKind.morningGreeting.key}';
      return (
        key,
        MaasoNotification(
          deliveryId: key,
          kind: MaasoNotificationKind.morningGreeting,
          title: '早上好',
          body: '新的一天开始啦，愿你今天从容又开心。',
          prompt: '用简短温暖的中文向用户道早安，不要连续追问。',
        ),
      );
    }
    if (minute >= 11 * 60 + 30 && minute < 13 * 60 + 30) {
      final key = '$date:${MaasoNotificationKind.middayGreeting.key}';
      return (
        key,
        MaasoNotification(
          deliveryId: key,
          kind: MaasoNotificationKind.middayGreeting,
          title: '午间休息一下吧',
          body: '记得吃饭、喝水，也给自己留一点喘息的时间。',
          prompt: '用一句轻松的中文提醒用户午间休息，不要说教。',
        ),
      );
    }
    if (minute >= 19 * 60 + 30 && minute < 21 * 60 + 30) {
      final key = '$date:${MaasoNotificationKind.eveningGreeting.key}';
      return (
        key,
        MaasoNotification(
          deliveryId: key,
          kind: MaasoNotificationKind.eveningGreeting,
          title: '晚上好',
          body: '今天辛苦了，愿接下来的时间慢一点、舒服一点。',
          prompt: '用简短温柔的中文向用户道晚安式问候，不要催促回复。',
        ),
      );
    }
    return null;
  }

  bool _inRandomWindow(DateTime now) {
    final minute = now.hour * 60 + now.minute;
    return minute >= 14 * 60 && minute < 18 * 60;
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
