import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/features/privacy/presentation/privacy_page.dart';
import 'identity_test_support.dart';
import 'privacy_models_test.dart' show privacySnapshotJson;
import 'privacy_service_test.dart' show PrivacyFake;

class _PolicyFailureGateway extends PrivacyFake {
  Future<PrivacyPublicPolicy> Function()? policyOperation;
  @override
  Future<PrivacyPublicPolicy> policy({
    required String expectedContextKey,
  }) async {
    policies++;
    return policyOperation == null ? currentPolicy : await policyOperation!();
  }
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  for (final platform in [AppHostPlatform.ios, AppHostPlatform.macos]) {
    for (final state in ['unconfigured', 'loading', 'failed']) {
      testWidgets(
        '$platform $state privacy still allows Continue and secondary routes',
        (tester) async {
          final gate = _PolicyFailureGateway()
            ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false});
          Completer<PrivacyPublicPolicy>? loading;
          if (state == 'loading') {
            loading = Completer<PrivacyPublicPolicy>();
            gate.policyOperation = () => loading!.future;
          }
          if (state == 'failed') {
            gate.policyOperation = () async =>
                throw const PrivacyException('PRIVACY_UNAVAILABLE');
          }
          final service = appServices.put(PrivacyService(gateway: gate));
          final identity = appServices.put(
            IdentityService(
              gateway: FakeIdentityGateway(initial: identityFixture()),
            ),
          );
          await identity.load();
          const destinations = [
            AppRouteCatalog.settings,
            AppRouteCatalog.widgetsHub,
            AppRouteCatalog.gameFeed,
          ];
          final router = createAppRouter(
            initialLocation: AppRouteCatalog.privacy,
            platformCapabilities: AppPlatformCapabilities.forPlatform(platform),
            routesOverride: [
              GoRoute(
                path: AppRouteCatalog.privacy,
                builder: (_, _) => PrivacyPage(service: service),
              ),
              GoRoute(
                path: AppRouteCatalog.home,
                builder: (_, _) => const Scaffold(body: Text('Companion home')),
              ),
              for (final path in destinations)
                GoRoute(
                  path: path,
                  builder: (_, _) => Scaffold(body: Text('Opened $path')),
                ),
            ],
          );
          await tester.pumpWidget(
            ProviderScope(child: MaterialApp.router(routerConfig: router)),
          );
          if (state == 'loading') {
            await tester.pump();
          } else {
            await tester.pumpAndSettle();
          }
          expect(service.canEnterOnlineFeatures, isTrue);
          expect(service.ageEligible, isFalse);
          expect(service.snapshot, isNull);
          expect(find.textContaining('operator’s'), findsNothing);
          expect(find.textContaining('unavailable'), findsNothing);
          expect(find.byKey(const Key('privacy-birth-date')), findsNothing);
          final continueButton = find.byKey(const Key('privacy-continue'));
          await tester.ensureVisible(continueButton);
          expect(
            tester.widget<FilledButton>(continueButton).onPressed,
            isNotNull,
          );
          await tester.tap(continueButton);
          await tester.pumpAndSettle();
          expect(appNavigation.currentRoute, AppRouteCatalog.home);
          for (final path in destinations) {
            router.go(path);
            await tester.pumpAndSettle();
            expect(appNavigation.currentRoute, path);
            expect(find.text('Opened $path'), findsOneWidget);
          }
          loading?.complete(PrivacyPublicPolicy.fromJson({'ready': false}));
          await tester.pump();
          expect(
            gate.writes,
            0,
            reason: 'navigation never fabricates consent or a birthday',
          );
          await tester.pumpWidget(const SizedBox());
          router.dispose();
        },
      );
    }
  }

  testWidgets('a saved off choice remains visibly off when refresh fails', (
    tester,
  ) async {
    final gate = _PolicyFailureGateway()
      ..value = PrivacySnapshot.fromJson(privacySnapshotJson(allow: false));
    final service = appServices.put(PrivacyService(gateway: gate));
    await service.refresh();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: PrivacyPage(service: service)),
      ),
    );
    await tester.pumpAndSettle();
    final choice = find.byKey(const Key('privacy-choice-provider-cloud_text'));
    await tester.ensureVisible(choice);
    expect(
      find.descendant(of: choice, matching: find.text('Off · Review')),
      findsOneWidget,
    );
    gate.reading = () async =>
        throw const PrivacyException('PRIVACY_UNAVAILABLE');
    final refresh = find.byKey(const Key('privacy-refresh'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(
      choice,
      findsNothing,
      reason: 'unknown snapshot never fabricates permission rows',
    );
    expect(find.byKey(const Key('privacy-notice')), findsOneWidget);
    expect(
      service.allowsLoadedConsent(
        recipientId: 'provider',
        scope: PrivacyScopes.cloudText,
      ),
      isFalse,
    );
    expect(gate.writes, 0);
    expect(find.textContaining('services are unavailable'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'production global ProviderScope defers initial privacy and identity work until first frame',
    (tester) async {
      appServices.testMode = false;
      final loading = Completer<PrivacyPublicPolicy>();
      final gate = _PolicyFailureGateway()
        ..policyOperation = () => loading.future;
      final service = appServices.put(PrivacyService(gateway: gate));
      final identityGateway = FakeIdentityGateway(initial: identityFixture());
      appServices.put(IdentityService(gateway: identityGateway));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: PrivacyPage()),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason:
            'initState must not publish loading state while the first widget tree is building',
      );
      await tester.pump();
      expect(service.loading, isTrue);
      expect(gate.policies, 1);
      loading.complete(PrivacyPublicPolicy.fromJson({'ready': false}));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(service.canEnterOnlineFeatures, isTrue);
      expect(identityGateway.reads, 1);
      expect(gate.writes, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
