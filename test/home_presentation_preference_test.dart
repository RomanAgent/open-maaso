import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({});
    AppLocalization.updateLocale(const Locale('en', 'US'));
    appServices.put(
      const AppPlatformCapabilities.forPlatform(AppHostPlatform.ios),
    );
  });

  tearDown(() async {
    await appServices.reset();
  });

  Future<HomePresentationPreferenceService> loadService() async =>
      appServices.put<HomePresentationPreferenceService>(
        await HomePresentationPreferenceService().load(),
      );

  test('new and unknown preferences default to avatar', () async {
    for (final raw in [null, 'unknown', 42]) {
      SharedPreferences.setMockInitialValues({
        HomePresentationPreferenceService.storageKey: ?raw,
      });
      final service = await HomePresentationPreferenceService().load();
      expect(service.mode.value, HomePresentationMode.avatar);
      expect(
        service.resolve(avatarAvailable: true),
        HomePresentationMode.avatar,
      );
    }
  });

  test('each saved choice is restored by a new service instance', () async {
    var service = await HomePresentationPreferenceService().load();
    for (final mode in HomePresentationMode.values) {
      await service.setMode(mode);
      await (await SharedPreferences.getInstance()).reload();
      service = await HomePresentationPreferenceService().load();
      expect(service.mode.value, mode);
      expect(
        (await SharedPreferences.getInstance()).getString(
          HomePresentationPreferenceService.storageKey,
        ),
        mode.name,
      );
    }
  });

  test('temporary avatar unavailability preserves the saved choice', () async {
    SharedPreferences.setMockInitialValues({
      HomePresentationPreferenceService.storageKey: 'avatar',
    });
    final service = await HomePresentationPreferenceService().load();
    expect(service.resolve(avatarAvailable: false), HomePresentationMode.chat);
    expect(service.mode.value, HomePresentationMode.avatar);
    expect(service.resolve(avatarAvailable: true), HomePresentationMode.avatar);
    expect(
      (await HomePresentationPreferenceService().load()).mode.value,
      HomePresentationMode.avatar,
    );
  });

  test('rapid choices persist in order and notify only after saving', () async {
    final store = _ControlledPreferencesStore();
    SharedPreferencesStorePlatform.instance = store;
    final service = await HomePresentationPreferenceService().load();
    final observed = <HomePresentationMode>[];
    final listener = service.mode.listen(observed.add);
    addTearDown(listener.dispose);
    final releaseFirst = Completer<void>();
    store.beforeNextWrite = releaseFirst.future;
    final chat = service.setMode(HomePresentationMode.chat);
    final avatar = service.setMode(HomePresentationMode.avatar);
    await store.firstWrite.future;
    expect(service.mode.value, HomePresentationMode.avatar);
    expect(observed, isEmpty);
    releaseFirst.complete();
    await Future.wait([chat, avatar]);
    expect(observed, [HomePresentationMode.chat, HomePresentationMode.avatar]);
    expect(store.writtenValues, ['chat', 'avatar']);
    expect(
      (await HomePresentationPreferenceService().load()).mode.value,
      HomePresentationMode.avatar,
    );
  });

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
              padding: EdgeInsets.all(16),
              child: HomePresentationSettingsSection(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  HomePresentationMode selectedMode(WidgetTester tester) =>
      tester
              .getSemantics(
                find.byKey(const ValueKey('settings-home-view-avatar')),
              )
              .flagsCollection
              .isSelected ==
          ui.Tristate.isTrue
      ? HomePresentationMode.avatar
      : HomePresentationMode.chat;

  testWidgets('settings switches persist without constructing Home', (
    tester,
  ) async {
    final service = await loadService();
    await mount(tester);
    expect(selectedMode(tester), HomePresentationMode.avatar);
    await tester.tap(find.byKey(const ValueKey('settings-home-view-chat')));
    await tester.pumpAndSettle();
    expect(service.mode.value, HomePresentationMode.chat);
    expect(selectedMode(tester), HomePresentationMode.chat);
    expect(
      (await HomePresentationPreferenceService().load()).mode.value,
      HomePresentationMode.chat,
    );
    await tester.tap(find.byKey(const ValueKey('settings-home-view-avatar')));
    await tester.pumpAndSettle();
    expect(service.mode.value, HomePresentationMode.avatar);
    expect(appServices.isRegistered<HomeController>(), isFalse);
  });

  testWidgets('failed save retains selection and can be retried', (
    tester,
  ) async {
    final store = _ControlledPreferencesStore()..failNextWrite = true;
    SharedPreferencesStorePlatform.instance = store;
    final service = await loadService();
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('settings-home-view-chat')));
    await tester.pumpAndSettle();
    expect(service.mode.value, HomePresentationMode.avatar);
    expect(selectedMode(tester), HomePresentationMode.avatar);
    expect(find.text('settings.home_view_error'.tr), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-home-view-chat')));
    await tester.pumpAndSettle();
    expect(selectedMode(tester), HomePresentationMode.chat);
    expect(find.text('settings.home_view_error'.tr), findsNothing);
  });

  for (final platform in [AppHostPlatform.macos, AppHostPlatform.linux]) {
    testWidgets(
      '$platform uses chat without rewriting the avatar preference',
      (tester) async {
        await appServices.delete<AppPlatformCapabilities>(force: true);
        appServices.put(AppPlatformCapabilities.forPlatform(platform));
        final service = await loadService();
        await mount(tester);
        expect(selectedMode(tester), HomePresentationMode.chat);
        for (final mode in HomePresentationMode.values) {
          final semantics = tester.getSemantics(
            find.byKey(ValueKey('settings-home-view-${mode.name}')),
          );
          expect(semantics.flagsCollection.isEnabled, ui.Tristate.isFalse);
        }
        expect(find.text('settings.home_view_unavailable'.tr), findsOneWidget);
        expect(service.mode.value, HomePresentationMode.avatar);
        expect(
          (await HomePresentationPreferenceService().load()).mode.value,
          HomePresentationMode.avatar,
        );
      },
      variant: TargetPlatformVariant.only(
        platform == AppHostPlatform.macos
            ? TargetPlatform.macOS
            : TargetPlatform.linux,
      ),
    );
  }

  for (final dark in [false, true]) {
    testWidgets(
      'view choices fit narrow large-text ${dark ? "dark" : "light"}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (dark) AppLocalization.updateLocale(const Locale('zh', 'CN'));
        await loadService();
        await mount(tester, dark: dark, scale: 2);
        expect(tester.takeException(), isNull);
        expect(find.text('settings.home_view_chat'.tr), findsOneWidget);
        expect(find.text('settings.home_view_avatar'.tr), findsOneWidget);
      },
    );
  }
}

class _ControlledPreferencesStore extends InMemorySharedPreferencesStore {
  _ControlledPreferencesStore() : super.empty();

  final firstWrite = Completer<void>();
  final writtenValues = <Object>[];
  Future<void>? beforeNextWrite;
  bool failNextWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writtenValues.add(value);
    if (!firstWrite.isCompleted) firstWrite.complete();
    final pending = beforeNextWrite;
    beforeNextWrite = null;
    if (pending != null) await pending;
    if (failNextWrite) {
      failNextWrite = false;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
