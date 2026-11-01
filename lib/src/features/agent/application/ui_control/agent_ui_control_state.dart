import 'dart:async';

/// UI-only ownership phases. This lifecycle is intentionally independent from
/// the conversational turn, TTS, and avatar lifecycles.
enum AgentUiControlPhase {
  idle,
  awaitingConsent,
  navigating,
  operating,
  pausedByUser,
  completed,
  failed,
}

enum AgentUiControlResultStatus {
  ok,
  pausedByUser,
  staleSession,
  pageNotReady,
  busy,
  invalidState,
  executionFailed,
}

/// Shared result contract for the coordinator and route-scoped page adapters.
class AgentUiControlResult<T> {
  const AgentUiControlResult.success([this.value])
    : status = AgentUiControlResultStatus.ok,
      message = null,
      error = null,
      stackTrace = null;

  const AgentUiControlResult.failure(
    this.status, {
    this.message,
    this.error,
    this.stackTrace,
  }) : assert(status != AgentUiControlResultStatus.ok),
       value = null;

  final AgentUiControlResultStatus status;
  final T? value;
  final String? message;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => status == AgentUiControlResultStatus.ok;

  String? get reason => switch (status) {
    AgentUiControlResultStatus.ok => null,
    AgentUiControlResultStatus.pausedByUser => 'paused_by_user',
    AgentUiControlResultStatus.staleSession => 'stale_session',
    AgentUiControlResultStatus.pageNotReady => 'page_not_ready',
    AgentUiControlResultStatus.busy => 'ui_control_busy',
    AgentUiControlResultStatus.invalidState => 'invalid_state',
    AgentUiControlResultStatus.executionFailed => 'execution_failed',
  };

  AgentUiControlResult<R> asFailure<R>() {
    if (isSuccess) {
      throw StateError('A successful UI-control result is not a failure.');
    }
    return AgentUiControlResult<R>.failure(
      status,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

class AgentUiControlLease {
  const AgentUiControlLease({
    required this.sessionId,
    required this.generation,
  });

  final String sessionId;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is AgentUiControlLease &&
      other.sessionId == sessionId &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(sessionId, generation);

  @override
  String toString() => 'AgentUiControlLease($sessionId, $generation)';
}

class AgentUiControlSnapshot {
  const AgentUiControlSnapshot({
    required this.phase,
    this.lease,
    this.purpose,
    this.targetRoute,
    this.stepId,
    this.pauseReason,
    this.failureMessage,
  });

  const AgentUiControlSnapshot.idle()
    : phase = AgentUiControlPhase.idle,
      lease = null,
      purpose = null,
      targetRoute = null,
      stepId = null,
      pauseReason = null,
      failureMessage = null;

  final AgentUiControlPhase phase;
  final AgentUiControlLease? lease;
  final String? purpose;
  final String? targetRoute;
  final String? stepId;
  final String? pauseReason;
  final String? failureMessage;

  String? get sessionId => lease?.sessionId;
  int? get generation => lease?.generation;
}

/// Pure state machine for one exclusive UI-control lease.
class AgentUiControlStateMachine {
  AgentUiControlSnapshot _snapshot = const AgentUiControlSnapshot.idle();
  final StreamController<AgentUiControlSnapshot> _changes =
      StreamController<AgentUiControlSnapshot>.broadcast(sync: true);
  int _generation = 0;
  AgentUiControlPhase? _pausedFrom;
  bool _disposed = false;

  AgentUiControlSnapshot get snapshot => _snapshot;
  Stream<AgentUiControlSnapshot> get changes => _changes.stream;

  bool get hasActiveLease => switch (_snapshot.phase) {
    AgentUiControlPhase.awaitingConsent ||
    AgentUiControlPhase.navigating ||
    AgentUiControlPhase.operating ||
    AgentUiControlPhase.pausedByUser => true,
    _ => false,
  };

  AgentUiControlResult<AgentUiControlLease> begin({
    required String sessionId,
    required String purpose,
    String? targetRoute,
    bool requiresConsent = false,
  }) {
    if (_disposed) {
      return const AgentUiControlResult<AgentUiControlLease>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'The UI-control state machine is disposed.',
      );
    }
    if (hasActiveLease) {
      return const AgentUiControlResult<AgentUiControlLease>.failure(
        AgentUiControlResultStatus.busy,
        message: 'Another UI-control lease is active.',
      );
    }
    final normalizedSessionId = sessionId.trim();
    final normalizedPurpose = purpose.trim();
    if (normalizedSessionId.isEmpty || normalizedPurpose.isEmpty) {
      return const AgentUiControlResult<AgentUiControlLease>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'sessionId and purpose must not be empty.',
      );
    }

    final lease = AgentUiControlLease(
      sessionId: normalizedSessionId,
      generation: ++_generation,
    );
    _pausedFrom = null;
    _emit(
      AgentUiControlSnapshot(
        phase: requiresConsent
            ? AgentUiControlPhase.awaitingConsent
            : AgentUiControlPhase.navigating,
        lease: lease,
        purpose: normalizedPurpose,
        targetRoute: _normalizedOptional(targetRoute),
      ),
    );
    return AgentUiControlResult<AgentUiControlLease>.success(lease);
  }

  AgentUiControlResult<void> grantConsent(AgentUiControlLease lease) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    if (_snapshot.phase != AgentUiControlPhase.awaitingConsent) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'Consent is not pending.',
      );
    }
    _emit(_next(phase: AgentUiControlPhase.navigating));
    return const AgentUiControlResult<void>.success();
  }

  /// Enters a modal confirmation boundary after navigation is ready.
  ///
  /// Pointer gestures are not considered takeover while this phase is active;
  /// the modal Host must translate the gesture into [grantConsent] or fail the
  /// lease. This transition is intentionally unavailable during an operating
  /// step so a handler cannot pause mid-side-effect to request more authority.
  AgentUiControlResult<void> enterAwaitingConsent(AgentUiControlLease lease) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    if (_snapshot.phase != AgentUiControlPhase.navigating) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'Consent can only be requested before page operation.',
      );
    }
    _emit(_next(phase: AgentUiControlPhase.awaitingConsent));
    return const AgentUiControlResult<void>.success();
  }

  AgentUiControlResult<void> enterNavigating(AgentUiControlLease lease) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    if (_snapshot.phase != AgentUiControlPhase.navigating) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'The lease is not ready to navigate.',
      );
    }
    return const AgentUiControlResult<void>.success();
  }

  AgentUiControlResult<void> enterOperating(
    AgentUiControlLease lease, {
    required String stepId,
  }) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    if (_snapshot.phase != AgentUiControlPhase.navigating &&
        _snapshot.phase != AgentUiControlPhase.operating) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'The lease is not ready to operate the UI.',
      );
    }
    final normalizedStepId = stepId.trim();
    if (normalizedStepId.isEmpty) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'stepId must not be empty.',
      );
    }
    _emit(
      _next(phase: AgentUiControlPhase.operating, stepId: normalizedStepId),
    );
    return const AgentUiControlResult<void>.success();
  }

  AgentUiControlResult<void> finishStep(
    AgentUiControlLease lease, {
    required String stepId,
  }) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    if (_snapshot.phase != AgentUiControlPhase.operating ||
        _snapshot.stepId != stepId.trim()) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'The UI-control step is no longer current.',
      );
    }
    _emit(_next(phase: AgentUiControlPhase.operating));
    return const AgentUiControlResult<void>.success();
  }

  /// Records a real user takeover without touching conversation or TTS state.
  bool pauseForUserActivity({required String reason}) {
    if (_snapshot.phase == AgentUiControlPhase.pausedByUser) return true;
    final normalizedReason = reason.trim().isEmpty
        ? 'user_activity'
        : reason.trim();
    if (_snapshot.phase == AgentUiControlPhase.awaitingConsent) {
      // The trusted root modal owns keyboard focus and the entire pointer hit
      // test while consent is visible. Those events are approval interaction,
      // including the Allow/Reject taps that bubble through AppAgentShell in
      // the production MaterialApp.router.builder hierarchy. System back,
      // route changes, lifecycle events, and rollout changes still cancel.
      if (normalizedReason == 'keyboard_input' ||
          normalizedReason == 'pointer_down') {
        return false;
      }
      _pausedFrom = null;
      _emit(
        _next(
          phase: AgentUiControlPhase.failed,
          pauseReason: normalizedReason,
          failureMessage: 'Consent was interrupted by user activity.',
        ),
      );
      return true;
    }
    if (_snapshot.phase != AgentUiControlPhase.navigating &&
        _snapshot.phase != AgentUiControlPhase.operating) {
      return false;
    }
    _pausedFrom = _snapshot.phase;
    _emit(
      _next(
        phase: AgentUiControlPhase.pausedByUser,
        pauseReason: normalizedReason,
      ),
    );
    return true;
  }

  /// Resuming is always explicit and always produces a fresh generation.
  AgentUiControlResult<AgentUiControlLease> resume(
    AgentUiControlLease pausedLease,
  ) {
    if (_snapshot.lease != pausedLease) {
      return const AgentUiControlResult<AgentUiControlLease>.failure(
        AgentUiControlResultStatus.staleSession,
        message: 'The UI-control lease is stale.',
      );
    }
    if (_snapshot.phase != AgentUiControlPhase.pausedByUser) {
      return const AgentUiControlResult<AgentUiControlLease>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'Only a user-paused lease can be resumed.',
      );
    }

    final lease = AgentUiControlLease(
      sessionId: pausedLease.sessionId,
      generation: ++_generation,
    );
    final resumePhase = _pausedFrom == AgentUiControlPhase.navigating
        ? AgentUiControlPhase.navigating
        : AgentUiControlPhase.operating;
    _pausedFrom = null;
    _emit(
      AgentUiControlSnapshot(
        phase: resumePhase,
        lease: lease,
        purpose: _snapshot.purpose,
        targetRoute: _snapshot.targetRoute,
      ),
    );
    return AgentUiControlResult<AgentUiControlLease>.success(lease);
  }

  AgentUiControlResult<void> complete(AgentUiControlLease lease) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    if (_snapshot.phase != AgentUiControlPhase.navigating &&
        _snapshot.phase != AgentUiControlPhase.operating) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'The UI-control lease cannot complete from this state.',
      );
    }
    _emit(_next(phase: AgentUiControlPhase.completed));
    return const AgentUiControlResult<void>.success();
  }

  AgentUiControlResult<void> fail(
    AgentUiControlLease lease, {
    required String message,
  }) {
    final validation = checkLease(lease);
    if (!validation.isSuccess) return validation;
    _emit(
      _next(
        phase: AgentUiControlPhase.failed,
        failureMessage: message.trim().isEmpty
            ? 'UI-control operation failed.'
            : message.trim(),
      ),
    );
    return const AgentUiControlResult<void>.success();
  }

  void settle() {
    if (_snapshot.phase != AgentUiControlPhase.completed &&
        _snapshot.phase != AgentUiControlPhase.failed) {
      return;
    }
    _pausedFrom = null;
    _emit(const AgentUiControlSnapshot.idle());
  }

  AgentUiControlResult<void> checkLease(AgentUiControlLease lease) {
    if (_snapshot.lease != lease ||
        _snapshot.phase == AgentUiControlPhase.idle ||
        _snapshot.phase == AgentUiControlPhase.completed ||
        _snapshot.phase == AgentUiControlPhase.failed) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.staleSession,
        message: 'The UI-control lease is stale.',
      );
    }
    if (_snapshot.phase == AgentUiControlPhase.pausedByUser) {
      return const AgentUiControlResult<void>.failure(
        AgentUiControlResultStatus.pausedByUser,
        message: 'The user paused UI control.',
      );
    }
    return const AgentUiControlResult<void>.success();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.close();
  }

  AgentUiControlSnapshot _next({
    required AgentUiControlPhase phase,
    String? stepId,
    String? pauseReason,
    String? failureMessage,
  }) {
    return AgentUiControlSnapshot(
      phase: phase,
      lease: _snapshot.lease,
      purpose: _snapshot.purpose,
      targetRoute: _snapshot.targetRoute,
      stepId: stepId,
      pauseReason: pauseReason,
      failureMessage: failureMessage,
    );
  }

  void _emit(AgentUiControlSnapshot next) {
    _snapshot = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  static String? _normalizedOptional(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
