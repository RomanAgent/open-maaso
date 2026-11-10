import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(appServices.reset);

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets(
      '${locale.languageCode}: API-only settings expose credentials without a Cloud-off switch',
      (tester) async {
        tester.view.physicalSize = const Size(430, 6000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        AppLocalization.updateLocale(locale);
        addTearDown(() => AppLocalization.updateLocale(const Locale('en')));
        appServices.put(await HomePresentationPreferenceService().load());
        appServices.put(
          LLMConfigController(
            storage: _MemoryStorage(),
            storageScopes: AccountStorageScopeService(),
            localEdition: true,
          ),
        );
        final controller = _ApiSettingsController(locale);
        appServices.put<AgentSettingsController>(controller);
        final theme = ThemeService()..setMode(ThemeModePreference.light);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.build(theme.palette),
              locale: locale,
              supportedLocales: const [Locale('en'), Locale('zh')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const AgentSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('settings.section_model'.tr), findsOneWidget);
        expect(
          find.text('settings.api_only_model_subtitle'.tr),
          findsOneWidget,
        );
        expect(find.text('settings.cloud_brain_off'.tr), findsNothing);
        expect(find.text('settings.cloud_brain_on'.tr), findsNothing);
        expect(find.text('settings.local_key_note'.tr), findsNothing);
        expect(find.text('settings.api_only_key_note'.tr), findsOneWidget);
        final credentials = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.controller == controller.apiKey,
        );
        expect(credentials, findsOneWidget);
        expect(tester.widget<TextField>(credentials).obscureText, isTrue);
        final modelGroup = find
            .ancestor(of: credentials, matching: find.byType(Column))
            .at(1);
        expect(
          find.descendant(
            of: modelGroup,
            matching: find.byType(AppGlassToggle),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        controller.apiKey.dispose();
        controller.baseUrl.dispose();
        controller.model.dispose();
      },
    );
  }
}

final class _ApiSettingsController extends Fake
    implements AgentSettingsController {
  _ApiSettingsController(Locale locale)
    : selectedLocale =
          (locale.languageCode == 'zh' ? AppLocale.zh : AppLocale.en).obs;
  @override
  bool get localEdition => true;
  @override
  final selectedThemeMode = ThemeModePreference.light.obs;
  @override
  final Rx<AppLocale> selectedLocale;
  @override
  final connectedDevice = RxnString();
  @override
  final cloudEnabled = false.obs;
  @override
  final cloudSaveFailed = false.obs;
  @override
  final apiKey = TextEditingController();
  @override
  final baseUrl = TextEditingController(text: 'https://model.example.test/v1');
  @override
  final model = TextEditingController(text: 'fixture-model');
  @override
  final selectedProviderName = AgentSettingsController.customProviderName.obs;
  @override
  final selectedModelId = 'fixture-model'.obs;
  @override
  List<ProviderPreset> get providers => AgentSettingsController.providerPresets;
  @override
  List<String> get currentModels => const [];
  @override
  void initializeLifecycle() {}
  @override
  void closeLifecycle() {}
}

final class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
