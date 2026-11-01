import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/data/privacy_fence_store.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

import 'privacy_gateway_test.dart' show privacyCode;
import 'privacy_models_test.dart' show privacySnapshotJson;
import 'privacy_service_test.dart' show PrivacyFake;

final class ControlledFenceStore implements PrivacyFenceStore {
  ControlledFenceStore(this.inner);
  final PrivacyFenceStore inner;
  bool failWrites = false;
  bool failReads = false;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  bool Function(PrivacyFenceState)? waitWhen;
  int reads = 0;
  int writes = 0;
  @override
  String get scopeKey => inner.scopeKey;
  @override
  Future<PrivacyFenceState?> read() {
    reads++;
    if (failReads) return Future.error(StateError('synthetic_read_failure'));
    return inner.read();
  }

  @override
  Future<void> write(PrivacyFenceState state) async {
    writes++;
    if (writeGate != null && (waitWhen?.call(state) ?? true)) {
      if (writeStarted?.isCompleted == false) writeStarted!.complete();
      await writeGate!.future;
    }
    if (failWrites) throw StateError('synthetic_disk_failure');
    await inner.write(state);
  }
}

void main() {
  late Directory directory;
  late Database database;
  final services = <PrivacyService>[];
  final scope = AccountStorageScope(
    environmentKey: 'test',
    accountUuid: 'privacy-owner',
  );
  final endpoint = Uri.parse('https://api.cloud.test/v1/chat/completions');

  PrivacyFenceStore store([AccountStorageScope? selected]) =>
      SembastPrivacyFenceStore(database: database, scope: selected ?? scope);
  PrivacyService service(PrivacyFake gateway, [PrivacyFenceStore? selected]) {
    final persistence = selected ?? store();
    final result = PrivacyService(
      gateway: gateway,
      fenceStore: Future.value(persistence),
      fenceScopeKey: persistence.scopeKey,
    );
    services.add(result);
    return result;
  }

  Future<void> restartDatabase(PrivacyService previous) async {
    await previous.sealAndDrain();
    await database.close();
    database = await databaseFactoryIo.openDatabase(
      '${directory.path}/state.db',
    );
  }

  setUp(() async {
    services.clear();
    directory = await Directory.systemTemp.createTemp('privacy-fence-test-');
    database = await databaseFactoryIo.openDatabase(
      '${directory.path}/state.db',
    );
  });
  tearDown(() async {
    for (final service in services) {
      try {
        await service.sealAndDrain();
      } catch (_) {
        // Individual tests assert intentional write/drain failures explicitly.
      }
      service.onClose();
    }
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'real Sembast restart keeps withdrawal through absent policy and failed reads',
    () async {
      final first = service(
        PrivacyFake()
          ..value = PrivacySnapshot.fromJson(
            privacySnapshotJson(revision: 3, allow: false),
          ),
      );
      await first.refresh();
      await restartDatabase(first);
      final offline = PrivacyFake()
        ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false});
      final restored = service(offline);
      await restored.hydrateFences();
      await restored.refresh();
      expect(restored.canEnterOnlineFeatures, isTrue);
      expect(restored.snapshot, isNull);
      await expectLater(
        restored.requireCloud(origin: endpoint, scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      await restored.requireCloud(origin: endpoint, scope: 'cloud_voice');
      await restartDatabase(restored);
      final failing = service(
        PrivacyFake()..reading = () async => throw StateError('offline'),
      );
      await expectLater(
        failing.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      expect(offline.writes, 0);
    },
  );

  test(
    'known ineligible age survives restart and same-revision contradiction',
    () async {
      final first = service(
        PrivacyFake()
          ..value = PrivacySnapshot.fromJson(
            privacySnapshotJson(revision: 5, age: 'ineligible', allow: false),
          ),
      );
      await first.refresh();
      await restartDatabase(first);
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(privacySnapshotJson(revision: 5));
      final restored = service(gateway);
      await expectLater(
        restored.requireAge(),
        throwsA(privacyCode('PRIVACY_AGE_INELIGIBLE')),
      );
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 6),
      );
      await restored.requireAge();
      await restartDatabase(restored);
      final unknown = service(
        PrivacyFake()
          ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false}),
      );
      await unknown.refresh();
      await unknown.requireAge();
    },
  );

  test(
    'account and environment namespaces never borrow another deny',
    () async {
      final first = service(
        PrivacyFake()
          ..value = PrivacySnapshot.fromJson(
            privacySnapshotJson(revision: 3, allow: false),
          ),
      );
      await first.refresh();
      for (final other in [
        AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'another-owner',
        ),
        AccountStorageScope(
          environmentKey: 'prod',
          accountUuid: scope.accountUuid,
        ),
      ]) {
        final fresh = service(
          PrivacyFake()..reading = () async => throw StateError('unconfigured'),
          store(other),
        );
        await fresh.requireCloud(origin: endpoint, scope: 'cloud_text');
        expect(await store(other).read(), isNull);
      }
    },
  );

  test(
    'uncertain withdrawal survives restart and failed grant cannot lift it',
    () async {
      final gateway = PrivacyFake();
      final first = service(gateway);
      final reviewed = (await first.refresh())!;
      gateway.writing = () async => throw StateError('response_lost');
      await expectLater(
        first.humanSetConsent(
          reviewed: reviewed,
          recipientId: 'provider',
          scope: 'cloud_text',
          allow: false,
        ),
        throwsStateError,
      );
      expect(
        (await store().read())!.denials['provider|cloud_text']!.pendingRevision,
        reviewed.revision,
      );
      await restartDatabase(first);
      final nextGateway = PrivacyFake();
      final next = service(nextGateway);
      final nextReview = (await next.refresh())!;
      nextGateway.writing = () async => throw StateError('grant_failed');
      await expectLater(
        next.humanSetConsent(
          reviewed: nextReview,
          recipientId: 'provider',
          scope: 'cloud_text',
          allow: true,
        ),
        throwsStateError,
      );
      expect(
        next.allowsLoadedConsent(recipientId: 'provider', scope: 'cloud_text'),
        isFalse,
      );
      final finalReview = (await next.refresh())!;
      nextGateway.writing = () async => PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: finalReview.revision + 1),
      );
      await next.humanSetConsent(
        reviewed: finalReview,
        recipientId: 'provider',
        scope: 'cloud_text',
        allow: true,
      );
      expect((await store().read())!.denials, isEmpty);
      await restartDatabase(next);
      final restored = service(
        PrivacyFake()..reading = () async => throw StateError('offline'),
      );
      await restored.requireCloud(origin: endpoint, scope: 'cloud_text');
    },
  );

  test(
    'successful network grant with failed local clear keeps deny and reports failure',
    () async {
      final persistence = ControlledFenceStore(store());
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(
          privacySnapshotJson(revision: 3, allow: false),
        );
      final current = service(gateway, persistence);
      final reviewed = (await current.refresh())!;
      persistence.failWrites = true;
      gateway.writing = () async =>
          PrivacySnapshot.fromJson(privacySnapshotJson(revision: 4));
      await expectLater(
        current.humanSetConsent(
          reviewed: reviewed,
          recipientId: 'provider',
          scope: 'cloud_text',
          allow: true,
        ),
        throwsA(privacyCode('PRIVACY_LOCAL_STATE_UNAVAILABLE')),
      );
      expect(current.snapshot, isNull);
      expect(
        current.allowsLoadedConsent(
          recipientId: 'provider',
          scope: 'cloud_text',
        ),
        isFalse,
      );
      expect((await store().read())!.denials, contains('provider|cloud_text'));
      await expectLater(
        current.sealAndDrain(),
        throwsA(privacyCode('PRIVACY_LOCAL_STATE_UNAVAILABLE')),
      );
    },
  );

  test(
    'withdrawal is durable before network and retirement drains admitted local write',
    () async {
      final persistence = ControlledFenceStore(store());
      final gateway = PrivacyFake();
      final current = service(gateway, persistence);
      final reviewed = (await current.refresh())!;
      persistence.writeGate = Completer<void>();
      final withdrawal = current.humanSetConsent(
        reviewed: reviewed,
        recipientId: 'provider',
        scope: 'cloud_text',
        allow: false,
      );
      final withdrawalDone = expectLater(
        withdrawal,
        throwsA(privacyCode('PRIVACY_CONTEXT_CHANGED')),
      );
      expect(
        current.allowsLoadedConsent(
          recipientId: 'provider',
          scope: 'cloud_text',
        ),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(gateway.writes, 0);
      var drained = false;
      final drain = current.sealAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      persistence.writeGate!.complete();
      await drain;
      await withdrawalDone;
      expect(gateway.writes, 0);
      await database.close();
      database = await databaseFactoryIo.openDatabase(
        '${directory.path}/state.db',
      );
      expect(
        (await store().read())!.denials['provider|cloud_text']!.pendingRevision,
        reviewed.revision,
      );
    },
  );

  test(
    'retirement releases unresolved store gate and late network never writes',
    () async {
      final delayed = Completer<PrivacyFenceStore>();
      final gateway = PrivacyFake();
      final waiting = PrivacyService(
        gateway: gateway,
        fenceStore: delayed.future,
        fenceScopeKey: scope.storageNamespace,
      );
      services.add(waiting);
      final access = expectLater(
        waiting.requireAge(),
        throwsA(privacyCode('PRIVACY_CONTEXT_CHANGED')),
      );
      expect(waiting.canEnterOnlineFeatures, isTrue);
      await waiting.sealAndDrain().timeout(const Duration(seconds: 1));
      await access;
      final persistence = ControlledFenceStore(store());
      delayed.complete(persistence);
      await Future<void>.delayed(Duration.zero);
      expect(persistence.reads, 0);
      final late = Completer<PrivacySnapshot>();
      final nextGateway = PrivacyFake()..reading = () => late.future;
      final next = service(nextGateway, persistence);
      final pending = expectLater(
        next.refresh(),
        throwsA(privacyCode('PRIVACY_CONTEXT_CHANGED')),
      );
      await Future<void>.delayed(Duration.zero);
      await next.sealAndDrain();
      final written = persistence.writes;
      late.complete(
        PrivacySnapshot.fromJson(
          privacySnapshotJson(revision: 99, allow: false),
        ),
      );
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(persistence.writes, written);
    },
  );

  test(
    'withdrawal racing a persisted policy update keeps both origins after restart',
    () async {
      final persistence = ControlledFenceStore(store());
      final gateway = PrivacyFake();
      final current = service(gateway, persistence);
      final reviewed = (await current.refresh())!;
      final next = privacySnapshotJson(
        revision: 2,
        version: 'v2',
        hash: 'b' * 64,
        effectiveAt: '2026-02-01T00:00:00Z',
      );
      (((next['policy']! as Map)['recipients']! as List).single
          as Map)['apiOrigins'] = [
        'https://new.cloud.test',
      ];
      gateway.value = PrivacySnapshot.fromJson(next);
      persistence.writeGate = Completer<void>();
      persistence.writeStarted = Completer<void>();
      persistence.waitWhen = (state) =>
          state.minimumRevision == 2 && state.denials.isEmpty;
      final refresh = current.refresh();
      await persistence.writeStarted!.future;
      final withdraw = expectLater(
        current.humanSetConsent(
          reviewed: reviewed,
          recipientId: 'provider',
          scope: 'cloud_text',
          allow: false,
        ),
        throwsA(privacyCode('PRIVACY_POLICY_CHANGED')),
      );
      persistence.writeGate!.complete();
      await refresh;
      await withdraw;
      expect(gateway.writes, 0);
      expect(
        (await store().read())!.denials['provider|cloud_text']!.origins,
        containsAll(['https://api.cloud.test', 'https://new.cloud.test']),
      );
      await restartDatabase(current);
      final restored = service(
        PrivacyFake()
          ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false}),
      );
      await restored.refresh();
      await expectLater(
        restored.requireCloud(
          origin: Uri.parse('https://new.cloud.test/'),
          scope: 'cloud_text',
        ),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
    },
  );

  test(
    'synchronous revocation retirement cannot enqueue a later database write',
    () async {
      final persistence = ControlledFenceStore(store());
      final current = service(
        PrivacyFake()
          ..value = PrivacySnapshot.fromJson(
            privacySnapshotJson(revision: 3, allow: false),
          ),
        persistence,
      );
      Future<void>? drain;
      Object? retirementError;
      int? writesAtRetirement;
      final subscription = current.revocations.listen((event) {
        if (event.recipientId == null || writesAtRetirement != null) return;
        writesAtRetirement = persistence.writes;
        try {
          drain = current.sealAndDrain();
        } catch (error) {
          retirementError = error;
        }
      });
      await expectLater(
        current.refresh(),
        throwsA(privacyCode('PRIVACY_CONTEXT_CHANGED')),
      );
      if (drain != null) await drain;
      await Future<void>.delayed(Duration.zero);
      expect(writesAtRetirement, isNotNull);
      expect(persistence.writes, writesAtRetirement);
      expect(retirementError, isNull);
      await subscription.cancel();
    },
  );

  test(
    'malformed fence has no partial cache or fabricated choice and pages remain open',
    () async {
      await stringMapStoreFactory
          .store('privacy_local_fences.v1')
          .record(scope.storageNamespace)
          .put(database, {
            'schemaVersion': 1,
            'scopeKey': scope.storageNamespace,
            'minimumRevision': 3,
            'ageIneligibleRevision': null,
            'denials': [
              {
                'key': 'provider|cloud_text',
                'observedRevision': 3,
                'pendingRevision': null,
                'origins': ['https://api.cloud.test'],
              },
              {
                'key': 'invalid|unknown_scope',
                'observedRevision': 3,
                'pendingRevision': null,
                'origins': <String>[],
              },
            ],
          });
      final gateway = PrivacyFake();
      final current = service(gateway);
      final changes = <PrivacyRevocation>[];
      final subscription = current.revocations.listen(changes.add);
      await current.hydrateFences();
      expect(changes, isEmpty);
      expect(current.canEnterOnlineFeatures, isTrue);
      expect(current.snapshot, isNull);
      await current.requireAge();
      await current.requireConsent(
        recipientId: 'provider',
        scope: 'cloud_text',
      );
      await current.requireCloud(origin: endpoint, scope: 'cloud_text');
      expect(gateway.writes, 0);
      final unchanged = await stringMapStoreFactory
          .store('privacy_local_fences.v1')
          .record(scope.storageNamespace)
          .get(database);
      expect((unchanged!['denials']! as List).length, 2);
      await subscription.cancel();
    },
  );

  test(
    'unknown local read failure defaults available without a storage write',
    () async {
      final persistence = ControlledFenceStore(store())..failReads = true;
      final gateway = PrivacyFake()
        ..reading = () async => throw StateError('network_unavailable');
      final current = service(gateway, persistence);
      await current.hydrateFences();
      expect(current.canEnterOnlineFeatures, isTrue);
      expect(
        current.allowsLoadedConsent(
          recipientId: 'provider',
          scope: 'cloud_text',
        ),
        isTrue,
      );
      expect(current.snapshot, isNull);
      await current.requireAge();
      await current.requireConsent(
        recipientId: 'provider',
        scope: 'cloud_text',
      );
      await current.requireCloud(origin: endpoint, scope: 'cloud_text');
      expect(persistence.writes, 0);
      expect(gateway.writes, 0);
      expect(await store().read(), isNull);
    },
  );

  test(
    'human withdrawal cannot claim success after an unknown local read failure',
    () async {
      final persistence = ControlledFenceStore(store())..failReads = true;
      final gateway = PrivacyFake();
      final current = service(gateway, persistence);
      final reviewed = (await current.refresh())!;
      await expectLater(
        current.humanSetConsent(
          reviewed: reviewed,
          recipientId: 'provider',
          scope: 'cloud_text',
          allow: false,
        ),
        throwsA(privacyCode('PRIVACY_LOCAL_STATE_UNAVAILABLE')),
      );
      expect(gateway.writes, 0);
      expect(persistence.writes, 0);
      expect(
        current.allowsLoadedConsent(
          recipientId: 'provider',
          scope: 'cloud_text',
        ),
        isFalse,
      );
      await expectLater(
        current.requireCloud(origin: endpoint, scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      await current.requireCloud(origin: endpoint, scope: 'cloud_voice');
      expect(current.canEnterOnlineFeatures, isTrue);
    },
  );

  test(
    'known denial survives later failed storage clear and failed network reads',
    () async {
      final persistence = ControlledFenceStore(store());
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(
          privacySnapshotJson(revision: 3, allow: false),
        );
      final current = service(gateway, persistence);
      await current.refresh();
      persistence.failWrites = true;
      gateway.value = PrivacySnapshot.fromJson(
        privacySnapshotJson(revision: 4),
      );
      await expectLater(
        current.requireConsent(recipientId: 'provider', scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      gateway.reading = () async => throw StateError('network_unavailable');
      await expectLater(
        current.requireCloud(origin: endpoint, scope: 'cloud_text'),
        throwsA(privacyCode('PRIVACY_CONSENT_REQUIRED')),
      );
      await current.requireCloud(origin: endpoint, scope: 'cloud_voice');
      expect(current.canEnterOnlineFeatures, isTrue);
      expect((await store().read())!.denials, contains('provider|cloud_text'));
    },
  );
}
