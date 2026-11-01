import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/learned_skill.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/installed_prompt_skill_adapter.dart';
import 'package:maaso/src/features/agent/application/skill_routing/learned_prompt_skill_adapter.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';

void main() {
  test('renders only entries named by the bounded per-turn grant', () {
    final first = _entry(
      id: 'marketplace:first',
      marker: 'FIRST_PRIVATE_INSTRUCTION',
    );
    final second = _entry(
      id: 'marketplace:second',
      marker: 'SECOND_PRIVATE_INSTRUCTION',
    );
    final snapshot = PromptSkillSnapshot.fromEntries([first, second]);
    final grant = TurnSkillGrant.bounded(
      rankedDescriptors: [first.descriptor],
      maxSkills: 1,
      promptBudget: 2048,
    );

    final prompt = snapshot.renderForGrant(grant, locale: AppLocale.en);

    expect(prompt, contains('FIRST_PRIVATE_INSTRUCTION'));
    expect(prompt, isNot(contains('SECOND_PRIVATE_INSTRUCTION')));
    expect(
      snapshot.renderForGrant(TurnSkillGrant.none, locale: AppLocale.en),
      isEmpty,
    );
  });

  test('selected signature ignores unselected catalog revisions', () {
    final selected = _entry(id: 'learned:selected', marker: 'A', revision: '1');
    final other = _entry(id: 'learned:other', marker: 'B', revision: '1');
    final changedOther = _entry(
      id: 'learned:other',
      marker: 'B changed',
      revision: '2',
    );
    final first = PromptSkillSnapshot.fromEntries([selected, other]);
    final second = PromptSkillSnapshot.fromEntries([selected, changedOther]);

    expect(first.revision, isNot(second.revision));
    expect(
      first.signatureFor([selected.descriptor.id]),
      second.signatureFor([selected.descriptor.id]),
    );
  });

  test('prompt-only sources require non-host namespaces', () {
    expect(
      () => PromptSkillSnapshot.fromEntries([
        PromptSkillEntry(
          source: PromptSkillSource.marketplace,
          descriptor: SkillDescriptor(
            id: 'FreeformSurface',
            summary: 'Must not alias a host skill.',
          ),
          promptFragment: 'Prompt-only instruction.',
          contentRevision: '1',
        ),
      ]),
      throwsArgumentError,
    );
  });

  test('10k catalog keeps routing and prompt projection Top-K bounded', () {
    final entries = [
      for (var index = 0; index < 10000; index++)
        _entry(
          id: 'learned:${index.toString().padLeft(5, '0')}',
          marker: 'PRIVATE_MARKER_$index',
          terms: ['intent_${index.toString().padLeft(5, '0')}'],
        ),
    ];
    final snapshot = PromptSkillSnapshot.fromEntries(entries);
    final router = SkillRouter(index: SkillIndex(snapshot.descriptors));

    final decision = router.route('please run intent_08342 now', maxResults: 6);
    final prompt = snapshot.renderForGrant(
      decision.grant,
      locale: AppLocale.en,
    );

    expect(decision.disposition, SkillRouteDisposition.selected);
    expect(decision.grant.descriptors.length, lessThanOrEqualTo(6));
    expect(decision.grant.descriptors.first.id, 'learned:08342');
    expect(prompt, contains('PRIVATE_MARKER_8342'));
    expect(prompt, isNot(contains('PRIVATE_MARKER_8341')));
    expect(prompt.length, lessThanOrEqualTo(decision.grant.promptBudget));
  });

  test('untruncated Marketplace keys produce stable collision-safe ids', () {
    final sharedPrefix = List<String>.filled(160, '🧠').join();
    final first = _card(
      id: 1,
      key: '$sharedPrefix甲',
      title: 'First',
      instruction: 'first instruction',
    );
    final second = _card(
      id: 2,
      key: '$sharedPrefix乙',
      title: 'Second',
      instruction: 'second instruction',
    );
    const adapter = InstalledPromptSkillAdapter();

    final snapshot = adapter.project([first, second], locale: AppLocale.en);
    final upgraded = adapter.project([
      _card(
        id: 99,
        key: '$sharedPrefix甲',
        title: 'First v2',
        instruction: 'updated instruction',
      ),
    ], locale: AppLocale.en);

    expect(snapshot.entries, hasLength(2));
    expect(snapshot.descriptors.map((entry) => entry.id).toSet(), hasLength(2));
    expect(
      upgraded.descriptors.single.id,
      snapshot.entries
          .singleWhere((entry) => entry.promptFragment.contains('First'))
          .descriptor
          .id,
    );
    expect(
      snapshot.entries.every((entry) => entry.descriptor.id.length == 44),
      isTrue,
    );
  });

  test('untruncated learned ids do not collide after display truncation', () {
    final sharedPrefix = List<String>.filled(160, '🎮').join();
    const adapter = LearnedPromptSkillAdapter();

    final snapshot = adapter.project([
      _learned(id: '$sharedPrefix甲', name: 'First'),
      _learned(id: '$sharedPrefix乙', name: 'Second'),
    ], locale: AppLocale.zh);

    expect(snapshot.entries, hasLength(2));
    expect(snapshot.descriptors.map((entry) => entry.id).toSet(), hasLength(2));
    expect(
      snapshot.entries.every((entry) => entry.descriptor.id.length == 40),
      isTrue,
    );
    expect(
      snapshot.entries.every(
        (entry) => entry.promptFragment.runes.length < 500,
      ),
      isTrue,
    );
  });
}

PromptSkillEntry _entry({
  required String id,
  required String marker,
  String revision = '1',
  List<String> terms = const <String>[],
}) {
  final descriptor = SkillDescriptor(
    id: id,
    summary: marker,
    terms: terms,
    promptCost: marker.length + PromptSkillSnapshot.perEntryPromptOverhead,
  );
  return PromptSkillEntry(
    source: id.startsWith('marketplace:')
        ? PromptSkillSource.marketplace
        : PromptSkillSource.learned,
    descriptor: descriptor,
    promptFragment: marker,
    contentRevision: revision,
  );
}

InstalledSkillCard _card({
  required int id,
  required String key,
  required String title,
  required String instruction,
}) => InstalledSkillCard(
  agentId: 'self',
  mastery: MasteryBucket.growing,
  skill: MarketplaceSkill(
    skillVersionId: id,
    submissionId: id,
    skillKey: key,
    title: title,
    summary: 'Summary $title',
    coverAssetUrl: '',
    publisherId: 'author',
    versionName: '1.0.0',
    permissions: const <String>{},
    category: SkillCategory.reasoning,
    instruction: instruction,
    examples: const <String>[],
    manifestDigest: 'digest',
    isFree: true,
  ),
);

LearnedSkill _learned({required String id, required String name}) =>
    LearnedSkill(
      id: id,
      name: name,
      triggers: const <String>['play now'],
      steps: const <LearnedStep>[],
      summary: '',
    );
