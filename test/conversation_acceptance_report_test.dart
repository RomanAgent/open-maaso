import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/conversation_acceptance_report.dart';

void main() {
  test('reports nearest-rank count min p50 p95 and max', () {
    final report = buildConversationAcceptanceReport([
      jsonEncode({
        'firstVisibleMs': [
          for (var value = 10; value <= 200; value += 10) value,
        ],
      }),
    ]);

    expect(_metric(report, 'firstVisibleMs'), {
      'status': 'available',
      'unit': 'ms',
      'count': 20,
      'min': 10,
      'p50': 100,
      'p95': 190,
      'max': 200,
    });
    expect(_metric(report, 'stopLatencyMs'), {
      'status': 'unavailable',
      'reason': 'no_observed_samples',
    });
  });

  test('labels occurrence metrics as counts rather than milliseconds', () {
    final report = buildConversationAcceptanceReport([
      '{"duplicatePublishedCount":[0,1],"staleLeakCount":0}',
    ]);

    expect(_metric(report, 'duplicatePublishedCount')['unit'], 'count');
    expect(_metric(report, 'duplicatePublishedCount')['count'], 2);
    expect(_metric(report, 'staleLeakCount')['unit'], 'count');
    expect(_metric(report, 'firstAudioMs')['status'], 'unavailable');
  });

  test('reads the existing M2 receipt shapes without inventing anchors', () {
    final report = buildConversationAcceptanceReport([
      jsonEncode({
        'status': 'completed',
        'published': [0, 1, 2],
        'started': [0, 1, 2],
        'gapsMs': [407, 1802],
        'terminals': ['completed', 'completed', 'completed'],
        'elapsedMs': 13033,
      }),
      jsonEncode({
        'events': [
          {'ms': 1872, 'event': 'started', 'unit': 0},
          {'ms': 4408, 'event': 'terminal', 'unit': 0},
          {'ms': 5799, 'event': 'started', 'unit': 1},
          {'ms': 7322, 'event': 'terminal', 'unit': 1},
          {'ms': 10255, 'event': 'started', 'unit': 2},
          {'ms': 13016, 'event': 'terminal', 'unit': 2},
        ],
        'audibleGapMs': [1391, 2933],
      }),
    ]);

    expect(_metric(report, 'probeStartToFirstAudioMs')['p50'], 1872);
    expect(_metric(report, 'postPlaybackPublishGapMs'), {
      'status': 'available',
      'unit': 'ms',
      'count': 2,
      'min': 407,
      'p50': 407,
      'p95': 1802,
      'max': 1802,
    });
    expect(_metric(report, 'audibleGapMs')['count'], 2);
    expect(_metric(report, 'turnElapsedMs')['max'], 13033);
    expect(_metric(report, 'firstVisibleMs')['status'], 'unavailable');
    expect(_metric(report, 'firstAudioMs')['status'], 'unavailable');
    expect(_metric(report, 'stopLatencyMs')['status'], 'unavailable');
    expect(report['terminalOutcomes'], {'completed': 3});
  });

  test('derives paired timings from sanitized TurnTrace lines', () {
    const trace = '''
[Trace/sample-a] +10ms conversation.admitted turn=t1
[Trace/sample-a] +30ms utterance.published turn=t1 sequence=0
[Trace/sample-a] +50ms conversation.speech_started turn=t1 sequence=0
[Trace/sample-a] +100ms conversation.speech_terminal turn=t1 sequence=0 terminal=completed
[Trace/sample-a] +140ms conversation.speech_started turn=t1 sequence=1
[Trace/sample-a] +200ms interrupt.received turn=t1
[Trace/sample-a] +225ms output.stopped turn=t1
''';

    final report = buildConversationAcceptanceReport([trace]);

    expect(_metric(report, 'firstVisibleMs')['p50'], 20);
    expect(_metric(report, 'firstAudioMs')['p50'], 40);
    expect(_metric(report, 'audibleGapMs')['p50'], 40);
    expect(_metric(report, 'stopLatencyMs')['p50'], 25);
    expect(report['terminalOutcomes'], {'completed': 1});
  });

  test('pairs newline-delimited JSON events in one source', () {
    const events = '''
{"ms":5,"event":"conversation.admitted","turn":"t2"}
{"ms":15,"event":"utterance.published","turn":"t2","sequence":0}
{"ms":35,"event":"speech.started","turn":"t2","sequence":0}
{"ms":80,"event":"interrupt.received","turn":"t2"}
{"ms":99,"event":"output.stopped","turn":"t2"}
''';

    final report = buildConversationAcceptanceReport([events]);

    expect(_metric(report, 'firstVisibleMs')['p50'], 10);
    expect(_metric(report, 'firstAudioMs')['p50'], 30);
    expect(_metric(report, 'stopLatencyMs')['p50'], 19);
  });

  test('failed acoustic candidate cannot steal a later pause receipt', () {
    const trace = '''
[Trace/sample-c] +100ms interrupt.received
[Trace/sample-c] +2100ms barge_in.deadline_exceeded
[Trace/sample-c] +3000ms interrupt.received
[Trace/sample-c] +3025ms output.stopped
''';

    final report = buildConversationAcceptanceReport([trace]);

    expect(_metric(report, 'stopLatencyMs'), {
      'status': 'available',
      'unit': 'ms',
      'count': 1,
      'min': 25,
      'p50': 25,
      'p95': 25,
      'max': 25,
    });
  });

  test('relative candidate clocks remain isolated in JSON reports', () {
    final report = buildConversationAcceptanceReport([
      jsonEncode([
        {'ms': 0, 'event': 'interrupt.received', 'candidate': 1},
        {'ms': 1, 'event': 'output.stopped', 'candidate': 1},
        {'ms': 2, 'event': 'barge_in.resume_empty', 'candidate': 1},
        {'ms': 3, 'event': 'barge_in.control_rejected', 'candidate': 1},
        {'ms': 0, 'event': 'interrupt.received', 'candidate': 2},
        {'ms': 10, 'event': 'output.stopped', 'candidate': 2},
      ]),
    ]);

    expect(_metric(report, 'stopLatencyMs'), {
      'status': 'available',
      'unit': 'ms',
      'count': 2,
      'min': 1,
      'p50': 1,
      'p95': 10,
      'max': 10,
    });
  });

  test('invalid and negative observations remain unavailable', () {
    final report = buildConversationAcceptanceReport([
      'an unrelated log line',
      '{"firstAudioMs":[-1,"12"],"stopLatencyMs":"NaN"}',
    ]);

    expect(_metric(report, 'firstAudioMs')['status'], 'unavailable');
    expect(_metric(report, 'stopLatencyMs')['status'], 'unavailable');
    expect((report['inputs']! as Map)['unrecognized'], 1);
  });
}

Map<String, Object?> _metric(Map<String, Object?> report, String name) =>
    Map<String, Object?>.from((report['metrics']! as Map)[name] as Map);
