import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/page_skill_routing_policy.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_intent_guard.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

class TurnSkillSelection {
  const TurnSkillSelection({required this.decision, required this.grant});

  final SkillRouteDecision decision;
  final TurnSkillGrant grant;

  bool get shouldClarify =>
      decision.disposition == SkillRouteDisposition.clarify && grant.isEmpty;
}

/// Merges deterministic policy hints into ranked router output while keeping
/// the same hard Top-K and prompt budget used by the model-visible grant.
class TurnSkillSelector {
  const TurnSkillSelector({required this.index, required this.router});

  final SkillIndex index;
  final SkillRouter router;

  TurnSkillSelection select(
    String query, {
    String? pageScope,
    Iterable<String> professions = const <String>[],
    Iterable<String> preferredSkillIds = const <String>[],
    PageSkillRoutingPrior pagePrior = PageSkillRoutingPrior.none,
    SurfaceIntent resolvedCreation = SurfaceIntent.none,
    int maxSkills = 6,
    int promptBudget = 8192,
    TurnSkillSnapshotToken? snapshotToken,
  }) {
    final intent = SkillRoutingIntentGuard.analyze(
      query,
      resolvedCreation: resolvedCreation,
    );
    final decision = router.route(
      query,
      pageScope: pageScope,
      professions: professions,
      maxResults: maxSkills,
      intentGuard: intent,
    );
    final ranked = <SkillDescriptor>[
      if (decision.disposition == SkillRouteDisposition.selected)
        ...decision.grant.descriptors,
    ];
    final seen = <String>{for (final descriptor in ranked) descriptor.id};
    final normalizedPageScope = SkillLexicalText.normalize(pageScope ?? '');
    final pagePreferredSkillIds =
        !pagePrior.isEmpty &&
            normalizedPageScope ==
                SkillLexicalText.normalize(pagePrior.pageScope)
        ? pagePrior.eligiblePreferredHostSkillIds(decision.matches)
        : const <String>[];
    for (final preferred in <String>[
      ...preferredSkillIds,
      ...pagePreferredSkillIds,
    ]) {
      final descriptor = index.descriptorById(preferred);
      if (descriptor != null &&
          intent.allows(descriptor) &&
          seen.add(descriptor.id)) {
        ranked.add(descriptor);
      }
    }
    if (ranked.isEmpty) {
      return TurnSkillSelection(decision: decision, grant: TurnSkillGrant.none);
    }
    return TurnSkillSelection(
      decision: decision,
      grant: TurnSkillGrant.bounded(
        rankedDescriptors: ranked,
        maxSkills: maxSkills,
        promptBudget: promptBudget,
        snapshotToken: snapshotToken,
      ),
    );
  }
}
