import 'dart:convert';

import 'natural_conversation_quality_catalog.dart';

enum NaturalConversationAcceptanceStatus { passed, failed, incomplete }

enum NaturalConversationAcceptanceSeverity { failure, incomplete }

class NaturalConversationAcceptanceFailure {
  const NaturalConversationAcceptanceFailure({
    required this.code,
    required this.severity,
    this.scenarioId,
  });

  final String code;
  final NaturalConversationAcceptanceSeverity severity;
  final String? scenarioId;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'severity': severity.name,
    if (scenarioId != null) 'scenarioId': scenarioId,
  };
}

class NaturalConversationAcceptanceResult {
  const NaturalConversationAcceptanceResult({
    required this.status,
    required this.scenariosExpected,
    required this.scenariosReviewed,
    required this.completedScenarios,
    required this.meanHumanRating,
    required this.failures,
  });

  final NaturalConversationAcceptanceStatus status;
  final int scenariosExpected;
  final int scenariosReviewed;
  final int completedScenarios;
  final double? meanHumanRating;
  final List<NaturalConversationAcceptanceFailure> failures;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'catalogVersion': naturalConversationQualityCatalogVersion,
    'sanitized': true,
    'status': status.name,
    'coverage': <String, Object?>{
      'expected': scenariosExpected,
      'reviewed': scenariosReviewed,
      'completed': completedScenarios,
    },
    'meanHumanRating': meanHumanRating,
    'thresholds': const <String, Object?>{
      'minimumScenarioRating':
          NaturalConversationAcceptancePolicy.minimumScenarioRating,
      'minimumMeanRating':
          NaturalConversationAcceptancePolicy.minimumMeanRating,
      'maximumReplyBytes':
          NaturalConversationAcceptancePolicy.maximumReplyBytes,
      'shortPauseMilliseconds': <String, int>{
        'minimum':
            NaturalConversationAcceptancePolicy.minimumShortPauseMilliseconds,
        'maximum':
            NaturalConversationAcceptancePolicy.maximumShortPauseMilliseconds,
      },
    },
    'failureCount': failures
        .where(
          (failure) =>
              failure.severity == NaturalConversationAcceptanceSeverity.failure,
        )
        .length,
    'incompleteCount': failures
        .where(
          (failure) =>
              failure.severity ==
              NaturalConversationAcceptanceSeverity.incomplete,
        )
        .length,
    'reasons': failures.map((failure) => failure.toJson()).toList(),
  };
}

/// Converts the local plaintext review artifact into a sanitized, deterministic
/// acceptance receipt. Reply text, notes, body tokens, and unknown input values
/// are never copied into the result.
class NaturalConversationAcceptancePolicy {
  const NaturalConversationAcceptancePolicy();

  static const minimumScenarioRating = 3;
  static const minimumMeanRating = 4.0;
  static const maximumReplyBytes = 4096;
  static const minimumShortPauseMilliseconds = 120;
  static const maximumShortPauseMilliseconds = 1200;

  static const _ratingFields = <String>{
    'naturalness',
    'contextUse',
    'segmentation',
    'emotionalAttunement',
    'actionFit',
    'pauseRhythm',
    'speechIdleCoordination',
    'semanticCorrectness',
  };

  static const _booleanFields = <String, String>{
    'emotionOverInferred': 'emotion_over_inferred',
    'staleContentLeaked': 'stale_content_leaked',
    'repeatedWording': 'repeated_wording',
    'unnecessaryAction': 'unnecessary_action',
    'speechIdleInterference': 'speech_idle_interference',
  };

  NaturalConversationAcceptanceResult evaluate(Map<String, Object?> artifact) {
    final failures = <NaturalConversationAcceptanceFailure>[];
    final expectedById = <String, NaturalConversationQualityScenario>{
      for (final scenario in naturalConversationQualityScenarios)
        scenario.id: scenario,
    };

    if (artifact['schemaVersion'] != 1 ||
        artifact['catalogVersion'] !=
            naturalConversationQualityCatalogVersion ||
        artifact['localOnly'] != true ||
        artifact['containsConversationText'] != true) {
      failures.add(
        const NaturalConversationAcceptanceFailure(
          code: 'invalid_review_artifact',
          severity: NaturalConversationAcceptanceSeverity.failure,
        ),
      );
      return _result(
        failures: failures,
        reviewed: 0,
        completed: 0,
        ratings: const [],
      );
    }

    final reviews = artifact['reviews'];
    if (reviews is! List) {
      failures.add(
        const NaturalConversationAcceptanceFailure(
          code: 'reviews_missing',
          severity: NaturalConversationAcceptanceSeverity.incomplete,
        ),
      );
      return _result(
        failures: failures,
        reviewed: 0,
        completed: 0,
        ratings: const [],
      );
    }

    final seen = <String>{};
    final countsByLocale = <NaturalConversationQualityLocale, List<int>>{
      for (final locale in NaturalConversationQualityLocale.values) locale: [],
    };
    final pausesByLocale = <NaturalConversationQualityLocale, int>{
      for (final locale in NaturalConversationQualityLocale.values) locale: 0,
    };
    final repliesByLocale =
        <NaturalConversationQualityLocale, Map<String, int>>{
          for (final locale in NaturalConversationQualityLocale.values)
            locale: {},
        };
    final openingsByLocale =
        <NaturalConversationQualityLocale, Map<String, int>>{
          for (final locale in NaturalConversationQualityLocale.values)
            locale: {},
        };
    final ratings = <int>[];
    var completed = 0;

    for (final rawReview in reviews) {
      if (rawReview is! Map<String, Object?>) {
        failures.add(
          const NaturalConversationAcceptanceFailure(
            code: 'invalid_review_entry',
            severity: NaturalConversationAcceptanceSeverity.failure,
          ),
        );
        continue;
      }
      final scenarioMap = rawReview['scenario'];
      final rawId = scenarioMap is Map<String, Object?>
          ? scenarioMap['id']
          : null;
      final id = rawId is String && expectedById.containsKey(rawId)
          ? rawId
          : null;
      if (id == null) {
        failures.add(
          const NaturalConversationAcceptanceFailure(
            code: 'unknown_scenario',
            severity: NaturalConversationAcceptanceSeverity.failure,
          ),
        );
        continue;
      }
      if (!seen.add(id)) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'duplicate_scenario',
            severity: NaturalConversationAcceptanceSeverity.failure,
            scenarioId: id,
          ),
        );
        continue;
      }

      final scenario = expectedById[id]!;
      final observed = rawReview['observed'];
      if (observed is! Map<String, Object?>) {
        failures.add(_missing('observation_missing', id));
        continue;
      }
      if (observed['outcome'] != 'completed') {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'scenario_not_completed',
            severity: NaturalConversationAcceptanceSeverity.failure,
            scenarioId: id,
          ),
        );
        continue;
      }
      completed++;
      final utterances = observed['utterances'];
      if (utterances is! List || utterances.isEmpty || utterances.length > 3) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'invalid_utterance_count',
            severity: NaturalConversationAcceptanceSeverity.failure,
            scenarioId: id,
          ),
        );
        continue;
      }
      countsByLocale[scenario.locale]!.add(utterances.length);
      if (observed['usesUtteranceProtocol'] != true) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'utterance_protocol_missing',
            severity: NaturalConversationAcceptanceSeverity.failure,
            scenarioId: id,
          ),
        );
      }
      final aggregateReply = observed['aggregateReply'];
      if (aggregateReply is! String || aggregateReply.trim().isEmpty) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'empty_reply',
            severity: NaturalConversationAcceptanceSeverity.failure,
            scenarioId: id,
          ),
        );
      } else {
        if (utf8.encode(aggregateReply).length > maximumReplyBytes) {
          failures.add(
            NaturalConversationAcceptanceFailure(
              code: 'reply_too_large',
              severity: NaturalConversationAcceptanceSeverity.failure,
              scenarioId: id,
            ),
          );
        }
        _increment(
          repliesByLocale[scenario.locale]!,
          _normalized(aggregateReply),
        );
      }

      final bodySignatures = <String>[];
      for (var index = 0; index < utterances.length; index++) {
        final utterance = utterances[index];
        if (utterance is! Map<String, Object?> ||
            utterance['text'] is! String ||
            (utterance['text'] as String).trim().isEmpty) {
          failures.add(
            NaturalConversationAcceptanceFailure(
              code: 'invalid_utterance',
              severity: NaturalConversationAcceptanceSeverity.failure,
              scenarioId: id,
            ),
          );
          continue;
        }
        if (index == 0) {
          _increment(
            openingsByLocale[scenario.locale]!,
            _opening(utterance['text'] as String),
          );
        }
        final pause = utterance['pause'];
        if (pause == 'brief' || pause == 'invite') {
          pausesByLocale[scenario.locale] =
              pausesByLocale[scenario.locale]! + 1;
        }
        final body = utterance['body'];
        if (body is Map<String, Object?> && body.isNotEmpty) {
          bodySignatures.add(_canonicalJson(body));
        }
      }
      if (bodySignatures.length > 2) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'body_cue_limit_exceeded',
            severity: NaturalConversationAcceptanceSeverity.failure,
            scenarioId: id,
          ),
        );
      }
      if (bodySignatures.length != bodySignatures.toSet().length) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'body_cue_repeated',
            severity: NaturalConversationAcceptanceSeverity.failure,
            scenarioId: id,
          ),
        );
      }

      final reviewRatings = rawReview['ratings'];
      if (reviewRatings is! Map<String, Object?>) {
        failures.add(_missing('human_ratings_missing', id));
        continue;
      }
      for (final field in _ratingFields) {
        final rating = reviewRatings[field];
        if (rating is! int || rating < 1 || rating > 5) {
          failures.add(_missing('human_rating_missing', id));
        } else {
          ratings.add(rating);
          if (rating < minimumScenarioRating) {
            failures.add(
              NaturalConversationAcceptanceFailure(
                code: 'human_rating_below_threshold',
                severity: NaturalConversationAcceptanceSeverity.failure,
                scenarioId: id,
              ),
            );
          }
        }
      }
      for (final entry in _booleanFields.entries) {
        final value = reviewRatings[entry.key];
        if (value is! bool) {
          failures.add(_missing('human_flag_missing', id));
        } else if (value) {
          failures.add(
            NaturalConversationAcceptanceFailure(
              code: entry.value,
              severity: NaturalConversationAcceptanceSeverity.failure,
              scenarioId: id,
            ),
          );
        }
      }
    }

    for (final scenario in naturalConversationQualityScenarios) {
      if (!seen.contains(scenario.id)) {
        failures.add(_missing('scenario_not_reviewed', scenario.id));
      }
    }
    for (final locale in NaturalConversationQualityLocale.values) {
      final counts = countsByLocale[locale]!;
      if (!counts.contains(1)) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'single_utterance_coverage_missing',
            severity: NaturalConversationAcceptanceSeverity.failure,
          ),
        );
      }
      if (!counts.any((count) => count >= 2)) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'multi_utterance_coverage_missing',
            severity: NaturalConversationAcceptanceSeverity.failure,
          ),
        );
      }
      if (pausesByLocale[locale] == 0) {
        failures.add(
          NaturalConversationAcceptanceFailure(
            code: 'semantic_pause_coverage_missing',
            severity: NaturalConversationAcceptanceSeverity.failure,
          ),
        );
      }
      if (_maximumCount(repliesByLocale[locale]!) > 1) {
        failures.add(
          const NaturalConversationAcceptanceFailure(
            code: 'exact_reply_reused',
            severity: NaturalConversationAcceptanceSeverity.failure,
          ),
        );
      }
      if (_maximumCount(openingsByLocale[locale]!) > 2) {
        failures.add(
          const NaturalConversationAcceptanceFailure(
            code: 'opening_overused',
            severity: NaturalConversationAcceptanceSeverity.failure,
          ),
        );
      }
    }

    final meanRating = ratings.isEmpty
        ? null
        : ratings.reduce((left, right) => left + right) / ratings.length;
    if (meanRating != null && meanRating < minimumMeanRating) {
      failures.add(
        const NaturalConversationAcceptanceFailure(
          code: 'mean_human_rating_below_threshold',
          severity: NaturalConversationAcceptanceSeverity.failure,
        ),
      );
    }
    _evaluateRuntimeEvidence(artifact['runtimeEvidence'], failures);

    return _result(
      failures: failures,
      reviewed: seen.length,
      completed: completed,
      ratings: ratings,
    );
  }

  void _evaluateRuntimeEvidence(
    Object? raw,
    List<NaturalConversationAcceptanceFailure> failures,
  ) {
    if (raw is! Map<String, Object?>) {
      failures.add(_missing('runtime_evidence_missing'));
      return;
    }
    if (raw['source'] != 'runtimeTrace' && raw['source'] != 'deviceProbe') {
      failures.add(_missing('runtime_evidence_source_missing'));
    }
    final observedTurns = raw['observedTurns'];
    if (observedTurns is! int || observedTurns < 2) {
      failures.add(_missing('runtime_turn_coverage_missing'));
    }
    final pauseSamples = raw['shortPauseSamplesMs'];
    if (pauseSamples is! List ||
        !pauseSamples.whereType<num>().any(
          (value) =>
              value >= minimumShortPauseMilliseconds &&
              value <= maximumShortPauseMilliseconds,
        )) {
      failures.add(_missing('short_pause_evidence_missing'));
    }
    for (final field in const [
      'speechMotionBlockedByIdleCount',
      'idleMotionOverrodeSpeechCount',
    ]) {
      final count = raw[field];
      if (count is! int || count < 0) {
        failures.add(_missing('speech_idle_evidence_missing'));
      } else if (count > 0) {
        failures.add(
          const NaturalConversationAcceptanceFailure(
            code: 'speech_idle_interference',
            severity: NaturalConversationAcceptanceSeverity.failure,
          ),
        );
      }
    }
  }

  NaturalConversationAcceptanceResult _result({
    required List<NaturalConversationAcceptanceFailure> failures,
    required int reviewed,
    required int completed,
    required List<int> ratings,
  }) {
    final deduplicated = <NaturalConversationAcceptanceFailure>[];
    final keys = <String>{};
    for (final failure in failures) {
      final key =
          '${failure.severity.name}|${failure.code}|${failure.scenarioId ?? ''}';
      if (keys.add(key)) deduplicated.add(failure);
    }
    final hasFailure = deduplicated.any(
      (failure) =>
          failure.severity == NaturalConversationAcceptanceSeverity.failure,
    );
    final hasIncomplete = deduplicated.any(
      (failure) =>
          failure.severity == NaturalConversationAcceptanceSeverity.incomplete,
    );
    final status = hasFailure
        ? NaturalConversationAcceptanceStatus.failed
        : hasIncomplete
        ? NaturalConversationAcceptanceStatus.incomplete
        : NaturalConversationAcceptanceStatus.passed;
    return NaturalConversationAcceptanceResult(
      status: status,
      scenariosExpected: naturalConversationQualityScenarios.length,
      scenariosReviewed: reviewed,
      completedScenarios: completed,
      meanHumanRating: ratings.isEmpty
          ? null
          : ratings.reduce((left, right) => left + right) / ratings.length,
      failures: List.unmodifiable(deduplicated),
    );
  }

  static NaturalConversationAcceptanceFailure _missing(
    String code, [
    String? scenarioId,
  ]) => NaturalConversationAcceptanceFailure(
    code: code,
    severity: NaturalConversationAcceptanceSeverity.incomplete,
    scenarioId: scenarioId,
  );
}

void _increment(Map<String, int> counts, String value) {
  if (value.isEmpty) return;
  counts[value] = (counts[value] ?? 0) + 1;
}

int _maximumCount(Map<String, int> counts) => counts.isEmpty
    ? 0
    : counts.values.reduce((left, right) => left > right ? left : right);

String _opening(String value) =>
    String.fromCharCodes(_normalized(value).runes.take(16));

String _normalized(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s，。！？、；：,.!?;:"“”‘’()（）\-—]+', unicode: true), ' ')
    .trim();

String _canonicalJson(Map<String, Object?> value) {
  Object? normalize(Object? input) {
    if (input is Map) {
      final keys = input.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: normalize(input[key]),
      };
    }
    if (input is List) return input.map(normalize).toList(growable: false);
    return input;
  }

  return jsonEncode(normalize(value));
}
