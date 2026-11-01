// Native Sherpa implementation. Exported through vad_service.dart.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/sherpa_model_download_service.dart';
import 'package:maaso/src/core/services/sherpa_model_registry.dart';

/// User-spoken-segment events surfaced on the global [EventBus].
///
/// L0 sensory consumers (EmotionSensorService, AgentRuntime) listen for
/// these to know "the human is talking right now" vs "they fell silent".
/// Kept agentId-less because they describe the *human*, not any specific
/// agent — every runtime that wants to react should subscribe.
class UserSpeakingStartedEvent extends ClawEvent {}

class UserSpeakingEndedEvent extends ClawEvent {
  UserSpeakingEndedEvent({
    required this.duration,
    required this.samples,
    this.beganDuringPlayback = false,
  });

  /// Length of the spoken segment.
  final Duration duration;

  /// Raw 16 kHz mono PCM samples of the utterance, normalized to [-1, 1].
  /// Mainly useful for replay or future speech consumers; listeners that just
  /// want to know the user spoke can ignore.
  final Float32List samples;

  /// Legacy compatibility marker for callers that construct this event.
  ///
  /// [VadService] never sets this for playback-time audio: those segments use
  /// [PlaybackSpeechCandidateEndedEvent] and remain outside the formal user
  /// speech chain.
  final bool beganDuringPlayback;
}

/// Speech detected while the agent's own audio is still playing.
///
/// This deliberately does not extend [UserSpeakingStartedEvent]. Playback
/// audio can contain self echo, so only the acoustic barge-in coordinator may
/// treat it as a candidate. Global human-presence and turn-input consumers
/// must continue listening exclusively to [UserSpeakingStartedEvent].
class PlaybackSpeechCandidateStartedEvent extends ClawEvent {
  @override
  bool get verboseLog => false;
}

/// A complete playback-time speech candidate with its exact VAD segment.
///
/// This deliberately does not extend [UserSpeakingEndedEvent]. The samples
/// need echo/backchannel classification before they can become a user turn.
class PlaybackSpeechCandidateEndedEvent extends ClawEvent {
  PlaybackSpeechCandidateEndedEvent({
    required this.duration,
    required this.samples,
  });

  final Duration duration;
  final Float32List samples;

  @override
  bool get verboseLog => false;
}

/// Minimal detector contract used to keep ordinary and playback-time VAD
/// state independent and to exercise their boundary behavior in tests.
abstract interface class VadAudioDetector {
  void acceptWaveform(Float32List samples);

  bool isDetected();

  bool isEmpty();

  Float32List frontSamples();

  void pop();

  void reset();

  void free();
}

final class _SherpaVadAudioDetector implements VadAudioDetector {
  _SherpaVadAudioDetector(this._delegate);

  final sherpa.VoiceActivityDetector _delegate;

  @override
  void acceptWaveform(Float32List samples) => _delegate.acceptWaveform(samples);

  @override
  bool isDetected() => _delegate.isDetected();

  @override
  bool isEmpty() => _delegate.isEmpty();

  @override
  Float32List frontSamples() => _delegate.front().samples;

  @override
  void pop() => _delegate.pop();

  @override
  void reset() => _delegate.reset();

  @override
  void free() => _delegate.free();
}

final class _VadSegmentState {
  bool wasSpeaking = false;
  DateTime? startedAt;

  void reset() {
    wasSpeaking = false;
    startedAt = null;
  }
}

/// Wrap of sherpa-onnx Silero VAD.
///
/// Lifecycle:
///   * [ensureReady] downloads the ~2 MB `silero_vad.onnx` and builds separate
///     [sherpa.VoiceActivityDetector] instances for ordinary and playback-time
///     audio.
///   * [start] subscribes to [MicCaptureService.recognitionStream], feeds
///     samples to the detector, and fires [UserSpeakingStartedEvent] /
///     [UserSpeakingEndedEvent] on EventBus as ordinary segments come in/out.
///     An explicitly enabled session can also subscribe to the isolated
///     playback stream and emit [PlaybackSpeechCandidateStartedEvent] /
///     [PlaybackSpeechCandidateEndedEvent] instead.
///   * [stop] cancels the subscription but keeps the detector alive (cheap
///     to re-attach on the next [start]).
///
/// Currently only used inside the chat voice-input flow.  A future P3
/// always-on mode will run continuously and gate by VAD signals — same
/// service, just a different "when to start" policy.
class VadService extends AppService {
  VadService();

  /// Test seam for driving both stream states without loading a native model.
  VadService.withDetectorsForTesting({
    required VadAudioDetector userDetector,
    required VadAudioDetector playbackCandidateDetector,
  }) : _userDetector = userDetector,
       _playbackCandidateDetector = playbackCandidateDetector {
    if (identical(userDetector, playbackCandidateDetector)) {
      throw ArgumentError('VAD streams require independent detector state.');
    }
    isReady.value = true;
  }

  VadAudioDetector? _userDetector;
  VadAudioDetector? _playbackCandidateDetector;
  StreamSubscription<Uint8List>? _sub;
  StreamSubscription<Uint8List>? _playbackCandidateSub;
  Future<void>? _stopFuture;
  final _userSegmentState = _VadSegmentState();
  final _playbackCandidateSegmentState = _VadSegmentState();

  final RxBool isReady = false.obs;
  // True while the tiny (~2 MB) silero_vad.onnx is downloading/initializing.
  // Lets the settings card show a load state like the local TTS subsystem.
  final RxBool isLoading = false.obs;
  final RxBool isDownloading = false.obs;
  final RxBool isRunning = false.obs;
  final RxBool userIsSpeaking = false.obs;
  final RxnString error = RxnString();
  final RxDouble downloadProgress = 0.0.obs;
  final RxInt receivedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;
  final RxnInt etaSeconds = RxnInt();

  SherpaModelDownloadService get _downloads =>
      appServices.find<SherpaModelDownloadService>();

  Future<void> ensureReady() async {
    if (isReady.value || isLoading.value) return;
    isLoading.value = true;
    error.value = null;
    try {
      const model = SherpaModelRegistry.sileroVad;
      final status = _downloads.statusOf(model.id);
      isDownloading.value = status.isLoading.value;
      final workers = <Worker>[
        ever<double>(status.progress, (v) => downloadProgress.value = v),
        ever<int>(status.receivedBytes, (v) => receivedBytes.value = v),
        ever<int>(status.totalBytes, (v) => totalBytes.value = v),
        ever<int?>(status.etaSeconds, (v) => etaSeconds.value = v),
        ever<bool>(status.isLoading, (v) => isDownloading.value = v),
      ];
      try {
        final dir = await _downloads.ensure(model);
        final modelPath = p.join(dir.path, 'silero_vad.onnx');
        final userDetector = _createDetector(modelPath);
        VadAudioDetector? playbackCandidateDetector;
        try {
          playbackCandidateDetector = _createDetector(modelPath);
        } catch (_) {
          userDetector.free();
          rethrow;
        }
        _userDetector = userDetector;
        _playbackCandidateDetector = playbackCandidateDetector;
        isReady.value = true;
        Log.i('🔉 [VAD] ready with isolated user/candidate detectors');
      } finally {
        for (final w in workers) {
          w.dispose();
        }
        isDownloading.value = false;
      }
    } catch (e) {
      error.value = e.toString();
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  VadAudioDetector _createDetector(String modelPath) {
    return _SherpaVadAudioDetector(
      sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: modelPath,
            // Defaults are tuned for conversational speech. Lowered
            // threshold so soft Mandarin tones still register; min speech
            // duration kept generous to suppress accidental clicks.
            threshold: 0.42,
            minSpeechDuration: 0.25,
            minSilenceDuration: 0.5,
          ),
          sampleRate: MicCaptureService.sampleRate,
        ),
        bufferSizeInSeconds: 30,
      ),
    );
  }

  /// Begin feeding mic audio into the VAD.  Caller is responsible for
  /// starting [MicCaptureService] separately — VAD doesn't open the mic on
  /// its own so it can share the same capture session with native ASR UX.
  Future<void> start() async {
    await startWithOptions();
  }

  /// Starts ordinary VAD and optionally admits the isolated playback candidate
  /// stream. The microphone remains the authority on whether that stream is
  /// actually active for this recorder session.
  Future<void> startWithOptions({
    bool includePlaybackCandidates = false,
  }) async {
    if (isRunning.value) return;
    if (!isReady.value) await ensureReady();
    if (!appServices.isRegistered<MicCaptureService>()) return;
    final mic = appServices.find<MicCaptureService>();
    // Read the gated stream: while our agent is speaking we must not let its
    // own voice drive endpoint detection (or fire UserSpeaking* on the bus).
    _sub = mic.recognitionStream.listen(
      (bytes) => _onChunk(bytes, beganDuringPlayback: false),
    );
    if (includePlaybackCandidates) {
      _playbackCandidateSub = mic.playbackCandidateStream.listen(
        (bytes) => _onChunk(bytes, beganDuringPlayback: true),
      );
    }
    isRunning.value = true;
    Log.i('🔉 [VAD] started');
  }

  Future<void> stop() {
    if (!isRunning.value && _sub == null && _playbackCandidateSub == null) {
      return Future<void>.value();
    }
    final current = _stopFuture;
    if (current != null) return current;
    late final Future<void> stopping;
    stopping = _stopOnce().whenComplete(() {
      if (identical(_stopFuture, stopping)) _stopFuture = null;
    });
    _stopFuture = stopping;
    return stopping;
  }

  Future<void> _stopOnce() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final subscription = _sub;
    if (subscription != null) {
      try {
        await subscription.cancel();
        if (identical(_sub, subscription)) _sub = null;
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }
    final playbackCandidateSubscription = _playbackCandidateSub;
    if (playbackCandidateSubscription != null) {
      try {
        await playbackCandidateSubscription.cancel();
        if (identical(_playbackCandidateSub, playbackCandidateSubscription)) {
          _playbackCandidateSub = null;
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
    _resetStreamStates();
    isRunning.value = false;
    Log.i('🔉 [VAD] stopped');
  }

  void _resetStreamStates() {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final detector in <VadAudioDetector?>[
      _userDetector,
      _playbackCandidateDetector,
    ]) {
      if (detector == null) continue;
      try {
        detector.reset();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _userSegmentState.reset();
    _playbackCandidateSegmentState.reset();
    userIsSpeaking.value = false;
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void _onChunk(Uint8List bytes, {required bool beganDuringPlayback}) {
    final detector = beganDuringPlayback
        ? _playbackCandidateDetector
        : _userDetector;
    if (detector == null) return;
    final segmentState = beganDuringPlayback
        ? _playbackCandidateSegmentState
        : _userSegmentState;
    final samples = pcm16BytesToFloat32(bytes);
    detector.acceptWaveform(samples);

    final speakingNow = detector.isDetected();
    if (speakingNow && !segmentState.wasSpeaking) {
      segmentState.wasSpeaking = true;
      segmentState.startedAt = DateTime.now();
      if (beganDuringPlayback) {
        EventBus().fire(PlaybackSpeechCandidateStartedEvent());
        Log.i('🗣️ [VAD] playback speech candidate started');
      } else {
        userIsSpeaking.value = true;
        EventBus().fire(UserSpeakingStartedEvent());
        Log.i('🗣️ [VAD] user started speaking');
      }
    } else if (!speakingNow && segmentState.wasSpeaking) {
      segmentState.wasSpeaking = false;
      if (!beganDuringPlayback) {
        userIsSpeaking.value = false;
      }
      // Drain any complete segments that the detector has buffered.
      var drained = 0;
      while (!detector.isEmpty()) {
        final segmentSamples = detector.frontSamples();
        drained++;
        final duration = segmentState.startedAt != null
            ? DateTime.now().difference(segmentState.startedAt!)
            : Duration.zero;
        Log.i(
          '🗣️ [VAD] segment#$drained wallMs=${duration.inMilliseconds} '
          '${_sampleStats(segmentSamples)}',
        );
        if (beganDuringPlayback) {
          EventBus().fire(
            PlaybackSpeechCandidateEndedEvent(
              duration: duration,
              samples: segmentSamples,
            ),
          );
        } else {
          EventBus().fire(
            UserSpeakingEndedEvent(duration: duration, samples: segmentSamples),
          );
        }
        detector.pop();
      }
      final source = beganDuringPlayback ? 'candidate' : 'user';
      segmentState.startedAt = null;
      Log.i('🗣️ [VAD] $source stopped speaking drained=$drained');
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _playbackCandidateSub?.cancel();
    _playbackCandidateSub = null;
    final userDetector = _userDetector;
    final playbackCandidateDetector = _playbackCandidateDetector;
    userDetector?.free();
    if (!identical(userDetector, playbackCandidateDetector)) {
      playbackCandidateDetector?.free();
    }
    _userDetector = null;
    _playbackCandidateDetector = null;
    isReady.value = false;
    isRunning.value = false;
    _userSegmentState.reset();
    _playbackCandidateSegmentState.reset();
    userIsSpeaking.value = false;
  }

  static Float32List pcm16BytesToFloat32(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  static String _sampleStats(Float32List samples) {
    if (samples.isEmpty) {
      return 'samples=0 durationMs=0 rms=0.0000 peak=0.0000';
    }
    double sumSq = 0;
    double peak = 0;
    for (final sample in samples) {
      sumSq += sample * sample;
      final abs = sample.abs();
      if (abs > peak) peak = abs;
    }
    final durationMs = (samples.length * 1000 / MicCaptureService.sampleRate)
        .round();
    final rms = math.sqrt(sumSq / samples.length);
    return 'samples=${samples.length} durationMs=$durationMs '
        'rms=${rms.toStringAsFixed(4)} peak=${peak.toStringAsFixed(4)}';
  }
}
