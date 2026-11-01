import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maaso/src/core/services/voice_prosody_service.dart';

/// Lightweight, model-free analyzer used only by the desktop prosody shadow.
///
/// The estimates are deliberately coarse and must never be interpreted as a
/// medical, emotional, or personality label. The analyzer retains no samples
/// and performs one linear pass over the VAD-ended segment.
final class LocalDspVoiceProsodyAnalyzer implements VoiceProsodyAnalyzer {
  bool _closed = false;

  @override
  VoiceProsodyBackend get backend => VoiceProsodyBackend.localDsp;

  @override
  Future<VoiceProsodyAnalysis> analyze(
    Float32List samples, {
    required int sampleRate,
  }) async {
    if (_closed) throw StateError('voice_prosody_analyzer_closed');
    if (sampleRate < 8000 || sampleRate > 192000) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'is invalid');
    }
    if (samples.isEmpty) {
      return const VoiceProsodyAnalysis(
        energy: 0,
        pitchHz: 0,
        speakingRate: 0,
        pauseRatio: 1,
        audioEventConfidence: 0,
      );
    }

    var sumSquares = 0.0;
    var zeroCrossings = 0;
    var previousSign = 0;
    for (var index = 0; index < samples.length; index++) {
      final sample = _finiteSample(samples[index]);
      sumSquares += sample * sample;
      if (sample.abs() >= _zeroCrossingFloor) {
        final sign = sample >= 0 ? 1 : -1;
        if (previousSign != 0 && sign != previousSign) zeroCrossings++;
        previousSign = sign;
      }
    }

    final rms = math.sqrt(sumSquares / samples.length).clamp(0.0, 1.0);
    final windowSamples = math.max(1, sampleRate ~/ 50); // 20 ms.
    final activeFloor = math.max(_absolutePauseFloor, rms * 0.22);
    var windowCount = 0;
    var pausedWindows = 0;
    var activeOnsets = 0;
    var wasActive = false;
    for (var start = 0; start < samples.length; start += windowSamples) {
      final end = math.min(samples.length, start + windowSamples);
      var windowSquares = 0.0;
      for (var index = start; index < end; index++) {
        final sample = _finiteSample(samples[index]);
        windowSquares += sample * sample;
      }
      final windowRms = math.sqrt(windowSquares / math.max(1, end - start));
      final active = windowRms >= activeFloor;
      if (!active) pausedWindows++;
      if (active && !wasActive) activeOnsets++;
      wasActive = active;
      windowCount++;
    }

    final durationSeconds = samples.length / sampleRate;
    final pauseRatio = windowCount == 0 ? 1.0 : pausedWindows / windowCount;
    final voicedDurationSeconds = durationSeconds * (1 - pauseRatio);
    final zeroCrossingPitch = voicedDurationSeconds <= 0
        ? 0.0
        : zeroCrossings / (voicedDurationSeconds * 2);
    final pitchHz = zeroCrossingPitch >= 45 && zeroCrossingPitch <= 650
        ? zeroCrossingPitch
        : 0.0;
    final speakingRate = durationSeconds <= 0
        ? 0.0
        : (activeOnsets / durationSeconds * 2.4).clamp(0.0, 12.0);
    final voicedFraction = (1 - pauseRatio).clamp(0.0, 1.0);
    final energyConfidence = (rms / 0.12).clamp(0.0, 1.0);

    return VoiceProsodyAnalysis(
      energy: rms,
      pitchHz: pitchHz,
      speakingRate: speakingRate,
      pauseRatio: pauseRatio,
      audioEventConfidence: (voicedFraction * energyConfidence).clamp(0.0, 1.0),
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  static const double _absolutePauseFloor = 0.008;
  static const double _zeroCrossingFloor = 0.002;

  static double _finiteSample(double value) {
    if (!value.isFinite) return 0;
    return value.clamp(-1.0, 1.0).toDouble();
  }
}
