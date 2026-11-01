import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

class UserSpeakingStartedEvent extends ClawEvent {}

class UserSpeakingEndedEvent extends ClawEvent {
  UserSpeakingEndedEvent({
    required this.duration,
    required this.samples,
    this.beganDuringPlayback = false,
  });

  final Duration duration;
  final Float32List samples;
  final bool beganDuringPlayback;
}

class PlaybackSpeechCandidateStartedEvent extends ClawEvent {
  @override
  bool get verboseLog => false;
}

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

abstract interface class VadAudioDetector {
  void acceptWaveform(Float32List samples);

  bool isDetected();

  bool isEmpty();

  Float32List frontSamples();

  void pop();

  void reset();

  void free();
}

class VadService extends AppService {
  VadService();

  VadService.withDetectorsForTesting({
    required VadAudioDetector userDetector,
    required VadAudioDetector playbackCandidateDetector,
  }) {
    if (identical(userDetector, playbackCandidateDetector)) {
      throw ArgumentError('VAD streams require independent detector state.');
    }
  }

  static const _unsupportedMessage =
      'Local Sherpa voice activity detection is unavailable in the browser.';

  final RxBool isReady = false.obs;
  final RxBool isLoading = false.obs;
  final RxBool isDownloading = false.obs;
  final RxBool isRunning = false.obs;
  final RxBool userIsSpeaking = false.obs;
  final RxnString error = RxnString(_unsupportedMessage);
  final RxDouble downloadProgress = 0.0.obs;
  final RxInt receivedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;
  final RxnInt etaSeconds = RxnInt();

  Future<void> ensureReady() async {
    error.value = _unsupportedMessage;
  }

  Future<void> start() async {
    await startWithOptions();
  }

  Future<void> startWithOptions({
    bool includePlaybackCandidates = false,
  }) async {
    error.value = _unsupportedMessage;
    isRunning.value = false;
  }

  Future<void> stop() async {
    isRunning.value = false;
    userIsSpeaking.value = false;
  }

  void dispose() {
    isReady.value = false;
    isRunning.value = false;
    userIsSpeaking.value = false;
  }

  static Float32List pcm16BytesToFloat32(Uint8List bytes) {
    final output = Float32List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var index = 0; index < output.length; index++) {
      output[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
    }
    return output;
  }

  static String sampleStatsForTesting(Float32List samples) {
    if (samples.isEmpty) {
      return 'samples=0 durationMs=0 rms=0.0000 peak=0.0000';
    }
    var sumSquares = 0.0;
    var peak = 0.0;
    for (final sample in samples) {
      sumSquares += sample * sample;
      peak = math.max(peak, sample.abs());
    }
    final durationMs = (samples.length * 1000 / MicCaptureService.sampleRate)
        .round();
    final rms = math.sqrt(sumSquares / samples.length);
    return 'samples=${samples.length} durationMs=$durationMs '
        'rms=${rms.toStringAsFixed(4)} peak=${peak.toStringAsFixed(4)}';
  }
}
