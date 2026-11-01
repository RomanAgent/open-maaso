import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/features/privacy/presentation/privacy_page.dart';
import 'package:maaso/src/features/privacy/presentation/privacy_page_adapter.dart';

import 'privacy_service_test.dart' show PrivacyFake;

const _internalBuild =
    bool.fromEnvironment('MAASO_STORE_INTERNAL_BUILD') &&
    bool.fromEnvironment('MAASO_INTERNAL_PRIVACY_TEST');

PrivacyFake _gateway({
  bool account = true,
  bool production = false,
}) => PrivacyFake()
  ..requestContextKey =
      '${(production ? MaasoEnvironment.production : MaasoEnvironment.test).baseUrl}/|${account ? 'account' : ''}'
  ..hasAccount = account
  ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false});

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  for (final account in [true, false]) {
    testWidgets(
      'test privacy page routes account=$account without fabricated choices',
      (tester) async {
        final gateway = _gateway(account: account);
        final service = PrivacyService(gateway: gateway);
        final router = GoRouter(
          initialLocation: AppRouteCatalog.privacy,
          routes: [
            GoRoute(
              path: AppRouteCatalog.privacy,
              builder: (_, _) => PrivacyPage(service: service),
            ),
            GoRoute(
              path: AppRouteCatalog.home,
              builder: (_, _) => const Scaffold(body: Text('Home')),
            ),
            GoRoute(
              path: AppRouteCatalog.login,
              builder: (_, _) => const Scaffold(body: Text('Login')),
            ),
          ],
        );
        appNavigation.configure(router);
        await tester.pumpWidget(
          ProviderScope(child: MaterialApp.router(routerConfig: router)),
        );
        await tester.pumpAndSettle();

        expect(service.ageEligible, isFalse);
        expect(service.snapshot, isNull);
        expect(find.byType(CheckboxListTile), findsNothing);
        expect(find.byKey(const Key('privacy-birth-date')), findsNothing);
        expect(gateway.reads + gateway.writes, 0);
        if (_internalBuild) {
          expect(gateway.policies, 0);
          expect(
            find.byKey(const Key('privacy-internal-test-info')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('privacy-refresh')), findsNothing);
          expect(find.textContaining('unavailable'), findsNothing);
          expect(find.textContaining('not configured'), findsNothing);
          expect(find.text(account ? 'Continue' : 'Sign in'), findsOneWidget);
          await tester.tap(
            find.byKey(const Key('privacy-internal-test-continue')),
          );
          await tester.pumpAndSettle();
          expect(
            appNavigation.currentRoute,
            account ? AppRouteCatalog.home : AppRouteCatalog.login,
          );
          expect(gateway.policies + gateway.reads + gateway.writes, 0);
        } else {
          expect(gateway.policies, 1);
          expect(
            find.byKey(const Key('privacy-default-available')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('privacy-internal-test-info')),
            findsNothing,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        service.onClose();
      },
    );
  }

  testWidgets(
    'production endpoint remains usable without fabricated configuration',
    (tester) async {
      final gateway = _gateway(production: true);
      final service = PrivacyService(gateway: gateway);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: PrivacyPage(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('privacy-default-available')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('privacy-internal-test-info')), findsNothing);
      expect(find.byKey(const Key('privacy-refresh')), findsOneWidget);
      expect(service.ageEligible, isFalse);
      expect(service.snapshot, isNull);
      expect(gateway.policies, 1);
      expect(gateway.reads + gateway.writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      service.onClose();
    },
  );

  testWidgets(
    'internal test page has no hidden AppControl privacy status action',
    (tester) async {
      final gateway = _gateway();
      final service = PrivacyService(gateway: gateway);
      final control = AgentUiControlService();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PrivacyPage(service: service, uiControl: control),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final lease = control.coordinator
          .begin(
            sessionId: 'internal-privacy-test',
            purpose: 'Inspect internal test page',
            targetRoute: AppRouteCatalog.privacy,
          )
          .value!;
      final adapter = control.adapters
          .resolve<PrivacyPageAdapter>(
            route: AppRouteCatalog.privacy,
            lease: lease,
          )
          .value!;
      expect(adapter.appControlActions, isEmpty);
      expect(find.byKey(const Key('privacy-refresh')), findsNothing);
      final result = await adapter.executeAppControlAction(
        lease: lease,
        actionId: PrivacyPageAdapter.refreshAction,
        arguments: const {},
        executionContext: AppControlActionExecutionContext.host(
          requiresCommit: false,
          authorityIsCurrent: () => true,
          staleCode: 'stale',
        ),
      );
      expect(result.isSuccess, isFalse);
      expect(gateway.policies + gateway.reads + gateway.writes, 0);
      expect(service.snapshot, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(control.adapters.length, 0);
      await control.coordinator.dispose();
      service.onClose();
    },
    skip: !_internalBuild,
  );

  testWidgets('internal test page fits compact landscape with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(812, 375);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = PrivacyService(gateway: _gateway());
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: PrivacyPage(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('privacy-internal-test-continue')),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Continue'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    service.onClose();
  }, skip: !_internalBuild);
}
