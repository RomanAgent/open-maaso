import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/speech_playback_clock_emitter.dart';
import 'package:maaso/src/features/agent/application/speech/speech_playback_lease.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

/// Immutable identity of PCM that the native host accepted for one utterance.
final class StreamingPcmPlaybackIdentity {
  const StreamingPcmPlaybackIdentity({
    required this.generation,
    required this.turnId,
    required this.utteranceId,
    required this.agentId,
  });

  final int generation;
  final String turnId;
  final String utteranceId;
  final String? agentId;

  @override
  bool operator ==(Object other) =>
      other is StreamingPcmPlaybackIdentity &&
      other.generation == generation &&
      other.turnId == turnId &&
      other.utteranceId == utteranceId &&
      other.agentId == agentId;

  @override
  int get hashCode => Object.hash(generation, turnId, utteranceId, agentId);
}

/// A bounded receipt for the exact playback reference available right now.
///
/// It intentionally carries no PCM. Callers present the receipt back to
/// [StreamingPcmPlaybackReferenceService.filterPlaybackCandidate], which
/// rechecks ownership synchronously before reading the private ring buffer.
final class StreamingPcmReferenceReceipt {
  const StreamingPcmReferenceReceipt({
    required this.identity,
    required this.referenceRevision,
    required this.acceptedSequence,
    required this.windowStartSample,
    required this.windowEndSample,
    required this.retainedSamples,
    required this.droppedFrames,
  });

  final StreamingPcmPlaybackIdentity identity;
  final int referenceRevision;
  final int acceptedSequence;
  final int windowStartSample;
  final int windowEndSample;
  final int retainedSamples;
  final int droppedFrames;
}

/// Owns the current conversation PCM player and its recent acoustic reference.
///
/// The ring keeps at most [maximumReferenceSamples] mono 16 kHz samples and
/// [maximumReferenceFrames] source frames. Only PCM acknowledged by the native
/// sink enters it. Provider frame boundaries do not affect retained PCM: old
/// chunks are trimmed by exact sample count and compacted when needed. Every
/// mutation is checked against the active registration, so a late frame from a
/// retired generation cannot become the reference for a replacement utterance.
final class StreamingPcmPlaybackReferenceService extends AppService {
  StreamingPcmPlaybackReferenceService({
    this.maximumReferenceSamples = 2200000,
    this.maximumReferenceFrames = 4096,
    this.maximumSearchSamples = 48000,
    this.playbackPositionPollInterval = const Duration(milliseconds: 40),
    this.playbackPositionTimeout = const Duration(milliseconds: 200),
    this.playbackPositionFreshness = const Duration(milliseconds: 250),
    this.minimumEchoCorrelation = 0.985,
    this.maximumEchoResidualRatio = 0.03,
    this.maximumPureEchoResidualRms = 0.003,
  }) {
    if (maximumReferenceSamples < 1600) {
      throw ArgumentError.value(
        maximumReferenceSamples,
        'maximumReferenceSamples',
      );
    }
    if (maximumReferenceFrames <= 0) {
      throw ArgumentError.value(
        maximumReferenceFrames,
        'maximumReferenceFrames',
      );
    }
    if (maximumSearchSamples < 1600 ||
        maximumSearchSamples > maximumReferenceSamples) {
      throw ArgumentError.value(maximumSearchSamples, 'maximumSearchSamples');
    }
    if (playbackPositionPollInterval <= Duration.zero ||
        playbackPositionTimeout <= Duration.zero ||
        playbackPositionFreshness <= Duration.zero) {
      throw ArgumentError(
        'Playback position polling durations must all be positive.',
      );
    }
    if (minimumEchoCorrelation <= 0 || minimumEchoCorrelation > 1) {
      throw ArgumentError.value(
        minimumEchoCorrelation,
        'minimumEchoCorrelation',
      );
    }
    if (maximumEchoResidualRatio < 0 || maximumEchoResidualRatio >= 1) {
      throw ArgumentError.value(
        maximumEchoResidualRatio,
        'maximumEchoResidualRatio',
      );
    }
    if (maximumPureEchoResidualRms < 0 || maximumPureEchoResidualRms >= 0.1) {
      throw ArgumentError.value(
        maximumPureEchoResidualRms,
        'maximumPureEchoResidualRms',
      );
    }
  }

  static const int referenceSampleRate = 16000;
  static int _playbackClockSequence = 0;

  final int maximumReferenceSamples;
  final int maximumReferenceFrames;
  final int maximumSearchSamples;
  final Duration playbackPositionPollInterval;
  final Duration playbackPositionTimeout;
  final Duration playbackPositionFreshness;
  final double minimumEchoCorrelation;
  final double maximumEchoResidualRatio;
  final double maximumPureEchoResidualRms;
  final Stopwatch _monotonicClock = Stopwatch()..start();

  StreamingPcmPlaybackLease? _current;
  bool _closed = false;

  StreamingPcmPlaybackLease bind({
    required String turnId,
    required String utteranceId,
    required String spokenText,
    required String? agentId,
    required ControllableStreamingAudioSink sink,
    Future<void> Function(String reason)? onStop,
  }) {
    if (_closed) throw StateError('pcm_playback_reference_closed');
    final generation = sink.activeGeneration;
    if (generation == null || generation <= 0) {
      throw StateError('pcm_playback_generation_unavailable');
    }
    if (turnId.trim().isEmpty || utteranceId.trim().isEmpty) {
      throw ArgumentError('PCM playback identity must be non-empty.');
    }
    final existing = _current;
    if (existing != null) _revoke(existing);
    final lease = StreamingPcmPlaybackLease._(
      owner: this,
      identity: StreamingPcmPlaybackIdentity(
        generation: generation,
        turnId: turnId,
        utteranceId: utteranceId,
        agentId: agentId,
      ),
      spokenText: spokenText,
      sink: sink,
      onStop: onStop,
    );
    _current = lease;
    return lease;
  }

  SpeechPlaybackLease? captureCurrentPlayback({String? agentId}) {
    final current = _current;
    if (current == null ||
        !current._audible ||
        current._paused ||
        !_isCurrent(current) ||
        (agentId != null &&
            current.agentId != null &&
            current.agentId != agentId)) {
      return null;
    }
    return current;
  }

  StreamingPcmReferenceReceipt? captureCurrentReference() {
    final current = _current;
    if (current == null ||
        !current._audible ||
        current._paused ||
        !current._hasFreshPlaybackPosition ||
        current._referenceSamples == 0 ||
        !_isCurrent(current)) {
      return null;
    }
    final playbackHead = current._playbackHeadReferenceSample;
    if (playbackHead == null) return null;
    final storedStart = current._referenceStartSample;
    final storedEnd = storedStart + current._referenceSamples;
    if (playbackHead < storedStart || playbackHead > storedEnd) return null;
    final historySamples = maximumSearchSamples * 5 ~/ 6;
    final lookaheadSamples = maximumSearchSamples - historySamples;
    final windowStart = math.max(storedStart, playbackHead - historySamples);
    final windowEnd = math.min(storedEnd, playbackHead + lookaheadSamples);
    if (windowEnd <= windowStart) return null;
    return StreamingPcmReferenceReceipt(
      identity: current.identity,
      referenceRevision: current._referenceRevision,
      acceptedSequence: current._acceptedSequence,
      windowStartSample: windowStart,
      windowEndSample: windowEnd,
      retainedSamples: windowEnd - windowStart,
      droppedFrames: current._droppedFrames,
    );
  }

  /// Removes a strongly matched playback component from one candidate chunk.
  ///
  /// `null` is returned only for near-digital-silence residuals after fitting
  /// the current generation's delayed/scaled PCM. A mixed chunk returns the
  /// residual PCM so quiet user speech is not discarded with louder playback.
  /// Missing, stale, weakly correlated, or poorly fitted references return the
  /// original object unchanged. This remains a conservative second stage after
  /// the platform's hardware AEC and preserves the normal recognition gate.
  Uint8List? filterPlaybackCandidate(
    Uint8List microphonePcm16Mono,
    StreamingPcmReferenceReceipt receipt,
  ) {
    final current = _current;
    if (current == null ||
        !_isCurrent(current) ||
        !current._audible ||
        current._paused ||
        current.identity != receipt.identity ||
        current._referenceRevision != receipt.referenceRevision ||
        current._acceptedSequence != receipt.acceptedSequence ||
        receipt.windowStartSample < current._referenceStartSample ||
        receipt.windowEndSample >
            current._referenceStartSample + current._referenceSamples ||
        receipt.windowEndSample <= receipt.windowStartSample ||
        receipt.retainedSamples !=
            receipt.windowEndSample - receipt.windowStartSample ||
        microphonePcm16Mono.length < 320 ||
        microphonePcm16Mono.length.isOdd) {
      return microphonePcm16Mono;
    }
    final microphone = _pcm16MonoToFloat(microphonePcm16Mono);
    final reference = current._flattenReferenceRange(
      receipt.windowStartSample,
      receipt.windowEndSample,
    );
    if (microphone.length > 3200 || reference.length < microphone.length) {
      return microphonePcm16Mono;
    }
    final microphoneEnergy = _energy(microphone, stride: 8);
    if (microphoneEnergy <= 1e-8) return microphonePcm16Mono;

    var bestCorrelation = 0.0;
    var bestResidualRatio = 1.0;
    var bestOffset = 0;
    const sampleStride = 8;
    const offsetStep = 40;
    final lastOffset = reference.length - microphone.length;
    void inspectOffset(int offset) {
      var dot = 0.0;
      var referenceEnergy = 0.0;
      for (var index = 0; index < microphone.length; index += sampleStride) {
        final ref = reference[offset + index];
        dot += microphone[index] * ref;
        referenceEnergy += ref * ref;
      }
      if (referenceEnergy <= 1e-8) return;
      final correlation =
          dot.abs() / math.sqrt(microphoneEnergy * referenceEnergy);
      if (correlation <= bestCorrelation) return;
      final gain = (dot / referenceEnergy).clamp(-2.0, 2.0).toDouble();
      var residualEnergy = 0.0;
      for (var index = 0; index < microphone.length; index += sampleStride) {
        final residual = microphone[index] - gain * reference[offset + index];
        residualEnergy += residual * residual;
      }
      bestCorrelation = correlation;
      bestResidualRatio = residualEnergy / microphoneEnergy;
      bestOffset = offset;
    }

    for (var offset = 0; offset <= lastOffset; offset += offsetStep) {
      inspectOffset(offset);
    }
    // Coarse search bounds CPU cost across the three-second ring. Refine the
    // winning acoustic-delay window sample-by-sample so a non-40-sample room
    // delay does not turn a true playback echo into a false user candidate.
    final refineStart = math.max(0, bestOffset - offsetStep);
    final refineEnd = math.min(lastOffset, bestOffset + offsetStep);
    for (var offset = refineStart; offset <= refineEnd; offset++) {
      inspectOffset(offset);
    }
    if (bestCorrelation < minimumEchoCorrelation ||
        bestResidualRatio > maximumEchoResidualRatio) {
      return microphonePcm16Mono;
    }

    var fullDot = 0.0;
    var fullReferenceEnergy = 0.0;
    for (var index = 0; index < microphone.length; index++) {
      final referenceSample = reference[bestOffset + index];
      fullDot += microphone[index] * referenceSample;
      fullReferenceEnergy += referenceSample * referenceSample;
    }
    if (fullReferenceEnergy <= 1e-8) return microphonePcm16Mono;
    final finalGain = (fullDot / fullReferenceEnergy)
        .clamp(-2.0, 2.0)
        .toDouble();

    final residual = Float32List(microphone.length);
    var residualEnergy = 0.0;
    for (var index = 0; index < microphone.length; index++) {
      final value =
          microphone[index] - finalGain * reference[bestOffset + index];
      residual[index] = value;
      residualEnergy += value * value;
    }
    final residualRms = math.sqrt(residualEnergy / residual.length);
    if (residualRms <= maximumPureEchoResidualRms) return null;
    return _floatToPcm16Mono(residual);
  }

  /// Compatibility predicate for diagnostics and existing focused tests.
  bool isLikelyOnlyPlaybackEcho(
    Uint8List microphonePcm16Mono,
    StreamingPcmReferenceReceipt receipt,
  ) => filterPlaybackCandidate(microphonePcm16Mono, receipt) == null;

  bool _isCurrent(StreamingPcmPlaybackLease lease) =>
      !_closed && identical(_current, lease) && !lease._retired;

  bool _revoke(StreamingPcmPlaybackLease lease) {
    if (!_isCurrent(lease)) return false;
    _current = null;
    lease._retired = true;
    lease._paused = false;
    lease._positionTimer?.cancel();
    lease._positionTimer = null;
    lease._referenceFrames.clear();
    lease._referenceSamples = 0;
    lease._referenceRevision++;
    lease._clock.stop();
    if (lease._audible) {
      lease._audible = false;
      EventBus().fire(SpeakingStatusEvent(false, agentId: lease.agentId));
    }
    return true;
  }

  @override
  void onClose() {
    if (_closed) return;
    final current = _current;
    if (current != null) {
      // Revoke before the asynchronous native stop so no late callback can
      // publish reference PCM after the account scope is gone.
      unawaited(
        current
            .stop('reference_service_closed')
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    _closed = true;
    super.onClose();
  }

  static Float32List _pcm16MonoToFloat(Uint8List bytes) {
    final output = Float32List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var index = 0; index < output.length; index++) {
      output[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
    }
    return output;
  }

  static Uint8List _floatToPcm16Mono(Float32List samples) {
    final output = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(output);
    for (var index = 0; index < samples.length; index++) {
      final value = (samples[index].clamp(-1.0, 1.0) * 32767).round();
      data.setInt16(index * 2, value, Endian.little);
    }
    return output;
  }

  static double _energy(Float32List samples, {required int stride}) {
    var energy = 0.0;
    for (var index = 0; index < samples.length; index += stride) {
      final sample = samples[index];
      energy += sample * sample;
    }
    return energy;
  }
}

/// Exact control lease for one native PCM generation.
final class StreamingPcmPlaybackLease implements SpeechPlaybackLease {
  StreamingPcmPlaybackLease._({
    required StreamingPcmPlaybackReferenceService owner,
    required this.identity,
    required this.spokenText,
    required ControllableStreamingAudioSink sink,
    required Future<void> Function(String reason)? onStop,
  }) : _owner = owner,
       _sink = sink,
       _onStop = onStop;

  final StreamingPcmPlaybackReferenceService _owner;
  final ControllableStreamingAudioSink _sink;
  final Future<void> Function(String reason)? _onStop;
  final Queue<_StreamingPcmReferenceChunk> _referenceFrames =
      Queue<_StreamingPcmReferenceChunk>();

  final StreamingPcmPlaybackIdentity identity;
  late final _clock = SpeechPlaybackClockEmitter(
    playbackId:
        'pcm-${++StreamingPcmPlaybackReferenceService._playbackClockSequence}',
    nativeGeneration: generation,
    turnId: turnId,
    utteranceId: utteranceId,
    source: SpeechPlaybackClockSource.pcm,
    agentId: agentId,
  );
  @override
  final String spokenText;

  int _referenceSamples = 0;
  int _referenceStartSample = 0;
  int _acceptedSequence = 0;
  int _referenceRevision = 0;
  int _droppedFrames = 0;
  int? _sourceSampleRate;
  int? _sourceChannels;
  int _sourceFramesSeen = 0;
  int _nextReferenceSample = 0;
  double? _previousSourceSample;
  int? _playbackHeadReferenceSample;
  int _lastNativePlayedFrames = 0;
  int _lastNativeAcceptedFrames = 0;
  Duration? _lastPositionObservedAt;
  Timer? _positionTimer;
  bool _positionPollInFlight = false;
  bool _referenceFailed = false;
  bool _audible = false;
  bool _paused = false;
  bool _retired = false;

  @override
  int get generation => identity.generation;
  @override
  String get turnId => identity.turnId;
  @override
  String get utteranceId => identity.utteranceId;
  @override
  String? get agentId => identity.agentId;

  bool get isCurrent => _owner._isCurrent(this);

  bool get _hasFreshPlaybackPosition {
    if (_referenceFailed || _playbackHeadReferenceSample == null) return false;
    final observedAt = _lastPositionObservedAt;
    return observedAt != null &&
        _owner._monotonicClock.elapsed - observedAt <=
            _owner.playbackPositionFreshness;
  }

  bool appendAcceptedPcm({
    required Uint8List pcmS16le,
    required int sampleRate,
    required int channels,
    required int sequence,
  }) {
    if (!_owner._isCurrent(this)) return false;
    if (sequence != _acceptedSequence + 1 ||
        sampleRate < 8000 ||
        sampleRate > 192000 ||
        channels < 1 ||
        channels > 2 ||
        pcmS16le.isEmpty ||
        pcmS16le.length % (channels * 2) != 0) {
      throw StateError('pcm_playback_reference_invalid');
    }
    final reference = _resampleToReference(
      pcmS16le,
      sampleRate: sampleRate,
      channels: channels,
    );
    _acceptedSequence = sequence;
    _referenceRevision++;
    if (reference.isEmpty || _referenceFailed) return true;
    var boundedReference = reference;
    if (reference.length > _owner.maximumReferenceSamples) {
      boundedReference = Float32List(_owner.maximumReferenceSamples)
        ..setRange(
          0,
          _owner.maximumReferenceSamples,
          reference,
          reference.length - _owner.maximumReferenceSamples,
        );
      _referenceFrames.clear();
      _referenceSamples = 0;
      _referenceStartSample =
          _nextReferenceSample - _owner.maximumReferenceSamples;
      _droppedFrames++;
    }
    _referenceFrames.addLast(_StreamingPcmReferenceChunk(boundedReference));
    _referenceSamples += boundedReference.length;
    while (_referenceSamples > _owner.maximumReferenceSamples) {
      final overflow = _referenceSamples - _owner.maximumReferenceSamples;
      final oldest = _referenceFrames.first;
      if (oldest.length <= overflow) {
        _referenceFrames.removeFirst();
        _referenceSamples -= oldest.length;
        _referenceStartSample += oldest.length;
      } else {
        oldest.start += overflow;
        _referenceSamples -= overflow;
        _referenceStartSample += overflow;
      }
      _droppedFrames++;
    }
    if (_referenceFrames.length > _owner.maximumReferenceFrames) {
      final compacted = _flattenReference();
      _referenceFrames
        ..clear()
        ..addLast(_StreamingPcmReferenceChunk(compacted));
    }
    return true;
  }

  bool markAudible() {
    if (!_owner._isCurrent(this) || _retired || _paused) return false;
    if (_audible) return true;
    _audible = true;
    if (_sink is PositionedStreamingAudioSink && !_referenceFailed) {
      _playbackHeadReferenceSample ??= 0;
      _startPositionPolling();
    } else {
      _invalidateReference();
    }
    EventBus().fire(SpeakingStatusEvent(true, agentId: agentId));
    return true;
  }

  /// Refreshes the authoritative native playback cursor for this generation.
  ///
  /// The periodic poll uses this same method. It is public so platform probes
  /// and deterministic contract tests can force one receipt without exposing
  /// PCM or mutable cursor state.
  Future<bool> refreshPlaybackPosition() async {
    if (!_owner._isCurrent(this) ||
        _referenceFailed ||
        _positionPollInFlight ||
        _sink is! PositionedStreamingAudioSink) {
      return false;
    }
    _positionPollInFlight = true;
    try {
      final positioned = _sink;
      final receipt = await positioned.positionWithReceipt().timeout(
        _owner.playbackPositionTimeout,
      );
      if (!_owner._isCurrent(this)) return false;
      if (receipt.generation != generation ||
          receipt.playedFrames < _lastNativePlayedFrames ||
          receipt.acceptedFrames < _lastNativeAcceptedFrames ||
          receipt.playedFrames > receipt.acceptedFrames ||
          receipt.acceptedFrames > _sourceFramesSeen) {
        _invalidateReference();
        return false;
      }
      final head = _referenceSamplesForSourcePrefix(
        receipt.playedFrames,
        _sourceSampleRate!,
      );
      if (head < (_playbackHeadReferenceSample ?? 0) ||
          head > _nextReferenceSample) {
        _invalidateReference();
        return false;
      }
      _lastNativePlayedFrames = receipt.playedFrames;
      _lastNativeAcceptedFrames = receipt.acceptedFrames;
      _lastPositionObservedAt = _owner._monotonicClock.elapsed;
      if (_playbackHeadReferenceSample != head) {
        _playbackHeadReferenceSample = head;
        _referenceRevision++;
      }
      if (_audible && !_paused && receipt.playedFrames > 0) {
        final positionMs = receipt.playedFrames * 1000 ~/ _sourceSampleRate!;
        // Accepted PCM is not proof of audible output. Only a matching native
        // cursor that actually advanced starts the correlated speech clock.
        _clock.start(positionMs: positionMs, authoritative: true);
        _clock.observe(positionMs);
      }
      return true;
    } catch (_) {
      if (_owner._isCurrent(this)) _invalidateReference();
      return false;
    } finally {
      _positionPollInFlight = false;
    }
  }

  void _startPositionPolling() {
    if (_positionTimer != null || _referenceFailed || _paused || _retired) {
      return;
    }
    unawaited(refreshPlaybackPosition());
    _positionTimer = Timer.periodic(
      _owner.playbackPositionPollInterval,
      (_) => unawaited(refreshPlaybackPosition()),
    );
  }

  void _invalidateReference() {
    if (_referenceFailed) return;
    _referenceFailed = true;
    _positionTimer?.cancel();
    _positionTimer = null;
    _referenceFrames.clear();
    _referenceSamples = 0;
    _referenceStartSample = _nextReferenceSample;
    _referenceRevision++;
    _clock.stop();
  }

  static int _referenceSamplesForSourcePrefix(
    int sourceFrames,
    int sourceSampleRate,
  ) {
    if (sourceFrames <= 0) return 0;
    return ((sourceFrames - 1) *
                StreamingPcmPlaybackReferenceService.referenceSampleRate) ~/
            sourceSampleRate +
        1;
  }

  /// Synchronously invalidates reference/control ownership.
  bool retire() => _owner._revoke(this);

  @override
  Future<bool> pause() async {
    if (!_owner._isCurrent(this) || !_audible) return false;
    if (_paused) return true;
    final receipt = await _sink.pauseWithReceipt();
    if (!_owner._isCurrent(this) ||
        _sink.activeGeneration != generation ||
        receipt.generation != generation ||
        receipt.state != StreamingAudioControlState.paused) {
      return false;
    }
    await refreshPlaybackPosition();
    _paused = true;
    _positionTimer?.cancel();
    _positionTimer = null;
    _clock.pause();
    if (_audible) {
      _audible = false;
      EventBus().fire(SpeakingStatusEvent(false, agentId: agentId));
    }
    return true;
  }

  @override
  Future<bool> resume() async {
    if (!_owner._isCurrent(this) || !_paused) return false;
    final receipt = await _sink.resumeWithReceipt();
    if (!_owner._isCurrent(this) ||
        _sink.activeGeneration != generation ||
        receipt.generation != generation ||
        receipt.state != StreamingAudioControlState.resumed) {
      return false;
    }
    _paused = false;
    _audible = true;
    _clock.resume();
    _startPositionPolling();
    EventBus().fire(SpeakingStatusEvent(true, agentId: agentId));
    return true;
  }

  @override
  Future<bool> stop([String reason = 'interrupted']) async {
    if (!_owner._revoke(this)) return false;
    final onStop = _onStop;
    if (onStop != null) {
      await onStop(reason);
      return true;
    }
    final receipt = await _sink.stopWithReceipt(drain: false);
    if (receipt.generation != generation ||
        receipt.terminal != StreamingAudioPlaybackTerminal.cancelled) {
      throw StateError('pcm_playback_cancel_receipt_invalid');
    }
    return true;
  }

  Float32List _flattenReference() {
    final output = Float32List(_referenceSamples);
    var offset = 0;
    for (final frame in _referenceFrames) {
      output.setRange(
        offset,
        offset + frame.length,
        frame.samples,
        frame.start,
      );
      offset += frame.length;
    }
    return output;
  }

  Float32List _flattenReferenceRange(int absoluteStart, int absoluteEnd) {
    if (absoluteStart < _referenceStartSample ||
        absoluteEnd > _referenceStartSample + _referenceSamples ||
        absoluteEnd <= absoluteStart) {
      throw StateError('pcm_playback_reference_range_invalid');
    }
    final output = Float32List(absoluteEnd - absoluteStart);
    var chunkStart = _referenceStartSample;
    var outputOffset = 0;
    for (final chunk in _referenceFrames) {
      final chunkEnd = chunkStart + chunk.length;
      final overlapStart = math.max(absoluteStart, chunkStart);
      final overlapEnd = math.min(absoluteEnd, chunkEnd);
      if (overlapEnd > overlapStart) {
        final sourceStart = chunk.start + overlapStart - chunkStart;
        final length = overlapEnd - overlapStart;
        output.setRange(
          outputOffset,
          outputOffset + length,
          chunk.samples,
          sourceStart,
        );
        outputOffset += length;
      }
      if (chunkEnd >= absoluteEnd) break;
      chunkStart = chunkEnd;
    }
    if (outputOffset != output.length) {
      throw StateError('pcm_playback_reference_range_incomplete');
    }
    return output;
  }

  Float32List _resampleToReference(
    Uint8List bytes, {
    required int sampleRate,
    required int channels,
  }) {
    final sourceFrames = bytes.length ~/ (channels * 2);
    if (sourceFrames == 0) return Float32List(0);
    final establishedRate = _sourceSampleRate;
    final establishedChannels = _sourceChannels;
    if ((establishedRate != null && establishedRate != sampleRate) ||
        (establishedChannels != null && establishedChannels != channels)) {
      throw StateError('pcm_playback_reference_format_changed');
    }
    _sourceSampleRate ??= sampleRate;
    _sourceChannels ??= channels;

    final data = ByteData.sublistView(bytes);
    final source = Float32List(sourceFrames);
    for (var frame = 0; frame < sourceFrames; frame++) {
      var sum = 0.0;
      for (var channel = 0; channel < channels; channel++) {
        sum +=
            data.getInt16((frame * channels + channel) * 2, Endian.little) /
            32768.0;
      }
      source[frame] = sum / channels;
    }

    final startFrame = _sourceFramesSeen;
    final finalFrame = startFrame + sourceFrames - 1;
    final referenceRate =
        StreamingPcmPlaybackReferenceService.referenceSampleRate;
    final output = <double>[];
    while (true) {
      final positionNumerator = _nextReferenceSample * sampleRate;
      final lower = positionNumerator ~/ referenceRate;
      final remainder = positionNumerator % referenceRate;
      final upper = remainder == 0 ? lower : lower + 1;
      if (upper > finalFrame) break;

      double sampleAt(int absoluteFrame) {
        if (absoluteFrame == startFrame - 1) {
          final previous = _previousSourceSample;
          if (previous == null) {
            throw StateError('pcm_playback_reference_phase_invalid');
          }
          return previous;
        }
        final localFrame = absoluteFrame - startFrame;
        if (localFrame < 0 || localFrame >= source.length) {
          throw StateError('pcm_playback_reference_phase_invalid');
        }
        return source[localFrame];
      }

      final lowerSample = sampleAt(lower);
      if (remainder == 0) {
        output.add(lowerSample);
      } else {
        final fraction = remainder / referenceRate;
        output.add(lowerSample * (1 - fraction) + sampleAt(upper) * fraction);
      }
      _nextReferenceSample++;
    }
    _sourceFramesSeen += sourceFrames;
    _previousSourceSample = source.last;
    return Float32List.fromList(output);
  }
}

final class _StreamingPcmReferenceChunk {
  _StreamingPcmReferenceChunk(this.samples);

  final Float32List samples;
  int start = 0;

  int get length => samples.length - start;
}
