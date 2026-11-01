import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;
  late Map<String, String> inputBars;

  setUpAll(() {
    source = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();
    inputBars = <String, String>{
      for (final path in const <String>[
        'lib/src/core/widgets/chat_input_bar.dart',
        'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
      ])
        path: File(path).readAsStringSync(),
    };
  });

  test('native voice entry admits only isolated policy-gated candidates', () {
    final entry = _methodBody(
      source,
      'Future<bool> _enterNativeAsrWithVadVoice({',
    );

    expect(source, contains('AcousticBargeInPolicy'));
    expect(entry, contains('nativeAsr.supportsExternalAudioInput'));
    expect(entry, contains('mic.startWithOptions('));
    expect(
      entry,
      contains('includePlaybackCandidates: requestPlaybackCandidates'),
    );
    expect(entry, contains('mic.playbackCandidateCaptureActive'));
    expect(entry, contains('vad.startWithOptions('));
    expect(entry, contains('on<PlaybackSpeechCandidateStartedEvent>()'));
    expect(entry, contains('on<PlaybackSpeechCandidateEndedEvent>()'));
    expect(
      entry.indexOf('mic.startWithOptions('),
      lessThan(entry.indexOf('vad.startWithOptions(')),
    );
  });

  test('candidate owns mic hold before pausing exact output', () {
    final started = _methodBody(source, 'void _onPlaybackCandidateStarted(');
    final begin = _methodBody(source, 'Future<void> _beginPlaybackCandidate(');
    final ended = _methodBody(source, 'void _onPlaybackCandidateEnded(');

    expect(started, contains('holdPlaybackCandidateCapture()'));
    expect(started, contains('_PlaybackCandidateAttempt('));
    expect(
      started.indexOf('holdPlaybackCandidateCapture()'),
      lessThan(started.indexOf('_beginPlaybackCandidate(attempt)')),
    );
    expect(begin, contains('beginCandidate(agentId: \'self\')'));
    expect(ended, isNot(contains('attempt.releaseHold()')));
    expect(ended, contains('PlaybackSpeechCandidateEndedEvent event'));
    expect(source, contains('attempt.releaseHold()'));
  });

  test('candidate ASR advances lease phases before exact PCM recognition', () {
    final recognize = _methodBody(
      source,
      'Future<void> _runPlaybackCandidateOperation(',
    );

    final pending = recognize.indexOf('markRecognitionPending(lease)');
    final recognizing = recognize.indexOf('markRecognizing(lease)');
    final process = recognize.indexOf('_speechSegmentProcessor.process(');
    expect(pending, greaterThanOrEqualTo(0));
    expect(recognizing, greaterThan(pending));
    expect(process, greaterThan(recognizing));
    expect(recognize, contains("source: 'playback-candidate'"));
    expect(recognize, contains('samples: event.samples'));
    expect(recognize, contains('duration: event.duration'));
  });

  test('only semantic interruption waits for and launches a new turn', () {
    final resolve = _methodBody(
      source,
      'Future<void> _resolvePlaybackCandidate(',
    );
    final finalResult = _methodBody(source, 'void _onNativeAsrFinal(');

    expect(finalResult, contains('_resolvePlaybackCandidate('));
    expect(resolve, contains('resolveCandidate('));
    expect(resolve, contains('if (outcome != BargeInOutcome.interrupted)'));
    expect(resolve, contains('_discardProsodyUtterance()'));
    expect(resolve, contains('_voiceTurnSends.waitForActive()'));
    expect(resolve, contains(r"source: 'barge-in-$source'"));
    expect(
      resolve.indexOf('_voiceTurnSends.waitForActive()'),
      lessThan(resolve.indexOf(r"source: 'barge-in-$source'")),
    );
  });

  test('normal turns reopen capture before background send launch', () {
    final restart = _methodBody(source, '_restartNativeAsrVoiceAfterSubmit({');
    final ordinaryEnded = _methodBody(source, 'void _onVadSpeechEnded(');

    expect(ordinaryEnded, contains('_voiceTurnInFlight'));
    expect(restart, contains('_enterNativeAsrWithVadVoice('));
    expect(restart, contains('_voiceTurnSends.launch('));
    expect(
      restart.indexOf('_enterNativeAsrWithVadVoice('),
      lessThan(restart.indexOf('_voiceTurnSends.launch(')),
    );
  });

  test('failure and teardown recover or cancel the exact candidate', () {
    final error = _methodBody(source, 'void _onNativeAsrError(');
    final reset = _methodBody(
      source,
      'Future<void> _resetVoiceModeSubscriptions()',
    );
    final dispose = _methodBody(source, 'void dispose()');
    final cancel = _methodBody(
      source,
      'Future<void> _cancelPlaybackCandidate()',
    );

    expect(error, contains('_recoverPlaybackCandidate('));
    expect(reset, contains('_cancelPlaybackCandidate'));
    expect(dispose, contains('_cancelPlaybackCandidate()'));
    expect(source, contains('recoverCandidate(lease)'));
    expect(cancel, contains('cancelCandidate(lease, agentId: \'self\')'));
    expect(cancel, isNot(contains('await attempt.settled')));
    expect(source, contains('_onBargeInControllerInactive(attempt)'));
    expect(source, contains('captureRestartRequired'));
  });

  test('both chat entrances keep the full acoustic barge-in contract', () {
    for (final MapEntry(key: path, value: input) in inputBars.entries) {
      final entry = _methodBody(
        input,
        'Future<bool> _enterNativeAsrWithVadVoice({',
      );
      final candidate = _methodBody(
        input,
        'Future<void> _runPlaybackCandidateOperation(',
      );
      final resolve = _methodBody(
        input,
        'Future<void> _resolvePlaybackCandidate(',
      );
      final restart = _methodBody(input, '_restartNativeAsrVoiceAfterSubmit({');
      final timeout = _methodBody(input, 'void _onBargeInControllerInactive(');
      final nativeFinal = _methodBody(input, 'void _onNativeAsrFinal(');
      final cancel = _methodBody(
        input,
        'Future<void> _cancelPlaybackCandidate()',
      );
      final reset = _methodBody(
        input,
        'Future<void> _resetVoiceModeSubscriptions()',
      );

      expect(entry, contains('mic.startWithOptions('), reason: path);
      expect(entry, contains('vad.startWithOptions('), reason: path);
      expect(
        entry,
        contains('on<PlaybackSpeechCandidateStartedEvent>()'),
        reason: path,
      );
      expect(
        entry,
        contains('on<PlaybackSpeechCandidateEndedEvent>()'),
        reason: path,
      );
      expect(
        candidate,
        contains('markRecognitionPending(lease)'),
        reason: path,
      );
      expect(candidate, contains('markRecognizing(lease)'), reason: path);
      expect(candidate, contains('samples: event.samples'), reason: path);
      expect(
        resolve,
        contains('_voiceTurnSends.waitForActive()'),
        reason: path,
      );
      expect(restart, contains('_voiceTurnSends.launch('), reason: path);
      expect(
        restart.indexOf('_enterNativeAsrWithVadVoice('),
        lessThan(restart.indexOf('_voiceTurnSends.launch(')),
        reason: path,
      );
      expect(reset, contains('_cancelPlaybackCandidate'), reason: path);

      final schedule = timeout.indexOf('_scheduleNativeVoiceRestart()');
      final clear = timeout.indexOf('_clearPlaybackCandidate(attempt)');
      expect(timeout, contains('attempt.resolving = true'), reason: path);
      expect(timeout, contains('attempt.releaseHold()'), reason: path);
      expect(schedule, greaterThanOrEqualTo(0), reason: path);
      expect(clear, greaterThan(schedule), reason: path);

      final candidateFinal = nativeFinal.indexOf(
        '_resolvePlaybackCandidate(attempt',
      );
      final ordinaryFinal = nativeFinal.indexOf('_submitNativeAsrText(');
      expect(candidateFinal, greaterThanOrEqualTo(0), reason: path);
      expect(ordinaryFinal, greaterThan(candidateFinal), reason: path);
      expect(
        resolve.indexOf('attempt.resolving'),
        lessThan(resolve.indexOf('attempt.controller.resolveCandidate(')),
        reason: path,
      );
      expect(
        cancel,
        contains('_playbackCandidateAttempt = null'),
        reason: path,
      );
      expect(
        entry,
        contains('finalResults.listen(_onNativeAsrFinal)'),
        reason: path,
      );
    }
  });
}

String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  final parameters = source.indexOf('(', start);
  if (parameters < 0) return '';
  var parameterDepth = 0;
  var parameterEnd = -1;
  for (var i = parameters; i < source.length; i++) {
    if (source.codeUnitAt(i) == 40) parameterDepth++;
    if (source.codeUnitAt(i) == 41) {
      parameterDepth--;
      if (parameterDepth == 0) {
        parameterEnd = i;
        break;
      }
    }
  }
  if (parameterEnd < 0) return '';
  final open = source.indexOf('{', parameterEnd);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source.codeUnitAt(i) == 123) depth++;
    if (source.codeUnitAt(i) == 125) {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  return source.substring(start);
}
