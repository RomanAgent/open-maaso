import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('privacy-safe defaults require explicit opt-in', () async {
    final service = await NotificationPreferencesService.forTesting().init();

    expect(service.state.value.enabled, isFalse);
    expect(service.state.value.permissionGranted, isFalse);
    expect(service.state.value.canNotify, isFalse);
  });

  test('consent, categories and quiet hours persist', () async {
    final service = await NotificationPreferencesService.forTesting().init();
    await service.setConsent(enabled: true, permissionGranted: true);
    await service.setGreetingsEnabled(false);
    await service.setRandomCheckInsEnabled(false);
    await service.setScheduledTasksEnabled(false);
    await service.setQuietHours(start: 23 * 60, end: 8 * 60);
    await service.setDailyProactiveBudget(2);

    final reloaded = await NotificationPreferencesService.forTesting().init();
    final value = reloaded.state.value;
    expect(value.canNotify, isTrue);
    expect(value.greetingsEnabled, isFalse);
    expect(value.randomCheckInsEnabled, isFalse);
    expect(value.scheduledTasksEnabled, isFalse);
    expect(value.quietStartMinutes, 23 * 60);
    expect(value.quietEndMinutes, 8 * 60);
    expect(value.dailyProactiveBudget, 2);
  });

  test('denied permission cannot leave notifications enabled', () async {
    final service = await NotificationPreferencesService.forTesting().init();

    await service.setConsent(enabled: true, permissionGranted: false);

    expect(service.state.value.enabled, isFalse);
    expect(service.state.value.canNotify, isFalse);
  });
}
