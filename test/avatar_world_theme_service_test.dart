import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/core/services/avatar_world_theme_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(UnityAvatarRuntime.channelName);
  late List<MethodCall> calls;

  setUp(() {
    appServices.testMode = true;
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'resolved app brightness updates active avatar world lighting',
    () async {
      final theme = appServices.put(ThemeService());
      final active = appServices.put(ActiveAvatarRuntime());
      final runtime = UnityAvatarRuntime(channel: channel);
      active.register(runtime);
      final service = appServices.put(
        AvatarWorldThemeService(themeService: theme, avatarRuntime: active),
      );

      await service.syncNow();
      expect(_lightingPayloads(calls).last, 'day');

      theme.setBrightness(Brightness.dark);
      await Future<void>.delayed(Duration.zero);

      expect(_lightingPayloads(calls).last, 'night');

      theme.setSystemBrightnessForTest(Brightness.dark);
      theme.setMode(ThemeModePreference.light);
      await Future<void>.delayed(Duration.zero);
      expect(theme.brightness.value, Brightness.light);
      expect(_lightingPayloads(calls).last, 'day');
    },
  );
}

List<String> _lightingPayloads(List<MethodCall> calls) {
  return calls
      .where((call) => call.method == 'setWorldTimeOfDay')
      .map(
        (call) =>
            (call.arguments as Map<Object?, Object?>)['timeOfDay'] as String,
      )
      .toList(growable: false);
}
