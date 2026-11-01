import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
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
    'keeps sanitized installed cards per agent and replaces an old version',
    () async {
      final db = appServices.put(DBService());
      await db.init(
        factory: databaseFactoryMemory,
        path: 'installed-skills.db',
      );
      final registry = InstalledSkillRegistry();

      await registry.upsert(
        agentId: 'self',
        skill: _skill(skillVersionId: 41, versionName: '1.0.0'),
      );
      await registry.upsert(
        agentId: 'self',
        skill: _skill(skillVersionId: 42, versionName: '1.1.0'),
        mastery: MasteryBucket.growing,
      );

      final installed = await registry.installedForAgent('self');

      expect(installed, hasLength(1));
      expect(installed.single.skill.skillVersionId, 42);
      expect(installed.single.skill.instruction, 'Check visible facts first.');
      expect(installed.single.skill.examples, ['Name two clues.']);
      expect(installed.single.mastery, MasteryBucket.growing);
      expect(installed.single.skill.permissions, {'conversation.read'});
    },
  );

  test(
    'sync removes inactive cards and keeps mastery for active Skills',
    () async {
      final db = appServices.put(DBService());
      await db.init(
        factory: databaseFactoryMemory,
        path: 'installed-skills-sync.db',
      );
      final registry = InstalledSkillRegistry();
      final first = _skill(skillVersionId: 41, versionName: '1.0.0');
      final second = MarketplaceSkill.fromJson({
        ..._skill(skillVersionId: 52, versionName: '2.0.0').toSanitizedJson(),
        'skillKey': 'route-planner',
        'title': 'Route Planner',
      });

      await registry.upsert(
        agentId: 'self',
        skill: first,
        mastery: MasteryBucket.expert,
      );
      await registry.syncActiveSkills(agentId: 'self', skills: [first, second]);
      await registry.syncActiveSkills(agentId: 'self', skills: [first]);

      final installed = await registry.installedForAgent('self');

      expect(installed, hasLength(1));
      expect(installed.single.skill.skillVersionId, 41);
      expect(installed.single.mastery, MasteryBucket.expert);

      await registry.remove(agentId: 'self', skillVersionId: 41);
      expect(await registry.installedForAgent('self'), isEmpty);
    },
  );
}

MarketplaceSkill _skill({
  required int skillVersionId,
  required String versionName,
}) {
  return MarketplaceSkill.fromJson({
    'skillVersionId': skillVersionId,
    'submissionId': 7,
    'skillKey': 'trail-observer',
    'title': 'Trail Observer',
    'summary': 'Collects evidence before choices.',
    'publisherId': 'author-1',
    'versionName': versionName,
    'category': 'observation',
    'instruction': 'Check visible facts first.',
    'examples': ['Name two clues.'],
    'permissions': ['conversation.read'],
    'manifestDigest': List<String>.filled(64, 'a').join(),
    'isFree': true,
  });
}
