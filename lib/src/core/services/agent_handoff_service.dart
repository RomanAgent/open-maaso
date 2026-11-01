import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';

typedef HandoffAuthoritySerialization =
    Future<T> Function<T>(Future<T> Function() work);

final class HandoffAccountContext {
  const HandoffAccountContext({
    required this.environment,
    required this.accountUuid,
    this.presenceSessionId = '',
  });
  final MaasoEnvironment environment;
  final String accountUuid;
  final String presenceSessionId;
  bool matches(HandoffAccountContext other) =>
      environment == other.environment &&
      accountUuid == other.accountUuid &&
      presenceSessionId == other.presenceSessionId;
}

enum AgentHandoffPhase {
  idle,
  preparing,
  waitingForTarget,
  targetPreparing,
  sourceExiting,
  awaitingCommit,
  targetEntering,
  away,
  completed,
  failed,
}

/// A presentation-only snapshot. It cannot authorize a lease or an avatar.
final class AgentHandoffConversationStatus {
  const AgentHandoffConversationStatus({
    required this.context,
    required this.transactionId,
    required this.phase,
    required this.isTarget,
    this.cancelled = false,
  });

  final HandoffAccountContext context;
  final String transactionId;
  final AgentHandoffPhase phase;
  final bool isTarget;
  final bool cancelled;
}

/// Presentation and account lifecycle are injected so two real protocol peers
/// can be tested without native windows, a phone or a running Unity Editor.
abstract interface class AgentHandoffRuntimeBridge {
  bool get isAvailable;
  Future<HandoffAvatarIdentity> currentAvatar();
  Future<void> prepareTarget(AccountDeviceHandoff handoff);
  Future<void> quiesceSource(AccountDeviceHandoff handoff);
  Future<void> exitSource(AccountDeviceHandoff handoff);
  Future<void> retireSource(AccountDeviceHandoff handoff);
  Future<void> mountTarget(AccountDeviceHandoff handoff);
  Future<void> enterTarget(AccountDeviceHandoff handoff);
  Future<void> restoreSource(AccountDeviceHandoff handoff);
  Future<void> cancelTarget(AccountDeviceHandoff handoff);
}

/// One account-bound handoff worker. Ownership is always the canonical server
/// receipt; timers only discover changes and never authorize a reveal.
final class AgentHandoffService extends ChangeNotifier {
  AgentHandoffService({
    required this.authority,
    required this.gateway,
    required this.bridge,
    required this.accountContext,
    required this.serializeAuthority,
    String Function()? newRequestId,
    this.idlePollInterval = const Duration(seconds: 2),
    this.activePollInterval = const Duration(milliseconds: 250),
    DateTime Function()? now,
  }) : _newRequestId = newRequestId ?? _opaqueId,
       _now = now ?? DateTime.now;

  final AccountDeviceLeaseCoordinator authority;
  final AccountDeviceHandoffGateway gateway;
  final AgentHandoffRuntimeBridge bridge;
  final HandoffAccountContext? Function() accountContext;
  final HandoffAuthoritySerialization serializeAuthority;
  final Duration idlePollInterval;
  final Duration activePollInterval;
  final String Function() _newRequestId;
  final DateTime Function() _now;
  Timer? _timer;
  bool _disposed = false;
  bool _started = false;
  bool _working = false;
  bool _requesting = false;
  bool _retiring = false;
  bool _prepareUncertain = false;
  String? _prepareTarget;
  HandoffAvatarIdentity? _prepareAvatar;
  String? _prepareAuthorityKey;
  bool Function()? _prepareRequestIsCurrent;
  bool _cancelRequested = false;
  bool _targetPrepared = false;
  bool _targetPrepareAttempted = false;
  bool _targetReadyAcknowledged = false;
  bool _sourceQuiesced = false;
  bool _sourceDrainCompleted = false;
  bool _sourceExited = false;
  bool _targetMounted = false;
  bool _targetEntered = false;
  bool _sourceRetired = false;
  int _generation = 0;
  HandoffAccountContext? _context;
  AccountDeviceHandoff? _handoff;
  String? _sourceConversationId;
  AgentHandoffConversationStatus? _settledConversation;
  AgentHandoffPhase _phase = AgentHandoffPhase.idle;
  Object? _error;
  DateTime? _presenceHeartbeatAt;
  final Map<String, String> _requestIds = {};
  final Set<String> _finished = {};

  AgentHandoffPhase get phase => _phase;
  AccountDeviceHandoff? get handoff => _handoff;
  Object? get error => _error;

  /// Only an actual, current account handoff belongs in conversation history.
  /// Routine discovery/network errors while idle must not become chat messages.
  AgentHandoffConversationStatus? get conversationStatus {
    final context = _context;
    if (context == null || !_isCurrent(_generation)) return null;
    final handoff = _handoff;
    if (handoff == null && _settledConversation != null) {
      return _settledConversation;
    }
    if (handoff == null &&
        !(_phase == AgentHandoffPhase.failed &&
            (_requesting || _prepareTarget != null))) {
      return null;
    }
    final isTarget =
        handoff != null &&
        authority.currentPresence != null &&
        handoff.isTarget(authority.currentPresence!);
    final completed =
        handoff != null &&
        handoff.isCommitted &&
        _finished.contains(handoff.handoffId);
    return AgentHandoffConversationStatus(
      context: context,
      // Before POST has returned, a failed local attempt still needs one
      // visible result. A presence session and local generation isolate it
      // from subsequent attempts without changing protocol request IDs.
      transactionId: _sourceConversationId ?? handoff!.handoffId,
      // Later discovery errors cannot rewrite an already completed crossing
      // as a failed move. They still retain their normal protocol retry path.
      phase: completed
          ? (isTarget ? AgentHandoffPhase.completed : AgentHandoffPhase.away)
          : (_error != null ? AgentHandoffPhase.failed : _phase),
      isTarget: isTarget,
    );
  }

  bool get isBusy =>
      !_disposed &&
      (_requesting ||
          _prepareUncertain ||
          _retiring ||
          // A cancelled server transaction can still be restoring the local
          // account and actor. Failed retries keep startup/input gated as well.
          (_sourceQuiesced && !_sourceRetired) ||
          (_handoff != null &&
              !_handoff!.isTerminal &&
              _phase != AgentHandoffPhase.away &&
              _phase != AgentHandoffPhase.completed) ||
          switch (_phase) {
            AgentHandoffPhase.preparing ||
            AgentHandoffPhase.waitingForTarget ||
            AgentHandoffPhase.targetPreparing ||
            AgentHandoffPhase.sourceExiting ||
            AgentHandoffPhase.awaitingCommit ||
            AgentHandoffPhase.targetEntering => true,
            _ => false,
          });
  bool get canRequest =>
      !_disposed &&
      !isBusy &&
      bridge.isAvailable &&
      accountContext() != null &&
      authority.canAdmitMutations;
  bool get canCancel =>
      _handoff != null && !_handoff!.isCommitted && !_handoff!.isCancelled;

  void start() {
    if (_disposed || _started) return;
    _started = true;
    _schedule(Duration.zero);
  }

  Future<String> request(
    String targetPresenceSessionId, {
    String? prepareRequestId,
    bool Function()? requestIsCurrent,
  }) async {
    if (!canRequest || _working) {
      throw StateError('handoff_unavailable_or_busy');
    }
    if (prepareRequestId != null) handoffIdentifier(prepareRequestId);
    if (requestIsCurrent?.call() == false) {
      throw StateError('handoff_request_cancelled');
    }
    _resetTransaction();
    _prepareRequestIsCurrent = requestIsCurrent;
    if (prepareRequestId != null) _requestIds['prepare'] = prepareRequestId;
    _context = accountContext();
    final generation = ++_generation;
    _sourceConversationId =
        'source:${authority.currentPresence?.presenceSessionId ?? _context!.presenceSessionId}:$generation';
    _requesting = true;
    _setPhase(AgentHandoffPhase.preparing);
    try {
      final avatar = await bridge.currentAvatar();
      _requireCurrent(generation);
      if (requestIsCurrent?.call() == false) {
        throw StateError('handoff_request_cancelled');
      }
      _prepareTarget = targetPresenceSessionId;
      _prepareAvatar = avatar;
      _prepareUncertain = true;
      final handoff = await serializeAuthority(() {
        _requireCurrent(generation);
        // A remote command can be waiting behind account teardown on this
        // queue. Do not dispatch it after its relay has closed.
        if (requestIsCurrent?.call() == false) {
          _prepareUncertain = false;
          throw StateError('handoff_request_cancelled');
        }
        _prepareAuthorityKey = _authorityKey;
        return authority.prepareHandoff(
          gateway,
          targetPresenceSessionId: targetPresenceSessionId,
          avatarModel: avatar,
          requestId: _id('prepare'),
        );
      });
      _requireCurrent(generation);
      _handoff = handoff;
      _prepareUncertain = false;
      _setPhase(AgentHandoffPhase.waitingForTarget);
      return handoff.handoffId;
    } catch (error) {
      // A transport error may hide a committed prepare. Poll current and
      // reconcile; never manufacture a second transaction on automatic retry.
      if (_isCurrent(generation)) {
        if (_isDefinitelyRejectedPrepare(error)) _prepareUncertain = false;
        _error = error;
        _setPhase(AgentHandoffPhase.failed);
      }
      rethrow;
    } finally {
      final wasBusy = isBusy;
      _requesting = false;
      // Failure was published while the request guard was still held. Publish
      // its release as well, or listeners retain a stale busy/input gate.
      if (!_disposed && wasBusy != isBusy) notifyListeners();
      if (_started) _schedule(Duration.zero);
    }
  }

  Future<void> cancel() async {
    if (!canCancel) return;
    _cancelRequested = true;
    await synchronize();
  }

  /// Public deterministic tick for lifecycle wakeups and integration tests.
  Future<void> synchronize() async {
    if (_disposed || _retiring) return;
    final observed = accountContext();
    // Account/presence changes fence even an in-flight request. Waiting until
    // its Future returns would let an A -> B -> A switch reuse stale work.
    if (_context != null &&
        (observed == null || !_context!.matches(observed))) {
      _retiring = true;
      try {
        await _retireContext();
      } catch (_) {
        // The old context is already fenced in _retireContext's finally.
        // Native cleanup failure cannot resurrect it or fail a new account tick.
      } finally {
        final wasBusy = isBusy;
        _retiring = false;
        // _retireContext publishes idle before this guard is released. A new
        // account may have no presence yet, so no later poll phase will notify.
        if (!_disposed && wasBusy != isBusy) notifyListeners();
      }
    }
    if (_disposed || _working || _requesting) return;
    _working = true;
    final generation = _generation;
    try {
      final next = accountContext();
      if (next == null || !bridge.isAvailable) {
        await _retireContext();
        return;
      }
      if (_context != null && !_context!.matches(next)) await _retireContext();
      _context = next;
      final presence = authority.currentPresence;
      if (presence == null) return;
      if (authority.currentReceipt == null &&
          !authority.hasPendingAcquire &&
          (_presenceHeartbeatAt == null ||
              _now().difference(_presenceHeartbeatAt!) >=
                  const Duration(seconds: 20))) {
        await serializeAuthority(authority.heartbeatObservationPresence);
        _requireCurrent(generation);
        _presenceHeartbeatAt = _now();
      }
      final result = await serializeAuthority(
        () => authority.inspectHandoff(
          gateway,
          handoffId: _finished.contains(_handoff?.handoffId)
              ? null
              : _handoff?.handoffId,
        ),
      );
      _requireCurrent(generation);
      var current = result.handoff;
      if (_prepareUncertain && current == null && authority.canAdmitMutations) {
        // A null GET can race a still-running POST. Resolve using the exact
        // original idempotency key/body, never a newly-created transaction.
        try {
          current = await serializeAuthority(() {
            _requireCurrent(generation);
            if (_prepareRequestIsCurrent?.call() == false) {
              _prepareUncertain = false;
              throw StateError('handoff_request_cancelled');
            }
            if (_prepareAuthorityKey == null ||
                _prepareAuthorityKey != _authorityKey) {
              throw StateError('handoff_prepare_authority_changed');
            }
            return authority.prepareHandoff(
              gateway,
              targetPresenceSessionId: _prepareTarget!,
              avatarModel: _prepareAvatar!,
              requestId: _id('prepare'),
            );
          });
        } catch (error) {
          if (_isCurrent(generation) && _isDefinitelyRejectedPrepare(error)) {
            _prepareUncertain = false;
          }
          rethrow;
        }
        _requireCurrent(generation);
      }
      if (current == null || _finished.contains(current.handoffId)) return;
      _prepareUncertain = false;
      _error = null;
      if (_handoff != null && _handoff!.handoffId != current.handoffId) {
        if (!_finished.contains(_handoff!.handoffId)) {
          throw StateError('handoff_changed_before_reconciliation');
        }
        _resetTransaction();
      }
      _handoff = current;
      if (_cancelRequested && !current.isCommitted && !current.isCancelled) {
        final currentId = current.handoffId;
        final resolved = await serializeAuthority(
          () => authority.cancelHandoff(
            gateway,
            handoffId: currentId,
            requestId: _id('cancel'),
          ),
        );
        _requireCurrent(generation);
        _handoff = resolved;
      }
      final handoff = _handoff!;
      if (handoff.isCancelled) {
        await _settleCancellation(handoff, generation);
      } else if (handoff.isSource(presence)) {
        await _advanceSource(handoff, generation);
      } else if (handoff.isTarget(presence)) {
        await _advanceTarget(handoff, generation);
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _error = error;
      // Once the source is off-screen an uncertain response must keep it
      // hidden. The next canonical GET decides whether to retire or restore.
      _setPhase(
        _sourceExited
            ? AgentHandoffPhase.awaitingCommit
            : AgentHandoffPhase.failed,
      );
    } finally {
      _working = false;
      if (_started && !_disposed) {
        _schedule(isBusy ? activePollInterval : idlePollInterval);
      }
    }
  }

  Future<void> _advanceSource(
    AccountDeviceHandoff handoff,
    int generation,
  ) async {
    if (handoff.isCommitted) {
      if (!_sourceRetired) {
        await bridge.retireSource(handoff);
        _requireCurrent(generation);
        _sourceRetired = true;
      }
      _finished.add(handoff.handoffId);
      _setPhase(AgentHandoffPhase.away);
      return;
    }
    if (handoff.state != AccountHandoffState.targetReady) {
      _setPhase(AgentHandoffPhase.waitingForTarget);
      return;
    }
    try {
      if (!_sourceDrainCompleted) {
        _sourceQuiesced = true;
        await bridge.quiesceSource(handoff);
        _requireCurrent(generation);
        _sourceDrainCompleted = true;
      }
      if (!_sourceExited) {
        _setPhase(AgentHandoffPhase.sourceExiting);
        await bridge.exitSource(handoff);
        _requireCurrent(generation);
        _sourceExited = true;
      }
    } catch (_) {
      if (_isCurrent(generation)) _cancelRequested = true;
      rethrow;
    }
    _setPhase(AgentHandoffPhase.awaitingCommit);
    if (_cancelRequested) return;
    final result = await serializeAuthority(
      () => authority.acknowledgeHandoffExit(
        gateway,
        handoffId: handoff.handoffId,
        requestId: _id('source-exited'),
      ),
    );
    _requireCurrent(generation);
    _handoff = result;
    if (result.isCommitted) await _advanceSource(result, generation);
  }

  Future<void> _advanceTarget(
    AccountDeviceHandoff handoff,
    int generation,
  ) async {
    if (!handoff.isCommitted) {
      _setPhase(AgentHandoffPhase.targetPreparing);
      if (!_targetPrepared) {
        try {
          _targetPrepareAttempted = true;
          await bridge.prepareTarget(handoff);
          _requireCurrent(generation);
          _targetPrepared = true;
        } catch (_) {
          if (!_isCurrent(generation)) rethrow;
          _cancelRequested = true;
          await bridge.cancelTarget(handoff);
          _requireCurrent(generation);
          _targetPrepareAttempted = false;
          rethrow;
        }
      }
      // A successful readiness acknowledgement keeps its pending authority
      // proof in the coordinator. Poll only for source exit after that: a
      // repeated POST adds another network round trip before the next GET.
      // Lost acknowledgements leave this false and retry the same request ID.
      if (_cancelRequested || _targetReadyAcknowledged) return;
      final ready = await serializeAuthority(
        () => authority.acknowledgeHandoffReady(
          gateway,
          handoff: handoff,
          requestId: _id('target-ready'),
        ),
      );
      _requireCurrent(generation);
      _handoff = ready;
      _targetReadyAcknowledged =
          ready.state == AccountHandoffState.targetReady || ready.isCommitted;
      // Source exit can commit while the ready reply is in flight. Use that
      // canonical result immediately; adoption still verifies the live lease.
      if (ready.isCommitted) await _advanceTarget(ready, generation);
      return;
    }
    try {
      _setPhase(AgentHandoffPhase.targetEntering);
      if (!_targetMounted) {
        final alreadyAdopted = _holdsCommittedLease(handoff);
        if (!alreadyAdopted && !authority.hasTransferredLeaseAwaitingMount) {
          await serializeAuthority(
            () => authority.adoptTargetHandoff(
              gateway,
              handoffId: handoff.handoffId,
            ),
          );
        }
        _requireCurrent(generation);
        await bridge.mountTarget(handoff);
        _requireCurrent(generation);
        _targetMounted = true;
      }
      if (!_holdsCommittedLease(handoff)) {
        throw StateError('handoff_target_authority_changed');
      }
      if (!_targetEntered) {
        await bridge.enterTarget(handoff);
        _requireCurrent(generation);
        _targetEntered = true;
      }
    } catch (error) {
      if (!_isCurrent(generation)) rethrow;
      TurnTrace.event(
        'handoff.target.presentation.failed',
        details:
            'handoff=${handoff.handoffId} generation=$generation '
            'entered=$_targetEntered holdsLease=${_holdsCommittedLease(handoff)} '
            'errorType=${error.runtimeType}',
      );
      _targetEntered = false;
      await bridge.cancelTarget(handoff);
      _requireCurrent(generation);
      rethrow;
    }
    try {
      // The completed acknowledgement is bookkeeping after a proven visible
      // entrance. A lost response must not replay that entrance while we still
      // hold this exact live lease.
      final completed = handoff.state == AccountHandoffState.completed
          ? handoff
          : await serializeAuthority(
              () => authority.completeHandoff(
                gateway,
                handoffId: handoff.handoffId,
                requestId: _id('completed'),
              ),
            );
      _requireCurrent(generation);
      if (!_holdsCommittedLease(completed)) {
        throw StateError('handoff_target_authority_changed');
      }
      _handoff = completed;
      _finished.add(handoff.handoffId);
      _setPhase(AgentHandoffPhase.completed);
    } catch (_) {
      if (!_isCurrent(generation)) rethrow;
      if (!_holdsCommittedLease(handoff)) {
        _targetEntered = false;
        await bridge.cancelTarget(handoff);
        _requireCurrent(generation);
      }
      rethrow;
    }
  }

  bool _holdsCommittedLease(AccountDeviceHandoff handoff) {
    final held = authority.currentReceipt;
    final committed = handoff.lease;
    return authority.canAdmitMutations &&
        held != null &&
        committed != null &&
        held.leaseId == committed.leaseId &&
        held.epoch == committed.epoch &&
        held.presenceSessionId == committed.presenceSessionId &&
        held.runtimeInstanceId == committed.runtimeInstanceId;
  }

  Future<void> _settleCancellation(
    AccountDeviceHandoff handoff,
    int generation,
  ) async {
    // Retire a target's in-memory pending proof even when expiry was learned
    // from GET instead of from our own cancellation request.
    await serializeAuthority(
      () => authority.cancelHandoff(
        gateway,
        handoffId: handoff.handoffId,
        requestId: _id('cancel'),
      ),
    );
    _requireCurrent(generation);
    if (_sourceQuiesced) {
      await bridge.restoreSource(handoff);
      _requireCurrent(generation);
    }
    if (_targetPrepared || _targetPrepareAttempted) {
      await bridge.cancelTarget(handoff);
    }
    _requireCurrent(generation);
    _finished.add(handoff.handoffId);
    final conversationId = _sourceConversationId ?? handoff.handoffId;
    _resetTransaction();
    // Publish cancellation only after the server result and local restore have
    // both settled. Expiry is an unfinished move, not a successful arrival.
    _settledConversation = AgentHandoffConversationStatus(
      context: _context!,
      transactionId: conversationId,
      phase: handoff.state == AccountHandoffState.expired
          ? AgentHandoffPhase.failed
          : AgentHandoffPhase.idle,
      isTarget:
          authority.currentPresence != null &&
          handoff.isTarget(authority.currentPresence!),
      cancelled: handoff.state == AccountHandoffState.cancelled,
    );
    _setPhase(AgentHandoffPhase.idle);
  }

  Future<void> _retireContext() async {
    ++_generation;
    final previous = _handoff;
    try {
      if (previous != null && (_targetPrepared || _targetPrepareAttempted)) {
        await bridge.cancelTarget(previous);
      }
    } finally {
      _resetTransaction();
      _context = null;
      _finished.clear();
      _presenceHeartbeatAt = null;
      _setPhase(AgentHandoffPhase.idle);
    }
  }

  void _resetTransaction() {
    _handoff = null;
    _sourceConversationId = null;
    _settledConversation = null;
    _prepareUncertain = false;
    _prepareTarget = null;
    _prepareAvatar = null;
    _prepareAuthorityKey = null;
    _prepareRequestIsCurrent = null;
    _cancelRequested = false;
    _targetPrepared = false;
    _targetPrepareAttempted = false;
    _targetReadyAcknowledged = false;
    _sourceQuiesced = false;
    _sourceDrainCompleted = false;
    _sourceExited = false;
    _targetMounted = false;
    _targetEntered = false;
    _sourceRetired = false;
    _requestIds.clear();
    _error = null;
  }

  String _id(String phase) => _requestIds.putIfAbsent(phase, _newRequestId);

  bool _isDefinitelyRejectedPrepare(Object error) {
    if (error is! AccountDeviceLeaseRequestException) return false;
    return (error.statusCode == 400 && error.code == 'VALIDATION_ERROR') ||
        (error.statusCode == 409 &&
            const {
              'STALE_RUNTIME_LEASE',
              'STALE_RUNTIME_PRESENCE',
              'REALTIME_SESSION_PENDING',
              'REALTIME_SESSION_BUSY',
            }.contains(error.code));
  }

  String? get _authorityKey {
    final receipt = authority.currentReceipt;
    return receipt == null
        ? null
        : '${receipt.leaseId}:${receipt.epoch}:${receipt.runtimeInstanceId}:${receipt.presenceSessionId}';
  }

  void _requireCurrent(int generation) {
    if (!_isCurrent(generation)) {
      throw StateError('handoff_account_generation_changed');
    }
  }

  bool _isCurrent(int generation) {
    final context = _context;
    return !_disposed &&
        generation == _generation &&
        context != null &&
        accountContext()?.matches(context) == true;
  }

  void _setPhase(AgentHandoffPhase phase) {
    if (_disposed) return;
    if (_phase != phase) {
      TurnTrace.event(
        'handoff.phase',
        details:
            'handoff=${_handoff?.handoffId ?? "none"} '
            'generation=$_generation from=${_phase.name} to=${phase.name} '
            'targetMounted=$_targetMounted targetEntered=$_targetEntered',
      );
    }
    _phase = phase;
    notifyListeners();
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(synchronize()));
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    super.dispose();
  }

  static String _opaqueId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
