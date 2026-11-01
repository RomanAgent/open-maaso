part of 'account_device_lease_coordinator.dart';

final class _PendingHandoffAuthority {
  const _PendingHandoffAuthority(this.handoffId, this.proof);
  final String handoffId;
  final String proof;
}

/// Keeps all handoff proofs in the same owner as ordinary runtime authority.
/// Callers receive only public receipts, never the target's pending proof.
extension AccountDeviceHandoffAuthority on AccountDeviceLeaseCoordinator {
  Future<AccountHandoffDrainResult> drainForHandoff(
    AccountDeviceHandoffGateway gateway, {
    required String requestId,
  }) => _runOperation(() async {
    final authority = requireCurrentRequestAuthority();
    final generation = _authorityGeneration;
    final scope = _requiredScope();
    final result = await gateway.drainHandoff(
      environment: scope.environment,
      accountUuid: scope.accountUuid,
      body: _handoffLeaseBody(requestId),
    );
    _ensureOperationCurrent(generation);
    authority.requireCurrent();
    return result;
  });
  bool get hasTransferredLeaseAwaitingMount =>
      _transferredLeaseAwaitingMount != null && canAdmitMutations;

  AccountDeviceLeaseReceipt consumeTransferredLeaseForMount() {
    enforceLocalDeadline();
    if (!hasTransferredLeaseAwaitingMount ||
        _transferredLeaseAwaitingMount != _lease?.leaseId) {
      throw StateError('transferred_lease_not_available');
    }
    _transferredLeaseAwaitingMount = null;
    return _requiredLease();
  }

  Future<AccountHandoffResult> inspectHandoff(
    AccountDeviceHandoffGateway gateway, {
    String? handoffId,
  }) => _runOperation(() async {
    final generation = _authorityGeneration;
    final scope = _requiredScope();
    final presence = _requiredPresence();
    final result = await gateway.currentHandoff(
      environment: scope.environment,
      accountUuid: scope.accountUuid,
      presence: presence,
      handoffId: handoffId,
    );
    _ensureOperationCurrent(generation);
    final handoff = result.handoff;
    if (handoff != null) _fenceCommittedHandoffSource(handoff);
    return result;
  });

  Future<AccountDeviceHandoff> prepareHandoff(
    AccountDeviceHandoffGateway gateway, {
    required String targetPresenceSessionId,
    required HandoffAvatarIdentity avatarModel,
    required String requestId,
  }) => _runOperation(() async {
    requireCurrentRequestAuthority();
    final generation = _authorityGeneration;
    final scope = _requiredScope();
    final result = await gateway.handoffCommand(
      environment: scope.environment,
      accountUuid: scope.accountUuid,
      command: AccountHandoffCommand.prepare,
      body: {
        ..._handoffLeaseBody(requestId),
        'targetPresenceSessionId': handoffIdentifier(targetPresenceSessionId),
        'avatarModel': avatarModel.toJson(),
      },
    );
    _ensureOperationCurrent(generation);
    final handoff = result.requiredHandoff;
    final lease = _requiredLease();
    if (!handoff.isSource(_requiredPresence()) ||
        handoff.sourceLeaseId != lease.leaseId ||
        handoff.sourceEpoch != lease.epoch ||
        handoff.targetPresenceSessionId != targetPresenceSessionId ||
        !handoff.avatarModel.matches(avatarModel)) {
      throw const FormatException('prepared_handoff_authority_mismatch');
    }
    _fenceCommittedHandoffSource(handoff);
    return handoff;
  });

  Future<AccountDeviceHandoff> acknowledgeHandoffReady(
    AccountDeviceHandoffGateway gateway, {
    required AccountDeviceHandoff handoff,
    required String requestId,
  }) => _runOperation(() async {
    _ensureOpen();
    if (_state == AccountDeviceLeaseCoordinatorState.fenced ||
        _lease != null ||
        _pendingAcquire != null ||
        handoff.isCancelled ||
        !handoff.isTarget(_requiredPresence())) {
      throw StateError('handoff_target_not_standby');
    }
    final prior = _pendingHandoffAuthority;
    if (prior != null && prior.handoffId != handoff.handoffId) {
      throw StateError('handoff_target_already_preparing');
    }
    final pending = _pendingHandoffAuthority ??= _PendingHandoffAuthority(
      handoff.handoffId,
      _newHolderProof(),
    );
    final generation = _authorityGeneration;
    final scope = _requiredScope();
    final result = await gateway.handoffCommand(
      environment: scope.environment,
      accountUuid: scope.accountUuid,
      command: AccountHandoffCommand.targetReady,
      handoffId: handoff.handoffId,
      body: {..._handoffPresenceBody(requestId), 'holderProof': pending.proof},
    );
    _ensureOperationCurrent(generation);
    final ready = result.requiredHandoff;
    if (ready.handoffId != handoff.handoffId ||
        !ready.isTarget(_requiredPresence()) ||
        ready.sourceLeaseId != handoff.sourceLeaseId ||
        ready.sourceEpoch != handoff.sourceEpoch ||
        !ready.avatarModel.matches(handoff.avatarModel)) {
      throw const FormatException('ready_handoff_authority_mismatch');
    }
    if (ready.isCancelled) _pendingHandoffAuthority = null;
    return ready;
  });

  Future<AccountDeviceHandoff> acknowledgeHandoffExit(
    AccountDeviceHandoffGateway gateway, {
    required String handoffId,
    required String requestId,
  }) => _handoffLeaseCommand(
    gateway,
    handoffId,
    requestId,
    AccountHandoffCommand.sourceExited,
  );

  Future<AccountDeviceHandoff> completeHandoff(
    AccountDeviceHandoffGateway gateway, {
    required String handoffId,
    required String requestId,
  }) => _handoffLeaseCommand(
    gateway,
    handoffId,
    requestId,
    AccountHandoffCommand.completed,
  );

  Future<AccountDeviceHandoff> _handoffLeaseCommand(
    AccountDeviceHandoffGateway gateway,
    String handoffId,
    String requestId,
    AccountHandoffCommand command,
  ) => _runOperation(() async {
    requireCurrentRequestAuthority();
    final generation = _authorityGeneration;
    final priorLease = _requiredLease();
    final presence = _requiredPresence();
    final scope = _requiredScope();
    // A successful source-exited request retires this authority remotely.
    // Preserve its exact receipt/proof only for the existing teardown path.
    final result = await gateway.handoffCommand(
      environment: scope.environment,
      accountUuid: scope.accountUuid,
      command: command,
      handoffId: handoffId,
      body: _handoffLeaseBody(requestId),
    );
    _ensureOperationCurrent(generation);
    final handoff = result.requiredHandoff;
    if (handoff.handoffId != handoffId ||
        (command == AccountHandoffCommand.sourceExited
            ? (!handoff.isSource(presence) ||
                  handoff.sourceLeaseId != priorLease.leaseId ||
                  handoff.sourceEpoch != priorLease.epoch)
            : (!handoff.isTarget(presence) ||
                  priorLease.epoch != handoff.sourceEpoch + 1))) {
      throw const FormatException('handoff_lease_command_authority_mismatch');
    }
    if (command == AccountHandoffCommand.sourceExited && handoff.isCommitted) {
      fence();
    }
    return handoff;
  });

  Future<AccountDeviceLeaseReceipt> adoptTargetHandoff(
    AccountDeviceHandoffGateway gateway, {
    required String handoffId,
  }) => _runOperation(() async {
    _ensureOpen();
    final pending = _pendingHandoffAuthority;
    if (_state == AccountDeviceLeaseCoordinatorState.fenced ||
        _pendingAcquire != null ||
        pending == null ||
        pending.handoffId != handoffId ||
        _lease != null) {
      throw StateError('handoff_target_proof_unavailable');
    }
    final scope = _requiredScope();
    final generation = _authorityGeneration;
    final presence = _requiredPresence();
    final result = await gateway.currentHandoff(
      environment: scope.environment,
      accountUuid: scope.accountUuid,
      presence: presence,
      handoffId: handoffId,
    );
    _ensureOperationCurrent(generation);
    final handoff = result.requiredHandoff;
    final advertised = handoff.lease;
    if (handoff.handoffId != handoffId ||
        !handoff.isCommitted ||
        !handoff.isTarget(presence) ||
        advertised == null) {
      throw StateError('handoff_target_lease_not_committed');
    }
    // Handoff receipts can be replayed after a later lease takeover. Only the
    // canonical current lease may restore local mutation admission.
    final anchor = _leaseRequestAnchor(generation);
    final canonical = await _gateway.currentLease(
      environment: scope.environment,
      accountUuid: scope.accountUuid,
      agentId: presence.agentId,
    );
    _ensureOperationCurrent(generation);
    final lease = canonical.lease;
    if (canonical.state != AccountDeviceLeaseRemoteState.active ||
        lease == null ||
        lease.leaseId != advertised.leaseId ||
        lease.epoch != advertised.epoch) {
      throw StateError('handoff_target_lease_no_longer_current');
    }
    _validateLease(lease, scope, presence);
    _lease = lease;
    _holderProof = pending.proof;
    _pendingHandoffAuthority = null;
    if (!_setAdmissionDeadline(lease, anchor)) {
      throw StateError('handoff_target_lease_expired');
    }
    _transferredLeaseAwaitingMount = lease.leaseId;
    return lease;
  });

  Future<AccountDeviceHandoff> cancelHandoff(
    AccountDeviceHandoffGateway gateway, {
    required String handoffId,
    required String requestId,
  }) => _runOperation(() async {
    final scope = _requiredScope();
    final generation = _authorityGeneration;
    final result = await gateway.handoffCommand(
      environment: scope.environment,
      accountUuid: scope.accountUuid,
      command: AccountHandoffCommand.cancel,
      handoffId: handoffId,
      body: _handoffPresenceBody(requestId),
    );
    _ensureOperationCurrent(generation);
    final handoff = result.requiredHandoff;
    if (handoff.handoffId != handoffId ||
        (!handoff.isSource(_requiredPresence()) &&
            !handoff.isTarget(_requiredPresence()))) {
      throw const FormatException('cancel_handoff_authority_mismatch');
    }
    if (handoff.isCancelled &&
        _pendingHandoffAuthority?.handoffId == handoffId) {
      _pendingHandoffAuthority = null;
    }
    _fenceCommittedHandoffSource(handoff);
    return handoff;
  });

  void _fenceCommittedHandoffSource(AccountDeviceHandoff handoff) {
    final lease = _lease;
    if (handoff.isCommitted &&
        lease != null &&
        handoff.isSource(_requiredPresence()) &&
        handoff.sourceLeaseId == lease.leaseId &&
        handoff.sourceEpoch == lease.epoch) {
      fence();
    }
  }

  Map<String, Object?> _handoffLeaseBody(String requestId) {
    final lease = _requiredLease();
    return {
      'agentId': lease.agentId,
      'leaseId': lease.leaseId,
      'epoch': lease.epoch,
      'runtimeInstanceId': lease.runtimeInstanceId,
      'presenceSessionId': lease.presenceSessionId,
      'holderProof': _requiredHolderProof(),
      'requestId': handoffIdentifier(requestId),
    };
  }

  Map<String, Object?> _handoffPresenceBody(String requestId) {
    final presence = _requiredPresence();
    return {
      'agentId': presence.agentId,
      'installationId': presence.installationId,
      'runtimeInstanceId': presence.runtimeInstanceId,
      'presenceSessionId': presence.presenceSessionId,
      'generation': presence.generation,
      'requestId': handoffIdentifier(requestId),
    };
  }
}
