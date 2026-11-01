import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_page_scope.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/turn_skill_selector.dart';

void main() {
  test('policy preferences can grant a skill without exposing the catalog', () {
    final index = SkillIndex(<SkillDescriptor>[
      SkillDescriptor(
        id: 'WebSearch',
        summary: 'Search',
        terms: const ['search'],
      ),
      SkillDescriptor(
        id: 'Calc',
        summary: 'Calculate',
        terms: const ['calculate'],
      ),
    ]);
    final selector = TurnSkillSelector(
      index: index,
      router: SkillRouter(index: index),
    );

    final selected = selector.select(
      '查一下今天的资料',
      preferredSkillIds: const <String>['WebSearch'],
    );

    expect(selected.grant.allowedSkillIds, <String>{'WebSearch'});
    expect(selected.grant.allows('Calc'), isFalse);
  });

  test('selected and preferred skills share one bounded grant', () {
    final index = SkillIndex(<SkillDescriptor>[
      SkillDescriptor(id: 'Calc', summary: 'Calculate', terms: const ['计算']),
      SkillDescriptor(id: 'Todo', summary: 'Checklist', terms: const ['待办']),
      SkillDescriptor(id: 'WebSearch', summary: 'Search', terms: const ['搜索']),
    ]);
    final selector = TurnSkillSelector(
      index: index,
      router: SkillRouter(index: index),
    );

    final selected = selector.select(
      '计算 1+2',
      preferredSkillIds: const <String>['Todo', 'WebSearch'],
      maxSkills: 2,
    );

    expect(selected.grant.allowedSkillIds, <String>{'Calc', 'Todo'});
    expect(selected.grant.allows('WebSearch'), isFalse);
  });

  test('route URI produces a stable page-scope prior', () {
    expect(
      SkillPageScope.fromRoute('/agent-media?channel=news'),
      'agent_media.news',
    );
    expect(SkillPageScope.fromRoute('/settings'), 'settings');
    expect(SkillPageScope.fromRoute('/selfie'), 'selfie');
    expect(
      SkillPageScope.fromRoute('/selfie?creatorPrompt=wave#director'),
      'selfie',
    );
    expect(SkillPageScope.fromRoute('/unknown'), isNull);
  });

  test('selection pins the immutable prompt snapshot used for the turn', () {
    const id = 'marketplace:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    PromptSkillSnapshot snapshot(String fragment, String revision) =>
        PromptSkillSnapshot.fromEntries([
          PromptSkillEntry(
            source: PromptSkillSource.marketplace,
            descriptor: SkillDescriptor(
              id: id,
              summary: 'Alpha ritual helper',
              terms: const <String>['alpha ritual'],
            ),
            promptFragment: fragment,
            contentRevision: revision,
          ),
        ], locale: AppLocale.en);

    TurnSkillSelection select(PromptSkillSnapshot catalog) {
      final index = SkillIndex(catalog.descriptors);
      return TurnSkillSelector(
        index: index,
        router: SkillRouter(index: index),
      ).select('alpha ritual', snapshotToken: catalog);
    }

    final oldCatalog = snapshot('OLD_ALPHA_INSTRUCTION', 'old');
    final oldTurn = select(oldCatalog);
    final newCatalog = snapshot('NEW_ALPHA_INSTRUCTION', 'new');
    final newTurn = select(newCatalog);

    expect(identical(oldTurn.grant.snapshotToken, oldCatalog), isTrue);
    expect(identical(newTurn.grant.snapshotToken, newCatalog), isTrue);
    expect(
      (oldTurn.grant.snapshotToken! as PromptSkillSnapshot).renderForGrant(
        oldTurn.grant,
        locale: AppLocale.en,
      ),
      allOf(contains('OLD_ALPHA_INSTRUCTION'), isNot(contains('NEW_ALPHA'))),
    );
    expect(
      (newTurn.grant.snapshotToken! as PromptSkillSnapshot).renderForGrant(
        newTurn.grant,
        locale: AppLocale.en,
      ),
      allOf(contains('NEW_ALPHA_INSTRUCTION'), isNot(contains('OLD_ALPHA'))),
    );
  });
}
