import 'dart:async';

import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/streaming_pcm_playback_reference_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';

typedef CorrelatedTtsSessionOpener = Future<TtsSession> Function();
typedef CorrelatedStreamingAudioSinkFactory =
    VerifiedStreamingAudioSink Function();

/// Adapts request-correlated streaming PCM to the same per-utterance contract
/// used by the existing WAV conversation delivery path.
///
/// Each server segment owns one native sink generation. A segment reaches
/// [SpeechTerminal.completed] only after its correlated `segment_done` event
/// and a matching native `drain` receipt. Missing protocol capability falls
/// back before any text is sent to the streaming session.
class CorrelatedStreamingSpeechTurn implements SpeechTurnHandle {
  CorrelatedStreamingSpeechTurn({
    required this.turnId,
    required CorrelatedTtsSessionOpener openSession,
    required this.sinkFactory,
    required this.fallbackTurn,
    this.agentId,
    this.canSpeak,
    this.playbackReference,
    this.startTimeout = const Duration(seconds: 30),
    this.terminalTimeout = const Duration(seconds: 45),
  }) : _openSession = openSession {
    if (turnId.trim().isEmpty) throw ArgumentError.value(turnId, 'turnId');
    if (startTimeout <= Duration.zero) {
      throw ArgumentError.value(startTimeout, 'startTimeout');
    }
    if (terminalTimeout <= Duration.zero) {
      throw ArgumentError.value(terminalTimeout, 'terminalTimeout');
    }
    _unregisterSoundStopper = MaasoTtsPlugin.registerSoundStopper(
      () => cancel('sound_disabled'),
    );
    if (!_speechAllowed) {
      _binding = Future<void>.value();
      unawaited(cancel('sound_disabled'));
    } else {
      _binding = _bind();
    }
    unawaited(
      _binding.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  @override
  final String turnId;
  final CorrelatedTtsSessionOpener _openSession;
  final CorrelatedStreamingAudioSinkFactory sinkFactory;
  final SpeechTurnHandle fallbackTurn;
  final String? agentId;
  final bool Function()? canSpeak;
  final StreamingPcmPlaybackReferenceService? playbackReference;
  final Duration startTimeout;
  final Duration terminalTimeout;

  final List<_CorrelatedPcmUtterance> _utterances = [];
  final Map<String, _CorrelatedPcmUtterance> _utterancesById = {};
  final Set<int> _retiredGenerations = {};
  late final Future<void> _binding;
  Future<void> _sendTail = Future<void>.value();
  Future<void> _playbackTail = Future<void>.value();
  Future<void>? _transportCleanup;
  Future<void>? _cancelFuture;
  bool _cancelFailed = false;
  StreamSubscription<TtsSegmentEvent>? _segmentSubscription;
  void Function()? _unregisterSoundStopper;
  TtsSession? _session;
  CorrelatedTtsSession? _correlatedSession;
  bool _fallbackActive = false;
  bool _cancelled = false;
  bool _transportFailed = false;
  int _nextSegmentOrdinal = 1;

  bool get _speechAllowed {
    if (_cancelled) return false;
    try {
      return canSpeak?.call() ?? MaasoTtsPlugin.soundEnabled.value;
    } on Object {
      return false;
    }
  }

  bool _requireSpeechPermission() {
    if (_speechAllowed) return true;
    if (!_cancelled) {
      unawaited(
        cancel(
          'speech_permission_revoked',
        ).catchError((Object _, StackTrace _) {}),
      );
    }
    return false;
  }

  @override
  SpeechUtteranceHandle speak({
    required String utteranceId,
    required String text,
  }) {
    final trimmedId = utteranceId.trim();
    if (trimmedId.isEmpty ||
        trimmedId != utteranceId ||
        trimmedId.length > 128 ||
        _utterancesById.containsKey(trimmedId)) {
      throw ArgumentError.value(utteranceId, 'utteranceId');
    }
    final utterance = _CorrelatedPcmUtterance(
      turn: this,
      utteranceId: trimmedId,
      text: text,
      ordinal: _utterances.length + 1,
    );
    _utterances.add(utterance);
    _utterancesById[trimmedId] = utterance;
    if (!_requireSpeechPermission()) {
      utterance._cancelLocal();
    } else if (_transportFailed) {
      utterance._failLocal(SpeechTerminal.failed);
    } else if (_fallbackActive) {
      utterance._useFallback();
    } else if (_correlatedSession != null) {
      _send(utterance);
    }
    return utterance;
  }

  Future<void> _bind() async {
    TtsSession session;
    try {
      session = await _openSession();
    } catch (_) {
      if (!_cancelled) _activateFallback();
      return;
    }
    _session = session;
    if (!_requireSpeechPermission()) {
      _retireTransport('turn_cancelled');
      return;
    }
    if (session case final CorrelatedTtsSession correlated
        when correlated.segmentProtocolVersion == 1 &&
            correlated.turnId == turnId) {
      _correlatedSession = correlated;
      _segmentSubscription = correlated.segmentEvents.listen(
        _onSegmentEvent,
        onError: (Object _, StackTrace _) {
          _failTransport(SpeechTerminal.failed, 'segment_stream_error');
        },
        onDone: () {
          if (!_cancelled &&
              _utterances.any((utterance) => !utterance._hasServerTerminal)) {
            _failTransport(SpeechTerminal.failed, 'segment_stream_closed');
          }
        },
        cancelOnError: true,
      );
      for (final utterance in _utterances) {
        _send(utterance);
      }
      return;
    }
    _retireTransport('segment_protocol_unavailable');
    if (!_cancelled) _activateFallback();
  }

  void _activateFallback() {
    if (_fallbackActive || _transportFailed || !_requireSpeechPermission()) {
      return;
    }
    _fallbackActive = true;
    TurnTrace.event(
      'tts.segment.fallback',
      details: 'turn=$turnId reason=protocol_unavailable',
    );
    for (final utterance in _utterances) {
      utterance._useFallback();
    }
  }

  void _send(_CorrelatedPcmUtterance utterance) {
    if (utterance._dispatched ||
        utterance._terminal.isCompleted ||
        !_requireSpeechPermission() ||
        _transportFailed) {
      return;
    }
    final session = _correlatedSession;
    if (session == null) return;
    utterance._dispatched = true;
    final sending = _sendTail.then((_) async {
      if (utterance._terminal.isCompleted ||
          !_requireSpeechPermission() ||
          _transportFailed) {
        return;
      }
      final identity = await session.sendSegment(
        utteranceId: utterance.utteranceId,
        text: utterance.text,
        flush: utterance.ordinal > 1,
      );
      if (!_requireSpeechPermission()) return;
      if (!utterance._matches(identity)) {
        throw StateError('tts_segment_send_identity_mismatch');
      }
      utterance._identity = identity;
      TurnTrace.event(
        'tts.segment.sent',
        details:
            'turn=$turnId utterance=${utterance.utteranceId} ordinal=${utterance.ordinal}',
      );
    });
    _sendTail = sending.catchError((Object _, StackTrace _) {
      _failTransport(SpeechTerminal.failed, 'segment_send_failed');
    });
  }

  void _onSegmentEvent(TtsSegmentEvent event) {
    if (!_requireSpeechPermission() || _transportFailed) return;
    final utterance = _utterancesById[event.identity.utteranceId];
    if (utterance == null || !utterance._matches(event.identity)) {
      _failTransport(SpeechTerminal.failed, 'segment_identity_mismatch');
      return;
    }
    switch (event.kind) {
      case TtsSegmentEventKind.started:
        if (utterance.ordinal != _nextSegmentOrdinal ||
            !utterance._markServerStarted()) {
          _failTransport(SpeechTerminal.failed, 'segment_start_out_of_order');
        }
      case TtsSegmentEventKind.audio:
        final frame = event.audioFrame;
        if (frame == null || !utterance._acceptAudioSequence(frame.sequence)) {
          _failTransport(SpeechTerminal.failed, 'segment_audio_out_of_order');
          return;
        }
        _enqueuePlayback(utterance, () => _writeFrame(utterance, frame));
      case TtsSegmentEventKind.completed:
        if (!utterance._markServerCompleted()) {
          _failTransport(SpeechTerminal.failed, 'segment_done_out_of_order');
          return;
        }
        _nextSegmentOrdinal++;
        _enqueuePlayback(utterance, () => _drainSegment(utterance));
      case TtsSegmentEventKind.failed:
        if (utterance.ordinal != _nextSegmentOrdinal ||
            !utterance._markServerFailed()) {
          _failTransport(SpeechTerminal.failed, 'segment_error_out_of_order');
          return;
        }
        _failTransport(SpeechTerminal.failed, 'segment_failed');
    }
  }

  void _enqueuePlayback(
    _CorrelatedPcmUtterance utterance,
    Future<void> Function() operation,
  ) {
    final running = _playbackTail.then((_) async {
      if (_transportFailed ||
          !_requireSpeechPermission() ||
          utterance._terminal.isCompleted) {
        return;
      }
      await operation();
    });
    _playbackTail = running.catchError((Object _, StackTrace _) {
      if (!utterance._terminal.isCompleted) {
        utterance._failLocal(SpeechTerminal.failed);
      }
      _failTransport(SpeechTerminal.failed, 'segment_playback_failed');
    });
  }

  Future<void> _writeFrame(
    _CorrelatedPcmUtterance utterance,
    TtsAudioFrame frame,
  ) async {
    if (frame.bytes.isEmpty ||
        frame.sampleRate <= 0 ||
        frame.channels <= 0 ||
        frame.encoding.toLowerCase() != 'pcm_s16le') {
      throw StateError('tts_segment_audio_invalid');
    }
    final sink = utterance._sink ??= sinkFactory();
    if (!utterance._sinkStarted) {
      await sink.start(sampleRate: frame.sampleRate, channels: frame.channels);
      if (utterance._revoked ||
          !_requireSpeechPermission() ||
          _transportFailed) {
        await utterance._stopSinkThatStartedAfterRevocation(sink);
        return;
      }
      utterance._sinkStarted = true;
      if (sink case final ControllableStreamingAudioSink controllable) {
        final reference = playbackReference;
        if (reference != null) {
          utterance._playbackLease = reference.bind(
            turnId: turnId,
            utteranceId: utterance.utteranceId,
            spokenText: utterance.text,
            agentId: agentId,
            sink: controllable,
            onStop: (reason) => _cancelUtterance(utterance, reason),
          );
        }
      }
    }
    if (utterance._revoked || !_requireSpeechPermission() || _transportFailed) {
      return;
    }
    await sink.write(frame.bytes);
    if (utterance._revoked || !_requireSpeechPermission() || _transportFailed) {
      return;
    }
    final playbackLease = utterance._playbackLease;
    if (playbackLease != null) {
      final accepted = playbackLease.appendAcceptedPcm(
        pcmS16le: frame.bytes,
        sampleRate: frame.sampleRate,
        channels: frame.channels,
        sequence: frame.sequence,
      );
      if (!accepted) return;
      playbackLease.markAudible();
    }
    utterance._markPlaybackStarted();
  }

  Future<void> _drainSegment(_CorrelatedPcmUtterance utterance) async {
    final sink = utterance._sink;
    if (sink == null || !utterance._sinkStarted || utterance._audioCount == 0) {
      throw StateError('tts_segment_done_without_audio');
    }
    final receipt = await sink.stopWithReceipt(drain: true);
    utterance._playbackLease?.retire();
    if (utterance._revoked || !_requireSpeechPermission() || _transportFailed) {
      return;
    }
    if (receipt.terminal != StreamingAudioPlaybackTerminal.completed ||
        receipt.generation <= 0 ||
        !_retiredGenerations.add(receipt.generation)) {
      throw StateError('tts_segment_drain_receipt_invalid');
    }
    utterance._nativeGeneration = receipt.generation;
    utterance._finish(SpeechTerminal.completed);
    utterance._finishDrain();
    TurnTrace.event(
      'tts.segment.terminal',
      details:
          'turn=$turnId utterance=${utterance.utteranceId} '
          'generation=${utterance._nativeGeneration} result=completed',
    );
  }

  void _failTransport(SpeechTerminal terminal, String reason) {
    if (_transportFailed || _cancelled) return;
    _transportFailed = true;
    TurnTrace.event(
      'tts.segment.transport_failed',
      details: 'turn=$turnId reason=$reason',
    );
    for (final utterance in _utterances) {
      utterance._failAndStop(terminal);
    }
    _retireTransport(reason);
  }

  void _utteranceTimedOut(_CorrelatedPcmUtterance utterance) {
    if (utterance._terminal.isCompleted) return;
    utterance._failLocal(SpeechTerminal.timedOut);
    _failTransport(SpeechTerminal.failed, 'segment_timeout');
  }

  void _retireTransport(String reason) {
    final session = _session;
    if (session == null || _transportCleanup != null) return;
    final subscription = _segmentSubscription;
    _transportCleanup = Future.wait<void>([
      Future<void>.sync(() => session.cancel(reason)),
      if (subscription != null) Future<void>.sync(subscription.cancel),
    ]).then<void>((_) {});
    unawaited(
      _transportCleanup!.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  Future<void> _cancelUtterance(
    _CorrelatedPcmUtterance utterance,
    String reason,
  ) {
    if (utterance._terminal.isCompleted && !utterance._stopFailed) {
      return utterance.drained;
    }
    return cancel(reason);
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) {
    if (_cancelFuture != null && !_cancelFailed) return _cancelFuture!;
    _cancelled = true;
    _cancelFailed = false;
    final stops = <Future<void>>[];
    for (final utterance in _utterances) {
      stops.add(utterance._cancelLocal());
    }
    _retireTransport(reason);
    final cancellingFallback = Future<void>.sync(
      () => fallbackTurn.cancel(reason),
    );
    return _cancelFuture = Future.wait<void>([...stops, cancellingFallback])
        .then<void>(
          (_) {
            _unregisterSoundStopper?.call();
            _unregisterSoundStopper = null;
          },
          onError: (Object error, StackTrace stack) {
            _cancelFailed = true;
            Error.throwWithStackTrace(error, stack);
          },
        );
  }

  @override
  Future<void> get drained async {
    await _binding;
    await Future.wait<void>([
      _sendTail,
      _playbackTail,
      for (final utterance in _utterances) utterance.drained,
      fallbackTurn.drained,
      ?_transportCleanup,
    ]);
    _unregisterSoundStopper?.call();
    _unregisterSoundStopper = null;
  }
}

enum _CorrelatedSegmentPhase { waiting, started, audio, completed, failed }

class _CorrelatedPcmUtterance implements SpeechUtteranceHandle {
  _CorrelatedPcmUtterance({
    required this.turn,
    required this.utteranceId,
    required this.text,
    required this.ordinal,
  }) {
    _startTimer = Timer(turn.startTimeout, () => turn._utteranceTimedOut(this));
    unawaited(
      _drained.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  final CorrelatedStreamingSpeechTurn turn;
  @override
  String get turnId => turn.turnId;
  @override
  final String utteranceId;
  final String text;
  final int ordinal;
  final Completer<bool> _started = Completer<bool>();
  final Completer<SpeechTerminal> _terminal = Completer<SpeechTerminal>();
  final Completer<void> _drained = Completer<void>();
  _CorrelatedSegmentPhase _phase = _CorrelatedSegmentPhase.waiting;
  TtsSegmentIdentity? _identity;
  SpeechUtteranceHandle? _fallback;
  VerifiedStreamingAudioSink? _sink;
  StreamingPcmPlaybackLease? _playbackLease;
  Future<void>? _immediateStop;
  bool _stopFailed = false;
  Timer? _startTimer;
  Timer? _terminalTimer;
  int _lastAudioSequence = 0;
  int _audioCount = 0;
  int? _nativeGeneration;
  bool _dispatched = false;
  bool _sinkStarted = false;
  bool _revoked = false;

  bool get _hasServerTerminal =>
      _phase == _CorrelatedSegmentPhase.completed ||
      _phase == _CorrelatedSegmentPhase.failed;

  bool _matches(TtsSegmentIdentity identity) =>
      (_identity == null || _identity == identity) &&
      identity.turnId == turnId &&
      identity.textSequence == ordinal &&
      identity.utteranceId == utteranceId &&
      identity.segmentOrdinal == ordinal;

  bool _markServerStarted() {
    if (_phase != _CorrelatedSegmentPhase.waiting || _terminal.isCompleted) {
      return false;
    }
    _phase = _CorrelatedSegmentPhase.started;
    return true;
  }

  bool _acceptAudioSequence(int sequence) {
    if ((_phase != _CorrelatedSegmentPhase.started &&
            _phase != _CorrelatedSegmentPhase.audio) ||
        sequence != _lastAudioSequence + 1 ||
        _terminal.isCompleted) {
      return false;
    }
    _phase = _CorrelatedSegmentPhase.audio;
    _lastAudioSequence = sequence;
    _audioCount++;
    return true;
  }

  bool _markServerCompleted() {
    if (_phase != _CorrelatedSegmentPhase.audio || _terminal.isCompleted) {
      return false;
    }
    _phase = _CorrelatedSegmentPhase.completed;
    return true;
  }

  bool _markServerFailed() {
    if ((_phase != _CorrelatedSegmentPhase.waiting &&
            _phase != _CorrelatedSegmentPhase.started &&
            _phase != _CorrelatedSegmentPhase.audio) ||
        _terminal.isCompleted) {
      return false;
    }
    _phase = _CorrelatedSegmentPhase.failed;
    return true;
  }

  void _markPlaybackStarted() {
    if (_revoked || _started.isCompleted || _terminal.isCompleted) return;
    _startTimer?.cancel();
    _started.complete(true);
    _terminalTimer = Timer(
      turn.terminalTimeout,
      () => turn._utteranceTimedOut(this),
    );
    TurnTrace.event(
      'tts.utterance.started',
      details: 'turn=$turnId utterance=$utteranceId transport=pcm',
    );
  }

  void _useFallback() {
    if (_fallback != null ||
        _terminal.isCompleted ||
        _revoked ||
        !turn._requireSpeechPermission()) {
      return;
    }
    final fallback = _fallback = turn.fallbackTurn.speak(
      utteranceId: utteranceId,
      text: text,
    );
    unawaited(
      fallback.started.then<void>((started) {
        if (_started.isCompleted ||
            _revoked ||
            !turn._requireSpeechPermission()) {
          return;
        }
        if (started) {
          _startTimer?.cancel();
          _started.complete(true);
        }
      }, onError: (Object _, StackTrace _) {}),
    );
    unawaited(
      fallback.terminal.then<void>(
        (terminal) {
          _finish(terminal);
        },
        onError: (Object _, StackTrace _) {
          _finish(SpeechTerminal.failed);
        },
      ),
    );
    unawaited(
      fallback.drained.then<void>(
        (_) => _finishDrain(),
        onError: (Object error, StackTrace stack) {
          _finishDrain(error, stack);
        },
      ),
    );
  }

  void _finish(SpeechTerminal result) {
    if (_terminal.isCompleted) return;
    _startTimer?.cancel();
    _terminalTimer?.cancel();
    if (!_started.isCompleted) _started.complete(false);
    _terminal.complete(result);
  }

  void _failLocal(SpeechTerminal result) {
    _revoked = true;
    _playbackLease?.retire();
    _finish(result);
    if (_sink == null && _fallback == null) _finishDrain();
  }

  void _failAndStop(SpeechTerminal result) {
    if (!_terminal.isCompleted) _failLocal(result);
    if (_drained.isCompleted) return;
    final stopping = _stopImmediately();
    unawaited(
      stopping.then<void>(
        (_) => _finishDrain(),
        onError: (Object error, StackTrace stack) {
          _finishDrain(error, stack);
        },
      ),
    );
  }

  Future<void> _stopImmediately() {
    _playbackLease?.retire();
    return _immediateStop ??=
        Future<void>.sync(() async {
          final fallback = _fallback;
          if (fallback != null) {
            await fallback.cancel('segment_retired');
          } else {
            final sink = _sink;
            if (sink != null) {
              final receipt = await sink.stopWithReceipt(drain: false);
              if (receipt.terminal !=
                  StreamingAudioPlaybackTerminal.cancelled) {
                throw StateError('tts_segment_cancel_receipt_invalid');
              }
              if (receipt.generation > 0) {
                _nativeGeneration = receipt.generation;
              }
            }
          }
          _stopFailed = false;
        }).catchError((Object error, StackTrace stack) {
          // Keep the failed cleanup observable, but allow another mute/cancel to
          // retry the native stop while this turn remains registered.
          _stopFailed = true;
          _immediateStop = null;
          Error.throwWithStackTrace(error, stack);
        });
  }

  Future<void> _stopSinkThatStartedAfterRevocation(
    VerifiedStreamingAudioSink sink,
  ) async {
    final earlierStop = _immediateStop;
    if (earlierStop != null) await earlierStop;
    if (sink case final ControllableStreamingAudioSink controllable
        when controllable.activeGeneration == null) {
      return;
    }
    final receipt = await sink.stopWithReceipt(drain: false);
    if (receipt.terminal != StreamingAudioPlaybackTerminal.cancelled) {
      throw StateError('tts_segment_late_start_cancel_receipt_invalid');
    }
    if (receipt.generation > 0) {
      _nativeGeneration = receipt.generation;
    }
  }

  Future<void> _cancelLocal() async {
    if (_terminal.isCompleted && !_stopFailed) {
      await _immediateStop;
      return;
    }
    _revoked = true;
    _finish(SpeechTerminal.cancelled);
    try {
      await _stopImmediately();
      _finishDrain();
    } catch (error, stack) {
      _finishDrain(error, stack);
      rethrow;
    }
  }

  void _finishDrain([Object? error, StackTrace? stack]) {
    if (_drained.isCompleted) return;
    if (error == null) {
      _drained.complete();
    } else {
      _drained.completeError(error, stack);
    }
  }

  @override
  Future<bool> get started => _started.future;

  @override
  Future<SpeechTerminal> get terminal => _terminal.future;

  @override
  Future<void> get drained => _drained.future;

  @override
  Future<void> cancel([String reason = 'cancelled']) =>
      turn._cancelUtterance(this, reason);
}
