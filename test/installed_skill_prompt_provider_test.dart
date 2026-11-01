import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/skills/data/installed_skill_prompt_provider.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test(
    'projects sanitized instruction without creating a host tool contract',
    () async {
      final db = appServices.put(DBService());
      await db.init(factory: databaseFactoryMemory, path: 'skill-prompt.db');
      final registry = InstalledSkillRegistry();
      await registry.upsert(
        agentId: 'self',
        skill: MarketplaceSkill.fromJson({
          'skillVersionId': 42,
          'submissionId': 7,
          'skillKey': 'trail-observer',
          'title': 'Trail Observer',
          'summary': 'Collects evidence.',
          'publisherId': 'author-1',
          'versionName': '1.0.0',
          'category': 'observation',
          'instruction': 'List visible facts before proposing a route.',
          'examples': ['Name two clues.'],
          'permissions': ['conversation.read'],
          'manifestDigest': List<String>.filled(64, 'a').join(),
          'isFree': true,
        }),
      );

      final prompt = await InstalledSkillPromptProvider(
        registry: registry,
      ).promptForAgent('self');

      expect(prompt, contains('List visible facts before proposing a route.'));
      expect(prompt, contains('not host capabilities'));
      expect(prompt, isNot(contains('skill.call tool "trail-observer"')));
    },
  );
}
