import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/installed_prompt_skill_adapter.dart';
import 'package:maaso/src/features/skills/data/installed_skill_prompt_provider.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'legacy effects are ignored without rewriting ordinary skill authority or digest',
    () {
      final original = _json(42);
      final skill = MarketplaceSkill.fromJson({
        ...original,
        'effects': [
          {'old': 'not an executable host feature'},
        ],
      });
      expect(skill.canInstall, isTrue);
      expect(skill.permissions, {'conversation.read'});
      expect(skill.manifestDigest, original['manifestDigest']);
      expect(skill.toSanitizedJson().containsKey('effects'), isFalse);
      expect(
        MarketplaceSkill.fromJson({
          ...original,
          'effects': 'invalid old shape',
        }).canInstall,
        isTrue,
      );
    },
  );

  test('World permission cards preserve metadata but cannot be installed', () {
    final skill = _skill(71, retired: true);
    expect(skill.hasRetiredWorldPermissions, isTrue);
    expect(skill.canInstall, isFalse);
    expect(skill.permissions, {'world.effect.play'});
    expect(skill.manifestDigest, 'a' * 64);
  });

  test(
    'offline cached World cards are purged while ordinary cards remain',
    () async {
      final db = await _database();
      final records = StoreRef<String, Map<String, Object?>>(
        'installed_skill_cards',
      );
      for (final skill in [_skill(71, retired: true), _skill(42)]) {
        await records.record('self:${skill.skillVersionId}').put(db.raw, {
          'agentId': 'self',
          'skill': {
            ...skill.toSanitizedJson(),
            'effects': {'legacy': true},
          },
          'masteryBucket': 'growing',
        });
      }
      final registry = InstalledSkillRegistry(database: db);
      final cards = await registry.installedForAgent('self');
      expect(cards.map((card) => card.skill.skillVersionId), [42]);
      expect(await records.record('self:71').get(db.raw), isNull);
      expect(
        (await records.record('self:42').get(db.raw))!['skill'],
        containsPair('manifestDigest', 'a' * 64),
      );
    },
  );

  test('stale upsert and sync cannot revive a retired World card', () async {
    final db = await _database();
    final registry = InstalledSkillRegistry(database: db);
    final ordinary = _skill(42);
    await registry.upsert(
      agentId: 'self',
      skill: ordinary,
      mastery: MasteryBucket.expert,
    );
    await registry.upsert(agentId: 'self', skill: _skill(71, retired: true));
    await registry.syncActiveSkills(
      agentId: 'self',
      skills: [ordinary, _skill(71, retired: true)],
    );
    final cards = await registry.installedForAgent('self');
    expect(cards.map((card) => card.skill.skillVersionId), [42]);
    expect(cards.single.mastery, MasteryBucket.expert);
  });

  test(
    'both declarative prompt boundaries reject stale World guidance',
    () async {
      final db = await _database();
      final cards = [
        for (final skill in [_skill(71, retired: true), _skill(42)])
          InstalledSkillCard(
            agentId: 'self',
            skill: skill,
            mastery: MasteryBucket.newSkill,
          ),
      ];
      final snapshot = const InstalledPromptSkillAdapter().project(
        cards,
        locale: AppLocale.en,
      );
      expect(snapshot.entries, hasLength(1));
      expect(
        snapshot.entries.single.promptFragment,
        contains('ORDINARY_GUIDANCE'),
      );
      expect(
        snapshot.entries.single.promptFragment,
        isNot(contains('RETIRED_WORLD_GUIDANCE')),
      );
      final prompt = await InstalledSkillPromptProvider(
        registry: _UnfilteredRegistry(db, cards),
      ).promptForAgent('self', locale: AppLocale.en);
      expect(prompt, contains('ORDINARY_GUIDANCE'));
      expect(prompt, isNot(contains('RETIRED_WORLD_GUIDANCE')));
    },
  );
}

Future<DBService> _database() async {
  final db = appServices.put(DBService());
  await db.init(factory: databaseFactoryMemory, path: 'retired-world-skill.db');
  return db;
}

Map<String, dynamic> _json(int version, {bool retired = false}) => {
  'skillVersionId': version,
  'skillKey': 'skill-$version',
  'title': 'Guide $version',
  'publisherId': 'author',
  'versionName': '1.0.0',
  'category': 'reasoning',
  'instruction': retired ? 'RETIRED_WORLD_GUIDANCE' : 'ORDINARY_GUIDANCE',
  'examples': <String>[],
  'permissions': [retired ? 'world.effect.play' : 'conversation.read'],
  'manifestDigest': 'a' * 64,
  'isFree': true,
  'safetyStatus': 'passed',
};

MarketplaceSkill _skill(int version, {bool retired = false}) =>
    MarketplaceSkill.fromJson(_json(version, retired: retired));

class _UnfilteredRegistry extends InstalledSkillRegistry {
  _UnfilteredRegistry(DBService db, this.cards) : super(database: db);
  final List<InstalledSkillCard> cards;
  @override
  Future<List<InstalledSkillCard>> installedForAgent(String agentId) async =>
      cards;
}
