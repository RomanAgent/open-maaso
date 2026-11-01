import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'privacy_service_test.dart' show PrivacyFake;
import 'privacy_models_test.dart' show privacySnapshotJson;
import 'privacy_gateway_test.dart' show privacyCode;

void main() {
  final endpoint = Uri.parse('https://api.cloud.test/v1/chat/completions');
  test(
    'unread configuration permits account pages without inventing consent',
    () {
      final gateway = PrivacyFake();
      final service = PrivacyService(gateway: gateway);
      expect(service.canEnterOnlineFeatures, isTrue);
      expect(
        service.allowsLoadedConsent(
          recipientId: 'provider',
          scope: 'cloud_text',
        ),
        isTrue,
      );
      expect(service.snapshot, isNull);
      expect(service.ageEligible, isFalse);
      expect(gateway.reads + gateway.policies + gateway.writes, 0);
    },
  );
  test(
    'operator unconfigured permits use and keeps disclosures absent',
    () async {
      final gateway = PrivacyFake()
        ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false});
      final service = PrivacyService(gateway: gateway);
      await service.refresh();
      expect(service.canEnterOnlineFeatures, isTrue);
      await service.requireAge();
      await service.requireConsent(recipientId: 'ark', scope: 'cloud_text');
      await service.requireCloud(origin: endpoint, scope: 'cloud_text');
      expect(service.publicPolicy?.ready, isFalse);
      expect(service.snapshot, isNull);
      expect(service.ageEligible, isFalse);
      expect(gateway.writes, 0);
    },
  );
  test('policy transport failure does not disable features', () async {
    final gateway = PrivacyFake()
      ..reading = () async =>
          throw const PrivacyException('PRIVACY_UNAVAILABLE');
    final service = PrivacyService(gateway: gateway);
    await expectLater(
      service.refresh(),
      throwsA(privacyCode('PRIVACY_UNAVAILABLE')),
    );
    expect(service.canEnterOnlineFeatures, isTrue);
    await service.requireAge();
    await service.requireConsent(recipientId: 'ark', scope: 'cloud_text');
    await service.requireCloud(origin: endpoint, scope: 'cloud_text');
    expect(gateway.writes, 0);
  });
  test(
    'missing declarations default available without an age declaration',
    () async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson({
          ...privacySnapshotJson(age: 'unconfirmed'),
          'consents': <Object?>[],
        });
      final service = PrivacyService(gateway: gateway);
      await service.refresh();
      await service.requireAge();
      await service.requireConsent(
        recipientId: 'new_provider',
        scope: 'cloud_image',
      );
      await service.requireCloud(
        origin: Uri.parse('https://configured-by-user.example/v1'),
        scope: 'cloud_text',
      );
      expect(service.canEnterOnlineFeatures, isTrue);
      expect(service.snapshot!.consents, isEmpty);
      expect(service.snapshot!.declaredAt, isNull);
      expect(gateway.writes, 0);
    },
  );
  test('expired grant is distinct from explicit withdrawal', () async {
    for (final declared in [null, true, false]) {
      final raw = privacySnapshotJson(allow: false, current: false);
      final entry = (raw['consents']! as List).single as Map<String, Object?>;
      if (declared != null) entry['explicitAllowed'] = declared;
      final gateway = PrivacyFake()..value = PrivacySnapshot.fromJson(raw);
      final service = PrivacyService(gateway: gateway);
      if (declared == false) {
        await expectLater(
          service.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
          throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
        );
      } else {
        await service.requireConsent(
          recipientId: 'provider',
          scope: 'cloud_text',
        );
      }
    }
  });
  test('known explicit withdrawal survives failed and older reads', () async {
    final gateway = PrivacyFake()
      ..value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 3, allow: false),
      );
    final service = PrivacyService(gateway: gateway);
    await service.refresh();
    gateway.reading = () async =>
        throw const PrivacyException('PRIVACY_UNAVAILABLE');
    await expectLater(
      service.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
      throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
    );
    await expectLater(
      service.requireCloud(origin: endpoint, scope: 'cloud_text'),
      throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
    );
    gateway.reading = null;
    gateway.value = PrivacySnapshot.fromJson(privacySnapshotJson(revision: 2));
    await expectLater(
      service.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
      throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
    );
    expect(
      service.allowsLoadedConsent(recipientId: 'provider', scope: 'cloud_text'),
      isFalse,
    );
  });
  test(
    'invalid policy response cannot clear a remembered withdrawal',
    () async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(
          privacySnapshotJson(revision: 3, allow: false),
        );
      final service = PrivacyService(gateway: gateway);
      await service.refresh();
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 4, hash: 'b' * 64),
      );
      await expectLater(
        service.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      expect(
        service.allowsLoadedConsent(
          recipientId: 'provider',
          scope: 'cloud_text',
        ),
        isFalse,
      );
    },
  );
  test('same-revision contradictory grant cannot clear a withdrawal', () async {
    final gateway = PrivacyFake()
      ..value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 3, allow: false),
      );
    final service = PrivacyService(gateway: gateway);
    await service.refresh();
    gateway.value = PrivacySnapshot.fromJson(privacySnapshotJson(revision: 3));
    await expectLater(
      service.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
      throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
    );
    gateway.value = PrivacySnapshot.fromJson(privacySnapshotJson(revision: 4));
    await service.requireConsent(recipientId: 'provider', scope: 'cloud_text');
  });
  test(
    'authoritative explicit rejection is never converted into a default',
    () async {
      for (final code in [
        'PRIVACY_CONSENT_REQUIRED',
        'PRIVACY_AGE_INELIGIBLE',
      ]) {
        final gateway = PrivacyFake()
          ..reading = () async => throw PrivacyException(code);
        final service = PrivacyService(gateway: gateway);
        await expectLater(
          service.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
          throwsA(privacyCode(code)),
        );
      }
    },
  );
  test(
    'account authentication, retirement and explicit ineligibility remain real',
    () async {
      final gateway = PrivacyFake()..hasAccount = false;
      final service = PrivacyService(gateway: gateway);
      await expectLater(
        service.requireAge(),
        throwsA(privacyCode('PRIVACY_AUTHENTICATION_REQUIRED')),
      );
      gateway.hasAccount = true;
      gateway.reading = () async =>
          throw const PrivacyException('PRIVACY_AUTHENTICATION_REQUIRED');
      await expectLater(
        service.requireAge(),
        throwsA(privacyCode('PRIVACY_AUTHENTICATION_REQUIRED')),
      );
      gateway.reading = null;
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(age: 'ineligible', allow: false),
      );
      await expectLater(
        service.requireAge(),
        throwsA(privacyCode('PRIVACY_AGE_INELIGIBLE')),
      );
      expect(service.canEnterOnlineFeatures, isFalse);
      service.onClose();
      await expectLater(
        service.requireAge(),
        throwsA(privacyCode('PRIVACY_CONTEXT_CHANGED')),
      );
    },
  );
}
