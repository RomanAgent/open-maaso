import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';

enum SkillRoutingReason {
  unknown,
  noLexicalMatch,
  insufficientEvidence,
  lowConfidence,
  ambiguous,
  promptBudgetExhausted,
  selected,
  nonActionContext;

  static SkillRoutingReason fromRouterReason(String reason) => switch (reason) {
    'no_lexical_match' => noLexicalMatch,
    'insufficient_evidence' => insufficientEvidence,
    'low_confidence' => lowConfidence,
    'ambiguous' => ambiguous,
    'prompt_budget_exhausted' => promptBudgetExhausted,
    'selected' => selected,
    'non_action_context' => nonActionContext,
    _ => unknown,
  };
}

/// Fixed buckets for heuristic router scores, not calibrated probabilities.
enum SkillRoutingScoreBand {
  unknown,
  belowQuarter,
  quarterToHalf,
  halfToThreeQuarters,
  atLeastThreeQuarters;

  static SkillRoutingScoreBand fromScore(double score) {
    if (!score.isFinite || score < 0 || score > 1) return unknown;
    if (score < 0.25) return belowQuarter;
    if (score < 0.5) return quarterToHalf;
    if (score < 0.75) return halfToThreeQuarters;
    return atLeastThreeQuarters;
  }
}

/// A bounded explanation without text, matched terms, or skill identifiers.
/// The raw router decision remains distinct from the final policy/page grant.
class SkillRoutingExplanation {
  const SkillRoutingExplanation._({
    required this.reason,
    required this.routerDisposition,
    required this.confidenceBand,
    required this.marginBand,
    required this.policyAddedCount,
    required this.pageAddedCount,
  });

  static const unknown = SkillRoutingExplanation._(
    reason: SkillRoutingReason.unknown,
    routerDisposition: null,
    confidenceBand: SkillRoutingScoreBand.unknown,
    marginBand: SkillRoutingScoreBand.unknown,
    policyAddedCount: 0,
    pageAddedCount: 0,
  );

  factory SkillRoutingExplanation.fromDecision({
    required SkillRouteDecision decision,
    required TurnSkillGrant grant,
    Iterable<String> policyPreferredSkillIds = const [],
    Iterable<String> pagePreferredSkillIds = const [],
  }) {
    final routed = {
      for (final descriptor in decision.grant.descriptors)
        descriptor.normalizedId,
    };
    final policy = {
      for (final id in policyPreferredSkillIds) SkillLexicalText.normalize(id),
    };
    final page = {
      for (final id in pagePreferredSkillIds) SkillLexicalText.normalize(id),
    };
    var policyAdded = 0;
    var pageAdded = 0;
    for (final descriptor in grant.descriptors) {
      final id = descriptor.normalizedId;
      if (routed.contains(id)) continue;
      if (policy.contains(id)) {
        policyAdded++;
      } else if (page.contains(id)) {
        pageAdded++;
      }
    }
    return SkillRoutingExplanation._(
      reason: SkillRoutingReason.fromRouterReason(decision.reason),
      routerDisposition: decision.disposition,
      confidenceBand: SkillRoutingScoreBand.fromScore(decision.confidence),
      marginBand: SkillRoutingScoreBand.fromScore(decision.margin),
      policyAddedCount: policyAdded,
      pageAddedCount: pageAdded,
    );
  }

  final SkillRoutingReason reason;
  final SkillRouteDisposition? routerDisposition;
  final SkillRoutingScoreBand confidenceBand;
  final SkillRoutingScoreBand marginBand;
  final int policyAddedCount;
  final int pageAddedCount;

  Map<String, Object> toJson() => <String, Object>{
    'reason': reason.name,
    'router_disposition': routerDisposition?.name ?? 'unknown',
    'confidence_band': confidenceBand.name,
    'margin_band': marginBand.name,
    'policy_added_count': policyAddedCount,
    'page_added_count': pageAddedCount,
  };
}

/// Zero-I/O aggregate retained even when individual route retention is off.
class SkillRoutingExplanationMetrics {
  final _reasons = List<int>.filled(SkillRoutingReason.values.length, 0);
  final _dispositions = List<int>.filled(
    SkillRouteDisposition.values.length + 1,
    0,
  );
  final _confidence = List<int>.filled(SkillRoutingScoreBand.values.length, 0);
  final _margin = List<int>.filled(SkillRoutingScoreBand.values.length, 0);
  int _policyAdded = 0;
  int _pageAdded = 0;

  void record(SkillRoutingExplanation explanation) {
    final reason = explanation.reason.index;
    _reasons[reason] = _add(_reasons[reason], 1);
    final disposition =
        explanation.routerDisposition?.index ??
        SkillRouteDisposition.values.length;
    _dispositions[disposition] = _add(_dispositions[disposition], 1);
    final confidence = explanation.confidenceBand.index;
    _confidence[confidence] = _add(_confidence[confidence], 1);
    final margin = explanation.marginBand.index;
    _margin[margin] = _add(_margin[margin], 1);
    _policyAdded = _add(_policyAdded, explanation.policyAddedCount);
    _pageAdded = _add(_pageAdded, explanation.pageAddedCount);
  }

  Map<String, Object> snapshot() => Map<String, Object>.unmodifiable({
    'reasons': Map<String, int>.unmodifiable({
      for (final reason in SkillRoutingReason.values)
        reason.name: _reasons[reason.index],
    }),
    'router_dispositions': Map<String, int>.unmodifiable({
      for (final disposition in SkillRouteDisposition.values)
        disposition.name: _dispositions[disposition.index],
      'unknown': _dispositions.last,
    }),
    'confidence_bands': Map<String, int>.unmodifiable({
      for (final band in SkillRoutingScoreBand.values)
        band.name: _confidence[band.index],
    }),
    'margin_bands': Map<String, int>.unmodifiable({
      for (final band in SkillRoutingScoreBand.values)
        band.name: _margin[band.index],
    }),
    'policy_added_total': _policyAdded,
    'page_added_total': _pageAdded,
  });

  static int _add(int value, int addition) {
    const maximum = 0x1fffffffffffff;
    return addition >= maximum - value ? maximum : value + addition;
  }
}
