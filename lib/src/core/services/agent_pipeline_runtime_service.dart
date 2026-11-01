import 'dart:typed_data';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/sherpa_tts_engine.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_proxy_tts_engine.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/sherpa_model_download_service.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/services/sherpa_bindings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:maaso/src/core/services/cloud_voice_privacy_gate.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

/// Exact receipt for the account generation allowed to reconfigure runtime
/// producers. Settings routes retain this receipt across their own awaits so
/// an account-A completion can never mutate account B.
final class AgentPipelineAccountSession {
  const AgentPipelineAccountSession._({
    required this.mount,
    required this.generation,
  });

  final AccountStorageScopeMount mount;
  final int generation;
}

class AgentPipelineRuntimeService extends AppService {
  AgentPipelineRuntimeService({AppPlatformCapabilities? platformCapabilities})
    : _platformCapabilities =
          platformCapabilities ?? AppPlatformCapabilities.current();

  final AppPlatformCapabilities _platformCapabilities;
  int _generation = 0;
  bool _fenced = false;
  bool _retiring = false;
  AgentPipelineAccountSession? _activeSession;
  Future<void>? _drainFuture;
  final Set<Future<void>> _operations = <Future<void>>{};

  /// True only while the currently published engine is the authenticated
  /// Maaso proxy TTS path. Consumers such as first-run onboarding can wait for
  /// the post-login token publication without mistaking the system fallback
  /// for a ready cloud voice.
  final RxBool proxyTtsReady = false.obs;

  AgentPipelineAccountSession? get activeAccountSession => _activeSession;

  Future<AgentPipelineRuntimeService> init() async {
    await refreshForCurrentMode();
    return this;
  }

  Future<void> activateAccount(AccountStorageScopeMount mount) {
    if (appServices.isRegistered<AccountStorageScopeService>()) {
      appServices.find<AccountStorageScopeService>().requireCurrent(mount);
    }
    final current = _activeSession;
    if (current != null &&
        current.mount.generation == mount.generation &&
        current.mount.scope == mount.scope) {
      return refreshForCurrentMode(accountSession: current);
    }
    if (current != null || _retiring || _drainFuture != null) {
      throw StateError(
        'Cannot activate the pipeline until the previous account is drained.',
      );
    }

    final session = AgentPipelineAccountSession._(
      mount: mount,
      generation: ++_generation,
    );
    _fenced = false;
    _activeSession = session;
    return refreshForCurrentMode(accountSession: session);
  }

  bool isAccountSessionActive(AgentPipelineAccountSession session) =>
      identical(_activeSession, session) && !_fenced && !_retiring;

  Future<void> refreshForCurrentMode({
    AgentPipelineAccountSession? accountSession,
  }) async {
    final mode = appServices.isRegistered<MaasoAgentModeService>()
        ? appServices.find<MaasoAgentModeService>().pipelineMode.value
        : AgentPipelineMode.defaultMode;
    await refreshForMode(mode, accountSession: accountSession);
  }

  Future<void> refreshForMode(
    AgentPipelineMode mode, {
    AgentPipelineAccountSession? accountSession,
  }) {
    final effectiveMode = mode.effectiveFor(_platformCapabilities);
    final receipt = _admit(accountSession);
    if (receipt == null) return Future<void>.value();
    return _track(() async {
      Log.i(
        '🧭 [AgentPipeline] refresh requested=${mode.key} '
        'effective=${effectiveMode.key}',
      );
      await _sanitizeUnsupportedLocalPreferences();
      if (!_isAdmitted(receipt)) return;
      await _registerRuntimeServices(effectiveMode, receipt);
      if (!_isAdmitted(receipt)) return;
      await _refreshTtsEngine(effectiveMode, receipt);
    });
  }

  Future<void> refreshTtsEngine({
    AgentPipelineMode? mode,
    AgentPipelineAccountSession? accountSession,
  }) {
    final receipt = _admit(accountSession);
    if (receipt == null) return Future<void>.value();
    final selectedMode =
        mode ??
        (appServices.isRegistered<MaasoAgentModeService>()
            ? appServices.find<MaasoAgentModeService>().pipelineMode.value
            : AgentPipelineMode.defaultMode);
    return _track(() => _refreshTtsEngine(selectedMode, receipt));
  }

  Future<void> _refreshTtsEngine(
    AgentPipelineMode mode,
    _AgentPipelineOperationReceipt receipt,
  ) async {
    final selected = await _selectTtsEngine(mode, receipt);
    if (selected == null || !_isAdmitted(receipt)) return;
    TTSEngineRegistry.current = selected;
    proxyTtsReady.value = selected is MaasoProxyTtsEngine && selected.isReady;
    Log.i(
      '🧭 [AgentPipeline] tts=${TTSEngineRegistry.current.runtimeType} '
      'mode=${mode.key}',
    );
  }

  /// Synchronously fences pipeline registration and TTS publication, then
  /// waits for every operation already admitted by the retiring generation.
  Future<void> deactivateAccountAndDrain() {
    final inFlight = _drainFuture;
    if (inFlight != null) return inFlight;
    if (_fenced && !_retiring && _operations.isEmpty) {
      return Future<void>.value();
    }

    if (!_retiring) {
      _activeSession = null;
      _fenced = true;
      _retiring = true;
      _generation++;
      TTSEngineRegistry.current = _SystemFallbackTtsEngine();
      proxyTtsReady.value = false;
    }

    late final Future<void> drain;
    drain = _drainOnce().whenComplete(() {
      if (identical(_drainFuture, drain)) _drainFuture = null;
    });
    _drainFuture = drain;
    return drain;
  }

  Future<void> _drainOnce() async {
    while (_operations.isNotEmpty) {
      final pending = _operations.toList(growable: false);
      await Future.wait<void>(pending, eagerError: false);
    }
    _retiring = false;
  }

  Future<bool> localTtsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_platformCapabilities.supportsOnDeviceSpeechModels) {
      if (prefs.getBool(SherpaNeuralTts.enabledPrefsKey) == true) {
        await prefs.setBool(SherpaNeuralTts.enabledPrefsKey, false);
      }
      return false;
    }
    return prefs.getBool(SherpaNeuralTts.enabledPrefsKey) ?? false;
  }

  Future<void> _sanitizeUnsupportedLocalPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_platformCapabilities.supportsOnDeviceLlm &&
        prefs.getBool(LocalLLMService.enabledPrefsKey) == true) {
      await prefs.setBool(LocalLLMService.enabledPrefsKey, false);
    }
    if (!_platformCapabilities.supportsOnDeviceSpeechModels &&
        prefs.getBool(SherpaNeuralTts.enabledPrefsKey) == true) {
      await prefs.setBool(SherpaNeuralTts.enabledPrefsKey, false);
    }
  }

  Future<void> _registerRuntimeServices(
    AgentPipelineMode mode,
    _AgentPipelineOperationReceipt receipt,
  ) async {
    mode = mode.effectiveFor(_platformCapabilities);
    if (!_isAdmitted(receipt)) return;
    if (!mode.pureChatOnly && !appServices.isRegistered<LocalBrainService>()) {
      final service = await LocalBrainService().init();
      if (!_isAdmitted(receipt)) {
        service.closeLifecycle();
        return;
      }
      if (!appServices.isRegistered<LocalBrainService>()) {
        appServices.put(service);
      } else {
        service.closeLifecycle();
      }
    }

    if (!_isAdmitted(receipt)) return;
    if (mode.usesLocalLlm && await _localLlmEnabled()) {
      if (!_isAdmitted(receipt)) return;
      if (!appServices.isRegistered<LocalLLMService>()) {
        final service = await LocalLLMService(
          platformCapabilities: _platformCapabilities,
        ).init(autoLoad: false);
        if (!_isAdmitted(receipt)) {
          service.closeLifecycle();
          return;
        }
        if (!appServices.isRegistered<LocalLLMService>()) {
          appServices.put(service);
        } else {
          service.closeLifecycle();
        }
      }
    }

    if (mode.usesLocalTts && await localTtsEnabled()) {
      if (!_isAdmitted(receipt)) return;
      if (!await _registerLocalTtsModelServices(receipt)) return;
    }

    if (mode.usesDirectCloudLlm && await _directCloudEnabled()) {
      if (!_isAdmitted(receipt)) return;
      if (!appServices.isRegistered<CloudLLMHealthService>()) {
        appServices.put(CloudLLMHealthService());
      }
    }
  }

  Future<bool> _localLlmEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_platformCapabilities.supportsOnDeviceLlm) {
      if (prefs.getBool(LocalLLMService.enabledPrefsKey) == true) {
        await prefs.setBool(LocalLLMService.enabledPrefsKey, false);
      }
      return false;
    }
    return prefs.getBool(LocalLLMService.enabledPrefsKey) ?? false;
  }

  Future<bool> _directCloudEnabled() async {
    if (!appServices.isRegistered<SecureStorageService>()) return false;
    final config = await LLMDirectCloudConfig.readFrom(
      appServices.find<SecureStorageService>(),
    );
    return config?.enabled ?? false;
  }

  Future<bool> _registerLocalTtsModelServices(
    _AgentPipelineOperationReceipt receipt,
  ) async {
    if (!_isAdmitted(receipt)) return false;
    initializeSherpaBindings();
    if (!_isAdmitted(receipt)) return false;
    if (!appServices.isRegistered<SherpaModelDownloadService>()) {
      appServices.put(SherpaModelDownloadService());
    }
    if (!appServices.isRegistered<SherpaNeuralTts>()) {
      final service = await SherpaNeuralTts(
        platformCapabilities: _platformCapabilities,
      ).init();
      if (!_isAdmitted(receipt)) {
        service.closeLifecycle();
        return false;
      }
      if (!appServices.isRegistered<SherpaNeuralTts>()) {
        appServices.put(service);
      } else {
        service.closeLifecycle();
      }
    }
    return _isAdmitted(receipt);
  }

  Future<TTSEngine?> _selectTtsEngine(
    AgentPipelineMode mode,
    _AgentPipelineOperationReceipt receipt,
  ) async {
    if (!_isAdmitted(receipt)) return null;
    mode = mode.effectiveFor(_platformCapabilities);
    switch (mode) {
      case AgentPipelineMode.localFull:
      case AgentPipelineMode.directCloud:
        final enabled = await localTtsEnabled();
        if (!_isAdmitted(receipt)) return null;
        if (!enabled) return _SystemFallbackTtsEngine();
        if (!await _registerLocalTtsModelServices(receipt)) return null;
        return _isAdmitted(receipt) ? SherpaTtsEngine() : null;
      case AgentPipelineMode.proxyDefault:
        final proxy = await _proxyTtsEngine();
        if (!_isAdmitted(receipt)) return null;
        return proxy ?? _SystemFallbackTtsEngine();
      case AgentPipelineMode.volcRealtimeAudio:
        return _SystemFallbackTtsEngine();
    }
  }

  Future<TTSEngine?> _proxyTtsEngine() async {
    if (!appServices.isRegistered<RealtimeAgentConfig>() ||
        !appServices.isRegistered<AuthSessionService>()) {
      return null;
    }
    final config = appServices.find<RealtimeAgentConfig>();
    final baseUri = config.baseUri;
    final auth = appServices.find<AuthSessionService>();
    final published = auth.session.value;
    final token = published != null && published.isValid
        ? published.accessToken.trim()
        : '';
    if (!config.isReady || baseUri == null || token.isEmpty) {
      return null;
    }
    final generation = _generation;
    final privacy = CloudVoicePrivacyGate.capture();
    void requireOwner() {
      if (_fenced ||
          _retiring ||
          generation != _generation ||
          auth.session.value?.accountUuid != published!.accountUuid) {
        throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
      }
      privacy.requireCurrent();
    }

    return MaasoProxyTtsEngine(
      baseUri: baseUri,
      beforeDispatch: () async {
        requireOwner();
        await privacy.require();
        requireOwner();
      },
      privacyRevocations: privacy.revocations,
      accessTokenProvider: () async {
        requireOwner();
        final current = auth.session.value;
        return current != null && current.isValid
            ? current.accessToken.trim()
            : null;
      },
    );
  }

  _AgentPipelineOperationReceipt? _admit(
    AgentPipelineAccountSession? expectedSession,
  ) {
    if (_fenced || _retiring) return null;
    final current = _activeSession;
    if (expectedSession != null && !identical(current, expectedSession)) {
      return null;
    }
    return _AgentPipelineOperationReceipt(
      generation: _generation,
      accountSession: current,
    );
  }

  bool _isAdmitted(_AgentPipelineOperationReceipt receipt) {
    if (_fenced || _retiring || receipt.generation != _generation) {
      return false;
    }
    return identical(receipt.accountSession, _activeSession);
  }

  Future<void> _track(Future<void> Function() operation) {
    late final Future<void> tracked;
    tracked = Future<void>.sync(operation).whenComplete(() {
      _operations.remove(tracked);
    });
    _operations.add(tracked);
    return tracked;
  }
}

final class _AgentPipelineOperationReceipt {
  const _AgentPipelineOperationReceipt({
    required this.generation,
    required this.accountSession,
  });

  final int generation;
  final AgentPipelineAccountSession? accountSession;
}

class _SystemFallbackTtsEngine implements TTSEngine {
  @override
  bool get isReady => false;

  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) async => false;

  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) {
    throw StateError('System fallback TTS does not synthesize WAV audio');
  }
}
