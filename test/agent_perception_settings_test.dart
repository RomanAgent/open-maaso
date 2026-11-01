import 'dart:async';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/emotion_sensor_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    GlobalAudioplayersPlatformInterface.instance = _Global();
    AudioplayersPlatformInterface.instance = _Player();
  });
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({});
    await SpUtils.init();
    await MaasoTtsPlugin.loadSoundPreference();
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });
  tearDown(() async => appServices.reset());

  Future<void> mount(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const Scaffold(
            body: SingleChildScrollView(
              child: AgentPerceptionSettingsSection(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings switch existing sensor consent without creating Home', (
    tester,
  ) async {
    final sensor = appServices.put<EmotionSensorService>(
      EmotionSensorService(cameraLoader: () async => []),
    );
    await mount(tester);
    final control = find.byKey(const ValueKey('settings-agent-vision'));
    expect(tester.widget<SwitchListTile>(control).value, isFalse);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(sensor.userEnabled.value, isTrue);
    expect(tester.widget<SwitchListTile>(control).value, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'emotion_sensor.user_enabled',
      ),
      isTrue,
    );
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(sensor.userEnabled.value, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'emotion_sensor.user_enabled',
      ),
      isFalse,
    );
    expect(appServices.isRegistered<HomeController>(), isFalse);
  });

  testWidgets('sound toggles persist and unsupported vision stays disabled', (
    tester,
  ) async {
    await mount(tester);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('settings-agent-vision')),
          )
          .onChanged,
      isNull,
    );
    final sound = find.byKey(const ValueKey('settings-agent-sound'));
    await tester.tap(sound);
    await tester.pumpAndSettle();
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        MaasoTtsPlugin.soundPreferenceKey,
      ),
      isFalse,
    );
    await tester.tap(sound);
    await tester.pumpAndSettle();
    expect(MaasoTtsPlugin.soundEnabled.value, isTrue);
    expect(appServices.isRegistered<HomeController>(), isFalse);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'controls fit narrow large-text ${dark ? "dark" : "light"} settings',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await mount(tester, dark: dark, scale: 2);
        expect(tester.takeException(), isNull);
        expect(find.byType(SwitchListTile), findsNWidgets(2));
      },
    );
  }

  test('Home menu routes to settings instead of exposing sensory controls', () {
    final home = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    expect(home, isNot(contains('_HudVisionMenuItem')));
    expect(home, isNot(contains('_VisionEyeToggle')));
    expect(home, contains('route: AppRouteCatalog.settings'));
  });

  test(
    'startup restores mute before constructing any agent speech producer',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final restored = source.indexOf(
        'await MaasoTtsPlugin.loadSoundPreference()',
      );
      expect(restored, greaterThanOrEqualTo(0));
      expect(
        restored,
        lessThan(source.indexOf('AgentPipelineRuntimeService(')),
      );
      expect(restored, lessThan(source.indexOf('AgentBootController(')));
    },
  );
}

class _Global extends GlobalAudioplayersPlatformInterface {
  @override
  Future<void> emitGlobalLog(String message) async {}
  @override
  Future<void> emitGlobalError(String code, String message) async {}
  @override
  Future<void> init() async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();
  @override
  Future<void> setGlobalAudioContext(AudioContext context) async {}
}

class _Player extends AudioplayersPlatformInterface {
  final _events = <String, StreamController<AudioEvent>>{};
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected playback operation: ${invocation.memberName}',
  );
  @override
  Future<void> create(String id) async {}
  @override
  Future<void> stop(String id) async {}
  @override
  Stream<AudioEvent> getEventStream(String id) => _events
      .putIfAbsent(id, () => StreamController<AudioEvent>.broadcast())
      .stream;
}
