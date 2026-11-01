/// Static catalog of every sherpa-onnx model maaso can download.
///
/// Speech subsystems (TTS / VAD) pull from this registry,
/// so [SherpaModel] is generic over what's *inside* the tarball — its
/// responsibilities stop at "where to get the bytes, what to name the cache
/// directory, how big it is roughly".  Per-model file paths (e.g. the six
/// `.onnx` files inside the Supertonic tarball) are resolved by the
/// consuming service against the extracted directory.
class SherpaModel {
  /// Stable id used as the on-disk cache directory name.  Pick something
  /// short and human-readable; once a build ships with id "X", **never**
  /// reuse it for a different model — existing users would see stale files.
  final String id;

  /// Human-facing name shown in download UIs.
  final String displayName;

  /// Direct download URL — typically a GitHub Releases `.tar.bz2`.
  final String releaseUrl;

  /// Approximate download size in bytes.  Pure UI hint ("~ 180 MB"); the
  /// real `Content-Length` from the HTTP response wins when present.
  final int approxBytes;

  /// Optional SHA-256 of the archive for integrity check after download.
  /// Skip when k2-fsa publishes a new build and we haven't pinned a hash yet.
  final String? sha256;

  /// Optional map of "asset path inside the Flutter bundle" → "filename to
  /// write under the model dir".  When all listed assets are present in
  /// the manifest, [SherpaModelDownloadService.ensure] copies them straight
  /// to disk and skips the cloud download entirely.  Missing assets cause
  /// a silent fall-through to [releaseUrl].
  ///
  /// To enable bundling for a model:
  ///   1. Drop the model files under `assets/sherpa_models/<id>/...`.
  ///   2. Uncomment the matching block in `pubspec.yaml`'s `flutter.assets`.
  ///   3. Run `flutter pub get` (so the manifest picks them up).
  final Map<String, String>? bundledAssets;

  /// Optional "download only these files" manifest: maps the on-disk filename
  /// (written directly under the model dir) → its direct download URL.
  ///
  /// When set, [SherpaModelDownloadService.ensure] fetches each file
  /// individually and SKIPS the [releaseUrl] tarball entirely.
  final Map<String, String>? directFiles;

  const SherpaModel({
    required this.id,
    required this.displayName,
    required this.releaseUrl,
    required this.approxBytes,
    this.sha256,
    this.bundledAssets,
    this.directFiles,
  });
}

class SherpaModelRegistry {
  /// TTS — Supertonic 3 (int8, 2026-05-11). Default voice engine.
  ///
  /// This model needs the rebuilt iOS sherpa_onnx binary that links ONNX
  /// Runtime 1.26.0; the published 1.13.2 iOS binary rejects its vocoder's
  /// `ai.onnx.ml` opset 5 stamp.
  ///
  /// Tarball flattens to 7 files under the model dir:
  ///   duration_predictor.int8.onnx, text_encoder.int8.onnx,
  ///   vector_estimator.int8.onnx, vocoder.int8.onnx, tts.json,
  ///   unicode_indexer.bin, voice.bin
  static const supertonicTts = SherpaModel(
    id: 'supertonic-3-tts-int8-2026-05-11',
    displayName: 'Supertonic 3 TTS (int8)',
    releaseUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'
        'sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2',
    approxBytes: 100 * 1024 * 1024,
  );

  /// Silero VAD — single ONNX, ~629 KB. Bundled for offline first launch;
  /// [releaseUrl] remains the fallback if the packaged asset is unavailable.
  static const sileroVad = SherpaModel(
    id: 'silero-vad-v5',
    displayName: 'Silero VAD',
    releaseUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'silero_vad.onnx',
    approxBytes: 643854,
    bundledAssets: <String, String>{
      'assets/sherpa_models/silero-vad-v5/silero_vad.onnx': 'silero_vad.onnx',
    },
  );
}
