import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/agent_sound_platforms.dart';
import 'package:maaso/src/core/services/barge_in_controller.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/streaming_pcm_playback_reference_service.dart';
import 'package:maaso/src/features/agent/application/conversation/correlated_streaming_speech_turn.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(installAgentSoundPlatforms);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MaasoTtsPlugin.soundEnabled.value = true;
  });
  tearDown(() async {
    await MaasoTtsPlugin.setSoundEnabled(false);
    MaasoTtsPlugin.soundEnabled.value = true;
  });

  test('muted correlated turn skips session and fallback playback', () async {
    await MaasoTtsPlugin.setSoundEnabled(false);
    var opens = 0;
    final fallback = _FallbackTurn('muted');
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'muted',
      openSession: () async {
        opens++;
        return _CorrelatedSession(turnId: 'muted');
      },
      sinkFactory: () => _VerifiedSink(1),
      fallbackTurn: fallback,
    );
    final utterance = turn.speak(utteranceId: 'u1', text: '安静回复');
    expect(await utterance.started, isFalse);
    expect(await utterance.terminal, SpeechTerminal.cancelled);
    expect(opens, 0);
    expect(fallback.spoken, isEmpty);
    await turn.drained;
  });

  test('scoped PCM speech plays without changing ordinary chat mute', () async {
    MaasoTtsPlugin.soundEnabled.value = false;
    final session = _CorrelatedSession(turnId: 'scoped');
    final sink = _VerifiedSink(701);
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'scoped',
      canSpeak: () => true,
      openSession: () async => session,
      sinkFactory: () => sink,
      fallbackTurn: _FallbackTurn('scoped'),
    );
    final speech = turn.speak(utteranceId: 'u1', text: 'A game reply');
    await session.waitForSends(1);
    session.emit(_event(TtsSegmentEventKind.started, 'scoped', 1, 'u1'));
    session.emit(
      _event(TtsSegmentEventKind.audio, 'scoped', 1, 'u1', frame: _frame(1)),
    );
    session.emit(_event(TtsSegmentEventKind.completed, 'scoped', 1, 'u1'));
    expect(await speech.started, isTrue);
    expect(await speech.terminal, SpeechTerminal.completed);
    expect(sink.writes, 1);
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
    await turn.cancel();
    await turn.drained;
  });

  test(
    'scope revoked while session opens sends no text or fallback speech',
    () async {
      final opening = Completer<TtsSession>();
      var permitted = true;
      final session = _CorrelatedSession(turnId: 'opening');
      final fallback = _FallbackTurn('opening');
      final turn = CorrelatedStreamingSpeechTurn(
        turnId: 'opening',
        canSpeak: () => permitted,
        openSession: () => opening.future,
        sinkFactory: () => _VerifiedSink(702),
        fallbackTurn: fallback,
      );
      final speech = turn.speak(utteranceId: 'u1', text: 'Must not be sent');
      permitted = false;
      opening.complete(session);
      expect(await speech.terminal, SpeechTerminal.cancelled);
      await turn.drained;
      expect(session.sent, isEmpty);
      expect(fallback.spoken, isEmpty);
    },
  );

  test('revoked callback rejects late PCM frames and cannot revive', () async {
    var permitted = true;
    final session = _CorrelatedSession(turnId: 'revoked', closeOnCancel: false);
    final sink = _VerifiedSink(703);
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'revoked',
      canSpeak: () => permitted,
      openSession: () async => session,
      sinkFactory: () => sink,
      fallbackTurn: _FallbackTurn('revoked'),
    );
    final speech = turn.speak(utteranceId: 'u1', text: 'Late reply');
    await session.waitForSends(1);
    permitted = false;
    session.emit(_event(TtsSegmentEventKind.started, 'revoked', 1, 'u1'));
    expect(await speech.terminal, SpeechTerminal.cancelled);
    permitted = true;
    session.emit(
      _event(TtsSegmentEventKind.audio, 'revoked', 1, 'u1', frame: _frame(1)),
    );
    await turn.drained;
    expect(sink.writes, 0);
    await session.close();
  });

  test('throwing PCM scope is rejected before provider binding', () async {
    var opens = 0;
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'bad-scope',
      canSpeak: () => throw StateError('retired'),
      openSession: () async {
        opens++;
        return _CorrelatedSession(turnId: 'bad-scope');
      },
      sinkFactory: () => _VerifiedSink(704),
      fallbackTurn: _FallbackTurn('bad-scope'),
    );
    final speech = turn.speak(utteranceId: 'u1', text: 'Silent');
    expect(await speech.terminal, SpeechTerminal.cancelled);
    expect(opens, 0);
    await turn.drained;
  });

  test('mute revokes a correlated native start before unmute', () async {
    final session = _CorrelatedSession(turnId: 'turn-1');
    final sink = _LateStartSink(501);
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-1',
      openSession: () async => session,
      sinkFactory: () => sink,
      fallbackTurn: _FallbackTurn('turn-1'),
    );
    final utterance = turn.speak(utteranceId: 'u1', text: '取消中的一句话');
    await session.waitForSends(1);
    session.emit(_event(TtsSegmentEventKind.started, 'turn-1', 1, 'u1'));
    session.emit(
      _event(TtsSegmentEventKind.audio, 'turn-1', 1, 'u1', frame: _frame(1)),
    );
    await sink.startEntered.future;
    await MaasoTtsPlugin.setSoundEnabled(false);
    await MaasoTtsPlugin.setSoundEnabled(true);
    sink.releaseStart.complete();
    await turn.drained;
    expect(await utterance.started, isFalse);
    expect(await utterance.terminal, SpeechTerminal.cancelled);
    expect(sink.writes, 0);
    expect(sink.activeGeneration, isNull);
  });
  test('mute retries a failed native PCM stop', () async {
    final session = _CorrelatedSession(turnId: 'turn-retry');
    final sink = _RetryingStopSink(601);
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-retry',
      openSession: () async => session,
      sinkFactory: () => sink,
      fallbackTurn: _FallbackTurn('turn-retry'),
    );
    final utterance = turn.speak(utteranceId: 'u1', text: '停止后保持安静');
    await session.waitForSends(1);
    session.emit(_event(TtsSegmentEventKind.started, 'turn-retry', 1, 'u1'));
    session.emit(
      _event(
        TtsSegmentEventKind.audio,
        'turn-retry',
        1,
        'u1',
        frame: _frame(1),
      ),
    );
    expect(await utterance.started, isTrue);

    await expectLater(MaasoTtsPlugin.setSoundEnabled(false), throwsStateError);
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
    expect(sink.activeGeneration, 601);
    await expectLater(utterance.drained, throwsStateError);
    await MaasoTtsPlugin.setSoundEnabled(false);
    expect(sink.stopAttempts, 2);
    expect(sink.activeGeneration, isNull);
    // The failed cleanup stays observable even after a successful native retry.
    await expectLater(turn.drained, throwsStateError);
  });
  test('segment done waits for its matching native generation drain', () async {
    final session = _CorrelatedSession(turnId: 'turn-1');
    final fallback = _FallbackTurn('turn-1');
    final sinks = <_VerifiedSink>[];
    var nextGeneration = 100;
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-1',
      openSession: () async => session,
      sinkFactory: () {
        final sink = _VerifiedSink(++nextGeneration);
        sinks.add(sink);
        return sink;
      },
      fallbackTurn: fallback,
    );

    final first = turn.speak(utteranceId: 'u1', text: '第一段');
    await session.waitForSends(1);
    session.emit(_event(TtsSegmentEventKind.started, 'turn-1', 1, 'u1'));
    session.emit(
      _event(TtsSegmentEventKind.audio, 'turn-1', 1, 'u1', frame: _frame(1)),
    );
    session.emit(_event(TtsSegmentEventKind.completed, 'turn-1', 1, 'u1'));

    expect(await first.started.timeout(const Duration(seconds: 1)), isTrue);
    expect(
      await first.terminal.timeout(const Duration(seconds: 1)),
      SpeechTerminal.completed,
    );
    expect(sinks.single.stops, [true]);
    expect(sinks.single.writes, 1);

    final second = turn.speak(utteranceId: 'u2', text: '第二段');
    await session.waitForSends(2);
    session.emit(_event(TtsSegmentEventKind.started, 'turn-1', 2, 'u2'));
    session.emit(
      _event(TtsSegmentEventKind.audio, 'turn-1', 2, 'u2', frame: _frame(1)),
    );
    session.emit(_event(TtsSegmentEventKind.completed, 'turn-1', 2, 'u2'));

    expect(
      await second.terminal.timeout(const Duration(seconds: 1)),
      SpeechTerminal.completed,
    );
    expect(sinks.map((sink) => sink.generation).toList(), [101, 102]);
    expect(fallback.spoken, isEmpty);
    await turn.cancel('conversation_closed');
    await turn.drained.timeout(const Duration(seconds: 1));
  });

  test('utterance cancel preempts an in-flight native drain', () async {
    final session = _CorrelatedSession(turnId: 'turn-cancel');
    final sink = _VerifiedSink(201, holdDrain: true);
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-cancel',
      openSession: () async => session,
      sinkFactory: () => sink,
      fallbackTurn: _FallbackTurn('turn-cancel'),
    );
    final handle = turn.speak(utteranceId: 'u1', text: '会被打断');
    await session.waitForSends(1);
    session.emit(_event(TtsSegmentEventKind.started, 'turn-cancel', 1, 'u1'));
    session.emit(
      _event(
        TtsSegmentEventKind.audio,
        'turn-cancel',
        1,
        'u1',
        frame: _frame(1),
      ),
    );
    session.emit(_event(TtsSegmentEventKind.completed, 'turn-cancel', 1, 'u1'));
    await sink.drainStarted.future.timeout(const Duration(seconds: 1));

    await handle.cancel('user_submit').timeout(const Duration(seconds: 1));
    expect(await handle.terminal, SpeechTerminal.cancelled);
    expect(sink.stops, [true, false]);
    expect(sink.drainTerminal, StreamingAudioPlaybackTerminal.cancelled);
    await handle.drained.timeout(const Duration(seconds: 1));
    await turn.drained.timeout(const Duration(seconds: 1));
  });

  test(
    'streaming playback remains pausable and resumable during native drain',
    () async {
      final session = _CorrelatedSession(turnId: 'turn-barge-resume');
      final sink = _VerifiedSink(221, holdDrain: true);
      final references = StreamingPcmPlaybackReferenceService();
      final bargeIn = BargeInController(
        enabled: () => true,
        capturePlayback: ({agentId}) =>
            references.captureCurrentPlayback(agentId: agentId),
      );
      addTearDown(() {
        bargeIn.onClose();
        references.onClose();
      });
      final turn = CorrelatedStreamingSpeechTurn(
        turnId: 'turn-barge-resume',
        agentId: 'agent-a',
        playbackReference: references,
        openSession: () async => session,
        sinkFactory: () => sink,
        fallbackTurn: _FallbackTurn('turn-barge-resume'),
      );
      final handle = turn.speak(utteranceId: 'u1', text: '我还在说话');
      await session.waitForSends(1);
      session.emit(
        _event(TtsSegmentEventKind.started, 'turn-barge-resume', 1, 'u1'),
      );
      session.emit(
        _event(
          TtsSegmentEventKind.audio,
          'turn-barge-resume',
          1,
          'u1',
          frame: _frame(1),
        ),
      );
      session.emit(
        _event(TtsSegmentEventKind.completed, 'turn-barge-resume', 1, 'u1'),
      );
      await sink.drainStarted.future.timeout(const Duration(seconds: 1));

      expect(references.captureCurrentPlayback(agentId: 'agent-a'), isNotNull);
      final candidate = await bargeIn.beginCandidate(agentId: 'agent-a');
      expect(candidate, isNotNull);
      expect(sink.controls, ['pause']);
      expect(references.captureCurrentPlayback(agentId: 'agent-a'), isNull);
      expect(
        await bargeIn.resolveCandidate(candidate!, '嗯', agentId: 'agent-a'),
        BargeInOutcome.resumed,
      );
      expect(sink.controls, ['pause', 'resume']);
      expect(references.captureCurrentPlayback(agentId: 'agent-a'), isNotNull);

      sink.completeDrain();
      expect(await handle.terminal, SpeechTerminal.completed);
      expect(references.captureCurrentPlayback(agentId: 'agent-a'), isNull);
      expect(sink.stops, [true]);
      await turn.cancel('test_complete');
      await turn.drained.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'semantic barge-in preempts drain and prevents queued segment playback',
    () async {
      final session = _CorrelatedSession(turnId: 'turn-barge-stop');
      final references = StreamingPcmPlaybackReferenceService();
      final sinks = <_VerifiedSink>[];
      final bargeIn = BargeInController(
        enabled: () => true,
        capturePlayback: ({agentId}) =>
            references.captureCurrentPlayback(agentId: agentId),
      );
      addTearDown(() {
        bargeIn.onClose();
        references.onClose();
      });
      final turn = CorrelatedStreamingSpeechTurn(
        turnId: 'turn-barge-stop',
        agentId: 'agent-a',
        playbackReference: references,
        openSession: () async => session,
        sinkFactory: () {
          final sink = _VerifiedSink(230 + sinks.length, holdDrain: true);
          sinks.add(sink);
          return sink;
        },
        fallbackTurn: _FallbackTurn('turn-barge-stop'),
      );
      final first = turn.speak(utteranceId: 'u1', text: '第一段');
      final queued = turn.speak(utteranceId: 'u2', text: '不应串音的第二段');
      await session.waitForSends(2);
      session.emit(
        _event(TtsSegmentEventKind.started, 'turn-barge-stop', 1, 'u1'),
      );
      session.emit(
        _event(
          TtsSegmentEventKind.audio,
          'turn-barge-stop',
          1,
          'u1',
          frame: _frame(1),
        ),
      );
      session.emit(
        _event(TtsSegmentEventKind.completed, 'turn-barge-stop', 1, 'u1'),
      );
      session.emit(
        _event(TtsSegmentEventKind.started, 'turn-barge-stop', 2, 'u2'),
      );
      session.emit(
        _event(
          TtsSegmentEventKind.audio,
          'turn-barge-stop',
          2,
          'u2',
          frame: _frame(1),
        ),
      );
      session.emit(
        _event(TtsSegmentEventKind.completed, 'turn-barge-stop', 2, 'u2'),
      );
      await _until(() => sinks.isNotEmpty);
      await sinks.single.drainStarted.future.timeout(
        const Duration(seconds: 1),
      );

      final candidate = await bargeIn.beginCandidate(agentId: 'agent-a');
      expect(candidate, isNotNull);
      expect(
        await bargeIn.resolveCandidate(
          candidate!,
          '等等，先别说了',
          agentId: 'agent-a',
        ),
        BargeInOutcome.interrupted,
      );

      expect(await first.terminal, SpeechTerminal.cancelled);
      expect(await queued.terminal, SpeechTerminal.cancelled);
      expect(sinks, hasLength(1));
      expect(sinks.single.writes, 1);
      expect(sinks.single.stops, [true, false]);
      expect(
        sinks.single.drainTerminal,
        StreamingAudioPlaybackTerminal.cancelled,
      );
      expect(references.captureCurrentPlayback(agentId: 'agent-a'), isNull);
      await turn.drained.timeout(const Duration(seconds: 1));
    },
  );

  test('native drain error revokes the correlated PCM reference', () async {
    final session = _CorrelatedSession(turnId: 'turn-drain-error');
    final references = StreamingPcmPlaybackReferenceService();
    addTearDown(references.onClose);
    final sink = _VerifiedSink(
      241,
      drainFailure: StateError('native drain failed'),
    );
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-drain-error',
      agentId: 'agent-a',
      playbackReference: references,
      openSession: () async => session,
      sinkFactory: () => sink,
      fallbackTurn: _FallbackTurn('turn-drain-error'),
    );
    final handle = turn.speak(utteranceId: 'u1', text: '会失败');
    await session.waitForSends(1);
    session.emit(
      _event(TtsSegmentEventKind.started, 'turn-drain-error', 1, 'u1'),
    );
    session.emit(
      _event(
        TtsSegmentEventKind.audio,
        'turn-drain-error',
        1,
        'u1',
        frame: _frame(1),
      ),
    );
    session.emit(
      _event(TtsSegmentEventKind.completed, 'turn-drain-error', 1, 'u1'),
    );

    expect(await handle.terminal, SpeechTerminal.failed);
    expect(references.captureCurrentPlayback(agentId: 'agent-a'), isNull);
    expect(references.captureCurrentReference(), isNull);
    await turn.drained.timeout(const Duration(seconds: 1));
  });

  test(
    'session close after segment done does not preempt native drain',
    () async {
      final session = _CorrelatedSession(turnId: 'turn-server-done');
      final sink = _VerifiedSink(251, holdDrain: true);
      final turn = CorrelatedStreamingSpeechTurn(
        turnId: 'turn-server-done',
        openSession: () async => session,
        sinkFactory: () => sink,
        fallbackTurn: _FallbackTurn('turn-server-done'),
      );
      final handle = turn.speak(utteranceId: 'u1', text: '最后一段');
      await session.waitForSends(1);
      session.emit(
        _event(TtsSegmentEventKind.started, 'turn-server-done', 1, 'u1'),
      );
      session.emit(
        _event(
          TtsSegmentEventKind.audio,
          'turn-server-done',
          1,
          'u1',
          frame: _frame(1),
        ),
      );
      session.emit(
        _event(TtsSegmentEventKind.completed, 'turn-server-done', 1, 'u1'),
      );
      await session.finishEvents();
      await sink.drainStarted.future.timeout(const Duration(seconds: 1));
      sink.completeDrain();

      expect(await handle.terminal, SpeechTerminal.completed);
      expect(sink.stops, [true]);
      await turn.cancel('test_complete');
      await turn.drained.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'mismatched server identity fails closed before native playback',
    () async {
      final session = _CorrelatedSession(turnId: 'turn-strict');
      var sinkCreations = 0;
      final turn = CorrelatedStreamingSpeechTurn(
        turnId: 'turn-strict',
        openSession: () async => session,
        sinkFactory: () {
          sinkCreations++;
          return _VerifiedSink(301);
        },
        fallbackTurn: _FallbackTurn('turn-strict'),
      );
      final handle = turn.speak(utteranceId: 'u1', text: 'strict');
      await session.waitForSends(1);
      session.emit(_event(TtsSegmentEventKind.started, 'turn-strict', 2, 'u1'));

      expect(await handle.started.timeout(const Duration(seconds: 1)), isFalse);
      expect(await handle.terminal, SpeechTerminal.failed);
      expect(sinkCreations, 0);
      expect(session.cancelReasons, ['segment_identity_mismatch']);
      await turn.drained.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'missing capability delegates to WAV before sending streaming text',
    () async {
      final session = _CorrelatedSession(
        turnId: 'turn-fallback',
        segmentProtocolVersion: 0,
      );
      final fallback = _FallbackTurn('turn-fallback');
      final turn = CorrelatedStreamingSpeechTurn(
        turnId: 'turn-fallback',
        openSession: () async => session,
        sinkFactory: () => _VerifiedSink(401),
        fallbackTurn: fallback,
      );
      final handle = turn.speak(utteranceId: 'u1', text: 'legacy WAV');

      expect(await handle.started.timeout(const Duration(seconds: 1)), isTrue);
      expect(await handle.terminal, SpeechTerminal.completed);
      expect(session.sent, isEmpty);
      expect(session.cancelReasons, ['segment_protocol_unavailable']);
      expect(fallback.spoken, ['u1:legacy WAV']);
      await turn.cancel('conversation_closed');
      await turn.drained.timeout(const Duration(seconds: 1));
    },
  );

  test('future segment is rejected before prior segment completes', () async {
    final session = _CorrelatedSession(turnId: 'turn-order');
    var sinkCreations = 0;
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-order',
      openSession: () async => session,
      sinkFactory: () {
        sinkCreations++;
        return _VerifiedSink(501);
      },
      fallbackTurn: _FallbackTurn('turn-order'),
    );
    final first = turn.speak(utteranceId: 'u1', text: 'one');
    final second = turn.speak(utteranceId: 'u2', text: 'two');
    await session.waitForSends(2);
    session.emit(_event(TtsSegmentEventKind.started, 'turn-order', 2, 'u2'));

    expect(await first.terminal, SpeechTerminal.failed);
    expect(await second.terminal, SpeechTerminal.failed);
    expect(sinkCreations, 0);
    expect(session.cancelReasons, ['segment_start_out_of_order']);
    await turn.drained.timeout(const Duration(seconds: 1));
  });

  test('segment failure immediately fails queued utterances', () async {
    final session = _CorrelatedSession(turnId: 'turn-failed');
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-failed',
      openSession: () async => session,
      sinkFactory: () => _VerifiedSink(551),
      fallbackTurn: _FallbackTurn('turn-failed'),
    );
    final first = turn.speak(utteranceId: 'u1', text: 'one');
    final second = turn.speak(utteranceId: 'u2', text: 'two');
    await session.waitForSends(2);
    session.emit(_event(TtsSegmentEventKind.started, 'turn-failed', 1, 'u1'));
    session.emit(_event(TtsSegmentEventKind.failed, 'turn-failed', 1, 'u1'));

    expect(await first.terminal, SpeechTerminal.failed);
    expect(await second.terminal, SpeechTerminal.failed);
    expect(await first.started, isFalse);
    expect(await second.started, isFalse);
    expect(session.cancelReasons, ['segment_failed']);
    await turn.drained.timeout(const Duration(seconds: 1));
  });

  test('cancelled turn ignores late frames while replacement plays', () async {
    final oldSession = _CorrelatedSession(
      turnId: 'turn-old',
      closeOnCancel: false,
    );
    final oldSink = _VerifiedSink(601);
    final oldTurn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-old',
      openSession: () async => oldSession,
      sinkFactory: () => oldSink,
      fallbackTurn: _FallbackTurn('turn-old'),
    );
    final oldHandle = oldTurn.speak(utteranceId: 'old-u1', text: 'old');
    await oldSession.waitForSends(1);
    await oldTurn.cancel('replaced');
    oldSession.emit(
      _event(TtsSegmentEventKind.started, 'turn-old', 1, 'old-u1'),
    );
    oldSession.emit(
      _event(
        TtsSegmentEventKind.audio,
        'turn-old',
        1,
        'old-u1',
        frame: _frame(1),
      ),
    );

    final newSession = _CorrelatedSession(turnId: 'turn-new');
    final newSink = _VerifiedSink(602);
    final newTurn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-new',
      openSession: () async => newSession,
      sinkFactory: () => newSink,
      fallbackTurn: _FallbackTurn('turn-new'),
    );
    final newHandle = newTurn.speak(utteranceId: 'new-u1', text: 'new');
    await newSession.waitForSends(1);
    newSession.emit(
      _event(TtsSegmentEventKind.started, 'turn-new', 1, 'new-u1'),
    );
    newSession.emit(
      _event(
        TtsSegmentEventKind.audio,
        'turn-new',
        1,
        'new-u1',
        frame: _frame(1),
      ),
    );
    newSession.emit(
      _event(TtsSegmentEventKind.completed, 'turn-new', 1, 'new-u1'),
    );

    expect(await oldHandle.terminal, SpeechTerminal.cancelled);
    expect(oldSink.writes, 0);
    expect(await newHandle.terminal, SpeechTerminal.completed);
    expect(newSink.writes, 1);
    await newTurn.cancel('test_complete');
    await oldSession.close();
    await oldTurn.drained.timeout(const Duration(seconds: 1));
    await newTurn.drained.timeout(const Duration(seconds: 1));
  });

  test('cancel during native start stops the late generation again', () async {
    final session = _CorrelatedSession(turnId: 'turn-start-race');
    final sink = _LateStartSink(651);
    final references = StreamingPcmPlaybackReferenceService();
    addTearDown(references.onClose);
    final turn = CorrelatedStreamingSpeechTurn(
      turnId: 'turn-start-race',
      playbackReference: references,
      openSession: () async => session,
      sinkFactory: () => sink,
      fallbackTurn: _FallbackTurn('turn-start-race'),
    );
    final handle = turn.speak(utteranceId: 'u1', text: '不会泄漏的音频');
    await session.waitForSends(1);
    session.emit(
      _event(TtsSegmentEventKind.started, 'turn-start-race', 1, 'u1'),
    );
    session.emit(
      _event(
        TtsSegmentEventKind.audio,
        'turn-start-race',
        1,
        'u1',
        frame: _frame(1),
      ),
    );
    await sink.startEntered.future.timeout(const Duration(seconds: 1));

    final cancelling = turn.cancel('replaced_during_start');
    await _until(() => sink.stops == 1);
    expect(sink.activeGeneration, isNull);
    sink.releaseStart.complete();

    await cancelling.timeout(const Duration(seconds: 1));
    await turn.drained.timeout(const Duration(seconds: 1));
    expect(await handle.terminal, SpeechTerminal.cancelled);
    expect(sink.stops, 2);
    expect(sink.activeGeneration, isNull);
    expect(sink.writes, 0);
    expect(references.captureCurrentPlayback(), isNull);
  });
}

TtsSegmentEvent _event(
  TtsSegmentEventKind kind,
  String turnId,
  int ordinal,
  String utteranceId, {
  TtsAudioFrame? frame,
}) => TtsSegmentEvent(
  kind: kind,
  identity: TtsSegmentIdentity(
    turnId: turnId,
    textSequence: ordinal,
    utteranceId: utteranceId,
    segmentOrdinal: ordinal,
  ),
  audioFrame: frame,
);

TtsAudioFrame _frame(int sequence) => TtsAudioFrame(
  bytes: Uint8List.fromList([1, 0, 2, 0]),
  sampleRate: 24000,
  channels: 1,
  encoding: 'pcm_s16le',
  sequence: sequence,
);

class _CorrelatedSession implements CorrelatedTtsSession {
  _CorrelatedSession({
    required this.turnId,
    this.segmentProtocolVersion = 1,
    this.closeOnCancel = true,
  });

  @override
  final String turnId;
  @override
  final int segmentProtocolVersion;
  final bool closeOnCancel;
  final events = StreamController<TtsSegmentEvent>.broadcast();
  final frames = StreamController<TtsAudioFrame>.broadcast();
  final sent = <TtsSegmentIdentity>[];
  final cancelReasons = <String>[];
  final _sendChanged = StreamController<void>.broadcast();
  var _closed = false;

  void emit(TtsSegmentEvent event) => events.add(event);

  Future<void> waitForSends(int count) async {
    while (sent.length < count) {
      await _sendChanged.stream.first.timeout(const Duration(seconds: 1));
    }
  }

  @override
  Stream<TtsAudioFrame> get audioFrames => frames.stream;

  @override
  Stream<TtsSegmentEvent> get segmentEvents => events.stream;

  @override
  Future<TtsSegmentIdentity> sendSegment({
    required String utteranceId,
    required String text,
    bool flush = false,
  }) async {
    final ordinal = sent.length + 1;
    final identity = TtsSegmentIdentity(
      turnId: turnId,
      textSequence: ordinal,
      utteranceId: utteranceId,
      segmentOrdinal: ordinal,
    );
    sent.add(identity);
    _sendChanged.add(null);
    return identity;
  }

  @override
  Future<void> sendText(String text, {bool flush = false}) async {}

  @override
  Future<void> finish() async {}

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    cancelReasons.add(reason);
    if (!closeOnCancel) return;
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await events.close();
    await frames.close();
    await _sendChanged.close();
  }

  Future<void> finishEvents() => events.close();
}

class _VerifiedSink implements PositionedStreamingAudioSink {
  _VerifiedSink(this.generation, {this.holdDrain = false, this.drainFailure});

  final int generation;
  final bool holdDrain;
  final Object? drainFailure;
  final stops = <bool>[];
  final controls = <String>[];
  final drainStarted = Completer<void>();
  final _drain = Completer<StreamingAudioPlaybackReceipt>();
  var writes = 0;
  var _active = false;
  var _paused = false;
  StreamingAudioPlaybackTerminal? drainTerminal;

  @override
  int? get activeGeneration => _active ? generation : null;

  void completeDrain() {
    if (_drain.isCompleted) return;
    drainTerminal = StreamingAudioPlaybackTerminal.completed;
    _drain.complete(
      StreamingAudioPlaybackReceipt(
        generation: generation,
        terminal: StreamingAudioPlaybackTerminal.completed,
      ),
    );
  }

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    _active = true;
    _paused = false;
  }

  @override
  Future<void> write(Uint8List pcmS16le) async => writes++;

  @override
  Future<StreamingAudioPlaybackPositionReceipt> positionWithReceipt() async =>
      StreamingAudioPlaybackPositionReceipt(
        generation: generation,
        playedFrames: 0,
        acceptedFrames: 0,
      );

  @override
  Future<void> stop({bool drain = true}) async {
    await stopWithReceipt(drain: drain);
  }

  @override
  Future<StreamingAudioPlaybackReceipt> stopWithReceipt({
    bool drain = true,
  }) async {
    stops.add(drain);
    if (drain) {
      if (!drainStarted.isCompleted) drainStarted.complete();
      final failure = drainFailure;
      if (failure != null) {
        _active = false;
        throw failure;
      }
      if (!holdDrain && !_drain.isCompleted) {
        drainTerminal = StreamingAudioPlaybackTerminal.completed;
        _drain.complete(
          StreamingAudioPlaybackReceipt(
            generation: generation,
            terminal: StreamingAudioPlaybackTerminal.completed,
          ),
        );
      }
      final receipt = await _drain.future;
      _active = false;
      _paused = false;
      return receipt;
    }
    drainTerminal = StreamingAudioPlaybackTerminal.cancelled;
    if (!_drain.isCompleted) {
      _drain.complete(
        StreamingAudioPlaybackReceipt(
          generation: generation,
          terminal: StreamingAudioPlaybackTerminal.cancelled,
        ),
      );
    }
    _active = false;
    _paused = false;
    return StreamingAudioPlaybackReceipt(
      generation: generation,
      terminal: StreamingAudioPlaybackTerminal.cancelled,
    );
  }

  @override
  Future<StreamingAudioControlReceipt> pauseWithReceipt() async {
    if (!_active) throw StateError('inactive');
    controls.add('pause');
    _paused = true;
    return StreamingAudioControlReceipt(
      generation: generation,
      state: StreamingAudioControlState.paused,
    );
  }

  @override
  Future<StreamingAudioControlReceipt> resumeWithReceipt() async {
    if (!_active || !_paused) throw StateError('not paused');
    controls.add('resume');
    _paused = false;
    return StreamingAudioControlReceipt(
      generation: generation,
      state: StreamingAudioControlState.resumed,
    );
  }
}

class _RetryingStopSink extends _VerifiedSink {
  _RetryingStopSink(super.generation);

  var stopAttempts = 0;

  @override
  Future<StreamingAudioPlaybackReceipt> stopWithReceipt({
    bool drain = true,
  }) async {
    if (!drain && ++stopAttempts == 1) {
      throw StateError('native_stop_failed');
    }
    return super.stopWithReceipt(drain: drain);
  }
}

class _LateStartSink implements ControllableStreamingAudioSink {
  _LateStartSink(this.generation);

  final int generation;
  final Completer<void> startEntered = Completer<void>();
  final Completer<void> releaseStart = Completer<void>();
  var stops = 0;
  var writes = 0;
  var _active = false;

  @override
  int? get activeGeneration => _active ? generation : null;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    startEntered.complete();
    await releaseStart.future;
    _active = true;
  }

  @override
  Future<void> write(Uint8List pcmS16le) async => writes++;

  @override
  Future<void> stop({bool drain = true}) async {
    await stopWithReceipt(drain: drain);
  }

  @override
  Future<StreamingAudioPlaybackReceipt> stopWithReceipt({
    bool drain = true,
  }) async {
    stops++;
    _active = false;
    return StreamingAudioPlaybackReceipt(
      generation: generation,
      terminal: drain
          ? StreamingAudioPlaybackTerminal.completed
          : StreamingAudioPlaybackTerminal.cancelled,
    );
  }

  @override
  Future<StreamingAudioControlReceipt> pauseWithReceipt() async =>
      StreamingAudioControlReceipt(
        generation: generation,
        state: StreamingAudioControlState.paused,
      );

  @override
  Future<StreamingAudioControlReceipt> resumeWithReceipt() async =>
      StreamingAudioControlReceipt(
        generation: generation,
        state: StreamingAudioControlState.resumed,
      );
}

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

class _FallbackTurn implements SpeechTurnHandle {
  _FallbackTurn(this.turnId);

  @override
  final String turnId;
  final spoken = <String>[];
  final handles = <_FallbackUtterance>[];

  @override
  SpeechUtteranceHandle speak({
    required String utteranceId,
    required String text,
  }) {
    spoken.add('$utteranceId:$text');
    final handle = _FallbackUtterance(turnId, utteranceId);
    handles.add(handle);
    return handle;
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    for (final handle in handles) {
      await handle.cancel(reason);
    }
  }

  @override
  Future<void> get drained async {
    await Future.wait(handles.map((handle) => handle.drained));
  }
}

class _FallbackUtterance implements SpeechUtteranceHandle {
  _FallbackUtterance(this.turnId, this.utteranceId);

  @override
  final String turnId;
  @override
  final String utteranceId;

  @override
  Future<bool> get started async => true;

  @override
  Future<SpeechTerminal> get terminal async => SpeechTerminal.completed;

  @override
  Future<void> cancel([String reason = 'cancelled']) async {}

  @override
  Future<void> get drained async {}
}
