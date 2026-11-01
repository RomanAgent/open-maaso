import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/sherpa_neural_tts.dart';

/// Drives the TTS-model warm-up and surfaces progress to the dashboard
/// banner.
///
/// Re-entry behavior:
///   * Calling [start] while warm-up is in flight → no-op.
///   * Calling [start] after a previous run **failed** → reset state and
///     restart from scratch (banner UI flips back from error to live
///     progress bar).
///   * Calling [start] after success → no-op.
class TtsWarmupService extends AppService {
  final RxDouble progress = 0.0.obs;
  final RxBool isReady = false.obs;
  final RxBool isFailed = false.obs;
  final RxBool isRunning = false.obs;
  // True ONLY while a real model download/extract is happening.  [isRunning]
  // is true for the whole warm-up (incl. cache load + ONNX prime), so the
  // download card binds to THIS to avoid flashing on cached launches.
  final RxBool isDownloading = false.obs;

  /// Last failure reason shown next to the Retry button.  Cleared at the
  /// start of every [start] attempt; populated when warm-up throws.
  final RxnString error = RxnString();

  /// Bytes downloaded so far / total expected.  Mirrored from
  /// [SherpaNeuralTts] while a download is in flight.  Used by the
  /// dashboard banner to render "152 MB / 180 MB · 2s left".
  final RxInt downloadedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;
  final RxnInt etaSeconds = RxnInt();

  /// Reserved for future per-file progress info if a future model split
  /// download into multiple parts.  Currently the sherpa pipeline downloads
  /// a single tarball so these stay at 0/0.
  final RxnString currentFile = RxnString();
  final RxInt completedFiles = 0.obs;
  final RxInt totalFiles = 0.obs;

  Future<void> start() async {
    if (isRunning.value || isReady.value) return;
    isFailed.value = false;
    error.value = null;
    progress.value = 0.0;
    downloadedBytes.value = 0;
    totalBytes.value = 0;
    etaSeconds.value = null;
    currentFile.value = null;
    completedFiles.value = 0;
    totalFiles.value = 0;
    isDownloading.value = false;
    isRunning.value = true;

    bool ok = false;
    try {
      if (!appServices.isRegistered<SherpaNeuralTts>()) {
        // No neural engine wired — system TTS will be used by the TTS bridge.
        // Treat the warm-up as a no-op success so the banner clears.
        ok = true;
      } else {
        ok = await _warmUpSherpa();
      }
    } finally {
      isRunning.value = false;
      isReady.value = ok;
      isFailed.value = !ok;
      if (ok) {
        progress.value = 1.0;
        currentFile.value = null;
      }
    }
  }

  Future<bool> _warmUpSherpa() async {
    final tts = appServices.find<SherpaNeuralTts>();
    isDownloading.value = tts.isDownloading.value;
    final workers = <Worker>[
      ever<double>(tts.downloadProgress, (v) {
        // sherpa emits -1 as the indeterminate sentinel; map to "unknown"
        // and let UI render an indeterminate spinner via value=null.
        progress.value = v < 0 ? 0 : v;
      }),
      ever<int>(tts.downloadedBytes, (v) => downloadedBytes.value = v),
      ever<int>(tts.totalBytes, (v) => totalBytes.value = v),
      ever<int?>(tts.etaSeconds, (v) => etaSeconds.value = v),
      ever<bool>(tts.isDownloading, (v) => isDownloading.value = v),
    ];
    try {
      await tts.ensureReady();
      return tts.isReady.value;
    } catch (e) {
      // Surface the real cause so the banner can show users why warmup
      // failed (404 / network / load-step file mismatch).  Without this
      // they only see the generic "Neural TTS not ready" and can't tell
      // whether retry is even doing anything.
      error.value = e.toString();
      return false;
    } finally {
      for (final w in workers) {
        w.dispose();
      }
      isDownloading.value = false;
    }
  }

  Future<void> retry() => start();

  /// Boot path: warm up the local neural voice only after explicit opt-in.
  Future<void> startIfEnabled() async {
    if (!appServices.isRegistered<SherpaNeuralTts>()) return;
    if (!appServices.find<SherpaNeuralTts>().enabled.value) return;
    await start();
  }
}
