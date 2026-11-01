import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/context_stats_service.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _appearanceToggle = ValueKey('settings-appearance-toggle');
const _topNotice = ValueKey<String>('app-top-notice');

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppLocalization.updateLocale(const Locale('en'));
  });
  tearDown(() async {
    appNavigation.dismissTopSnackBar();
    AppLocalization.updateLocale(const Locale('en'));
    await appServices.reset();
  });

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets('${locale.languageCode}: appearance offers explicit choices', (
      tester,
    ) async {
      final fixture = await _mountAppearance(tester, locale: locale);
      expect(
        fixture.controller.selectedThemeMode.value,
        ThemeModePreference.system,
      );
      expect(_button(tester).icon, Icons.light_mode_rounded);

      for (final next in [
        ThemeModePreference.dark,
        ThemeModePreference.light,
        ThemeModePreference.system,
      ]) {
        await _openAppearance(tester);
        expect(fixture.controller.requests.length, lessThan(3));
        for (final mode in ThemeModePreference.values) {
          expect(find.byKey(_choice(mode)), findsOneWidget);
        }
        await tester.tap(find.byKey(_choice(next)));
        await tester.pumpAndSettle();

        expect(fixture.controller.selectedThemeMode.value, next);
        expect(fixture.theme.mode.value, next);
        expect(
          _button(tester).icon,
          next == ThemeModePreference.dark
              ? Icons.dark_mode_rounded
              : Icons.light_mode_rounded,
        );
        final notice = find.byKey(_topNotice);
        expect(notice, findsOneWidget);
        expect(
          find.descendant(
            of: notice,
            matching: find.text(_changedMessage(next)),
          ),
          findsOneWidget,
        );
        expect(tester.getRect(notice).top, lessThan(160));
        expect(find.byType(SnackBar), findsNothing);
        expect(_button(tester).tooltip, contains(_modeLabel(next)));
        expect(tester.takeException(), isNull);
      }
      expect(fixture.controller.requests, [
        ThemeModePreference.dark,
        ThemeModePreference.light,
        ThemeModePreference.system,
      ]);
    });

    testWidgets('${locale.languageCode}: save failure stays retryable', (
      tester,
    ) async {
      final fixture = await _mountAppearance(tester, locale: locale);
      fixture.controller.failNextSave = true;
      await _openAppearance(tester);
      await tester.tap(find.byKey(_choice(ThemeModePreference.light)));
      await tester.pumpAndSettle();

      expect(
        fixture.controller.selectedThemeMode.value,
        ThemeModePreference.system,
      );
      expect(fixture.theme.mode.value, ThemeModePreference.system);
      expect(_button(tester).icon, Icons.light_mode_rounded);
      expect(_button(tester).onPressed, isNotNull);
      expect(
        find.descendant(
          of: find.byKey(_topNotice),
          matching: find.text('settings.theme_mode_save_failed'.tr),
        ),
        findsOneWidget,
      );
      expect(
        find.text(_changedMessage(ThemeModePreference.light)),
        findsNothing,
      );

      await _openAppearance(tester);
      await tester.tap(find.byKey(_choice(ThemeModePreference.light)));
      await tester.pumpAndSettle();
      expect(
        fixture.controller.selectedThemeMode.value,
        ThemeModePreference.light,
      );
      expect(fixture.controller.requests, [
        ThemeModePreference.light,
        ThemeModePreference.light,
      ]);
      expect(
        find.text(_changedMessage(ThemeModePreference.light)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('${locale.languageCode}: dismissing does not change mode', (
      tester,
    ) async {
      final fixture = await _mountAppearance(tester, locale: locale);
      await _openAppearance(tester);
      expect(fixture.controller.requests, isEmpty);
      Navigator.of(
        tester.element(find.byKey(const ValueKey('settings-appearance-sheet'))),
      ).pop();
      await tester.pumpAndSettle();
      expect(fixture.controller.requests, isEmpty);
      expect(
        fixture.controller.selectedThemeMode.value,
        ThemeModePreference.system,
      );
      expect(find.byKey(_topNotice), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('system resolves to sun and moon without a third icon', (
    tester,
  ) async {
    final fixture = await _mountAppearance(tester);
    expect(fixture.theme.mode.value, ThemeModePreference.system);
    expect(_button(tester).icon, Icons.light_mode_rounded);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(fixture.theme.systemBrightness.value, Brightness.dark);
    expect(fixture.theme.brightness.value, Brightness.dark);
    expect(_button(tester).icon, Icons.dark_mode_rounded);
    expect(
      fixture.controller.selectedThemeMode.value,
      ThemeModePreference.system,
    );
    expect(fixture.controller.requests, isEmpty);
    expect(find.byKey(_topNotice), findsNothing);

    // Selecting light explicitly overrides the system's current dark mode.
    await _openAppearance(tester);
    await tester.tap(find.byKey(_choice(ThemeModePreference.light)));
    await tester.pumpAndSettle();
    expect(
      fixture.controller.selectedThemeMode.value,
      ThemeModePreference.light,
    );
    expect(fixture.theme.brightness.value, Brightness.light);
    expect(_button(tester).icon, Icons.light_mode_rounded);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(fixture.theme.brightness.value, Brightness.light);
    expect(_button(tester).icon, Icons.light_mode_rounded);

    await _openAppearance(tester);
    await tester.tap(find.byKey(_choice(ThemeModePreference.dark)));
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(
      fixture.controller.selectedThemeMode.value,
      ThemeModePreference.dark,
    );
    expect(fixture.theme.brightness.value, Brightness.dark);
    expect(_button(tester).icon, Icons.dark_mode_rounded);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending appearance save ignores duplicate taps', (tester) async {
    final fixture = await _mountAppearance(tester);
    final gate = Completer<void>();
    fixture.controller.saveGate = gate.future;
    await _openAppearance(tester);
    await tester.tap(find.byKey(_choice(ThemeModePreference.light)));
    await tester.pump();
    expect(_button(tester).onPressed, isNull);
    expect(find.byKey(_topNotice), findsNothing);
    await tester.tap(find.byKey(_appearanceToggle));
    await tester.pump();
    expect(fixture.controller.requests, [ThemeModePreference.light]);

    gate.complete();
    await tester.pumpAndSettle();
    expect(
      fixture.controller.selectedThemeMode.value,
      ThemeModePreference.light,
    );
    expect(_button(tester).onPressed, isNotNull);
    expect(
      find.text(_changedMessage(ThemeModePreference.light)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets(
      'replaced account suppresses late ${fail ? 'failure' : 'success'} notice',
      (tester) async {
        final fixture = await _mountAppearance(tester);
        final gate = Completer<void>();
        fixture.controller.saveGate = gate.future;
        fixture.controller.failNextSave = fail;
        await _openAppearance(tester);
        await tester.tap(find.byKey(_choice(ThemeModePreference.light)));
        await tester.pump();
        final replacement = _AppearanceController(fixture.theme);
        appServices.put<AgentSettingsController>(
          replacement,
          overrideAbstract: true,
        );
        gate.complete();
        await tester.pumpAndSettle();

        expect(find.byKey(_topNotice), findsNothing);
        expect(replacement.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      testWidgets('${locale.languageCode}: 2x text header fits $size', (
        tester,
      ) async {
        final reportedErrors = <FlutterErrorDetails>[];
        final previousErrorHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          reportedErrors.add(details);
          previousErrorHandler?.call(details);
        };
        addTearDown(() => FlutterError.onError = previousErrorHandler);
        await _mountAppearance(
          tester,
          locale: locale,
          size: size,
          textScaler: const TextScaler.linear(2),
        );
        final toggle = find.byKey(_appearanceToggle);
        final rect = tester.getRect(toggle);
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(find.byTooltip(_button(tester).tooltip), findsOneWidget);

        await _openAppearance(tester);
        final choice = find.byKey(_choice(ThemeModePreference.dark));
        await tester.ensureVisible(choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
        final notice = tester.getRect(find.byKey(_topNotice));
        expect(notice.left, greaterThanOrEqualTo(0));
        expect(notice.right, lessThanOrEqualTo(size.width));
        expect(
          tester.takeException(),
          isNull,
          reason: reportedErrors
              .map((details) => details.toDiagnosticsNode().toStringDeep())
              .join('\n'),
        );
      });
    }
  }
}

ValueKey<String> _choice(ThemeModePreference mode) =>
    ValueKey('settings-appearance-${mode.key}');

Future<void> _openAppearance(WidgetTester tester) async {
  final sheet = find.byKey(const ValueKey('settings-appearance-sheet'));
  if (sheet.evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(_appearanceToggle));
  await tester.pumpAndSettle();
  expect(sheet, findsOneWidget);
}

AppGlassIconButton _button(WidgetTester tester) =>
    tester.widget<AppGlassIconButton>(find.byKey(_appearanceToggle));

String _modeLabel(ThemeModePreference mode) => switch (mode) {
  ThemeModePreference.system => 'settings.theme_mode_system'.tr,
  ThemeModePreference.light => 'settings.theme_mode_light'.tr,
  ThemeModePreference.dark => 'settings.theme_mode_dark'.tr,
};

String _changedMessage(ThemeModePreference mode) =>
    'settings.theme_mode_changed'.trParams({'mode': _modeLabel(mode)});

Future<_AppearanceFixture> _mountAppearance(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  Size size = const Size(375, 812),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  AppLocalization.updateLocale(locale);
  appServices.put(
    const AppPlatformCapabilities.forPlatform(AppHostPlatform.ios),
  );
  appServices.put(await HomePresentationPreferenceService().load());
  appServices.put(ContextStatsService());
  final theme = appServices.put(ThemeService());
  final controller =
      appServices.put<AgentSettingsController>(
            _AppearanceController(theme, locale: locale),
          )
          as _AppearanceController;
  await tester.pumpWidget(
    ProviderScope(
      child: AppReactiveBuilder(
        () => MaterialApp(
          navigatorKey: rootNavigatorKey,
          theme: AppTheme.build(theme.palette),
          themeAnimationDuration: Duration.zero,
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: Stack(
              fit: StackFit.expand,
              children: [
                child ?? const SizedBox.shrink(),
                const AppTopNoticeHost(),
              ],
            ),
          ),
          home: const AgentSettingsPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    appNavigation.dismissTopSnackBar();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  return _AppearanceFixture(controller, theme);
}

final class _AppearanceFixture {
  const _AppearanceFixture(this.controller, this.theme);

  final _AppearanceController controller;
  final ThemeService theme;
}

// Only persistence is replaced: every assertion mounts the real settings page,
// shared theme, controls and notification host. DB restore is tested separately.
final class _AppearanceController extends Fake
    implements AgentSettingsController {
  _AppearanceController(this.theme, {Locale locale = const Locale('en')})
    : selectedLocale =
          (locale.languageCode == 'zh' ? AppLocale.zh : AppLocale.en).obs;

  final ThemeService theme;
  final requests = <ThemeModePreference>[];
  Future<void>? saveGate;
  bool failNextSave = false;

  @override
  final selectedThemeMode = ThemeModePreference.system.obs;
  @override
  final Rx<AppLocale> selectedLocale;
  @override
  final connectedDevice = Rxn<String>();
  @override
  void initializeLifecycle() {}
  @override
  void closeLifecycle() {}

  @override
  Future<void> setThemeMode(ThemeModePreference next) async {
    requests.add(next);
    await saveGate;
    if (failNextSave) {
      failNextSave = false;
      throw StateError('appearance_test_save_failed');
    }
    selectedThemeMode.value = next;
    theme.setMode(next);
  }
}
