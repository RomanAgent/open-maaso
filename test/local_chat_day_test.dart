import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/chat/application/local_chat_day.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local calendar bounds include midnight and exclude the next midnight',
    () {
      final day = LocalChatDay.at(DateTime(2026, 9, 15, 12).toUtc());
      expect(day.start, DateTime(2026, 9, 15));
      expect(day.end, DateTime(2026, 9, 16));
      expect(day.contains(day.start.toUtc()), isTrue);
      expect(
        day.contains(day.start.subtract(const Duration(microseconds: 1))),
        isFalse,
      );
      expect(
        day.contains(day.end.subtract(const Duration(microseconds: 1)).toUtc()),
        isTrue,
      );
      expect(day.contains(day.end.toUtc()), isFalse);
    },
  );

  test('DST boundary dates use the next local calendar date, not 24 hours', () {
    for (final date in [DateTime(2026, 3, 8, 12), DateTime(2026, 11, 1, 12)]) {
      final day = LocalChatDay.at(date);
      expect(day.end, DateTime(date.year, date.month, date.day + 1));
      expect(day.end.hour, 0);
    }
  });

  testWidgets('midnight notifies once, resume refreshes and dispose cancels', (
    tester,
  ) async {
    var now = DateTime(2026, 9, 15, 23, 59, 59);
    final clock = LocalChatDayClock(clock: () => now);
    var notifications = 0;
    clock.addListener(() => notifications++);
    now = DateTime(2026, 9, 16);
    await tester.pump(const Duration(seconds: 1));
    expect(notifications, 1);
    expect(clock.day.start, now);
    await tester.pump(const Duration(minutes: 1));
    expect(notifications, 1);
    clock.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = DateTime(2026, 9, 20, 9);
    await tester.pump(const Duration(days: 4));
    expect(notifications, 1);
    clock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(notifications, 2);
    expect(clock.day.start, DateTime(2026, 9, 20));
    clock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(
      notifications,
      3,
    ); // Same-day resume must refresh persisted rows too.
    clock.dispose();
    await tester.pump(const Duration(days: 1));
    expect(notifications, 3);
  });

  testWidgets('foreground checks notice a backward device clock change', (
    tester,
  ) async {
    var now = DateTime(2026, 9, 15, 12);
    final clock = LocalChatDayClock(clock: () => now);
    var notifications = 0;
    clock.addListener(() => notifications++);
    now = DateTime(2026, 9, 14, 12);
    await tester.pump(const Duration(minutes: 1));
    expect(notifications, 1);
    expect(clock.day.start, DateTime(2026, 9, 14));
    clock.dispose();
  });
}
