import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';

/// The offline-safe local source of installed remote Skill cards. Only the
/// server-sanitized manifest projection is persisted; package bytes and raw
/// training data never enter Sembast.
class InstalledSkillRegistry extends AppService {
  InstalledSkillRegistry({DBService? database})
    : _database = database ?? appServices.find<DBService>();

  static final _store = StoreRef<String, Map<String, Object?>>(
    'installed_skill_cards',
  );

  final DBService _database;

  Future<void> upsert({
    required String agentId,
    required MarketplaceSkill skill,
    MasteryBucket mastery = MasteryBucket.newSkill,
  }) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty || skill.skillVersionId <= 0) {
      throw StateError('Agent and installed Skill version are required');
    }
    if (skill.isRetiredOfficialSkill || skill.hasRetiredWorldPermissions) {
      await remove(
        agentId: normalizedAgentId,
        skillVersionId: skill.skillVersionId,
      );
      return;
    }
    await _database.raw.transaction((transaction) async {
      final existing = await _store.find(
        transaction,
        finder: Finder(filter: Filter.equals('agentId', normalizedAgentId)),
      );
      for (final record in existing) {
        final stored = InstalledSkillCard.fromJson(record.value);
        if (stored.skill.skillKey == skill.skillKey &&
            stored.skill.skillVersionId != skill.skillVersionId) {
          await _store.record(record.key).delete(transaction);
        }
      }
      await _store
          .record(_key(normalizedAgentId, skill.skillVersionId))
          .put(
            transaction,
            InstalledSkillCard(
              agentId: normalizedAgentId,
              skill: skill,
              mastery: mastery,
            ).toJson(),
          );
    });
  }

  Future<void> updateMastery({
    required String agentId,
    required int skillVersionId,
    required MasteryBucket mastery,
  }) async {
    final key = _key(agentId.trim(), skillVersionId);
    final current = await _store.record(key).get(_database.raw);
    if (current == null) return;
    await _store.record(key).update(_database.raw, {
      'masteryBucket': mastery.wireValue,
    });
  }

  Future<void> remove({
    required String agentId,
    required int skillVersionId,
  }) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty || skillVersionId <= 0) return;
    await _store
        .record(_key(normalizedAgentId, skillVersionId))
        .delete(_database.raw);
  }

  Future<void> syncActiveSkills({
    required String agentId,
    required Iterable<MarketplaceSkill> skills,
  }) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty) {
      throw StateError('Agent id is required to sync installed Skills');
    }
    final activeByVersion = <int, MarketplaceSkill>{
      for (final skill in skills)
        if (skill.skillVersionId > 0 &&
            !skill.isRetiredOfficialSkill &&
            !skill.hasRetiredWorldPermissions)
          skill.skillVersionId: skill,
    };
    await _database.raw.transaction((transaction) async {
      final existing = await _store.find(
        transaction,
        finder: Finder(filter: Filter.equals('agentId', normalizedAgentId)),
      );
      final masteryByVersion = <int, MasteryBucket>{};
      for (final record in existing) {
        final stored = InstalledSkillCard.fromJson(record.value);
        masteryByVersion[stored.skill.skillVersionId] = stored.mastery;
        if (!activeByVersion.containsKey(stored.skill.skillVersionId)) {
          await _store.record(record.key).delete(transaction);
        }
      }
      for (final entry in activeByVersion.entries) {
        await _store
            .record(_key(normalizedAgentId, entry.key))
            .put(
              transaction,
              InstalledSkillCard(
                agentId: normalizedAgentId,
                skill: entry.value,
                mastery: masteryByVersion[entry.key] ?? MasteryBucket.newSkill,
              ).toJson(),
            );
      }
    });
  }

  Future<List<InstalledSkillCard>> installedForAgent(String agentId) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty) return const <InstalledSkillCard>[];
    final records = await _store.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('agentId', normalizedAgentId)),
    );
    final cards = <InstalledSkillCard>[];
    for (final record in records) {
      final card = InstalledSkillCard.fromJson(record.value);
      if (card.skill.isRetiredOfficialSkill ||
          card.skill.hasRetiredWorldPermissions) {
        // Purge retired cached cards even when the device is
        // offline; neither prompt projection nor locale refresh can revive it.
        await _store.record(record.key).delete(_database.raw);
        continue;
      }
      cards.add(card);
    }
    cards.sort((left, right) {
      final byCategory = _categoryOrder(
        left.skill.category,
      ).compareTo(_categoryOrder(right.skill.category));
      if (byCategory != 0) return byCategory;
      return left.skill.title.compareTo(right.skill.title);
    });
    return List.unmodifiable(cards);
  }

  static String _key(String agentId, int skillVersionId) =>
      '$agentId:$skillVersionId';
}

class InstalledSkillCard {
  const InstalledSkillCard({
    required this.agentId,
    required this.skill,
    required this.mastery,
  });

  final String agentId;
  final MarketplaceSkill skill;
  final MasteryBucket mastery;

  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'skill': skill.toSanitizedJson(),
    'masteryBucket': mastery.wireValue,
  };

  factory InstalledSkillCard.fromJson(Map<String, Object?> json) {
    final rawSkill = json['skill'];
    if (rawSkill is! Map) throw StateError('Installed Skill card is invalid');
    return InstalledSkillCard(
      agentId: json['agentId']?.toString().trim() ?? '',
      skill: MarketplaceSkill.fromJson(Map<String, dynamic>.from(rawSkill)),
      mastery: MasteryBucket.fromWire(json['masteryBucket']),
    );
  }
}

int _categoryOrder(SkillCategory category) => switch (category) {
  SkillCategory.observation => 0,
  SkillCategory.reasoning => 1,
  SkillCategory.collaboration => 2,
  SkillCategory.unknown => 3,
};
