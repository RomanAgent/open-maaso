import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings exposes Volc realtime as one explicit pipeline mode', () {
    final page = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final controller = File(
      'lib/src/features/settings/application/agent_settings_controller.dart',
    ).readAsStringSync();

    expect(page, contains('AgentPipelineMode.values'));
    expect(page, contains('settings.pipeline_volc_realtime_audio'));
    expect(page, contains('controller.setPipelineMode'));
    expect(controller, contains('pipelineMode'));
    expect(controller, contains('volcRealtimeChatOnly'));
    expect(controller, contains('setVolcRealtimeChatOnly'));
  });

  test('realtime voice entry is gated by the explicit realtime mode', () {
    final source = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();

    expect(source, contains('MaasoAgentModeService'));
    expect(source, contains('pipelineMode.value'));
    expect(source, contains('usesRealtimeAudio'));
  });

  test('typed turns bypass agent runtime in chat-only experiment mode', () {
    final source = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();

    expect(source, contains('MaasoAgentModeService'));
    expect(source, contains('_sendPureChatOnly'));
    expect(source, contains('pureChatOnly'));
  });
}
