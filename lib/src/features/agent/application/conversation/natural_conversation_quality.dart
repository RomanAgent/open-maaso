import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'natural_conversation_quality_catalog.dart';

enum NaturalConversationQualityOutcome {
  completed,
  timedOut,
  invalidResponse,
  providerUnavailable,
  failed,
  notRun,
}

enum NaturalConversationTimingSource { runtimeTrace, deviceProbe, injected }

class NaturalConversationDeliveryTiming {
  const NaturalConversationDeliveryTiming({
    required this.source,
    this.firstVisibleMilliseconds,
    this.firstAudioMilliseconds,
  });

  final NaturalConversationTimingSource source;
  final int? firstVisibleMilliseconds;
  final int? firstAudioMilliseconds;
}

class NaturalConversationQualityUtterance {
  NaturalConversationQualityUtterance({
    required this.text,
    required this.after,
    this.pause,
    Map<String, Object?>? body,
  }) : body = body == null ? null : Map<String, Object?>.unmodifiable(body);

  final String text;
  final String after;
  final String? pause;
  final Map<String, Object?>? body;
}

class NaturalConversationQualityObservation {
  NaturalConversationQualityObservation.completed({
    required this.aggregateReply,
    required List<NaturalConversationQualityUtterance> utterances,
    required this.usesUtteranceProtocol,
    this.timing,
  }) : outcome = NaturalConversationQualityOutcome.completed,
       utterances = List<NaturalConversationQualityUtterance>.unmodifiable(
         utterances,
       ) {
    if (aggregateReply.trim().isEmpty ||
        utterances.isEmpty ||
        utterances.length > 3 ||
        utterances.any((utterance) => utterance.text.trim().isEmpty)) {
      throw ArgumentError(
        'A completed quality observation must be a 1-3 part reply.',
      );
    }
  }

  const NaturalConversationQualityObservation.failure(this.outcome)
    : assert(outcome != NaturalConversationQualityOutcome.completed),
      aggregateReply = '',
      utterances = const <NaturalConversationQualityUtterance>[],
      usesUtteranceProtocol = false,
      timing = null;

  final NaturalConversationQualityOutcome outcome;
  final String aggregateReply;
  final List<NaturalConversationQualityUtterance> utterances;
  final bool usesUtteranceProtocol;
  final NaturalConversationDeliveryTiming? timing;
}

/// Executes one isolated scenario. Implementations own their transport and
/// must make [cancelAndDrain] stop the active call without exposing raw errors.
abstract interface class NaturalConversationQualityScenarioRunner {
  Future<NaturalConversationQualityObservation> run(
    NaturalConversationQualityScenario scenario, {
    required Duration timeout,
  });

  Future<void> cancelAndDrain();
}

class NaturalConversationQualitySuite {
  const NaturalConversationQualitySuite({
    this.scenarioTimeout = const Duration(seconds: 30),
    this.cleanupTimeout = const Duration(seconds: 3),
  });

  final Duration scenarioTimeout;
  final Duration cleanupTimeout;

  Future<NaturalConversationQualityEvaluation> run(
    NaturalConversationQualityScenarioRunner runner, {
    List<NaturalConversationQualityScenario> scenarios =
        naturalConversationQualityScenarios,
  }) async {
    _validateDuration(
      scenarioTimeout,
      'scenarioTimeout',
      const Duration(seconds: 120),
    );
    _validateDuration(
      cleanupTimeout,
      'cleanupTimeout',
      const Duration(seconds: 10),
    );
    if (scenarios.isEmpty || scenarios.length > 48) {
      throw ArgumentError.value(
        scenarios.length,
        'scenarios',
        'must contain between 1 and 48 scenarios',
      );
    }
    final ids = <String>{};
    for (final scenario in scenarios) {
      if (!ids.add(scenario.id)) {
        throw ArgumentError.value(scenario.id, 'scenarios', 'duplicate id');
      }
    }

    final samples = <NaturalConversationQualitySample>[];
    var runnerCanContinue = true;
    for (final scenario in scenarios) {
      if (!runnerCanContinue) {
        samples.add(
          NaturalConversationQualitySample(
            scenario: scenario,
            observation: const NaturalConversationQualityObservation.failure(
              NaturalConversationQualityOutcome.notRun,
            ),
          ),
        );
        continue;
      }
      NaturalConversationQualityObservation observation;
      try {
        observation = await runner
            .run(scenario, timeout: scenarioTimeout)
            .timeout(scenarioTimeout + cleanupTimeout);
      } on TimeoutException {
        observation = const NaturalConversationQualityObservation.failure(
          NaturalConversationQualityOutcome.timedOut,
        );
        runnerCanContinue = await _cancelAndDrain(runner);
      } catch (_) {
        observation = const NaturalConversationQualityObservation.failure(
          NaturalConversationQualityOutcome.failed,
        );
        runnerCanContinue = await _cancelAndDrain(runner);
      }
      samples.add(
        NaturalConversationQualitySample(
          scenario: scenario,
          observation: observation,
        ),
      );
    }
    return NaturalConversationQualityEvaluation._(
      requestedScenarios: List<NaturalConversationQualityScenario>.unmodifiable(
        scenarios,
      ),
      samples: List<NaturalConversationQualitySample>.unmodifiable(samples),
    );
  }

  Future<bool> _cancelAndDrain(
    NaturalConversationQualityScenarioRunner runner,
  ) async {
    try {
      await runner.cancelAndDrain().timeout(cleanupTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void _validateDuration(Duration value, String name, Duration maximum) {
    if (value <= Duration.zero || value > maximum) {
      throw ArgumentError.value(value, name, 'outside the supported bound');
    }
  }
}

class NaturalConversationQualitySample {
  const NaturalConversationQualitySample({
    required this.scenario,
    required this.observation,
  });

  final NaturalConversationQualityScenario scenario;
  final NaturalConversationQualityObservation observation;
}

class NaturalConversationQualityEvaluation {
  const NaturalConversationQualityEvaluation._({
    required this.requestedScenarios,
    required this.samples,
  });

  final List<NaturalConversationQualityScenario> requestedScenarios;
  final List<NaturalConversationQualitySample> samples;

  /// Contains fixed identifiers, counts, bounded timings and lengths only.
  /// Conversation text, body tokens and arbitrary provider errors are omitted.
  Map<String, Object?> toSanitizedJson() {
    final all = _QualitySummary(samples);
    final requestedIds = requestedScenarios.map((item) => item.id).toSet();
    final catalogIds = naturalConversationQualityScenarios
        .map((item) => item.id)
        .toSet();
    return <String, Object?>{
      'schemaVersion': 1,
      'catalogVersion': naturalConversationQualityCatalogVersion,
      'sanitized': true,
      'coverage': <String, Object?>{
        'requested': requestedScenarios.length,
        'observed': samples.length,
        'completed': all.completed.length,
        'fullCatalogExpected': naturalConversationQualityScenarios.length,
        'isFullCatalogRun':
            requestedIds.length == catalogIds.length &&
            requestedIds.containsAll(catalogIds),
      },
      'overall': all.toJson(),
      'locales': <String, Object?>{
        for (final locale in NaturalConversationQualityLocale.values)
          _localeName(locale): _QualitySummary(
            samples
                .where((sample) => sample.scenario.locale == locale)
                .toList(growable: false),
          ).toJson(),
      },
      'scenarios': samples.map(_sanitizedSample).toList(growable: false),
    };
  }

  /// Local-only, plaintext artifact for human judgment. Callers must keep it
  /// out of telemetry and version control.
  Map<String, Object?> toHumanReviewJson() => <String, Object?>{
    'schemaVersion': 1,
    'catalogVersion': naturalConversationQualityCatalogVersion,
    'localOnly': true,
    'containsConversationText': true,
    'rubric': <String, Object?>{
      'scores': 'Use integers 1 (poor) through 5 (excellent).',
      'naturalness': 'Would this sound like a natural conversational response?',
      'contextUse':
          'Does it use the recent dialogue without leaking old intent?',
      'segmentation': 'Are separate utterances useful rather than mechanical?',
      'emotionalAttunement':
          'Is emotion handled tentatively and proportionally?',
      'actionFit': 'Do body cues fit, remain subtle, and avoid repetition?',
      'pauseRhythm': 'Do pauses and hesitations sound short and intentional?',
      'speechIdleCoordination':
          'Do speaking motion and idle motion remain visually independent?',
      'semanticCorrectness':
          'Judge meaning freely; there is no fixed expected reply.',
    },
    'runtimeEvidence': <String, Object?>{
      'source': null,
      'observedTurns': null,
      'shortPauseSamplesMs': <int>[],
      'speechMotionBlockedByIdleCount': null,
      'idleMotionOverrodeSpeechCount': null,
    },
    'reviews': samples.map(_humanReviewSample).toList(growable: false),
  };

  String toHumanReviewMarkdown() {
    final output = StringBuffer()
      ..writeln('# Natural conversation human review')
      ..writeln()
      ..writeln('Local-only artifact. It contains model and scenario text.')
      ..writeln(
        'Score naturalness, context use, segmentation, emotional attunement, '
        'action fit, and semantic correctness from 1–5.',
      )
      ..writeln(
        'Use the JSON artifact for final acceptance; it also requires bounded '
        'pause samples and speech/idle runtime evidence.',
      )
      ..writeln();
    for (final sample in samples) {
      final scenario = sample.scenario;
      final observation = sample.observation;
      output
        ..writeln('## ${scenario.id}')
        ..writeln()
        ..writeln('- Locale: `${_localeName(scenario.locale)}`')
        ..writeln('- Category: `${_categoryName(scenario.category)}`')
        ..writeln(
          '- Focus: `${scenario.focuses.map((focus) => focus.name).join(', ')}`',
        )
        ..writeln(
          '- Emotion evidence: `${_emotionEvidenceName(scenario.emotionEvidence)}`',
        )
        ..writeln('- Outcome: `${_outcomeName(observation.outcome)}`')
        ..writeln()
        ..writeln('### Conversation')
        ..writeln();
      for (final turn in scenario.history) {
        output.writeln(
          '- ${turn.role == NaturalConversationHistoryRole.user ? 'User' : 'Agent'}: '
          '${_markdownText(turn.text)}',
        );
      }
      output
        ..writeln('- User: ${_markdownText(scenario.userText)}')
        ..writeln()
        ..writeln('### Observed reply')
        ..writeln();
      if (observation.outcome != NaturalConversationQualityOutcome.completed) {
        output.writeln('_No completed reply._');
      } else {
        for (var index = 0; index < observation.utterances.length; index++) {
          final utterance = observation.utterances[index];
          output.writeln(
            '${index + 1}. ${_markdownText(utterance.text)}'
            '${utterance.body == null ? '' : ' `${jsonEncode(utterance.body)}`'}',
          );
        }
      }
      output
        ..writeln()
        ..writeln('### Scores')
        ..writeln()
        ..writeln('- Naturalness (1–5): ')
        ..writeln('- Context use (1–5): ')
        ..writeln('- Segmentation (1–5): ')
        ..writeln('- Emotional attunement (1–5): ')
        ..writeln('- Action fit (1–5): ')
        ..writeln('- Pause rhythm (1–5): ')
        ..writeln('- Speech/idle coordination (1–5): ')
        ..writeln('- Semantic correctness (1–5): ')
        ..writeln('- Emotion over-inferred (yes/no/unclear): ')
        ..writeln('- Stale content leaked (yes/no/unclear): ')
        ..writeln('- Repeated wording (yes/no/unclear): ')
        ..writeln('- Unnecessary action (yes/no/unclear): ')
        ..writeln('- Speech/idle interference (yes/no/unclear): ')
        ..writeln('- Notes: ')
        ..writeln();
    }
    return output.toString();
  }

  Map<String, Object?> _sanitizedSample(
    NaturalConversationQualitySample sample,
  ) {
    final scenario = sample.scenario;
    final observation = sample.observation;
    final utteranceCount = observation.utterances.length;
    final actionSignatures = _actionSignatures(observation);
    final staleReferences = _potentialStaleReferenceCount(sample);
    final timing = observation.timing;
    final responseBytes = utf8.encode(observation.aggregateReply).length;
    return <String, Object?>{
      'scenarioId': scenario.id,
      'locale': _localeName(scenario.locale),
      'category': _categoryName(scenario.category),
      'focuses': scenario.focuses.map((focus) => focus.name).toList(),
      'outcome': _outcomeName(observation.outcome),
      'utteranceCount': utteranceCount,
      'usesUtteranceProtocol': observation.usesUtteranceProtocol,
      'responseUtf8Bytes': math.min(responseBytes, 65536),
      'responseSizeCapped': responseBytes > 65536,
      'bodyCueCount': actionSignatures.length,
      'semanticPauseCount': observation.utterances
          .where((utterance) => utterance.pause != null)
          .length,
      'repeatedBodyCueCount':
          actionSignatures.length - actionSignatures.toSet().length,
      'potentialStaleReferenceCount': staleReferences,
      'staleReferenceReviewRequired': staleReferences > 0,
      'emotionReviewRequired':
          scenario.emotionEvidence !=
          NaturalConversationEmotionEvidence.explicit,
      'ambiguousEmotionWithBodyCue':
          scenario.emotionEvidence !=
              NaturalConversationEmotionEvidence.explicit &&
          actionSignatures.isNotEmpty,
      'timingSource': timing == null ? null : _timingSourceName(timing.source),
      'firstVisibleMs': _boundedTiming(timing?.firstVisibleMilliseconds),
      'firstAudioMs': _boundedTiming(timing?.firstAudioMilliseconds),
    };
  }

  Map<String, Object?> _humanReviewSample(
    NaturalConversationQualitySample sample,
  ) {
    final scenario = sample.scenario;
    final observation = sample.observation;
    return <String, Object?>{
      'scenario': <String, Object?>{
        'id': scenario.id,
        'locale': _localeName(scenario.locale),
        'category': _categoryName(scenario.category),
        'focuses': scenario.focuses.map((focus) => focus.name).toList(),
        'emotionEvidence': _emotionEvidenceName(scenario.emotionEvidence),
        'history': scenario.history
            .map(
              (turn) => <String, Object?>{
                'role': turn.role == NaturalConversationHistoryRole.user
                    ? 'user'
                    : 'assistant',
                'text': turn.text,
              },
            )
            .toList(growable: false),
        'userText': scenario.userText,
      },
      'observed': <String, Object?>{
        'outcome': _outcomeName(observation.outcome),
        'aggregateReply': observation.aggregateReply,
        'usesUtteranceProtocol': observation.usesUtteranceProtocol,
        'utterances': observation.utterances
            .map(
              (utterance) => <String, Object?>{
                'text': utterance.text,
                'after': utterance.after,
                'pause': utterance.pause,
                'body': utterance.body,
              },
            )
            .toList(growable: false),
        'timing': observation.timing == null
            ? null
            : <String, Object?>{
                'source': _timingSourceName(observation.timing!.source),
                'firstVisibleMs': observation.timing!.firstVisibleMilliseconds,
                'firstAudioMs': observation.timing!.firstAudioMilliseconds,
              },
      },
      'machineFlags': <String, Object?>{
        'potentialStaleReferenceCount': _potentialStaleReferenceCount(sample),
        'emotionReviewRequired':
            scenario.emotionEvidence !=
            NaturalConversationEmotionEvidence.explicit,
      },
      'ratings': <String, Object?>{
        'naturalness': null,
        'contextUse': null,
        'segmentation': null,
        'emotionalAttunement': null,
        'actionFit': null,
        'pauseRhythm': null,
        'speechIdleCoordination': null,
        'semanticCorrectness': null,
        'emotionOverInferred': null,
        'staleContentLeaked': null,
        'repeatedWording': null,
        'unnecessaryAction': null,
        'speechIdleInterference': null,
        'notes': '',
      },
    };
  }
}

final class _QualitySummary {
  _QualitySummary(this.samples)
    : completed = samples
          .where(
            (sample) =>
                sample.observation.outcome ==
                NaturalConversationQualityOutcome.completed,
          )
          .toList(growable: false);

  final List<NaturalConversationQualitySample> samples;
  final List<NaturalConversationQualitySample> completed;

  Map<String, Object?> toJson() {
    final outcomeCounts = <String, int>{
      for (final outcome in NaturalConversationQualityOutcome.values)
        _outcomeName(outcome): 0,
    };
    final distribution = <String, int>{'0': 0, '1': 0, '2': 0, '3': 0};
    final openings = <String>[];
    final replies = <String>[];
    final actionSignatures = <String>[];
    final firstVisible = <int>[];
    final firstAudio = <int>[];
    var bodyCueCount = 0;
    var repeatedBodyCueCount = 0;
    var potentialStaleReferenceSamples = 0;
    var emotionReviewRequiredSamples = 0;
    var ambiguousEmotionWithBodyCueSamples = 0;
    var utteranceProtocolSamples = 0;
    var semanticPauseCount = 0;

    for (final sample in samples) {
      final observation = sample.observation;
      outcomeCounts[_outcomeName(observation.outcome)] =
          outcomeCounts[_outcomeName(observation.outcome)]! + 1;
      distribution[observation.utterances.length.toString()] =
          distribution[observation.utterances.length.toString()]! + 1;
      if (observation.outcome != NaturalConversationQualityOutcome.completed) {
        continue;
      }
      if (observation.usesUtteranceProtocol) utteranceProtocolSamples++;
      semanticPauseCount += observation.utterances
          .where((utterance) => utterance.pause != null)
          .length;
      openings.add(_openingKey(observation));
      replies.add(_normalizedText(observation.aggregateReply));
      final signatures = _actionSignatures(observation);
      bodyCueCount += signatures.length;
      repeatedBodyCueCount += signatures.length - signatures.toSet().length;
      actionSignatures.addAll(signatures);
      if (_potentialStaleReferenceCount(sample) > 0) {
        potentialStaleReferenceSamples++;
      }
      final needsEmotionReview =
          sample.scenario.emotionEvidence !=
          NaturalConversationEmotionEvidence.explicit;
      if (needsEmotionReview) emotionReviewRequiredSamples++;
      if (needsEmotionReview && signatures.isNotEmpty) {
        ambiguousEmotionWithBodyCueSamples++;
      }
      final visible = _boundedTiming(
        observation.timing?.firstVisibleMilliseconds,
      );
      final audio = _boundedTiming(observation.timing?.firstAudioMilliseconds);
      if (visible != null) firstVisible.add(visible);
      if (audio != null) firstAudio.add(audio);
    }

    final utteranceCount = completed.fold<int>(
      0,
      (sum, sample) => sum + sample.observation.utterances.length,
    );
    return <String, Object?>{
      'samples': samples.length,
      'completed': completed.length,
      'outcomes': outcomeCounts,
      'utteranceDistribution': distribution,
      'meanUtterancesPerCompleted': completed.isEmpty
          ? null
          : utteranceCount / completed.length,
      'utteranceProtocolSamples': utteranceProtocolSamples,
      'semanticPauseCount': semanticPauseCount,
      'openingReuse': _reuseSummary(openings),
      'exactReplyReuse': _reuseSummary(replies),
      'bodyCues': <String, Object?>{
        'count': bodyCueCount,
        'perUtterance': utteranceCount == 0
            ? null
            : bodyCueCount / utteranceCount,
        'repeatedWithinReply': repeatedBodyCueCount,
        'crossScenarioReuse': _reuseSummary(actionSignatures),
      },
      'emotionReview': <String, Object?>{
        'requiredSamples': emotionReviewRequiredSamples,
        'ambiguousOrAbsentEvidenceWithBodyCueSamples':
            ambiguousEmotionWithBodyCueSamples,
        'automaticVerdict': false,
      },
      'potentialStaleContent': <String, Object?>{
        'flaggedSamples': potentialStaleReferenceSamples,
        'automaticVerdict': false,
      },
      'timings': <String, Object?>{
        'firstVisibleMs': _timingSummary(firstVisible),
        'firstAudioMs': _timingSummary(firstAudio),
      },
    };
  }
}

Map<String, Object?> _reuseSummary(List<String> values) {
  final counts = <String, int>{};
  for (final value in values.where((value) => value.isNotEmpty)) {
    counts[value] = (counts[value] ?? 0) + 1;
  }
  final repeated = counts.values.where((count) => count > 1).toList();
  return <String, Object?>{
    'groups': repeated.length,
    'affectedSamples': repeated.fold<int>(0, (sum, count) => sum + count),
    'maxGroupSize': repeated.isEmpty ? 0 : repeated.reduce(math.max),
  };
}

Map<String, Object?> _timingSummary(List<int> values) {
  if (values.isEmpty) {
    return const <String, Object?>{
      'available': 0,
      'p50': null,
      'p95': null,
      'max': null,
    };
  }
  final sorted = values.toList()..sort();
  int percentile(double fraction) =>
      sorted[((sorted.length - 1) * fraction).round()];
  return <String, Object?>{
    'available': sorted.length,
    'p50': percentile(0.5),
    'p95': percentile(0.95),
    'max': sorted.last,
  };
}

List<String> _actionSignatures(NaturalConversationQualityObservation value) =>
    value.utterances
        .map((utterance) => utterance.body)
        .whereType<Map<String, Object?>>()
        .where((body) => body.isNotEmpty)
        .map(_canonicalJson)
        .toList(growable: false);

int _potentialStaleReferenceCount(NaturalConversationQualitySample sample) {
  if (sample.observation.outcome !=
      NaturalConversationQualityOutcome.completed) {
    return 0;
  }
  final reply = _normalizedText(sample.observation.aggregateReply);
  return sample.scenario.potentialStaleMarkers
      .map(_normalizedText)
      .where((marker) => marker.isNotEmpty && reply.contains(marker))
      .length;
}

String _openingKey(NaturalConversationQualityObservation observation) {
  if (observation.utterances.isEmpty) return '';
  final normalized = _normalizedText(observation.utterances.first.text);
  return String.fromCharCodes(normalized.runes.take(16));
}

String _normalizedText(String value) => value
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

int? _boundedTiming(int? value) {
  if (value == null || value < 0) return null;
  return math.min(value, 60000);
}

String _localeName(NaturalConversationQualityLocale locale) => locale.name;
String _categoryName(NaturalConversationQualityCategory category) =>
    category.name;
String _emotionEvidenceName(NaturalConversationEmotionEvidence evidence) =>
    evidence.name;
String _timingSourceName(NaturalConversationTimingSource source) => source.name;
String _outcomeName(NaturalConversationQualityOutcome outcome) => outcome.name;

String _markdownText(String value) => value.replaceAll('\n', ' ').trim();
