import 'dart:async';
import 'dart:io';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:maaso/src/features/agent/application/llamadart_llm_backend.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';

/// A selectable on-device LLM, shown in the onboarding / settings picker.
///
/// All are text-only GGUFs loaded by the backbone path (no mmproj).  The
/// default is Qwen3.5-2B Q4_K_M — the Unsloth build llamadart ships/tests and
/// the one validated against the bundled llama.cpp (b9371).
class LlmModelOption {
  const LlmModelOption({
    required this.key,
    required this.label,
    required this.source,
    required this.approxLabel,
  });

  final String key;
  final String label;
  final String source;
  final String approxLabel;

  static const qwen35_2bQ4 = LlmModelOption(
    key: 'qwen3.5-2b-q4km',
    label: 'local_llm.qwen35_2b_q4',
    source: 'hf://unsloth/Qwen3.5-2B-GGUF/Qwen3.5-2B-Q4_K_M.gguf',
    approxLabel: '~1.5 GB',
  );

  static const defaultOption = qwen35_2bQ4;

  static const all = <LlmModelOption>[qwen35_2bQ4];

  static LlmModelOption fromKey(String? key) =>
      all.firstWhere((o) => o.key == key, orElse: () => defaultOption);
}

/// Owns the lifecycle of the on-device LLM ([LlamadartLLMBackend]).
///
/// The model weighs ≈ 1 GB so this is **opt-in** — we never auto-download.
/// The user (or a Settings UI) calls [enable], we kick off the download in
/// the background, expose [progress] for a banner, and register the backend
/// with the app service graph when it's ready. The model stays off the hot
/// route path; it is
/// used for local chat fallback and transient cloud-mode filler. Disabling
/// flips everything off and frees the native model handle.
class LocalLLMService extends AppService {
  LocalLLMService({AppPlatformCapabilities? platformCapabilities})
    : _platformCapabilities =
          platformCapabilities ?? AppPlatformCapabilities.current();

  static const _unsupportedPlatformMessage =
      'On-device LLM is available only on desktop hosts.';

  final AppPlatformCapabilities _platformCapabilities;

  bool get isSupportedOnHost => _platformCapabilities.supportsOnDeviceLlm;

  // ─────────── reactive surface (drive any UI from these) ───────────
  final RxBool isEnabled = false.obs;
  final RxBool isLoading = false.obs;
  // True ONLY while an actual network download is in flight.  Loading an
  // already-cached model flips [isLoading] but NOT this, so UI gated on
  // [isDownloading] (the download card) won't flash on every cold start.
  final RxBool isDownloading = false.obs;
  final RxBool isAvailable = false.obs;
  final RxDouble progress = 0.0.obs;
  final RxnString error = RxnString();

  /// "Save memory" mode. When ON, the local model is unloaded while the cloud
  /// brain is available and only resides in RAM when the cloud is unavailable.
  /// When OFF, the local model stays resident at all times so the
  /// hand-off to local is instant. Persisted.
  final RxBool saveMemory = false.obs;

  /// True while the local model is currently UNLOADED because save-memory is on
  /// and the cloud is the active brain. Drives the settings status text.
  final RxBool suppressedByCloud = false.obs;

  /// True only when the local model is actually serving right now.
  bool get isActive => isAvailable.value && !suppressedByCloud.value;

  final RxInt receivedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;
  final RxnInt etaSeconds = RxnInt();

  // ─────────── private ───────────
  LlamadartLLMBackend? _backend;

  /// Serializes the native model lifecycle.  Creating a new llama context
  /// (`_load`) while a previous one is still being disposed (`_unloadBackend`)
  /// can wedge the native backend — `llama_new_context_with_model` returns null
  /// ("Failed to create context"), after which EVERY later load fails until the
  /// app is restarted.  This happened in practice from the boot-time race
  /// (config loads async → a spurious local load then immediately unloads under
  /// save-memory+cloud) and from rapid cloud on/off toggles.  Chaining every
  /// load/unload through here guarantees create and dispose never overlap.
  Future<void> _lifecycle = Future.value();

  Future<void> _exclusive(Future<void> Function() op) {
    final run = _lifecycle.then((_) => op(), onError: (_) => op());
    _lifecycle = run.catchError((_) {});
    return run;
  }

  /// SharedPreferences key for the "save memory" mode (see [saveMemory]).
  static const _kSaveMemoryKey = 'local_llm.save_memory';

  /// SharedPreferences key for the user's explicit local-model opt-in.
  static const enabledPrefsKey = 'local_llm.enabled';
  static const _kEnabledKey = enabledPrefsKey;

  static const modelCacheDirName = 'llamadart_models';

  /// SharedPreferences key for the user's chosen model (persisted across
  /// launches so the picker selection sticks).
  static const _kModelKey = 'local_llm.model_key';

  /// The user-selected model.  Defaults to [LlmModelOption.defaultOption].
  final Rx<LlmModelOption> selectedModel = LlmModelOption.defaultOption.obs;

  // ─────────── per-model download surface (Settings model picker) ───────────
  /// Keys of models whose GGUF is fully present on disk (ready to switch to).
  final RxSet<String> downloadedKeys = <String>{}.obs;

  /// Key of the model whose file is currently being fetched by a per-model
  /// download button (independent of the active-model [isLoading] lifecycle).
  final RxnString downloadingKey = RxnString();

  /// Per-model download fraction (0..1) keyed by model key.
  final RxMap<String, double> downloadProgress = <String, double>{}.obs;

  /// Per-model raw download counters keyed by model key.
  final RxMap<String, int> downloadReceivedBytes = <String, int>{}.obs;
  final RxMap<String, int> downloadTotalBytes = <String, int>{}.obs;
  final RxMap<String, int> downloadEtaSeconds = <String, int>{}.obs;

  /// Per-model download error message keyed by model key (drives the retry
  /// button on the download row).
  final RxMap<String, String> downloadError = <String, String>{}.obs;

  static const defaultModelSource =
      'hf://unsloth/Qwen3.5-2B-GGUF/Qwen3.5-2B-Q4_K_M.gguf';

  /// [autoLoad] is ignored (kept for call-site compatibility). The local LLM
  /// is disabled until the user opts in from Settings; after that the
  /// [LlmModeCoordinator] decides residency.
  Future<LocalLLMService> init({bool autoLoad = true}) async {
    final prefs = await SharedPreferences.getInstance();
    selectedModel.value = LlmModelOption.fromKey(prefs.getString(_kModelKey));
    saveMemory.value = prefs.getBool(_kSaveMemoryKey) ?? true;
    if (!isSupportedOnHost) {
      await _disableOnUnsupportedHost(prefs: prefs, unload: false);
      return this;
    }
    isEnabled.value = prefs.getBool(_kEnabledKey) ?? false;
    // Discover which models are already on disk so the picker can offer them
    // without a re-download.  Cheap (a few stat() calls) — safe at boot.
    // ignore: unawaited_futures
    refreshDownloadedKeys();
    return this;
  }

  /// Switch which local model is active. Persists the choice; if we should be
  /// resident right now, tears down the old model and loads the new one.
  Future<void> selectModel(LlmModelOption option, {bool enable = true}) async {
    if (!isSupportedOnHost) {
      await _disableOnUnsupportedHost();
      return;
    }
    final changed = option.key != selectedModel.value.key;
    selectedModel.value = option;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModelKey, option.key);
    if (enable && !isEnabled.value) {
      isEnabled.value = true;
      await prefs.setBool(_kEnabledKey, true);
    }
    if (changed && (isAvailable.value || isLoading.value)) {
      await _exclusive(_unloadBackend);
    }
    if (!isEnabled.value) return;
    // Reload the new model only if we're meant to be resident (i.e. not
    // currently suppressed by save-memory + cloud).
    if (!suppressedByCloud.value) {
      await _exclusive(_load);
    }
  }

  /// Persist the user's local-model opt-in. Enabling keeps the existing
  /// cloud-priority residency policy; disabling unloads and prevents fallback
  /// loads until the user turns it back on.
  Future<void> setEnabled(bool value) async {
    if (!isSupportedOnHost) {
      await _disableOnUnsupportedHost();
      return;
    }
    final changed = isEnabled.value != value;
    if (changed) {
      isEnabled.value = value;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabledKey, value);
    }
    if (!value) {
      error.value = null;
      if (isAvailable.value || isLoading.value) {
        Log.i('🧠 [LocalLLM] disabled by user → unloading');
        await _exclusive(_unloadBackend);
      }
      return;
    }
    if (!suppressedByCloud.value) {
      await _exclusive(_load);
    }
  }

  /// Toggle "save memory" mode. Persists + lets the coordinator re-apply
  /// residency immediately.
  Future<void> setSaveMemory(bool value) async {
    if (saveMemory.value == value) return;
    saveMemory.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSaveMemoryKey, value);
  }

  /// Re-scan the cache and mark every model whose GGUF is fully present.
  /// Drives the "downloaded" state of each row + the switch dropdown.
  Future<void> refreshDownloadedKeys() async {
    if (!isSupportedOnHost) {
      downloadedKeys.clear();
      return;
    }
    final cacheRoot = await modelCacheDirectoryPath();
    final present = <String>{};
    for (final option in LlmModelOption.all) {
      final source = ModelSource.parse(option.source);
      if (await _cachedModelFile(source, cacheRoot) != null) {
        present.add(option.key);
      }
    }
    downloadedKeys.assignAll(present);
  }

  /// Download (but do not activate) a single model's GGUF to the shared cache.
  ///
  /// Used by the per-model download button in Settings.  Progress + errors are
  /// reported on [downloadProgress] / [downloadError] keyed by [option.key], so
  /// the row can show its own bar and a retry button independent of the active
  /// model's load lifecycle.  On success the key lands in [downloadedKeys] and
  /// becomes selectable in the switch dropdown.
  Future<void> downloadModel(LlmModelOption option) async {
    if (!isSupportedOnHost) {
      downloadError[option.key] = _unsupportedPlatformMessage;
      return;
    }
    if (downloadingKey.value != null) return; // one download at a time
    if (downloadedKeys.contains(option.key)) return;
    downloadingKey.value = option.key;
    downloadError.remove(option.key);
    downloadProgress[option.key] = 0;
    downloadReceivedBytes[option.key] = 0;
    downloadTotalBytes[option.key] = 0;
    downloadEtaSeconds.remove(option.key);
    try {
      final cacheRoot = await modelCacheDirectoryPath();
      final source = ModelSource.parse(option.source);
      final manager = DefaultModelDownloadManager(
        defaultCacheDirectory: cacheRoot,
      );
      final downloadStart = DateTime.now();
      var lastEtaUpdate = downloadStart;
      await manager.ensureModel(
        source,
        options: ModelLoadOptions(cacheDirectory: cacheRoot),
        onProgress: (ModelDownloadProgress p) {
          downloadProgress[option.key] = p.fraction ?? 0;
          downloadReceivedBytes[option.key] = p.receivedBytes;
          if (p.totalBytes != null && p.totalBytes! > 0) {
            downloadTotalBytes[option.key] = p.totalBytes!;
          }
          final now = DateTime.now();
          if (now.difference(lastEtaUpdate).inMilliseconds < 500) return;
          lastEtaUpdate = now;
          final total = p.totalBytes;
          final received = p.receivedBytes;
          final elapsedMs = now.difference(downloadStart).inMilliseconds;
          if (elapsedMs < 1000 ||
              received <= 0 ||
              total == null ||
              total <= received) {
            return;
          }
          final bytesPerSec = received / (elapsedMs / 1000.0);
          if (bytesPerSec <= 0) return;
          downloadEtaSeconds[option.key] = ((total - received) / bytesPerSec)
              .round();
        },
      );
      downloadProgress[option.key] = 1;
      downloadedKeys.add(option.key);
      Log.i('🧠 [LocalLLM] downloaded model: ${option.key}');
    } catch (e, st) {
      Log.e('🧠 [LocalLLM] download failed (${option.key}): $e\n$st');
      downloadError[option.key] = e.toString();
    } finally {
      downloadEtaSeconds.remove(option.key);
      downloadingKey.value = null;
    }
  }

  /// Tear down the native backend (model handle + registered backend).
  Future<void> _unloadBackend() async {
    if (appServices.isRegistered<LocalLLMBackend>()) {
      appServices.delete<LocalLLMBackend>(force: true);
    }
    final b = _backend;
    _backend = null;
    isAvailable.value = false;
    progress.value = 0;
    if (b != null) {
      await b.dispose();
    }
  }

  /// Ensure the local model is up to serve as the cloud fallback, waiting for
  /// an in-flight or freshly-kicked load to finish (up to [timeout]).
  ///
  /// Called from the chat path the moment the cloud is unavailable so the
  /// hand-off is seamless: if the user opted into local, we bring it up and
  /// wait rather than failing the turn with "no local answer brain".
  /// Returns true once the model is available.
  Future<bool> ensureLoadedForFallback({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!isSupportedOnHost) {
      await _disableOnUnsupportedHost();
      return false;
    }
    // Reconcile against the REAL backend, not just the flag: a stale
    // isAvailable=true with no ready backend would otherwise short-circuit here
    // and leave chat with "no answer brain".
    final backend = _backend;
    if (isAvailable.value && (backend?.isReady ?? false)) {
      if (!appServices.isRegistered<LocalLLMBackend>()) {
        appServices.put<LocalLLMBackend>(backend!, permanent: true);
      }
      return true;
    }
    if (!isEnabled.value) return false; // user hasn't opted into local at all
    // The caller invokes this only when the cloud is CONFIRMED unavailable, so
    // local is allowed to run now. Clear any stale cloud-suppression (the
    // coordinator may not have processed the toggle yet) — otherwise _load()
    // would discard itself via its in-flight suppression guard.
    suppressedByCloud.value = false;
    // Serialized load (won't overlap an in-flight unload).  Retries even if a
    // previous attempt errored — _load resets error and tries again.
    final loaded = _exclusive(_load);
    try {
      await loaded.timeout(timeout);
    } on TimeoutException {
      Log.w(
        '🧠 [LocalLLM] fallback load timed out after ${timeout.inSeconds}s',
      );
    } catch (_) {
      /* surfaced via error.value; fall through to the flag check */
    }
    return isAvailable.value && (_backend?.isReady ?? false);
  }

  /// Residency control (called by [LlmModeCoordinator]).
  ///
  /// [resident] = whether the local model should be loaded in RAM right now.
  /// The coordinator computes it as `!saveMemory || !cloudAvailable`:
  ///   * save-memory OFF → always resident.
  ///   * save-memory ON  → resident only while the cloud is unavailable.
  Future<void> applyResident(bool resident) async {
    if (!isSupportedOnHost) {
      await _disableOnUnsupportedHost();
      return;
    }
    suppressedByCloud.value = !resident;
    if (!isEnabled.value) {
      if (isAvailable.value || isLoading.value) {
        Log.i('🧠 [LocalLLM] residency ignored while disabled → unloading');
        await _exclusive(_unloadBackend);
      }
      return;
    }
    if (resident) {
      if (!isAvailable.value) {
        Log.i('🧠 [LocalLLM] residency=on → loading local model');
        // Serialized so it can't overlap an in-flight unload (native wedge).
        await _exclusive(_load);
      }
    } else {
      if (isAvailable.value || isLoading.value) {
        Log.i('🧠 [LocalLLM] residency=off (save-memory + cloud) → unloading');
        await _exclusive(_unloadBackend);
      }
    }
  }

  Future<void> _load({String? modelSource}) async {
    if (!isSupportedOnHost) {
      isEnabled.value = false;
      suppressedByCloud.value = true;
      error.value = _unsupportedPlatformMessage;
      return;
    }
    if (!isEnabled.value) return;
    if (isLoading.value) return;
    // Idempotent: a duplicate load queued behind a successful one is a no-op.
    if (isAvailable.value && (_backend?.isReady ?? false)) return;
    isLoading.value = true;
    error.value = null;
    progress.value = 0;
    receivedBytes.value = 0;
    totalBytes.value = 0;
    etaSeconds.value = null;
    try {
      final backend = LlamadartLLMBackend();

      final source = ModelSource.parse(
        modelSource ?? selectedModel.value.source,
      );
      final cacheDirectory = await modelCacheDirectoryPath();
      final cachedFile = await _cachedModelFile(source, cacheDirectory);
      if (cachedFile != null) {
        final bytes = await cachedFile.length();
        receivedBytes.value = bytes;
        totalBytes.value = bytes;
        progress.value = 1;
        Log.i('🧠 [LocalLLM] loading cached model: ${cachedFile.path}');
        try {
          await backend.loadPath(cachedFile.path);
          if (!isEnabled.value || suppressedByCloud.value) {
            Log.i(
              '🧠 [LocalLLM] local disabled/suppressed mid-load → discarding',
            );
            await backend.dispose();
            return;
          }
          _backend = backend;
          appServices.put<LocalLLMBackend>(backend, permanent: true);
          isAvailable.value = true;
          downloadedKeys.add(selectedModel.value.key);
          Log.i('🧠 [LocalLLM] available from persistent cache');
          // Prime chat + transient filler off the hot path.
          // ignore: unawaited_futures
          backend.warmup();
          // ignore: unawaited_futures
          _cleanupLegacyTempCache();
          return;
        } catch (e) {
          Log.w(
            '🧠 [LocalLLM] cached model load failed, falling back to '
            'network source: $e',
          );
        }
      }
      // Past the cache check — a real network download is about to start.
      // This is the only path that flips [isDownloading], so the download
      // card shows for genuine downloads and stays hidden on cached launches.
      isDownloading.value = true;
      final downloadStart = DateTime.now();
      DateTime lastEtaUpdate = downloadStart;
      await backend.load(
        source,
        cacheDirectory: cacheDirectory,
        onProgress: (ModelDownloadProgress p) {
          progress.value = p.fraction ?? -1;
          receivedBytes.value = p.receivedBytes;
          if (p.totalBytes != null && p.totalBytes! > 0) {
            totalBytes.value = p.totalBytes!;
          }
          final now = DateTime.now();
          if (now.difference(lastEtaUpdate).inMilliseconds < 500) return;
          lastEtaUpdate = now;
          final elapsedMs = now.difference(downloadStart).inMilliseconds;
          final received = p.receivedBytes;
          final total = p.totalBytes;
          if (elapsedMs < 1000 ||
              received <= 0 ||
              total == null ||
              total <= received) {
            return;
          }
          final bytesPerSec = received / (elapsedMs / 1000.0);
          if (bytesPerSec <= 0) return;
          final remainingBytes = total - received;
          etaSeconds.value = (remainingBytes / bytesPerSec).round();
        },
      );
      if (!isEnabled.value || suppressedByCloud.value) {
        Log.i(
          '🧠 [LocalLLM] local disabled/suppressed mid-download → discarding',
        );
        await backend.dispose();
        return;
      }
      _backend = backend;
      appServices.put<LocalLLMBackend>(backend, permanent: true);
      isAvailable.value = true;
      downloadedKeys.add(selectedModel.value.key);
      Log.i('🧠 [LocalLLM] available — local chat/filler ready');
      // Prime chat + transient filler off the hot path.
      // ignore: unawaited_futures
      backend.warmup();
      // ignore: unawaited_futures
      _cleanupLegacyTempCache();
    } catch (e, st) {
      Log.e('🧠 [LocalLLM] load failed: $e\n$st');
      error.value = e.toString();
      await _backend?.dispose();
      _backend = null;
      isAvailable.value = false;
    } finally {
      isLoading.value = false;
      isDownloading.value = false;
    }
  }

  Future<void> warmupFiller() async {
    final backend = _backend;
    if (backend == null || !isAvailable.value) return;
    await backend.warmupFillerOnly();
  }

  Future<void> _disableOnUnsupportedHost({
    SharedPreferences? prefs,
    bool unload = true,
  }) async {
    isEnabled.value = false;
    suppressedByCloud.value = true;
    error.value = _unsupportedPlatformMessage;
    final storage = prefs ?? await SharedPreferences.getInstance();
    if (storage.getBool(_kEnabledKey) == true) {
      await storage.setBool(_kEnabledKey, false);
    }
    if (unload && (isAvailable.value || isLoading.value || _backend != null)) {
      await _exclusive(_unloadBackend);
    }
  }

  Future<String> modelCacheDirectoryPath() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, modelCacheDirName);
  }

  Future<File?> _cachedModelFile(ModelSource source, String cacheRoot) async {
    final direct = File(
      p.join(cacheRoot, source.cacheDirectoryName, source.fileName),
    );
    if (await _looksCompleteModelFile(direct)) return direct;

    final root = Directory(cacheRoot);
    if (!await root.exists()) return null;
    try {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (p.basename(entity.path) != source.fileName) continue;
        if (await _looksCompleteModelFile(entity)) return entity;
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _looksCompleteModelFile(File file) async {
    if (!await file.exists()) return false;
    if (file.path.endsWith('.part') || file.path.endsWith('.download')) {
      return false;
    }
    final bytes = await file.length();
    // Avoid trying to load a failed tiny/partial response as GGUF.
    return bytes > 100 * 1024 * 1024;
  }

  Future<void> _cleanupLegacyTempCache() async {
    final legacy = Directory(
      p.join(Directory.systemTemp.path, 'llamadart', 'models'),
    );
    try {
      if (!await legacy.exists()) return;
      await legacy.delete(recursive: true);
      Log.i('🧠 [LocalLLM] removed legacy temp cache: ${legacy.path}');
    } catch (e) {
      Log.w('🧠 [LocalLLM] failed to remove legacy temp cache: $e');
    }
  }
}
