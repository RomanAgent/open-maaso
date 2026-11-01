import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

enum AgentPipelineMode {
  localFull('local_full'),
  directCloud('direct_cloud'),
  proxyDefault('proxy_default'),
  volcRealtimeAudio('volc_realtime_audio');

  const AgentPipelineMode(this.key);

  final String key;

  static const defaultMode = AgentPipelineMode.proxyDefault;

  static AgentPipelineMode fromKey(String? key) {
    for (final value in values) {
      if (value.key == key) return value;
    }
    return defaultMode;
  }

  bool get usesPlatformSpeechRecognition =>
      this == localFull || this == directCloud || this == proxyDefault;
  bool get usesRealtimeAudio => this == volcRealtimeAudio;

  bool get usesLocalLlm => this == localFull;
  bool get usesDirectCloudLlm => this == directCloud;
  bool get usesProxyLlm => this == proxyDefault || this == volcRealtimeAudio;

  bool get usesLocalTts => this == localFull || this == directCloud;
  bool get usesProxyTts => this == proxyDefault;

  bool get pureChatOnly => this == volcRealtimeAudio;
  bool get requiresLocalModels => usesLocalLlm || usesLocalTts;
}

extension AgentPipelineModePlatformPolicy on AgentPipelineMode {
  bool isAvailableFor(AppPlatformCapabilities capabilities) => switch (this) {
    AgentPipelineMode.proxyDefault => true,
    AgentPipelineMode.volcRealtimeAudio =>
      capabilities.supportsAdvancedAiSettings &&
          capabilities.actionStatus(AppActionCapability.realtimeRtc).available,
    _ => capabilities.supportsAdvancedAiSettings,
  };

  AgentPipelineMode effectiveFor(AppPlatformCapabilities capabilities) =>
      isAvailableFor(capabilities) ? this : AgentPipelineMode.defaultMode;
}

class MaasoAgentModeService extends AppService {
  MaasoAgentModeService({AppPlatformCapabilities? platformCapabilities})
    : _platformCapabilities =
          platformCapabilities ?? AppPlatformCapabilities.current();

  final AppPlatformCapabilities _platformCapabilities;
  final SecureStorageService _storage = appServices
      .find<SecureStorageService>();

  final pipelineMode = AgentPipelineMode.defaultMode.obs;

  /// Compatibility observable for older call sites/tests. Prefer [pipelineMode].
  final volcRealtimeChatOnly = false.obs;

  Future<MaasoAgentModeService> init() async {
    final stored = await _storage.read(GlobalConstant.keyAgentPipelineMode);
    var next = AgentPipelineMode.fromKey(stored);
    if (stored == null) {
      final legacyRtc =
          await _storage.readBool(GlobalConstant.keyVolcRealtimeChatOnly) ??
          false;
      if (legacyRtc) next = AgentPipelineMode.volcRealtimeAudio;
    }
    final effective = next.effectiveFor(_platformCapabilities);
    _applyMode(effective);
    if (effective != next) {
      await _storage.write(GlobalConstant.keyAgentPipelineMode, effective.key);
      await _storage.writeBool(GlobalConstant.keyVolcRealtimeChatOnly, false);
    }
    return this;
  }

  Future<void> setPipelineMode(AgentPipelineMode value) async {
    final effective = value.effectiveFor(_platformCapabilities);
    _applyMode(effective);
    await _storage.write(GlobalConstant.keyAgentPipelineMode, effective.key);
    await _storage.writeBool(
      GlobalConstant.keyVolcRealtimeChatOnly,
      effective == AgentPipelineMode.volcRealtimeAudio,
    );
  }

  Future<void> setVolcRealtimeChatOnly(bool value) {
    return setPipelineMode(
      value
          ? AgentPipelineMode.volcRealtimeAudio
          : AgentPipelineMode.defaultMode,
    );
  }

  void _applyMode(AgentPipelineMode value) {
    pipelineMode.value = value;
    volcRealtimeChatOnly.value = value == AgentPipelineMode.volcRealtimeAudio;
  }
}
