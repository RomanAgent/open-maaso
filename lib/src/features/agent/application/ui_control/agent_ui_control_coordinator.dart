import 'dart:async';

import 'agent_ui_control_state.dart';

typedef AgentUiControlCommand<T> =
    Future<T> Function(AgentUiControlStepContext context);

/// Serializes all UI commands while keeping UI ownership independent from the
/// conversation, TTS, and avatar runtimes.
class AgentUiControlCoordinator {
  AgentUiControlCoordinator({
    AgentUiControlStateMachine? stateMachine,
    bool Function()? isControlEnabled,
    Stream<bool>? controlEnabledChanges,
  }) : _stateMachine = stateMachine ?? AgentUiControlStateMachine(),
       _isControlEnabled = isControlEnabled ?? _alwaysEnabled {
    _controlEnabledSubscription = controlEnabledChanges?.distinct().listen(
      _handleControlEnabledChange,
    );
  }

  final AgentUiControlStateMachine _stateMachine;
  final bool Function() _isControlEnabled;
  StreamSubscription<bool>? _controlEnabledSubscription;
  Future<void> _commandTail = Future<void>.value();
  bool _disposed = false;

  AgentUiControlSnapshot get snapshot => _stateMachine.snapshot;
  Stream<AgentUiControlSnapshot> get changes => _stateMachine.changes;

  AgentUiControlResult<AgentUiControlLease> begin({
    required String sessionId,
    required String purpose,
    String? targetRoute,
    bool requiresConsent = false,
  }) {
    if (!_controlAllowed) {
      return _rolloutDisabled<AgentUiControlLease>();
    }
    return _stateMachine.begin(
      sessionId: sessionId,
      purpose: purpose,
      targetRoute: targetRoute,
      requiresConsent: requiresConsent,
    );
  }

  AgentUiControlResult<void> grantConsent(AgentUiControlLease lease) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    return _stateMachine.grantConsent(lease);
  }

  AgentUiControlResult<void> enterAwaitingConsent(AgentUiControlLease lease) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    return _stateMachine.enterAwaitingConsent(lease);
  }

  AgentUiControlResult<void> enterNavigating(AgentUiControlLease lease) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    return _stateMachine.enterNavigating(lease);
  }

  bool pauseForUserActivity({String reason = 'user_activity'}) =>
      _stateMachine.pauseForUserActivity(reason: reason);

  AgentUiControlResult<AgentUiControlLease> resume(
    AgentUiControlLease pausedLease,
  ) {
    if (!_controlAllowed) {
      return _rolloutDisabled<AgentUiControlLease>();
    }
    return _stateMachine.resume(pausedLease);
  }

  AgentUiControlResult<void> complete(AgentUiControlLease lease) =>
      _stateMachine.complete(lease);

  AgentUiControlResult<void> fail(
    AgentUiControlLease lease, {
    required String message,
  }) => _stateMachine.fail(lease, message: message);

  void settle() => _stateMachine.settle();

  AgentUiControlResult<void> checkLease(AgentUiControlLease lease) {
    if (!_controlAllowed) {
      final paused = _stateMachine.pauseForUserActivity(
        reason: 'rollout_disabled',
      );
      if (paused) return _stateMachine.checkLease(lease);
      return _rolloutDisabled<void>();
    }
    return _stateMachine.checkLease(lease);
  }

  Future<AgentUiControlResult<T>> runStep<T>({
    required AgentUiControlLease lease,
    required String stepId,
    required AgentUiControlCommand<T> command,
  }) {
    final completer = Completer<AgentUiControlResult<T>>();
    final next = _commandTail.then((_) async {
      final result = await _executeStep(
        lease: lease,
        stepId: stepId,
        command: command,
      );
      if (!completer.isCompleted) completer.complete(result);
    });
    _commandTail = next.catchError((Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.complete(
          AgentUiControlResult<T>.failure(
            AgentUiControlResultStatus.executionFailed,
            message: 'The serialized UI-control queue failed.',
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    });
    return completer.future;
  }

  Future<void> get idle async {
    while (true) {
      final active = _commandTail;
      await active;
      if (identical(active, _commandTail)) return;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final controlEnabledSubscription = _controlEnabledSubscription;
    _controlEnabledSubscription = null;
    await controlEnabledSubscription?.cancel();
    await idle;
    await _stateMachine.dispose();
  }

  bool get _controlAllowed {
    if (_disposed) return false;
    try {
      return _isControlEnabled();
    } catch (_) {
      return false;
    }
  }

  void _handleControlEnabledChange(bool enabled) {
    if (_disposed || enabled) return;
    final snapshot = _stateMachine.snapshot;
    final lease = snapshot.lease;
    if (snapshot.phase == AgentUiControlPhase.awaitingConsent &&
        lease != null) {
      _stateMachine.fail(lease, message: 'rollout_disabled');
      return;
    }
    _stateMachine.pauseForUserActivity(reason: 'rollout_disabled');
  }

  static bool _alwaysEnabled() => true;

  static AgentUiControlResult<T> _rolloutDisabled<T>() =>
      AgentUiControlResult<T>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'Agent UI control is disabled by rollout.',
      );

  Future<AgentUiControlResult<T>> _executeStep<T>({
    required AgentUiControlLease lease,
    required String stepId,
    required AgentUiControlCommand<T> command,
  }) async {
    if (_disposed) {
      return AgentUiControlResult<T>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'The UI-control coordinator is disposed.',
      );
    }

    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation.asFailure<T>();
    final entered = _stateMachine.enterOperating(lease, stepId: stepId);
    if (!entered.isSuccess) return entered.asFailure<T>();

    final context = AgentUiControlStepContext._(this, lease);
    try {
      context.checkpoint();
      final value = await command(context);
      context.checkpoint();
      final finished = _stateMachine.finishStep(lease, stepId: stepId);
      if (!finished.isSuccess) return finished.asFailure<T>();
      return AgentUiControlResult<T>.success(value);
    } on _AgentUiControlStepAborted catch (abort) {
      return abort.result.asFailure<T>();
    } catch (error, stackTrace) {
      final afterFailure = checkLease(lease);
      if (!afterFailure.isSuccess) return afterFailure.asFailure<T>();
      _stateMachine.fail(lease, message: error.toString());
      return AgentUiControlResult<T>.failure(
        AgentUiControlResultStatus.executionFailed,
        message: 'The UI-control command failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// A command should wrap every internal asynchronous boundary with
/// [guardedAwait]. The coordinator also checks once before and after the whole
/// command, so an old generation can never report a successful step.
class AgentUiControlStepContext {
  AgentUiControlStepContext._(this._coordinator, this.lease);

  final AgentUiControlCoordinator _coordinator;
  final AgentUiControlLease lease;

  void checkpoint() {
    final result = _coordinator.checkLease(lease);
    if (!result.isSuccess) throw _AgentUiControlStepAborted(result);
  }

  Future<T> guardedAwait<T>(Future<T> operation) async {
    checkpoint();
    final value = await operation;
    checkpoint();
    return value;
  }
}

class _AgentUiControlStepAborted implements Exception {
  const _AgentUiControlStepAborted(this.result);

  final AgentUiControlResult<void> result;
}
