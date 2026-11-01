// Native Sherpa implementation. Exported through tts_lip_sync_driver.dart.
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
import 'package:maaso/src/core/services/vad_service.dart';

class TtsLipSyncDriver extends AppService {
  sherpa.VoiceActivityDetector? _lipVad;
  String? _vadModelPath;
  Timer? _lipTimer;
  double _smoothed = 0;
  StreamSubscription<Uint8List>? _micSub;
  Future<void>? _loadFuture;

  final RxBool isReady = false.obs;

  static const _frameRate = 30;
  static const _frameMs = 33;
  static const _attackCoeff = 0.5;
  static const _releaseCoeff = 0.15;
  static const _tailFadeFrames = 3;

  SherpaModelDownloadService get _downloads =>
      appServices.find<SherpaModelDownloadService>();

  Future<TtsLipSyncDriver> init() async {
    await ensureReady();
    return this;
  }

  Future<void> ensureReady() {
    if (isReady.value) return Future.value();
    return _loadFuture ??= _loadVadModel();
  }

  Future<void> _loadVadModel() async {
    try {
      sherpa.initBindings();
      const model = SherpaModelRegistry.sileroVad;
      final dir = await _downloads.ensure(model);
      _vadModelPath = p.join(dir.path, 'silero_vad.onnx');
      isReady.value = true;
      Log.i('👄 [LipSync] VAD driver ready');
    } catch (e) {
      Log.w('👄 [LipSync] VAD model not available, will use RMS fallback: $e');
    } finally {
      _loadFuture = null;
    }
  }

  Future<void> driveFromSamples(
    Float32List samples,
    int sampleRate, {
    String? agentId,
  }) async {
    stop();

    final envelope = _computeVadEnvelope(samples, sampleRate);
    if (envelope.isEmpty) return;

    final start = DateTime.now();
    _lipTimer = Timer.periodic(const Duration(milliseconds: _frameMs), (t) {
      final elapsedMs = DateTime.now().difference(start).inMilliseconds;
      final idx = (elapsedMs / _frameMs).floor();
      if (idx >= envelope.length) {
        t.cancel();
        EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
        return;
      }
      EventBus().fire(LipSyncAmplitudeEvent(envelope[idx], agentId: agentId));
    });
  }

  Future<void> driveFromWavBytes(Uint8List wavBytes, {String? agentId}) async {
    stop();

    final parsed = _parseWavToFloat32(wavBytes);
    if (parsed == null) {
      final envelope = _computeRmsEnvelopeFromWav(wavBytes);
      _startEnvelopePlayback(envelope, agentId: agentId);
      return;
    }

    final envelope = _computeVadEnvelope(parsed.samples, parsed.sampleRate);
    _startEnvelopePlayback(envelope, agentId: agentId);
  }

  Future<void> driveFromSystemTts(String text, {String? agentId}) async {
    stop();

    if (_vadModelPath == null ||
        !appServices.isRegistered<MicCaptureService>()) {
      // Keep the first system-TTS path instant: use sine fallback now and let
      // the VAD model prepare in the background for later utterances.
      // ignore: unawaited_futures
      ensureReady();
      _driveSineFallback(text, agentId: agentId);
      return;
    }

    final mic = appServices.find<MicCaptureService>();
    if (!mic.isRecording.value) {
      final ok = await mic.start();
      if (!ok) {
        _driveSineFallback(text, agentId: agentId);
        return;
      }
    }

    _lipVad ??= sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: _vadModelPath!,
          threshold: 0.35,
          minSpeechDuration: 0.08,
          minSilenceDuration: 0.15,
        ),
        sampleRate: MicCaptureService.sampleRate,
      ),
      bufferSizeInSeconds: 10,
    );

    final estDurationMs = math.max(800, (text.length * 180));
    final start = DateTime.now();
    _smoothed = 0;

    _micSub = mic.audioStream.listen((bytes) {
      _lipVad?.acceptWaveform(VadService.pcm16BytesToFloat32(bytes));
    });

    _lipTimer = Timer.periodic(const Duration(milliseconds: _frameMs), (t) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      if (elapsed > estDurationMs + 1000) {
        t.cancel();
        _micSub?.cancel();
        _micSub = null;
        _smoothed = 0;
        EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
        return;
      }

      final isSpeech = _lipVad?.isDetected() ?? false;
      final target = isSpeech ? 0.7 : 0.0;
      final coeff = target > _smoothed ? _attackCoeff : _releaseCoeff;
      _smoothed = _smoothed + coeff * (target - _smoothed);

      EventBus().fire(LipSyncAmplitudeEvent(_smoothed, agentId: agentId));
    });
  }

  void stop({String? agentId}) {
    _lipTimer?.cancel();
    _lipTimer = null;
    _micSub?.cancel();
    _micSub = null;
    _smoothed = 0;
    EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
  }

  @override
  void onClose() {
    stop();
    _lipVad?.free();
    _lipVad = null;
    super.onClose();
  }

  void _startEnvelopePlayback(List<double> envelope, {String? agentId}) {
    if (envelope.isEmpty) return;
    final start = DateTime.now();
    _lipTimer = Timer.periodic(const Duration(milliseconds: _frameMs), (t) {
      final elapsedMs = DateTime.now().difference(start).inMilliseconds;
      final idx = (elapsedMs / _frameMs).floor();
      if (idx >= envelope.length) {
        t.cancel();
        EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
        return;
      }
      EventBus().fire(LipSyncAmplitudeEvent(envelope[idx], agentId: agentId));
    });
  }

  List<double> _computeVadEnvelope(Float32List samples, int sampleRate) {
    final vad = _createLipVad(sampleRate);
    if (vad == null) return _computeRmsEnvelope(samples, sampleRate);

    final samplesPerFrame = (sampleRate / _frameRate).round();
    final raw = <double>[];

    for (int i = 0; i < samples.length; i += samplesPerFrame) {
      final end = math.min(i + samplesPerFrame, samples.length);
      final frame = Float32List.sublistView(samples, i, end);

      vad.acceptWaveform(frame);
      final isSpeech = vad.isDetected();

      double rms = 0;
      for (int j = 0; j < frame.length; j++) {
        rms += frame[j] * frame[j];
      }
      rms = math.sqrt(rms / frame.length);

      final value = isSpeech
          ? (rms * 5.0).clamp(0.15, 1.0)
          : (rms * 2.0).clamp(0.0, 0.08);
      raw.add(value);
    }

    vad.free();
    return _smoothEnvelope(raw);
  }

  /// Sample rate the bundled Silero VAD model was trained at.  Feeding it
  /// anything else makes sherpa-onnx's native layer assert
  /// ("Expected sample rate 16000. Given: …") and hard-crash the process —
  /// so any other rate must fall back to the RMS envelope instead.
  static const int _sileroVadSampleRate = 16000;

  sherpa.VoiceActivityDetector? _createLipVad(int sampleRate) {
    if (_vadModelPath == null) return null;
    // Silero VAD only accepts 16 kHz.  TTS audio (e.g. Supertonic's 44.1 kHz
    // vocoder output) would otherwise crash the native engine — fall back to
    // the pure-RMS envelope, which is plenty for mouth-open animation.
    if (sampleRate != _sileroVadSampleRate) {
      Log.i(
        '👄 [LipSync] sampleRate=$sampleRate ≠ ${_sileroVadSampleRate}Hz, '
        'using RMS envelope (Silero VAD unsupported at this rate)',
      );
      return null;
    }
    try {
      return sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: _vadModelPath!,
            threshold: 0.30,
            minSpeechDuration: 0.05,
            minSilenceDuration: 0.10,
          ),
          sampleRate: sampleRate,
        ),
        bufferSizeInSeconds: 10,
      );
    } catch (e) {
      Log.w('👄 [LipSync] failed to create lip VAD: $e');
      return null;
    }
  }

  List<double> _computeRmsEnvelope(Float32List samples, int sampleRate) {
    final samplesPerFrame = (sampleRate / _frameRate).round();
    final raw = <double>[];

    for (int i = 0; i < samples.length; i += samplesPerFrame) {
      double sumSq = 0;
      int n = 0;
      for (int j = i; j < i + samplesPerFrame && j < samples.length; j++, n++) {
        sumSq += samples[j] * samples[j];
      }
      if (n == 0) break;
      final rms = math.sqrt(sumSq / n);
      raw.add((rms * 5.0).clamp(0.0, 1.0));
    }

    return _smoothEnvelope(raw);
  }

  List<double> _computeRmsEnvelopeFromWav(Uint8List bytes) {
    if (bytes.length < 44) return const [];
    final bd = ByteData.sublistView(bytes);
    if (bytes[0] != 0x52 || bytes[1] != 0x49) return const [];
    final sampleRate = bd.getUint32(24, Endian.little);
    final bitsPerSample = bd.getUint16(34, Endian.little);
    if (sampleRate == 0 || bitsPerSample != 16) return const [];

    int dataStart = 36;
    while (dataStart + 8 < bytes.length) {
      final chunkId = String.fromCharCodes(
        bytes.sublist(dataStart, dataStart + 4),
      );
      final chunkSize = bd.getUint32(dataStart + 4, Endian.little);
      if (chunkId == 'data') {
        dataStart += 8;
        break;
      }
      dataStart += 8 + chunkSize;
    }
    if (dataStart >= bytes.length) return const [];

    final samplesPerFrame = (sampleRate / _frameRate).round();
    final samples = ByteData.sublistView(bytes, dataStart);
    final sampleCount = samples.lengthInBytes ~/ 2;

    final raw = <double>[];
    for (int i = 0; i < sampleCount; i += samplesPerFrame) {
      double sumSq = 0;
      int n = 0;
      for (int j = i; j < i + samplesPerFrame && j < sampleCount; j++, n++) {
        final s = samples.getInt16(j * 2, Endian.little).toDouble();
        sumSq += s * s;
      }
      if (n == 0) break;
      final rms = math.sqrt(sumSq / n);
      raw.add((rms / 8000).clamp(0.0, 1.0));
    }
    return _smoothEnvelope(raw);
  }

  List<double> _smoothEnvelope(List<double> raw) {
    if (raw.isEmpty) return raw;
    final out = List<double>.filled(raw.length, 0);
    out[0] = raw[0];

    for (int i = 1; i < raw.length; i++) {
      final coeff = raw[i] > out[i - 1] ? _attackCoeff : _releaseCoeff;
      out[i] = out[i - 1] + coeff * (raw[i] - out[i - 1]);
    }

    final fadeLen = math.min(_tailFadeFrames, out.length);
    for (int i = 0; i < fadeLen; i++) {
      final idx = out.length - fadeLen + i;
      out[idx] *= (i + 1) / fadeLen;
    }

    return out;
  }

  void _driveSineFallback(String text, {String? agentId}) {
    final estDurationMs = math.max(800, text.length * 180);
    final start = DateTime.now();
    _smoothed = 0;

    _lipTimer = Timer.periodic(const Duration(milliseconds: _frameMs), (t) {
      final elapsedMs = DateTime.now().difference(start).inMilliseconds;
      if (elapsedMs > estDurationMs + 500) {
        t.cancel();
        _smoothed = 0;
        EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
        return;
      }
      final phase = elapsedMs / 1000.0 * 4 * 2 * math.pi;
      final envelope = math
          .min(
            1.0,
            math.min(elapsedMs / 200, (estDurationMs - elapsedMs) / 200),
          )
          .clamp(0.0, 1.0);
      final target = ((math.sin(phase) + 1) / 2 * 0.7) * envelope;
      final coeff = target > _smoothed ? _attackCoeff : _releaseCoeff;
      _smoothed = _smoothed + coeff * (target - _smoothed);
      EventBus().fire(LipSyncAmplitudeEvent(_smoothed, agentId: agentId));
    });
  }

  ({Float32List samples, int sampleRate})? _parseWavToFloat32(Uint8List bytes) {
    if (bytes.length < 44) return null;
    final bd = ByteData.sublistView(bytes);
    if (bytes[0] != 0x52 || bytes[1] != 0x49) return null;
    final sampleRate = bd.getUint32(24, Endian.little);
    final bitsPerSample = bd.getUint16(34, Endian.little);
    if (sampleRate == 0 || bitsPerSample != 16) return null;

    int dataStart = 36;
    while (dataStart + 8 < bytes.length) {
      final chunkId = String.fromCharCodes(
        bytes.sublist(dataStart, dataStart + 4),
      );
      final chunkSize = bd.getUint32(dataStart + 4, Endian.little);
      if (chunkId == 'data') {
        dataStart += 8;
        break;
      }
      dataStart += 8 + chunkSize;
    }
    if (dataStart >= bytes.length) return null;

    final sampleCount = (bytes.length - dataStart) ~/ 2;
    final samples = Float32List(sampleCount);
    for (int i = 0; i < sampleCount; i++) {
      samples[i] = bd.getInt16(dataStart + i * 2, Endian.little) / 32768.0;
    }
    return (samples: samples, sampleRate: sampleRate);
  }
}
