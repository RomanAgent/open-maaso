import 'dart:typed_data';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/sherpa_model_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _unsupportedMessage =
    'Local Sherpa neural TTS is unavailable in the browser.';

enum TtsEngine {
  supertonic('supertonic');

  const TtsEngine(this.key);

  final String key;

  static TtsEngine fromKey(String? key) => TtsEngine.supertonic;

  String get label => 'Supertonic 3';

  SherpaModel get model => SherpaModelRegistry.supertonicTts;
}

class SherpaTtsResult {
  SherpaTtsResult({required this.samples, required this.sampleRate});

  final Float32List samples;
  final int sampleRate;

  Uint8List toWavBytes() => Uint8List(0);
}

class SherpaTtsClip {
  SherpaTtsClip({required this.wav, required this.envelope});

  final Uint8List wav;
  final List<double> envelope;
}

class SherpaNeuralTts extends AppService {
  SherpaNeuralTts({AppPlatformCapabilities? platformCapabilities});

  static const enabledPrefsKey = 'tts.enabled';
  static const _voiceSidKey = 'tts.voice_sid';

  final RxBool isReady = false.obs;
  final RxBool isLoading = false.obs;
  final RxBool isDownloading = false.obs;
  final RxnString error = RxnString(_unsupportedMessage);
  final RxDouble downloadProgress = 0.0.obs;
  final RxInt downloadedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;
  final RxnInt etaSeconds = RxnInt();
  final Rx<TtsEngine> engine = TtsEngine.supertonic.obs;
  final RxBool enabled = false.obs;
  final RxInt voiceSid = 0.obs;

  Future<SherpaNeuralTts> init() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = false;
    if (prefs.getBool(enabledPrefsKey) == true) {
      await prefs.setBool(enabledPrefsKey, false);
    }
    voiceSid.value = prefs.getInt(_voiceSidKey) ?? 0;
    return this;
  }

  Future<void> setVoiceSid(int sid) async {
    voiceSid.value = sid;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_voiceSidKey, sid);
  }

  Future<void> select(TtsEngine next, {bool enable = true}) async {
    engine.value = next;
    enabled.value = false;
    error.value = _unsupportedMessage;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledPrefsKey, false);
    if (enable) throw UnsupportedError(_unsupportedMessage);
  }

  Future<void> ensureReady() =>
      Future<void>.error(UnsupportedError(_unsupportedMessage));

  Future<SherpaTtsResult> synthesize(
    String text, {
    int? sid,
    double? speed,
    String? lang,
  }) => Future<SherpaTtsResult>.error(UnsupportedError(_unsupportedMessage));

  Future<Uint8List> synthesizeToWav(
    String text, {
    int? sid,
    double? speed,
    String? lang,
  }) => Future<Uint8List>.error(UnsupportedError(_unsupportedMessage));

  Future<SherpaTtsClip> synthesizeToWavWithEnvelope(
    String text, {
    int? sid,
    double? speed,
    String? lang,
  }) => Future<SherpaTtsClip>.error(UnsupportedError(_unsupportedMessage));

  bool supportsLang(String? lang) => false;

  Future<String> smokeSynthesizeToFile(String text, {int? sid}) =>
      Future<String>.error(UnsupportedError(_unsupportedMessage));

  void dispose() {
    isReady.value = false;
  }
}
