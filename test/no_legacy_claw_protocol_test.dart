import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime source has no legacy script protocol residue', () {
    const legacyNamespace =
        'C'
        'law.';
    final bannedTokens = [
      legacyNamespace,
      'C'
          'lawSkill',
      'C'
          'lawBridgePlugin',
      'C'
          'lawJSRuntime',
      'Bridge'
          'Registry',
      'Maaso'
          'AgentCore',
      'js'
          'Signature',
      'generate'
          'SkillPrompt',
      'mount'
          'ToRegistry',
    ];
    final bannedPaths = [
      'lib/agent_core/agents/manager_agent.dart',
      'lib/agent_core/agents/prompt_templates.dart',
      'lib/agent_core/bridge/bridge_registry.dart',
      'lib/agent_core/context/'
          'claw_config.dart',
      'lib/agent_core/sandbox/js_runtime.dart',
      'lib/agent_core/skills/'
          'claw_skill.dart',
    ];

    final violations = <String>[];
    for (final path in bannedPaths) {
      if (File(path).existsSync()) violations.add('legacy path exists: $path');
    }

    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !file.path.endsWith('.g.dart'));
    for (final file in files) {
      // This decoder explicitly rejects the retired script marker as input.
      final source = file.readAsStringSync().replaceAll(
        "text.contains('Claw.')",
        '',
      );
      for (final token in bannedTokens) {
        if (source.contains(token)) {
          violations.add('${file.path} contains $token');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
