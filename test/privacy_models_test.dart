import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

Map<String, Object?> privacyPolicyJson({
  String version = 'v1',
  String hash = '',
  String effectiveAt = '2026-01-01T00:00:00Z',
}) => {
  'ready': true,
  'policyHash': hash.isEmpty ? List.filled(64, 'a').join() : hash,
  'policy': {
    'version': version,
    'effectiveAt': effectiveAt,
    'operatorName': 'Test Operator',
    'supportEmail': 'support@maaso.test',
    'privacyUrl': 'https://maaso.test/privacy',
    'termsUrl': 'https://maaso.test/terms',
    'minimumAge': 18,
    'recipients': [
      {
        'id': 'provider',
        'name': 'Test Provider',
        'policyUrl': 'https://cloud.test/privacy',
        'apiOrigins': ['https://api.cloud.test'],
        'scopes': ['cloud_text', 'cloud_voice'],
        'dataCategories': ['Messages'],
      },
    ],
  },
};

Map<String, Object?> privacySnapshotJson({
  int revision = 1,
  String age = 'eligible',
  bool allow = true,
  bool current = true,
  String version = 'v1',
  String hash = '',
  String effectiveAt = '2026-01-01T00:00:00Z',
}) => {
  ...privacyPolicyJson(version: version, hash: hash, effectiveAt: effectiveAt),
  'revision': revision,
  'ageStatus': age,
  if (age != 'unconfirmed') 'declaredAt': '2026-01-02T00:00:00Z',
  'consents': [
    {
      'recipientId': 'provider',
      'scope': 'cloud_text',
      'allowed': allow,
      'current': current,
      'updatedAt': '2026-01-02T00:00:00Z',
    },
  ],
};

void main() {
  test('unconfigured policy does not fabricate operator or age defaults', () {
    final value = PrivacyPublicPolicy.fromJson({'ready': false});
    expect(value.ready, isFalse);
    expect(value.policy, isNull);
    expect(value.policyHash, isNull);
    expect(
      () => PrivacyPublicPolicy.fromJson({'ready': false, 'policy': {}}),
      throwsFormatException,
    );
  });
  test('valid disclosure and consent are immutable and typed', () {
    final raw = privacySnapshotJson();
    final value = PrivacySnapshot.fromJson(raw);
    expect(value.ageEligible, isTrue);
    expect(value.allows('provider', PrivacyScopes.cloudText), isTrue);
    expect(value.allows('provider', PrivacyScopes.cloudVoice), isTrue);
    expect(value.explicitChoice('provider', PrivacyScopes.cloudVoice), isNull);
    expect(() => value.policy!.recipients.clear(), throwsUnsupportedError);
    expect(() => value.consents.clear(), throwsUnsupportedError);
    ((raw['policy'] as Map)['recipients'] as List).clear();
    expect(value.policy!.recipients, hasLength(1));
  });
  test('integer and boolean coercions never grant access', () {
    for (final raw in [
      {...privacySnapshotJson(), 'revision': '1'},
      {...privacySnapshotJson(), 'revision': 1.0},
      {...privacySnapshotJson(), 'revision': -1},
      {...privacySnapshotJson(), 'revision': 9007199254740992},
      {...privacySnapshotJson(), 'ready': 'true'},
    ]) {
      expect(() => PrivacySnapshot.fromJson(raw), throwsFormatException);
    }
    for (final allowed in ['true', 1, null]) {
      final raw = privacySnapshotJson();
      raw['consents'] = [
        <String, Object?>{
          ...Map<String, Object?>.from((raw['consents'] as List).first as Map),
          'allowed': allowed,
        },
      ];
      expect(() => PrivacySnapshot.fromJson(raw), throwsFormatException);
    }
  });
  test('private birth date and stale allow are rejected', () {
    expect(
      () => PrivacySnapshot.fromJson({
        ...privacySnapshotJson(),
        'birthDate': '2000-01-01',
      }),
      throwsFormatException,
    );
    expect(
      () => PrivacySnapshot.fromJson(privacySnapshotJson(current: false)),
      throwsFormatException,
    );
    expect(
      PrivacySnapshot.fromJson(
        privacySnapshotJson(current: false, allow: false),
      ).allows('provider', 'cloud_text'),
      isTrue,
    );
  });
  test(
    'unsupported scope, duplicate recipient and insecure origin are rejected',
    () {
      for (final origin in [
        'http://api.cloud.test',
        'https://api.cloud.test/v1',
        'https://me:secret@api.cloud.test',
        'https://api.cloud.test?q=1',
      ]) {
        final raw = privacyPolicyJson();
        (((raw['policy'] as Map)['recipients'] as List).first
            as Map)['apiOrigins'] = [
          origin,
        ];
        expect(() => PrivacyPublicPolicy.fromJson(raw), throwsFormatException);
      }
      final duplicate = privacyPolicyJson();
      final recipients = (duplicate['policy'] as Map)['recipients'] as List;
      recipients.add(recipients.first);
      expect(
        () => PrivacyPublicPolicy.fromJson(duplicate),
        throwsFormatException,
      );
      final badScope = privacyPolicyJson();
      (((badScope['policy'] as Map)['recipients'] as List).first
          as Map)['scopes'] = [
        'all',
      ];
      expect(
        () => PrivacyPublicPolicy.fromJson(badScope),
        throwsFormatException,
      );
    },
  );
  test('consent must refer to a disclosed recipient and unique pair', () {
    final raw = privacySnapshotJson();
    ((raw['consents'] as List).first as Map)['recipientId'] = 'other';
    expect(() => PrivacySnapshot.fromJson(raw), throwsFormatException);
    final duplicate = privacySnapshotJson();
    (duplicate['consents'] as List).add((duplicate['consents'] as List).first);
    expect(() => PrivacySnapshot.fromJson(duplicate), throwsFormatException);
  });
  test('age status and declaration time cannot contradict each other', () {
    expect(
      PrivacySnapshot.fromJson(
        privacySnapshotJson(age: 'unconfirmed', allow: false),
      ).ageEligible,
      isFalse,
    );
    expect(
      PrivacySnapshot.fromJson(
        privacySnapshotJson(age: 'ineligible', allow: false),
      ).ageEligible,
      isFalse,
    );
    expect(
      () => PrivacySnapshot.fromJson({
        ...privacySnapshotJson(),
        'ageStatus': 'adult',
      }),
      throwsFormatException,
    );
    expect(
      () => PrivacySnapshot.fromJson({
        ...privacySnapshotJson(),
        'declaredAt': null,
      }),
      throwsFormatException,
    );
  });
}
