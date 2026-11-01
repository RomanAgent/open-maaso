import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_corpus_evaluator.dart';

void main() {
  test('100/1k/10k curve is linear to index and bounded on lookup', () {
    const evaluator = SkillRoutingCorpusEvaluator();
    final corpus = <SkillDescriptor>[
      for (var index = 0; index < 10000; index++) _descriptor(index),
    ];

    final curve = evaluator.evaluatePrefixes(
      descriptors: corpus,
      lookupTerms: const <String>['intent00042'],
    );

    expect(
      curve.evaluations.map((evaluation) => evaluation.catalogSize),
      SkillRoutingCorpusEvaluator.standardCorpusSizes,
    );
    final perDescriptorOperations =
        curve.evaluations.first.operations.indexOperationCount ~/ 100;
    expect(perDescriptorOperations, greaterThan(0));
    for (final evaluation in curve.evaluations) {
      expect(
        evaluation.operations.indexOperationCount,
        evaluation.catalogSize * perDescriptorOperations,
      );
      expect(evaluation.candidateCount, 1);
      expect(evaluation.selectedCount, 1);
      expect(evaluation.operations.lookupOperationCount, 4);
      expect(evaluation.candidateLimitReached, isFalse);
      expect(evaluation.lookupTokenLimitReached, isFalse);
    }
    expect(
      curve.evaluations.last.operations.indexOperationCount,
      curve.evaluations.first.operations.indexOperationCount * 100,
    );
  });

  test('10k shared posting retains only bounded candidates and Top-K', () {
    const evaluator = SkillRoutingCorpusEvaluator();
    final evaluation = evaluator.evaluate(
      descriptors: <SkillDescriptor>[
        for (var index = 0; index < 10000; index++)
          SkillDescriptor(
            id: 'shared${index.toString().padLeft(5, '0')}',
            summary: 'Shared synthetic tool',
            terms: const <String>['sharedintent'],
            promptCost: 64,
          ),
      ],
      lookupTerms: const <String>['sharedintent'],
    );

    expect(evaluation.catalogSize, 10000);
    expect(evaluation.candidateCount, 256);
    expect(evaluation.selectedCount, 6);
    expect(evaluation.selectedPromptCostUnits, 384);
    expect(evaluation.candidateLimitReached, isTrue);
    expect(evaluation.operations.postingVisits, 256);
    expect(evaluation.operations.selectionVisits, 6);
    expect(evaluation.operations.lookupOperationCount, 264);
  });

  test('evaluation is deterministic and exports only structural data', () {
    const evaluator = SkillRoutingCorpusEvaluator();
    final corpus = <SkillDescriptor>[
      for (var index = 0; index < 1000; index++) _descriptor(index),
    ];

    final forward = evaluator.evaluate(
      descriptors: corpus,
      lookupTerms: const <String>['intent00842'],
    );
    final reverse = evaluator.evaluate(
      descriptors: corpus.reversed,
      lookupTerms: const <String>['intent00842'],
    );

    expect(reverse.toJson(), forward.toJson());
    final encoded = jsonEncode(forward.toJson());
    expect(encoded, isNot(contains('intent00842')));
    expect(encoded, isNot(contains('scale00842')));
    expect(encoded, isNot(contains('duration')));
    expect(encoded, isNot(contains('elapsed')));
    expect(encoded, isNot(contains('millis')));
  });

  test('lookup token and prompt limits are enforced structurally', () {
    final evaluator = SkillRoutingCorpusEvaluator(
      config: SkillRoutingCorpusEvaluatorConfig(
        maxLookupTokens: 2,
        maxCandidates: 4,
        maxSelectedSkills: 2,
        promptBudget: 64,
      ),
    );
    final evaluation = evaluator.evaluate(
      descriptors: <SkillDescriptor>[
        SkillDescriptor(
          id: 'alpha',
          summary: 'Alpha',
          terms: const <String>['one', 'two', 'three'],
          promptCost: 64,
        ),
      ],
      lookupTerms: const <String>['one two three'],
    );

    expect(evaluation.lookupTokenLimitReached, isTrue);
    expect(evaluation.operations.lookupTokenVisits, 2);
    expect(evaluation.selectedCount, 1);
    expect(evaluation.selectedPromptCostUnits, 64);
  });

  test('invalid curve sizes and duplicate descriptors fail closed', () {
    const evaluator = SkillRoutingCorpusEvaluator();
    final descriptor = _descriptor(1);

    expect(
      () => evaluator.evaluate(
        descriptors: <SkillDescriptor>[descriptor, descriptor],
        lookupTerms: const <String>['intent00001'],
      ),
      throwsArgumentError,
    );
    expect(
      () => evaluator.evaluatePrefixes(
        descriptors: <SkillDescriptor>[descriptor],
        lookupTerms: const <String>['intent00001'],
        corpusSizes: const <int>[1, 1],
      ),
      throwsRangeError,
    );
  });

  test('invalid evaluator config fails in release mode too', () {
    expect(
      () => SkillRoutingCorpusEvaluatorConfig(maxLookupTokens: 0),
      throwsRangeError,
    );
    expect(
      () => SkillRoutingCorpusEvaluatorConfig(maxCandidates: 0),
      throwsRangeError,
    );
    expect(
      () => SkillRoutingCorpusEvaluatorConfig(maxSelectedSkills: 0),
      throwsRangeError,
    );
    expect(
      () => SkillRoutingCorpusEvaluatorConfig(promptBudget: 0),
      throwsRangeError,
    );
    expect(
      () => SkillRoutingCorpusEvaluatorConfig(
        maxCandidates: 2,
        maxSelectedSkills: 3,
      ),
      throwsArgumentError,
    );
  });
}

SkillDescriptor _descriptor(int index) {
  final suffix = index.toString().padLeft(5, '0');
  return SkillDescriptor(
    id: 'scale$suffix',
    summary: 'Synthetic tool',
    terms: <String>['intent$suffix'],
    promptCost: 64,
  );
}
