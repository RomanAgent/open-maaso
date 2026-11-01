import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 9, 8, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues(<String, Object>{
      AppInstallationIdentityService.preferencesKey:
          '0123456789abcdef0123456789abcdef',
    }),
  );

  for (final role in <String>['source', 'target']) {
    test(
      '$role avatar preparation decodes the real read-only HTTP response',
      () async {
        final requests = <http.Request>[];
        final accounts = <String>[];
        final transport = AccountDeviceHandoffTransport(
          AccountDeviceLeaseTransport(
            accessTokenProvider: (_, account) async {
              accounts.add(account);
              return '$role-token';
            },
            httpClient: MockClient((request) async {
              requests.add(request);
              return http.Response(
                jsonEncode({
                  'code': 'OK',
                  'message': 'success',
                  'traceId': 'server-avatar-$role',
                  'data': {
                    'contractVersion': avatarSelectionContractVersion,
                    'selection': {
                      'selectionId': null,
                      'agentId': 'self',
                      'modelId': null,
                      'version': 0,
                      'selectedAt': null,
                    },
                    'asset': {
                      'id': 1,
                      'modelKey': 'masso.bundled.agent',
                      'displayName': 'Agent',
                      'modelSource': 'official',
                      'assetUrl': 'unity://masso/avatar_agent',
                      'assetSha256': 'a' * 64,
                      'runtimeConfig': {
                        'avatar': 'agent',
                        'assetName': 'Agent',
                      },
                      'compatibility': {
                        'backends': ['unity'],
                      },
                    },
                    'selectionAvailable': true,
                  },
                }),
                200,
              );
            }),
          ),
        );
        final snapshot = await transport.currentAvatar(
          environment: MaasoEnvironment.test,
          accountUuid: '$role-account',
        );
        expect(snapshot.selection.agentId, 'self');
        expect(snapshot.asset.modelKey, 'masso.bundled.agent');
        expect(snapshot.selectionAvailable, isTrue);
        expect(accounts, ['$role-account']);
        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/avatar-models/selections/current');
        expect(request.url.queryParameters, {
          'agentId': 'self',
          'platformAssets': 'false',
        });
        expect(request.body, isEmpty);
        expect(request.headers['Authorization'], 'Bearer $role-token');
        expect(request.headers['Cache-Control'], 'no-store');
        expect(request.followRedirects, isFalse);
      },
    );
  }

  for (final inspect in <bool>[false, true]) {
    test(
      'accepted ${inspect ? 'inspection' : 'cancel race'} fences exact old source lease',
      () async {
        final f = await _Fixture.create(source: true);
        f.handoff.current = f.receipt(AccountHandoffState.accepted);
        if (inspect) {
          await f.coordinator.inspectHandoff(f.handoff, handoffId: 'handoff_1');
        } else {
          await f.coordinator.cancelHandoff(
            f.handoff,
            handoffId: 'handoff_1',
            requestId: 'cancel',
          );
        }
        expect(f.coordinator.canAdmitMutations, isFalse);
        expect(f.coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
      },
    );
  }

  test(
    'DTO rejects secrets, mismatched lease actors and malformed avatar hashes',
    () async {
      final f = await _Fixture.create();
      final valid = f.json(AccountHandoffState.accepted);
      expect(AccountDeviceHandoff.fromJson(valid).isCommitted, isTrue);
      expect(
        () =>
            AccountDeviceHandoff.fromJson({...valid, 'holderProof': 'secret'}),
        throwsFormatException,
      );
      expect(
        () => AccountDeviceHandoff.fromJson({...valid, 'agentId': 'other'}),
        throwsFormatException,
      );
      expect(
        () => AccountDeviceHandoff.fromJson({...valid, 'sourceEpoch': 99}),
        throwsFormatException,
      );
      expect(
        () => AccountDeviceHandoff.fromJson({
          ...valid,
          'avatarModel': <String, Object?>{
            'modelId': 'a',
            'revision': '1',
            'sha256': null,
          },
        }),
        throwsFormatException,
      );
      expect(
        () => AccountDeviceHandoff.fromJson({
          ...valid,
          'sourcePresenceSessionId': valid['targetPresenceSessionId'],
        }),
        throwsFormatException,
      );
      expect(
        () => AccountDeviceHandoff.fromJson({...valid, 'remainingTtlMs': -1}),
        throwsFormatException,
      );
      expect(
        () => AccountHandoffResult.fromJson({
          'handoff': valid,
          'replayed': 'true',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'target retries uncertain ready with exactly the original private proof',
    () async {
      final f = await _Fixture.create();
      f.handoff.current = f.receipt(AccountHandoffState.targetReady);
      f.handoff.failReadyOnce = true;
      await expectLater(
        f.coordinator.acknowledgeHandoffReady(
          f.handoff,
          handoff: f.receipt(AccountHandoffState.prepared),
          requestId: 'ready-request-1',
        ),
        throwsA(isA<TimeoutException>()),
      );
      await f.ready();
      final proofs = f.handoff.bodies
          .map((body) => body['holderProof'])
          .toSet();
      expect(proofs, hasLength(1));
      expect(
        base64Url.decode(base64Url.normalize(proofs.single as String)),
        hasLength(32),
      );
      expect(
        f.coordinator.toString(),
        isNot(contains(proofs.single as String)),
      );
      expect(f.coordinator.canAdmitMutations, isFalse);
    },
  );

  test(
    'ready response for a different target never installs authority',
    () async {
      final f = await _Fixture.create();
      f.handoff.current = AccountDeviceHandoff.fromJson({
        ...f.json(AccountHandoffState.targetReady),
        'targetPresenceSessionId': 'different_presence',
      });
      await expectLater(
        f.coordinator.acknowledgeHandoffReady(
          f.handoff,
          handoff: f.receipt(AccountHandoffState.prepared),
          requestId: 'ready',
        ),
        throwsFormatException,
      );
      expect(f.coordinator.canAdmitMutations, isFalse);
    },
  );

  test(
    'source exit after local fencing rejects late successful acknowledgement',
    () async {
      final f = await _Fixture.create(source: true);
      f.handoff.current = f.receipt(AccountHandoffState.accepted);
      f.handoff.gate = Completer<void>();
      final result = expectLater(
        f.coordinator.acknowledgeHandoffExit(
          f.handoff,
          handoffId: 'handoff_1',
          requestId: 'exit',
        ),
        throwsStateError,
      );
      await f.handoff.started.future;
      f.coordinator.fence();
      f.handoff.gate!.complete();
      await result;
      expect(f.coordinator.canAdmitMutations, isFalse);
      expect(f.coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
    },
  );

  test('committed source exit fences its old request capability', () async {
    final f = await _Fixture.create(source: true);
    final capability = f.coordinator.requireCurrentRequestAuthority();
    f.handoff.current = f.receipt(AccountHandoffState.accepted);
    await f.coordinator.acknowledgeHandoffExit(
      f.handoff,
      handoffId: 'handoff_1',
      requestId: 'exit',
    );
    expect(capability.requireCurrent, throwsStateError);
    expect(f.coordinator.canAdmitMutations, isFalse);
  });

  test(
    'target adopts canonical lease once and retains the proof through mount',
    () async {
      final f = await _Fixture.create();
      await f.ready();
      f.commit();
      final adopted = await f.coordinator.adoptTargetHandoff(
        f.handoff,
        handoffId: 'handoff_1',
      );
      expect(adopted, same(f.lease.current));
      expect(f.lease.currentReads, 1);
      expect(f.coordinator.canAdmitMutations, isTrue);
      expect(f.coordinator.hasTransferredLeaseAwaitingMount, isTrue);
      expect(f.coordinator.consumeTransferredLeaseForMount(), same(adopted));
      expect(f.coordinator.consumeTransferredLeaseForMount, throwsStateError);
      final proofBefore = f.handoff.bodies.first['holderProof'];
      f.handoff.current = f.receipt(AccountHandoffState.completed);
      await f.coordinator.completeHandoff(
        f.handoff,
        handoffId: 'handoff_1',
        requestId: 'complete',
      );
      expect(f.handoff.bodies.last['holderProof'], proofBefore);
    },
  );

  test(
    'replayed accepted handoff cannot adopt a replaced canonical lease',
    () async {
      final f = await _Fixture.create();
      await f.ready();
      f.commit();
      f.lease.current = _lease(f.local, id: 'replacement_lease', epoch: 3);
      await expectLater(
        f.coordinator.adoptTargetHandoff(f.handoff, handoffId: 'handoff_1'),
        throwsStateError,
      );
      expect(f.coordinator.currentReceipt, isNull);
      expect(f.coordinator.canAdmitMutations, isFalse);
      // A failed observation did not discard the pending proof.
      f.commit();
      await f.coordinator.adoptTargetHandoff(f.handoff, handoffId: 'handoff_1');
      expect(f.coordinator.canAdmitMutations, isTrue);
    },
  );

  test(
    'canonical request latency is subtracted from admission deadline',
    () async {
      final f = await _Fixture.create();
      await f.ready();
      f.commit();
      f.lease.current = _lease(f.local, ttl: const Duration(seconds: 3));
      f.lease.onCurrent = () => f.monotonic = const Duration(seconds: 4);
      await expectLater(
        f.coordinator.adoptTargetHandoff(f.handoff, handoffId: 'handoff_1'),
        throwsStateError,
      );
      expect(f.coordinator.canAdmitMutations, isFalse);
      expect(f.coordinator.hasTransferredLeaseAwaitingMount, isFalse);
    },
  );

  test(
    'fencing while fetching canonical lease cannot re-activate target',
    () async {
      final f = await _Fixture.create();
      await f.ready();
      f.commit();
      f.lease.onCurrent = f.coordinator.fence;
      await expectLater(
        f.coordinator.adoptTargetHandoff(f.handoff, handoffId: 'handoff_1'),
        throwsStateError,
      );
      expect(f.coordinator.currentReceipt, isNull);
      expect(f.coordinator.canAdmitMutations, isFalse);
    },
  );

  test(
    'cancel racing accepted preserves pending proof for canonical adoption',
    () async {
      final f = await _Fixture.create();
      await f.ready();
      f.commit();
      final result = await f.coordinator.cancelHandoff(
        f.handoff,
        handoffId: 'handoff_1',
        requestId: 'cancel',
      );
      expect(result.isCommitted, isTrue);
      await f.coordinator.adoptTargetHandoff(f.handoff, handoffId: 'handoff_1');
      expect(f.coordinator.canAdmitMutations, isTrue);
    },
  );

  test(
    'confirmed cancellation clears the target proof and blocks replay adoption',
    () async {
      final f = await _Fixture.create();
      await f.ready();
      f.handoff.current = f.receipt(AccountHandoffState.cancelled);
      await f.coordinator.cancelHandoff(
        f.handoff,
        handoffId: 'handoff_1',
        requestId: 'cancel',
      );
      f.commit();
      await expectLater(
        f.coordinator.adoptTargetHandoff(f.handoff, handoffId: 'handoff_1'),
        throwsStateError,
      );
    },
  );

  test(
    'drain uses exact source authority and cannot outlive a local fence',
    () async {
      final f = await _Fixture.create(source: true);
      f.handoff.gate = Completer<void>();
      final response = expectLater(
        f.coordinator.drainForHandoff(f.handoff, requestId: 'drain-request'),
        throwsStateError,
      );
      await f.handoff.started.future;
      expect(f.handoff.bodies.single.keys.toSet(), <String>{
        'agentId',
        'leaseId',
        'epoch',
        'runtimeInstanceId',
        'presenceSessionId',
        'holderProof',
        'requestId',
      });
      expect(f.handoff.bodies.single['leaseId'], 'source_lease');
      f.coordinator.fence();
      f.handoff.gate!.complete();
      await response;
    },
  );

  test('drain DTO requires exact fields and consistent ready count', () {
    expect(
      AccountHandoffDrainResult.fromJson({
        'ready': true,
        'pendingSessionCount': 0,
        'replayed': false,
      }).ready,
      isTrue,
    );
    for (final json in <Map<String, Object?>>[
      {'ready': true, 'pendingSessionCount': 1, 'replayed': false},
      {'ready': false, 'pendingSessionCount': 0, 'replayed': false},
      {'ready': false, 'pendingSessionCount': -1, 'replayed': false},
      {'ready': true, 'pendingSessionCount': 0, 'replayed': 'yes'},
      {
        'ready': true,
        'pendingSessionCount': 0,
        'replayed': false,
        'holderProof': 'secret',
      },
    ]) {
      expect(
        () => AccountHandoffDrainResult.fromJson(json),
        throwsFormatException,
      );
    }
  });

  test(
    'HTTP handoff keeps proof in bounded POST body and GET discovery proof-free',
    () async {
      final f = await _Fixture.create();
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        final Object data = request.url.path.endsWith('/drain')
            ? {'ready': true, 'pendingSessionCount': 0, 'replayed': false}
            : {
                'handoff': f.json(AccountHandoffState.targetReady),
                'replayed': false,
              };
        return http.Response(
          jsonEncode({
            'code': 'OK',
            'message': '',
            'traceId': 'trace',
            'data': data,
          }),
          200,
        );
      });
      final transport = AccountDeviceHandoffTransport(
        AccountDeviceLeaseTransport(
          accessTokenProvider: (_, _) async => 'test-token',
          httpClient: client,
        ),
      );
      await transport.currentHandoff(
        environment: MaasoEnvironment.test,
        accountUuid: 'account',
        presence: f.local,
        handoffId: 'handoff_1',
      );
      await transport.drainHandoff(
        environment: MaasoEnvironment.test,
        accountUuid: 'account',
        body: {'holderProof': 'test-proof', 'requestId': 'request'},
      );
      expect(requests[0].method, 'GET');
      expect(requests[0].url.query, isNot(contains('Proof')));
      expect(requests[0].body, isEmpty);
      expect(requests[1].method, 'POST');
      expect(requests[1].url.path, '/v1/companion/runtime-handoffs/drain');
      expect(requests[1].url.toString(), isNot(contains('test-proof')));
      expect(jsonDecode(requests[1].body)['holderProof'], 'test-proof');
      expect(requests[1].headers['Cache-Control'], 'no-store');
      expect(requests[1].followRedirects, isFalse);
      await expectLater(
        transport.handoffCommand(
          environment: MaasoEnvironment.test,
          accountUuid: 'account',
          command: AccountHandoffCommand.cancel,
          body: {},
          handoffId: '../../bad',
        ),
        throwsFormatException,
      );
      expect(requests, hasLength(2));
    },
  );
}

class _Fixture {
  _Fixture(this.identity, this.source);
  final AppInstallationIdentityService identity;
  final bool source;
  final lease = _LeaseGateway();
  final handoff = _HandoffGateway();
  Duration monotonic = Duration.zero;
  late final AccountDeviceLeaseCoordinator coordinator;
  AccountDevicePresenceReceipt get local => coordinator.currentPresence!;

  static Future<_Fixture> create({bool source = false}) async {
    final identity = await AppInstallationIdentityService(
      sharedPreferences: await SharedPreferences.getInstance(),
      randomBytes: (length) => List<int>.filled(length, 0x44),
    ).init();
    final f = _Fixture(identity, source);
    var entropy = 0;
    f.coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: f.lease,
      monotonicNow: () => f.monotonic,
      wallClock: () => _now,
      randomBytes: (length) => List<int>.filled(length, ++entropy),
    );
    addTearDown(() {
      f.coordinator.abandonLocalAuthority();
      f.coordinator.close();
    });
    if (source) {
      await f.coordinator.acquire(
        environment: MaasoEnvironment.test,
        accountUuid: 'account',
        deviceLabel: 'Test Mac',
        platform: 'macos',
        appVersion: '1',
      );
    } else {
      await f.coordinator.openObservationPresence(
        environment: MaasoEnvironment.test,
        accountUuid: 'account',
        deviceLabel: 'Test Mac',
        platform: 'macos',
        appVersion: '1',
      );
    }
    return f;
  }

  AccountDeviceHandoff receipt(AccountHandoffState state) =>
      AccountDeviceHandoff.fromJson(json(state));
  Map<String, Object?> json(AccountHandoffState state) {
    final target = source
        ? _presence(
            installation: 'target_install',
            runtime: 'target_runtime',
            session: 'target_presence',
          )
        : local;
    return <String, Object?>{
      'handoffId': 'handoff_1',
      'agentId': 'self',
      'state': state.wireName,
      'sourceLeaseId': 'source_lease',
      'sourceEpoch': 1,
      'sourcePresenceSessionId': source
          ? local.presenceSessionId
          : 'source_presence',
      'sourceRuntimeInstanceId': source
          ? local.runtimeInstanceId
          : 'source_runtime',
      'targetPresenceSessionId': target.presenceSessionId,
      'targetRuntimeInstanceId': target.runtimeInstanceId,
      'avatarModel': {'modelId': 'bundled:ria', 'revision': '1', 'sha256': ''},
      'createdAt': _now.toIso8601String(),
      'expiresAt': _now.add(const Duration(seconds: 30)).toIso8601String(),
      'remainingTtlMs': 30000,
      'lease':
          (state == AccountHandoffState.accepted ||
              state == AccountHandoffState.completed)
          ? _lease(target).toJson()
          : null,
    };
  }

  Future<void> ready() async {
    handoff.current = receipt(AccountHandoffState.targetReady);
    await coordinator.acknowledgeHandoffReady(
      handoff,
      handoff: receipt(AccountHandoffState.prepared),
      requestId: 'ready-request-1',
    );
  }

  void commit() {
    handoff.current = receipt(AccountHandoffState.accepted);
    lease.current = _lease(local);
  }
}

class _HandoffGateway implements AccountDeviceHandoffGateway {
  late AccountDeviceHandoff current;
  final bodies = <Map<String, Object?>>[];
  final started = Completer<void>();
  Completer<void>? gate;
  bool failReadyOnce = false;
  @override
  Future<AccountHandoffResult> handoffCommand({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountHandoffCommand command,
    required Map<String, Object?> body,
    String? handoffId,
  }) async {
    bodies.add(Map.of(body));
    if (!started.isCompleted) started.complete();
    if (command == AccountHandoffCommand.targetReady && failReadyOnce) {
      failReadyOnce = false;
      throw TimeoutException('uncertain ready');
    }
    await gate?.future;
    return AccountHandoffResult(handoff: current, replayed: false);
  }

  @override
  Future<AccountHandoffResult> currentHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    String? handoffId,
  }) async => AccountHandoffResult(handoff: current, replayed: false);
  @override
  Future<AccountHandoffDrainResult> drainHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required Map<String, Object?> body,
  }) async {
    bodies.add(Map.of(body));
    if (!started.isCompleted) started.complete();
    await gate?.future;
    return const AccountHandoffDrainResult(
      ready: true,
      pendingSessionCount: 0,
      replayed: false,
    );
  }
}

class _LeaseGateway implements AccountDeviceLeaseGateway {
  AccountDeviceLeaseReceipt? current;
  void Function()? onCurrent;
  int currentReads = 0;
  @override
  Future<AccountDevicePresenceOperationResult> openPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    required String requestId,
  }) async => AccountDevicePresenceOperationResult(
    presence: _presence(
      installation: installationId,
      runtime: runtimeInstanceId,
      session: 'local_presence',
    ),
    replayed: false,
  );
  @override
  Future<AccountDeviceLeaseOperationResult> acquireLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String presenceSessionId,
    required String holderProof,
    required String requestId,
  }) async {
    current = _lease(
      _presence(
        installation: installationId,
        runtime: runtimeInstanceId,
        session: presenceSessionId,
      ),
      id: 'source_lease',
      epoch: 1,
    );
    return AccountDeviceLeaseOperationResult(lease: current!, replayed: false);
  }

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async {
    currentReads++;
    onCurrent?.call();
    return AccountDeviceLeaseSnapshot(
      state: current == null
          ? AccountDeviceLeaseRemoteState.inactive
          : AccountDeviceLeaseRemoteState.active,
      lease: current,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

AccountDevicePresenceReceipt _presence({
  required String installation,
  required String runtime,
  required String session,
}) => AccountDevicePresenceReceipt(
  agentId: 'self',
  installationId: installation,
  runtimeInstanceId: runtime,
  presenceSessionId: session,
  generation: 1,
  deviceLabel: 'Test Mac',
  platform: 'macos',
  appVersion: '1',
  openedAt: _now,
  lastSeenAt: _now,
  expiresAt: _now.add(const Duration(seconds: 60)),
  remainingTtl: const Duration(seconds: 60),
  renewAfter: const Duration(seconds: 20),
);

AccountDeviceLeaseReceipt _lease(
  AccountDevicePresenceReceipt presence, {
  String id = 'target_lease',
  int epoch = 2,
  Duration ttl = const Duration(seconds: 45),
}) => AccountDeviceLeaseReceipt(
  agentId: 'self',
  leaseId: id,
  epoch: epoch,
  installationId: presence.installationId,
  runtimeInstanceId: presence.runtimeInstanceId,
  presenceSessionId: presence.presenceSessionId,
  expiresAt: _now.add(ttl),
  remainingTtl: ttl,
  renewAfter: Duration(milliseconds: ttl.inMilliseconds ~/ 3),
  holder: presence.toHolder(),
);
