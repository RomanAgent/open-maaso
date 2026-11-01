import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime_diagnostic.dart';

/// Fixed, source-free failures that a workerCanvas host may report.
enum SurfaceWorkerFatalReason {
  invalidDrawCommands('invalid_draw_commands'),
  invalidState('invalid_state'),
  invalidGameDefinition('invalid_game_definition'),
  canvasUnavailable('canvas_unavailable'),
  workerStartFailed('worker_start_failed'),
  watchdogTimeout('watchdog_timeout'),
  webViewLoadFailed('webview_load_failed'),
  securityBoundaryFailed('security_boundary_failed'),
  runtimeFailed('runtime_failed');

  const SurfaceWorkerFatalReason(this.wireName);

  final String wireName;

  static SurfaceWorkerFatalReason? fromWireName(String value) {
    for (final reason in values) {
      if (reason.wireName == value) return reason;
    }
    return null;
  }
}

enum SurfaceWorkerFirstFrameFailureKind {
  fatal,
  timeout,
  unavailable,
  superseded,
  gateClosed,
}

class SurfaceWorkerFirstFrameException implements Exception {
  const SurfaceWorkerFirstFrameException.fatal(this.reason, {this.diagnostic})
    : kind = SurfaceWorkerFirstFrameFailureKind.fatal;

  const SurfaceWorkerFirstFrameException.timeout()
    : kind = SurfaceWorkerFirstFrameFailureKind.timeout,
      reason = null,
      diagnostic = null;

  const SurfaceWorkerFirstFrameException.unavailable()
    : kind = SurfaceWorkerFirstFrameFailureKind.unavailable,
      reason = null,
      diagnostic = null;

  const SurfaceWorkerFirstFrameException.superseded()
    : kind = SurfaceWorkerFirstFrameFailureKind.superseded,
      reason = null,
      diagnostic = null;

  const SurfaceWorkerFirstFrameException.gateClosed()
    : kind = SurfaceWorkerFirstFrameFailureKind.gateClosed,
      reason = null,
      diagnostic = null;

  final SurfaceWorkerFirstFrameFailureKind kind;
  final SurfaceWorkerFatalReason? reason;
  final SurfaceRuntimeDiagnostic? diagnostic;

  @override
  String toString() {
    final reasonName = reason?.wireName;
    return 'surface_worker_first_frame_${kind.name}'
        '${reasonName == null ? '' : ':$reasonName'}';
  }
}

class SurfaceWorkerRepairFailure {
  const SurfaceWorkerRepairFailure(this.reason, {this.diagnostic});
  final SurfaceWorkerFatalReason reason;
  final SurfaceRuntimeDiagnostic? diagnostic;
  String get wireName => reason.wireName;
}

class SurfaceWorkerLifecycleMessage {
  const SurfaceWorkerLifecycleMessage._({
    required this.session,
    required this.isReady,
    required this.reason,
    this.diagnostic,
  });

  static const Set<String> _keys = <String>{
    'version',
    'session',
    'status',
    'reason',
  };

  final int session;
  final bool isReady;
  final SurfaceWorkerFatalReason? reason;
  final SurfaceRuntimeDiagnostic? diagnostic;

  static SurfaceWorkerLifecycleMessage? tryParse(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic> ||
        (decoded.length != _keys.length &&
            decoded.length != _keys.length + 1) ||
        !decoded.keys.every(
          (key) => _keys.contains(key) || key == 'diagnostic',
        ) ||
        decoded['version'] != 1 ||
        decoded['session'] is! int ||
        (decoded['session'] as int) <= 0 ||
        decoded['status'] is! String ||
        decoded['reason'] is! String) {
      return null;
    }
    final session = decoded['session'] as int;
    final status = decoded['status'] as String;
    final reasonName = decoded['reason'] as String;
    final diagnostic = decoded.containsKey('diagnostic')
        ? SurfaceRuntimeDiagnostic.tryParse(decoded['diagnostic'])
        : null;
    if (decoded.containsKey('diagnostic') &&
        (status != 'fatal' ||
            reasonName != 'runtime_failed' ||
            diagnostic == null)) {
      return null;
    }
    if (status == 'ready') {
      if (reasonName != 'first_frame_ready') return null;
      return SurfaceWorkerLifecycleMessage._(
        session: session,
        isReady: true,
        reason: null,
      );
    }
    if (status != 'fatal') return null;
    final reason = SurfaceWorkerFatalReason.fromWireName(reasonName);
    if (reason == null) return null;
    return SurfaceWorkerLifecycleMessage._(
      session: session,
      isReady: false,
      reason: reason,
      diagnostic: diagnostic,
    );
  }
}

class SurfaceWorkerValidationRequest {
  const SurfaceWorkerValidationRequest({
    required this.session,
    required this.document,
    this.runtime,
  });

  final int session;
  final String document;
  final SurfaceRuntime? runtime;
}

/// Test-injectable boundary used between presenting workerCanvas and making
/// its durable presentation visible to the rest of the app.
abstract interface class SurfaceWorkerFirstFrameWaiter {
  void beginPresentation({SurfaceRuntime? runtime});

  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  });

  void cancelPresentation();
}

/// A deliberate test-only bypass. Production wiring registers
/// [SurfaceWorkerHealthGate] and never uses this implementation.
class SurfaceWorkerTestFirstFrameWaiter
    implements SurfaceWorkerFirstFrameWaiter {
  const SurfaceWorkerTestFirstFrameWaiter();

  @override
  void beginPresentation({SurfaceRuntime? runtime}) {}

  @override
  void cancelPresentation() {}

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) async {}
}

/// Owns the single validation-host claim for a workerCanvas presentation.
///
/// The claim is armed before [SurfaceRuntime.show] publishes its document, so
/// visible SurfaceWebViews can suppress that document. The app-root validation
/// WebView reports a typed terminal result, clears its page, then releases the
/// claim. Only a successful release allows a visible host to load that session.
class SurfaceWorkerHealthGate extends AppService
    implements SurfaceWorkerFirstFrameWaiter {
  final Rxn<SurfaceWorkerValidationRequest> activeRequest =
      Rxn<SurfaceWorkerValidationRequest>();
  final RxInt visibleLeaseRevision = 0.obs;

  bool _claimed = false;
  int? _session;
  int? _rejectedSession;
  Completer<void>? _completion;
  Timer? _timeoutTimer;
  bool _terminalReady = false;
  SurfaceWorkerFirstFrameException? _terminalFailure;
  SurfaceRuntime? _validationRuntime;
  Completer<void>? _claimReleased;
  Object? _visibleHostOwner;
  int? _visibleHostSession;

  bool get hasValidationClaim => _claimed;

  /// Waits for the single validation host and claims it atomically.
  ///
  /// Saved-game previews can be mounted together in a grid. They must queue
  /// here instead of treating another presentation's in-flight claim as a
  /// permanent validation failure.
  Future<bool> beginPresentationWhenAvailable({
    SurfaceRuntime? runtime,
    bool Function()? canBegin,
  }) async {
    while (true) {
      if (isClosed) {
        throw const SurfaceWorkerFirstFrameException.gateClosed();
      }
      if (canBegin?.call() == false) return false;
      if (!_claimed) {
        beginPresentation(runtime: runtime);
        return true;
      }
      final released = _claimReleased;
      if (released == null) continue;
      await released.future;
    }
  }

  bool shouldSuppressVisibleSession(int session) {
    return _claimed || _rejectedSession == session;
  }

  bool claimVisibleHost(Object owner, int session) {
    if (shouldSuppressVisibleSession(session)) return false;
    if (_visibleHostOwner == null || _visibleHostSession != session) {
      _visibleHostOwner = owner;
      _visibleHostSession = session;
      return true;
    }
    return identical(_visibleHostOwner, owner);
  }

  void releaseVisibleHost(Object owner) {
    if (!identical(_visibleHostOwner, owner)) return;
    _visibleHostOwner = null;
    _visibleHostSession = null;
    visibleLeaseRevision.value++;
  }

  @override
  void beginPresentation({SurfaceRuntime? runtime}) {
    if (isClosed) throw const SurfaceWorkerFirstFrameException.gateClosed();
    if (_claimed) throw const SurfaceWorkerFirstFrameException.superseded();
    TurnTrace.event('surface.first_frame.begin');
    _visibleHostOwner = null;
    _visibleHostSession = null;
    visibleLeaseRevision.value++;
    _claimed = true;
    _session = null;
    _completion = null;
    _terminalReady = false;
    _terminalFailure = null;
    _validationRuntime = runtime;
    _claimReleased = Completer<void>();
  }

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) {
    if (isClosed) {
      return Future<void>.error(
        const SurfaceWorkerFirstFrameException.gateClosed(),
      );
    }
    if (!_claimed || _completion != null || session <= 0 || document.isEmpty) {
      return Future<void>.error(
        const SurfaceWorkerFirstFrameException.unavailable(),
      );
    }
    final completion = Completer<void>();
    _completion = completion;
    _session = session;
    activeRequest.value = SurfaceWorkerValidationRequest(
      session: session,
      document: document,
      runtime: _validationRuntime,
    );
    TurnTrace.event(
      'surface.first_frame.request',
      details: 'session=$session timeout_ms=${timeout.inMilliseconds}',
    );
    _timeoutTimer = Timer(timeout, () {
      if (_session != session || completion.isCompleted) return;
      TurnTrace.event(
        'surface.first_frame.timeout',
        details: 'session=$session',
      );
      _rejectWithoutHost(
        session,
        const SurfaceWorkerFirstFrameException.timeout(),
      );
    });
    return completion.future;
  }

  bool acceptLifecycleMessage(String source, {required int currentSession}) {
    final message = SurfaceWorkerLifecycleMessage.tryParse(source);
    if (message == null ||
        message.session != currentSession ||
        message.session != _session ||
        activeRequest.value?.session != message.session ||
        _terminalReady ||
        _terminalFailure != null) {
      TurnTrace.event(
        'surface.first_frame.lifecycle_rejected',
        details:
            'parsed=${message != null} reported=${message?.session ?? -1} '
            'current=$currentSession expected=${_session ?? -1}',
      );
      return false;
    }
    if (message.isReady) {
      _terminalReady = true;
    } else {
      final diagnostic = message.diagnostic;
      final project = _validationRuntime?.activeProject.value;
      if (diagnostic != null &&
          (project == null ||
              project.rendering != SurfaceRendering.webApp ||
              !diagnostic.matchesProjectSource(
                html: project.html,
                js: project.js,
              ))) {
        return false;
      }
      _terminalFailure = SurfaceWorkerFirstFrameException.fatal(
        message.reason!,
        diagnostic: diagnostic,
      );
    }
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    TurnTrace.event(
      'surface.first_frame.lifecycle_accepted',
      details:
          'session=${message.session} '
          'status=${message.isReady ? "ready" : "fatal"} '
          'reason=${message.reason?.wireName ?? "first_frame_ready"}',
    );
    return true;
  }

  bool reportHostFatal(
    SurfaceWorkerFatalReason reason, {
    required int session,
    required int currentSession,
  }) {
    if (session != currentSession ||
        session != _session ||
        activeRequest.value?.session != session ||
        _terminalReady ||
        _terminalFailure != null) {
      return false;
    }
    _terminalFailure = SurfaceWorkerFirstFrameException.fatal(reason);
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    return true;
  }

  bool releaseValidationHost(int session) {
    final completion = _completion;
    if (session != _session ||
        completion == null ||
        completion.isCompleted ||
        (!_terminalReady && _terminalFailure == null)) {
      return false;
    }
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final failure = _terminalFailure;
    if (_terminalReady) {
      _rejectedSession = null;
    } else {
      _rejectedSession = session;
    }
    _clearClaim();
    if (failure == null) {
      completion.complete();
    } else {
      completion.completeError(failure);
    }
    TurnTrace.event(
      'surface.first_frame.released',
      details: 'session=$session status=${failure == null ? "ready" : "fatal"}',
    );
    return true;
  }

  @override
  void cancelPresentation() {
    final session = _session;
    final completion = _completion;
    if (!_claimed) return;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    if (session != null) _rejectedSession = session;
    _clearClaim();
    visibleLeaseRevision.value++;
    if (completion != null && !completion.isCompleted) {
      completion.completeError(
        const SurfaceWorkerFirstFrameException.superseded(),
      );
    }
  }

  void _rejectWithoutHost(
    int session,
    SurfaceWorkerFirstFrameException failure,
  ) {
    final completion = _completion;
    if (completion == null || completion.isCompleted) return;
    _rejectedSession = session;
    _clearClaim();
    completion.completeError(failure);
  }

  void _clearClaim() {
    final claimReleased = _claimReleased;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _claimed = false;
    _session = null;
    _completion = null;
    _terminalReady = false;
    _terminalFailure = null;
    _validationRuntime = null;
    _claimReleased = null;
    activeRequest.value = null;
    if (claimReleased != null && !claimReleased.isCompleted) {
      claimReleased.complete();
    }
  }

  @override
  void onClose() {
    final completion = _completion;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _clearClaim();
    visibleLeaseRevision.value++;
    if (completion != null && !completion.isCompleted) {
      completion.completeError(
        const SurfaceWorkerFirstFrameException.gateClosed(),
      );
    }
    super.onClose();
  }
}
