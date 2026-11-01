import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';

void main() {
  test('turn grant is a prefix bounded by skill count and prompt cost', () {
    final first = SkillDescriptor(
      id: 'first',
      summary: 'first',
      terms: const ['first'],
      promptCost: 70,
    );
    final second = SkillDescriptor(
      id: 'second',
      summary: 'second',
      terms: const ['second'],
      promptCost: 40,
    );

    final grant = TurnSkillGrant.bounded(
      rankedDescriptors: [first, second],
      maxSkills: 4,
      promptBudget: 100,
    );

    expect(grant.allowedSkillIds, {'first'});
    expect(grant.promptCost, 70);
    expect(grant.promptCost, lessThanOrEqualTo(grant.promptBudget));
    expect(() => grant.requireAllowed('second'), throwsStateError);
  });

  test('router never selects a descriptor that exceeds the turn budget', () {
    final router = SkillRouter(
      index: SkillIndex([
        SkillDescriptor(
          id: 'large.skill',
          summary: 'A deliberately large prompt projection',
          terms: const ['large skill'],
          promptCost: 500,
        ),
      ]),
      config: const SkillRouterConfig(promptBudget: 100),
    );

    final decision = router.route('run large skill');

    expect(decision.disposition, SkillRouteDisposition.clarify);
    expect(decision.reason, 'prompt_budget_exhausted');
    expect(decision.grant.isEmpty, isTrue);
  });
}
