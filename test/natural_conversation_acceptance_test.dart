import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/conversation/natural_conversation_acceptance.dart';
import 'package:maaso/src/features/agent/application/conversation/natural_conversation_quality_catalog.dart';

import '../tool/natural_conversation_quality_report.dart';

void main() {
  test('complete bilingual evidence produces a sanitized passing receipt', () {
    final artifact = _passingArtifact();
    artifact['privateMarker'] = 'must-not-leak';

    final report =
        jsonDecode(
              buildNaturalConversationQualityAcceptanceReport(
                jsonEncode(artifact),
              ),
            )
            as Map<String, Object?>;

    expect(report['status'], 'passed');
    expect(report['failureCount'], 0);
    expect(report['incompleteCount'], 0);
    expect(jsonEncode(report), isNot(contains('must-not-leak')));
    expect(jsonEncode(report), isNot(contains('reply-zh')));
  });

  test('missing human and runtime evidence remains explicitly incomplete', () {
    final artifact = _passingArtifact();
    final first = (artifact['reviews'] as List).first as Map<String, Object?>;
    (first['ratings'] as Map<String, Object?>)['naturalness'] = null;
    (artifact['runtimeEvidence'] as Map<String, Object?>)['source'] = null;

    final result = const NaturalConversationAcceptancePolicy().evaluate(
      artifact,
    );
    final reasons = result.failures.map((failure) => failure.code).toSet();

    expect(result.status, NaturalConversationAcceptanceStatus.incomplete);
    expect(reasons, contains('human_rating_missing'));
    expect(reasons, contains('runtime_evidence_source_missing'));
  });

  test('repetition, over-action, and idle interference fail acceptance', () {
    final artifact = _passingArtifact();
    final first = (artifact['reviews'] as List).first as Map<String, Object?>;
    final utterances =
        (first['observed'] as Map<String, Object?>)['utterances'] as List;
    final body = <String, Object?>{'gesture': 'think', 'style': 'subtle'};
    for (final utterance in utterances.cast<Map<String, Object?>>()) {
      utterance['body'] = body;
    }
    final ratings = first['ratings'] as Map<String, Object?>;
    ratings['repeatedWording'] = true;
    final runtime = artifact['runtimeEvidence'] as Map<String, Object?>;
    runtime['idleMotionOverrodeSpeechCount'] = 1;

    final result = const NaturalConversationAcceptancePolicy().evaluate(
      artifact,
    );
    final reasons = result.failures.map((failure) => failure.code).toSet();

    expect(result.status, NaturalConversationAcceptanceStatus.failed);
    expect(reasons, contains('body_cue_repeated'));
    expect(reasons, contains('repeated_wording'));
    expect(reasons, contains('speech_idle_interference'));
  });
}

Map<String, Object?> _passingArtifact() => <String, Object?>{
  'schemaVersion': 1,
  'catalogVersion': naturalConversationQualityCatalogVersion,
  'localOnly': true,
  'containsConversationText': true,
  'runtimeEvidence': <String, Object?>{
    'source': 'deviceProbe',
    'observedTurns': 4,
    'shortPauseSamplesMs': <int>[240, 410],
    'speechMotionBlockedByIdleCount': 0,
    'idleMotionOverrodeSpeechCount': 0,
  },
  'reviews': [
    for (final scenario in naturalConversationQualityScenarios)
      _passingReview(scenario),
  ],
};

Map<String, Object?> _passingReview(
  NaturalConversationQualityScenario scenario,
) {
  final multi =
      scenario.category == NaturalConversationQualityCategory.everydayChoice;
  final prefix = 'reply-${scenario.id}-';
  final utterances = multi
      ? <Map<String, Object?>>[
          {
            'text': '${prefix}one',
            'after': 'continue',
            'pause': 'brief',
            'body': <String, Object?>{'gesture': 'think', 'style': 'subtle'},
          },
          {
            'text': '${prefix}two',
            'after': 'finish',
            'pause': null,
            'body': null,
          },
        ]
      : <Map<String, Object?>>[
          {
            'text': '${prefix}one',
            'after': 'finish',
            'pause': null,
            'body': null,
          },
        ];
  return <String, Object?>{
    'scenario': <String, Object?>{'id': scenario.id},
    'observed': <String, Object?>{
      'outcome': 'completed',
      'aggregateReply': utterances.map((item) => item['text']).join(),
      'usesUtteranceProtocol': true,
      'utterances': utterances,
    },
    'ratings': <String, Object?>{
      'naturalness': 5,
      'contextUse': 5,
      'segmentation': 5,
      'emotionalAttunement': 5,
      'actionFit': 5,
      'pauseRhythm': 5,
      'speechIdleCoordination': 5,
      'semanticCorrectness': 5,
      'emotionOverInferred': false,
      'staleContentLeaked': false,
      'repeatedWording': false,
      'unnecessaryAction': false,
      'speechIdleInterference': false,
      'notes': '',
    },
  };
}
