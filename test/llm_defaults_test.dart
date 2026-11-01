import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';

void main() {
  const turbo = 'doubao-seed-2-1-turbo-260628';
  const pro = 'doubao-seed-2-1-pro-260628';

  test(
    'Seed Evolving is the fresh install default while legacy IDs remain',
    () {
      expect(LLMDefaults.doubaoSeed21Turbo, turbo);
      expect(LLMDefaults.doubaoSeed21Pro, pro);
      expect(LLMDefaults.model, LLMDefaults.seedEvolving);
    },
  );

  test('settings Doubao preset exposes the current configured models', () {
    final doubao = AgentSettingsController.providerPresets.first;

    expect(doubao.model, LLMDefaults.seedEvolving);
    expect(doubao.models, contains(LLMDefaults.seedEvolving));
    expect(doubao.models, contains(LLMDefaults.glm53Flash));
  });
}
