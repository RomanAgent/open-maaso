import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'privacy_models_test.dart' show privacyPolicyJson, privacySnapshotJson;
import 'privacy_gateway_test.dart' show privacyCode;

class PrivacyFake implements PrivacyGateway {
  @override
  String requestContextKey = 'test|account';
  @override
  bool hasAccount = true;
  int policies = 0, reads = 0, writes = 0;
  PrivacyPublicPolicy currentPolicy = PrivacyPublicPolicy.fromJson(
    privacyPolicyJson(),
  );
  PrivacySnapshot value = PrivacySnapshot.fromJson(privacySnapshotJson());
  Future<PrivacySnapshot> Function()? reading;
  Future<PrivacySnapshot> Function()? writing;
  Map<String, Object?>? sent;
  @override
  Future<PrivacyPublicPolicy> policy({
    required String expectedContextKey,
  }) async {
    policies++;
    return currentPolicy;
  }

  @override
  Future<PrivacySnapshot> read({required String expectedContextKey}) async {
    reads++;
    return reading == null ? value : await reading!();
  }

  @override
  Future<PrivacySnapshot> declareAge({
    required String expectedContextKey,
    required String requestKey,
    required int expectedRevision,
    required String expectedPolicyVersion,
    required String expectedPolicyHash,
    required String birthDate,
  }) async {
    writes++;
    sent = {
      'context': expectedContextKey,
      'key': requestKey,
      'revision': expectedRevision,
      'version': expectedPolicyVersion,
      'hash': expectedPolicyHash,
      'birthDate': birthDate,
    };
    return writing == null ? value : await writing!();
  }

  @override
  Future<PrivacySnapshot> setConsent({
    required String expectedContextKey,
    required String requestKey,
    required int expectedRevision,
    required String expectedPolicyVersion,
    required String expectedPolicyHash,
    required String recipientId,
    required String scope,
    required bool allow,
  }) async {
    writes++;
    sent = {
      'context': expectedContextKey,
      'key': requestKey,
      'revision': expectedRevision,
      'version': expectedPolicyVersion,
      'hash': expectedPolicyHash,
      'recipient': recipientId,
      'scope': scope,
      'allow': allow,
    };
    return writing == null ? value : await writing!();
  }
}

void main() {
  final endpoint = Uri.parse('https://api.cloud.test/v1/chat/completions');
  test(
    'construction has no network and public anonymous refresh has no me read',
    () async {
      final gateway = PrivacyFake()..hasAccount = false;
      final service = PrivacyService(gateway: gateway);
      expect(gateway.policies + gateway.reads, 0);
      expect(await service.refresh(), isNull);
      expect(service.publicPolicy?.ready, isTrue);
      expect(service.hasAccount, isFalse);
      expect(service.snapshot, isNull);
      expect(gateway.reads, 0);
      await expectLater(
        service.requireAge(),
        throwsA(privacyCode('PRIVACY_AUTHENTICATION_REQUIRED')),
      );
    },
  );
  test('unconfigured policy permits access without fake minimum age', () async {
    final gateway = PrivacyFake()
      ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false});
    final service = PrivacyService(gateway: gateway);
    expect(await service.refresh(), isNull);
    expect(gateway.reads, 0);
    expect(service.publicPolicy?.policy, isNull);
    expect(service.ageEligible, isFalse);
    expect(service.canEnterOnlineFeatures, isTrue);
  });
  test(
    'fresh reads apply explicit choices while undisclosed providers default available',
    () async {
      final gateway = PrivacyFake();
      final service = PrivacyService(gateway: gateway);
      await service.requireCloud(origin: endpoint, scope: 'cloud_text');
      await service.requireCloud(origin: endpoint, scope: 'cloud_text');
      expect(gateway.reads, 2);
      await service.requireCloud(
        origin: Uri.parse('https://another-configured-provider.test/v1'),
        scope: 'cloud_text',
      );
      await service.requireCloud(origin: endpoint, scope: 'cloud_voice');
      await expectLater(
        service.requireCloud(origin: endpoint, scope: 'all'),
        throwsA(privacyCode('PRIVACY_UNAVAILABLE')),
      );
      await service.requireConsent(
        recipientId: 'provider',
        scope: 'cloud_text',
      );
      await service.requireConsent(
        recipientId: 'undisclosed',
        scope: 'cloud_text',
      );
    },
  );
  test(
    'server revocation and age ineligibility block subsequent dispatches',
    () async {
      final gateway = PrivacyFake();
      final service = PrivacyService(gateway: gateway);
      await service.requireCloud(origin: endpoint, scope: 'cloud_text');
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 2, allow: false),
      );
      await expectLater(
        service.requireCloud(origin: endpoint, scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 2, age: 'ineligible', allow: false),
      );
      await expectLater(
        service.requireAge(),
        throwsA(privacyCode('PRIVACY_AGE_INELIGIBLE')),
      );
    },
  );
  test(
    'retired and replaced account late reads never restore policy or snapshot',
    () async {
      for (final retire in [true, false]) {
        final reply = Completer<PrivacySnapshot>();
        final started = Completer<void>();
        final gateway = PrivacyFake()
          ..reading = () {
            started.complete();
            return reply.future;
          };
        var closes = 0;
        final service = PrivacyService(
          gateway: gateway,
          closeGateway: () {
            closes++;
          },
        );
        final load = service.refresh();
        final checked = expectLater(
          load,
          throwsA(privacyCode('PRIVACY_CONTEXT_CHANGED')),
        );
        await started.future;
        if (retire) {
          service.onClose();
        } else {
          gateway.requestContextKey = 'test|other-account';
        }
        reply.complete(gateway.value);
        await checked;
        expect(service.snapshot, isNull);
        expect(service.publicPolicy, isNull);
        expect(service.ageEligible, isFalse);
        if (retire) {
          expect(closes, 1);
          service.onClose();
          expect(closes, 1);
        }
      }
    },
  );
  test(
    'human age declaration binds reviewed policy without retaining DOB',
    () async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(
          privacySnapshotJson(revision: 0, age: 'unconfirmed', allow: false),
        );
      final service = PrivacyService(
        gateway: gateway,
        requestKey: () => 'fixed-key',
      );
      final reviewed = (await service.refresh())!;
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 1, allow: false),
      );
      final result = await service.humanDeclareAge(
        reviewed: reviewed,
        birthDate: '2000-01-01',
      );
      expect(result.ageEligible, isTrue);
      expect(gateway.sent, {
        'context': 'test|account',
        'key': 'fixed-key',
        'revision': 0,
        'version': 'v1',
        'hash': reviewed.policyHash,
        'birthDate': '2000-01-01',
      });
      expect(service.snapshot?.revision, 1);
    },
  );
  test(
    'invalid date and outdated human review are rejected before mutation',
    () async {
      final gateway = PrivacyFake();
      final service = PrivacyService(gateway: gateway);
      final reviewed = (await service.refresh())!;
      await expectLater(
        service.humanDeclareAge(reviewed: reviewed, birthDate: '2000-02-31'),
        throwsA(privacyCode('PRIVACY_INVALID_INPUT')),
      );
      gateway.currentPolicy = PrivacyPublicPolicy.fromJson(
        privacyPolicyJson(
          version: 'v2',
          hash: List.filled(64, 'b').join(),
          effectiveAt: '2026-02-01T00:00:00Z',
        ),
      );
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(
          version: 'v2',
          hash: List.filled(64, 'b').join(),
          effectiveAt: '2026-02-01T00:00:00Z',
        ),
      );
      await service.refresh();
      await expectLater(
        service.humanSetConsent(
          reviewed: reviewed,
          recipientId: 'provider',
          scope: 'cloud_text',
          allow: true,
        ),
        throwsA(privacyCode('PRIVACY_POLICY_CHANGED')),
      );
      expect(gateway.writes, 0);
    },
  );
  test(
    'starting human revocation fences a slower authorization read',
    () async {
      final gateway = PrivacyFake();
      final service = PrivacyService(gateway: gateway);
      final reviewed = (await service.refresh())!;
      final reply = Completer<PrivacySnapshot>();
      final started = Completer<void>();
      gateway.reading = () {
        started.complete();
        return reply.future;
      };
      final authorization = service.requireCloud(
        origin: endpoint,
        scope: 'cloud_text',
      );
      final denied = expectLater(
        authorization,
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      await started.future;
      gateway.writing = () async => PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 2, allow: false),
      );
      final revoked = service.humanSetConsent(
        reviewed: reviewed,
        recipientId: 'provider',
        scope: 'cloud_text',
        allow: false,
      );
      expect(service.snapshot, isNull);
      expect(service.saving, isTrue);
      reply.complete(reviewed);
      await denied;
      await revoked;
      expect(service.snapshot?.allows('provider', 'cloud_text'), isFalse);
    },
  );
  test(
    'uncertain withdrawal cannot reuse still-allowed server cache',
    () async {
      final gateway = PrivacyFake();
      final service = PrivacyService(gateway: gateway);
      final reviewed = (await service.refresh())!;
      gateway.writing = () async =>
          throw const PrivacyException('PRIVACY_UNAVAILABLE');
      await expectLater(
        service.humanSetConsent(
          reviewed: reviewed,
          recipientId: 'provider',
          scope: 'cloud_text',
          allow: false,
        ),
        throwsA(privacyCode('PRIVACY_UNAVAILABLE')),
      );
      expect(service.snapshot, isNull);
      // A read can race a server mutation whose response was lost.
      await expectLater(
        service.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      expect(gateway.reads, 2);
    },
  );
  test(
    'successful explicit regrant lifts withdrawal fence; double click is single write',
    () async {
      final gateway = PrivacyFake();
      final service = PrivacyService(gateway: gateway);
      final reviewed = (await service.refresh())!;
      final reply = Completer<PrivacySnapshot>();
      gateway.writing = () => reply.future;
      final first = service.humanSetConsent(
        reviewed: reviewed,
        recipientId: 'provider',
        scope: 'cloud_text',
        allow: false,
      );
      await expectLater(
        service.humanSetConsent(
          reviewed: reviewed,
          recipientId: 'provider',
          scope: 'cloud_text',
          allow: false,
        ),
        throwsA(privacyCode('PRIVACY_BUSY')),
      );
      reply.complete(
        PrivacySnapshot.fromJson(
          privacySnapshotJson(revision: 2, allow: false),
        ),
      );
      await first;
      expect(gateway.writes, 1);
      gateway.writing = () async =>
          PrivacySnapshot.fromJson(privacySnapshotJson(revision: 3));
      await service.humanSetConsent(
        reviewed: service.snapshot!,
        recipientId: 'provider',
        scope: 'cloud_text',
        allow: true,
      );
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 3),
      );
      await service.requireConsent(
        recipientId: 'provider',
        scope: 'cloud_text',
      );
    },
  );
  test(
    'revision floor survives network failure and stale read cannot reauthorize',
    () async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(
          privacySnapshotJson(revision: 3, allow: false),
        );
      final service = PrivacyService(gateway: gateway);
      await service.refresh();
      gateway.reading = () async =>
          throw const PrivacyException('PRIVACY_UNAVAILABLE');
      await service.requireAge();
      gateway.reading = null;
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 2),
      );
      await expectLater(
        service.requireCloud(origin: endpoint, scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      expect(service.snapshot, isNull);
    },
  );
  testWidgets(
    'plain getters notify AppReactiveBuilder after refresh and retirement',
    (tester) async {
      final service = PrivacyService(gateway: PrivacyFake());
      await tester.pumpWidget(
        MaterialApp(
          home: AppReactiveBuilder(
            () => Text(service.ageEligible ? 'eligible' : 'unconfirmed'),
          ),
        ),
      );
      expect(find.text('unconfirmed'), findsOneWidget);
      await service.refresh();
      await tester.pump();
      expect(find.text('eligible'), findsOneWidget);
      service.onClose();
      await tester.pump();
      expect(find.text('unconfirmed'), findsOneWidget);
    },
  );
}
