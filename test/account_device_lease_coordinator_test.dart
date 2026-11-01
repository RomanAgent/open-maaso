import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppInstallationIdentityService.preferencesKey:
          '0123456789abcdef0123456789abcdef',
    });
  });

  test(
    'replays an uncertain acquire with the same request and proof',
    () async {
      final identity = await _identity();
      final gateway = _FakeLeaseGateway()..acquireTransportFailures = 1;
      final entropy = _Entropy();
      final coordinator = AccountDeviceLeaseCoordinator(
        identity: identity,
        gateway: gateway,
        randomBytes: entropy.bytes,
        monotonicNow: () => Duration.zero,
        wallClock: () => _wallNow,
      );

      await expectLater(
        _acquire(coordinator),
        throwsA(isA<TimeoutException>()),
      );
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.degraded);
      expect(coordinator.canAdmitMutations, isFalse);
      expect(gateway.acquireCalls, hasLength(1));

      final lease = await _acquire(coordinator);

      expect(lease.epoch, 1);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.active);
      expect(coordinator.canAdmitMutations, isTrue);
      expect(gateway.openCalls, hasLength(1));
      expect(gateway.acquireCalls, hasLength(2));
      expect(
        gateway.acquireCalls[1].requestId,
        gateway.acquireCalls[0].requestId,
      );
      expect(
        gateway.acquireCalls[1].holderProof,
        gateway.acquireCalls[0].holderProof,
      );
      expect(
        base64Url.decode(
          base64Url.normalize(gateway.acquireCalls.first.holderProof),
        ),
        hasLength(32),
      );
      expect(coordinator.toString(), isNot(contains('holderProof')));
      expect(
        coordinator.toString(),
        isNot(contains(gateway.acquireCalls.first.holderProof)),
      );
    },
  );

  test('presence close refuses an unresolved acquire command', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway()..acquireTransportFailures = 1;
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );

    await expectLater(_acquire(coordinator), throwsA(isA<TimeoutException>()));
    final presence = coordinator.currentPresence;
    expect(presence, isNotNull);
    expect(coordinator.hasPendingAcquire, isTrue);

    await expectLater(coordinator.closePresence(), throwsStateError);

    expect(coordinator.currentPresence, same(presence));
    expect(coordinator.hasPendingAcquire, isTrue);
    expect(gateway.acquireCalls, hasLength(1));
  });

  test(
    'stale acquire replay clears proof and leaves presence closable',
    () async {
      final identity = await _identity();
      final gateway = _FakeLeaseGateway()
        ..committedAcquireFailures = 1
        ..staleAcquireLease = 1;
      final coordinator = AccountDeviceLeaseCoordinator(
        identity: identity,
        gateway: gateway,
        randomBytes: _Entropy().bytes,
        monotonicNow: () => Duration.zero,
        wallClock: () => _wallNow,
      );

      await expectLater(
        _acquire(coordinator),
        throwsA(isA<TimeoutException>()),
      );
      expect(coordinator.hasPendingAcquire, isTrue);
      expect(gateway._lease, isNotNull);

      await expectLater(
        _acquire(coordinator),
        throwsA(
          isA<AccountDeviceLeaseRequestException>().having(
            (error) => error.code,
            'code',
            'STALE_RUNTIME_LEASE',
          ),
        ),
      );

      expect(gateway.acquireCalls, hasLength(2));
      expect(
        gateway.acquireCalls.map((call) => call.requestId).toSet(),
        hasLength(1),
      );
      expect(
        gateway.acquireCalls.map((call) => call.holderProof).toSet(),
        hasLength(1),
      );
      expect(coordinator.hasPendingAcquire, isFalse);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNotNull);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.standby);

      await coordinator.closePresence();

      expect(coordinator.currentPresence, isNull);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.idle);
    },
  );

  test(
    'retry authentication failure retains an uncertain acquire proof',
    () async {
      final identity = await _identity();
      final gateway = _FakeLeaseGateway()
        ..acquireTransportFailures = 1
        ..acquireAuthenticationFailures = 1;
      final coordinator = AccountDeviceLeaseCoordinator(
        identity: identity,
        gateway: gateway,
        randomBytes: _Entropy().bytes,
        monotonicNow: () => Duration.zero,
        wallClock: () => _wallNow,
      );

      await expectLater(
        _acquire(coordinator),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        _acquire(coordinator),
        throwsA(
          isA<AccountDeviceLeaseRequestException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );

      expect(coordinator.hasPendingAcquire, isTrue);
      expect(gateway.acquireCalls, hasLength(2));
      expect(
        gateway.acquireCalls.map((call) => call.requestId).toSet(),
        hasLength(1),
      );
      expect(
        gateway.acquireCalls.map((call) => call.holderProof).toSet(),
        hasLength(1),
      );

      final lease = await _acquire(coordinator);
      expect(lease, same(coordinator.currentReceipt));
      expect(coordinator.hasPendingAcquire, isFalse);
      expect(gateway.acquireCalls, hasLength(3));
      expect(
        gateway.acquireCalls.map((call) => call.requestId).toSet(),
        hasLength(1),
      );
      expect(
        gateway.acquireCalls.map((call) => call.holderProof).toSet(),
        hasLength(1),
      );
    },
  );

  test(
    'network heartbeat failure degrades admission and retry is idempotent',
    () async {
      final identity = await _identity();
      final gateway = _FakeLeaseGateway()..heartbeatLeaseFailures = 1;
      final entropy = _Entropy();
      var monotonicNow = Duration.zero;
      final coordinator = AccountDeviceLeaseCoordinator(
        identity: identity,
        gateway: gateway,
        randomBytes: entropy.bytes,
        monotonicNow: () => monotonicNow,
        wallClock: () => _wallNow,
      );
      await _acquire(coordinator);
      monotonicNow = const Duration(seconds: 10);

      await expectLater(
        coordinator.heartbeat(),
        throwsA(isA<TimeoutException>()),
      );
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.degraded);
      expect(coordinator.canAdmitMutations, isFalse);

      final renewed = await coordinator.heartbeat();

      expect(renewed.epoch, 1);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.active);
      expect(coordinator.canAdmitMutations, isTrue);
      expect(gateway.heartbeatLeaseRequestIds, hasLength(2));
      expect(
        gateway.heartbeatLeaseRequestIds[1],
        gateway.heartbeatLeaseRequestIds[0],
      );
    },
  );

  test(
    'monotonic safety deadline hard-fences but retains exact release',
    () async {
      final identity = await _identity();
      final gateway = _FakeLeaseGateway();
      final entropy = _Entropy();
      var monotonicNow = Duration.zero;
      final coordinator = AccountDeviceLeaseCoordinator(
        identity: identity,
        gateway: gateway,
        randomBytes: entropy.bytes,
        monotonicNow: () => monotonicNow,
        wallClock: () => _wallNow,
        safetyMargin: const Duration(seconds: 5),
      );
      await _acquire(coordinator);
      final proof = gateway.acquireCalls.single.holderProof;

      monotonicNow = const Duration(seconds: 40);
      coordinator.enforceLocalDeadline();

      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
      expect(coordinator.canAdmitMutations, isFalse);
      await expectLater(coordinator.heartbeat(), throwsStateError);
      expect(coordinator.close, throwsStateError);

      final release = await coordinator.release();
      expect(release.released, isTrue);
      expect(gateway.releaseProofs, <String>[proof]);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.standby);
    },
  );

  test('a definitive conflict discards proof before a fresh acquire', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway()..acquireConflicts = 1;
    final entropy = _Entropy();
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: entropy.bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );

    await expectLater(
      _acquire(coordinator),
      throwsA(isA<AccountDeviceLeaseConflict>()),
    );
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.conflict);
    expect(coordinator.currentReceipt, isNull);

    await _acquire(coordinator);

    expect(gateway.acquireCalls, hasLength(2));
    expect(
      gateway.acquireCalls[1].holderProof,
      isNot(gateway.acquireCalls[0].holderProof),
    );
  });

  test('stale heartbeat clears local authority immediately', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway()..staleHeartbeat = true;
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );
    await _acquire(coordinator);

    await expectLater(
      coordinator.heartbeat(),
      throwsA(
        isA<AccountDeviceLeaseRequestException>().having(
          (error) => error.code,
          'code',
          'STALE_RUNTIME_LEASE',
        ),
      ),
    );

    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
    expect(coordinator.currentReceipt, isNull);
    expect(coordinator.canAdmitMutations, isFalse);
  });

  test('request authority is exact, generation-bound, and redacted', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway();
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );
    await _acquire(coordinator);
    final proof = gateway.acquireCalls.single.holderProof;
    final authority = coordinator.requireCurrentRequestAuthority();
    final body = <String, Object?>{};
    final headers = <String, String>{};

    authority.authorizeRealtimeSessionCreation(
      body,
      destination: Uri.parse(
        'https://api-test.futurpals.com.cn/v1/realtime/sessions',
      ),
    );
    authority.authorizeRealtimeActionStream(
      headers,
      destination: Uri.parse(
        'https://api-test.futurpals.com.cn/'
        'v1/realtime/sessions/session_1/actions',
      ),
      sessionId: 'session_1',
    );

    expect(body, <String, Object?>{
      'agentId': 'self',
      'leaseId': 'lease_1',
      'epoch': 1,
      'runtimeInstanceId': identity.runtimeInstanceId,
      'presenceSessionId': 'presence_1',
      'holderProof': proof,
    });
    expect(headers, <String, String>{
      'X-Maaso-Runtime-Agent-Id': 'self',
      'X-Maaso-Runtime-Lease-Id': 'lease_1',
      'X-Maaso-Runtime-Lease-Epoch': '1',
      'X-Maaso-Runtime-Instance-Id': identity.runtimeInstanceId,
      'X-Maaso-Runtime-Presence-Session-Id': 'presence_1',
      'X-Maaso-Runtime-Holder-Proof': proof,
    });
    expect(authority.toString(), contains('holderProof: <redacted>'));
    expect(authority.toString(), isNot(contains(proof)));

    final foreignBody = <String, Object?>{};
    expect(
      () => authority.authorizeRealtimeSessionCreation(
        foreignBody,
        destination: Uri.parse('https://example.test/v1/realtime/sessions'),
      ),
      throwsStateError,
    );
    expect(foreignBody, isEmpty);

    coordinator.fence();
    final lateBody = <String, Object?>{};
    final lateHeaders = <String, String>{};
    expect(
      () => authority.authorizeRealtimeSessionCreation(
        lateBody,
        destination: Uri.parse(
          'https://api-test.futurpals.com.cn/v1/realtime/sessions',
        ),
      ),
      throwsStateError,
    );
    expect(
      () => authority.authorizeRealtimeActionStream(
        lateHeaders,
        destination: Uri.parse(
          'https://api-test.futurpals.com.cn/'
          'v1/realtime/sessions/session_1/actions',
        ),
        sessionId: 'session_1',
      ),
      throwsStateError,
    );
    expect(lateBody, isEmpty);
    expect(lateHeaders, isEmpty);
  });

  test('request authority survives same-identity renewal only', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway();
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );
    await _acquire(coordinator);
    final authority = coordinator.requireCurrentRequestAuthority();

    await coordinator.heartbeat();
    expect(authority.requireCurrent, returnsNormally);

    await coordinator.release();
    expect(authority.requireCurrent, throwsStateError);
  });

  test('lease deadlines stay anchored to request dispatch', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway();
    var monotonicNow = Duration.zero;
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => monotonicNow,
      wallClock: () => _wallNow,
    );
    await _acquire(coordinator);

    monotonicNow = const Duration(seconds: 10);
    gateway.heartbeatLeaseGate = Completer<void>();
    final heartbeat = coordinator.heartbeat();
    await gateway.heartbeatLeaseStarted.future;

    monotonicNow = const Duration(seconds: 20);
    gateway.heartbeatLeaseGate!.complete();
    await heartbeat;

    expect(coordinator.admissionTimeRemaining, const Duration(seconds: 30));
    expect(coordinator.canAdmitMutations, isTrue);
  });

  test('late heartbeat completion cannot revive a deadline fence', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway();
    var monotonicNow = Duration.zero;
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => monotonicNow,
      wallClock: () => _wallNow,
    );
    await _acquire(coordinator);

    monotonicNow = const Duration(seconds: 10);
    gateway.heartbeatLeaseGate = Completer<void>();
    final heartbeat = coordinator.heartbeat();
    await gateway.heartbeatLeaseStarted.future;

    monotonicNow = const Duration(seconds: 40);
    coordinator.enforceLocalDeadline();
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
    gateway.heartbeatLeaseGate!.complete();

    await expectLater(heartbeat, throwsStateError);
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
    expect(coordinator.canAdmitMutations, isFalse);
  });

  test('absolute expiry conservatively caps the admission deadline', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway()
      ..leaseExpiresAt = _wallNow.add(const Duration(seconds: 20));
    var monotonicNow = Duration.zero;
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => monotonicNow,
      wallClock: () => _wallNow,
      safetyMargin: const Duration(seconds: 5),
    );

    await _acquire(coordinator);
    expect(coordinator.admissionTimeRemaining, const Duration(seconds: 15));

    monotonicNow = const Duration(seconds: 15);
    coordinator.enforceLocalDeadline();
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
    expect(coordinator.canAdmitMutations, isFalse);
  });

  test('observation presence never acquires or creates holder proof', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway();
    final entropy = _Entropy();
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: entropy.bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );

    final opened = await coordinator.openObservationPresence(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      deviceLabel: 'Kunhong Mac',
      platform: 'macos',
      appVersion: '1.2.3+4',
    );
    final renewed = await coordinator.heartbeatObservationPresence();
    final closed = await coordinator.closePresence();

    expect(renewed.presenceSessionId, opened.presenceSessionId);
    expect(closed.closed, isTrue);
    expect(gateway.openCalls, hasLength(1));
    expect(gateway.presenceHeartbeatRequestIds, hasLength(1));
    expect(gateway.acquireCalls, isEmpty);
    expect(gateway.heartbeatLeaseRequestIds, isEmpty);
    expect(entropy.requestedLengths, everyElement(16));
    expect(entropy.requestedLengths, hasLength(3));
    expect(coordinator.currentPresence, isNull);
    expect(coordinator.currentReceipt, isNull);
    expect(coordinator.canAdmitMutations, isFalse);
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.idle);
  });

  test('acquire reuses the exact observation presence', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway();
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );

    final presence = await coordinator.openObservationPresence(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      deviceLabel: 'Kunhong Mac',
      platform: 'macos',
      appVersion: '1.2.3+4',
    );
    final lease = await _acquire(coordinator);

    expect(gateway.openCalls, hasLength(1));
    expect(gateway.acquireCalls, hasLength(1));
    expect(lease.presenceSessionId, presence.presenceSessionId);
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.active);
    expect(coordinator.canAdmitMutations, isTrue);
  });

  test('observation heartbeat retry keeps the same request id', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway()..heartbeatPresenceFailures = 1;
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );
    await coordinator.openObservationPresence(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      deviceLabel: 'Kunhong Mac',
      platform: 'macos',
      appVersion: '1.2.3+4',
    );

    await expectLater(
      coordinator.heartbeatObservationPresence(),
      throwsA(isA<TimeoutException>()),
    );
    await coordinator.heartbeatObservationPresence();

    expect(gateway.presenceHeartbeatRequestIds, hasLength(2));
    expect(
      gateway.presenceHeartbeatRequestIds[1],
      gateway.presenceHeartbeatRequestIds[0],
    );
    expect(gateway.acquireCalls, isEmpty);
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.standby);
  });

  test('stale observation heartbeat clears receipt for a fresh open', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway();
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );
    await coordinator.openObservationPresence(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      deviceLabel: 'Kunhong Mac',
      platform: 'macos',
      appVersion: '1.2.3+4',
    );
    gateway.stalePresenceHeartbeat = true;

    await expectLater(
      coordinator.heartbeatObservationPresence(),
      throwsA(
        isA<AccountDeviceLeaseRequestException>().having(
          (error) => error.code,
          'code',
          'STALE_RUNTIME_PRESENCE',
        ),
      ),
    );

    expect(coordinator.currentPresence, isNull);
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.idle);
    gateway
      ..stalePresenceHeartbeat = false
      .._presence = null;
    await coordinator.openObservationPresence(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      deviceLabel: 'Kunhong Mac',
      platform: 'macos',
      appVersion: '1.2.3+4',
    );

    expect(gateway.openCalls, hasLength(2));
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.standby);
  });

  test('cancel fences a late observation open before changing scope', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway()..openPresenceGate = Completer<void>();
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );

    final oldOpen = coordinator.openObservationPresence(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-old',
      deviceLabel: 'Old runtime',
      platform: 'macos',
      appVersion: '1.2.3+4',
    );
    await gateway.openPresenceStarted.future;

    coordinator.cancelObservationPresence();
    expect(coordinator.currentPresence, isNull);
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.idle);

    gateway.openPresenceGate!.complete();
    await expectLater(oldOpen, throwsStateError);
    expect(coordinator.currentPresence, isNull);

    gateway
      .._presence = null
      ..openPresenceGate = null;
    final current = await coordinator.openObservationPresence(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-new',
      deviceLabel: 'New runtime',
      platform: 'macos',
      appVersion: '1.2.3+4',
    );

    expect(current.deviceLabel, 'New runtime');
    expect(gateway.openCalls, hasLength(2));
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.standby);
  });

  test('close rejects an in-flight presence open', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway()..openPresenceGate = Completer<void>();
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );

    final acquire = _acquire(coordinator);
    await gateway.openPresenceStarted.future;
    expect(coordinator.close, throwsStateError);
    expect(
      coordinator.state,
      AccountDeviceLeaseCoordinatorState.openingPresence,
    );

    gateway.openPresenceGate!.complete();
    await acquire;
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.active);
    expect(coordinator.canAdmitMutations, isTrue);
  });

  test(
    'local authority abandon rejects in-flight work and starts fresh state',
    () async {
      final identity = await _identity();
      final gateway = _FakeLeaseGateway()..openPresenceGate = Completer<void>();
      final coordinator = AccountDeviceLeaseCoordinator(
        identity: identity,
        gateway: gateway,
        randomBytes: _Entropy().bytes,
        monotonicNow: () => Duration.zero,
        wallClock: () => _wallNow,
      );

      final acquiring = _acquire(coordinator);
      await gateway.openPresenceStarted.future;
      expect(coordinator.abandonLocalAuthority, throwsStateError);

      gateway.openPresenceGate!.complete();
      await acquiring;
      final firstOpenRequest = gateway.openCalls.single;
      final firstAcquire = gateway.acquireCalls.single;

      coordinator.fence();
      coordinator.abandonLocalAuthority();

      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.idle);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(coordinator.canAdmitMutations, isFalse);

      await _acquire(coordinator);

      expect(gateway.openCalls, hasLength(2));
      expect(gateway.openCalls.last, isNot(firstOpenRequest));
      expect(gateway.acquireCalls, hasLength(2));
      expect(
        gateway.acquireCalls.last.requestId,
        isNot(firstAcquire.requestId),
      );
      expect(
        gateway.acquireCalls.last.holderProof,
        isNot(firstAcquire.holderProof),
      );
    },
  );

  test('stale acquire presence opens a fresh session and request', () async {
    final identity = await _identity();
    final gateway = _FakeLeaseGateway()..staleAcquirePresence = 1;
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => Duration.zero,
      wallClock: () => _wallNow,
    );

    await expectLater(
      _acquire(coordinator),
      throwsA(
        isA<AccountDeviceLeaseRequestException>().having(
          (error) => error.code,
          'code',
          'STALE_RUNTIME_PRESENCE',
        ),
      ),
    );
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.idle);
    expect(coordinator.currentPresence, isNull);
    expect(coordinator.currentReceipt, isNull);

    await _acquire(coordinator);

    expect(gateway.openCalls, hasLength(2));
    expect(gateway.acquireCalls, hasLength(2));
    expect(
      gateway.acquireCalls[1].requestId,
      isNot(gateway.acquireCalls[0].requestId),
    );
    expect(
      gateway.acquireCalls[1].holderProof,
      isNot(gateway.acquireCalls[0].holderProof),
    );
    expect(coordinator.currentPresence!.presenceSessionId, 'presence_2');
    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.active);
  });

  for (final mutation in <String>['session', 'generation']) {
    test('heartbeat rejects a changed presence $mutation', () async {
      final identity = await _identity();
      final gateway = _FakeLeaseGateway();
      final coordinator = AccountDeviceLeaseCoordinator(
        identity: identity,
        gateway: gateway,
        randomBytes: _Entropy().bytes,
        monotonicNow: () => Duration.zero,
        wallClock: () => _wallNow,
      );
      await _acquire(coordinator);
      if (mutation == 'session') {
        gateway.heartbeatPresenceSessionId = 'presence_changed';
      } else {
        gateway.heartbeatPresenceGeneration = 2;
      }

      await expectLater(coordinator.heartbeat(), throwsFormatException);

      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.degraded);
      expect(coordinator.canAdmitMutations, isFalse);
      expect(gateway.heartbeatLeaseRequestIds, isEmpty);
    });
  }
}

Future<AppInstallationIdentityService> _identity() async {
  final preferences = await SharedPreferences.getInstance();
  final identity = AppInstallationIdentityService(
    sharedPreferences: preferences,
    randomBytes: (length) => List<int>.filled(length, 0x44),
  );
  return identity.init();
}

Future<AccountDeviceLeaseReceipt> _acquire(
  AccountDeviceLeaseCoordinator coordinator,
) => coordinator.acquire(
  environment: MaasoEnvironment.test,
  accountUuid: 'account-1',
  deviceLabel: 'Kunhong Mac',
  platform: 'macos',
  appVersion: '1.2.3+4',
);

class _Entropy {
  int _seed = 1;
  final List<int> requestedLengths = <int>[];

  List<int> bytes(int length) {
    requestedLengths.add(length);
    final seed = _seed++;
    return List<int>.generate(length, (index) => (seed + index) & 0xff);
  }
}

class _AcquireCall {
  const _AcquireCall({required this.requestId, required this.holderProof});

  final String requestId;
  final String holderProof;
}

class _FakeLeaseGateway implements AccountDeviceLeaseGateway {
  int acquireTransportFailures = 0;
  int committedAcquireFailures = 0;
  int acquireAuthenticationFailures = 0;
  int acquireConflicts = 0;
  int staleAcquirePresence = 0;
  int staleAcquireLease = 0;
  int heartbeatPresenceFailures = 0;
  int heartbeatLeaseFailures = 0;
  bool stalePresenceHeartbeat = false;
  bool staleHeartbeat = false;
  DateTime leaseExpiresAt = _wallNow.add(const Duration(seconds: 45));
  Completer<void>? openPresenceGate;
  Completer<void>? heartbeatLeaseGate;
  String? heartbeatPresenceSessionId;
  int? heartbeatPresenceGeneration;

  final List<String> openCalls = <String>[];
  final List<_AcquireCall> acquireCalls = <_AcquireCall>[];
  final List<String> presenceHeartbeatRequestIds = <String>[];
  final List<String> heartbeatLeaseRequestIds = <String>[];
  final List<String> releaseProofs = <String>[];
  final Completer<void> openPresenceStarted = Completer<void>();
  final Completer<void> heartbeatLeaseStarted = Completer<void>();

  AccountDevicePresenceReceipt? _presence;
  AccountDeviceLeaseReceipt? _lease;

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
  }) async {
    openCalls.add(requestId);
    if (!openPresenceStarted.isCompleted) openPresenceStarted.complete();
    final presence = _presence ??= _newPresence(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: 'presence_${openCalls.length}',
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
    );
    await openPresenceGate?.future;
    return AccountDevicePresenceOperationResult(
      presence: presence,
      replayed: openCalls.length > 1,
    );
  }

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
    acquireCalls.add(
      _AcquireCall(requestId: requestId, holderProof: holderProof),
    );
    if (acquireTransportFailures > 0) {
      acquireTransportFailures--;
      throw TimeoutException('response lost');
    }
    if (acquireAuthenticationFailures > 0) {
      acquireAuthenticationFailures--;
      throw const AccountDeviceLeaseRequestException(
        statusCode: 401,
        code: 'AUTHENTICATION_REQUIRED',
      );
    }
    if (acquireConflicts > 0) {
      acquireConflicts--;
      throw AccountDeviceLeaseConflict(
        observedEpoch: 4,
        holder: _newPresence(
          installationId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          runtimeInstanceId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          deviceLabel: 'Other device',
          platform: 'android',
          appVersion: '1.0.0',
        ).toHolder(),
        expiresAt: DateTime.utc(2026, 8, 21, 12, 0, 30),
        remainingTtl: const Duration(seconds: 30),
      );
    }
    if (staleAcquirePresence > 0) {
      staleAcquirePresence--;
      _presence = null;
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_PRESENCE',
      );
    }
    final lease = _lease ??= _newLease(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      expiresAt: leaseExpiresAt,
    );
    if (committedAcquireFailures > 0) {
      committedAcquireFailures--;
      throw TimeoutException('response lost after commit');
    }
    if (staleAcquireLease > 0) {
      staleAcquireLease--;
      _lease = null;
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_LEASE',
      );
    }
    return AccountDeviceLeaseOperationResult(
      lease: lease,
      replayed: acquireCalls.length > 1,
    );
  }

  @override
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    heartbeatLeaseRequestIds.add(requestId);
    if (!heartbeatLeaseStarted.isCompleted) heartbeatLeaseStarted.complete();
    if (staleHeartbeat) {
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_LEASE',
      );
    }
    if (heartbeatLeaseFailures > 0) {
      heartbeatLeaseFailures--;
      throw TimeoutException('heartbeat response lost');
    }
    await heartbeatLeaseGate?.future;
    final renewed = _newLease(
      installationId: lease.installationId,
      runtimeInstanceId: lease.runtimeInstanceId,
      presenceSessionId: lease.presenceSessionId,
      expiresAt: leaseExpiresAt,
    );
    _lease = renewed;
    return AccountDeviceLeaseOperationResult(
      lease: renewed,
      replayed: heartbeatLeaseRequestIds.length > 1,
    );
  }

  @override
  Future<AccountDevicePresenceOperationResult> heartbeatPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    presenceHeartbeatRequestIds.add(requestId);
    if (stalePresenceHeartbeat) {
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_PRESENCE',
      );
    }
    if (heartbeatPresenceFailures > 0) {
      heartbeatPresenceFailures--;
      throw TimeoutException('presence heartbeat response lost');
    }
    return AccountDevicePresenceOperationResult(
      presence: _copyPresence(
        presence,
        presenceSessionId:
            heartbeatPresenceSessionId ?? presence.presenceSessionId,
        generation: heartbeatPresenceGeneration ?? presence.generation,
      ),
      replayed: false,
    );
  }

  @override
  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    releaseProofs.add(holderProof);
    _lease = null;
    return AccountDeviceLeaseReleaseResult(
      released: true,
      stale: false,
      epoch: lease.epoch + 1,
    );
  }

  @override
  Future<AccountDevicePresenceCloseResult> closePresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    _presence = null;
    return AccountDevicePresenceCloseResult(
      closed: true,
      stale: false,
      generation: presence.generation,
    );
  }

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async => AccountDeviceLeaseSnapshot(
    state: _lease == null
        ? AccountDeviceLeaseRemoteState.inactive
        : AccountDeviceLeaseRemoteState.active,
    lease: _lease,
  );
}

AccountDevicePresenceReceipt _newPresence({
  required String installationId,
  required String runtimeInstanceId,
  String presenceSessionId = 'presence_1',
  required String deviceLabel,
  required String platform,
  required String appVersion,
}) => AccountDevicePresenceReceipt(
  agentId: 'self',
  installationId: installationId,
  runtimeInstanceId: runtimeInstanceId,
  presenceSessionId: presenceSessionId,
  generation: 1,
  deviceLabel: deviceLabel,
  platform: platform,
  appVersion: appVersion,
  openedAt: DateTime.utc(2026, 8, 21, 12),
  lastSeenAt: DateTime.utc(2026, 8, 21, 12),
  expiresAt: DateTime.utc(2026, 8, 21, 12, 1),
  remainingTtl: const Duration(seconds: 60),
  renewAfter: const Duration(seconds: 20),
);

AccountDeviceLeaseReceipt _newLease({
  required String installationId,
  required String runtimeInstanceId,
  required String presenceSessionId,
  DateTime? expiresAt,
}) {
  final holder = AccountDeviceLeaseHolder(
    installationId: installationId,
    runtimeInstanceId: runtimeInstanceId,
    presenceSessionId: presenceSessionId,
    deviceLabel: 'Kunhong Mac',
    platform: 'macos',
    lastSeenAt: DateTime.utc(2026, 8, 21, 12),
  );
  return AccountDeviceLeaseReceipt(
    agentId: 'self',
    leaseId: 'lease_1',
    epoch: 1,
    installationId: installationId,
    runtimeInstanceId: runtimeInstanceId,
    presenceSessionId: presenceSessionId,
    expiresAt: expiresAt ?? _wallNow.add(const Duration(seconds: 45)),
    remainingTtl: const Duration(seconds: 45),
    renewAfter: const Duration(seconds: 15),
    holder: holder,
  );
}

AccountDevicePresenceReceipt _copyPresence(
  AccountDevicePresenceReceipt source, {
  required String presenceSessionId,
  required int generation,
}) => AccountDevicePresenceReceipt(
  agentId: source.agentId,
  installationId: source.installationId,
  runtimeInstanceId: source.runtimeInstanceId,
  presenceSessionId: presenceSessionId,
  generation: generation,
  deviceLabel: source.deviceLabel,
  platform: source.platform,
  appVersion: source.appVersion,
  openedAt: source.openedAt,
  lastSeenAt: source.lastSeenAt,
  expiresAt: source.expiresAt,
  remainingTtl: source.remainingTtl,
  renewAfter: source.renewAfter,
);

final DateTime _wallNow = DateTime.utc(2026, 8, 21, 12);
