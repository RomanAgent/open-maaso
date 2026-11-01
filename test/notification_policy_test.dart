import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/notifications/notification_models.dart';
import 'package:maaso/src/core/notifications/notification_policy.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';

void main() {
  const policy = NotificationPolicy();
  const enabled = NotificationPreferences(
    enabled: true,
    permissionGranted: true,
  );

  test('requires explicit consent and permission', () {
    final decision = policy.evaluate(
      now: DateTime(2026, 8, 10, 8),
      preferences: const NotificationPreferences(),
      ledger: const NotificationPolicyLedger(),
      randomValue: 0,
    );

    expect(decision, isNull);
  });

  test('quiet hours support a range that crosses midnight', () {
    expect(enabled.isQuietAt(DateTime(2026, 8, 10, 23)), isTrue);
    expect(enabled.isQuietAt(DateTime(2026, 8, 10, 6, 59)), isTrue);
    expect(enabled.isQuietAt(DateTime(2026, 8, 10, 7)), isFalse);
  });

  test('morning, midday and evening windows are deterministic and deduped', () {
    final morning = policy.evaluate(
      now: DateTime(2026, 8, 10, 8),
      preferences: enabled,
      ledger: const NotificationPolicyLedger(),
      randomValue: 1,
    );
    final midday = policy.evaluate(
      now: DateTime(2026, 8, 10, 12),
      preferences: enabled,
      ledger: const NotificationPolicyLedger(),
      randomValue: 1,
    );
    final evening = policy.evaluate(
      now: DateTime(2026, 8, 10, 20),
      preferences: enabled,
      ledger: const NotificationPolicyLedger(),
      randomValue: 1,
    );

    expect(morning?.notification.kind, MaasoNotificationKind.morningGreeting);
    expect(midday?.notification.kind, MaasoNotificationKind.middayGreeting);
    expect(evening?.notification.kind, MaasoNotificationKind.eveningGreeting);
    expect(
      policy.evaluate(
        now: DateTime(2026, 8, 10, 8, 30),
        preferences: enabled,
        ledger: NotificationPolicyLedger(
          deliveredKeys: <String>{morning!.dedupKey},
        ),
        randomValue: 0,
      ),
      isNull,
    );
  });

  test('daily budget suppresses additional proactive messages', () {
    final now = DateTime(2026, 8, 10, 20);
    final decision = policy.evaluate(
      now: now,
      preferences: enabled,
      ledger: NotificationPolicyLedger(
        deliveredAt: <DateTime>[
          DateTime(2026, 8, 10, 8),
          DateTime(2026, 8, 10, 12),
          DateTime(2026, 8, 10, 15),
        ],
      ),
      randomValue: 0,
    );

    expect(decision, isNull);
  });

  test('random check-ins are chance-gated and at least 36 hours apart', () {
    final now = DateTime(2026, 8, 10, 15);
    final first = policy.evaluate(
      now: now,
      preferences: enabled,
      ledger: const NotificationPolicyLedger(),
      randomValue: 0.01,
    );
    final tooSoon = policy.evaluate(
      now: now,
      preferences: enabled,
      ledger: NotificationPolicyLedger(
        deliveredAt: <DateTime>[now.subtract(const Duration(hours: 24))],
        lastRandomAt: now.subtract(const Duration(hours: 24)),
      ),
      randomValue: 0.01,
    );
    final chanceMiss = policy.evaluate(
      now: now,
      preferences: enabled,
      ledger: const NotificationPolicyLedger(),
      randomValue: 0.5,
    );

    expect(first?.notification.kind, MaasoNotificationKind.randomCheckIn);
    expect(tooSoon, isNull);
    expect(chanceMiss, isNull);
  });
}
