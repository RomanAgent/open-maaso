// Native Sherpa implementation. Exported through sherpa_neural_tts.dart.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:maaso/src/core/services/sherpa_model_download_service.dart';
import 'package:maaso/src/core/services/sherpa_model_registry.dart';

/// Selectable on-device neural TTS engine.
///
/// Supertonic 3 is the only bundled/downloadable neural TTS model.
enum TtsEngine {
  supertonic('supertonic');

  const TtsEngine(this.key);

  /// Persisted string key.
  final String key;

  static TtsEngine fromKey(String? key) => TtsEngine.supertonic;

  String get label => switch (this) {
    TtsEngine.supertonic => 'Supertonic 3',
  };

  SherpaModel get model => switch (this) {
    TtsEngine.supertonic => SherpaModelRegistry.supertonicTts,
  };
}

/// Single sherpa-onnx neural-TTS facade.
///
/// Wraps **Supertonic 3** (`sherpa-onnx-supertonic-3-tts-int8-2026-05-11`).
class SherpaTtsResult {
  SherpaTtsResult({required this.samples, required this.sampleRate});

  /// Mono Float32 PCM samples in [-1.0, 1.0], straight from the vocoder.
  final Float32List samples;

  /// Native sample rate of the active model.
  final int sampleRate;

  /// 16-bit PCM WAV byte stream — what the core TTS plugin's playback
  /// path expects (it writes to a temp file and hands it to audioplayers).
  Uint8List toWavBytes() {
    final n = samples.length;
    final dataSize = n * 2;
    final buffer = ByteData(44 + dataSize);
    buffer.setUint32(0, 0x52494646, Endian.big); // 'RIFF'
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    buffer.setUint32(8, 0x57415645, Endian.big); // 'WAVE'
    buffer.setUint32(12, 0x666d7420, Endian.big); // 'fmt '
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, 1, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);
    buffer.setUint32(36, 0x64617461, Endian.big); // 'data'
    buffer.setUint32(40, dataSize, Endian.little);
    var offset = 44;
    for (var i = 0; i < n; i++) {
      var v = samples[i];
      if (v > 1.0) v = 1.0;
      if (v < -1.0) v = -1.0;
      buffer.setInt16(offset, (v * 32767).round(), Endian.little);
      offset += 2;
    }
    return buffer.buffer.asUint8List();
  }
}

class SherpaTtsClip {
  SherpaTtsClip({required this.wav, required this.envelope});

  /// Complete 16-bit PCM WAV bytes ready for audioplayers.
  final Uint8List wav;

  /// Per-frame RMS envelope at 30fps, aligned with [wav] playback.
  final List<double> envelope;
}

class SherpaNeuralTts extends AppService {
  SherpaNeuralTts({AppPlatformCapabilities? platformCapabilities})
    : _platformCapabilities =
          platformCapabilities ?? AppPlatformCapabilities.current();

  static const _unsupportedPlatformMessage =
      'On-device neural TTS is available only on desktop hosts.';

  final AppPlatformCapabilities _platformCapabilities;
  Isolate? _worker;
  ReceivePort? _workerReceivePort;
  StreamSubscription? _workerSubscription;
  SendPort? _workerSendPort;
  Completer<void>? _workerReady;
  Future<void>? _loadFuture;
  int _requestSeq = 0;
  final Map<int, Completer<SherpaTtsClip>> _pendingSynth = {};

  // ───────────────── Reactive surface (drive Settings UI) ─────────────────
  final RxBool isReady = false.obs;
  final RxBool isLoading = false.obs;
  // True ONLY while a real model download/extract is in flight (mirrors the
  // download service's per-model isLoading, which a cache hit never sets).
  // UI gated on this won't flash on cached launches.
  final RxBool isDownloading = false.obs;
  final RxnString error = RxnString();

  /// Mirrors the underlying [SherpaDownloadStatus.progress].
  final RxDouble downloadProgress = 0.0.obs;

  /// Raw byte counters mirrored from the download service.
  final RxInt downloadedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;

  /// Seconds remaining estimate; null until enough data has streamed in.
  final RxnInt etaSeconds = RxnInt();

  /// Active engine. Kept as a reactive value so existing settings/onboarding
  /// code can observe it, but the only supported value is Supertonic 3.
  final Rx<TtsEngine> engine = TtsEngine.supertonic.obs;

  /// Whether the local neural engine is enabled. This is opt-in; a disabled
  /// engine must not download on first speech.
  final RxBool enabled = false.obs;

  static const _kEngineKey = 'tts.engine';
  static const enabledPrefsKey = 'tts.enabled';
  static const _kEnabledKey = enabledPrefsKey;
  static const _kVoiceSidKey = 'tts.voice_sid';

  /// Default speaker id.  The bundled build ships 10 voices: sids 0–4 are
  /// female (F1–F5) and 5–9 are male (M1–M5).  Default to F1 (sid 0) so the
  /// app speaks with a female voice out of the box — see
  /// AgentSettingsController.voiceOptions for the full mapping.
  static const int _defaultSid = 0;

  /// Currently selected speaker id (the chosen "音色").  Settings writes this
  /// via [setVoiceSid]; every synthesis with no explicit sid uses it.  Loaded
  /// at boot in [init] so the choice survives without opening Settings.
  final RxInt voiceSid = _defaultSid.obs;

  /// Flow-matching denoise steps for the vector estimator (synthesis latency
  /// scales ~linearly with this).  6 balances prosody/clarity against the
  /// whole-reply single-shot synthesis the TTS bridge now does.
  static const int _numSteps = 6;

  SherpaModelDownloadService get _downloads =>
      appServices.find<SherpaModelDownloadService>();

  Future<SherpaNeuralTts> init() async {
    final prefs = await SharedPreferences.getInstance();
    engine.value = TtsEngine.fromKey(prefs.getString(_kEngineKey));
    await prefs.setString(_kEngineKey, TtsEngine.supertonic.key);
    voiceSid.value = prefs.getInt(_kVoiceSidKey) ?? _defaultSid;
    if (!_platformCapabilities.supportsOnDeviceSpeechModels) {
      enabled.value = false;
      error.value = _unsupportedPlatformMessage;
      if (prefs.getBool(_kEnabledKey) == true) {
        await prefs.setBool(_kEnabledKey, false);
      }
      return this;
    }
    enabled.value = prefs.getBool(_kEnabledKey) ?? false;
    return this;
  }

  /// Pick the voice/timbre (Supertonic speaker id).  Persists so it sticks
  /// across launches; the next synthesis call picks it up immediately.
  Future<void> setVoiceSid(int sid) async {
    voiceSid.value = sid;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kVoiceSidKey, sid);
  }

  /// Persist the chosen engine (called from onboarding/settings).
  Future<void> select(TtsEngine next, {bool enable = true}) async {
    if (!_platformCapabilities.supportsOnDeviceSpeechModels) {
      engine.value = next;
      enabled.value = false;
      error.value = _unsupportedPlatformMessage;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEngineKey, next.key);
      await prefs.setBool(_kEnabledKey, false);
      if (enable) throw UnsupportedError(_unsupportedPlatformMessage);
      return;
    }
    final changed = next != engine.value;
    engine.value = next;
    enabled.value = enable;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEngineKey, next.key);
    await prefs.setBool(_kEnabledKey, enable);
    if ((!enable || changed) && isReady.value) {
      dispose();
    }
  }

  Future<void> ensureReady() {
    if (!_platformCapabilities.supportsOnDeviceSpeechModels) {
      return Future<void>.error(UnsupportedError(_unsupportedPlatformMessage));
    }
    if (!enabled.value) {
      return Future.error(StateError('Local neural TTS is disabled'));
    }
    if (isReady.value) return Future.value();
    return _loadFuture ??= _ensureReady();
  }

  Future<void> _ensureReady() async {
    isLoading.value = true;
    error.value = null;
    final model = engine.value.model;
    try {
      final status = _downloads.statusOf(model.id);
      isDownloading.value = status.isLoading.value;
      final workers = <Worker>[
        ever<double>(status.progress, (v) => downloadProgress.value = v),
        ever<int>(status.receivedBytes, (v) => downloadedBytes.value = v),
        ever<int>(status.totalBytes, (v) => totalBytes.value = v),
        ever<int?>(status.etaSeconds, (v) => etaSeconds.value = v),
        ever<bool>(status.isLoading, (v) => isDownloading.value = v),
      ];
      try {
        final dir = await _downloads.ensure(model);
        await _startWorkerFromDir(dir);
        isReady.value = true;
        // Prime the ONNX graphs off the hot path.  Without this the FIRST real
        // utterance pays graph-build / first-inference cost mid-conversation;
        // a tiny throwaway synthesis warms all four models inside the worker.
        try {
          await synthesizeToWav('hi', lang: 'en');
        } catch (_) {}
        Log.i('🗣️ [SherpaTts] ${engine.value.label} ready (primed)');
      } finally {
        for (final w in workers) {
          w.dispose();
        }
        isDownloading.value = false;
      }
    } catch (e, st) {
      error.value = e.toString();
      // Surface the REAL reason — without this the only visible log was
      // "cleared cache", hiding why the engine actually failed to load
      // (e.g. the worker isolate's OfflineTts() throwing on an ONNX opset
      // the iOS runtime rejects, or a missing/renamed model file).
      Log.e(
        '🗣️ [SherpaTts] ${engine.value.label} (${model.id}) load FAILED: $e',
        error: e,
        stackTrace: st,
      );
      // If extraction wrote the marker but loading failed afterwards (a
      // renamed file, truncated tarball, etc.), nuke the cache so the
      // next retry truly re-downloads instead of looping on the same bad
      // state.  No-op when nothing was extracted.
      try {
        await _downloads.remove(model);
        Log.w('🗣️ [SherpaTts] cleared cache after failure for clean retry');
      } catch (cleanupErr) {
        Log.w('🗣️ [SherpaTts] cache cleanup also failed: $cleanupErr');
      }
      rethrow;
    } finally {
      isLoading.value = false;
      _loadFuture = null;
    }
  }

  Future<void> _startWorkerFromDir(Directory dir) async {
    final paths = await _supertonicPaths(dir);
    await _disposeWorker();

    final ready = Completer<void>();
    final receivePort = ReceivePort();
    _workerReady = ready;
    _workerReceivePort = receivePort;
    _workerSubscription = receivePort.listen(_handleWorkerMessage);

    _worker = await Isolate.spawn(_sherpaTtsWorkerMain, {
      'replyPort': receivePort.sendPort,
      'paths': paths,
    }, debugName: 'sherpa_tts_worker');
    await ready.future;
  }

  /// Supertonic 3 int8 ships 7 files flattened under [dir]:
  ///   duration_predictor.int8.onnx, text_encoder.int8.onnx,
  ///   vector_estimator.int8.onnx, vocoder.int8.onnx, tts.json,
  ///   unicode_indexer.bin, voice.bin
  Future<Map<String, String>> _supertonicPaths(Directory dir) async {
    final durationPredictor = p.join(dir.path, 'duration_predictor.int8.onnx');
    final textEncoder = p.join(dir.path, 'text_encoder.int8.onnx');
    final vectorEstimator = p.join(dir.path, 'vector_estimator.int8.onnx');
    final vocoder = p.join(dir.path, 'vocoder.int8.onnx');
    final ttsJson = p.join(dir.path, 'tts.json');
    final unicodeIndexer = p.join(dir.path, 'unicode_indexer.bin');
    final voiceStyle = p.join(dir.path, 'voice.bin');

    for (final f in [
      durationPredictor,
      textEncoder,
      vectorEstimator,
      vocoder,
      ttsJson,
      unicodeIndexer,
      voiceStyle,
    ]) {
      if (!await File(f).exists()) {
        throw StateError('Supertonic file missing: $f');
      }
    }

    return {
      'durationPredictor': durationPredictor,
      'textEncoder': textEncoder,
      'vectorEstimator': vectorEstimator,
      'vocoder': vocoder,
      'ttsJson': ttsJson,
      'unicodeIndexer': unicodeIndexer,
      'voiceStyle': voiceStyle,
    };
  }

  void _handleWorkerMessage(dynamic message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'ready') {
      _workerSendPort = message['sendPort'] as SendPort?;
      if (!(_workerReady?.isCompleted ?? true)) {
        _workerReady?.complete();
      }
      return;
    }
    if (type == 'initError') {
      final err = StateError(message['error']?.toString() ?? 'TTS init failed');
      if (!(_workerReady?.isCompleted ?? true)) {
        _workerReady?.completeError(err);
      }
      return;
    }
    if (type != 'synthResult') return;

    final id = message['id'] as int?;
    if (id == null) return;
    final pending = _pendingSynth.remove(id);
    if (pending == null || pending.isCompleted) return;

    if (message['ok'] == true) {
      final data = message['wav'] as TransferableTypedData;
      final envelope = (message['envelope'] as List? ?? const [])
          .map((v) => (v as num).toDouble())
          .toList(growable: false);
      pending.complete(
        SherpaTtsClip(
          wav: data.materialize().asUint8List(),
          envelope: envelope,
        ),
      );
    } else {
      pending.completeError(
        StateError(message['error']?.toString() ?? 'TTS synthesis failed'),
      );
    }
  }

  /// Run synthesis.  Synchronous on the native side — returns once the
  /// worker isolate has produced all samples.  The UI isolate only awaits a
  /// message and never runs the sherpa FFI generation.
  Future<SherpaTtsResult> synthesize(
    String text, {
    int? sid,
    double? speed,
    String? lang,
  }) async {
    final wav = await synthesizeToWav(text, sid: sid, speed: speed, lang: lang);
    return _parseWavResult(wav);
  }

  Future<Uint8List> synthesizeToWav(
    String text, {
    int? sid,
    double? speed,
    String? lang,
  }) async {
    final clip = await synthesizeToWavWithEnvelope(
      text,
      sid: sid,
      speed: speed,
      lang: lang,
    );
    return clip.wav;
  }

  Future<SherpaTtsClip> synthesizeToWavWithEnvelope(
    String text, {
    int? sid,
    double? speed,
    String? lang,
  }) async {
    if (!isReady.value) await ensureReady();
    final port = _workerSendPort;
    if (port == null) {
      throw StateError('Sherpa TTS worker not ready');
    }
    final id = ++_requestSeq;
    final completer = Completer<SherpaTtsClip>();
    _pendingSynth[id] = completer;
    port.send({
      'type': 'synthesize',
      'id': id,
      'text': text,
      'sid': sid ?? voiceSid.value,
      'speed': speed ?? 1.0,
      'lang': _supertonicLang(lang),
      'numSteps': _numSteps,
    });
    return completer.future;
  }

  /// Languages the bundled Supertonic build can actually synthesize.  The
  /// model rejects any tag outside this set with "Invalid language: …" and
  /// emits an empty/garbage WAV (notably for Chinese 'zh'), which then fails
  /// AVPlayer playback.  Source of truth = the native "Available:" list the
  /// engine prints at load.
  static const _supertonicLangs = <String>{
    'en',
    'ko',
    'ja',
    'ar',
    'bg',
    'cs',
    'da',
    'de',
    'el',
    'es',
    'et',
    'fi',
    'fr',
    'hi',
    'hr',
    'hu',
    'id',
    'it',
    'lt',
    'lv',
    'nl',
    'pl',
    'pt',
    'ro',
    'ru',
    'sk',
    'sl',
    'sv',
    'tr',
    'uk',
    'vi',
  };

  /// Map an app locale to a Supertonic `lang` tag.  Anything the model can't
  /// speak falls back to English — the one tag this int8 build always
  /// accepts.  (Upstream Supertonic also has a language-agnostic 'na' tag, but
  /// the bundled sherpa-onnx int8 build rejects it: "Invalid language: na".)
  ///
  /// NOTE: Chinese has no Supertonic support at all and should never reach
  /// here — [supportsLang] gates it out so the caller can use system TTS.
  String _supertonicLang(String? lang) {
    final code = (lang ?? '').toLowerCase().split(RegExp(r'[-_]')).first;
    return _supertonicLangs.contains(code) ? code : 'en';
  }

  /// Whether Supertonic can synthesize [lang] at all.  Returns false for
  /// Chinese (and anything else outside the 31-language set), so the caller
  /// can route those to the system TTS instead of feeding the engine text it
  /// will mangle or reject.
  bool supportsLang(String? lang) {
    final code = (lang ?? '').toLowerCase().split(RegExp(r'[-_]')).first;
    return _supertonicLangs.contains(code);
  }

  /// Convenience for verifying TTS end-to-end without going through
  /// playback — synthesize then dump a WAV under app docs dir.
  Future<String> smokeSynthesizeToFile(String text, {int? sid}) async {
    await ensureReady();
    final wav = await synthesizeToWav(text, sid: sid);
    final docs = await getApplicationDocumentsDirectory();
    final path = p.join(docs.path, 'sherpa_tts_smoke.wav');
    await File(path).writeAsBytes(wav, flush: true);
    Log.i(
      '🎧 [SherpaTts] smoke wav: $path '
      '(${wav.length} bytes)',
    );
    return path;
  }

  @override
  void onClose() {
    dispose();
    super.onClose();
  }

  void dispose() {
    _disposeWorker();
    isReady.value = false;
  }

  Future<void> _disposeWorker() async {
    _workerSendPort?.send({'type': 'shutdown'});
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _workerSendPort = null;
    await _workerSubscription?.cancel();
    _workerSubscription = null;
    _workerReceivePort?.close();
    _workerReceivePort = null;
    final pending = List.of(_pendingSynth.values);
    _pendingSynth.clear();
    for (final c in pending) {
      if (!c.isCompleted) {
        c.completeError(StateError('Sherpa TTS worker disposed'));
      }
    }
  }
}

void _sherpaTtsWorkerMain(Map<String, Object?> init) {
  final replyPort = init['replyPort']! as SendPort;
  final paths = Map<String, String>.from(init['paths']! as Map);
  final commandPort = ReceivePort();
  sherpa.OfflineTts? engine;

  try {
    // sherpa-onnx FFI bindings live in isolate-local statics, so the main
    // isolate's initBindings() (in main.dart) does NOT carry over here. This
    // spawned worker must initialize them itself before any OfflineTts /
    // factory call, or every create throws "Please initialize sherpa-onnx
    // first".  Cheap + idempotent.
    sherpa.initBindings();
    engine = sherpa.OfflineTts(_workerConfig(paths));
    replyPort.send({'type': 'ready', 'sendPort': commandPort.sendPort});
  } catch (e, st) {
    replyPort.send({'type': 'initError', 'error': '$e\n$st'});
    commandPort.close();
    return;
  }

  commandPort.listen((message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'shutdown') {
      engine?.free();
      engine = null;
      commandPort.close();
      return;
    }
    if (type != 'synthesize') return;
    final id = message['id'] as int;
    try {
      final audio = engine!.generateWithConfig(
        text: message['text']?.toString() ?? '',
        config: sherpa.OfflineTtsGenerationConfig(
          sid: message['sid'] as int? ?? SherpaNeuralTts._defaultSid,
          speed: (message['speed'] as num?)?.toDouble() ?? 1.0,
          numSteps: message['numSteps'] as int? ?? 6,
          extra: {
            'lang': message['lang']?.toString() ?? 'en',
            'num_steps': message['numSteps'] as int? ?? 6,
          },
        ),
      );
      final wav = _samplesToWav(audio.samples, audio.sampleRate);
      final envelope = _computeEnvelopeFromSamples(
        audio.samples,
        audio.sampleRate,
      );
      replyPort.send({
        'type': 'synthResult',
        'id': id,
        'ok': true,
        'wav': TransferableTypedData.fromList([wav]),
        'envelope': envelope,
      });
    } catch (e, st) {
      replyPort.send({
        'type': 'synthResult',
        'id': id,
        'ok': false,
        'error': '$e\n$st',
      });
    }
  });
}

sherpa.OfflineTtsConfig _workerConfig(Map<String, String> paths) {
  return sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      supertonic: sherpa.OfflineTtsSupertonicModelConfig(
        durationPredictor: paths['durationPredictor']!,
        textEncoder: paths['textEncoder']!,
        vectorEstimator: paths['vectorEstimator']!,
        vocoder: paths['vocoder']!,
        ttsJson: paths['ttsJson']!,
        unicodeIndexer: paths['unicodeIndexer']!,
        voiceStyle: paths['voiceStyle']!,
      ),
      // 3 inference threads: now that we synthesize the whole reply in one shot
      // (no first-chunk latency trick), extra parallelism keeps end-to-end synth
      // time down on multi-core devices.
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    ),
  );
}

Uint8List _samplesToWav(Float32List samples, int sampleRate) {
  final n = samples.length;
  final dataSize = n * 2;
  final buffer = ByteData(44 + dataSize);
  buffer.setUint32(0, 0x52494646, Endian.big); // 'RIFF'
  buffer.setUint32(4, 36 + dataSize, Endian.little);
  buffer.setUint32(8, 0x57415645, Endian.big); // 'WAVE'
  buffer.setUint32(12, 0x666d7420, Endian.big); // 'fmt '
  buffer.setUint32(16, 16, Endian.little);
  buffer.setUint16(20, 1, Endian.little);
  buffer.setUint16(22, 1, Endian.little);
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, sampleRate * 2, Endian.little);
  buffer.setUint16(32, 2, Endian.little);
  buffer.setUint16(34, 16, Endian.little);
  buffer.setUint32(36, 0x64617461, Endian.big); // 'data'
  buffer.setUint32(40, dataSize, Endian.little);
  var offset = 44;
  for (var i = 0; i < n; i++) {
    var v = samples[i];
    if (v > 1.0) v = 1.0;
    if (v < -1.0) v = -1.0;
    buffer.setInt16(offset, (v * 32767).round(), Endian.little);
    offset += 2;
  }
  return buffer.buffer.asUint8List();
}

List<double> _computeEnvelopeFromSamples(
  Float32List samples,
  int sampleRate, {
  int frameRate = 30,
}) {
  if (sampleRate <= 0 || samples.isEmpty) return const [];
  final samplesPerFrame = (sampleRate / frameRate).round();
  final out = <double>[];
  for (var i = 0; i < samples.length; i += samplesPerFrame) {
    double sumSq = 0;
    var n = 0;
    for (var j = i; j < i + samplesPerFrame && j < samples.length; j++, n++) {
      final s = samples[j];
      sumSq += s * s;
    }
    if (n == 0) break;
    final rms = math.sqrt(sumSq / n);
    out.add((rms * 32767 / 8000).clamp(0.0, 1.0));
  }
  return out;
}

SherpaTtsResult _parseWavResult(Uint8List wav) {
  if (wav.length < 44) {
    throw StateError('Invalid WAV: too short');
  }
  final bd = ByteData.sublistView(wav);
  final sampleRate = bd.getUint32(24, Endian.little);
  final bitsPerSample = bd.getUint16(34, Endian.little);
  if (bitsPerSample != 16) {
    throw StateError('Invalid WAV: expected 16-bit PCM');
  }
  var dataStart = 36;
  while (dataStart + 8 < wav.length) {
    final chunkId = String.fromCharCodes(wav.sublist(dataStart, dataStart + 4));
    final chunkSize = bd.getUint32(dataStart + 4, Endian.little);
    if (chunkId == 'data') {
      dataStart += 8;
      break;
    }
    dataStart += 8 + chunkSize;
  }
  final data = ByteData.sublistView(wav, dataStart);
  final samples = Float32List(data.lengthInBytes ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return SherpaTtsResult(samples: samples, sampleRate: sampleRate);
}
