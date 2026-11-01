import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first use prepares only VAD by default', () {
    final bootSource = File(
      'lib/src/features/agent/application/controllers/agent_boot_controller.dart',
    ).readAsStringSync();
    final mainSource = File('lib/main.dart').readAsStringSync();
    final bootLoadsSource = _methodBody(
      bootSource,
      'void _startBootLoads()',
      '  // ──────────── chat-pipeline hook',
    );

    final postFrameBoot = _methodBody(
      mainSource,
      'Future<void> _runPostFrameBootTasks()',
      'extension SecureStorageServiceExt',
    );

    expect(bootLoadsSource, isNot(contains('downloadModel(')));
    expect(bootLoadsSource, isNot(contains('TtsWarmupService')));
    expect(bootLoadsSource, isNot(contains('AsrService')));
    expect(
      postFrameBoot,
      contains('appServices.find<VadService>().ensureReady()'),
    );
    expect(bootSource, contains('AdvancedFeatureService'));
  });

  test('local brain is disabled by default until settings enables it', () {
    final llmSource = File(
      'lib/src/core/services/local_llm_service.dart',
    ).readAsStringSync();
    final settingsSource = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final initSource = _methodBody(
      llmSource,
      'Future<LocalLLMService> init',
      '  /// Switch which local model is active.',
    );

    expect(llmSource, contains('_kEnabledKey'));
    expect(initSource, contains('prefs.getBool(_kEnabledKey) ?? false'));
    expect(initSource, isNot(contains('isEnabled.value = true;')));
    expect(llmSource, contains('prefs.getBool(_kSaveMemoryKey) ?? true'));
    expect(settingsSource, contains('settings.local_brain_enable'));
    expect(settingsSource, contains('settings.local_brain_disable'));
    expect(settingsSource, contains('setEnabled('));
  });

  test('home loading UI renders one aggregate model card', () {
    final cardSource = File(
      'lib/src/core/widgets/agent_loading_card.dart',
    ).readAsStringSync();

    expect(cardSource, contains('boot.modelLoading.value'));
    expect(cardSource, contains('boot.modelProgress.value'));
    expect(cardSource, isNot(contains('boot.voiceLoading.value')));
    expect(cardSource, isNot(contains('boot.asrLoading.value')));
  });

  test(
    'default TTS avoids local sherpa model unless pipeline mode requires it',
    () {
      final settingsSource = File(
        'lib/src/features/settings/presentation/agent_settings_page.dart',
      ).readAsStringSync();
      final runtimeSource = File(
        'lib/src/core/services/agent_pipeline_runtime_service.dart',
      ).readAsStringSync();

      expect(settingsSource, contains('class _AdvancedFeaturesSection'));
      expect(
        settingsSource,
        contains('appNavigation.push(AppRouteCatalog.advancedFeatures)'),
      );
      expect(settingsSource, isNot(contains('requiresLocalModels')));
      expect(runtimeSource, contains('AgentPipelineMode.proxyDefault'));
      expect(runtimeSource, contains('AgentPipelineMode.directCloud'));
      expect(runtimeSource, contains('AgentPipelineMode.localFull'));
      expect(runtimeSource, contains('_SystemFallbackTtsEngine'));
      expect(runtimeSource, contains('SherpaTtsEngine()'));
      expect(runtimeSource, contains('SherpaNeuralTts.enabledPrefsKey'));
      expect(
        runtimeSource,
        contains('if (!enabled) return _SystemFallbackTtsEngine();'),
      );
      expect(
        runtimeSource,
        contains('mode.effectiveFor(_platformCapabilities)'),
      );
    },
  );

  test('default startup does not register legacy model services', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final runtimeSource = File(
      'lib/src/core/services/agent_pipeline_runtime_service.dart',
    ).readAsStringSync();
    final mainBody = _methodBody(
      mainSource,
      'void main() async {',
      'void _registerDefaultVadServices',
    );
    final defaultVadServices = _methodBody(
      mainSource,
      'void _registerDefaultVadServices',
      'Future<void> _runPostFrameBootTasks()',
    );
    final runtimeServices = _methodBody(
      runtimeSource,
      'Future<void> _registerRuntimeServices',
      'Future<bool> _localLlmEnabled()',
    );
    final postFrameBoot = _methodBody(
      mainSource,
      'Future<void> _runPostFrameBootTasks()',
      'extension SecureStorageServiceExt',
    );

    expect(mainBody, isNot(contains('LocalLLMService().init')));
    expect(mainBody, isNot(contains('SherpaNeuralTts().init')));
    expect(mainBody, isNot(contains('appServices.put(AsrService())')));
    expect(mainBody, contains('_registerDefaultVadServices();'));
    expect(mainBody, isNot(contains('CloudLLMHealthService()')));
    expect(mainBody, isNot(contains('LlmModeCoordinator')));
    expect(mainBody, contains('AgentPipelineRuntimeService().init()'));

    expect(defaultVadServices, contains('appServices.put(VadService())'));
    expect(runtimeServices, contains('mode.usesLocalLlm'));
    expect(runtimeServices, contains('await _localLlmEnabled()'));
    expect(runtimeServices, isNot(contains('mode.requiresLocalModels')));
    expect(runtimeServices, contains('mode.usesDirectCloudLlm'));
    expect(runtimeServices, contains('await _directCloudEnabled()'));
    expect(runtimeServices, contains('mode.usesLocalTts'));
    expect(runtimeServices, contains('await localTtsEnabled()'));

    expect(postFrameBoot, contains('AdvancedFeatureService'));
    expect(postFrameBoot, contains('advancedEnabled &&'));
    expect(
      postFrameBoot,
      contains('appServices.find<VadService>().ensureReady()'),
    );
    expect(
      postFrameBoot,
      contains('appServices.put(EnvironmentSensorService())'),
    );
  });
}

String _methodBody(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start);
  expect(start, isNonNegative);
  expect(end, isNonNegative);
  return source.substring(start, end);
}
