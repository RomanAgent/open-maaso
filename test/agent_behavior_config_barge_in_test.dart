// test/agent_behavior_config_barge_in_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';

void main() {
  test('voiceBargeInEnabled defaults to false', () {
    final cfg = AgentBehaviorConfig();
    expect(cfg.voiceBargeInEnabled.value, isFalse);
  });

  test('setVoiceBargeIn flips the flag', () {
    final cfg = AgentBehaviorConfig();
    cfg.setVoiceBargeIn(true);
    expect(cfg.voiceBargeInEnabled.value, isTrue);
    cfg.setVoiceBargeIn(false);
    expect(cfg.voiceBargeInEnabled.value, isFalse);
  });
}
