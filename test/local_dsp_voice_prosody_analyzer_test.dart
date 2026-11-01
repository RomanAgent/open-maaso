import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/local_dsp_voice_prosody_analyzer.dart';

void main() {
  test('silence produces bounded neutral estimates', () async {
    final analyzer = LocalDspVoiceProsodyAnalyzer();
    addTearDown(analyzer.close);

    final result = await analyzer.analyze(
      Float32List(16000),
      sampleRate: 16000,
    );

    expect(result.energy, 0);
    expect(result.pitchHz, 0);
    expect(result.speakingRate, 0);
    expect(result.pauseRatio, 1);
    expect(result.audioEventConfidence, 0);
  });

  test('voiced segment derives finite hints without retaining PCM', () async {
    final analyzer = LocalDspVoiceProsodyAnalyzer();
    addTearDown(analyzer.close);
    final samples = _toneWithPause(sampleRate: 16000, frequencyHz: 200);

    final result = await analyzer.analyze(samples, sampleRate: 16000);
    samples.fillRange(0, samples.length, double.nan);

    expect(result.energy, inInclusiveRange(0, 1));
    expect(result.pitchHz, closeTo(200, 8));
    expect(result.speakingRate, inInclusiveRange(0, 12));
    expect(result.pauseRatio, inInclusiveRange(0.2, 0.8));
    expect(result.audioEventConfidence, inInclusiveRange(0, 1));
  });

  test('non-finite samples are sanitized and close fences reuse', () async {
    final analyzer = LocalDspVoiceProsodyAnalyzer();
    final result = await analyzer.analyze(
      Float32List.fromList(<double>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
        2,
        -2,
      ]),
      sampleRate: 16000,
    );

    expect(result.energy.isFinite, isTrue);
    expect(result.pitchHz.isFinite, isTrue);
    await analyzer.close();
    expect(
      () => analyzer.analyze(Float32List(1), sampleRate: 16000),
      throwsStateError,
    );
  });
}

Float32List _toneWithPause({
  required int sampleRate,
  required double frequencyHz,
}) {
  final samples = Float32List(sampleRate * 2);
  for (var index = 0; index < samples.length; index++) {
    final second = index / sampleRate;
    final voiced = second < 0.5 || (second >= 1 && second < 1.5);
    samples[index] = voiced
        ? 0.25 * math.sin(2 * math.pi * frequencyHz * second)
        : 0;
  }
  return samples;
}
