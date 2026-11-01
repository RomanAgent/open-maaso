import 'dart:collection';

import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';

class SkillRoutingCorpusEvaluatorConfig {
  factory SkillRoutingCorpusEvaluatorConfig({
    int maxLookupTokens = 32,
    int maxCandidates = 256,
    int maxSelectedSkills = 6,
    int promptBudget = 8192,
  }) {
    _requirePositive(maxLookupTokens, 'maxLookupTokens');
    _requirePositive(maxCandidates, 'maxCandidates');
    _requirePositive(maxSelectedSkills, 'maxSelectedSkills');
    _requirePositive(promptBudget, 'promptBudget');
    if (maxCandidates < maxSelectedSkills) {
      throw ArgumentError.value(
        maxCandidates,
        'maxCandidates',
        'must be greater than or equal to maxSelectedSkills',
      );
    }
    return SkillRoutingCorpusEvaluatorConfig._(
      maxLookupTokens: maxLookupTokens,
      maxCandidates: maxCandidates,
      maxSelectedSkills: maxSelectedSkills,
      promptBudget: promptBudget,
    );
  }

  const SkillRoutingCorpusEvaluatorConfig._({
    required this.maxLookupTokens,
    required this.maxCandidates,
    required this.maxSelectedSkills,
    required this.promptBudget,
  });

  static const defaults = SkillRoutingCorpusEvaluatorConfig._(
    maxLookupTokens: 32,
    maxCandidates: 256,
    maxSelectedSkills: 6,
    promptBudget: 8192,
  );

  final int maxLookupTokens;
  final int maxCandidates;
  final int maxSelectedSkills;
  final int promptBudget;

  static void _requirePositive(int value, String name) {
    if (value <= 0) {
      throw RangeError.value(value, name, 'must be greater than zero');
    }
  }
}

/// Explicit metadata-operation counters for a routing corpus probe.
///
/// These counters intentionally exclude wall-clock time and SDK sort internals;
/// they make descriptor indexing, posting traversal, and bounded selection
/// comparable across devices and CI hosts.
class SkillRoutingCorpusOperationCounts {
  const SkillRoutingCorpusOperationCounts({
    required this.descriptorVisits,
    required this.duplicateIdChecks,
    required this.lexemeVisits,
    required this.postingWrites,
    required this.lookupTermVisits,
    required this.lookupTokenVisits,
    required this.postingVisits,
    required this.selectionVisits,
  });

  final int descriptorVisits;
  final int duplicateIdChecks;
  final int lexemeVisits;
  final int postingWrites;
  final int lookupTermVisits;
  final int lookupTokenVisits;
  final int postingVisits;
  final int selectionVisits;

  int get indexOperationCount =>
      descriptorVisits + duplicateIdChecks + lexemeVisits + postingWrites;

  int get lookupOperationCount =>
      lookupTermVisits + lookupTokenVisits + postingVisits + selectionVisits;

  int get totalOperationCount => indexOperationCount + lookupOperationCount;

  Map<String, int> toJson() => <String, int>{
    'descriptor_visits': descriptorVisits,
    'duplicate_id_checks': duplicateIdChecks,
    'lexeme_visits': lexemeVisits,
    'posting_writes': postingWrites,
    'lookup_term_visits': lookupTermVisits,
    'lookup_token_visits': lookupTokenVisits,
    'posting_visits': postingVisits,
    'selection_visits': selectionVisits,
    'index_operation_count': indexOperationCount,
    'lookup_operation_count': lookupOperationCount,
    'total_operation_count': totalOperationCount,
  };
}

class SkillRoutingCorpusEvaluation {
  const SkillRoutingCorpusEvaluation({
    required this.catalogSize,
    required this.uniqueLexemeCount,
    required this.candidateCount,
    required this.selectedCount,
    required this.selectedPromptCostUnits,
    required this.candidateLimitReached,
    required this.lookupTokenLimitReached,
    required this.operations,
  });

  final int catalogSize;
  final int uniqueLexemeCount;
  final int candidateCount;
  final int selectedCount;
  final int selectedPromptCostUnits;
  final bool candidateLimitReached;
  final bool lookupTokenLimitReached;
  final SkillRoutingCorpusOperationCounts operations;

  Map<String, Object> toJson() => <String, Object>{
    'catalog_size': catalogSize,
    'unique_lexeme_count': uniqueLexemeCount,
    'candidate_count': candidateCount,
    'selected_count': selectedCount,
    'selected_prompt_cost_units': selectedPromptCostUnits,
    'candidate_limit_reached': candidateLimitReached,
    'lookup_token_limit_reached': lookupTokenLimitReached,
    'operations': operations.toJson(),
  };
}

class SkillRoutingCorpusCurve {
  SkillRoutingCorpusCurve(Iterable<SkillRoutingCorpusEvaluation> evaluations)
    : evaluations = List.unmodifiable(evaluations);

  final List<SkillRoutingCorpusEvaluation> evaluations;

  Map<String, Object> toJson() => <String, Object>{
    'schema_version': 1,
    'evaluations': <Map<String, Object>>[
      for (final evaluation in evaluations) evaluation.toJson(),
    ],
  };
}

/// Deterministic structural evaluator for descriptor-catalog scaling.
///
/// It mirrors the inverted-index candidate traversal and bounded prompt-cost
/// selection, but deliberately does not score confidence or measure time. It
/// is intended for benchmark tests and release gates, not as the live router.
/// No lookup text or descriptor identifier is retained in its results.
class SkillRoutingCorpusEvaluator {
  const SkillRoutingCorpusEvaluator({
    this.config = SkillRoutingCorpusEvaluatorConfig.defaults,
  });

  static const List<int> standardCorpusSizes = <int>[100, 1000, 10000];

  final SkillRoutingCorpusEvaluatorConfig config;

  SkillRoutingCorpusEvaluation evaluate({
    required Iterable<SkillDescriptor> descriptors,
    required Iterable<String> lookupTerms,
  }) {
    final ordered = descriptors.toList()
      ..sort((a, b) {
        final normalized = a.normalizedId.compareTo(b.normalizedId);
        return normalized != 0 ? normalized : a.id.compareTo(b.id);
      });

    var descriptorVisits = 0;
    var duplicateIdChecks = 0;
    var lexemeVisits = 0;
    var postingWrites = 0;
    final ids = <String>{};
    final postings = <String, List<int>>{};
    for (
      var descriptorIndex = 0;
      descriptorIndex < ordered.length;
      descriptorIndex++
    ) {
      final descriptor = ordered[descriptorIndex];
      descriptorVisits++;
      duplicateIdChecks++;
      if (!ids.add(descriptor.normalizedId)) {
        throw ArgumentError('Duplicate skill descriptor id: ${descriptor.id}');
      }
      for (final lexeme in descriptor.indexLexemes) {
        lexemeVisits++;
        postingWrites++;
        (postings[lexeme] ??= <int>[]).add(descriptorIndex);
      }
    }

    var lookupTermVisits = 0;
    var lookupTokenLimitReached = false;
    final lookupTokens = SplayTreeSet<String>();
    for (final term in lookupTerms) {
      lookupTermVisits++;
      for (final token in SkillLexicalText.tokens(term)) {
        if (lookupTokens.length >= config.maxLookupTokens &&
            !lookupTokens.contains(token)) {
          lookupTokenLimitReached = true;
          break;
        }
        lookupTokens.add(token);
      }
      if (lookupTokenLimitReached) break;
    }

    final matchingPostings =
        <MapEntry<String, List<int>>>[
          for (final token in lookupTokens)
            if (postings[token] case final matches?) MapEntry(token, matches),
        ]..sort((a, b) {
          final rarity = a.value.length.compareTo(b.value.length);
          return rarity != 0 ? rarity : a.key.compareTo(b.key);
        });

    var postingVisits = 0;
    var candidateLimitReached = false;
    final candidateIndexes = <int>{};
    for (final entry in matchingPostings) {
      for (final descriptorIndex in entry.value) {
        if (candidateIndexes.length >= config.maxCandidates) {
          candidateLimitReached = true;
          break;
        }
        postingVisits++;
        candidateIndexes.add(descriptorIndex);
      }
      if (candidateLimitReached) break;
    }

    var selectionVisits = 0;
    var selectedCount = 0;
    var selectedPromptCostUnits = 0;
    for (final descriptorIndex in candidateIndexes) {
      if (selectedCount >= config.maxSelectedSkills) break;
      selectionVisits++;
      final descriptor = ordered[descriptorIndex];
      if (selectedPromptCostUnits + descriptor.promptCost >
          config.promptBudget) {
        break;
      }
      selectedCount++;
      selectedPromptCostUnits += descriptor.promptCost;
    }

    return SkillRoutingCorpusEvaluation(
      catalogSize: ordered.length,
      uniqueLexemeCount: postings.length,
      candidateCount: candidateIndexes.length,
      selectedCount: selectedCount,
      selectedPromptCostUnits: selectedPromptCostUnits,
      candidateLimitReached: candidateLimitReached,
      lookupTokenLimitReached: lookupTokenLimitReached,
      operations: SkillRoutingCorpusOperationCounts(
        descriptorVisits: descriptorVisits,
        duplicateIdChecks: duplicateIdChecks,
        lexemeVisits: lexemeVisits,
        postingWrites: postingWrites,
        lookupTermVisits: lookupTermVisits,
        lookupTokenVisits: lookupTokens.length,
        postingVisits: postingVisits,
        selectionVisits: selectionVisits,
      ),
    );
  }

  SkillRoutingCorpusCurve evaluatePrefixes({
    required Iterable<SkillDescriptor> descriptors,
    required Iterable<String> lookupTerms,
    Iterable<int> corpusSizes = standardCorpusSizes,
  }) {
    final corpus = descriptors.toList(growable: false);
    final terms = lookupTerms.toList(growable: false);
    final sizes = corpusSizes.toList(growable: false);
    var previousSize = 0;
    for (final size in sizes) {
      if (size <= previousSize || size > corpus.length) {
        throw RangeError(
          'corpusSizes must be strictly increasing and at most '
          '${corpus.length}: $sizes',
        );
      }
      previousSize = size;
    }
    return SkillRoutingCorpusCurve(<SkillRoutingCorpusEvaluation>[
      for (final size in sizes)
        evaluate(descriptors: corpus.take(size), lookupTerms: terms),
    ]);
  }
}
