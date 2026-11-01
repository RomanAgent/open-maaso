import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/agent_pipeline_runtime_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/sherpa_model_download_service.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  tearDown(appServices.reset);

  test('mobile, web, and unknown hosts normalize every advanced mode', () {
    for (final platform in <AppHostPlatform>[
      AppHostPlatform.android,
      AppHostPlatform.ios,
      AppHostPlatform.web,
      AppHostPlatform.fuchsia,
    ]) {
      final capabilities = AppPlatformCapabilities.forPlatform(platform);
      for (final mode in AgentPipelineMode.values) {
        expect(
          mode.effectiveFor(capabilities),
          AgentPipelineMode.proxyDefault,
          reason: '${platform.name} ${mode.key}',
        );
      }
    }
  });

  test('desktop hosts keep explicit modes while defaulting to cloud', () {
    for (final platform in <AppHostPlatform>[
      AppHostPlatform.macos,
      AppHostPlatform.windows,
      AppHostPlatform.linux,
    ]) {
      final capabilities = AppPlatformCapabilities.forPlatform(platform);
      expect(
        AgentPipelineMode.defaultMode.effectiveFor(capabilities),
        AgentPipelineMode.proxyDefault,
      );
      expect(
        AgentPipelineMode.localFull.effectiveFor(capabilities),
        AgentPipelineMode.localFull,
      );
      expect(
        AgentPipelineMode.directCloud.effectiveFor(capabilities),
        AgentPipelineMode.directCloud,
      );
      expect(
        AgentPipelineMode.volcRealtimeAudio.effectiveFor(capabilities),
        AgentPipelineMode.proxyDefault,
      );
      expect(
        AgentPipelineMode.volcRealtimeAudio.isAvailableFor(capabilities),
        isFalse,
      );
    }
  });

  test('Volc realtime mode requires both advanced UI and RTC runtime', () {
    for (final platform in AppHostPlatform.values) {
      final capabilities = AppPlatformCapabilities.forPlatform(platform);
      expect(
        AgentPipelineMode.volcRealtimeAudio.isAvailableFor(capabilities),
        isFalse,
        reason: platform.name,
      );
      expect(
        AgentPipelineMode.volcRealtimeAudio.effectiveFor(capabilities),
        AgentPipelineMode.proxyDefault,
        reason: platform.name,
      );
    }
  });

  test('stale mobile pipeline preference is migrated to proxy mode', () async {
    final storage = _MemorySecureStorage(<String, String>{
      GlobalConstant.keyAgentPipelineMode: AgentPipelineMode.localFull.key,
      GlobalConstant.keyVolcRealtimeChatOnly: 'true',
    });
    appServices.put<SecureStorageService>(storage);
    final mode = MaasoAgentModeService(
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.android,
      ),
    );

    await mode.init();

    expect(mode.pipelineMode.value, AgentPipelineMode.proxyDefault);
    expect(
      storage.values[GlobalConstant.keyAgentPipelineMode],
      AgentPipelineMode.proxyDefault.key,
    );
    expect(storage.values[GlobalConstant.keyVolcRealtimeChatOnly], 'false');

    await mode.setPipelineMode(AgentPipelineMode.directCloud);
    expect(mode.pipelineMode.value, AgentPipelineMode.proxyDefault);
    expect(
      storage.values[GlobalConstant.keyAgentPipelineMode],
      AgentPipelineMode.proxyDefault.key,
    );
  });

  test('desktop mode service preserves an explicit local selection', () async {
    final storage = _MemorySecureStorage(<String, String>{
      GlobalConstant.keyAgentPipelineMode: AgentPipelineMode.localFull.key,
    });
    appServices.put<SecureStorageService>(storage);
    final mode = MaasoAgentModeService(
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.macos,
      ),
    );

    await mode.init();

    expect(mode.pipelineMode.value, AgentPipelineMode.localFull);
    expect(
      storage.values[GlobalConstant.keyAgentPipelineMode],
      AgentPipelineMode.localFull.key,
    );
  });

  test(
    'unsupported local LLM preference cannot scan, enable, or load',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        LocalLLMService.enabledPrefsKey: true,
      });
      final service = LocalLLMService(
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.ios,
        ),
      );

      await service.init();
      expect(service.isSupportedOnHost, isFalse);
      expect(service.isEnabled.value, isFalse);
      expect(service.suppressedByCloud.value, isTrue);
      expect(service.downloadedKeys, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          LocalLLMService.enabledPrefsKey,
        ),
        isFalse,
      );

      await service.setEnabled(true);
      await service.selectModel(LlmModelOption.defaultOption);
      await service.downloadModel(LlmModelOption.defaultOption);
      await service.applyResident(true);

      expect(await service.ensureLoadedForFallback(), isFalse);
      expect(service.isEnabled.value, isFalse);
      expect(service.isAvailable.value, isFalse);
      expect(service.isLoading.value, isFalse);
      expect(service.isDownloading.value, isFalse);
    },
  );

  test(
    'unsupported local TTS preference is cleared before model loading',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SherpaNeuralTts.enabledPrefsKey: true,
      });
      final service = SherpaNeuralTts(
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.android,
        ),
      );

      await service.init();

      expect(service.enabled.value, isFalse);
      expect(service.isLoading.value, isFalse);
      expect(service.isDownloading.value, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          SherpaNeuralTts.enabledPrefsKey,
        ),
        isFalse,
      );
      await expectLater(
        service.select(TtsEngine.supertonic, enable: true),
        throwsUnsupportedError,
      );
      await expectLater(service.ensureReady(), throwsUnsupportedError);
    },
  );

  test(
    'pipeline refresh clears every stale local preference without loading',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        LocalLLMService.enabledPrefsKey: true,
        SherpaNeuralTts.enabledPrefsKey: true,
      });
      final runtime = AgentPipelineRuntimeService(
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.android,
        ),
      );

      await runtime.refreshForMode(AgentPipelineMode.localFull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(LocalLLMService.enabledPrefsKey), isFalse);
      expect(prefs.getBool(SherpaNeuralTts.enabledPrefsKey), isFalse);
      expect(appServices.isRegistered<LocalLLMService>(), isFalse);
      expect(appServices.isRegistered<SherpaNeuralTts>(), isFalse);
      expect(appServices.isRegistered<SherpaModelDownloadService>(), isFalse);
    },
  );

  test('advanced deep links redirect only on unsupported hosts', () {
    expect(
      platformCapabilityRedirectForPath(
        AppRoutes.advancedFeatures,
        const AppPlatformCapabilities.forPlatform(AppHostPlatform.web),
      ),
      AppRoutes.settings,
    );
    expect(
      platformCapabilityRedirectForPath(
        AppRoutes.advancedFeatures,
        const AppPlatformCapabilities.forPlatform(AppHostPlatform.macos),
      ),
      isNull,
    );
    expect(
      platformCapabilityRedirectForPath(
        AppRoutes.settings,
        const AppPlatformCapabilities.forPlatform(AppHostPlatform.web),
      ),
      isNull,
    );
  });
}

final class _MemorySecureStorage extends SecureStorageService {
  _MemorySecureStorage([Map<String, String>? initialValues])
    : values = <String, String>{...?initialValues};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }
}
