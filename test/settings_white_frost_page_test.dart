import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/notification_consent_service.dart';
import 'package:maaso/src/core/notifications/notification_delivery.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/context_stats_service.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:maaso/src/features/settings/presentation/settings_frost_components.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _capture = bool.fromEnvironment('MAASO_CAPTURE_SETTINGS');
const _visualFont = 'SettingsWhiteFrostVisual';

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
    testWidgets(
      '${locale.languageCode}: approved groups preserve destinations',
      (tester) async {
        await _mount(tester, locale: locale, size: const Size(430, 5000));
        final topToBottom = <Finder>[
          find.text('settings.title'.tr),
          find.byKey(const ValueKey('settings-home-view')),
          find.byKey(const ValueKey('settings-context-panel')),
          find.text('settings.agent_controls'.tr),
          find.text('settings.notifications_title'.tr),
          find.text('settings.devices_preferences'.tr),
          find.text('settings.privacy_policy'.tr),
          find.byKey(const ValueKey('settings-logout')),
        ];
        var previous = double.negativeInfinity;
        for (final finder in topToBottom) {
          expect(finder, findsOneWidget);
          final top = tester.getTopLeft(finder).dy;
          expect(top, greaterThan(previous));
          previous = top;
        }
        for (final key in [
          'settings.language',
          'settings.bluetooth',
          'settings.microphone',
          'account_deletion.title',
        ]) {
          expect(find.text(key.tr), findsOneWidget);
        }
        expect(find.text('profile.public_identity'.tr), findsNothing);
        expect(find.text('people_safety.title'.tr), findsNothing);
        expect(
          find.byKey(const ValueKey('settings-people-safety')),
          findsNothing,
        );
        expect(find.text('settings.network_region'.tr), findsNothing);
        expect(find.text('Maaso-Paw-001'), findsNothing);
        expect(find.text('settings.authorized'.tr), findsNothing);
        for (final element in find.byType(SettingsFrostGroup).evaluate()) {
          final group = element.widget as SettingsFrostGroup;
          final heading = find.descendant(
            of: find.byWidget(group),
            matching: find.text(group.title),
          );
          final panel = find.byKey(ValueKey('settings-group-${group.title}'));
          final material = tester.widget<Material>(
            find.descendant(of: panel, matching: find.byType(Material)).first,
          );
          expect(
            tester.getRect(heading).bottom,
            lessThan(tester.getRect(panel).top),
          );
          expect(material.color, MaasoGlassTheme.of(element).muted);
          expect(material.elevation, 0);
          expect(material.shape, isNull);
          expect(
            find.descendant(of: panel, matching: find.byType(BackdropFilter)),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('language sheet saves the chosen locale without cycling', (
    tester,
  ) async {
    final fixture = await _mount(tester, size: const Size(430, 5000));
    await tester.tap(find.byKey(const ValueKey('settings-language')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-language-sheet')),
      findsOneWidget,
    );
    expect(fixture.controller.localeRequests, isEmpty);
    for (final locale in AppLocale.values) {
      expect(
        find.byKey(ValueKey('settings-language-${locale.code}')),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey('settings-language-zh')));
    await tester.pumpAndSettle();
    expect(fixture.controller.localeRequests, [AppLocale.zh]);
    expect(fixture.controller.selectedLocale.value, AppLocale.zh);
    expect(find.byKey(const ValueKey('settings-language-sheet')), findsNothing);
    expect(find.text('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'notification rows retain consent and scheduled preference gates',
    (tester) async {
      final fixture = await _mount(tester, size: const Size(430, 5000));
      SwitchListTile row(String key) => tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, key.tr),
      );
      expect(fixture.delivery.permissionRequests, 0);
      expect(row('settings.notifications_allow').value, isFalse);
      expect(row('settings.notifications_scheduled_tasks').onChanged, isNull);

      await tester.tap(find.text('settings.notifications_allow'.tr));
      await tester.pumpAndSettle();
      expect(fixture.delivery.permissionRequests, 1);
      expect(fixture.notifications.state.value.canNotify, isTrue);
      expect(
        row('settings.notifications_scheduled_tasks').onChanged,
        isNotNull,
      );
      await tester.tap(find.text('settings.notifications_scheduled_tasks'.tr));
      await tester.pumpAndSettle();
      expect(fixture.notifications.state.value.scheduledTasksEnabled, isFalse);
      final reloaded = await NotificationPreferencesService.forTesting().init();
      expect(reloaded.state.value.scheduledTasksEnabled, isFalse);

      await tester.tap(find.text('settings.notifications_allow'.tr));
      await tester.pumpAndSettle();
      expect(fixture.notifications.state.value.canNotify, isFalse);
      expect(fixture.delivery.permissionRequests, 1);
      expect(row('settings.notifications_scheduled_tasks').onChanged, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hardware, privacy and account rows route to existing pages', (
    tester,
  ) async {
    final fixture = await _mount(tester, size: const Size(430, 5000));
    for (final destination in [
      (label: 'settings.bluetooth', route: AppRouteCatalog.bleProjector),
      (label: 'settings.privacy_policy', route: AppRouteCatalog.privacy),
      (label: 'account_deletion.title', route: AppRouteCatalog.accountDeletion),
    ]) {
      final semantics = tester.getSemantics(
        find.widgetWithText(SettingsFrostRow, destination.label.tr),
      );
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(
        semantics.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      expect(semantics.label, contains(destination.label.tr));
      await tester.tap(find.text(destination.label.tr));
      await tester.pumpAndSettle();
      expect(appNavigation.currentRoute, destination.route);
      expect(find.text('destination:${destination.route}'), findsOneWidget);
      fixture.router.pop();
      await tester.pumpAndSettle();
      expect(appNavigation.currentRoute, AppRouteCatalog.settings);
    }
    expect(fixture.controller.logoutRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'logout requires explicit confirmation and cancellation is safe',
    (tester) async {
      final fixture = await _mount(tester, size: const Size(430, 5000));
      final logout = find.byKey(const ValueKey('settings-logout'));
      await tester.tap(logout);
      await tester.pumpAndSettle();
      expect(fixture.controller.logoutRequests, 0);
      expect(
        find.byKey(const ValueKey('settings-logout-confirm')),
        findsOneWidget,
      );
      await tester.tap(find.text('common.cancel'.tr));
      await tester.pumpAndSettle();
      expect(fixture.controller.logoutRequests, 0);
      expect(
        find.byKey(const ValueKey('settings-logout-confirm')),
        findsNothing,
      );

      await tester.tap(logout);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-logout-confirm')));
      await tester.pumpAndSettle();
      expect(fixture.controller.logoutRequests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (
      name: 'light-zh',
      locale: const Locale('zh'),
      dark: false,
      scale: 1.0,
      size: const Size(393, 852),
    ),
    (
      name: 'dark-zh',
      locale: const Locale('zh'),
      dark: true,
      scale: 1.0,
      size: const Size(393, 852),
    ),
    (
      name: 'light-en',
      locale: const Locale('en'),
      dark: false,
      scale: 1.0,
      size: const Size(393, 852),
    ),
    (
      name: 'narrow-large-zh',
      locale: const Locale('zh'),
      dark: false,
      scale: 2.0,
      size: const Size(320, 740),
    ),
    (
      name: 'narrow-large-en',
      locale: const Locale('en'),
      dark: true,
      scale: 2.0,
      size: const Size(320, 740),
    ),
    (
      name: 'landscape-large-en',
      locale: const Locale('en'),
      dark: false,
      scale: 2.0,
      size: const Size(812, 375),
    ),
  ]) {
    testWidgets('whole settings layout ${scenario.name}', (tester) async {
      final fixture = await _mount(
        tester,
        locale: scenario.locale,
        dark: scenario.dark,
        scale: scenario.scale,
        size: scenario.size,
        visual: _capture,
      );
      expect(tester.takeException(), isNull);
      await _captureFrame(tester, fixture, '${scenario.name}-top');
      final scrollable = find
          .descendant(
            of: find.byType(AgentSettingsPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-language')),
        220,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _captureFrame(tester, fixture, '${scenario.name}-devices');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-logout')),
        220,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-logout')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _captureFrame(tester, fixture, '${scenario.name}-bottom');
      debugDisableShadows = true;
    });
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  bool dark = false,
  double scale = 1,
  Size size = const Size(393, 852),
  bool visual = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  AppLocalization.updateLocale(locale);
  appServices.put(
    const AppPlatformCapabilities.forPlatform(AppHostPlatform.ios),
  );
  appServices.put(
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: AppRouteCatalog.destinations.map(
          (destination) => destination.id,
        ),
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.ios,
        rolloutGeneration: 0,
      ),
    ),
  );
  appServices.put(await HomePresentationPreferenceService().load());
  final stats = appServices.put(ContextStatsService());
  stats.snapshot.value = ContextSnapshot(
    modelName: 'qwen',
    modelContextWindow: 32768,
    systemPromptChars: 4200,
    userInputChars: 8960,
    responseChars: 1820,
    turnCount: 8,
    updatedAt: DateTime.now(),
  );
  final theme = appServices.put(ThemeService());
  theme.setMode(dark ? ThemeModePreference.dark : ThemeModePreference.light);
  final controller = _SettingsController(theme, locale);
  appServices.put<AgentSettingsController>(controller);
  final notifications = appServices.put(
    await NotificationPreferencesService.forTesting().init(),
  );
  final delivery = _NotificationDelivery();
  appServices.put(
    NotificationConsentService(preferences: notifications, delivery: delivery),
  );
  if (visual) {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    await tester.runAsync(() async {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      final font = File('/System/Library/Fonts/STHeiti Light.ttc');
      if (await font.exists()) {
        final data = ByteData.sublistView(await font.readAsBytes());
        for (final family in [_visualFont, 'Ahem', 'Roboto']) {
          await (FontLoader(family)..addFont(Future.value(data))).load();
        }
      }
    });
  }
  final boundary = GlobalKey();
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRouteCatalog.settings,
    routes: [
      GoRoute(
        path: AppRouteCatalog.settings,
        builder: (_, _) => const AgentSettingsPage(),
      ),
      for (final route in [
        AppRouteCatalog.home,
        AppRouteCatalog.bleProjector,
        AppRouteCatalog.privacy,
        AppRouteCatalog.peopleSafety,
        AppRouteCatalog.accountDeletion,
      ])
        GoRoute(
          path: route,
          builder: (_, _) => Scaffold(body: Text('destination:$route')),
        ),
    ],
  );
  appNavigation.configure(router);
  await tester.pumpWidget(
    ProviderScope(
      child: AppReactiveBuilder(() {
        final base = AppTheme.build(
          theme.palette,
        ).copyWith(platform: TargetPlatform.iOS);
        return MaterialApp.router(
          routerConfig: router,
          theme: visual
              ? base.copyWith(
                  textTheme: base.textTheme.apply(fontFamily: _visualFont),
                  primaryTextTheme: base.primaryTextTheme.apply(
                    fontFamily: _visualFont,
                  ),
                  listTileTheme: base.listTileTheme.copyWith(
                    titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
                      fontFamily: _visualFont,
                    ),
                    subtitleTextStyle: base.listTileTheme.subtitleTextStyle
                        ?.copyWith(fontFamily: _visualFont),
                    leadingAndTrailingTextStyle: base
                        .listTileTheme
                        .leadingAndTrailingTextStyle
                        ?.copyWith(fontFamily: _visualFont),
                  ),
                  textButtonTheme: TextButtonThemeData(
                    style: base.textButtonTheme.style?.copyWith(
                      textStyle: WidgetStatePropertyAll(
                        base.textButtonTheme.style?.textStyle
                            ?.resolve({})
                            ?.copyWith(fontFamily: _visualFont),
                      ),
                    ),
                  ),
                )
              : base,
          themeAnimationDuration: Duration.zero,
          locale: controller.selectedLocale.value == AppLocale.zh
              ? const Locale('zh')
              : const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 44, bottom: 24),
              textScaler: TextScaler.linear(scale),
            ),
            child: RepaintBoundary(
              key: boundary,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  child ?? const SizedBox.shrink(),
                  const AppTopNoticeHost(),
                ],
              ),
            ),
          ),
        );
      }),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    appNavigation.dismissTopSnackBar();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    router.dispose();
  });
  return _Fixture(controller, notifications, delivery, router, boundary);
}

Future<void> _captureFrame(
  WidgetTester tester,
  _Fixture fixture,
  String name,
) async {
  if (!_capture) return;
  await tester.runAsync(() async {
    final render =
        fixture.boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final output = File(
      'build/verification/settings-white-frost-20261021/$name.png',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

final class _Fixture {
  const _Fixture(
    this.controller,
    this.notifications,
    this.delivery,
    this.router,
    this.boundary,
  );
  final _SettingsController controller;
  final NotificationPreferencesService notifications;
  final _NotificationDelivery delivery;
  final GoRouter router;
  final GlobalKey boundary;
}

final class _SettingsController extends Fake
    implements AgentSettingsController {
  _SettingsController(this.theme, Locale locale)
    : selectedLocale =
          (locale.languageCode == 'zh' ? AppLocale.zh : AppLocale.en).obs;

  final ThemeService theme;
  final localeRequests = <AppLocale>[];
  int logoutRequests = 0;

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
  Future<void> setLocale(AppLocale next) async {
    localeRequests.add(next);
    selectedLocale.value = next;
    AppLocalization.updateLocale(Locale(next == AppLocale.zh ? 'zh' : 'en'));
  }

  @override
  Future<void> setThemeMode(ThemeModePreference next) async {
    selectedThemeMode.value = next;
    theme.setMode(next);
  }

  @override
  Future<void> logout() async {
    logoutRequests += 1;
  }
}

final class _NotificationDelivery extends Fake implements NotificationDelivery {
  int permissionRequests = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async {
    permissionRequests += 1;
    return true;
  }
}
