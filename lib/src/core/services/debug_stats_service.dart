import 'dart:io';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:maaso/src/core/services/delayed_choice_executor.dart';
import 'package:maaso/src/core/services/entangled_memory_service.dart';
import 'package:maaso/src/core/services/intent_wave_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/sherpa_model_registry.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/services/tts_warmup_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/core/utils/byte_format.dart';

class DebugStatsService {
  static Future<Map<String, dynamic>> collect() async {
    final docs = await getApplicationDocumentsDirectory();
    final temp = await getTemporaryDirectory();
    final llmCache = Directory(
      p.join(docs.path, LocalLLMService.modelCacheDirName),
    );
    final legacyLlmTempCache = Directory(
      p.join(Directory.systemTemp.path, 'llamadart', 'models'),
    );
    final sherpaRoot = Directory(p.join(docs.path, 'sherpa_models'));
    final dbFile = File(p.join(docs.path, 'maaso.db'));

    final modelRows = <Map<String, String>>[
      {
        'label': 'Local model',
        'value': formatBytes(await _dirSize(llmCache)),
        'detail': _localLlmDetail(llmCache.path),
      },
      await _sherpaModelRow(
        label: 'TTS model',
        model: SherpaModelRegistry.supertonicTts,
        sherpaRoot: sherpaRoot,
        status: _ttsStatus(),
      ),
      await _sherpaModelRow(
        label: 'VAD model',
        model: SherpaModelRegistry.sileroVad,
        sherpaRoot: sherpaRoot,
        status: _vadStatus(),
      ),
    ];

    final storageRows = <Map<String, String>>[
      {
        'label': 'Documents',
        'value': formatBytes(await _dirSize(docs)),
        'detail': docs.path,
      },
      {
        'label': 'DB',
        'value': formatBytes(await _fileSize(dbFile)),
        'detail': dbFile.path,
      },
      {
        'label': 'Secure storage',
        'value': appServices.isRegistered<SecureStorageService>()
            ? 'Registered'
            : 'Unavailable',
        'detail': 'Platform keychain / encrypted shared preferences',
      },
      {
        'label': 'Temp',
        'value': formatBytes(await _dirSize(temp)),
        'detail': temp.path,
      },
      {
        'label': 'Legacy temp LLM cache',
        'value': formatBytes(await _dirSize(legacyLlmTempCache)),
        'detail': legacyLlmTempCache.path,
      },
    ];

    final runtimeRows = <Map<String, String>>[
      {
        'label': 'Process RSS',
        'value': formatBytes(ProcessInfo.currentRss),
        'detail': 'Current resident memory',
      },
    ];

    final entangledMemory = appServices.isRegistered<EntangledMemoryService>()
        ? await appServices.find<EntangledMemoryService>().stats()
        : null;
    final delayedChoice = appServices.isRegistered<DelayedChoiceExecutor>()
        ? appServices.find<DelayedChoiceExecutor>().toDebugMap()
        : null;

    return {
      'model_rows': modelRows,
      'storage_rows': storageRows,
      'runtime_rows': runtimeRows,
      'rows': [...modelRows, ...storageRows, ...runtimeRows],
      if (appServices.isRegistered<IntentWaveService>())
        'intent_wave': appServices.find<IntentWaveService>().toDebugMap(),
      if (entangledMemory != null) 'entangled_memory': entangledMemory,
      if (delayedChoice != null) 'delayed_choice': delayedChoice,
      'note':
          'LLM downloads now persist under Documents/${LocalLLMService.modelCacheDirName}. '
          'The legacy temp cache is shown because older runs used that volatile path.',
    };
  }

  static Future<Map<String, String>> _sherpaModelRow({
    required String label,
    required SherpaModel model,
    required Directory sherpaRoot,
    required String status,
  }) async {
    final dir = Directory(p.join(sherpaRoot.path, model.id));
    return {
      'label': label,
      'value': formatBytes(await _dirSize(dir)),
      'detail': '${model.displayName} · $status\n${dir.path}',
    };
  }

  static String _localLlmDetail(String path) {
    if (!appServices.isRegistered<LocalLLMService>()) {
      return 'Service unavailable\n$path';
    }
    final llm = appServices.find<LocalLLMService>();
    final model = llm.selectedModel.value;
    final status = _localLlmStatus(llm, model.key);
    return '${model.label.tr} · ${model.approxLabel} · $status\n$path';
  }

  static String _localLlmStatus(LocalLLMService llm, String key) {
    if (llm.downloadingKey.value == key) {
      return 'Downloading ${_percent(llm.downloadProgress[key] ?? 0)}';
    }
    if (llm.isDownloading.value) {
      return 'Downloading ${_percent(llm.progress.value)}';
    }
    if (llm.isLoading.value) return 'Loading';
    if (llm.isActive) return 'Active';
    if (llm.suppressedByCloud.value) return 'Save-memory standby';
    if (llm.isAvailable.value) return 'Ready';
    if (llm.downloadedKeys.contains(key)) return 'Downloaded';
    final error = llm.downloadError[key] ?? llm.error.value;
    if (error != null && error.isNotEmpty) return 'Error';
    return 'Missing';
  }

  static String _ttsStatus() {
    final tts = appServices.isRegistered<SherpaNeuralTts>()
        ? appServices.find<SherpaNeuralTts>()
        : null;
    final warmup = appServices.isRegistered<TtsWarmupService>()
        ? appServices.find<TtsWarmupService>()
        : null;
    if (tts == null) return 'Service unavailable';
    if (!tts.enabled.value) return 'Disabled';
    if (warmup?.isDownloading.value == true || tts.isDownloading.value) {
      final progress = warmup?.progress.value ?? tts.downloadProgress.value;
      return 'Downloading ${_percent(progress)}';
    }
    if (warmup?.isRunning.value == true || tts.isLoading.value) {
      return 'Loading';
    }
    if (warmup?.isFailed.value == true || tts.error.value != null) {
      return 'Error';
    }
    if (warmup?.isReady.value == true || tts.isReady.value) return 'Ready';
    return 'Missing';
  }

  static String _vadStatus() {
    if (!appServices.isRegistered<VadService>()) return 'Service unavailable';
    final vad = appServices.find<VadService>();
    if (vad.isDownloading.value) {
      return 'Downloading ${_percent(vad.downloadProgress.value)}';
    }
    if (vad.isLoading.value) return 'Loading';
    if (vad.error.value != null) return 'Error';
    if (vad.isReady.value) return 'Ready';
    return 'Missing';
  }

  static String _percent(double value) {
    final normalized = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    return '${(normalized * 100).round()}%';
  }

  static Future<int> _fileSize(File file) async {
    try {
      return await file.exists() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }
}
