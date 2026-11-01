import 'dart:async';

import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_card_controller.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/widgets/agent_cards.dart';
import 'package:maaso/src/core/services/advanced_feature_service.dart';
import 'package:maaso/src/core/services/agent_pipeline_runtime_service.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/tts_warmup_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';

/// Orchestrates the first-launch chat ceremony.
///
/// Concretely it owns side-effects that used to be scattered across
/// onboarding / soul-interview / settings:
///
///   1. **Loading-state reactive surface** — UI binds head-bubble indicators
///      to [llmLoading] / [voiceLoading] / [bootBlocking].
///   2. **Name-ask flow** — after voice is ready and the agent has no
///      nickname yet, the agent opens with "give me a name?", intercepts the
///      next user message as the candidate, and pushes a confirm card via
///      [AgentCardController].
///
/// Wiring contract — [HomeController.send] must call
/// [tryInterceptUserMessage] *before* persisting / running the runtime.
class AgentBootController extends AppController {
  AgentBootController({
    Future<void> Function()? fallbackStop,
    this.presentationReady,
    this.presentationChanges,
  }) : _fallbackStopOverride = fallbackStop;

  /// Defers the automatic opening line while the avatar is entering the device.
  /// Explicit user replies and background model preparation keep their lifecycle.
  final bool Function()? presentationReady;
  final Listenable? presentationChanges;

  // Mirrors of the underlying services — exposed so widgets don't have to
  // know which concrete service holds the flag.
  final RxBool llmLoading = false.obs;
  final RxBool voiceLoading = false.obs;
  final RxBool llmReady = false.obs;
  final RxBool voiceReady = false.obs;
  final RxBool llmFailed = false.obs;
  final RxBool voiceFailed = false.obs;
  final RxnString llmError = RxnString();
  final RxnString voiceError = RxnString();

  // Download progress mirrors — drive the rich bubble UI (percentage,
  // bytes, ETA, progress bar).  -1 in [llmProgress] / [voiceProgress] means
  // "indeterminate" (size unknown yet).
  final RxDouble llmProgress = 0.0.obs;
  final RxDouble voiceProgress = 0.0.obs;
  final RxInt llmReceivedBytes = 0.obs;
  final RxInt voiceReceivedBytes = 0.obs;
  final RxInt llmTotalBytes = 0.obs;
  final RxInt voiceTotalBytes = 0.obs;
  final RxnInt llmEtaSeconds = RxnInt();
  final RxnInt voiceEtaSeconds = RxnInt();

  final RxBool vadLoading = false.obs;
  final RxBool vadFailed = false.obs;
  final RxnString vadError = RxnString();
  final RxDouble vadProgress = 0.0.obs;
  final RxInt vadReceivedBytes = 0.obs;
  final RxInt vadTotalBytes = 0.obs;
  final RxnInt vadEtaSeconds = RxnInt();

  /// Aggregated first-use model preparation status. Downloads may run in
  /// parallel, but the home UI shows one calm progress bar.
  final RxBool modelLoading = false.obs;
  final RxBool modelFailed = false.obs;
  final RxnString modelError = RxnString();
  final RxDouble modelProgress = 0.0.obs;
  final RxInt modelReceivedBytes = 0.obs;
  final RxInt modelTotalBytes = 0.obs;
  final RxnInt modelEtaSeconds = RxnInt();

  /// True only while the voice path is unavailable enough that boot should
  /// answer with system TTS. The combined model downloads are background work
  /// and must not block text chat for a large local-LLM file download.
  bool get bootBlocking => voiceLoading.value;

  /// True iff the agent just asked for a name and is waiting for the user's
  /// next message to be the candidate (which we route into a confirm card
  /// instead of the runtime).
  final RxBool awaitingName = false.obs;

  /// Hook the boot controller uses to *speak* through the chat UI.  Set by
  /// [HomeController.onReady] so this controller can update the floating
  /// bubble + persist messages without importing HomeController directly.
  void Function(String text)? say;

  // ──────────── private ────────────
  final FlutterTts _fallbackTts = FlutterTts();
  MaasoTtsPlugin? _fallbackSpeech;
  final Future<void> Function()? _fallbackStopOverride;
  final Set<Future<void>> _inFlightSystemSpeech = <Future<void>>{};
  Future<void>? _shutdownFuture;
  bool _retiring = false;
  bool _fallbackStopped = false;
  bool _nameAskedOnce = false;
  bool _presentationListenerAttached = false;
  Worker? _llmLoadingWatcher;
  Worker? _llmAvailableWatcher;
  Worker? _llmErrorWatcher;
  Worker? _llmProgressWatcher;
  Worker? _llmReceivedWatcher;
  Worker? _llmTotalWatcher;
  Worker? _llmEtaWatcher;
  Worker? _llmDownloadKeyWatcher;
  Worker? _llmDownloadProgressWatcher;
  Worker? _llmDownloadReceivedWatcher;
  Worker? _llmDownloadTotalWatcher;
  Worker? _llmDownloadEtaWatcher;
  Worker? _llmDownloadErrorWatcher;
  Worker? _cloudKeyWatcher;
  Worker? _cloudEnabledWatcher;
  Worker? _cloudHealthWatcher;
  Worker? _voiceReadyWatcher;
  Worker? _voiceRunningWatcher;
  Worker? _voiceFailedWatcher;
  Worker? _voiceErrorWatcher;
  Worker? _voiceProgressWatcher;
  Worker? _voiceReceivedWatcher;
  Worker? _voiceTotalWatcher;
  Worker? _voiceEtaWatcher;
  Worker? _vadLoadingWatcher;
  Worker? _vadFailedWatcher;
  Worker? _vadErrorWatcher;
  Worker? _vadProgressWatcher;
  Worker? _vadReceivedWatcher;
  Worker? _vadTotalWatcher;
  Worker? _vadEtaWatcher;
  Worker? _profileWatcher;
  bool _bootLoadsScheduled = false;

  @override
  void onInit() {
    super.onInit();
    if (!_retiring && !_presentationListenerAttached) {
      presentationChanges?.addListener(_handlePresentationChanged);
      _presentationListenerAttached = presentationChanges != null;
    }
    _wireLocalLlm();
    _wireCloudLlm();
    _wireVoice();
    _wireVad();
    _wireProfile();
  }

  /// Re-evaluate the name prompt whenever the agent profile changes — most
  /// importantly the async DB load that flips `isInitialized` true and
  /// populates `profile.value`.  Without this, a name persisted from a
  /// previous session is invisible at the moment voice/LLM report ready, and
  /// the onboarding "what should you call me?" prompt fires every launch.
  void _wireProfile() {
    if (!appServices.isRegistered<AgentCoreController>()) return;
    final core = appServices.find<AgentCoreController>();
    _profileWatcher = ever<AgentProfile?>(core.profile, (_) => _maybeAskName());
    // If the profile already loaded before we wired up, check now.
    if (core.isInitialized.value) _maybeAskName();
  }

  /// Idempotent — safe to call from home page initState. Default Maaso uses
  /// hosted services plus platform ASR, so boot only syncs existing model state;
  /// local model downloads are explicit Advanced Features actions.
  void boot() {
    // Home binds [say] immediately before calling boot. Re-check here because
    // hosted LLM/TTS readiness may have arrived while this controller was
    // being registered, before a chat surface existed to receive the prompt.
    _maybeAskName();
    if (_bootLoadsScheduled) return;
    _bootLoadsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _startBootLoads());
  }

  void _startBootLoads() {
    if (appServices.isRegistered<AdvancedFeatureService>() &&
        !appServices.find<AdvancedFeatureService>().enabled.value) {
      _recomputeModelDownload();
      return;
    }
    _recomputeModelDownload();
  }

  // ──────────── chat-pipeline hook ────────────

  /// Called by [HomeController.send] before the user message is persisted.
  /// Returns true when the boot controller fully handled the input — the
  /// caller should skip its normal pipeline (no DB write, no runtime call).
  bool tryInterceptUserMessage(String text) {
    // Name-confirmation flow has priority over the loading guard so users
    // can complete onboarding even while LLM is still loading.
    if (awaitingName.value) {
      _proposeName(text);
      return true;
    }
    if (bootBlocking) {
      _replyDuringLoad();
      return true;
    }
    return false;
  }

  // ──────────── wiring ────────────

  void _wireLocalLlm() {
    if (!appServices.isRegistered<LocalLLMService>()) return;
    final llm = appServices.find<LocalLLMService>();
    // Card / bootBlocking key off *download* (not cache-load) so they don't
    // flash on every cold start once the model is already on disk.
    llmLoading.value = llm.isDownloading.value;
    llmReady.value = llm.isAvailable.value;
    llmError.value = llm.error.value;
    llmFailed.value = llm.error.value != null && !llm.isAvailable.value;
    llmProgress.value = llm.progress.value;
    llmReceivedBytes.value = llm.receivedBytes.value;
    llmTotalBytes.value = llm.totalBytes.value;
    llmEtaSeconds.value = llm.etaSeconds.value;
    _llmLoadingWatcher = ever<bool>(llm.isDownloading, (v) {
      llmLoading.value = v;
      _recomputeModelDownload();
    });
    _llmAvailableWatcher = ever<bool>(llm.isAvailable, (v) {
      llmReady.value = v;
      if (v) llmFailed.value = false;
      _maybeAskName();
    });
    _llmErrorWatcher = ever<String?>(llm.error, (e) {
      llmError.value = e;
      llmFailed.value = e != null && !llm.isAvailable.value;
      _recomputeModelDownload();
    });
    _llmProgressWatcher = ever<double>(llm.progress, (v) {
      llmProgress.value = v;
      _recomputeModelDownload();
    });
    _llmReceivedWatcher = ever<int>(llm.receivedBytes, (v) {
      llmReceivedBytes.value = v;
      _recomputeModelDownload();
    });
    _llmTotalWatcher = ever<int>(llm.totalBytes, (v) {
      llmTotalBytes.value = v;
      _recomputeModelDownload();
    });
    _llmEtaWatcher = ever<int?>(llm.etaSeconds, (v) {
      llmEtaSeconds.value = v;
      _recomputeModelDownload();
    });
    _llmDownloadKeyWatcher = ever<String?>(llm.downloadingKey, (_) {
      _syncLlmDownloadMirror(llm);
      _recomputeModelDownload();
    });
    _llmDownloadProgressWatcher = ever<Map<String, double>>(
      llm.downloadProgress,
      (_) {
        _syncLlmDownloadMirror(llm);
        _recomputeModelDownload();
      },
    );
    _llmDownloadReceivedWatcher = ever<Map<String, int>>(
      llm.downloadReceivedBytes,
      (_) {
        _syncLlmDownloadMirror(llm);
        _recomputeModelDownload();
      },
    );
    _llmDownloadTotalWatcher = ever<Map<String, int>>(llm.downloadTotalBytes, (
      _,
    ) {
      _syncLlmDownloadMirror(llm);
      _recomputeModelDownload();
    });
    _llmDownloadEtaWatcher = ever<Map<String, int>>(llm.downloadEtaSeconds, (
      _,
    ) {
      _syncLlmDownloadMirror(llm);
      _recomputeModelDownload();
    });
    _llmDownloadErrorWatcher = ever<Map<String, String>>(llm.downloadError, (
      _,
    ) {
      _syncLlmDownloadMirror(llm);
      _recomputeModelDownload();
    });
    _syncLlmDownloadMirror(llm);
    _recomputeModelDownload();
  }

  void _wireCloudLlm() {
    if (appServices.isRegistered<LLMConfigController>()) {
      final config = appServices.find<LLMConfigController>();
      _cloudKeyWatcher = ever<String>(config.apiKey, (_) => _maybeAskName());
      _cloudEnabledWatcher = ever<bool>(
        config.cloudEnabled,
        (_) => _maybeAskName(),
      );
    }
    if (appServices.isRegistered<CloudLLMHealthService>()) {
      _cloudHealthWatcher = ever<CloudLLMHealth>(
        appServices.find<CloudLLMHealthService>().health,
        (_) => _maybeAskName(),
      );
    }
    _maybeAskName();
  }

  void _wireVoice() {
    if (!appServices.isRegistered<TtsWarmupService>()) {
      final pipeline = appServices.maybeFind<AgentPipelineRuntimeService>();
      if (pipeline == null) return;
      voiceReady.value = pipeline.proxyTtsReady.value;
      _voiceReadyWatcher = ever<bool>(pipeline.proxyTtsReady, (ready) {
        voiceReady.value = ready;
        if (ready) {
          voiceFailed.value = false;
          _maybeAskName();
        }
      });
      if (pipeline.proxyTtsReady.value) _maybeAskName();
      return;
    }
    final tts = appServices.find<TtsWarmupService>();
    // Card / bootBlocking key off *download* (not warm-up/cache-load) so they
    // don't flash on every cold start once the model is already on disk.
    voiceLoading.value = tts.isDownloading.value;
    voiceReady.value = tts.isReady.value;
    voiceFailed.value = tts.isFailed.value;
    voiceError.value = tts.error.value;
    _voiceRunningWatcher = ever<bool>(tts.isDownloading, (v) {
      voiceLoading.value = v;
      _recomputeModelDownload();
    });
    _voiceReadyWatcher = ever<bool>(tts.isReady, (v) {
      voiceReady.value = v;
      if (v) {
        voiceFailed.value = false;
        _maybeAskName();
      }
    });
    _voiceFailedWatcher = ever<bool>(tts.isFailed, (v) {
      voiceFailed.value = v;
      _recomputeModelDownload();
    });
    _voiceErrorWatcher = ever<String?>(tts.error, (e) {
      voiceError.value = e;
      _recomputeModelDownload();
    });
    voiceProgress.value = tts.progress.value;
    voiceReceivedBytes.value = tts.downloadedBytes.value;
    voiceTotalBytes.value = tts.totalBytes.value;
    voiceEtaSeconds.value = tts.etaSeconds.value;
    _voiceProgressWatcher = ever<double>(tts.progress, (v) {
      voiceProgress.value = v;
      _recomputeModelDownload();
    });
    _voiceReceivedWatcher = ever<int>(tts.downloadedBytes, (v) {
      voiceReceivedBytes.value = v;
      _recomputeModelDownload();
    });
    _voiceTotalWatcher = ever<int>(tts.totalBytes, (v) {
      voiceTotalBytes.value = v;
      _recomputeModelDownload();
    });
    _voiceEtaWatcher = ever<int?>(tts.etaSeconds, (v) {
      voiceEtaSeconds.value = v;
      _recomputeModelDownload();
    });
    // Edge case: tts was already ready before we wired up (warm-up finished
    // during main init, before home built).  Fire the side-effects now.
    if (tts.isReady.value) {
      _maybeAskName();
    }
  }

  void _wireVad() {
    if (!appServices.isRegistered<VadService>()) return;
    final vad = appServices.find<VadService>();
    vadLoading.value = vad.isDownloading.value;
    vadFailed.value = vad.error.value != null && !vad.isReady.value;
    vadError.value = vad.error.value;
    vadProgress.value = vad.downloadProgress.value;
    vadReceivedBytes.value = vad.receivedBytes.value;
    vadTotalBytes.value = vad.totalBytes.value;
    vadEtaSeconds.value = vad.etaSeconds.value;
    _vadLoadingWatcher = ever<bool>(vad.isDownloading, (v) {
      vadLoading.value = v;
      _recomputeModelDownload();
    });
    _vadErrorWatcher = ever<String?>(vad.error, (e) {
      vadError.value = e;
      vadFailed.value = e != null && !vad.isReady.value;
      _recomputeModelDownload();
    });
    _vadFailedWatcher = ever<bool>(vad.isReady, (v) {
      if (v) vadFailed.value = false;
      _recomputeModelDownload();
    });
    _vadProgressWatcher = ever<double>(vad.downloadProgress, (v) {
      vadProgress.value = v;
      _recomputeModelDownload();
    });
    _vadReceivedWatcher = ever<int>(vad.receivedBytes, (v) {
      vadReceivedBytes.value = v;
      _recomputeModelDownload();
    });
    _vadTotalWatcher = ever<int>(vad.totalBytes, (v) {
      vadTotalBytes.value = v;
      _recomputeModelDownload();
    });
    _vadEtaWatcher = ever<int?>(vad.etaSeconds, (v) {
      vadEtaSeconds.value = v;
      _recomputeModelDownload();
    });
    _recomputeModelDownload();
  }

  void _syncLlmDownloadMirror(LocalLLMService llm) {
    final key = llm.downloadingKey.value;
    if (key == null) {
      llmLoading.value = llm.isDownloading.value;
      llmProgress.value = llm.progress.value;
      llmReceivedBytes.value = llm.receivedBytes.value;
      llmTotalBytes.value = llm.totalBytes.value;
      llmEtaSeconds.value = llm.etaSeconds.value;
      final downloadError = llm.downloadError[llm.selectedModel.value.key];
      llmError.value = downloadError ?? llm.error.value;
      llmFailed.value =
          downloadError != null ||
          (llm.error.value != null && !llm.isAvailable.value);
      return;
    }
    llmLoading.value = true;
    llmProgress.value = llm.downloadProgress[key] ?? 0;
    llmReceivedBytes.value = llm.downloadReceivedBytes[key] ?? 0;
    llmTotalBytes.value = llm.downloadTotalBytes[key] ?? 0;
    llmEtaSeconds.value = llm.downloadEtaSeconds[key];
    llmError.value = llm.downloadError[key] ?? llm.error.value;
    llmFailed.value = llm.downloadError[key] != null;
  }

  void _recomputeModelDownload() {
    final tasks = <_ModelDownloadTask>[
      if (llmLoading.value)
        _ModelDownloadTask(
          progress: llmProgress.value,
          receivedBytes: llmReceivedBytes.value,
          totalBytes: llmTotalBytes.value,
          etaSeconds: llmEtaSeconds.value,
        ),
      if (voiceLoading.value)
        _ModelDownloadTask(
          progress: voiceProgress.value,
          receivedBytes: voiceReceivedBytes.value,
          totalBytes: voiceTotalBytes.value,
          etaSeconds: voiceEtaSeconds.value,
        ),
      if (vadLoading.value)
        _ModelDownloadTask(
          progress: vadProgress.value,
          receivedBytes: vadReceivedBytes.value,
          totalBytes: vadTotalBytes.value,
          etaSeconds: vadEtaSeconds.value,
        ),
    ];
    modelLoading.value = tasks.isNotEmpty;
    if (tasks.isEmpty) {
      modelReceivedBytes.value = 0;
      modelTotalBytes.value = 0;
      modelProgress.value = 0;
      modelEtaSeconds.value = null;
    } else {
      final total = tasks.fold<int>(0, (sum, t) => sum + t.effectiveTotal);
      final received = tasks.fold<int>(
        0,
        (sum, t) => sum + t.effectiveReceived,
      );
      modelTotalBytes.value = total;
      modelReceivedBytes.value = received.clamp(0, total).toInt();
      modelProgress.value = total > 0 ? (received / total).clamp(0.0, 1.0) : -1;
      final etas = tasks
          .map((t) => t.etaSeconds)
          .whereType<int>()
          .where((v) => v > 0)
          .toList();
      modelEtaSeconds.value = etas.isEmpty
          ? null
          : etas.reduce((a, b) => a > b ? a : b);
    }

    modelFailed.value = llmFailed.value || voiceFailed.value || vadFailed.value;
    modelError.value = llmError.value ?? voiceError.value ?? vadError.value;
  }

  // ──────────── retry hooks ────────────

  Future<void> retryVad() async {
    if (!appServices.isRegistered<VadService>()) return;
    vadFailed.value = false;
    vadError.value = null;
    try {
      await appServices.find<VadService>().ensureReady();
    } catch (_) {}
  }

  /// Re-kick the neural TTS warm-up after a download/handshake failure.
  /// Safe to call any time — the underlying service no-ops when already
  /// running or ready.
  Future<void> retryVoice() async {
    if (!appServices.isRegistered<TtsWarmupService>()) return;
    voiceFailed.value = false;
    voiceError.value = null;
    await appServices.find<TtsWarmupService>().retry();
  }

  /// Re-kick the on-device LLM download/load after a failure (network drop,
  /// llama.cpp context init crash, etc).  Idempotent.
  Future<void> retryLlm() async {
    if (!appServices.isRegistered<LocalLLMService>()) return;
    final llm = appServices.find<LocalLLMService>();
    llmFailed.value = false;
    llmError.value = null;
    if (!llm.downloadedKeys.contains(llm.selectedModel.value.key)) {
      await llm.downloadModel(llm.selectedModel.value);
      return;
    }
    if (llm.isAvailable.value || llm.isLoading.value) return;
    await llm.applyResident(true);
  }

  // ──────────── side-effects ────────────

  void _handlePresentationChanged() {
    if (!_retiring) _maybeAskName();
  }

  void _maybeAskName() {
    if (_retiring || !(presentationReady?.call() ?? true)) return;
    if (_nameAskedOnce) return;
    final say = this.say;
    // The account runtime is mounted before HomeController binds its chat
    // surface. Never latch the ceremony until the opening line can be shown.
    if (say == null) return;
    // Only ask when voice is ready — otherwise we'd speak with the fallback
    // voice and immediately switch mid-conversation, which feels glitchy.
    if (!voiceReady.value) return;
    // Do not run the fixed name-card flow until at least one brain can answer
    // the turns that follow. Otherwise an offline first launch can collect a
    // name into UI-only state and the later LLM identity interview asks again.
    if (!_hasCallableBrain()) return;
    final core = appServices.isRegistered<AgentCoreController>()
        ? appServices.find<AgentCoreController>()
        : null;
    // CRITICAL: the profile loads from the DB asynchronously, independently of
    // when voice/LLM report ready (the triggers for this method).  If the
    // profile isn't loaded yet, `nickname` reads as '' — indistinguishable
    // from "no name set" — and we'd wrongly ask for a name the user already
    // chose.  So bail WITHOUT latching `_nameAskedOnce`; the profile watcher
    // (`_wireProfile`) re-invokes us the moment the real profile lands.
    if (core == null ||
        !core.isInitialized.value ||
        core.profile.value == null) {
      return;
    }
    final nickname = core.profile.value!.nickname.trim();
    if (nickname.isNotEmpty) return;
    _nameAskedOnce = true;
    awaitingName.value = true;
    final line = 'boot.ask_name'.tr;
    say(line);
    _speakNeural(line);
  }

  bool _hasCallableBrain() {
    final hostedReady = appServices
        .maybeFind<AgentPipelineRuntimeService>()
        ?.proxyTtsReady
        .value;
    if (hostedReady ?? false) return true;
    final localReady =
        appServices.isRegistered<LocalLLMService>() &&
        appServices.find<LocalLLMService>().isAvailable.value;
    if (localReady) return true;
    if (!appServices.isRegistered<LLMConfigController>()) return false;
    if (!appServices.find<LLMConfigController>().cloudUsable) return false;
    if (!appServices.isRegistered<CloudLLMHealthService>()) return true;
    return appServices.find<CloudLLMHealthService>().cloudPermittedForRouting;
  }

  void _proposeName(String text) {
    final candidate = text.trim();
    if (candidate.isEmpty) return;
    if (!appServices.isRegistered<AgentCardController>()) return;
    appServices.find<AgentCardController>().push(
      AgentCards.confirmName(
        candidate: candidate,
        onConfirm: () => _confirmName(candidate),
        onBack: () => _retryAsk(),
      ),
    );
  }

  Future<void> _confirmName(String name) {
    final registry = appServices.maybeFind<AgentRuntimeRegistry>();
    if (registry == null) return _confirmNameActive(name);
    return registry.runAccountOperation(() => _confirmNameActive(name));
  }

  Future<void> _confirmNameActive(String name) async {
    if (!appServices.isRegistered<AgentCoreController>()) return;
    final core = appServices.find<AgentCoreController>();
    final profile = core.profile.value;
    if (profile == null) return;
    profile.nickname = name;
    await core.updateProfile(profile);
    if (appServices.isRegistered<SoulService>()) {
      final soul = appServices.find<SoulService>();
      await soul.update(name: name, gender: profile.gender);
      soul.lockGender();
    }
    awaitingName.value = false;
    final line = 'boot.name_confirmed'.trParams({'name': name});
    say?.call(line);
    _speakNeural(line);
  }

  void _retryAsk() {
    final line = 'boot.retry_name'.tr;
    say?.call(line);
    _speakNeural(line);
  }

  /// Fixed reply spoken with system TTS — used while models are loading.
  /// Doesn't touch the runtime or DB chat history (no need to pollute the
  /// agent's memory with system stalling messages).
  void _replyDuringLoad() {
    final line = 'boot.model_loading'.tr;
    say?.call(line);
    _speakSystem(line);
  }

  /// Public hook for other controllers that produced a reply themselves
  /// (e.g. the cloud-key-missing fallback in [HomeController]) and want it
  /// spoken with the best available voice.  Picks neural TTS once
  /// [voiceReady] is true, otherwise falls back to system TTS.
  void speakBubble(String text) {
    if (text.trim().isEmpty) return;
    appServices
        .maybeFind<AgentReplyPresentationService>()
        ?.presentStandaloneReply(text);
    if (voiceReady.value) {
      _speakNeural(text);
    } else {
      _speakSystem(text);
    }
  }

  // ──────────── tts plumbing ────────────

  /// Speak via the Supertonic neural engine. Caller is
  /// responsible for only calling this when [voiceReady] is true.
  void _speakNeural(String text) {
    if (_retiring) return;
    try {
      TurnTrace.event(
        'tts.request',
        details:
            'agent=self source=boot.speakBubble chars=${text.trim().length}',
      );
      Log.i(
        '🔊 [AgentBoot/self] speakBubble → MaasoTtsPlugin '
        '(${text.trim().length} chars)',
      );
      MaasoTtsPlugin(agentId: 'self').methods['speak']!([text]);
    } catch (e) {
      Log.w('[Boot] neural speak failed, falling back to system: $e');
      _speakSystem(text);
    }
  }

  Future<void> _speakSystem(String text) {
    if (_retiring) return Future<void>.value();
    late final Future<void> tracked;
    tracked = _speakSystemActive(text).whenComplete(() {
      _inFlightSystemSpeech.remove(tracked);
    });
    _inFlightSystemSpeech.add(tracked);
    return tracked;
  }

  Future<void> _speakSystemActive(String text) async {
    final sw = TurnTrace.stopwatch(
      'tts.boot_system',
      details: 'agent=self chars=${text.length}',
    );
    try {
      final speech = _fallbackSpeech ??= MaasoTtsPlugin(
        agentId: 'self',
        fallbackTts: _fallbackTts,
      );
      await speech.speakSystem(text);
      TurnTrace.done('tts.boot_system', sw);
    } catch (e) {
      TurnTrace.event('tts.boot_system.error', details: 'error=$e');
      Log.w('[Boot] system speak failed: $e');
      EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
      EventBus().fire(LipSyncAmplitudeEvent(0, agentId: 'self'));
    }
  }

  /// Permanently fences boot-time voice producers for the retiring account,
  /// waits for already-admitted system speech calls, then strictly stops the
  /// controller-owned FlutterTts player. Failed stops retain the handle and
  /// can be retried by the account lease.
  Future<void> deactivateAndDrain() {
    _retiring = true;
    if (_presentationListenerAttached) {
      presentationChanges?.removeListener(_handlePresentationChanged);
      _presentationListenerAttached = false;
    }
    _disposeWorkers();
    return _shutdownFuture ??= _deactivateAndDrainOnce();
  }

  Future<void> _deactivateAndDrainOnce() async {
    var completed = false;
    try {
      while (_inFlightSystemSpeech.isNotEmpty) {
        await Future.wait<void>(
          _inFlightSystemSpeech.toList(growable: false),
          eagerError: false,
        );
      }
      await _fallbackSpeech?.dispose();
      if (!_fallbackStopped) {
        final override = _fallbackStopOverride;
        if (override != null) {
          await override();
        } else {
          await _fallbackTts.stop();
        }
        _fallbackStopped = true;
      }
      completed = true;
    } finally {
      if (!completed) _shutdownFuture = null;
    }
  }

  void _disposeWorkers() {
    _llmLoadingWatcher?.dispose();
    _llmAvailableWatcher?.dispose();
    _llmErrorWatcher?.dispose();
    _llmProgressWatcher?.dispose();
    _llmReceivedWatcher?.dispose();
    _llmTotalWatcher?.dispose();
    _llmEtaWatcher?.dispose();
    _llmDownloadKeyWatcher?.dispose();
    _llmDownloadProgressWatcher?.dispose();
    _llmDownloadReceivedWatcher?.dispose();
    _llmDownloadTotalWatcher?.dispose();
    _llmDownloadEtaWatcher?.dispose();
    _llmDownloadErrorWatcher?.dispose();
    _cloudKeyWatcher?.dispose();
    _cloudEnabledWatcher?.dispose();
    _cloudHealthWatcher?.dispose();
    _voiceReadyWatcher?.dispose();
    _voiceRunningWatcher?.dispose();
    _voiceFailedWatcher?.dispose();
    _voiceErrorWatcher?.dispose();
    _voiceProgressWatcher?.dispose();
    _voiceReceivedWatcher?.dispose();
    _voiceTotalWatcher?.dispose();
    _voiceEtaWatcher?.dispose();
    _vadLoadingWatcher?.dispose();
    _vadFailedWatcher?.dispose();
    _vadErrorWatcher?.dispose();
    _vadProgressWatcher?.dispose();
    _vadReceivedWatcher?.dispose();
    _vadTotalWatcher?.dispose();
    _vadEtaWatcher?.dispose();
    _profileWatcher?.dispose();
  }

  @override
  void onClose() {
    unawaited(
      deactivateAndDrain().catchError((Object error, StackTrace stackTrace) {
        Log.w(
          '[AgentBoot] asynchronous shutdown failed',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
    super.onClose();
  }
}

class _ModelDownloadTask {
  const _ModelDownloadTask({
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
    required this.etaSeconds,
  });

  final double progress;
  final int receivedBytes;
  final int totalBytes;
  final int? etaSeconds;

  int get effectiveTotal {
    if (totalBytes > 0) return totalBytes;
    if (progress > 0 && receivedBytes > 0) {
      return (receivedBytes / progress).round();
    }
    return 0;
  }

  int get effectiveReceived {
    final total = effectiveTotal;
    if (receivedBytes > 0) return receivedBytes;
    if (total > 0 && progress > 0) return (total * progress).round();
    return 0;
  }
}
