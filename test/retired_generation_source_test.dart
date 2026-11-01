import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skills/device_handoff_skill.dart';

void main() {
  test('retired orchestration and script extractors cannot rejoin production', () {
    for (final path in [
      'lib/src/features/agent/data/agents/router_agent.dart',
      'lib/src/features/agent/data/agents/worker_agent.dart',
      'lib/src/features/agent/data/agents/profiler_agent.dart',
      'lib/src/features/agent/data/perception/context_aggregator.dart',
      'lib/src/features/agent/data/utils/token_optimizer.dart',
      'lib/src/features/agent/data/utils/markdown_code_extractor.dart',
      'lib/src/features/agent/application/action/device_handoff_action_binding.dart',
      'lib/src/features/surface_play/examples/surface_play_example_factory.dart',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      expect(
        source,
        isNot(contains('SurfacePlayExampleFactory')),
        reason: file.path,
      );
      expect(
        source,
        isNot(contains('DeviceHandoffActionBinding')),
        reason: file.path,
      );
      expect(
        source,
        isNot(contains('deviceHandoffBinding')),
        reason: file.path,
      );
    }
  });

  test(
    'only active account profile compatibility remains in legacy prompts',
    () {
      for (final locale in [AppLocale.en, AppLocale.zh]) {
        final keys = AgentPromptCatalog.keysFor(
          locale,
        ).where((key) => key.startsWith('legacy.'));
        expect(
          keys,
          unorderedEquals([
            'legacy.profile.unknown',
            'legacy.profile.header',
            'legacy.profile.entry',
          ]),
        );
      }
    },
  );

  test('online devices publishes no retired handoff tools', () {
    final skill = DeviceHandoffSkill();
    expect(skill.methods.keys, ['listDevices']);
    expect(skill.nativeToolSchemas.keys, ['listDevices']);
    expect(skill.nativeMethodDescriptions.keys, ['listDevices']);
  });
}
