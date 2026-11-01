import 'dart:typed_data';

import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/sherpa_neural_tts.dart';

class SherpaTtsEngine implements TTSEngine {
  SherpaTtsEngine();

  SherpaNeuralTts get _tts => appServices.find<SherpaNeuralTts>();

  @override
  bool get isReady => _tts.isReady.value;

  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) async {
    Worker? worker;
    if (onProgress != null) {
      worker = ever<double>(_tts.downloadProgress, (v) {
        onProgress(v, phase: 'model');
      });
      onProgress(0, phase: 'starting');
    }
    try {
      await _tts.ensureReady();
      onProgress?.call(1.0, phase: 'ready');
      return _tts.isReady.value;
    } catch (_) {
      return false;
    } finally {
      worker?.dispose();
    }
  }

  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) async {
    final clip = await synthesizeToWavWithEnvelope(
      text,
      language: language,
      voice: voice,
    );
    return clip.wav;
  }

  /// [speed] lets the caller adjust delivery pace (Supertonic accepts roughly
  /// 0.7–2.0).  The TTS bridge uses it to push the agent's current emotion
  /// into the voice — excited speech runs faster, sad/sleepy slower.
  Future<SherpaTtsClip> synthesizeToWavWithEnvelope(
    String text, {
    String? language,
    String? voice,
    double? speed,
  }) {
    // Synthesis and envelope generation both run in SherpaNeuralTts' worker
    // isolate. The bridge plugin only schedules playback on the UI isolate.
    return _tts.synthesizeToWavWithEnvelope(text, lang: language, speed: speed);
  }
}
