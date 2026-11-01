import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/streaming_pcm_playback_reference_service.dart';
import 'package:record/record.dart';

typedef PlaybackCandidateCaptureAuthorization = bool Function();
typedef StreamingPcmReferenceServiceProvider =
    StreamingPcmPlaybackReferenceService? Function();

/// Exact, short-lived ownership of playback-candidate microphone routing.
///
/// A candidate acquires this while TTS is still playing, before pausing the
/// captured utterance. The hold keeps subsequent speech tail and endpointing
/// silence on [MicCaptureService.playbackCandidateStream] after the normal
/// playback gate falls. Releasing an older hold can never release a newer one.
final class PlaybackCandidateCaptureHold {
  const PlaybackCandidateCaptureHold._({
    required MicCaptureService owner,
    required int lifecycleGeneration,
    required int identity,
  }) : _owner = owner,
       _lifecycleGeneration = lifecycleGeneration,
       _identity = identity;

  final MicCaptureService _owner;
  final int _lifecycleGeneration;
  final int _identity;

  bool get isActive => _owner._isPlaybackCandidateCaptureHoldCurrent(this);

  /// Releases this exact hold. Returns false once it is stale or was cleared.
  bool release() => _owner._releasePlaybackCandidateCaptureHold(this);
}

/// Streams 16-bit PCM frames from the mic at 16 kHz mono.
///
/// One service, one active stream — calling [start] while already running
/// is a no-op.  Consumers all read from broadcast streams, so we only pay the
/// mic-open cost once.
///
/// ## Two streams, on purpose
///
/// While our own agent is talking (TTS over the speaker) the mic hears that
/// playback back as echo.  Two kinds of consumer want opposite things during
/// that window:
///
///   * **Recognition** (chat VAD, native speech-recognition endpointing, and the
///     voice-print waveform) must NOT hear the agent — otherwise we can capture
///     our own voice and the waveform saturates on speaker echo. They read
///     [recognitionStream] / [amplitude], which are muted while
///     [playbackActive] is set or an exact interruption hold is active.
///   * **System-TTS lip-sync** ([TtsLipSyncDriver]) deliberately listens to
///     that echo to animate the avatar's mouth when there's no neural audio
///     buffer to analyse.  It reads the raw [audioStream], which is never
///     gated.
///
/// Ordinary sessions therefore gate at the recognition layer without enabling
/// hardware echo cancellation. A separately authorized interruption-candidate
/// session may request AEC; that opt-in can reduce the playback echo available
/// to system-TTS lip-sync and must be validated per platform before production
/// wiring enables it.
///
/// Permission handling: relies on the `record` package's built-in prompt.
/// Caller must ensure the platform manifests include the relevant entries
/// (NSMicrophoneUsageDescription on iOS, android.permission.RECORD_AUDIO
/// on Android).
class MicCaptureService extends AppService {
  MicCaptureService({
    @visibleForTesting AudioRecorder? recorder,
    PlaybackCandidateCaptureAuthorization? playbackCandidateCaptureAuthorized,
    StreamingPcmReferenceServiceProvider? streamingPcmReferenceService,
    @visibleForTesting
    Duration playbackCandidateHoldTimeout =
        defaultPlaybackCandidateCaptureHoldTimeout,
  }) : _recorder = recorder,
       _playbackCandidateCaptureAuthorized =
           playbackCandidateCaptureAuthorized ?? _denyPlaybackCandidates,
       _streamingPcmReferenceService =
           streamingPcmReferenceService ?? _findStreamingPcmReferenceService,
       _playbackCandidateHoldTimeout = playbackCandidateHoldTimeout {
    if (playbackCandidateHoldTimeout <= Duration.zero) {
      throw ArgumentError.value(
        playbackCandidateHoldTimeout,
        'playbackCandidateHoldTimeout',
      );
    }
  }

  static const int sampleRate = 16000;
  static const int _bytesPerSample = 2; // PCM16
  static const Duration defaultPlaybackCandidateCaptureHoldTimeout = Duration(
    seconds: 12,
  );

  /// How long after the agent stops speaking we keep the recognition path
  /// muted, to swallow the speaker's decay tail / room reverb before listening
  /// for the user again.  350 ms (the old per-widget grace) was too short with
  /// the speaker on; ~1 s is comfortable without feeling laggy.
  static const Duration _playbackTailGrace = Duration(milliseconds: 1000);

  AudioRecorder? _recorder;
  final PlaybackCandidateCaptureAuthorization
  _playbackCandidateCaptureAuthorized;
  final StreamingPcmReferenceServiceProvider _streamingPcmReferenceService;
  final Duration _playbackCandidateHoldTimeout;
  bool _playbackCandidateCaptureActive = false;
  PlaybackCandidateCaptureHold? _playbackCandidateCaptureHold;
  Timer? _playbackCandidateHoldTimer;
  int _playbackCandidateHoldIdentity = 0;
  AudioRecorder get _activeRecorder => _recorder ??= AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  Future<bool>? _startFuture;
  Future<void>? _stopFuture;
  int _lifecycleGeneration = 0;
  bool _stopping = false;
  bool _recorderMayBeActive = false;

  /// Raw, ungated mic frames.  Used by system-TTS lip-sync, which needs to
  /// hear playback echo.  Do NOT feed VAD from this — use [recognitionStream].
  final _controller = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioStream => _controller.stream;

  /// Mic frames with our own TTS playback windows removed.  Voice-input
  /// consumers read this so the agent never hears itself.
  final _recognitionController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get recognitionStream => _recognitionController.stream;

  /// A separate, default-closed stream for acoustic interruption candidates.
  ///
  /// It emits while our own playback is active or an exact candidate hold is
  /// preserving the user's endpointing tail, and only when the current recorder
  /// session was explicitly requested *and* admitted by the injected
  /// authorization callback. [recognitionStream] stays mutually exclusive with
  /// this path, so the same PCM cannot enter both recognizers.
  final _playbackCandidateController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get playbackCandidateStream =>
      _playbackCandidateController.stream;

  bool get playbackCandidateCaptureActive => _playbackCandidateCaptureActive;
  bool get playbackCandidateCaptureHeld =>
      _playbackCandidateCaptureHold != null;

  @visibleForTesting
  int get debugSuppressedStreamingEchoChunks => _suppressedStreamingEchoChunks;

  /// True while our agent's TTS is playing (plus a short decay grace).  Driven
  /// by [SpeakingStatusEvent] on the global bus — set up once for the service
  /// lifetime so it can never miss the leading edge the way a late per-widget
  /// subscription could (the old self-echo race).  While set, [recognitionStream]
  /// is silent and [amplitude] is pinned to 0. An exact candidate hold may keep
  /// that routing in place after this reactive playback flag falls.
  final RxBool playbackActive = false.obs;

  /// Live amplitude (RMS / 32768) — drives the voice-print waveform.  Updated
  /// at roughly the chunk rate of the underlying recorder (~10–20 Hz). Pinned
  /// to 0 while playback or an exact candidate hold owns the input route.
  final RxDouble amplitude = 0.0.obs;

  /// True between [start] and [stop].
  final RxBool isRecording = false.obs;

  /// Last error message (permission denied, no mic, etc.).
  final RxnString error = RxnString();

  StreamSubscription? _speakingSub;
  Timer? _playbackGraceTimer;
  int _logTick = 0;
  int _gatedChunkTick = 0;
  int _suppressedStreamingEchoChunks = 0;

  @override
  void onInit() {
    super.onInit();
    // Long-lived: subscribes before any TTS fires, so [playbackActive] is
    // always correct even if the user enters voice mode mid-utterance.
    _speakingSub = EventBus().on<SpeakingStatusEvent>().listen(
      _onSpeakingStatus,
    );
  }

  void _onSpeakingStatus(SpeakingStatusEvent e) {
    _playbackGraceTimer?.cancel();
    if (e.isSpeaking) {
      if (!playbackActive.value) {
        Log.i('🎤 [Mic] playback gate ON (agent speaking)');
      }
      playbackActive.value = true;
    } else {
      // Hold the gate through the speaker's decay tail before reopening.
      _playbackGraceTimer = Timer(_playbackTailGrace, () {
        playbackActive.value = false;
        Log.i('🎤 [Mic] playback gate OFF (tail grace elapsed)');
      });
    }
  }

  Future<bool> hasPermission() => _activeRecorder.hasPermission();

  /// Begin streaming.  Returns true on success.  Safe to call when already
  /// running (early-returns true).
  Future<bool> start() => startWithOptions();

  /// Starts capture, optionally requesting the isolated playback-candidate
  /// path. The request is fail-closed through
  /// [PlaybackCandidateCaptureAuthorization] and is snapshotted for the whole
  /// recorder session because AEC cannot be enabled safely mid-stream.
  Future<bool> startWithOptions({bool includePlaybackCandidates = false}) {
    if (isRecording.value) return Future<bool>.value(true);
    if (_stopping) return Future<bool>.value(false);
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;
    _clearPlaybackCandidateCaptureHold();
    final generation = _lifecycleGeneration;
    late final Future<bool> starting;
    starting =
        _startOnce(
          generation,
          includePlaybackCandidates: includePlaybackCandidates,
        ).whenComplete(() {
          if (identical(_startFuture, starting)) _startFuture = null;
        });
    _startFuture = starting;
    return starting;
  }

  Future<bool> _startOnce(
    int generation, {
    required bool includePlaybackCandidates,
  }) async {
    error.value = null;
    _playbackCandidateCaptureActive = false;
    try {
      final recorder = _activeRecorder;
      final ok = await recorder.hasPermission();
      if (!_isStartCurrent(generation)) return false;
      if (!ok) {
        error.value = 'microphone permission denied';
        return false;
      }
      final candidateCaptureAuthorized =
          includePlaybackCandidates && _readPlaybackCandidateAuthorization();
      final stream = await recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          // Ordinary recognition retains the hard playback gate. AEC/NS are
          // requested only for an independently authorized candidate stream;
          // auto gain stays off so quiet rooms are not amplified into speech.
          echoCancel: candidateCaptureAuthorized,
          noiseSuppress: candidateCaptureAuthorized,
        ),
      );
      _recorderMayBeActive = true;
      if (!_isStartCurrent(generation)) return false;
      _playbackCandidateCaptureActive = candidateCaptureAuthorized;
      _sub = stream.listen(
        _onChunk,
        onError: (e) {
          Log.e('🎤 [Mic] stream error: $e');
          error.value = e.toString();
        },
        onDone: () {
          Log.i('🎤 [Mic] stream ended');
        },
      );
      isRecording.value = true;
      Log.i(
        '🎤 [Mic] capturing @ $sampleRate Hz '
        'playbackCandidates=$_playbackCandidateCaptureActive',
      );
      return true;
    } catch (e) {
      Log.e('🎤 [Mic] start failed: $e');
      error.value = e.toString();
      if (_recorderMayBeActive && !_stopping) {
        try {
          await _recorder?.stop();
          _recorderMayBeActive = false;
        } catch (cleanupError) {
          _stopping = true;
          isRecording.value = true;
          error.value = cleanupError.toString();
        }
      }
      if (!_recorderMayBeActive) isRecording.value = false;
      if (!_recorderMayBeActive) _playbackCandidateCaptureActive = false;
      return false;
    }
  }

  Future<void> stop() {
    _lifecycleGeneration++;
    _stopping = true;
    _clearPlaybackCandidateCaptureHold();
    final inFlight = _stopFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> stopping;
    stopping = _stopOnce().whenComplete(() {
      if (identical(_stopFuture, stopping)) _stopFuture = null;
    });
    _stopFuture = stopping;
    return stopping;
  }

  Future<void> _stopOnce() async {
    try {
      final starting = _startFuture;
      if (starting != null) await starting;
      final subscription = _sub;
      if (subscription != null) {
        await subscription.cancel();
        if (identical(_sub, subscription)) _sub = null;
      }
      if (isRecording.value || _recorderMayBeActive) {
        await _recorder?.stop();
      }
    } catch (error, stackTrace) {
      Log.w(
        '🎤 [Mic] stop failed; retaining the recorder for retry',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    _recorderMayBeActive = false;
    _playbackCandidateCaptureActive = false;
    isRecording.value = false;
    amplitude.value = 0;
    _stopping = false;
    Log.i('🎤 [Mic] stopped');
  }

  bool _isStartCurrent(int generation) =>
      generation == _lifecycleGeneration && !_stopping;

  /// Test seam: drive the chunk pipeline without opening a real mic so the
  /// playback gate can be exercised in a unit test.
  @visibleForTesting
  void debugIngest(Uint8List bytes) => _onChunk(bytes);

  /// Keeps an authorized interruption candidate isolated after TTS pauses.
  ///
  /// Acquisition is allowed only while an authorized recorder session is
  /// running and the playback gate is currently active. Each call supersedes
  /// the prior hold; callers must retain and release the returned exact token.
  /// A bounded timeout is a final safety net if caller cleanup is lost.
  PlaybackCandidateCaptureHold? holdPlaybackCandidateCapture() {
    if (!_playbackCandidateCaptureActive ||
        !isRecording.value ||
        _stopping ||
        !playbackActive.value) {
      return null;
    }
    _clearPlaybackCandidateCaptureHold();
    final hold = PlaybackCandidateCaptureHold._(
      owner: this,
      lifecycleGeneration: _lifecycleGeneration,
      identity: ++_playbackCandidateHoldIdentity,
    );
    _playbackCandidateCaptureHold = hold;
    _playbackCandidateHoldTimer = Timer(_playbackCandidateHoldTimeout, () {
      if (_releasePlaybackCandidateCaptureHold(hold)) {
        Log.w('🎤 [Mic] playback candidate hold expired');
      }
    });
    return hold;
  }

  void _onChunk(Uint8List bytes) {
    // Raw stream is always live — system-TTS lip-sync reads it to animate the
    // mouth from playback echo, which only exists while we're speaking.
    _controller.add(bytes);

    // While our own TTS is playing, the mic is hearing the agent, not the
    // user: keep the recognition path silent and the waveform flat so we
    // neither transcribe ourselves nor saturate the bars on echo.
    final candidateHeld = _playbackCandidateCaptureHold != null;
    if (playbackActive.value || candidateHeld) {
      amplitude.value = 0;
      if (_playbackCandidateCaptureActive) {
        final referenceService = _readStreamingPcmReferenceService();
        final reference = referenceService?.captureCurrentReference();
        final currentStreamingPlayback = referenceService
            ?.captureCurrentPlayback();
        final candidate = switch ((currentStreamingPlayback, reference)) {
          (final Object _, null) => null,
          (_, final StreamingPcmReferenceReceipt receipt)
              when referenceService != null =>
            referenceService.filterPlaybackCandidate(bytes, receipt),
          _ => bytes,
        };
        if (candidate == null) {
          _suppressedStreamingEchoChunks++;
        } else {
          _playbackCandidateController.add(candidate);
        }
      }
      if (++_gatedChunkTick == 1 || _gatedChunkTick % 30 == 0) {
        Log.d(
          '🎤 [Mic] recognition muted by playback candidate gate '
          'bytes=${bytes.length} gatedChunks=$_gatedChunkTick',
        );
      }
      return;
    }
    _gatedChunkTick = 0;

    // Forward to voice-input consumers (chat VAD / waveform).
    _recognitionController.add(bytes);

    // Compute RMS amplitude for the waveform UI.  We only sample a subset of
    // the int16s to keep this cheap — UI doesn't need full resolution.
    if (bytes.length >= 8) {
      final bd = ByteData.sublistView(bytes);
      final stride = math.max(1, (bytes.length ~/ _bytesPerSample) ~/ 64);
      double sumSq = 0;
      int n = 0;
      for (var i = 0; i < bytes.length - 1; i += stride * _bytesPerSample) {
        final s = bd.getInt16(i, Endian.little).toDouble();
        sumSq += s * s;
        n++;
      }
      if (n > 0) {
        final rms = math.sqrt(sumSq / n);
        amplitude.value = (rms / 32768.0 * 6).clamp(0.0, 1.0);
        // Throttled so we don't flood the log at ~15 Hz; ~every 2 s of audio.
        if (++_logTick % 30 == 0) {
          Log.d(
            '🎤 [Mic] rms=${rms.toStringAsFixed(0)} '
            'amp=${amplitude.value.toStringAsFixed(2)} '
            'playbackActive=${playbackActive.value}',
          );
        }
      }
    }
  }

  @override
  void onClose() {
    _lifecycleGeneration++;
    _clearPlaybackCandidateCaptureHold();
    _speakingSub?.cancel();
    _playbackGraceTimer?.cancel();
    _sub?.cancel();
    _controller.close();
    _recognitionController.close();
    _playbackCandidateController.close();
    _playbackCandidateCaptureActive = false;
    unawaited(_recorder?.dispose());
    _recorder = null;
    super.onClose();
  }

  bool _readPlaybackCandidateAuthorization() {
    try {
      return _playbackCandidateCaptureAuthorized();
    } on Object catch (e) {
      Log.w('🎤 [Mic] playback candidate authorization failed: $e');
      return false;
    }
  }

  bool _isPlaybackCandidateCaptureHoldCurrent(
    PlaybackCandidateCaptureHold hold,
  ) {
    return identical(_playbackCandidateCaptureHold, hold) &&
        hold._lifecycleGeneration == _lifecycleGeneration &&
        hold._identity == _playbackCandidateHoldIdentity;
  }

  bool _releasePlaybackCandidateCaptureHold(PlaybackCandidateCaptureHold hold) {
    if (!_isPlaybackCandidateCaptureHoldCurrent(hold)) return false;
    _clearPlaybackCandidateCaptureHold();
    return true;
  }

  void _clearPlaybackCandidateCaptureHold() {
    _playbackCandidateHoldTimer?.cancel();
    _playbackCandidateHoldTimer = null;
    _playbackCandidateCaptureHold = null;
  }

  static bool _denyPlaybackCandidates() => false;

  StreamingPcmPlaybackReferenceService? _readStreamingPcmReferenceService() {
    try {
      return _streamingPcmReferenceService();
    } on Object {
      return null;
    }
  }

  static StreamingPcmPlaybackReferenceService?
  _findStreamingPcmReferenceService() =>
      appServices.maybeFind<StreamingPcmPlaybackReferenceService>();
}
