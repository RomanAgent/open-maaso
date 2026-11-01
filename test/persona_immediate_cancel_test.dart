import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/persona/persona_chat_loop.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

const _plan = AgentTurnPlan(
  route: AgentTurnRoute.chitchat,
  mood: 'attentive',
  confidence: 0.8,
);

void main() {
  test('retirement drain reports a failed local PCM stop', () async {
    final session = _FrameSession();
    final sink = _Sink(stopError: StateError('output_still_active'));
    final speech = Mode3FullDuplexSpeech(
      agentId: 'mode3_failed_stop',
      session: session,
      sink: sink,
    );
    speech.start();
    await expectLater(speech.cancel('retiring'), throwsStateError);
    await expectLater(speech.drained, throwsStateError);
    expect(sink.stops, [false]);
  });

  test(
    'ordinary loop cancel stays responsive but drain reports session failure',
    () async {
      final llm = _HeldLlm();
      final loop = _loop(llm, () async => _FailedCancelSpeechSession());
      final run = loop.run(userText: '你好', turnPlan: _plan);
      await llm.listening.future;
      await _tick();
      await loop.cancel('retiring').timeout(const Duration(seconds: 1));
      await run.timeout(const Duration(seconds: 1));
      await expectLater(loop.drained, throwsStateError);
      await llm.close();
    },
  );

  test(
    'cancelled default opener never starts or emits old speaking state',
    () async {
      final previous = TTSEngineRegistry.current;
      final engine = _OpeningEngine();
      TTSEngineRegistry.current = engine;
      addTearDown(() => TTSEngineRegistry.current = previous);
      final session = _FrameSession();
      final sink = _Sink();
      final cleanup = <Future<void>>[];
      final states = <bool>[];
      final subscription = EventBus()
          .on<SpeakingStatusEvent>()
          .where((event) => event.agentId == 'cancelled_default_opener')
          .listen((event) => states.add(event.isSpeaking));
      addTearDown(subscription.cancel);
      var cancelled = false;
      final opening = PersonaChatLoop.openDefaultSpeechSession(
        'cancelled_default_opener',
        sink: sink,
        shouldCancel: () => cancelled,
        trackCleanup: cleanup.add,
      );
      await _tick();
      cancelled = true;
      engine.opened.complete(session);
      expect(await opening, isNull);
      await Future.wait(cleanup).timeout(const Duration(seconds: 1));
      await _tick();
      expect(session.cancelReasons, ['opener_cancelled']);
      expect(sink.starts, 0);
      expect(sink.stops, isEmpty);
      expect(states, isEmpty);
    },
  );

  test(
    'timed-out default opener retains and cleans its late underlying session',
    () async {
      final previous = TTSEngineRegistry.current;
      final engine = _OpeningEngine();
      TTSEngineRegistry.current = engine;
      addTearDown(() => TTSEngineRegistry.current = previous);
      final session = _FrameSession();
      final sink = _Sink();
      final cleanup = <Future<void>>[];
      final opening = PersonaChatLoop.openDefaultSpeechSession(
        'timed_out_default_opener',
        sink: sink,
        trackCleanup: cleanup.add,
      );
      expect(await opening.timeout(const Duration(seconds: 2)), isNull);
      var drained = false;
      final drain = Future.wait(cleanup).then((_) => drained = true);
      await _tick();
      expect(drained, isFalse);
      engine.opened.complete(session);
      await drain.timeout(const Duration(seconds: 1));
      expect(session.cancelReasons, ['opener_cancelled']);
      expect(sink.starts, 0);
      expect(sink.stops, isEmpty);
    },
  );

  test(
    'uncancelled default opener preserves ordinary live speech startup',
    () async {
      final previous = TTSEngineRegistry.current;
      final engine = _OpeningEngine();
      TTSEngineRegistry.current = engine;
      addTearDown(() => TTSEngineRegistry.current = previous);
      final session = _FrameSession();
      final sink = _Sink();
      final cleanup = <Future<void>>[];
      final opening = PersonaChatLoop.openDefaultSpeechSession(
        'normal_default_opener',
        sink: sink,
        shouldCancel: () => false,
        trackCleanup: cleanup.add,
      );
      engine.opened.complete(session);
      final speech = await opening;
      expect(speech, isA<Mode3FullDuplexSpeech>());
      session.frames.add(_frame(1));
      await _tick();
      await speech!.finish().timeout(const Duration(seconds: 1));
      await Future.wait(cleanup);
      expect(session.cancelReasons, isEmpty);
      expect(sink.starts, 1);
      expect(sink.writes, 1);
      expect(sink.stops, [true]);
    },
  );

  test(
    'cancel stops speech and releases a silent model before network cleanup',
    () async {
      final llm = _HeldLlm(holdCancellation: true);
      final session = _SpeechSession();
      final deltas = <String>[];
      final loop = _loop(llm, () async => session, onReply: deltas.add);
      final run = loop.run(userText: '聊聊吧', turnPlan: _plan);
      await llm.listening.future;
      llm.emit('这一句已经进入语音队列，现在用户打断了。');
      await session.firstSend.future.timeout(const Duration(seconds: 1));

      await loop.cancel('user_submit').timeout(const Duration(seconds: 1));
      await run.timeout(const Duration(seconds: 1));
      expect(session.cancelReasons, ['user_submit']);
      expect(llm.cancelRequested, isTrue);
      final shown = List<String>.of(deltas);
      llm.emit('旧回答不能继续。');
      await _tick();
      expect(deltas, shown);
      expect(session.sent, hasLength(1));

      var drained = false;
      final drain = loop.drained.then((_) => drained = true);
      await _tick();
      expect(drained, isFalse);
      llm.releaseCancellation();
      await drain.timeout(const Duration(seconds: 1));
      await llm.close();
      await loop.cancel();
      expect(session.cancelReasons, hasLength(1));
    },
  );

  test(
    'cancel during a required opener returns now and drains its late session',
    () async {
      final llm = _HeldLlm();
      final opener = Completer<PersonaSpeechSession?>();
      final session = _SpeechSession();
      final loop = _loop(llm, () => opener.future, requireSpeech: true);
      final run = loop.run(userText: '你好', turnPlan: _plan);
      await _tick();
      await loop.cancel('new_turn').timeout(const Duration(seconds: 1));
      await run.timeout(const Duration(seconds: 1));
      expect(llm.listenCalls, 0);

      var drained = false;
      final drain = loop.drained.then((_) => drained = true);
      await _tick();
      expect(drained, isFalse);
      opener.complete(session);
      await drain.timeout(const Duration(seconds: 1));
      expect(session.sent, isEmpty);
      expect(session.cancelReasons, ['new_turn']);
      await llm.close();
    },
  );

  test(
    'cancel cannot mistake an in-progress speech resolution for no session',
    () async {
      final llm = _HeldLlm();
      final opener = Completer<PersonaSpeechSession?>();
      final session = _SpeechSession();
      final loop = _loop(llm, () => opener.future);
      final run = loop.run(userText: '你好', turnPlan: _plan);
      await llm.listening.future;
      llm.emit('这一句足够长，所以语音队列正在等待打开。');
      await _tick();
      await loop.cancel('user_submit').timeout(const Duration(seconds: 1));
      await run.timeout(const Duration(seconds: 1));
      opener.complete(session);
      await loop.drained.timeout(const Duration(seconds: 1));
      expect(session.sent, isEmpty);
      expect(session.cancelReasons, ['user_submit']);
      expect(session.finishCalls, 0);
      await llm.close();
    },
  );

  test(
    'cancel releases an awaiting control handler and drops later deltas',
    () async {
      final llm = _HeldLlm();
      final handlerStarted = Completer<void>();
      final releaseHandler = Completer<void>();
      final deltas = <String>[];
      final loop = _loop(
        llm,
        () async => _SpeechSession(),
        onReply: deltas.add,
        onControl: (_) {
          handlerStarted.complete();
          return releaseHandler.future;
        },
      );
      final run = loop.run(userText: '你好', turnPlan: _plan);
      await llm.listening.future;
      llm.events.add(const LLMStreamEvent(event: 'status', data: '{}'));
      await handlerStarted.future;
      await loop.cancel().timeout(const Duration(seconds: 1));
      await run.timeout(const Duration(seconds: 1));
      releaseHandler.complete();
      llm.emit('不能在新问题后插话。');
      await loop.drained.timeout(const Duration(seconds: 1));
      expect(deltas, isEmpty);
      await llm.close();
    },
  );

  test('cancel before run opens neither the model nor speech', () async {
    final llm = _HeldLlm();
    var openCalls = 0;
    final loop = _loop(llm, () async {
      openCalls++;
      return _SpeechSession();
    });
    await loop.cancel();
    await loop.run(userText: '你好', turnPlan: _plan);
    await loop.drained;
    expect(openCalls, 0);
    expect(llm.listenCalls, 0);
    await llm.close();
  });

  test(
    'verified PCM drain is the playback clock and replaces duration guessing',
    () async {
      final session = _FrameSession();
      final sink = _VerifiedSink();
      final speech = Mode3FullDuplexSpeech(
        agentId: 'mode3_verified_drain',
        session: session,
        sink: sink,
      );
      speech.start();
      session.frames.add(_longFrame(1));
      await _tick();
      await _tick();

      var finished = false;
      final finish = speech.finish().then((_) => finished = true);
      await sink.drainStarted.future.timeout(const Duration(seconds: 1));
      expect(finished, isFalse);

      sink.completeDrain(StreamingAudioPlaybackTerminal.completed);
      await finish.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () =>
            fail('verified native completion must skip PCM timing'),
      );
      expect(sink.stops, [true]);
    },
  );

  test(
    'cancel during verified native drain releases both waiters immediately',
    () async {
      final session = _FrameSession();
      final sink = _VerifiedSink();
      final speech = Mode3FullDuplexSpeech(
        agentId: 'mode3_verified_cancel',
        session: session,
        sink: sink,
      );
      speech.start();
      session.frames.add(_longFrame(1));
      await _tick();
      await _tick();

      final finish = speech.finish();
      await sink.drainStarted.future.timeout(const Duration(seconds: 1));
      await speech.cancel('user_submit').timeout(const Duration(seconds: 1));
      await finish.timeout(const Duration(seconds: 1));
      await speech.drained.timeout(const Duration(seconds: 1));

      expect(sink.stops, [true, false]);
      expect(sink.drainTerminal, StreamingAudioPlaybackTerminal.cancelled);
    },
  );

  test(
    'server EOF keeps queued audio playable but does not disable cancel',
    () async {
      const agentId = 'mode3_cancel_after_eof';
      final session = _FrameSession();
      final sink = _Sink();
      final speaking = <bool>[];
      final visemes = <LipSyncVisemeTrackEvent>[];
      final statuses = EventBus()
          .on<SpeakingStatusEvent>()
          .where((event) => event.agentId == agentId)
          .listen((event) => speaking.add(event.isSpeaking));
      final tracks = EventBus()
          .on<LipSyncVisemeTrackEvent>()
          .where((event) => event.agentId == agentId)
          .listen(visemes.add);
      addTearDown(statuses.cancel);
      addTearDown(tracks.cancel);
      final speech = Mode3FullDuplexSpeech(
        agentId: agentId,
        session: session,
        sink: sink,
      );
      speech.start();
      session.frames.add(_frame(1));
      session.frames.add(_frame(2));
      await _tick();
      await _tick();
      await session.frames.close();
      await _tick();
      expect(sink.writes, 2);
      expect(sink.stops, [true]);
      var finished = false;
      final finish = speech.finish().then((_) => finished = true);
      await _tick();
      expect(finished, isFalse, reason: 'server done is not playback done');
      final beforeCancel = visemes.length;

      await speech.cancel('user_submit').timeout(const Duration(seconds: 1));
      await finish.timeout(const Duration(seconds: 1));
      await speech.drained.timeout(const Duration(seconds: 1));
      expect(sink.stops, [true, false]);
      expect(session.cancelReasons, ['user_submit']);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(visemes, hasLength(beforeCancel));
      expect(speaking, [true, false]);
      await speech.cancel('again');
      expect(sink.stops, [true, false]);
    },
  );

  test(
    'local PCM stop does not wait for remote cancellation acknowledgement',
    () async {
      final session = _FrameSession(holdCancellation: true);
      final sink = _Sink();
      final speech = Mode3FullDuplexSpeech(
        agentId: 'mode3_slow_transport_cancel',
        session: session,
        sink: sink,
      );
      speech.start();
      session.frames.add(_frame(1));
      await _tick();
      await speech.cancel('new_turn').timeout(const Duration(seconds: 1));
      expect(sink.stops, [false]);
      var drained = false;
      final drain = speech.drained.then((_) => drained = true);
      await _tick();
      expect(drained, isFalse);
      session.releaseCancellation();
      await drain.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'cancel while sink starts suppresses late PCM and mouth frames',
    () async {
      const agentId = 'mode3_cancel_start';
      final session = _FrameSession(holdCancellation: true);
      final start = Completer<void>();
      final sink = _LateStartingSink(start.future);
      final events = <ClawEvent>[];
      final subscription = EventBus()
          .on<ClawEvent>()
          .where((event) => event.agentId == agentId)
          .listen(events.add);
      addTearDown(subscription.cancel);
      final speech = Mode3FullDuplexSpeech(
        agentId: agentId,
        session: session,
        sink: sink,
      );
      speech.start();
      session.frames.add(_frame(1));
      session.frames.add(_frame(2));
      await _tick();
      expect(sink.starts, 1);
      await speech.cancel('new_turn').timeout(const Duration(seconds: 1));
      expect(sink.stops, [
        false,
      ], reason: 'Immediate mute does not wait for start.');
      session.frames.add(_frame(3));
      session.releaseCancellation();
      var drained = false;
      final drain = speech.drained.then((_) => drained = true);
      await _tick();
      expect(
        drained,
        isFalse,
        reason: 'Retirement must own the pending native start.',
      );
      start.complete();
      await drain.timeout(const Duration(seconds: 1));
      expect(sink.writes, 0);
      expect(sink.stops, [
        false,
        false,
      ], reason: 'The late native generation needs its own stop.');
      expect(sink.active, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(events.whereType<LipSyncEnvelopeEvent>(), isEmpty);
      expect(events.whereType<LipSyncVisemeTrackEvent>(), isEmpty);
      expect(
        events.whereType<LipSyncAmplitudeEvent>().map(
          (event) => event.amplitude,
        ),
        [0],
      );
      expect(
        events.whereType<SpeakingStatusEvent>().map(
          (event) => event.isSpeaking,
        ),
        [true, false],
      );
      await speech.cancel('again');
      expect(sink.stops, [false, false]);
    },
  );
}

PersonaChatLoop _loop(
  _HeldLlm llm,
  PersonaSpeechSessionOpener open, {
  bool requireSpeech = false,
  PersonaReplyDeltaHandler? onReply,
  PersonaControlEventHandler? onControl,
}) => PersonaChatLoop(
  agentId: 'cancel_test',
  llmClient: llm,
  profileProvider: () => AgentProfile(
    nickname: 'Maaso',
    avatar: '',
    bio: '',
    personalityTraits: const ['playful'],
    catchphrase: '',
  ),
  localeProvider: () => AppLocale.zh,
  openSpeechSession: open,
  fallbackSpeak: (_) => fail('unexpected fallback'),
  requireSpeechSession: requireSpeech,
  onReplyDelta: onReply,
  onControlEvent: onControl,
);

Future<void> _tick() => Future<void>.delayed(Duration.zero);

class _HeldLlm extends LLMClient {
  _HeldLlm({bool holdCancellation = false}) {
    if (!holdCancellation) releaseCancellation();
    events = StreamController<LLMStreamEvent>(
      onListen: () => listening.complete(),
      onCancel: () {
        cancelRequested = true;
        return _cancellationReleased.future;
      },
    );
  }

  late final StreamController<LLMStreamEvent> events;
  final listening = Completer<void>();
  final _cancellationReleased = Completer<void>();
  bool cancelRequested = false;
  int listenCalls = 0;

  void releaseCancellation() {
    if (!_cancellationReleased.isCompleted) _cancellationReleased.complete();
  }

  void emit(String text) => events.add(
    LLMStreamEvent(event: 'reply.delta', data: '{"delta":"$text"}'),
  );

  Future<void> close() async {
    releaseCancellation();
    if (listenCalls == 0) {
      unawaited(events.close());
    } else {
      await events.close();
    }
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    listenCalls++;
    return events.stream;
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async => '';

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '';

  @override
  Stream<String> streamChat(List<Message> messages, {Duration? timeout}) =>
      const Stream.empty();
}

class _SpeechSession implements PersonaSpeechSession {
  final sent = <String>[];
  final cancelReasons = <String>[];
  final firstSend = Completer<void>();
  int finishCalls = 0;

  @override
  Future<void> sendText(String text, {required bool flush}) async {
    sent.add(text);
    if (!firstSend.isCompleted) firstSend.complete();
  }

  @override
  Future<void> finish() async => finishCalls++;

  @override
  Future<void> cancel(String reason) async => cancelReasons.add(reason);
}

class _FailedCancelSpeechSession extends _SpeechSession {
  @override
  Future<void> cancel(String reason) async {
    throw StateError('session_stop_failed');
  }
}

class _FrameSession implements TtsSession {
  _FrameSession({bool holdCancellation = false}) {
    if (!holdCancellation) releaseCancellation();
  }

  final frames = StreamController<TtsAudioFrame>.broadcast();
  final cancelReasons = <String>[];
  final _cancellationReleased = Completer<void>();

  void releaseCancellation() {
    if (!_cancellationReleased.isCompleted) _cancellationReleased.complete();
  }

  @override
  Stream<TtsAudioFrame> get audioFrames => frames.stream;

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    cancelReasons.add(reason);
    await _cancellationReleased.future;
    await frames.close();
  }

  @override
  Future<void> finish() => frames.close();

  @override
  Future<void> sendText(String text, {bool flush = false}) async {}
}

class _OpeningEngine implements FullDuplexTTSEngine {
  final opened = Completer<TtsSession>();

  @override
  Future<TtsSession> openSession({
    required String turnId,
    String? language,
    String? voice,
  }) => opened.future;

  @override
  bool get isReady => true;

  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) async => true;

  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) => throw UnsupportedError('not WAV');
}

class _Sink implements StreamingAudioSink {
  _Sink({this.startGate, this.stopError});

  final Future<void>? startGate;
  final Object? stopError;
  final stops = <bool>[];
  int starts = 0;
  int writes = 0;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    starts++;
    await startGate;
  }

  @override
  Future<void> write(Uint8List bytes) async => writes++;

  @override
  Future<void> stop({bool drain = true}) async {
    stops.add(drain);
    final error = stopError;
    if (error != null) throw error;
  }
}

/// A stop that precedes native setup cannot stop the generation created later.
class _LateStartingSink extends _Sink {
  _LateStartingSink(Future<void> gate) : super(startGate: gate);

  bool active = false;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    await super.start(sampleRate: sampleRate, channels: channels);
    active = true;
  }

  @override
  Future<void> stop({bool drain = true}) async {
    await super.stop(drain: drain);
    active = false;
  }
}

class _VerifiedSink implements VerifiedStreamingAudioSink {
  static const generation = 41;

  final drainStarted = Completer<void>();
  final _drain = Completer<StreamingAudioPlaybackReceipt>();
  final stops = <bool>[];
  StreamingAudioPlaybackTerminal? drainTerminal;

  void completeDrain(StreamingAudioPlaybackTerminal terminal) {
    if (_drain.isCompleted) return;
    drainTerminal = terminal;
    _drain.complete(
      StreamingAudioPlaybackReceipt(generation: generation, terminal: terminal),
    );
  }

  @override
  Future<void> start({required int sampleRate, required int channels}) async {}

  @override
  Future<void> write(Uint8List pcmS16le) async {}

  @override
  Future<void> stop({bool drain = true}) async {
    await stopWithReceipt(drain: drain);
  }

  @override
  Future<StreamingAudioPlaybackReceipt> stopWithReceipt({bool drain = true}) {
    stops.add(drain);
    if (drain) {
      if (!drainStarted.isCompleted) drainStarted.complete();
      return _drain.future;
    }
    completeDrain(StreamingAudioPlaybackTerminal.cancelled);
    return Future<StreamingAudioPlaybackReceipt>.value(
      const StreamingAudioPlaybackReceipt(
        generation: generation,
        terminal: StreamingAudioPlaybackTerminal.cancelled,
      ),
    );
  }
}

TtsAudioFrame _frame(int sequence) {
  final pcm = ByteData(3200);
  for (var i = 0; i < pcm.lengthInBytes; i += 2) {
    pcm.setInt16(i, i.isEven ? 10000 : -10000, Endian.little);
  }
  return TtsAudioFrame(
    bytes: pcm.buffer.asUint8List(),
    sampleRate: 8000,
    channels: 1,
    encoding: 'pcm_s16le',
    sequence: sequence,
  );
}

TtsAudioFrame _longFrame(int sequence) => TtsAudioFrame(
  bytes: Uint8List(16000),
  sampleRate: 8000,
  channels: 1,
  encoding: 'pcm_s16le',
  sequence: sequence,
);
