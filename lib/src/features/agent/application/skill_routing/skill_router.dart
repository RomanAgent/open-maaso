import 'dart:math' as math;

import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_intent_guard.dart';

/// Optional synchronous reranker for an already bounded lexical candidate set.
/// Implementations must be deterministic and local/in-memory; network access is
/// intentionally absent from this hot-path contract.
abstract interface class SkillSemanticScorer {
  double score({required String query, required SkillDescriptor descriptor});
}

class SkillRouterConfig {
  const SkillRouterConfig({
    this.defaultTopK = 4,
    this.maxTopK = 6,
    this.maxCandidates = 256,
    this.promptBudget = 8192,
    this.minimumCandidateConfidence = 0.28,
    this.selectionConfidence = 0.52,
    this.minimumMargin = 0.12,
    this.pageScopeBoost = 8,
    this.professionBoost = 2,
    this.semanticWeight = 4,
  }) : assert(defaultTopK > 0),
       assert(maxTopK >= defaultTopK),
       assert(maxCandidates >= maxTopK),
       assert(promptBudget > 0),
       assert(minimumCandidateConfidence >= 0),
       assert(selectionConfidence >= minimumCandidateConfidence),
       assert(selectionConfidence <= 1),
       assert(minimumMargin >= 0),
       assert(minimumMargin <= 1);

  final int defaultTopK;
  final int maxTopK;
  final int maxCandidates;
  final int promptBudget;
  final double minimumCandidateConfidence;
  final double selectionConfidence;
  final double minimumMargin;
  final double pageScopeBoost;
  final double professionBoost;
  final double semanticWeight;
}

class SkillRouter {
  const SkillRouter({
    required SkillIndex index,
    this.config = const SkillRouterConfig(),
    SkillSemanticScorer? semanticScorer,
  }) : _index = index,
       _semanticScorer = semanticScorer;

  final SkillIndex _index;
  final SkillRouterConfig config;
  final SkillSemanticScorer? _semanticScorer;

  SkillRouteDecision route(
    String query, {
    String? pageScope,
    Iterable<String> professions = const <String>[],
    int? maxResults,
    SkillRoutingIntentGuard? intentGuard,
  }) {
    final intent = intentGuard ?? SkillRoutingIntentGuard.analyze(query);
    if (intent.blockAll) {
      return SkillRouteDecision.noTool(reason: 'non_action_context');
    }
    final lookup = _index.lookup(
      intent.routingText,
      maxCandidates: config.maxCandidates,
    );
    if (lookup.normalizedQuery.isEmpty || lookup.candidates.isEmpty) {
      return SkillRouteDecision.noTool();
    }

    final normalizedPage = SkillLexicalText.normalize(pageScope ?? '');
    final normalizedProfessions = {
      for (final profession in professions)
        if (SkillLexicalText.normalize(profession).isNotEmpty)
          SkillLexicalText.normalize(profession),
    };
    final scored = <SkillRouteMatch>[];
    for (final descriptor in lookup.candidates) {
      if (!intent.allows(descriptor)) continue;
      final match = _score(
        descriptor,
        lookup,
        normalizedPage: normalizedPage,
        normalizedProfessions: normalizedProfessions,
      );
      if (match != null) scored.add(match);
    }
    scored.sort((a, b) {
      final score = b.score.compareTo(a.score);
      return score != 0 ? score : a.descriptor.id.compareTo(b.descriptor.id);
    });

    final requested = maxResults ?? config.defaultTopK;
    final topK = requested.clamp(1, config.maxTopK);
    final matches = scored
        .where((match) => match.confidence >= config.minimumCandidateConfidence)
        .take(topK)
        .toList(growable: false);
    if (matches.isEmpty) {
      return SkillRouteDecision.noTool(reason: 'insufficient_evidence');
    }

    final top = matches.first;
    final margin = matches.length == 1
        ? top.confidence
        : top.confidence - matches[1].confidence;
    if (top.confidence < config.selectionConfidence) {
      return SkillRouteDecision.clarify(
        matches: matches,
        confidence: top.confidence,
        margin: margin,
        reason: 'low_confidence',
      );
    }
    if (matches.length > 1 && margin < config.minimumMargin) {
      return SkillRouteDecision.clarify(
        matches: matches,
        confidence: top.confidence,
        margin: margin,
      );
    }

    final grant = TurnSkillGrant.bounded(
      rankedDescriptors: matches
          .where((match) => match.confidence >= config.selectionConfidence)
          .map((match) => match.descriptor),
      maxSkills: topK,
      promptBudget: config.promptBudget,
    );
    if (grant.isEmpty) {
      return SkillRouteDecision.clarify(
        matches: matches,
        confidence: top.confidence,
        margin: margin,
        reason: 'prompt_budget_exhausted',
      );
    }
    return SkillRouteDecision.selected(
      matches: matches,
      confidence: top.confidence,
      margin: margin,
      grant: grant,
    );
  }

  SkillRouteMatch? _score(
    SkillDescriptor descriptor,
    SkillIndexLookup lookup, {
    required String normalizedPage,
    required Set<String> normalizedProfessions,
  }) {
    if (_containsAny(lookup.normalizedQuery, descriptor.negativeTerms) ||
        _containsAny(lookup.normalizedQuery, descriptor.negativeExamples)) {
      return null;
    }

    final matchedTerms = [
      for (final term in descriptor.terms)
        if (SkillLexicalText.containsPhrase(lookup.normalizedQuery, term)) term,
    ];
    final matchedExamples = [
      for (final example in descriptor.positiveExamples)
        if (SkillLexicalText.containsPhrase(lookup.normalizedQuery, example))
          example,
    ];

    var lexicalScore = 0.0;
    if (SkillLexicalText.containsPhrase(
      lookup.normalizedQuery,
      descriptor.normalizedId,
    )) {
      lexicalScore += 14;
    }
    for (final term in matchedTerms) {
      lexicalScore += 10 + math.min(4, term.runes.length / 4);
    }
    lexicalScore += matchedExamples.length * 14;

    final termOverlap = lookup.queryTokens
        .intersection(descriptor.termTokens)
        .length;
    lexicalScore += math.min(6, termOverlap * 2);
    lexicalScore += math.min(
      4,
      lookup.queryTokens
          .intersection(descriptor.summaryTokens)
          .length
          .toDouble(),
    );
    if (lexicalScore <= 0) return null;

    final pagePriorApplied =
        normalizedPage.isNotEmpty &&
        (matchedTerms.isNotEmpty ||
            matchedExamples.isNotEmpty ||
            termOverlap >= 2) &&
        descriptor.pageScopes.contains(normalizedPage);
    final professionPriorApplied = descriptor.professions.any(
      normalizedProfessions.contains,
    );
    var score = lexicalScore;
    if (pagePriorApplied) score += config.pageScopeBoost;
    if (professionPriorApplied) score += config.professionBoost;

    var semanticScore = 0.0;
    final scorer = _semanticScorer;
    if (scorer != null) {
      semanticScore = scorer
          .score(query: lookup.normalizedQuery, descriptor: descriptor)
          .clamp(0.0, 1.0);
      score += semanticScore * config.semanticWeight;
    }

    final confidence = 1 - math.exp(-score / 12);
    return SkillRouteMatch(
      descriptor: descriptor,
      score: score,
      confidence: confidence.clamp(0.0, 1.0),
      matchedTerms: List.unmodifiable(matchedTerms),
      matchedExamples: List.unmodifiable(matchedExamples),
      pagePriorApplied: pagePriorApplied,
      professionPriorApplied: professionPriorApplied,
      semanticScore: semanticScore,
    );
  }

  bool _containsAny(String normalizedQuery, Iterable<String> phrases) {
    for (final phrase in phrases) {
      if (SkillLexicalText.containsPhrase(normalizedQuery, phrase)) return true;
    }
    return false;
  }
}
