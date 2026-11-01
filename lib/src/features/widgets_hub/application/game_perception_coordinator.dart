import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:maaso/src/features/widgets_hub/application/game_frame_processor.dart';
import 'package:maaso/src/features/widgets_hub/data/game_perception_gateway.dart';

enum GamePerceptionStatus {
  observing,
  unsupported,
  disabled,
  membershipRequired,
  premiumRequired,
  busy,
  unavailable,
  stopped,
}

final class GameVisualObservation {
  const GameVisualObservation({
    required this.capturedAt,
    required this.analyzedAt,
    required this.frameSequence,
    required this.description,
    required this.modelId,
    required this.roundGeneration,
    required this.sourceMediaId,
    required this.isCurrentFrame,
  });
  final DateTime capturedAt;
  final DateTime analyzedAt;
  final int frameSequence;
  final String description;
  final String modelId;
  final int roundGeneration;
  final String sourceMediaId;
  final bool isCurrentFrame;
}

/// Local sampling and cloud dispatch have separate clocks. The coordinator owns
/// one capture, one physical HTTP operation and one replaceable pending frame.
/// It never speaks, persists pixels or requires authored game telemetry.
class GamePerceptionCoordinator {
  GamePerceptionCoordinator({
    required Future<Uint8List?> Function() capture,
    required GamePerceptionGateway gateway,
    required bool Function() isCurrent,
    required void Function(GameVisualObservation) onObservation,
    required String Function() question,
    required String Function() locale,
    bool Function()? shouldYield,
    bool Function()? isCaptureSupported,
    void Function(GamePerceptionStatus)? onStatus,
    void Function()? onFrameChanged,
    Listenable? priorityChanges,
    DateTime Function()? now,
    Future<ProcessedGameFrame> Function(Uint8List)? processor,
    this.samplingInterval = const Duration(seconds: 2),
    this.staticSamplingInterval = const Duration(seconds: 5),
    this.minimumDispatchInterval = const Duration(seconds: 3),
    this.maximumObservationAge = const Duration(seconds: 8),
    this.requestDeadline = const Duration(seconds: 8),
  }) : _capture = capture,
       _gateway = gateway,
       _isCurrent = isCurrent,
       _onObservation = onObservation,
       _question = question,
       _locale = locale,
       _shouldYield = shouldYield ?? (() => false),
       _isCaptureSupported = isCaptureSupported ?? (() => true),
       _onStatus = onStatus,
       _onFrameChanged = onFrameChanged,
       _priorityChanges = priorityChanges,
       _now = now ?? DateTime.now,
       _processor = processor ?? processGameFrame {
    if (samplingInterval <= Duration.zero ||
        staticSamplingInterval <= Duration.zero ||
        minimumDispatchInterval < Duration.zero ||
        maximumObservationAge <= Duration.zero ||
        requestDeadline <= Duration.zero) {
      throw ArgumentError('game_perception_schedule');
    }
    _priorityChanges?.addListener(notifyPriorityChanged);
  }

  final Future<Uint8List?> Function() _capture;
  final GamePerceptionGateway _gateway;
  final bool Function() _isCurrent;
  final void Function(GameVisualObservation) _onObservation;
  final String Function() _question;
  final String Function() _locale;
  final bool Function() _shouldYield;
  final bool Function() _isCaptureSupported;
  final void Function(GamePerceptionStatus)? _onStatus;
  final void Function()? _onFrameChanged;
  final Listenable? _priorityChanges;
  final DateTime Function() _now;
  final Future<ProcessedGameFrame> Function(Uint8List) _processor;
  final Duration samplingInterval, staticSamplingInterval;
  final Duration minimumDispatchInterval,
      maximumObservationAge,
      requestDeadline;

  bool _started = false, _closed = false, _terminal = false;
  bool _forceAfterSample = false, _retryAdmission = false;
  bool _wasYielding = false, _activeForced = false;
  Completer<void>? _activeCancelled;
  int _round = 0, _sequence = 0, _failures = 0;
  Completer<void> _revoked = Completer<void>();
  Future<void>? _sampling, _active, _closing;
  Timer? _sampleTimer, _dispatchTimer;
  DateTime? _lastDispatchAt, _blockedUntil;
  final List<_GameQuestionWaiter> _waiters = [];
  _GameFrameCandidate? _pending, _lastCaptured;
  ProcessedGameFrame? _lastAttemptedSignature, _latestSignature;
  GameVisualObservation? _latest;
  GamePerceptionStatus _status = GamePerceptionStatus.stopped;

  bool get _live => _started && !_closed && _isCurrent();
  GamePerceptionStatus get status => _status;
  GameVisualObservation? get latest {
    final value = _latest;
    if (!_live ||
        value == null ||
        value.roundGeneration != _round ||
        _now().difference(value.capturedAt) > maximumObservationAge ||
        _now().isBefore(value.capturedAt)) {
      return null;
    }
    final current = _lastCaptured;
    if (current != null && gameFramesDiffer(_latestSignature, current.frame)) {
      return null;
    }
    return value;
  }

  void start() {
    if (_started || _closed) return;
    _started = true;
    _setStatus(GamePerceptionStatus.observing);
    _scheduleSample(Duration.zero);
  }

  void _setStatus(GamePerceptionStatus value) {
    if (_status == value) return;
    _status = value;
    _onStatus?.call(value);
  }

  bool _syncPriority() {
    final yielding = _shouldYield();
    if (yielding && !_wasYielding) _cancelBackgroundForUser();
    _wasYielding = yielding;
    return yielding;
  }

  void _cancelBackgroundForUser() {
    final cancelled = _activeCancelled;
    if (!_activeForced && cancelled != null && !cancelled.isCompleted) {
      cancelled.complete();
    }
  }

  void notifyPriorityChanged() {
    if (_closed) return;
    if (!_syncPriority()) _dispatchPending();
  }

  void _scheduleSample(Duration delay, {bool force = false}) {
    _sampleTimer?.cancel();
    if (!_live || _terminal) return;
    _sampleTimer = Timer(delay, () => unawaited(_sample(force: force)));
  }

  Future<void> _sample({bool force = false}) {
    if (!_live || _terminal) return Future<void>.value();
    _syncPriority();
    final active = _sampling;
    if (active != null) {
      _forceAfterSample |= force;
      return active;
    }
    _sampleTimer?.cancel();
    var nextDelay = samplingInterval;
    final round = _round;
    late final Future<void> operation;
    operation = Future<void>(() {})
        .then((_) async {
          if (!_live || round != _round) return;
          if (!_isCaptureSupported()) {
            _halt(GamePerceptionStatus.unsupported);
            return;
          }
          // Native returns bytes after snapshot/encoding. Timestamp the request
          // conservatively so that encoding latency cannot rejuvenate a frame.
          final capturedAt = _now();
          final bytes = await _capture();
          if (!_live || round != _round) return;
          if (bytes == null) {
            throw const FormatException('game_capture_unavailable');
          }
          final frame = await _processor(bytes);
          if (!_live || round != _round) return;
          _failures = 0;
          final hadPrevious = _lastCaptured != null;
          final changed = gameFramesDiffer(_lastCaptured?.frame, frame);
          nextDelay = changed ? samplingInterval : staticSamplingInterval;
          final pendingForce = force || (_pending?.force ?? false);
          final candidate = _GameFrameCandidate(
            frame,
            capturedAt,
            ++_sequence,
            round,
            pendingForce,
          );
          _lastCaptured = candidate;
          if (hadPrevious && changed) _onFrameChanged?.call();
          if (!_live || round != _round) return;
          // A question always checks the local screen first. An unchanged,
          // still-fresh observation can then be reused without another upload;
          // preserve its original capture/analysis times and do not republish it
          // as a new event.
          final cached = latest;
          if (pendingForce &&
              cached != null &&
              _waiters.any((waiter) => waiter.accepts(candidate))) {
            for (final waiter in _waiters.toList(growable: false)) {
              if (waiter.accepts(candidate)) _finishWaiter(waiter, cached);
            }
            _pending = null;
            return;
          }
          if (pendingForce ||
              _retryAdmission ||
              gameFramesDiffer(_lastAttemptedSignature, frame)) {
            _pending = candidate;
          } else {
            _pending = null;
          }
          _dispatchPending();
        })
        .catchError((Object _) {
          if (!_live || round != _round) return;
          _failures = math.min(4, _failures + 1);
          nextDelay = Duration(seconds: math.min(30, 2 << _failures));
          _setStatus(GamePerceptionStatus.unavailable);
        })
        .whenComplete(() {
          if (identical(_sampling, operation)) _sampling = null;
          if (!_live || _terminal) return;
          final forceNext = _forceAfterSample;
          _forceAfterSample = false;
          _scheduleSample(
            forceNext ? Duration.zero : nextDelay,
            force: forceNext,
          );
        });
    _sampling = operation;
    return operation;
  }

  Duration _admissionDelay() {
    final now = _now();
    var delay = Duration.zero;
    void waitUntil(DateTime at) {
      final pending = at.difference(now);
      if (pending > delay) delay = pending;
    }

    final blocked = _blockedUntil;
    if (blocked != null) waitUntil(blocked);
    final last = _lastDispatchAt;
    if (last != null) waitUntil(last.add(minimumDispatchInterval));
    return delay;
  }

  void _dispatchPending() {
    _dispatchTimer?.cancel();
    if (_closed) return;
    final yielding = _syncPriority();
    if (!_live || _terminal || _active != null) return;
    final candidate = _pending;
    if (candidate == null || candidate.round != _round) return;
    if (_now().difference(candidate.capturedAt) > maximumObservationAge) {
      _pending = null;
      unawaited(_sample(force: candidate.force));
      return;
    }
    if (!candidate.force && yielding) {
      _setStatus(GamePerceptionStatus.busy);
      _dispatchTimer = Timer(samplingInterval, _dispatchPending);
      return;
    }
    final delay = _admissionDelay();
    if (delay > Duration.zero) {
      _setStatus(GamePerceptionStatus.busy);
      _dispatchTimer = Timer(delay, _dispatchPending);
      return;
    }
    _pending = null;
    _retryAdmission = false;
    _lastAttemptedSignature = _signature(candidate.frame);
    _lastDispatchAt = _now();
    final revoked = _revoked.future;
    final cancelled = _activeCancelled = Completer<void>();
    _activeForced = candidate.force;
    late final Future<void> operation;
    operation = _analyze(candidate, revoked, cancelled).whenComplete(() {
      if (identical(_active, operation)) {
        _active = null;
        _activeCancelled = null;
        _activeForced = false;
      }
      if (_live && !_terminal) _dispatchPending();
    });
    _active = operation;
  }

  Future<void> _analyze(
    _GameFrameCandidate candidate,
    Future<void> revoked,
    Completer<void> cancelled,
  ) async {
    bool current() =>
        _live && candidate.round == _round && !cancelled.isCompleted;
    try {
      final result = await _gateway.analyze(
        frame: candidate.frame,
        question: _question(),
        locale: _locale(),
        cancelled: Future.any([revoked, cancelled.future]),
        requestIsCurrent: current,
        deadline: requestDeadline,
      );
      if (!current()) return;
      final at = _now();
      if (at.isBefore(candidate.capturedAt) ||
          at.difference(candidate.capturedAt) > maximumObservationAge) {
        return;
      }
      final isCurrentFrame =
          _lastCaptured == null ||
          !gameFramesDiffer(candidate.frame, _lastCaptured!.frame);
      final observation = GameVisualObservation(
        capturedAt: candidate.capturedAt,
        analyzedAt: at,
        frameSequence: candidate.sequence,
        description: result.description,
        modelId: result.modelId,
        roundGeneration: candidate.round,
        sourceMediaId: result.sourceMediaId,
        isCurrentFrame: isCurrentFrame,
      );
      if (isCurrentFrame) {
        _latest = observation;
        _latestSignature = _signature(candidate.frame);
        for (final waiter in _waiters.toList(growable: false)) {
          if (waiter.accepts(candidate)) {
            _finishWaiter(waiter, observation);
          }
        }
      }
      _setStatus(GamePerceptionStatus.observing);
      _onObservation(observation);
    } on GamePerceptionException catch (error) {
      if (!current()) return;
      switch (error.code) {
        case 'GAME_PERCEPTION_DISABLED':
        case 'PRIVACY_CONSENT_REQUIRED':
        case 'PRIVACY_AGE_INELIGIBLE':
        case 'PRIVACY_AGE_REQUIRED':
          _halt(GamePerceptionStatus.disabled);
        case 'GAME_PERCEPTION_MEMBERSHIP_REQUIRED':
          _halt(GamePerceptionStatus.membershipRequired);
        case 'GAME_PERCEPTION_PREMIUM_REQUIRED':
          _halt(GamePerceptionStatus.premiumRequired);
        case 'GAME_PERCEPTION_RATE_LIMIT':
        case 'GAME_PERCEPTION_BUSY':
          // Backpressure/minimum sampling cadence is transient technical
          // scheduling, never a membership or daily-use allowance.
          _retryAdmission = true;
          _blockedUntil = _now().add(
            error.retryAfter ?? const Duration(seconds: 5),
          );
          _pending ??= _lastCaptured;
          _setStatus(GamePerceptionStatus.busy);
        case 'GAME_PERCEPTION_CANCELLED':
          break;
        default:
          // An uncertain dispatch is never retried with the same frame merely
          // because a timer elapsed. A new scene or explicit question can retry.
          _blockedUntil = _now().add(const Duration(seconds: 5));
          _setStatus(GamePerceptionStatus.unavailable);
      }
    } on Object {
      if (!current()) return;
      _blockedUntil = _now().add(const Duration(seconds: 5));
      _setStatus(GamePerceptionStatus.unavailable);
    }
  }

  Future<GameVisualObservation?> refreshForUserQuestion({
    Duration waitBudget = const Duration(seconds: 3),
  }) {
    if (!_started && !_closed) start();
    _cancelBackgroundForUser();
    if (!_live || _terminal || waitBudget <= Duration.zero) {
      return Future.value(null);
    }
    final waiter = _GameQuestionWaiter(_round, _sequence + 1, _now());
    _waiters.add(waiter);
    waiter.timer = Timer(waitBudget, () => _finishWaiter(waiter, null));
    unawaited(_sample(force: true));
    return waiter.result.future;
  }

  void _finishWaiter(_GameQuestionWaiter waiter, GameVisualObservation? value) {
    if (!_waiters.remove(waiter)) return;
    waiter.timer?.cancel();
    waiter.result.complete(value);
  }

  void _halt(GamePerceptionStatus status) {
    _terminal = true;
    _pending = _lastCaptured = null;
    _latest = null;
    _latestSignature = null;
    _sampleTimer?.cancel();
    _dispatchTimer?.cancel();
    for (final waiter in _waiters.toList(growable: false)) {
      _finishWaiter(waiter, null);
    }
    _setStatus(status);
  }

  void invalidateRound() {
    if (_closed) return;
    _round++;
    _revoked.complete();
    _revoked = Completer<void>();
    _pending = _lastCaptured = null;
    _latest = null;
    _latestSignature = _lastAttemptedSignature = null;
    _failures = 0;
    for (final waiter in _waiters.toList(growable: false)) {
      _finishWaiter(waiter, null);
    }
    _scheduleSample(Duration.zero, force: true);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _priorityChanges?.removeListener(notifyPriorityChanged);
    _sampleTimer?.cancel();
    _dispatchTimer?.cancel();
    _round++;
    _revoked.complete();
    _pending = _lastCaptured = null;
    _latest = null;
    _latestSignature = _lastAttemptedSignature = null;
    for (final waiter in _waiters.toList(growable: false)) {
      _finishWaiter(waiter, null);
    }
    _setStatus(GamePerceptionStatus.stopped);
    await Future.wait([?_sampling, ?_active]);
  }
}

ProcessedGameFrame _signature(ProcessedGameFrame frame) => ProcessedGameFrame(
  jpegBytes: Uint8List(0),
  contentHash: frame.contentHash,
  width: frame.width,
  height: frame.height,
  fingerprint: frame.fingerprint,
);

final class _GameFrameCandidate {
  const _GameFrameCandidate(
    this.frame,
    this.capturedAt,
    this.sequence,
    this.round,
    this.force,
  );
  final ProcessedGameFrame frame;
  final DateTime capturedAt;
  final int sequence, round;
  final bool force;
}

final class _GameQuestionWaiter {
  _GameQuestionWaiter(this.round, this.minimumSequence, this.notBefore);
  final int round, minimumSequence;
  final DateTime notBefore;
  bool accepts(_GameFrameCandidate candidate) =>
      candidate.round == round &&
      candidate.sequence >= minimumSequence &&
      !candidate.capturedAt.isBefore(notBefore);
  final result = Completer<GameVisualObservation?>();
  Timer? timer;
}
