import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skills/set_soul_skill.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/identity/presentation/identity_setup_page.dart';

import 'identity_test_support.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'missing server profile gates all routes and never enables local skip',
    () async {
      final service = appServices.put(
        IdentityService(
          gateway: FakeIdentityGateway(),
          hasLocalCompanion: () => true,
        ),
      );
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.onboarding);
      await service.load();
      expect(service.continueLocally(), isFalse);
      for (final route in [
        AppRouteCatalog.home,
        AppRouteCatalog.agentSpace,
        AppRouteCatalog.identity,
        AppRouteCatalog.gameFeed,
      ]) {
        expect(IdentityRoutePolicy.redirect(route), AppRouteCatalog.onboarding);
      }
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.login), isNull);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.onboarding), isNull);
    },
  );

  test(
    'local fallback requires failed read and old companion, then only private routes',
    () async {
      final gateway = FakeIdentityGateway()
        ..fetchOverride = () async =>
            throw const IdentityException(IdentityFailure.unavailable);
      final service = appServices.put(
        IdentityService(gateway: gateway, hasLocalCompanion: () => true),
      );
      expect(service.continueLocally(), isFalse);
      await expectLater(service.load(), throwsA(isA<IdentityException>()));
      expect(service.continueLocally(), isTrue);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.home), isNull);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.settings), isNull);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.agentSpace), isNull);
      expect(
        IdentityRoutePolicy.redirect(AppRouteCatalog.gameFeed),
        AppRouteCatalog.onboarding,
      );
      gateway.fetchOverride = null;
      await service.load();
      expect(service.localCompanionEnabled, isFalse);
      expect(service.canContinueLocally, isFalse);
    },
  );

  test(
    'authentication rejection and new accounts cannot use local fallback',
    () async {
      for (final failure in [
        IdentityFailure.authenticationRequired,
        IdentityFailure.unavailable,
      ]) {
        final gateway = FakeIdentityGateway()
          ..fetchOverride = () async => throw IdentityException(failure);
        final service = IdentityService(
          gateway: gateway,
          hasLocalCompanion: () => failure != IdentityFailure.unavailable,
        );
        await expectLater(service.load(), throwsA(isA<IdentityException>()));
        expect(service.continueLocally(), isFalse);
      }
    },
  );

  test(
    'projection failure keeps confirmed revision and retry does not write twice',
    () async {
      final gateway = FakeIdentityGateway();
      var fail = true;
      var projected = '';
      final service = IdentityService(
        gateway: gateway,
        projectProfile: (profile) async {
          if (fail) throw StateError('storage unavailable');
          projected = profile.agentName;
        },
      );
      await service.load();
      await expectLater(
        service.save(playerName: 'Star', agentName: 'Rice'),
        throwsStateError,
      );
      expect(service.profile?.version, 1);
      expect(service.completed, isFalse);
      fail = false;
      await service.save(playerName: 'Star', agentName: 'Rice');
      expect(gateway.writes, 1);
      expect(projected, 'Rice');
      expect(service.completed, isTrue);
    },
  );

  test('in-flight projection cannot admit an old account', () async {
    final pending = Completer<void>();
    final gateway = FakeIdentityGateway(initial: identityFixture());
    final service = IdentityService(
      gateway: gateway,
      projectProfile: (_) => pending.future,
    );
    final load = service.load();
    await Future<void>.delayed(Duration.zero);
    expect(service.completed, isFalse);
    gateway.requestContextKey = 'test|account-b';
    pending.complete();
    await expectLater(load, throwsA(isA<IdentityException>()));
    expect(service.completed, isFalse);
    expect(service.profile, isNull);
  });

  testWidgets(
    'router blocks a public deep link then admits completed identity',
    (tester) async {
      final service = appServices.put(
        IdentityService(gateway: FakeIdentityGateway()),
      );
      final router = createAppRouter(
        initialLocation: AppRouteCatalog.gameFeed,
        routesOverride: [
          for (final path in [
            AppRouteCatalog.gameFeed,
            AppRouteCatalog.onboarding,
            AppRouteCatalog.home,
          ])
            GoRoute(
              path: path,
              builder: (_, _) => Scaffold(body: Text(path)),
            ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        AppRouteCatalog.onboarding,
      );
      await service.load();
      await service.save(playerName: 'Star', agentName: 'Rice');
      router.go(AppRouteCatalog.gameFeed);
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        AppRouteCatalog.gameFeed,
      );
    },
  );

  testWidgets('complete profile resumes automatically without a new revision', (
    tester,
  ) async {
    final gateway = FakeIdentityGateway(initial: identityFixture());
    final controller = IdentitySetupController(
      service: IdentityService(gateway: gateway),
    );
    var completions = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: IdentitySetupPage(
            controller: controller,
            route: AppRouteCatalog.onboarding,
            autoComplete: true,
            onCompleted: (_) async {
              completions++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(completions, 1);
    expect(gateway.writes, 0);
  });

  test(
    'SetSoul keeps the setup name without linking to the retired page',
    () async {
      final service = appServices.put(
        IdentityService(
          gateway: FakeIdentityGateway(initial: identityFixture()),
        ),
      );
      await service.load();
      final result = jsonDecode(
        await SetSoulSkill().methods['setSoul']!([
              jsonEncode({'name': 'Hidden rename'}),
            ])
            as String,
      );
      expect(result['status'], 'agent_name_from_setup');
      expect(result.containsKey('route'), isFalse);
      expect(result['agentName'], 'Wheat');
      expect(result['message'], isNotEmpty);
      final chineseResult = jsonDecode(
        await AgentPromptCatalog.runWithLocale(
              AppLocale.zh,
              () => SetSoulSkill().methods['setSoul']!([
                jsonEncode({'name': 'Hidden rename'}),
              ]),
            )
            as String,
      );
      expect(chineseResult['status'], result['status']);
      expect(chineseResult['route'], result['route']);
      expect(chineseResult['message'], contains('初始化 App 时设置的名字'));
      expect(service.profile?.agentName, 'Wheat');
    },
  );

  test('SetSoul points an unnamed account to initial setup', () async {
    final gateway = FakeIdentityGateway();
    final service = appServices.put(IdentityService(gateway: gateway));
    await service.load();
    final result = jsonDecode(
      await SetSoulSkill().methods['setSoul']!([
            jsonEncode({'name': 'Unconfirmed'}),
          ])
          as String,
    );
    expect(result['status'], 'agent_setup_required');
    expect(result['route'], AppRouteCatalog.onboarding);
    expect(result['message'], isNotEmpty);
    expect(gateway.writes, 0);
    expect(service.onboardingCompleted, isFalse);
    expect(service.setupAgentName, isEmpty);
  });

  testWidgets('failed load keeps retry and account recovery visible', (
    tester,
  ) async {
    final gateway = FakeIdentityGateway()
      ..fetchOverride = () async =>
          throw const IdentityException(IdentityFailure.unavailable);
    final controller = IdentitySetupController(
      service: IdentityService(gateway: gateway, hasLocalCompanion: () => true),
    );
    var switchedAccount = false;
    var continued = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: IdentitySetupPage(
            controller: controller,
            route: AppRouteCatalog.onboarding,
            onCompleted: (_) async {},
            onChangeAccount: () => switchedAccount = true,
            onContinueLocally: () =>
                continued = controller.service.continueLocally(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('identity-retry')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('identity-continue-local')),
    );
    await tester.tap(find.byKey(const ValueKey('identity-continue-local')));
    expect(continued, isTrue);
    await tester.ensureVisible(
      find.byKey(const ValueKey('identity-change-account')),
    );
    await tester.tap(find.byKey(const ValueKey('identity-change-account')));
    expect(switchedAccount, isTrue);
    expect(gateway.writes, 0);
  });

  test(
    'Applet attribution accepts named authors and explicit roles, preserving old comments',
    () {
      final author = AppletCatalogAuthor.fromJson({
        'agentId': identityFixture().agentActorId,
        'displayName': '小麦  🌾',
        'verified': false,
      });
      expect(author.displayName, '小麦  🌾');
      final old = <String, Object?>{
        'id': 'c1',
        'displayName': 'Legacy player',
        'text': 'Hello',
        'createdAt': '2026-09-12T00:00:00Z',
      };
      expect(AppletComment.fromJson(old).actorKind, IdentityActorKind.player);
      expect(
        AppletComment.fromJson({
          ...old,
          'displayName': 'Star  Child',
          'actorId': 'public-player',
          'actorKind': 'user',
        }).displayName,
        'Star  Child',
      );
      expect(
        AppletComment.fromJson({
          ...old,
          'actorId': 'public-agent',
          'actorKind': 'agent',
        }).actorKind,
        IdentityActorKind.agent,
      );
      expect(
        AppletComment.fromJson({
          ...old,
          'actorId': 'public-player',
          'actorKind': 'user',
        }).actorKind,
        IdentityActorKind.player,
      );
      for (final extra in [
        {'actorId': 'unpaired'},
        {'actorKind': 'agent'},
        {'actorId': 'id', 'actorKind': 'admin'},
        {'actorId': '', 'actorKind': 'user'},
      ]) {
        expect(
          () => AppletComment.fromJson({...old, ...extra}),
          throwsFormatException,
        );
      }
    },
  );
}
