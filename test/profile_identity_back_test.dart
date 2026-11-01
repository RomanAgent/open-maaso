import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/presentation/identity_route_page.dart';
import 'package:maaso/src/features/identity/presentation/profile_page.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';

import 'identity_test_support.dart';
import 'profile_membership_test_support.dart';

class _SettingsController extends Fake implements AgentSettingsController {
  @override
  final selectedThemeMode = ThemeModePreference.light.obs;
  @override
  final selectedLocale = AppLocale.en.obs;
  @override
  final connectedDevice = Rxn<String>();
  @override
  void initializeLifecycle() {}
  @override
  void closeLifecycle() {}
}

Future<GoRouter> _mount(
  WidgetTester tester,
  ProfileFixture fixture, {
  String initial = AppRoutes.home,
  Locale locale = const Locale('en'),
}) async {
  await fixture.identity.load();
  appServices.put<IdentityService>(fixture.identity);
  appServices.put<AgentSettingsController>(_SettingsController());
  final router = createAppRouter(
    initialLocation: initial,
    routesOverride: [
      GoRoute(
        path: AppRoutes.home,
        builder: (_, _) => Scaffold(
          body: Column(
            children: [
              TextButton(
                onPressed: () =>
                    unawaited(appNavigation.push(AppRoutes.profile)),
                child: const Text('Open profile'),
              ),
              TextButton(
                onPressed: () =>
                    unawaited(appNavigation.push(AppRoutes.settings)),
                child: const Text('Open settings'),
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.profile,
        builder: (_, _) => ProfilePage(
          controller: fixture.controller,
          route: AppRoutes.profile,
          membershipRoute: AppRoutes.membership,
        ),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (_, _) => const AgentSettingsPage(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (_, _) => const IdentityRoutePage(),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (_, _) => const Scaffold(body: Text('Login')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('common.back'.tr));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en'));
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    AppLocalization.updateLocale(const Locale('en'));
    await appServices.reset();
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      testWidgets(
        '${platform.name}/${locale.languageCode}: profile omits public identity and returns Home',
        (tester) async {
          final fixture = ProfileFixture();
          addTearDown(fixture.close);
          AppLocalization.updateLocale(locale);
          final router = await _mount(tester, fixture, locale: locale);
          addTearDown(router.dispose);
          await tester.tap(find.text('Open profile'));
          await tester.pumpAndSettle();
          final nickname = find.byKey(const ValueKey('profile-nickname-edit'));
          await tester.scrollUntilVisible(
            nickname,
            180,
            scrollable: find
                .descendant(
                  of: find.byType(ProfilePage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.ensureVisible(nickname);
          await tester.pumpAndSettle();
          expect(nickname.hitTestable(), findsOneWidget);
          expect(
            find.byKey(const ValueKey('profile-public-identity')),
            findsNothing,
          );
          expect(find.text('玩家与 Agent 公开身份'), findsNothing);
          expect(find.text('Player and Agent public identities'), findsNothing);
          expect(find.byType(IdentityRoutePage), findsNothing);
          expect(fixture.identityGateway.writes, 0);
          expect(fixture.companionGateway.writes, 0);
          await _back(tester);
          expect(appNavigation.currentRoute, AppRoutes.home);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    for (final initial in [AppRoutes.identity, AppRoutes.settings]) {
      testWidgets('${platform.name}: direct $initial can return home', (
        tester,
      ) async {
        final fixture = ProfileFixture();
        addTearDown(fixture.close);
        final router = await _mount(tester, fixture, initial: initial);
        addTearDown(router.dispose);
        expect(router.canPop(), isFalse);
        if (initial == AppRoutes.identity) {
          expect(appNavigation.currentRoute, AppRoutes.profile);
          expect(find.byType(ProfilePage), findsOneWidget);
          expect(find.byType(IdentityRoutePage), findsNothing);
          expect(find.byKey(const ValueKey('identity-save')), findsNothing);
        }
        await _back(tester);
        expect(appNavigation.currentRoute, AppRoutes.home);
        expect(fixture.identityGateway.writes, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant({platform}));
    }
  }

  testWidgets('first-use back returns to login without bypassing naming', (
    tester,
  ) async {
    final fixture = ProfileFixture();
    addTearDown(fixture.close);
    final gateway = fixture.identityGateway;
    gateway.stored = identityFixture(version: 0, player: '', agent: '');
    final router = await _mount(tester, fixture, initial: AppRoutes.onboarding);
    addTearDown(router.dispose);
    await _back(tester);
    expect(appNavigation.currentRoute, AppRoutes.login);
    appNavigation.go(AppRoutes.home);
    await tester.pumpAndSettle();
    expect(appNavigation.currentRoute, AppRoutes.onboarding);
    expect(gateway.writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));
}
