import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/features/privacy/presentation/privacy_page.dart';
import 'privacy_models_test.dart' show privacySnapshotJson;
import 'privacy_service_test.dart' show PrivacyFake;

Future<void> _mount(
  WidgetTester tester,
  PrivacyService service, {
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: PrivacyPage(service: service, openUrl: (_) async => true),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  testWidgets(
    'age form needs human confirmation and submits reviewed version',
    (tester) async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(
          privacySnapshotJson(age: 'unconfirmed', allow: false),
        );
      gateway.writing = () async => gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 2, allow: false),
      );
      final service = PrivacyService(gateway: gateway);
      await _mount(tester, service);
      final submit = find.byKey(const Key('privacy-age-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('privacy-birth-date')),
        '2000-01-02',
      );
      expect(gateway.writes, 0);
      await tester.ensureVisible(find.byKey(const Key('privacy-age-confirm')));
      await tester.tap(find.byKey(const Key('privacy-age-confirm')));
      await tester.pump();
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(gateway.writes, 1);
      expect(gateway.sent?['birthDate'], '2000-01-02');
      expect(gateway.sent?['version'], 'v1');
      expect(service.ageEligible, isTrue);
      expect(find.byKey(const Key('privacy-birth-date')), findsNothing);
    },
  );

  testWidgets(
    'consent preview begins unchecked and only a confirmed user tap writes',
    (tester) async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(privacySnapshotJson(allow: false));
      gateway.writing = () async => gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 2),
      );
      final service = PrivacyService(gateway: gateway);
      await _mount(tester, service);
      final choice = find.byKey(
        const Key('privacy-choice-provider-cloud_text'),
      );
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(gateway.writes, 0);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('privacy-consent-confirm')),
            )
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('privacy-consent-submit')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('privacy-consent-confirm')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('privacy-consent-submit')));
      await tester.pumpAndSettle();
      expect(gateway.writes, 1);
      expect(gateway.sent?['allow'], isTrue);
      expect(gateway.sent?['scope'], 'cloud_text');
    },
  );

  testWidgets(
    'account change while preview is open cannot submit its consent',
    (tester) async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(privacySnapshotJson(allow: false));
      final service = PrivacyService(gateway: gateway);
      await _mount(tester, service);
      final choice = find.byKey(
        const Key('privacy-choice-provider-cloud_text'),
      );
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      gateway.requestContextKey = 'test|different-account';
      await tester.tap(find.byKey(const Key('privacy-consent-confirm')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('privacy-consent-submit')));
      await tester.pumpAndSettle();
      expect(gateway.writes, 0);
      expect(find.textContaining('account session changed'), findsOneWidget);
    },
  );

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(1024, 768),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('privacy layout $size $brightness supports large text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = PrivacyService(gateway: PrivacyFake());
        await _mount(tester, service, scale: 2, brightness: brightness);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView).first, const Offset(0, -1500));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'anonymous unconfigured policy never shows fabricated disclosures or choices',
    (tester) async {
      final gateway = PrivacyFake()
        ..hasAccount = false
        ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false});
      await _mount(tester, PrivacyService(gateway: gateway));
      expect(
        find.byKey(const Key('privacy-default-available')),
        findsOneWidget,
      );
      expect(find.text('Test Operator'), findsNothing);
      expect(gateway.reads + gateway.writes, 0);
      expect(find.byType(CheckboxListTile), findsNothing);
    },
  );

  test(
    'privacy and secondary routes remain reachable before an age declaration',
    () async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(
          privacySnapshotJson(age: 'unconfirmed', allow: false),
        );
      final service = appServices.put(PrivacyService(gateway: gateway));
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.home);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.privacy), isNull);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.agentSpace), isNull);
      expect(
        IdentityRoutePolicy.redirect('/wallet'),
        isNull,
        reason:
            'The router normalizes legacy paths when access is unrestricted.',
      );
      gateway.value = PrivacySnapshot.fromJson(privacySnapshotJson());
      await service.refresh();
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.agentSpace), isNull);
      expect(
        AppRouteCatalog.resolveCommand('privacy'),
        AppRouteCatalog.privacy,
      );
    },
  );

  test('retired wallet has no account-read privacy exemption', () async {
    final gateway = PrivacyFake()
      ..value = PrivacySnapshot.fromJson(
        privacySnapshotJson(age: 'ineligible', allow: false),
      );
    final service = appServices.put(PrivacyService(gateway: gateway));
    await service.refresh();

    expect(service.canEnterOnlineFeatures, isFalse);
    expect(IdentityRoutePolicy.redirect('/wallet'), AppRouteCatalog.privacy);
    expect(IdentityRoutePolicy.redirect(AppRouteCatalog.profile), isNull);
    expect(IdentityRoutePolicy.redirect(AppRouteCatalog.membership), isNull);
  });
}
