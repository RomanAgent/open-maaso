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
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:maaso/src/features/settings/presentation/location_settings_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() async {
    AppLocalization.updateLocale(const Locale('en'));
    await appServices.reset();
  });

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets(
      '${locale.languageCode}: settings has no internet region selector',
      (tester) async {
        // Render every settings group, including the hardware section that used
        // to contain the selector, so lazy offscreen content cannot hide it.
        tester.view.physicalSize = const Size(430, 5000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        AppLocalization.updateLocale(locale);
        appServices.put(
          const AppPlatformCapabilities.forPlatform(AppHostPlatform.ios),
        );
        appServices.put(await HomePresentationPreferenceService().load());
        appServices.put(ContextStatsService());
        final theme = appServices.put(ThemeService());
        appServices.put<AgentSettingsController>(_SettingsController(locale));
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.build(theme.palette),
              themeAnimationDuration: Duration.zero,
              locale: locale,
              supportedLocales: const [Locale('en'), Locale('zh')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const AgentSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('settings.devices_preferences'.tr), findsOneWidget);
        expect(find.text('settings.bluetooth'.tr), findsOneWidget);
        expect(find.text('settings.microphone'.tr), findsOneWidget);
        expect(find.byType(LocationSettingsRow), findsOneWidget);
        expect(find.text('Internet tool region'), findsNothing);
        expect(find.text('联网查询地区'), findsNothing);
        expect(find.text('settings.network_region'), findsNothing);
        for (final key in [
          'settings-network-region-choice',
          'settings-network-region-status',
          'settings-network-region-chinaMainland',
          'settings-network-region-overseas',
        ]) {
          expect(find.byKey(ValueKey(key)), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
}

// Keep settings persistence out of this UI boundary test; the actual page,
// locale, theme and neighboring location control are mounted above.
final class _SettingsController extends Fake
    implements AgentSettingsController {
  _SettingsController(Locale locale)
    : selectedLocale =
          (locale.languageCode == 'zh' ? AppLocale.zh : AppLocale.en).obs;

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
}
