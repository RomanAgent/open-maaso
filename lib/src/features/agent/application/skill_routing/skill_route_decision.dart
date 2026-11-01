import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';

enum SkillRouteDisposition { noTool, clarify, selected }

/// Immutable catalog context captured alongside a per-turn Skill grant.
///
/// Routing stays independent of prompt-only catalog implementations while
/// allowing prompt construction to use the exact snapshot that was routed.
abstract interface class TurnSkillSnapshotToken {}

class SkillRouteMatch {
  const SkillRouteMatch({
    required this.descriptor,
    required this.score,
    required this.confidence,
    required this.matchedTerms,
    required this.matchedExamples,
    required this.pagePriorApplied,
    required this.professionPriorApplied,
    required this.semanticScore,
  });

  final SkillDescriptor descriptor;
  final double score;
  final double confidence;
  final List<String> matchedTerms;
  final List<String> matchedExamples;
  final bool pagePriorApplied;
  final bool professionPriorApplied;
  final double semanticScore;
}

/// Per-turn execution allowlist. Future prompt/executor adapters should expose
/// only [allowedSkillIds], never the router's complete catalog.
class TurnSkillGrant {
  const TurnSkillGrant._({
    required this.descriptors,
    required this.allowedSkillIds,
    required this.promptCost,
    required this.promptBudget,
    required this.maxSkills,
    required this.snapshotToken,
  });

  static const none = TurnSkillGrant._(
    descriptors: <SkillDescriptor>[],
    allowedSkillIds: <String>{},
    promptCost: 0,
    promptBudget: 0,
    maxSkills: 0,
    snapshotToken: null,
  );

  factory TurnSkillGrant.bounded({
    required Iterable<SkillDescriptor> rankedDescriptors,
    required int maxSkills,
    required int promptBudget,
    TurnSkillSnapshotToken? snapshotToken,
  }) {
    if (maxSkills <= 0) {
      throw ArgumentError.value(maxSkills, 'maxSkills', 'must be positive');
    }
    if (promptBudget <= 0) {
      throw ArgumentError.value(
        promptBudget,
        'promptBudget',
        'must be positive',
      );
    }
    final selected = <SkillDescriptor>[];
    final ids = <String>{};
    var cost = 0;
    for (final descriptor in rankedDescriptors) {
      if (selected.length >= maxSkills) break;
      if (cost + descriptor.promptCost > promptBudget) break;
      if (!ids.add(descriptor.id)) continue;
      selected.add(descriptor);
      cost += descriptor.promptCost;
    }
    return TurnSkillGrant._(
      descriptors: List.unmodifiable(selected),
      allowedSkillIds: Set.unmodifiable(ids),
      promptCost: cost,
      promptBudget: promptBudget,
      maxSkills: maxSkills,
      snapshotToken: snapshotToken,
    );
  }

  final List<SkillDescriptor> descriptors;
  final Set<String> allowedSkillIds;
  final int promptCost;
  final int promptBudget;
  final int maxSkills;
  final TurnSkillSnapshotToken? snapshotToken;

  bool get isEmpty => allowedSkillIds.isEmpty;

  bool allows(String skillId) => allowedSkillIds.contains(skillId);

  void requireAllowed(String skillId) {
    if (!allows(skillId)) {
      throw StateError('skill_not_granted:$skillId');
    }
  }
}

class SkillRouteDecision {
  const SkillRouteDecision._({
    required this.disposition,
    required this.matches,
    required this.confidence,
    required this.margin,
    required this.grant,
    required this.reason,
  });

  factory SkillRouteDecision.noTool({
    String reason = 'no_lexical_match',
    List<SkillRouteMatch> matches = const <SkillRouteMatch>[],
  }) => SkillRouteDecision._(
    disposition: SkillRouteDisposition.noTool,
    matches: List.unmodifiable(matches),
    confidence: matches.isEmpty ? 0 : matches.first.confidence,
    margin: 0,
    grant: TurnSkillGrant.none,
    reason: reason,
  );

  factory SkillRouteDecision.clarify({
    required List<SkillRouteMatch> matches,
    required double confidence,
    required double margin,
    String reason = 'ambiguous',
  }) => SkillRouteDecision._(
    disposition: SkillRouteDisposition.clarify,
    matches: List.unmodifiable(matches),
    confidence: confidence,
    margin: margin,
    grant: TurnSkillGrant.none,
    reason: reason,
  );

  factory SkillRouteDecision.selected({
    required List<SkillRouteMatch> matches,
    required double confidence,
    required double margin,
    required TurnSkillGrant grant,
    String reason = 'selected',
  }) {
    if (grant.isEmpty) {
      throw ArgumentError('A selected route requires a non-empty grant');
    }
    return SkillRouteDecision._(
      disposition: SkillRouteDisposition.selected,
      matches: List.unmodifiable(matches),
      confidence: confidence,
      margin: margin,
      grant: grant,
      reason: reason,
    );
  }

  final SkillRouteDisposition disposition;
  final List<SkillRouteMatch> matches;
  final double confidence;
  final double margin;
  final TurnSkillGrant grant;
  final String reason;

  SkillRouteMatch? get topMatch => matches.isEmpty ? null : matches.first;
}
