import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';

const _legacyAuthoringIds = {'card', 'artifact', 'playable_game'};
const _legacyAuthoringPaths = <String>[
  'lib/agent/card_backend.dart',
  'lib/agent/card_manifest.dart',
  'lib/agent/card_runtime.dart',
  'lib/agent/card_template.dart',
  'lib/agent/card_template_registry.dart',
  'lib/agent/card_templates.dart',
  'lib/agent/artifact_intent.dart',
  'lib/agent/artifacts',
  'lib/agent/playable_game',
  'lib/agent/skills/artifact_skill.dart',
  'lib/agent/skills/card_control_skill.dart',
  'lib/agent/skills/playable_game_skill.dart',
  'lib/pages/widget/card_web_view.dart',
  'lib/pages/widget/widget_stage_surface.dart',
  'lib/service/card_backend_service.dart',
  'lib/service/playable_post_service.dart',
  'lib/models/playable_post.dart',
];

void main() {
  test(
    'default-enabled model-visible authoring uses freeform surface only',
    () {
      final defaultEnabled = SkillCatalog.defaultEnabled;
      final violations = <String>[];

      if (!defaultEnabled.contains('freeform_surface')) {
        violations.add('freeform_surface is not enabled by default.');
      }

      for (final id in _legacyAuthoringIds) {
        if (defaultEnabled.contains(id)) {
          violations.add('Legacy authoring id "$id" is enabled by default.');
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );

  test('legacy authoring SkillSpec ids are not active catalog entries', () {
    final activeIds = SkillCatalog.all
        .where((spec) => !spec.isComingSoon && spec.factory != null)
        .map((spec) => spec.id)
        .toSet();
    final violations = <String>[];

    if (!activeIds.contains('freeform_surface')) {
      violations.add('freeform_surface is not an active SkillSpec id.');
    }

    for (final id in _legacyAuthoringIds) {
      if (activeIds.contains(id)) {
        violations.add(
          'Legacy authoring id "$id" remains an active SkillSpec.',
        );
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('legacy generated-ui authoring runtime files are removed', () {
    final repo = Directory.current.path;
    final violations = <String>[];

    for (final path in _legacyAuthoringPaths) {
      final absolutePath = '$repo/$path';
      if (FileSystemEntity.typeSync(absolutePath) !=
          FileSystemEntityType.notFound) {
        violations.add('Legacy authoring path still exists: $path');
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
