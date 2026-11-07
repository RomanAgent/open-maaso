import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:maaso/src/core/services/bundled_model_resolver.dart';
import 'package:maaso/src/core/services/sherpa_model_registry.dart';

/// One-stop "make sure this sherpa model is unpacked on disk" service.
///
/// Two responsibilities:
///   1. **Download** the `.tar.bz2` archive from GitHub Releases, with
///      cancellable Dio progress.  Re-runs are no-ops once the marker file
///      is in place.
///   2. **Extract** with the pure-Dart `archive` package (bzip2 → tar).
///      Files land inside `<docsDir>/sherpa_models/<model.id>/…` — the
///      exact tree the upstream tarball contains.  Empty directories at
///      the top level are flattened so the consuming service doesn't have
///      to know whether the tarball ships a wrapping folder.
///
/// Reactive surface (one [SherpaDownloadStatus] per model id) lets the
/// Settings UI render progress / errors without polling.
class SherpaModelDownloadService extends AppService {
  SherpaModelDownloadService({this.allowNetwork = true});

  final bool allowNetwork;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // Large model files - allow generous read window so a 100 MB chunk
      // mid-stream on a slow connection doesn't timeout.
      receiveTimeout: const Duration(minutes: 10),
    ),
  );

  /// Live status keyed by model id.  Returned by [statusOf] so any UI can
  /// `AppReactiveBuilder(() => svc.statusOf(id).progress.value)` without coupling to the
  /// download flow itself.
  final Map<String, SherpaDownloadStatus> _statuses = {};

  SherpaDownloadStatus statusOf(String modelId) =>
      _statuses.putIfAbsent(modelId, SherpaDownloadStatus.new);

  /// Returns the on-disk directory where the model's contents live.
  /// Downloads + extracts on first call; cheap on subsequent calls.
  ///
  /// Throws if any step fails — callers should wrap with try/catch and
  /// surface the error on the model's [SherpaDownloadStatus.error].
  Future<Directory> ensure(SherpaModel model) async {
    final status = statusOf(model.id);
    if (status.isReady.value) {
      return Directory(status.directoryPath.value!);
    }

    final docs = await getApplicationDocumentsDirectory();
    final modelsRoot = Directory(p.join(docs.path, 'sherpa_models'));
    final modelDir = Directory(p.join(modelsRoot.path, model.id));
    final marker = File(p.join(modelDir.path, '.ready'));

    if (await marker.exists()) {
      status.directoryPath.value = modelDir.path;
      status.isReady.value = true;
      status.progress.value = 1.0;
      return modelDir;
    }

    status.isLoading.value = true;
    status.error.value = null;
    status.progress.value = 0;
    try {
      await modelDir.create(recursive: true);

      // 1) Bundled-assets fast path.  If the host build dropped the model
      // files under the right asset paths AND added them to pubspec, copy
      // straight from rootBundle — no cloud download, no bzip2/tar pass.
      final bundle = model.bundledAssets;
      if (bundle != null && bundle.isNotEmpty) {
        if (await BundledModelResolver.areAssetsBundled(bundle.keys)) {
          status.phase.value = SherpaDownloadPhase.extracting;
          final ok = await BundledModelResolver.copyBundledAssetsTo(
            bundle,
            modelDir,
            onProgress: (copied, total) {
              if (total > 0) {
                status.progress.value = (copied / total).clamp(0.0, 0.99);
              }
            },
          );
          if (ok) {
            await marker.create();
            status.directoryPath.value = modelDir.path;
            status.isReady.value = true;
            status.progress.value = 1.0;
            status.phase.value = SherpaDownloadPhase.idle;
            Log.i('✅ [SherpaDL] ${model.id} loaded from bundled assets');
            return modelDir;
          }
          Log.w('📦 [SherpaDL] ${model.id} bundled-asset copy failed');
        }
      }

      if (!allowNetwork) {
        throw StateError(
          'The required model is not available in the app bundle.',
        );
      }

      // 2) Direct-files fast path.  When the model declares an explicit
      // filename→URL manifest, download just those files straight into the
      // model dir and skip the (often much larger) release tarball + extract.
      final direct = model.directFiles;
      if (direct != null && direct.isNotEmpty) {
        await _downloadDirectFiles(model, direct, modelDir, status);
        await marker.create();
        status.directoryPath.value = modelDir.path;
        status.isReady.value = true;
        status.progress.value = 1.0;
        status.phase.value = SherpaDownloadPhase.idle;
        Log.i(
          '✅ [SherpaDL] ${model.id} ready (direct files) at '
          '${modelDir.path}',
        );
        return modelDir;
      }

      // 3) Cloud download fallback.
      final urlBasename = p.basename(Uri.parse(model.releaseUrl).path);
      final isTarball =
          urlBasename.endsWith('.tar.bz2') || urlBasename.endsWith('.tar.gz');
      final downloadPath = isTarball
          ? p.join(docs.path, '${model.id}.tar.bz2')
          : p.join(modelDir.path, urlBasename);
      final downloadFile = File(downloadPath);

      Log.i('📦 [SherpaDL] ${model.id} → $downloadPath');
      status.phase.value = SherpaDownloadPhase.downloading;

      // These big tarballs come off GitHub release CDN, which routinely drops
      // the connection mid-stream ("Connection closed while receiving data").
      // A single failure shouldn't strand the user without a local speech
      // model — retry a few times with backoff, wiping the partial file between
      // attempts.
      const maxAttempts = 3;
      Object? lastErr;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        status.receivedBytes.value = 0;
        status.totalBytes.value = 0;
        status.etaSeconds.value = null;
        final downloadStart = DateTime.now();
        // Throttle the ETA recomputation — Dio's callback fires per packet,
        // which is way more often than the UI needs and would make the ETA
        // number jitter every frame.
        DateTime lastEtaUpdate = downloadStart;
        try {
          await _dio.download(
            model.releaseUrl,
            downloadPath,
            deleteOnError: true,
            onReceiveProgress: (received, total) {
              status.receivedBytes.value = received;
              if (total > 0) {
                status.totalBytes.value = total;
                status.progress.value = (received / total).clamp(0.0, 0.95);
              }
              final now = DateTime.now();
              if (now.difference(lastEtaUpdate).inMilliseconds < 500) return;
              lastEtaUpdate = now;
              final elapsedMs = now.difference(downloadStart).inMilliseconds;
              if (elapsedMs < 1000 || received <= 0 || total <= received) {
                return;
              }
              final bytesPerSec = received / (elapsedMs / 1000.0);
              if (bytesPerSec <= 0) return;
              final remainingBytes = total - received;
              status.etaSeconds.value = (remainingBytes / bytesPerSec).round();
            },
          );
          lastErr = null;
          break; // success
        } on DioException catch (e) {
          lastErr = e;
          Log.w(
            '📦 [SherpaDL] ${model.id} download attempt '
            '$attempt/$maxAttempts failed: ${e.message}',
          );
          // Drop any partial bytes so the retry starts clean.
          try {
            if (await downloadFile.exists()) await downloadFile.delete();
          } catch (_) {}
          if (attempt < maxAttempts) {
            await Future.delayed(Duration(seconds: 2 * attempt));
          }
        }
      }
      if (lastErr != null) {
        throw lastErr; // exhausted retries — surface to the catch below
      }

      if (isTarball) {
        // Decode bzip2 → tar → individual files.
        status.phase.value = SherpaDownloadPhase.extracting;
        await _extractTarBz2(downloadFile, modelDir);
        await downloadFile.delete().catchError((_) => downloadFile);
        // Some k2-fsa archives wrap the payload in a sub-folder named
        // after the archive.
        // Flatten it so consumers see files directly under [modelDir].
        await _flattenSingleSubdir(modelDir);
      }
      // Non-tarball (bare .onnx) — already in place at modelDir/<basename>.

      await marker.create();
      status.directoryPath.value = modelDir.path;
      status.isReady.value = true;
      status.progress.value = 1.0;
      status.phase.value = SherpaDownloadPhase.idle;
      Log.i('✅ [SherpaDL] ${model.id} ready at ${modelDir.path}');
      return modelDir;
    } catch (e, st) {
      Log.e('❌ [SherpaDL] ${model.id} failed: $e\n$st');
      status.error.value = e.toString();
      rethrow;
    } finally {
      status.isLoading.value = false;
    }
  }

  /// Download each file in [files] (filename → URL) directly into [modelDir],
  /// reporting a single aggregate progress / ETA across the whole set.  Used
  /// by the [SherpaModel.directFiles] path to avoid pulling a fat tarball when
  /// only a handful of files are actually needed.
  Future<void> _downloadDirectFiles(
    SherpaModel model,
    Map<String, String> files,
    Directory modelDir,
    SherpaDownloadStatus status,
  ) async {
    status.phase.value = SherpaDownloadPhase.downloading;
    status.receivedBytes.value = 0;
    status.totalBytes.value = 0;
    status.etaSeconds.value = null;

    // Probe each file's size up front so aggregate progress + ETA are
    // accurate. A failed HEAD just leaves that file's size unknown (0); the
    // download still proceeds, progress is merely coarser.
    final sizes = <String, int>{};
    var grandTotal = 0;
    for (final entry in files.entries) {
      try {
        final head = await _dio.head<void>(entry.value);
        final len =
            int.tryParse(
              head.headers.value(Headers.contentLengthHeader) ?? '',
            ) ??
            0;
        sizes[entry.key] = len;
        grandTotal += len;
      } catch (_) {
        sizes[entry.key] = 0;
      }
    }
    status.totalBytes.value = grandTotal;

    final downloadStart = DateTime.now();
    var lastEtaUpdate = downloadStart;
    var completedBytes = 0;

    for (final entry in files.entries) {
      final dest = p.join(modelDir.path, entry.key);
      final destFile = File(dest);
      Log.i('📦 [SherpaDL] ${model.id} → ${entry.key}');

      const maxAttempts = 3;
      Object? lastErr;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          await _dio.download(
            entry.value,
            dest,
            deleteOnError: true,
            onReceiveProgress: (received, total) {
              final overall = completedBytes + received;
              status.receivedBytes.value = overall;
              if (grandTotal > 0) {
                status.progress.value = (overall / grandTotal).clamp(0.0, 0.95);
              }
              final now = DateTime.now();
              if (now.difference(lastEtaUpdate).inMilliseconds < 500) return;
              lastEtaUpdate = now;
              final elapsedMs = now.difference(downloadStart).inMilliseconds;
              if (elapsedMs < 1000 || overall <= 0 || grandTotal <= overall) {
                return;
              }
              final bytesPerSec = overall / (elapsedMs / 1000.0);
              if (bytesPerSec <= 0) return;
              status.etaSeconds.value = ((grandTotal - overall) / bytesPerSec)
                  .round();
            },
          );
          lastErr = null;
          break; // file done
        } on DioException catch (e) {
          lastErr = e;
          Log.w(
            '📦 [SherpaDL] ${model.id} file ${entry.key} attempt '
            '$attempt/$maxAttempts failed: ${e.message}',
          );
          try {
            if (await destFile.exists()) await destFile.delete();
          } catch (_) {}
          if (attempt < maxAttempts) {
            await Future.delayed(Duration(seconds: 2 * attempt));
          }
        }
      }
      if (lastErr != null) throw lastErr; // exhausted retries for this file

      // Advance the cumulative counter by the real on-disk size so the next
      // file's progress continues from the right baseline (covers the case
      // where the HEAD probe returned 0).
      completedBytes += await destFile.length();
    }
  }

  /// Wipe an already-extracted model.  Useful when the user toggles a
  /// subsystem off in Settings and wants the disk back, or when we need
  /// to force a fresh re-download after a corrupted extraction.
  Future<void> remove(SherpaModel model) async {
    final docs = await getApplicationDocumentsDirectory();
    final modelDir = Directory(p.join(docs.path, 'sherpa_models', model.id));
    if (await modelDir.exists()) {
      await modelDir.delete(recursive: true);
    }
    final status = statusOf(model.id);
    status.isReady.value = false;
    status.directoryPath.value = null;
    status.progress.value = 0;
  }

  Future<void> _extractTarBz2(File archive, Directory dest) async {
    // Read entire archive into memory. Supertonic 3 is about 100 MB
    // compressed. If models start crossing 500 MB
    // we'll want to switch to a streaming decoder.
    final bytes = await archive.readAsBytes();
    final tarBytes = BZip2Decoder().decodeBytes(bytes);
    final tarArchive = TarDecoder().decodeBytes(tarBytes);
    for (final entry in tarArchive) {
      final relPath = entry.name;
      // Defense: skip any traversal attempts (`../`) in the tarball.
      if (relPath.contains('..')) {
        Log.w('🚨 [SherpaDL] skipping suspicious entry: $relPath');
        continue;
      }
      final outPath = p.join(dest.path, relPath);
      if (entry.isFile) {
        final file = File(outPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
  }

  /// If [root] contains exactly one subdirectory and no top-level files,
  /// hoist that subdirectory's contents up one level.  Standard pattern for
  /// k2-fsa tarballs which always wrap files in a folder matching the
  /// archive name — annoying because the consumer would otherwise have to
  /// know that folder's exact name to build paths against it.
  Future<void> _flattenSingleSubdir(Directory root) async {
    final entries = await root.list().toList();
    final dirs = entries.whereType<Directory>().toList();
    final hasTopLevelFiles = entries.any(
      (e) => e is File && p.basename(e.path) != '.ready',
    );
    if (hasTopLevelFiles || dirs.length != 1) return;

    final inner = dirs.first;
    final innerEntries = await inner.list().toList();
    for (final e in innerEntries) {
      final dst = p.join(root.path, p.basename(e.path));
      await e.rename(dst);
    }
    await inner.delete(recursive: true);
  }
}

/// Reactive view of one model's download lifecycle.  Pass instances of this
/// straight into `AppReactiveBuilder(() => ...)` widgets.
class SherpaDownloadStatus {
  /// 0..1 download fraction, or 1.0 once extraction completes.
  final RxDouble progress = 0.0.obs;

  /// True while download or extraction is in flight.
  final RxBool isLoading = false.obs;

  /// True once the model is fully unpacked and the consuming service can
  /// load it.  Stays true across app restarts (the marker file persists).
  final RxBool isReady = false.obs;

  /// Filesystem path to the extracted model directory, set when [isReady].
  final RxnString directoryPath = RxnString();

  /// Last failure message, cleared on the next successful run.
  final RxnString error = RxnString();

  /// Coarse stage indicator — most of the time UIs only need [progress],
  /// but during the bzip2/tar pass the progress bar would freeze without
  /// this hint.
  final Rx<SherpaDownloadPhase> phase = SherpaDownloadPhase.idle.obs;

  /// Raw download counters straight from Dio's `onReceiveProgress`.  Reset
  /// to 0 at the start of every fresh download.  Used by UIs to show
  /// "152 MB / 180 MB" alongside the progress bar.
  final RxInt receivedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;

  /// Estimated seconds remaining, derived from average throughput since
  /// the download started.  Null when too early to estimate (< 1 s elapsed
  /// or speed not yet computable).
  final RxnInt etaSeconds = RxnInt();
}

enum SherpaDownloadPhase { idle, downloading, extracting }
