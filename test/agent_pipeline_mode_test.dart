import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';

void main() {
  test('pipeline modes are explicit and default to proxy mode', () {
    expect(AgentPipelineMode.values.map((m) => m.key), [
      'local_full',
      'direct_cloud',
      'proxy_default',
      'volc_realtime_audio',
    ]);
    expect(AgentPipelineMode.defaultMode, AgentPipelineMode.proxyDefault);
    expect(
      AgentPipelineMode.fromKey('missing'),
      AgentPipelineMode.proxyDefault,
    );
  });

  test('pipeline modes expose routing capabilities', () {
    expect(AgentPipelineMode.localFull.usesPlatformSpeechRecognition, isTrue);
    expect(AgentPipelineMode.localFull.usesLocalLlm, isTrue);
    expect(AgentPipelineMode.localFull.usesLocalTts, isTrue);

    expect(AgentPipelineMode.directCloud.usesPlatformSpeechRecognition, isTrue);
    expect(AgentPipelineMode.directCloud.usesDirectCloudLlm, isTrue);
    expect(AgentPipelineMode.directCloud.usesLocalTts, isTrue);

    expect(AgentPipelineMode.proxyDefault.usesProxyLlm, isTrue);
    expect(AgentPipelineMode.proxyDefault.usesProxyTts, isTrue);
    expect(
      AgentPipelineMode.proxyDefault.usesPlatformSpeechRecognition,
      isTrue,
    );

    expect(AgentPipelineMode.volcRealtimeAudio.usesRealtimeAudio, isTrue);
    expect(AgentPipelineMode.volcRealtimeAudio.pureChatOnly, isTrue);
  });

  test('settings exposes only host-supported pipeline modes', () {
    final page = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final controller = File(
      'lib/src/features/settings/application/agent_settings_controller.dart',
    ).readAsStringSync();

    expect(page, contains('AgentPipelineMode.values'));
    expect(page, contains('mode.isAvailableFor(capabilities)'));
    expect(page, contains('for (final mode in availableModes)'));
    expect(page, contains('controller.pipelineMode.value'));
    expect(page, contains('controller.setPipelineMode'));
    expect(
      controller,
      contains('late final Rx<AgentPipelineMode> pipelineMode'),
    );
    expect(controller, contains('Future<void> setPipelineMode'));
  });

  test(
    'advanced settings only show model and voice controls for modes 1 and 2',
    () {
      final source = File(
        'lib/src/features/settings/presentation/agent_settings_page.dart',
      ).readAsStringSync();
      final body = source.substring(
        source.indexOf('class _AdvancedFeaturesPage'),
        source.indexOf('class _AdvancedPreparingBanner'),
      );

      expect(body, contains('final showModeScopedSections'));
      expect(body, contains('AgentPipelineMode.localFull'));
      expect(body, contains('AgentPipelineMode.directCloud'));
      expect(body, contains('if (showModeScopedSections)'));

      final modeScopedIndex = body.indexOf('if (showModeScopedSections)');
      final modelIndex = body.indexOf('const _ModelConfigSection()');
      final voiceIndex = body.indexOf('const _VoiceSection()');
      final brainIndex = body.indexOf('const _OnDeviceBrainSection()');

      expect(modeScopedIndex, greaterThanOrEqualTo(0));
      expect(modelIndex, greaterThan(modeScopedIndex));
      expect(voiceIndex, greaterThan(modeScopedIndex));
      expect(brainIndex, greaterThan(modeScopedIndex));
      expect(body, isNot(contains('const _VadSection()')));
    },
  );

  test('pipeline mode changes refresh runtime services and TTS engine', () {
    final controller = File(
      'lib/src/features/settings/application/agent_settings_controller.dart',
    ).readAsStringSync();
    final runtimeService = File(
      'lib/src/core/services/agent_pipeline_runtime_service.dart',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final login = File(
      'lib/src/features/auth/application/login_controller.dart',
    ).readAsStringSync();

    expect(controller, contains('AgentPipelineRuntimeService'));
    expect(controller, contains('refreshForMode('));
    expect(controller, contains('effectiveMode,'));
    expect(runtimeService, contains('class AgentPipelineRuntimeService'));
    expect(runtimeService, contains('LocalBrainService'));
    expect(runtimeService, contains('TTSEngineRegistry.current'));
    expect(runtimeService, contains('MaasoProxyTtsEngine'));
    expect(main, contains('AgentPipelineRuntimeService'));
    expect(login, contains('refreshForCurrentMode'));

    final receipt = controller.indexOf(
      'final pipelineSession = pipeline?.activeAccountSession;',
    );
    final persist = controller.indexOf(
      'await _agentMode.setPipelineMode(value);',
    );
    final effective = controller.indexOf(
      'final effectiveMode = _agentMode.pipelineMode.value;',
    );
    final refresh = controller.indexOf('effectiveMode,', effective);
    final exactFence = controller.indexOf(
      '!pipeline.isAccountSessionActive(pipelineSession)',
    );
    final lateRegistration = controller.indexOf(
      'appServices.put(CloudLLMHealthService())',
    );
    expect(receipt, greaterThanOrEqualTo(0));
    expect(persist, greaterThan(receipt));
    expect(effective, greaterThan(persist));
    expect(refresh, greaterThan(effective));
    expect(exactFence, greaterThan(refresh));
    expect(lateRegistration, greaterThan(exactFence));
  });

  test('runtime routes by explicit pipeline mode', () {
    final llm = File(
      'lib/src/core/services/llm_proxy_service.dart',
    ).readAsStringSync();
    final tts = File(
      'lib/src/core/services/agent_pipeline_runtime_service.dart',
    ).readAsStringSync();
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();
    final chatInput = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();
    final rtc = File(
      'lib/src/core/services/volc_engine_rtc_native_adapter.dart',
    ).readAsStringSync();

    expect(llm, contains('switch (_pipelineMode)'));
    expect(llm, contains('AgentPipelineMode.directCloud'));
    expect(llm, contains('AgentPipelineMode.proxyDefault'));
    expect(tts, contains('AgentPipelineMode.proxyDefault'));
    expect(tts, contains('AgentPipelineMode.directCloud'));
    expect(tts, contains('AgentPipelineMode.localFull'));
    expect(runtime, contains('AgentPipelineMode.localFull'));
    expect(chatInput, contains('usesRealtimeAudio'));
    expect(chatInput, contains('_enterNativeAsrWithVadVoice'));
    expect(chatInput, isNot(contains('usesLocalSpeechModels')));
    expect(rtc, contains('publishVideo = false'));
    expect(rtc, contains('autoSubscribeVideo = false'));
  });
}
