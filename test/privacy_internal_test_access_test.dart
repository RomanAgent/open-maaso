import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/data/identity_http_client.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/data/privacy_http_client.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

void main() {
  const enabled =
      bool.fromEnvironment('MAASO_INTERNAL_PRIVACY_TEST') &&
      kMaasoStoreInternalBuild;
  late Uri baseUri;
  late String account;
  late int requests;
  late PrivacyService service;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    baseUri = Uri.parse('${MaasoEnvironment.test.baseUrl}/');
    account = 'qa-account';
    requests = 0;
  });
  tearDown(appServices.reset);

  PrivacyService mount() {
    final gateway = PrivacyHttpClient(
      baseUri: () => baseUri,
      accountId: () => account,
      accessToken: () async => 'test-token',
      client: MockClient((_) async {
        requests++;
        return http.Response('404 page not found', 404);
      }),
    );
    return service = appServices.put(
      PrivacyService(gateway: gateway, closeGateway: gateway.close),
    );
  }

  Matcher code(String expected) =>
      isA<PrivacyException>().having((e) => e.code, 'code', expected);

  test(
    'missing endpoint defaults available while QA flags only skip transport',
    () async {
      mount();
      expect(service.isInternalTest, enabled);
      if (enabled) {
        expect(await service.refresh(), isNull);
        await service.requireAge();
        await service.requireConsent(recipientId: 'ark', scope: 'cloud_text');
        await service.requireConsent(
          recipientId: 'volcengine',
          scope: 'cloud_voice',
        );
        await service.requireCloud(
          origin: Uri.parse('https://ark.cn-beijing.volces.com/api/v3'),
          scope: 'cloud_text',
        );
        expect(requests, 0);
        expect(service.canEnterOnlineFeatures, isTrue);
        expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.home);
        expect(
          IdentityRoutePolicy.redirect(AppRouteCatalog.onboarding),
          isNull,
        );
      } else {
        await expectLater(
          service.refresh(),
          throwsA(code('PRIVACY_UNAVAILABLE')),
        );
        await service.requireAge();
        expect(requests, 2);
        expect(service.canEnterOnlineFeatures, isTrue);
        expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.home);
        expect(
          IdentityRoutePolicy.redirect(AppRouteCatalog.onboarding),
          isNull,
        );
      }
      // The exemption cannot be mistaken for a user's age/permission declaration.
      expect(service.ageEligible, isFalse);
      expect(service.snapshot, isNull);
      expect(service.publicPolicy, isNull);
    },
  );

  for (final url in [
    '${MaasoEnvironment.production.baseUrl}/',
    'https://api-test.futurpals.com.cn.attacker.test/',
    'https://api-test.futurpals.com.cn:444/',
    'http://api-test.futurpals.com.cn/',
    'https://api-test.futurpals.com.cn/other/',
    'https://user@api-test.futurpals.com.cn/',
  ]) {
    test('flags never exempt a different API base: $url', () async {
      baseUri = Uri.parse(url);
      mount();
      expect(service.isInternalTest, isFalse);
      await service.requireAge();
      expect(requests, 1);
      expect(service.canEnterOnlineFeatures, isTrue);
    });
  }

  test(
    'fresh test install still performs one-time naming with identity API absent',
    () async {
      mount();
      final gateway = IdentityHttpClient(
        baseUri: () => baseUri,
        accountId: () => account,
        accessToken: () async => 'test-token',
        client: MockClient(
          (_) async => http.Response('404 page not found', 404),
        ),
      );
      final identity = appServices.put(
        IdentityService(
          gateway: gateway,
          closeGateway: gateway.close,
          hasLocalCompanion: () => false,
        ),
      );
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.onboarding);
      await expectLater(identity.load(), throwsA(isA<IdentityException>()));
      expect(identity.canContinueLocally, isFalse);
      expect(identity.profile, isNull);
      expect(identity.completed, isFalse);
      for (final route in [AppRouteCatalog.home, AppRouteCatalog.settings]) {
        expect(IdentityRoutePolicy.redirect(route), AppRouteCatalog.onboarding);
      }
      for (final route in [
        AppRouteCatalog.agentSpace,
        AppRouteCatalog.gameFeed,
      ]) {
        expect(IdentityRoutePolicy.redirect(route), AppRouteCatalog.onboarding);
      }
      baseUri = Uri.parse('${MaasoEnvironment.production.baseUrl}/');
      expect(
        IdentityRoutePolicy.redirect(AppRouteCatalog.home),
        AppRouteCatalog.onboarding,
      );
    },
  );

  test('test access still requires an account', () async {
    account = '';
    mount();
    await expectLater(
      service.requireAge(),
      throwsA(code('PRIVACY_AUTHENTICATION_REQUIRED')),
    );
    await expectLater(
      service.requireConsent(recipientId: 'ark', scope: 'cloud_text'),
      throwsA(code('PRIVACY_AUTHENTICATION_REQUIRED')),
    );
    expect(service.canEnterOnlineFeatures, isFalse);
    expect(requests, 0);
  });

  for (final change in ['account', 'environment', 'retire']) {
    test('old test access is invalid after $change changes', () async {
      mount();
      switch (change) {
        case 'account':
          account = 'other-account';
        case 'environment':
          baseUri = Uri.parse('${MaasoEnvironment.production.baseUrl}/');
        case 'retire':
          service.onClose();
      }
      expect(service.isInternalTest, isFalse);
      expect(service.canEnterOnlineFeatures, isFalse);
      await expectLater(
        service.requireConsent(recipientId: 'ark', scope: 'cloud_text'),
        throwsA(code('PRIVACY_CONTEXT_CHANGED')),
      );
      expect(requests, 0);
    });
  }

  test('internal test mode retains destination and scope validation', () async {
    mount();
    await expectLater(
      service.requireCloud(
        origin: Uri.parse('http://cloud.test'),
        scope: 'cloud_text',
      ),
      throwsA(code('PRIVACY_UNAVAILABLE')),
    );
    await expectLater(
      service.requireCloud(
        origin: Uri.parse('https://cloud.test'),
        scope: 'unknown',
      ),
      throwsA(code('PRIVACY_UNAVAILABLE')),
    );
    await expectLater(
      service.requireConsent(
        recipientId: 'invalid recipient',
        scope: 'cloud_text',
      ),
      throwsA(code('PRIVACY_UNAVAILABLE')),
    );
    expect(requests, 0);
  });
}
