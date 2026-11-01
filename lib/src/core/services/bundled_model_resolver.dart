import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:path/path.dart' as p;

/// Pull model files out of the Flutter asset bundle into a real file system
/// location, so native ONNX / GGUF loaders (which only accept real paths)
/// can use them.
///
/// Why this exists — first-launch UX.  Without bundling, every fresh
/// install has to download ~180 MB (TTS) or ~1.3 GB (LLM) before the agent
/// can speak or route locally.  Bundling lets a delivered build come up
/// instantly; the cloud-download fallback stays in place for builds that
/// chose to keep the assets out of the bundle.
///
/// Cost knobs that need a one-time decision before flipping bundling on:
///   * **App bundle size** balloons by the size of the bundled files.
///     iOS App Store ipa hard cap is 4 GB.  Android App Bundle's base APK
///     is capped at 200 MB unless you use dynamic-delivery asset packs.
///   * **Disk duplication** — the asset stays in the app bundle while a
///     copy lives in `getApplicationDocumentsDirectory()`.  No way around
///     this without platform channels: native loaders refuse asset:// URIs.
///   * **Transient memory** — `rootBundle.load()` loads the whole asset
///     into a `ByteData` before we can write it to disk.  Fine for 50 MB
///     ONNX files; risky for the 1.3 GB GGUF on low-RAM devices.
class BundledModelResolver {
  /// Returns true iff ALL asset paths in [assetPaths] exist in the bundle.
  /// Probes the asset manifest only (cheap), never loads any bytes.
  static Future<bool> areAssetsBundled(Iterable<String> assetPaths) async {
    if (assetPaths.isEmpty) return false;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final available = manifest.listAssets().toSet();
      for (final path in assetPaths) {
        if (!available.contains(path)) {
          Log.i('📦 [BundledModel] asset not in manifest: $path');
          return false;
        }
      }
      return true;
    } catch (e) {
      Log.w('📦 [BundledModel] asset manifest probe failed: $e');
      return false;
    }
  }

  /// Copy bundled assets into [destDir].  [assetToFilename] maps each asset
  /// path → the basename to write under [destDir].  Returns true if every
  /// file copied successfully, false if anything went wrong (caller should
  /// fall back to remote download in that case).
  ///
  /// Caller is responsible for ensuring [destDir] exists.  Existing files
  /// at the target paths are overwritten.
  static Future<bool> copyBundledAssetsTo(
    Map<String, String> assetToFilename,
    Directory destDir, {
    void Function(int copiedBytes, int totalBytes)? onProgress,
  }) async {
    // First: confirm every asset is actually present before we start
    // writing partial files to disk.
    if (!await areAssetsBundled(assetToFilename.keys)) return false;

    // Pre-tally total bytes so the UI can render real progress.  Cheap
    // because manifest doesn't load file bodies.
    int totalBytes = 0;
    int copiedBytes = 0;
    final sizes = <String, int>{};
    try {
      for (final assetPath in assetToFilename.keys) {
        final data = await rootBundle.load(assetPath);
        // Unfortunate: rootBundle.load reads the whole thing.  We do it
        // here once per file rather than peeking-then-loading; the
        // ByteData is kept only until we write it.
        sizes[assetPath] = data.lengthInBytes;
        totalBytes += data.lengthInBytes;
        final file = File(p.join(destDir.path, assetToFilename[assetPath]!));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
        copiedBytes += data.lengthInBytes;
        onProgress?.call(copiedBytes, totalBytes);
      }
      Log.i(
        '📦 [BundledModel] copied ${assetToFilename.length} files '
        '(${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB) → '
        '${destDir.path}',
      );
      return true;
    } catch (e, st) {
      Log.e('📦 [BundledModel] copy failed: $e\n$st');
      return false;
    }
  }
}
