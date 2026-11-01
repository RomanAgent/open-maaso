import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/backchannel_classifier.dart';
import 'package:maaso/src/core/services/barge_in_self_echo_guard.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/speech/speech_playback_lease.dart';

/// Result of resolving a barge-in once the user's utterance is finalized.
enum BargeInOutcome {
  /// No current barge-in owned the output by the time it was resolved.
  none,

  /// Empty input, self echo, or a backchannel resumed the captured reply.
  resumed,

  /// Semantic user speech stopped the captured reply.
  interrupted,
}

/// Lifecycle of one acoustic interruption candidate.
enum BargeInPhase {
  idle,
  pausing,
  candidate,
  recognitionPending,
  recognizing,
  resolving,
}

/// Fixed-cardinality, privacy-safe milestones for acoustic barge-in.
///
/// No event carries transcript text, spoken text, persistent/domain
/// identifiers, exceptions, or caller-provided reasons. A controller-local
/// candidate ordinal only correlates milestones from one lifecycle. The
/// canonical candidate-captured and output-paused names are consumed by the
/// conversation acceptance report to derive the user-speech-to-audible-silence
/// latency before ASR begins.
enum BargeInDiagnosticKind {
  controllerDisabled,
  playbackUnavailable,
  candidateCaptured,
  outputPaused,
  recognitionPending,
  recognitionStarted,
  resumeEmpty,
  resumeSelfEcho,
  resumeBackchannel,
  resumeRecovery,
  semanticTakeover,
  outputResumed,
  outputRetired,
  deadlineExceeded,
  controlRejected,
  controlFailed,
  cancelled,
  closed;

  String get traceName => switch (this) {
    BargeInDiagnosticKind.candidateCaptured => 'interrupt.received',
    BargeInDiagnosticKind.outputPaused => 'output.stopped',
    BargeInDiagnosticKind.semanticTakeover => 'barge_in.semantic_takeover',
    BargeInDiagnosticKind.outputRetired => 'barge_in.output_retired',
    BargeInDiagnosticKind.controllerDisabled => 'barge_in.controller_disabled',
    BargeInDiagnosticKind.playbackUnavailable =>
      'barge_in.playback_unavailable',
    BargeInDiagnosticKind.recognitionPending => 'barge_in.recognition_pending',
    BargeInDiagnosticKind.recognitionStarted => 'barge_in.recognition_started',
    BargeInDiagnosticKind.resumeEmpty => 'barge_in.resume_empty',
    BargeInDiagnosticKind.resumeSelfEcho => 'barge_in.resume_self_echo',
    BargeInDiagnosticKind.resumeBackchannel => 'barge_in.resume_backchannel',
    BargeInDiagnosticKind.resumeRecovery => 'barge_in.resume_recovery',
    BargeInDiagnosticKind.outputResumed => 'barge_in.output_resumed',
    BargeInDiagnosticKind.deadlineExceeded => 'barge_in.deadline_exceeded',
    BargeInDiagnosticKind.controlRejected => 'barge_in.control_rejected',
    BargeInDiagnosticKind.controlFailed => 'barge_in.control_failed',
    BargeInDiagnosticKind.cancelled => 'barge_in.cancelled',
    BargeInDiagnosticKind.closed => 'barge_in.closed',
  };
}

/// One redacted diagnostic event for a single candidate lifecycle.
final class BargeInDiagnosticEvent {
  const BargeInDiagnosticEvent({
    required this.kind,
    required this.phase,
    required this.candidateSequence,
    required this.elapsedMilliseconds,
  });

  static const schemaVersion = 1;

  final BargeInDiagnosticKind kind;
  final BargeInPhase phase;
  final int candidateSequence;
  final int elapsedMilliseconds;

  Map<String, Object> toJson() => <String, Object>{
    'schemaVersion': schemaVersion,
    'event': kind.traceName,
    'phase': phase.name,
    'candidate': candidateSequence,
    'ms': elapsedMilliseconds,
  };
}

/// Best-effort observer; failures must never alter speech control.
typedef BargeInDiagnosticObserver = void Function(BargeInDiagnosticEvent event);

/// Captures the current host-identified speech output, when one exists.
typedef SpeechPlaybackLeaseCapture =
    SpeechPlaybackLease? Function({String? agentId});

/// Unforgeable identity for one acoustic interruption candidate.
///
/// The candidate owns exactly one [SpeechPlaybackLease]. A delayed ASR result
/// presented with an older candidate therefore cannot control newer output.
final class BargeInLease {
  BargeInLease._({
    required this.generation,
    required this.agentId,
    required SpeechPlaybackLease playback,
    required Stopwatch diagnosticStopwatch,
  }) : _playback = playback,
       _diagnosticStopwatch = diagnosticStopwatch;

  final int generation;
  final String? agentId;
  final SpeechPlaybackLease _playback;
  final Stopwatch _diagnosticStopwatch;
  bool _outputRetiredReported = false;

  int get playbackGeneration => _playback.generation;
  String get turnId => _playback.turnId;
  String get utteranceId => _playback.utteranceId;
}

/// Coordinates one acoustic interruption against one exact speech output.
///
/// The voice surface drives [beginCandidate], [markRecognitionPending],
/// [markRecognizing], then [resolveCandidate]. Each stage has its own deadline.
/// Every recovery and interruption operation uses the captured output lease;
/// no delayed candidate can pause, resume, or stop a later utterance.
class BargeInController extends AppService {
  BargeInController({
    bool Function()? enabled,
    SpeechPlaybackLeaseCapture? capturePlayback,
    BackchannelClassifier classifier = const BackchannelClassifier(),
    BargeInSelfEchoGuard selfEchoGuard = const BargeInSelfEchoGuard(),
    Duration pauseTimeout = const Duration(seconds: 2),
    Duration controlTimeout = const Duration(seconds: 2),
    Duration candidateTimeout = const Duration(seconds: 8),
    Duration recognitionPendingTimeout = const Duration(seconds: 3),
    Duration recognizingTimeout = const Duration(seconds: 15),
    BargeInDiagnosticObserver? diagnosticObserver,
  }) : _enabled = enabled ?? _defaultEnabled,
       _capturePlayback =
           capturePlayback ?? MaasoTtsPlugin.captureCurrentTypedPlayback,
       _classifier = classifier,
       _selfEchoGuard = selfEchoGuard,
       _pauseTimeout = pauseTimeout,
       _controlTimeout = controlTimeout,
       _candidateTimeout = candidateTimeout,
       _recognitionPendingTimeout = recognitionPendingTimeout,
       _recognizingTimeout = recognizingTimeout,
       _diagnosticObserver = diagnosticObserver ?? _traceDiagnostic {
    _requirePositive(pauseTimeout, 'pauseTimeout');
    _requirePositive(controlTimeout, 'controlTimeout');
    _requirePositive(candidateTimeout, 'candidateTimeout');
    _requirePositive(recognitionPendingTimeout, 'recognitionPendingTimeout');
    _requirePositive(recognizingTimeout, 'recognizingTimeout');
  }

  final bool Function() _enabled;
  final SpeechPlaybackLeaseCapture _capturePlayback;
  final BackchannelClassifier _classifier;
  final BargeInSelfEchoGuard _selfEchoGuard;
  final Duration _pauseTimeout;
  final Duration _controlTimeout;
  final Duration _candidateTimeout;
  final Duration _recognitionPendingTimeout;
  final Duration _recognizingTimeout;
  final BargeInDiagnosticObserver _diagnosticObserver;

  int _generation = 0;
  BargeInLease? _lease;
  BargeInPhase _phase = BargeInPhase.idle;
  Future<bool>? _pauseFuture;
  Completer<bool>? _pauseAbort;
  Timer? _phaseTimer;

  /// True while a candidate owns a paused output and awaits classification.
  final RxBool active = false.obs;

  bool get enabled => _enabled();
  BargeInPhase get phase => _phase;
  BargeInLease? get currentLease => _lease;

  static bool _defaultEnabled() =>
      appServices.isRegistered<AgentBehaviorConfig>() &&
      appServices.find<AgentBehaviorConfig>().voiceBargeInEnabled.value;

  static void _requirePositive(Duration value, String name) {
    if (value <= Duration.zero) throw ArgumentError.value(value, name);
  }

  /// Compatibility entry point for callers that do not retain a candidate.
  Future<void> begin({String? agentId}) async {
    await beginCandidate(agentId: agentId);
  }

  /// Captures and pauses the exact typed WAV or streaming PCM output playing.
  Future<BargeInLease?> beginCandidate({String? agentId}) async {
    if (!enabled) {
      _emit(BargeInDiagnosticKind.controllerDisabled);
      return null;
    }
    final existing = _lease;
    if (existing != null && _phase != BargeInPhase.idle) return existing;

    final playback = _capturePlayback(agentId: agentId);
    if (playback == null ||
        (agentId != null &&
            playback.agentId != null &&
            playback.agentId != agentId)) {
      _emit(BargeInDiagnosticKind.playbackUnavailable);
      return null;
    }
    final lease = BargeInLease._(
      generation: ++_generation,
      agentId: playback.agentId ?? agentId,
      playback: playback,
      diagnosticStopwatch: Stopwatch()..start(),
    );
    _lease = lease;
    _phase = BargeInPhase.pausing;
    active.value = true;
    _emit(BargeInDiagnosticKind.candidateCaptured, lease: lease);

    final pauseAbort = Completer<bool>();
    final pausing = Future.any<bool>([
      Future<bool>.sync(playback.pause),
      pauseAbort.future,
    ]).timeout(_pauseTimeout);
    _pauseAbort = pauseAbort;
    _pauseFuture = pausing;
    try {
      final paused = await pausing;
      if (!_isCurrent(lease) || _phase != BargeInPhase.pausing) return null;
      if (!paused) {
        _emit(BargeInDiagnosticKind.controlRejected, lease: lease);
        _clear(lease);
        return null;
      }
      _enterPhase(lease, BargeInPhase.candidate, _candidateTimeout);
      _emit(BargeInDiagnosticKind.outputPaused, lease: lease);
      return lease;
    } on TimeoutException {
      if (_isCurrent(lease) && _phase == BargeInPhase.pausing) {
        _emit(BargeInDiagnosticKind.deadlineExceeded, lease: lease);
        _clear(lease);
        // A platform pause may still complete after its Dart deadline. Retire
        // only the captured output so that late native work cannot leave it
        // paused or affect a replacement utterance. Do not await this cleanup:
        // the same unhealthy platform call must not block voice teardown.
        unawaited(_stopOnly(lease));
      }
      return null;
    } catch (_) {
      if (_isCurrent(lease) && _phase == BargeInPhase.pausing) {
        _emit(BargeInDiagnosticKind.controlFailed, lease: lease);
        _clear(lease);
        // Method-channel errors do not prove that the native pause had no
        // side effect. Keep ambiguous playback on a stop-only path.
        unawaited(_stopOnly(lease, 'barge_in_pause_failed'));
      }
      rethrow;
    } finally {
      if (identical(_pauseFuture, pausing)) _pauseFuture = null;
      if (identical(_pauseAbort, pauseAbort)) _pauseAbort = null;
    }
  }

  /// Marks the gap after speech ends and before an ASR operation starts.
  bool markRecognitionPending(BargeInLease lease) {
    if (!_isCurrent(lease) || _phase != BargeInPhase.candidate) return false;
    _enterPhase(
      lease,
      BargeInPhase.recognitionPending,
      _recognitionPendingTimeout,
    );
    _emit(BargeInDiagnosticKind.recognitionPending, lease: lease);
    return true;
  }

  /// Marks an in-flight ASR operation and starts its independent deadline.
  bool markRecognizing(BargeInLease lease) {
    if (!_isCurrent(lease) ||
        (_phase != BargeInPhase.candidate &&
            _phase != BargeInPhase.recognitionPending)) {
      return false;
    }
    _enterPhase(lease, BargeInPhase.recognizing, _recognizingTimeout);
    _emit(BargeInDiagnosticKind.recognitionStarted, lease: lease);
    return true;
  }

  /// Recovers from an ASR startup/finalization failure by resuming only the
  /// captured output. A stale lease returns [BargeInOutcome.none].
  Future<BargeInOutcome> recoverCandidate(BargeInLease lease) async {
    if (!_isCurrent(lease) || _phase == BargeInPhase.resolving) {
      return BargeInOutcome.none;
    }
    _phaseTimer?.cancel();
    _phaseTimer = null;
    _phase = BargeInPhase.resolving;
    if (!await _awaitPause(lease)) return BargeInOutcome.none;
    _emit(BargeInDiagnosticKind.resumeRecovery, lease: lease);
    try {
      final resumed = await _runControl(lease._playback.resume);
      _emit(
        resumed
            ? BargeInDiagnosticKind.outputResumed
            : BargeInDiagnosticKind.controlRejected,
        lease: lease,
      );
      return resumed ? BargeInOutcome.resumed : BargeInOutcome.none;
    } on TimeoutException {
      _emit(BargeInDiagnosticKind.deadlineExceeded, lease: lease);
      unawaited(_stopOnly(lease, 'barge_in_control_timeout'));
      return BargeInOutcome.none;
    } catch (_) {
      _emit(BargeInDiagnosticKind.controlFailed, lease: lease);
      await _bestEffortStop(lease);
      return BargeInOutcome.none;
    } finally {
      if (_isCurrent(lease)) _clear(lease);
    }
  }

  /// Compatibility entry point that resolves the current candidate.
  Future<BargeInOutcome> resolve(String utterance, {String? agentId}) async {
    final lease = _lease;
    if (lease == null) return BargeInOutcome.none;
    return resolveCandidate(lease, utterance, agentId: agentId);
  }

  /// Resolves only [lease]; stale candidates are inert.
  Future<BargeInOutcome> resolveCandidate(
    BargeInLease lease,
    String utterance, {
    String? agentId,
  }) async {
    if (!_isCurrent(lease) || _phase == BargeInPhase.resolving) {
      return BargeInOutcome.none;
    }
    _phaseTimer?.cancel();
    _phaseTimer = null;
    _phase = BargeInPhase.resolving;
    if (!await _awaitPause(lease)) return BargeInOutcome.none;

    final BargeInDiagnosticKind decision;
    if (utterance.trim().isEmpty) {
      decision = BargeInDiagnosticKind.resumeEmpty;
    } else if (_selfEchoGuard.isLikelySelfEcho(
      transcript: utterance,
      spokenText: lease._playback.spokenText,
    )) {
      decision = BargeInDiagnosticKind.resumeSelfEcho;
    } else if (_classifier.classify(utterance) ==
        BackchannelVerdict.backchannel) {
      decision = BargeInDiagnosticKind.resumeBackchannel;
    } else {
      decision = BargeInDiagnosticKind.semanticTakeover;
    }
    final shouldResume = decision != BargeInDiagnosticKind.semanticTakeover;
    _emit(decision, lease: lease);
    try {
      if (shouldResume) {
        final resumed = await _runControl(lease._playback.resume);
        _emit(
          resumed
              ? BargeInDiagnosticKind.outputResumed
              : BargeInDiagnosticKind.controlRejected,
          lease: lease,
        );
        return resumed ? BargeInOutcome.resumed : BargeInOutcome.none;
      }
      final stopped = await _stopWithDiagnostic(
        lease,
        'semantic_barge_in',
        phase: BargeInPhase.resolving,
      );
      if (!stopped) {
        _emit(BargeInDiagnosticKind.controlRejected, lease: lease);
      }
      return stopped ? BargeInOutcome.interrupted : BargeInOutcome.none;
    } on TimeoutException {
      _emit(BargeInDiagnosticKind.deadlineExceeded, lease: lease);
      unawaited(_stopOnly(lease, 'barge_in_control_timeout'));
      return BargeInOutcome.none;
    } catch (_) {
      _emit(BargeInDiagnosticKind.controlFailed, lease: lease);
      if (shouldResume) {
        await _bestEffortStop(lease);
      } else {
        await _bestEffortResume(lease);
      }
      rethrow;
    } finally {
      if (_isCurrent(lease)) _clear(lease);
    }
  }

  /// Stops the current candidate's output and clears the controller.
  Future<void> cancel({String? agentId}) async {
    final lease = _lease;
    if (lease == null) return;
    await cancelCandidate(lease, agentId: agentId);
  }

  /// Cancels only [lease]. A stale cleanup cannot stop a newer output.
  Future<void> cancelCandidate(BargeInLease lease, {String? agentId}) async {
    if (!_isCurrent(lease)) return;
    _emit(BargeInDiagnosticKind.cancelled, lease: lease);
    if (_phase == BargeInPhase.pausing) {
      final pauseAbort = _pauseAbort;
      _clear(lease);
      if (pauseAbort != null && !pauseAbort.isCompleted) {
        pauseAbort.complete(false);
      }
      await _stopOnly(lease, 'barge_in_cancelled');
      return;
    }
    _phaseTimer?.cancel();
    _phaseTimer = null;
    _phase = BargeInPhase.resolving;
    if (!await _awaitPause(lease)) return;
    try {
      final stopped = await _stopWithDiagnostic(
        lease,
        'barge_in_cancelled',
        phase: BargeInPhase.resolving,
      );
      if (!stopped) {
        _emit(BargeInDiagnosticKind.controlRejected, lease: lease);
      }
    } on TimeoutException {
      _emit(BargeInDiagnosticKind.deadlineExceeded, lease: lease);
      unawaited(_stopOnly(lease, 'barge_in_control_timeout'));
    } catch (error, stack) {
      _emit(BargeInDiagnosticKind.controlFailed, lease: lease);
      await _bestEffortResume(lease);
      Error.throwWithStackTrace(error, stack);
    } finally {
      if (_isCurrent(lease)) _clear(lease);
    }
  }

  void _enterPhase(BargeInLease lease, BargeInPhase phase, Duration timeout) {
    if (!_isCurrent(lease)) return;
    _phaseTimer?.cancel();
    _phase = phase;
    _phaseTimer = Timer(timeout, () => unawaited(_expire(lease, phase)));
  }

  Future<bool> _awaitPause(BargeInLease lease) async {
    final pausing = _pauseFuture;
    if (pausing != null) {
      try {
        if (!await pausing) {
          if (_isCurrent(lease)) _clear(lease);
          return false;
        }
      } catch (_) {
        if (_isCurrent(lease)) _clear(lease);
        return false;
      }
    }
    if (!_isCurrent(lease)) return false;
    return true;
  }

  Future<void> _expire(BargeInLease lease, BargeInPhase expectedPhase) async {
    if (!_isCurrent(lease) || _phase != expectedPhase) return;
    _emit(BargeInDiagnosticKind.deadlineExceeded, lease: lease);
    await recoverCandidate(lease);
  }

  Future<bool> _runControl(Future<bool> Function() operation) =>
      Future<bool>.sync(operation).timeout(_controlTimeout);

  Future<void> _stopOnly(
    BargeInLease lease, [
    String reason = 'barge_in_recovery',
  ]) async {
    try {
      await _stopWithDiagnostic(lease, reason);
    } catch (_) {}
  }

  Future<void> _bestEffortStop(BargeInLease lease) async {
    try {
      await _stopWithDiagnostic(lease, 'barge_in_recovery');
    } on TimeoutException {
      // The stop state is ambiguous. A resume could race behind a late stop or
      // pause, so keep this exact output on the monotonic stop path.
    } catch (_) {
      await _bestEffortResume(lease);
    }
  }

  Future<void> _bestEffortResume(BargeInLease lease) async {
    try {
      await _runControl(lease._playback.resume);
    } catch (_) {}
  }

  Future<bool> _stopWithDiagnostic(
    BargeInLease lease,
    String reason, {
    BargeInPhase? phase,
  }) {
    final operation = Future<bool>.sync(() => lease._playback.stop(reason));
    unawaited(
      operation.then<void>((stopped) {
        if (!stopped || lease._outputRetiredReported) return;
        lease._outputRetiredReported = true;
        _emit(BargeInDiagnosticKind.outputRetired, lease: lease, phase: phase);
      }, onError: (Object _, StackTrace _) {}),
    );
    return operation.timeout(_controlTimeout);
  }

  bool _isCurrent(BargeInLease lease) =>
      identical(_lease, lease) && lease.generation == _generation;

  void _emit(
    BargeInDiagnosticKind kind, {
    BargeInLease? lease,
    BargeInPhase? phase,
  }) {
    final rawElapsed = lease?._diagnosticStopwatch.elapsedMilliseconds ?? 0;
    final elapsed = rawElapsed > 60000 ? 60000 : rawElapsed;
    try {
      _diagnosticObserver(
        BargeInDiagnosticEvent(
          kind: kind,
          phase: phase ?? _phase,
          candidateSequence: lease?.generation ?? 0,
          elapsedMilliseconds: elapsed,
        ),
      );
    } catch (_) {
      // Diagnostics are non-authoritative and cannot alter speech control.
    }
  }

  static void _traceDiagnostic(BargeInDiagnosticEvent event) {
    TurnTrace.event(
      event.kind.traceName,
      details:
          'phase=${event.phase.name} candidate=${event.candidateSequence} '
          'elapsedMs=${event.elapsedMilliseconds}',
    );
  }

  void _clear(BargeInLease lease) {
    if (!_isCurrent(lease)) return;
    _phaseTimer?.cancel();
    _phaseTimer = null;
    _pauseFuture = null;
    _pauseAbort = null;
    _lease = null;
    _phase = BargeInPhase.idle;
    active.value = false;
  }

  @override
  void onClose() {
    final lease = _lease;
    final pauseAbort = _pauseAbort;
    if (lease != null) {
      _emit(BargeInDiagnosticKind.closed, lease: lease);
    }
    _generation++;
    _phaseTimer?.cancel();
    _phaseTimer = null;
    _pauseFuture = null;
    _pauseAbort = null;
    _lease = null;
    _phase = BargeInPhase.idle;
    active.value = false;
    if (pauseAbort != null && !pauseAbort.isCompleted) {
      pauseAbort.complete(false);
    }
    if (lease != null) unawaited(_stopOnly(lease));
    super.onClose();
  }
}
