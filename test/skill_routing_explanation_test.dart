import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_explanation.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_observability.dart';
import 'package:maaso/src/features/agent/application/skill_routing/turn_skill_selector.dart';

void main() {
  test('policy grants do not turn a router ambiguity into a measured hit', () {
    final index = SkillIndex([
      SkillDescriptor(id: 'comment.news', summary: '', terms: ['评论']),
      SkillDescriptor(id: 'comment.video', summary: '', terms: ['评论']),
    ]);
    final selector = TurnSkillSelector(
      index: index,
      router: SkillRouter(index: index),
    );
    final selection = selector.select(
      '帮我评论一下',
      preferredSkillIds: ['comment.news'],
    );
    final explanation = SkillRoutingExplanation.fromDecision(
      decision: selection.decision,
      grant: selection.grant,
      policyPreferredSkillIds: ['COMMENT.NEWS'],
    );
    final collector = SkillRoutingMetricsCollector(retainedRouteLimit: 0);
    collector.recordRouting(_observation(explanation, selectedK: 1));

    final snapshot = collector.snapshot();
    expect(selection.decision.disposition, SkillRouteDisposition.clarify);
    expect(selection.grant.allowedSkillIds, {'comment.news'});
    expect(explanation.reason, SkillRoutingReason.ambiguous);
    expect(explanation.routerDisposition, SkillRouteDisposition.clarify);
    expect(explanation.policyAddedCount, 1);
    expect(explanation.pageAddedCount, 0);
    expect(snapshot.dispositionCounts[SkillRouteDisposition.selected], 1);
    expect(
      snapshot.explanations['router_dispositions'],
      containsPair('clarify', 1),
    );
    expect(snapshot.explanations['reasons'], containsPair('ambiguous', 1));
    expect(snapshot.explanations['policy_added_total'], 1);
    expect(snapshot.recentRoutes, isEmpty);
  });

  test(
    'only granted additions are counted and policy/page overlap counts once',
    () {
      final routed = SkillDescriptor(id: 'routed', summary: '', promptCost: 10);
      final policy = SkillDescriptor(id: 'policy', summary: '', promptCost: 10);
      final page = SkillDescriptor(id: 'page', summary: '', promptCost: 10);
      final excluded = SkillDescriptor(
        id: 'excluded',
        summary: '',
        promptCost: 10,
      );
      final routerGrant = TurnSkillGrant.bounded(
        rankedDescriptors: [routed],
        maxSkills: 3,
        promptBudget: 30,
      );
      final decision = SkillRouteDecision.selected(
        matches: [],
        confidence: 0.8,
        margin: 0.4,
        grant: routerGrant,
      );
      final grant = TurnSkillGrant.bounded(
        rankedDescriptors: [routed, policy, page, excluded],
        maxSkills: 3,
        promptBudget: 30,
      );
      final explanation = SkillRoutingExplanation.fromDecision(
        decision: decision,
        grant: grant,
        policyPreferredSkillIds: ['routed', 'policy', 'excluded'],
        pagePreferredSkillIds: ['policy', 'page', 'excluded'],
      );
      expect(explanation.policyAddedCount, 1);
      expect(explanation.pageAddedCount, 1);
      expect(
        explanation.confidenceBand,
        SkillRoutingScoreBand.atLeastThreeQuarters,
      );
      expect(explanation.marginBand, SkillRoutingScoreBand.quarterToHalf);
    },
  );

  test(
    'fixed corpus distinguishes routing failure reasons without changing decisions',
    () {
      final navigation = SkillDescriptor(
        id: 'AppNavigate',
        summary: '',
        terms: ['设置'],
        negativeTerms: ['不要'],
      );
      final fixtures =
          <({String query, SkillRouter router, SkillRoutingReason reason})>[
            (
              query: 'hello',
              router: SkillRouter(index: SkillIndex([navigation])),
              reason: SkillRoutingReason.noLexicalMatch,
            ),
            (
              query: '不要打开设置',
              router: SkillRouter(index: SkillIndex([navigation])),
              reason: SkillRoutingReason.nonActionContext,
            ),
            (
              query: '设置 仅为示例',
              router: SkillRouter(
                index: SkillIndex([
                  SkillDescriptor(
                    id: 'AppNavigate',
                    summary: '',
                    terms: ['设置'],
                    negativeTerms: ['仅为示例'],
                  ),
                ]),
              ),
              reason: SkillRoutingReason.insufficientEvidence,
            ),
            (
              query: 'draftword please extra',
              router: SkillRouter(
                index: SkillIndex([
                  SkillDescriptor(
                    id: 'creator',
                    summary: '',
                    terms: ['draftword extra'],
                  ),
                ]),
              ),
              reason: SkillRoutingReason.lowConfidence,
            ),
            (
              query: '打开设置',
              router: SkillRouter(
                index: SkillIndex([navigation]),
                config: const SkillRouterConfig(promptBudget: 1),
              ),
              reason: SkillRoutingReason.promptBudgetExhausted,
            ),
            (
              query: '打开设置',
              router: SkillRouter(index: SkillIndex([navigation])),
              reason: SkillRoutingReason.selected,
            ),
          ];
      for (final fixture in fixtures) {
        final decision = fixture.router.route(fixture.query);
        final explanation = SkillRoutingExplanation.fromDecision(
          decision: decision,
          grant: decision.grant,
        );
        expect(explanation.reason, fixture.reason, reason: fixture.query);
        expect(explanation.routerDisposition, decision.disposition);
        expect(explanation.policyAddedCount, 0);
        expect(explanation.pageAddedCount, 0);
        expect(
          fixture.router.route(fixture.query).grant.allowedSkillIds,
          decision.grant.allowedSkillIds,
        );
      }
    },
  );

  test('score buckets have exact boundaries and preserve unknown values', () {
    expect(
      SkillRoutingScoreBand.fromScore(0),
      SkillRoutingScoreBand.belowQuarter,
    );
    expect(
      SkillRoutingScoreBand.fromScore(0.25),
      SkillRoutingScoreBand.quarterToHalf,
    );
    expect(
      SkillRoutingScoreBand.fromScore(0.5),
      SkillRoutingScoreBand.halfToThreeQuarters,
    );
    expect(
      SkillRoutingScoreBand.fromScore(0.75),
      SkillRoutingScoreBand.atLeastThreeQuarters,
    );
    expect(
      SkillRoutingScoreBand.fromScore(1),
      SkillRoutingScoreBand.atLeastThreeQuarters,
    );
    for (final invalid in [double.nan, double.infinity, -0.1, 1.1]) {
      expect(
        SkillRoutingScoreBand.fromScore(invalid),
        SkillRoutingScoreBand.unknown,
      );
    }
  });

  test('unknown free-form reasons and identifiers are never exported', () {
    const privateReason = 'private query and account detail';
    final decision = SkillRouteDecision.noTool(reason: privateReason);
    final explanation = SkillRoutingExplanation.fromDecision(
      decision: decision,
      grant: TurnSkillGrant.none,
      policyPreferredSkillIds: ['private-skill-id'],
    );
    final collector = SkillRoutingMetricsCollector(retainedRouteLimit: 1);
    collector.recordRouting(_observation(explanation));
    final snapshot = collector.snapshot();
    final json = jsonEncode(snapshot.toJson());
    expect(explanation.reason, SkillRoutingReason.unknown);
    expect(json, isNot(contains(privateReason)));
    expect(json, isNot(contains('private-skill-id')));
    expect(snapshot.explanations['reasons'], containsPair('unknown', 1));
    expect(() => snapshot.explanations['reasons'] = {}, throwsUnsupportedError);
    expect(
      () => (snapshot.explanations['reasons'] as Map)['unknown'] = 9,
      throwsUnsupportedError,
    );
  });
}

SkillRoutingObservation _observation(
  SkillRoutingExplanation explanation, {
  int selectedK = 0,
}) => SkillRoutingObservation(
  routingLatency: const Duration(microseconds: 100),
  catalogSize: 2,
  candidateCount: 2,
  selectedK: selectedK,
  promptCostUnits: 0,
  promptBytesEstimate: 0,
  disposition: selectedK > 0
      ? SkillRouteDisposition.selected
      : SkillRouteDisposition.noTool,
  explanation: explanation,
);
