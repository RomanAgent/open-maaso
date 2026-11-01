import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_skill_prompt_metadata.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart'
    as builtin;
import 'package:maaso/src/features/agent/application/skill_routing/installed_prompt_skill_adapter.dart';
import 'package:maaso/src/features/skills/data/installed_skill_locale_refresher.dart';
import 'package:maaso/src/features/skills/data/installed_skill_prompt_provider.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });
  tearDown(appServices.reset);

  test(
    'catalog and prompt metadata only advertise executable retained skills',
    () {
      const retiredIds = {
        'soul',
        'set_ui_style',
        'translate',
        '__coming_calendar',
        'weather',
        'trip_plan',
        'calc',
        'set_theme',
        'avatar_motion_learning',
      };
      const retiredNames = {
        'RealWeather',
        'TripPlan',
        'Calc',
        'SetTheme',
        'AvatarMotionLearning',
      };
      final ids = builtin.SkillCatalog.all.map((skill) => skill.id).toSet();
      expect(ids.intersection(retiredIds), isEmpty);
      expect(builtin.SkillCatalog.coreIds.intersection(retiredIds), isEmpty);
      expect(
        builtin.SkillCatalog.defaultConfigured.intersection(retiredIds),
        isEmpty,
      );
      expect(
        builtin.SkillCatalog.defaultEnabled.intersection(retiredIds),
        isEmpty,
      );
      expect(
        builtin.SkillCatalog.all.every((skill) => skill.factory != null),
        isTrue,
      );
      for (final id in retiredIds) {
        expect(builtin.SkillCatalog.byId(id), isNull, reason: id);
      }
      expect(
        builtin.SkillCatalog.all
            .map((skill) => skill.localManifest?.skillName)
            .whereType<String>()
            .toSet()
            .intersection(retiredNames),
        isEmpty,
      );
      expect(
        builtin.SkillCatalog.all
            .map((skill) => skill.hostRouting?.skillName)
            .whereType<String>()
            .toSet()
            .intersection(retiredNames),
        isEmpty,
      );
      expect(
        AgentSkillPromptMetadata.builtInSkillNames.intersection({
          'SoulControl',
          'SetUiStyle',
          'Translate',
          'WeatherQuery',
          ...retiredNames,
        }),
        isEmpty,
      );
      for (final id in [
        'set_soul',
        'face',
        'web_search',
        'scheduled_task',
        'app_control',
        'app_navigate',
      ]) {
        expect(builtin.SkillCatalog.byId(id)?.factory, isNotNull, reason: id);
      }
    },
  );

  test(
    'old enabled preferences are pruned without re-enabling optional skills',
    () async {
      SharedPreferences.setMockInitialValues({
        'enabledSkills.self': <String>[
          'soul',
          'set_ui_style',
          'translate',
          'weather',
          'trip_plan',
          'calc',
          'set_theme',
          'avatar_motion_learning',
          'bluetooth',
        ],
      });
      final registry = AgentRuntimeRegistry();
      final enabled = await registry.readEnabledSkills('self');
      expect(enabled, contains('bluetooth'));
      expect(enabled, containsAll(builtin.SkillCatalog.coreIds));
      expect(enabled, isNot(contains('weather')));
      expect(
        enabled.intersection({
          'soul',
          'set_ui_style',
          'translate',
          'weather',
          'trip_plan',
          'calc',
          'set_theme',
          'avatar_motion_learning',
        }),
        isEmpty,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('enabledSkills.self')!.toSet(), enabled);

      await registry.setEnabledSkills('peer', {
        'translate',
        '__coming_calendar',
        'weather',
        'trip_plan',
        'calc',
        'set_theme',
        'avatar_motion_learning',
        'web_search',
      });
      final peer = await registry.readEnabledSkills('peer');
      expect(peer, contains('web_search'));
      expect(
        peer.intersection({
          'translate',
          '__coming_calendar',
          'weather',
          'trip_plan',
          'calc',
          'set_theme',
          'avatar_motion_learning',
        }),
        isEmpty,
      );
      expect(prefs.getStringList('enabledSkills.self')!.toSet(), enabled);
    },
  );

  test(
    'retirement identifies only the official publisher and exact skill key',
    () {
      expect(_skill(41).isRetiredOfficialSkill, isTrue);
      expect(_skill(41).canInstall, isFalse);
      final author = _skill(42, publisherId: 'author-42');
      expect(author.isRetiredOfficialSkill, isFalse);
      expect(author.canInstall, isTrue);
      final otherOfficial = _skill(43, key: 'official-guide');
      expect(otherOfficial.isRetiredOfficialSkill, isFalse);
      expect(otherOfficial.canInstall, isTrue);
    },
  );

  test(
    'offline historical cards are purged while author and other agents survive',
    () async {
      final db = await _database('retired-skill-offline.db');
      final store = StoreRef<String, Map<String, Object?>>(
        'installed_skill_cards',
      );
      final official = _card('self', _skill(41));
      final author = _card('self', _skill(42, publisherId: 'author-42'));
      final peer = _card('peer', _skill(43));
      await store.record('self:41').put(db.raw, official.toJson());
      await store.record('self:42').put(db.raw, author.toJson());
      await store.record('peer:43').put(db.raw, peer.toJson());
      final registry = InstalledSkillRegistry(database: db);

      final installed = await registry.installedForAgent('self');
      expect(installed, hasLength(1));
      expect(installed.single.skill.publisherId, 'author-42');
      expect(installed.single.mastery, MasteryBucket.expert);
      expect(await store.record('self:41').get(db.raw), isNull);
      expect(await store.record('self:42').get(db.raw), author.toJson());
      expect(await store.record('peer:43').get(db.raw), peer.toJson());

      var loadCalls = 0;
      await InstalledSkillLocaleRefresher(
        registry: registry,
        loadSkill: (_) async {
          loadCalls++;
          return author.skill;
        },
      ).refreshForAgent('self', expectedLocale: AppLocale.en);
      expect(loadCalls, 1);
      expect(await registry.installedForAgent('peer'), isEmpty);
      expect(await store.record('peer:43').get(db.raw), isNull);
    },
  );

  test(
    'stale install and sync responses cannot restore retired official cards',
    () async {
      final db = await _database('retired-skill-sync.db');
      final registry = InstalledSkillRegistry(database: db);
      final author = _skill(42, publisherId: 'author-42');
      await registry.upsert(
        agentId: 'self',
        skill: author,
        mastery: MasteryBucket.expert,
      );
      await registry.upsert(agentId: 'self', skill: _skill(41));
      await registry.syncActiveSkills(
        agentId: 'self',
        skills: [_skill(41), author],
      );
      final installed = await registry.installedForAgent('self');
      expect(installed, hasLength(1));
      expect(installed.single.skill.skillVersionId, 42);
      expect(installed.single.mastery, MasteryBucket.expert);
    },
  );

  test(
    'both prompt boundaries omit retired cached guidance and preserve author content',
    () async {
      final cards = [
        _card('self', _skill(41)),
        _card('self', _skill(42, publisherId: 'author-42')),
      ];
      final snapshot = const InstalledPromptSkillAdapter().project(
        cards,
        locale: AppLocale.en,
      );
      expect(snapshot.entries, hasLength(1));
      expect(snapshot.entries.single.promptFragment, contains('AUTHOR_MARKER'));
      expect(
        snapshot.entries.single.promptFragment,
        isNot(contains('RETIRED_MARKER')),
      );
      final prompt = await InstalledSkillPromptProvider(
        registry: _UnfilteredRegistry(cards),
      ).promptForAgent('self', locale: AppLocale.en);
      expect(prompt, contains('AUTHOR_MARKER'));
      expect(prompt, isNot(contains('RETIRED_MARKER')));
    },
  );
}

Future<DBService> _database(String path) async {
  final database = appServices.put(DBService());
  await database.init(factory: databaseFactoryMemory, path: path);
  return database;
}

MarketplaceSkill _skill(
  int id, {
  String publisherId = MarketplaceSkill.officialPublisherId,
  String key = 'quick-observe',
}) => MarketplaceSkill.fromJson({
  'skillVersionId': id,
  'submissionId': id + 100,
  'skillKey': key,
  'title': 'Quick Observe',
  'summary': 'Publisher-owned instruction.',
  'publisherId': publisherId,
  'versionName': '1.0.0',
  'category': 'observation',
  'instruction': publisherId == MarketplaceSkill.officialPublisherId
      ? 'RETIRED_MARKER'
      : 'AUTHOR_MARKER',
  'examples': <String>[],
  'permissions': <String>[],
  'manifestDigest': 'digest',
  'isFree': true,
  'contentLocale': 'en',
});

InstalledSkillCard _card(String agentId, MarketplaceSkill skill) =>
    InstalledSkillCard(
      agentId: agentId,
      skill: skill,
      mastery: MasteryBucket.expert,
    );

class _UnfilteredRegistry extends InstalledSkillRegistry {
  _UnfilteredRegistry(this.cards) : super(database: DBService());
  final List<InstalledSkillCard> cards;
  @override
  Future<List<InstalledSkillCard>> installedForAgent(String agentId) async =>
      cards;
}
