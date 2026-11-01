import 'dart:convert';
import 'dart:math';

import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';

part 'account_device_handoff_authority.dart';

typedef AccountDeviceLeaseMonotonicClock = Duration Function();
typedef AccountDeviceLeaseWallClock = DateTime Function();

/// A generation-bound capability for one exact active runtime lease.
///
/// The holder proof deliberately has no getter and is only copied directly
/// into an outbound request after the coordinator confirms this generation is
/// still current. Its string representation never includes the proof.
final class AccountDeviceLeaseRequestAuthority {
  const AccountDeviceLeaseRequestAuthority._({
    required AccountDeviceLeaseCoordinator coordinator,
    required AccountDeviceLeaseReceipt receipt,
    required String holderProof,
    required int authorityGeneration,
  }) : _coordinator = coordinator,
       _receipt = receipt,
       _holderProof = holderProof,
       _authorityGeneration = authorityGeneration;

  final AccountDeviceLeaseCoordinator _coordinator;
  final AccountDeviceLeaseReceipt _receipt;
  final String _holderProof;
  final int _authorityGeneration;

  String get agentId => _receipt.agentId;
  String get leaseId => _receipt.leaseId;
  int get leaseEpoch => _receipt.epoch;
  String get runtimeInstanceId => _receipt.runtimeInstanceId;
  String get presenceSessionId => _receipt.presenceSessionId;

  void requireCurrent() => _coordinator._requireRequestAuthorityCurrent(
    receipt: _receipt,
    holderProof: _holderProof,
    authorityGeneration: _authorityGeneration,
  );

  /// Adds this proof only to the fixed Maaso realtime-session creation route.
  ///
  /// The destination check lives beside the proof so a future caller cannot
  /// reuse this capability for an arbitrary JSON request.
  void authorizeRealtimeSessionCreation(
    Map<String, Object?> request, {
    required Uri destination,
  }) {
    requireCurrent();
    _requireBoundRealtimeDestination(
      destination: destination,
      expectedPath: '/v1/realtime/sessions',
    );
    request.addAll(<String, Object>{
      'agentId': agentId,
      'leaseId': leaseId,
      'epoch': leaseEpoch,
      'runtimeInstanceId': runtimeInstanceId,
      'presenceSessionId': presenceSessionId,
      'holderProof': _holderProof,
    });
  }

  /// The shared-world proof is private and may only reach these owner routes.
  void authorizeSharedWorldRequest(
    Map<String, Object?> request, {
    required Uri destination,
  }) {
    requireCurrent();
    const paths = <String>{};
    if (!paths.contains(destination.path)) {
      throw StateError('Shared World proof destination is not authorized');
    }
    _requireBoundRealtimeDestination(
      destination: destination,
      expectedPath: destination.path,
    );
    if (request.containsKey('agentId') && request['agentId'] != agentId) {
      throw StateError('Shared World Agent does not match runtime authority');
    }
    request['leaseCredential'] = <String, Object>{
      'leaseId': leaseId,
      'epoch': leaseEpoch,
      'runtimeInstanceId': runtimeInstanceId,
      'presenceSessionId': presenceSessionId,
      'holderProof': _holderProof,
    };
  }

  /// Adds this proof only to the exact same-origin action stream for
  /// [sessionId].
  void authorizeRealtimeActionStream(
    Map<String, String> headers, {
    required Uri destination,
    required String sessionId,
  }) {
    requireCurrent();
    if (sessionId.length < 8 ||
        sessionId.length > 64 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(sessionId)) {
      throw StateError('Realtime session id is not safe');
    }
    _requireBoundRealtimeDestination(
      destination: destination,
      expectedPath:
          '/v1/realtime/sessions/${Uri.encodeComponent(sessionId)}/actions',
    );
    headers.addAll(<String, String>{
      'X-Maaso-Runtime-Agent-Id': agentId,
      'X-Maaso-Runtime-Lease-Id': leaseId,
      'X-Maaso-Runtime-Lease-Epoch': leaseEpoch.toString(),
      'X-Maaso-Runtime-Instance-Id': runtimeInstanceId,
      'X-Maaso-Runtime-Presence-Session-Id': presenceSessionId,
      'X-Maaso-Runtime-Holder-Proof': _holderProof,
    });
  }

  void _requireBoundRealtimeDestination({
    required Uri destination,
    required String expectedPath,
  }) {
    final environment = _coordinator._requiredScope().environment;
    final base = Uri.parse(environment.baseUrl);
    if (base.scheme.toLowerCase() != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw StateError('Configured Maaso realtime origin is not safe');
    }
    if (destination.scheme.toLowerCase() != 'https' ||
        destination.host.isEmpty ||
        destination.userInfo.isNotEmpty ||
        destination.hasQuery ||
        destination.hasFragment ||
        destination.path != expectedPath ||
        destination.host.toLowerCase() != base.host.toLowerCase() ||
        _effectiveHttpsPort(destination) != _effectiveHttpsPort(base)) {
      throw StateError('Realtime proof destination is not authorized');
    }
  }

  static int _effectiveHttpsPort(Uri uri) => uri.hasPort ? uri.port : 443;

  @override
  String toString() =>
      'AccountDeviceLeaseRequestAuthority(agentId: $agentId, '
      'leaseId: $leaseId, epoch: $leaseEpoch, '
      'runtimeInstanceId: $runtimeInstanceId, '
      'presenceSessionId: $presenceSessionId, holderProof: <redacted>)';
}

enum AccountDeviceLeaseCoordinatorState {
  idle,
  openingPresence,
  standby,
  acquiring,
  active,
  degraded,
  conflict,
  fenced,
  closed,
}

class AccountDeviceLeaseCoordinator {
  factory AccountDeviceLeaseCoordinator({
    required AppInstallationIdentityService identity,
    required AccountDeviceLeaseGateway gateway,
    SecureRandomBytesGenerator? randomBytes,
    AccountDeviceLeaseMonotonicClock? monotonicNow,
    AccountDeviceLeaseWallClock? wallClock,
    Duration safetyMargin = const Duration(seconds: 5),
    Duration maximumLeaseTtl = const Duration(minutes: 5),
  }) {
    final stopwatch = Stopwatch()..start();
    return AccountDeviceLeaseCoordinator._(
      identity: identity,
      gateway: gateway,
      randomBytes: randomBytes ?? _secureRandomBytes,
      monotonicNow: monotonicNow ?? () => stopwatch.elapsed,
      wallClock: wallClock ?? DateTime.now,
      safetyMargin: safetyMargin,
      maximumLeaseTtl: maximumLeaseTtl,
    );
  }

  AccountDeviceLeaseCoordinator._({
    required AppInstallationIdentityService identity,
    required AccountDeviceLeaseGateway gateway,
    required SecureRandomBytesGenerator randomBytes,
    required AccountDeviceLeaseMonotonicClock monotonicNow,
    required AccountDeviceLeaseWallClock wallClock,
    required this.safetyMargin,
    required this.maximumLeaseTtl,
  }) : _identity = identity,
       _gateway = gateway,
       _randomBytes = randomBytes,
       _monotonicNow = monotonicNow,
       _wallClock = wallClock {
    if (safetyMargin.isNegative) {
      throw ArgumentError.value(
        safetyMargin,
        'safetyMargin',
        'must not be negative',
      );
    }
    if (maximumLeaseTtl <= Duration.zero) {
      throw ArgumentError.value(
        maximumLeaseTtl,
        'maximumLeaseTtl',
        'must be positive',
      );
    }
  }

  final AppInstallationIdentityService _identity;
  final AccountDeviceLeaseGateway _gateway;
  final SecureRandomBytesGenerator _randomBytes;
  final AccountDeviceLeaseMonotonicClock _monotonicNow;
  final AccountDeviceLeaseWallClock _wallClock;
  final Duration safetyMargin;
  final Duration maximumLeaseTtl;

  AccountDeviceLeaseCoordinatorState _state =
      AccountDeviceLeaseCoordinatorState.idle;
  _AccountDeviceLeaseScope? _scope;
  AccountDevicePresenceReceipt? _presence;
  AccountDeviceLeaseReceipt? _lease;
  String? _holderProof;
  Duration? _admissionDeadline;
  _PendingPresenceOpen? _pendingPresenceOpen;
  _PendingLeaseAcquire? _pendingAcquire;
  String? _pendingPresenceHeartbeatRequestId;
  String? _pendingLeaseHeartbeatRequestId;
  String? _pendingReleaseRequestId;
  String? _pendingPresenceCloseRequestId;
  bool _operationInFlight = false;
  int _authorityGeneration = 0;
  _PendingHandoffAuthority? _pendingHandoffAuthority;
  String? _transferredLeaseAwaitingMount;

  AccountDeviceLeaseCoordinatorState get state => _state;
  AccountDevicePresenceReceipt? get currentPresence => _presence;
  AccountDeviceLeaseReceipt? get currentReceipt => _lease;
  bool get hasPendingAcquire => _pendingAcquire != null;

  bool get canAdmitMutations {
    final deadline = _admissionDeadline;
    return _state == AccountDeviceLeaseCoordinatorState.active &&
        _lease != null &&
        _holderProof != null &&
        deadline != null &&
        _monotonicNow() < deadline;
  }

  Duration? get admissionTimeRemaining {
    final deadline = _admissionDeadline;
    if (deadline == null) return null;
    final remaining = deadline - _monotonicNow();
    return remaining.isNegative ? Duration.zero : remaining;
  }

  AccountDeviceLeaseRequestAuthority requireCurrentRequestAuthority() {
    enforceLocalDeadline();
    if (!canAdmitMutations) {
      throw StateError('No current runtime lease authority is available');
    }
    return AccountDeviceLeaseRequestAuthority._(
      coordinator: this,
      receipt: _requiredLease(),
      holderProof: _requiredHolderProof(),
      authorityGeneration: _authorityGeneration,
    );
  }

  /// Opens this runtime's proof-free presence for shadow discovery only.
  ///
  /// This path deliberately cannot acquire a lease or create a holder proof.
  /// A later explicit [acquire] reuses the exact same presence session.
  Future<AccountDevicePresenceReceipt> openObservationPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    String agentId = 'self',
  }) => _runOperation(() async {
    _ensureOpen();
    if (!_identity.isInitialized) {
      throw StateError('App installation identity is not initialized');
    }
    if (_lease != null || _holderProof != null || _pendingAcquire != null) {
      throw StateError(
        'Release or resolve runtime lease authority before observing presence',
      );
    }
    final requestedScope = _AccountDeviceLeaseScope(
      environment: environment,
      accountUuid: _accountUuid(accountUuid),
      agentId: _agentId(agentId),
    );
    final existingScope = _scope;
    if (existingScope != null && !existingScope.matches(requestedScope)) {
      throw StateError(
        'Close the existing runtime presence before changing lease scope',
      );
    }
    _scope = requestedScope;
    final operationGeneration = _authorityGeneration;
    await _ensurePresence(
      requestedScope,
      expectedGeneration: operationGeneration,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
    );
    _ensureOperationCurrent(operationGeneration);
    _state = AccountDeviceLeaseCoordinatorState.standby;
    return _requiredPresence();
  });

  /// Renews only the proof-free shadow presence.
  Future<AccountDevicePresenceReceipt> heartbeatObservationPresence() =>
      _runOperation(() async {
        _ensureOpen();
        if (_lease != null || _holderProof != null || _pendingAcquire != null) {
          throw StateError(
            'Use the authority heartbeat while a runtime lease is active',
          );
        }
        final scope = _requiredScope();
        final presence = _requiredPresence();
        final operationGeneration = _authorityGeneration;
        try {
          final result = await _gateway.heartbeatPresence(
            environment: scope.environment,
            accountUuid: scope.accountUuid,
            presence: presence,
            requestId: _pendingPresenceHeartbeatRequestId ??= _newOpaqueId(16),
          );
          _ensureOperationCurrent(operationGeneration);
          _validateHeartbeatPresence(result.presence, presence, scope);
          _presence = result.presence;
          _pendingPresenceHeartbeatRequestId = null;
          _state = AccountDeviceLeaseCoordinatorState.standby;
          return result.presence;
        } on AccountDeviceLeaseRequestException catch (error) {
          if (error.code == 'STALE_RUNTIME_PRESENCE') {
            _authorityGeneration++;
            _clearPresence();
            _state = AccountDeviceLeaseCoordinatorState.idle;
          } else {
            _degradeIfCurrent(operationGeneration);
          }
          rethrow;
        } catch (_) {
          _degradeIfCurrent(operationGeneration);
          rethrow;
        }
      });

  /// Fences proof-free observation work synchronously.
  ///
  /// This is safe during an in-flight open or heartbeat: the generation check
  /// prevents a late response from attaching to a new account scope. When an
  /// operation is in flight its receipt is abandoned and the server TTL is the
  /// cleanup fallback; otherwise an existing receipt is retained so the caller
  /// can still perform an exact [closePresence].
  void cancelObservationPresence() {
    _ensureOpen();
    if (_lease != null || _holderProof != null || _pendingAcquire != null) {
      throw StateError(
        'Cannot cancel observation while lease authority exists',
      );
    }
    _authorityGeneration++;
    if (_operationInFlight) {
      _clearPresence();
      _state = AccountDeviceLeaseCoordinatorState.idle;
      return;
    }
    _pendingPresenceOpen = null;
    _pendingPresenceHeartbeatRequestId = null;
    _state = _presence == null
        ? AccountDeviceLeaseCoordinatorState.idle
        : AccountDeviceLeaseCoordinatorState.fenced;
  }

  Future<AccountDeviceLeaseReceipt> acquire({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    String agentId = 'self',
  }) => _runOperation(() async {
    _ensureOpen();
    if (!_identity.isInitialized) {
      throw StateError('App installation identity is not initialized');
    }
    if (_lease != null || _holderProof != null) {
      throw StateError('A runtime lease is already held or awaiting release');
    }
    final requestedScope = _AccountDeviceLeaseScope(
      environment: environment,
      accountUuid: _accountUuid(accountUuid),
      agentId: _agentId(agentId),
    );
    final existingScope = _scope;
    if (existingScope != null && !existingScope.matches(requestedScope)) {
      throw StateError(
        'Close the existing runtime presence before changing lease scope',
      );
    }
    _scope = requestedScope;
    final operationGeneration = _authorityGeneration;
    await _ensurePresence(
      requestedScope,
      expectedGeneration: operationGeneration,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
    );
    _ensureOperationCurrent(operationGeneration);
    final presence = _presence!;
    final pending = _pendingAcquire ??= _PendingLeaseAcquire(
      requestId: _newOpaqueId(16),
      holderProof: _newHolderProof(),
    );
    _state = AccountDeviceLeaseCoordinatorState.acquiring;
    final requestAnchor = _leaseRequestAnchor(operationGeneration);
    late final AccountDeviceLeaseOperationResult result;
    try {
      result = await _gateway.acquireLease(
        environment: requestedScope.environment,
        accountUuid: requestedScope.accountUuid,
        agentId: requestedScope.agentId,
        installationId: _identity.installationId,
        runtimeInstanceId: _identity.runtimeInstanceId,
        presenceSessionId: presence.presenceSessionId,
        holderProof: pending.holderProof,
        requestId: pending.requestId,
      );
    } on AccountDeviceLeaseConflict {
      _pendingAcquire = null;
      _state = AccountDeviceLeaseCoordinatorState.conflict;
      rethrow;
    } on AccountDeviceLeaseRequestException catch (error) {
      if (error.code == 'STALE_RUNTIME_PRESENCE') {
        _authorityGeneration++;
        _pendingAcquire = null;
        _holderProof = null;
        _clearPresence();
        _state = AccountDeviceLeaseCoordinatorState.idle;
      } else if (error.code == 'STALE_RUNTIME_LEASE') {
        // A replay can outlive a lease that the server committed before its
        // response was lost. The stale result proves no live mutation
        // authority remains, so the exact pending proof can be discarded and
        // the still-known presence can proceed through normal exact close.
        _pendingAcquire = null;
        _holderProof = null;
        _state = _presence == null
            ? AccountDeviceLeaseCoordinatorState.idle
            : AccountDeviceLeaseCoordinatorState.standby;
      } else if (!pending.hasUncertainDispatch &&
          (error.code == 'AUTHENTICATION_REQUIRED' ||
              error.statusCode == 401 ||
              error.statusCode == 403)) {
        // Authentication rejects before the authority handler runs, so this
        // first dispatch cannot have committed a lease and its proof is not
        // needed for idempotent recovery. After any uncertain dispatch, a
        // later 401/403 says nothing about whether the earlier request
        // committed and the exact request/proof must be retained.
        _pendingAcquire = null;
        _state = AccountDeviceLeaseCoordinatorState.standby;
      } else {
        pending.hasUncertainDispatch = true;
        _degradeIfCurrent(operationGeneration);
      }
      rethrow;
    } catch (_) {
      pending.hasUncertainDispatch = true;
      _degradeIfCurrent(operationGeneration);
      rethrow;
    }
    try {
      _validateLease(result.lease, requestedScope, presence);
      if (operationGeneration != _authorityGeneration) {
        // A shadow observation or local deadline may fence while the server
        // is still deciding the acquire. Preserve the exact late authority
        // and its in-memory proof so detached cleanup can release it instead
        // of leaving an unseen lease alive until TTL.
        _lease = result.lease;
        _holderProof = pending.holderProof;
        _pendingAcquire = null;
      }
      _ensureOperationCurrent(operationGeneration);
    } catch (_) {
      if (identical(_pendingAcquire, pending)) {
        pending.hasUncertainDispatch = true;
      }
      _degradeIfCurrent(operationGeneration);
      rethrow;
    }
    _lease = result.lease;
    _holderProof = pending.holderProof;
    _pendingAcquire = null;
    if (!_setAdmissionDeadline(result.lease, requestAnchor)) {
      throw StateError('The acquired runtime lease is already fenced locally');
    }
    return result.lease;
  });

  Future<AccountDeviceLeaseSnapshot> inspectCurrent({
    required MaasoEnvironment environment,
    required String accountUuid,
    String agentId = 'self',
  }) => _runOperation(() {
    _ensureOpen();
    return _gateway.currentLease(
      environment: environment,
      accountUuid: _accountUuid(accountUuid),
      agentId: _agentId(agentId),
    );
  });

  Future<AccountDeviceLeaseReceipt> heartbeat() => _runOperation(() async {
    _ensureOpen();
    final scope = _requiredScope();
    final presence = _requiredPresence();
    final lease = _requiredLease();
    final proof = _requiredHolderProof();
    final operationGeneration = _authorityGeneration;
    if (_state == AccountDeviceLeaseCoordinatorState.fenced ||
        _deadlineReached()) {
      enforceLocalDeadline();
      throw StateError('The runtime lease admission deadline has passed');
    }
    try {
      final presenceResult = await _gateway.heartbeatPresence(
        environment: scope.environment,
        accountUuid: scope.accountUuid,
        presence: presence,
        requestId: _pendingPresenceHeartbeatRequestId ??= _newOpaqueId(16),
      );
      _ensureOperationCurrent(operationGeneration);
      if (_deadlineReached()) {
        _pendingPresenceHeartbeatRequestId = null;
        enforceLocalDeadline();
        throw StateError('The runtime lease expired during presence renewal');
      }
      _validateHeartbeatPresence(presenceResult.presence, presence, scope);
      _presence = presenceResult.presence;
      _pendingPresenceHeartbeatRequestId = null;

      final requestAnchor = _leaseRequestAnchor(operationGeneration);
      final leaseResult = await _gateway.heartbeatLease(
        environment: scope.environment,
        accountUuid: scope.accountUuid,
        lease: lease,
        holderProof: proof,
        requestId: _pendingLeaseHeartbeatRequestId ??= _newOpaqueId(16),
      );
      _ensureOperationCurrent(operationGeneration);
      if (_deadlineReached()) {
        _pendingLeaseHeartbeatRequestId = null;
        enforceLocalDeadline();
        throw StateError('The runtime lease expired during lease renewal');
      }
      _validateHeartbeatLease(leaseResult.lease, lease, _presence!);
      _lease = leaseResult.lease;
      _pendingLeaseHeartbeatRequestId = null;
      if (!_setAdmissionDeadline(leaseResult.lease, requestAnchor)) {
        throw StateError('The renewed runtime lease is already fenced locally');
      }
      return leaseResult.lease;
    } on AccountDeviceLeaseRequestException catch (error) {
      if (error.isStaleAuthority) {
        _applyRemoteFence(
          stalePresence: error.code == 'STALE_RUNTIME_PRESENCE',
        );
      } else {
        _degradeIfCurrent(operationGeneration);
      }
      rethrow;
    } catch (_) {
      _degradeIfCurrent(operationGeneration);
      rethrow;
    }
  });

  Future<AccountDeviceLeaseReleaseResult> release() => _runOperation(() async {
    _ensureOpen();
    final scope = _requiredScope();
    final lease = _requiredLease();
    final proof = _requiredHolderProof();
    try {
      final result = await _gateway.releaseLease(
        environment: scope.environment,
        accountUuid: scope.accountUuid,
        lease: lease,
        holderProof: proof,
        requestId: _pendingReleaseRequestId ??= _newOpaqueId(16),
      );
      _authorityGeneration++;
      _clearLeaseAuthority();
      _state = _presence == null
          ? AccountDeviceLeaseCoordinatorState.idle
          : AccountDeviceLeaseCoordinatorState.standby;
      return result;
    } on AccountDeviceLeaseRequestException catch (error) {
      if (error.isStaleAuthority) {
        _authorityGeneration++;
        _clearLeaseAuthority();
        _state = _presence == null
            ? AccountDeviceLeaseCoordinatorState.fenced
            : AccountDeviceLeaseCoordinatorState.standby;
      } else {
        _state = AccountDeviceLeaseCoordinatorState.degraded;
      }
      rethrow;
    } catch (_) {
      _state = AccountDeviceLeaseCoordinatorState.degraded;
      rethrow;
    }
  });

  Future<AccountDevicePresenceCloseResult> closePresence() =>
      _runOperation(() async {
        _ensureOpen();
        if (_lease != null || _holderProof != null || _pendingAcquire != null) {
          throw StateError(
            'Release or resolve the runtime lease before closing presence',
          );
        }
        final scope = _requiredScope();
        final presence = _requiredPresence();
        try {
          final result = await _gateway.closePresence(
            environment: scope.environment,
            accountUuid: scope.accountUuid,
            presence: presence,
            requestId: _pendingPresenceCloseRequestId ??= _newOpaqueId(16),
          );
          _authorityGeneration++;
          _clearPresence();
          _state = AccountDeviceLeaseCoordinatorState.idle;
          return result;
        } on AccountDeviceLeaseRequestException catch (error) {
          if (error.isStaleAuthority) {
            _authorityGeneration++;
            _clearPresence();
            _state = AccountDeviceLeaseCoordinatorState.idle;
          } else {
            _state = AccountDeviceLeaseCoordinatorState.degraded;
          }
          rethrow;
        } catch (_) {
          _state = AccountDeviceLeaseCoordinatorState.degraded;
          rethrow;
        }
      });

  void enforceLocalDeadline() {
    if (_state == AccountDeviceLeaseCoordinatorState.closed ||
        _state == AccountDeviceLeaseCoordinatorState.fenced ||
        !_deadlineReached()) {
      return;
    }
    fence();
  }

  /// Synchronously invalidates every in-flight authority operation while
  /// retaining the exact receipt/proof needed for best-effort release after
  /// the local account runtime has drained.
  void fence() {
    if (_state == AccountDeviceLeaseCoordinatorState.closed ||
        _state == AccountDeviceLeaseCoordinatorState.fenced) {
      return;
    }
    _authorityGeneration++;
    _state = AccountDeviceLeaseCoordinatorState.fenced;
  }

  /// Forgets locally retained authority without making a remote request.
  ///
  /// This is the terminal sign-out fallback for an exact release/close that
  /// could not be confirmed. The server-side authority is left to expire by
  /// TTL; no credential is retained to retry it after account sign-out.
  void abandonLocalAuthority() {
    _ensureOpen();
    if (_operationInFlight) {
      throw StateError(
        'Wait for the in-flight runtime lease operation before abandoning',
      );
    }
    _authorityGeneration++;
    _clearLeaseAuthority();
    _clearPresence();
    _state = AccountDeviceLeaseCoordinatorState.idle;
  }

  void close() {
    if (_state == AccountDeviceLeaseCoordinatorState.closed) return;
    if (_operationInFlight) {
      throw StateError(
        'Wait for the in-flight runtime lease operation before closing',
      );
    }
    if (_lease != null || _holderProof != null || _pendingAcquire != null) {
      throw StateError(
        'Release or resolve the runtime lease before closing its coordinator',
      );
    }
    _authorityGeneration++;
    _clearPresence();
    _state = AccountDeviceLeaseCoordinatorState.closed;
  }

  Future<void> _ensurePresence(
    _AccountDeviceLeaseScope scope, {
    required int expectedGeneration,
    required String deviceLabel,
    required String platform,
    required String appVersion,
  }) async {
    final existing = _presence;
    if (existing != null) {
      _validatePresence(existing, scope);
      return;
    }
    final pending = _pendingPresenceOpen ??= _PendingPresenceOpen(
      requestId: _newOpaqueId(16),
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
    );
    if (pending.deviceLabel != deviceLabel ||
        pending.platform != platform ||
        pending.appVersion != appVersion) {
      throw StateError(
        'Retry an uncertain presence open with the original device metadata',
      );
    }
    _state = AccountDeviceLeaseCoordinatorState.openingPresence;
    try {
      final result = await _gateway.openPresence(
        environment: scope.environment,
        accountUuid: scope.accountUuid,
        agentId: scope.agentId,
        installationId: _identity.installationId,
        runtimeInstanceId: _identity.runtimeInstanceId,
        deviceLabel: deviceLabel,
        platform: platform,
        appVersion: appVersion,
        requestId: pending.requestId,
      );
      _ensureOperationCurrent(expectedGeneration);
      _validatePresence(result.presence, scope);
      _presence = result.presence;
      _pendingPresenceOpen = null;
      _state = AccountDeviceLeaseCoordinatorState.standby;
    } catch (_) {
      _degradeIfCurrent(expectedGeneration);
      rethrow;
    }
  }

  void _validatePresence(
    AccountDevicePresenceReceipt presence,
    _AccountDeviceLeaseScope scope,
  ) {
    if (presence.agentId != scope.agentId ||
        presence.installationId != _identity.installationId ||
        presence.runtimeInstanceId != _identity.runtimeInstanceId) {
      throw const FormatException(
        'runtime presence does not match the requested device identity',
      );
    }
  }

  void _validateLease(
    AccountDeviceLeaseReceipt lease,
    _AccountDeviceLeaseScope scope,
    AccountDevicePresenceReceipt presence,
  ) {
    if (lease.agentId != scope.agentId ||
        lease.installationId != _identity.installationId ||
        lease.runtimeInstanceId != _identity.runtimeInstanceId ||
        lease.presenceSessionId != presence.presenceSessionId) {
      throw const FormatException(
        'runtime lease does not match the requested authority identity',
      );
    }
  }

  void _validateHeartbeatPresence(
    AccountDevicePresenceReceipt next,
    AccountDevicePresenceReceipt previous,
    _AccountDeviceLeaseScope scope,
  ) {
    _validatePresence(next, scope);
    if (next.presenceSessionId != previous.presenceSessionId ||
        next.generation != previous.generation ||
        next.deviceLabel != previous.deviceLabel ||
        next.platform != previous.platform ||
        next.appVersion != previous.appVersion ||
        next.openedAt != previous.openedAt) {
      throw const FormatException(
        'runtime presence heartbeat changed immutable presence identity',
      );
    }
  }

  void _validateHeartbeatLease(
    AccountDeviceLeaseReceipt next,
    AccountDeviceLeaseReceipt previous,
    AccountDevicePresenceReceipt presence,
  ) {
    _validateLease(next, _requiredScope(), presence);
    if (next.leaseId != previous.leaseId || next.epoch != previous.epoch) {
      throw const FormatException(
        'runtime lease heartbeat changed immutable authority identity',
      );
    }
  }

  _LeaseRequestAnchor _leaseRequestAnchor(int expectedGeneration) =>
      _LeaseRequestAnchor(
        monotonicDispatchedAt: _monotonicNow(),
        wallDispatchedAt: _wallClock().toUtc(),
        authorityGeneration: expectedGeneration,
      );

  bool _setAdmissionDeadline(
    AccountDeviceLeaseReceipt lease,
    _LeaseRequestAnchor requestAnchor,
  ) {
    _ensureOperationCurrent(requestAnchor.authorityGeneration);
    final absoluteTtl = lease.expiresAt.difference(
      requestAnchor.wallDispatchedAt,
    );
    var conservativeTtl = lease.remainingTtl;
    if (absoluteTtl < conservativeTtl) conservativeTtl = absoluteTtl;
    if (maximumLeaseTtl < conservativeTtl) {
      conservativeTtl = maximumLeaseTtl;
    }
    final usableTtl = conservativeTtl - safetyMargin;
    final deadline =
        requestAnchor.monotonicDispatchedAt +
        (usableTtl.isNegative ? Duration.zero : usableTtl);
    _admissionDeadline = deadline;
    if (usableTtl <= Duration.zero || _monotonicNow() >= deadline) {
      _authorityGeneration++;
      _state = AccountDeviceLeaseCoordinatorState.fenced;
      return false;
    }
    _state = AccountDeviceLeaseCoordinatorState.active;
    return true;
  }

  void _applyRemoteFence({required bool stalePresence}) {
    _authorityGeneration++;
    _clearLeaseAuthority();
    if (stalePresence) _clearPresence();
    _state = AccountDeviceLeaseCoordinatorState.fenced;
  }

  void _clearLeaseAuthority() {
    _transferredLeaseAwaitingMount = null;
    _lease = null;
    _holderProof = null;
    _admissionDeadline = null;
    _pendingAcquire = null;
    _pendingLeaseHeartbeatRequestId = null;
    _pendingReleaseRequestId = null;
  }

  void _clearPresence() {
    _pendingHandoffAuthority = null;
    _transferredLeaseAwaitingMount = null;
    _presence = null;
    _scope = null;
    // Acquire idempotency is scoped to the exact presence session. Once that
    // presence is closed or fenced, retrying its request/proof against a new
    // presence would be an invalid cross-session replay.
    _pendingAcquire = null;
    _pendingPresenceOpen = null;
    _pendingPresenceHeartbeatRequestId = null;
    _pendingPresenceCloseRequestId = null;
  }

  bool _deadlineReached() {
    final deadline = _admissionDeadline;
    return deadline != null && _monotonicNow() >= deadline;
  }

  void _ensureOperationCurrent(int expectedGeneration) {
    if (_state == AccountDeviceLeaseCoordinatorState.closed ||
        expectedGeneration != _authorityGeneration) {
      throw StateError(
        'The runtime lease operation was fenced before completion',
      );
    }
  }

  void _requireRequestAuthorityCurrent({
    required AccountDeviceLeaseReceipt receipt,
    required String holderProof,
    required int authorityGeneration,
  }) {
    enforceLocalDeadline();
    final current = _lease;
    if (!canAdmitMutations ||
        authorityGeneration != _authorityGeneration ||
        current == null ||
        current.agentId != receipt.agentId ||
        current.leaseId != receipt.leaseId ||
        current.epoch != receipt.epoch ||
        current.runtimeInstanceId != receipt.runtimeInstanceId ||
        current.presenceSessionId != receipt.presenceSessionId ||
        _holderProof != holderProof) {
      throw StateError('The runtime request authority is no longer current');
    }
  }

  void _degradeIfCurrent(int expectedGeneration) {
    if (_state != AccountDeviceLeaseCoordinatorState.closed &&
        expectedGeneration == _authorityGeneration) {
      _state = AccountDeviceLeaseCoordinatorState.degraded;
    }
  }

  _AccountDeviceLeaseScope _requiredScope() =>
      _scope ?? (throw StateError('No runtime authority scope is open'));

  AccountDevicePresenceReceipt _requiredPresence() =>
      _presence ?? (throw StateError('No runtime presence is open'));

  AccountDeviceLeaseReceipt _requiredLease() =>
      _lease ?? (throw StateError('No runtime lease is held'));

  String _requiredHolderProof() =>
      _holderProof ?? (throw StateError('No runtime lease proof is held'));

  void _ensureOpen() {
    if (_state == AccountDeviceLeaseCoordinatorState.closed) {
      throw StateError('Runtime lease coordinator is closed');
    }
  }

  Future<T> _runOperation<T>(Future<T> Function() operation) async {
    if (_operationInFlight) {
      throw StateError('A runtime lease operation is already in flight');
    }
    _operationInFlight = true;
    try {
      return await operation();
    } finally {
      _operationInFlight = false;
    }
  }

  String _newHolderProof() =>
      base64UrlEncode(_validatedRandomBytes(32)).replaceAll('=', '');

  String _newOpaqueId(int byteLength) => _validatedRandomBytes(
    byteLength,
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  List<int> _validatedRandomBytes(int length) {
    final bytes = _randomBytes(length);
    if (bytes.length != length ||
        bytes.any((value) => value < 0 || value > 255)) {
      throw StateError('Secure random byte generator returned invalid data');
    }
    return bytes;
  }

  static String _accountUuid(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized != value || normalized.length > 128) {
      throw const FormatException('runtime authority account is invalid');
    }
    return normalized;
  }

  static String _agentId(String value) {
    if (value != 'self') {
      throw const FormatException('runtime authority agentId is invalid');
    }
    return value;
  }

  @override
  String toString() =>
      'AccountDeviceLeaseCoordinator(state: $_state, lease: $_lease, '
      'presence: $_presence)';

  static List<int> _secureRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}

class _AccountDeviceLeaseScope {
  const _AccountDeviceLeaseScope({
    required this.environment,
    required this.accountUuid,
    required this.agentId,
  });

  final MaasoEnvironment environment;
  final String accountUuid;
  final String agentId;

  bool matches(_AccountDeviceLeaseScope other) =>
      environment == other.environment &&
      accountUuid == other.accountUuid &&
      agentId == other.agentId;
}

class _LeaseRequestAnchor {
  const _LeaseRequestAnchor({
    required this.monotonicDispatchedAt,
    required this.wallDispatchedAt,
    required this.authorityGeneration,
  });

  final Duration monotonicDispatchedAt;
  final DateTime wallDispatchedAt;
  final int authorityGeneration;
}

class _PendingPresenceOpen {
  const _PendingPresenceOpen({
    required this.requestId,
    required this.deviceLabel,
    required this.platform,
    required this.appVersion,
  });

  final String requestId;
  final String deviceLabel;
  final String platform;
  final String appVersion;
}

class _PendingLeaseAcquire {
  _PendingLeaseAcquire({required this.requestId, required this.holderProof});

  final String requestId;
  final String holderProof;
  bool hasUncertainDispatch = false;
}
