import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/working_memory.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_commentary_runtime.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  late AgentRuntime runtime;
  late DBService database;
  late bool previousSound;
  late TTSEngine? previousTts;
  late ConversationDeliveryMode deliveryMode;
  late List<_PlaySpeechTurn> spokenTurns;

  AgentRuntime createRuntime(LLMClient llm) => AgentRuntime(
    agentId: 'self',
    profile: _profile(),
    llmClient: llm,
    prepareTtsForNewTurn: (_) async {},
    conversationDeliveryModeProvider: () => deliveryMode,
    openConversationSpeechTurn: ({required turnId, required text}) {
      final speech = _PlaySpeechTurn(turnId);
      spokenTurns.add(speech);
      return speech;
    },
  );

  Future<void> replaceRuntime(LLMClient llm) async {
    await runtime.retireAndDrain();
    runtime.dispose();
    TTSEngineRegistry.current = _LaneTtsEngine();
    runtime = createRuntime(llm);
    await runtime.init();
  }

  setUp(() async {
    spokenTurns = [];
    deliveryMode = ConversationDeliveryMode.legacy;
    previousSound = MaasoTtsPlugin.soundEnabled.value;
    previousTts = TTSEngineRegistry.current;
    MaasoTtsPlugin.soundEnabled.value = false;
    appServices.testMode = true;
    appServices.reset();
    appServices.put(SecureStorageService());
    appServices.put(MaasoAgentModeService()).pipelineMode.value =
        AgentPipelineMode.directCloud;
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'play-runtime.db',
    );
    appServices.put(database);
    appServices.put(WorkingMemory());
    appServices.put(await ShortTermMemory().init());
    appServices.put(AgentTaskJobStore());
    runtime = createRuntime(_NoActionLlm());
    await runtime.init();
  });
  tearDown(() async {
    await runtime.retireAndDrain();
    runtime.dispose();
    await database.close();
    appServices.reset();
    MaasoTtsPlugin.soundEnabled.value = previousSound;
    TTSEngineRegistry.current = previousTts;
  });

  test(
    'voice page fence survives private conversation policy capture',
    () async {
      await runtime.retireAndDrain();
      runtime.dispose();
      final provider = _BlockedVoiceReplyLlm();
      runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: provider,
        prepareTtsForNewTurn: (_) async {},
      );
      await runtime.init();
      var current = true;
      final deltas = <String>[];
      final subscription = runtime.onLocalReplyDelta.listen(deltas.add);
      final pending = runtime.runGuardedVoiceChat(
        'How is this game going?',
        const [],
        isCurrent: () => current,
      );
      await provider.started.future;
      current = false;
      expect(runtime.canPublishConversationReply('late voice reply'), isFalse);
      provider.result.complete();
      await pending;
      expect(deltas, isEmpty);
      await subscription.cancel();
    },
  );

  test('stale guarded live never reaches the model or audio sink', () async {
    final provider = _NoActionLlm();
    await replaceRuntime(provider);
    MaasoTtsPlugin.soundEnabled.value = true;
    final sink = _LaneAudioSink();

    final result = await runtime.runGuardedVoiceChat(
      'A public live turn',
      const [],
      origin: TurnOrigin.live,
      liveAudioSink: sink,
      isCurrent: () => false,
    );

    expect(result.isSuccess, isFalse);
    expect(provider.calls, 0);
    expect(sink.starts, isEmpty);
    expect(sink.writes, isEmpty);
    expect(spokenTurns, isEmpty);
    expect(runtime.turn.isProcessing, isFalse);
  });

  test('live caller fence rejects late public text and PCM', () async {
    final provider = _BlockedVoiceReplyLlm();
    await replaceRuntime(provider);
    MaasoTtsPlugin.soundEnabled.value = true;
    var current = true;
    final sink = _LaneAudioSink();
    final deltas = <String>[];
    final subscription = runtime.onLocalReplyDelta.listen(deltas.add);
    final pending = runtime.runGuardedVoiceChat(
      'A public live turn',
      const [],
      origin: TurnOrigin.live,
      liveAudioSink: sink,
      isCurrent: () => current,
    );
    await provider.started.future;
    current = false;
    provider.result.complete();

    final result = await pending.timeout(const Duration(seconds: 2));
    expect(result.stdout, isNot(contains('late voice reply')));
    expect(deltas, isEmpty);
    expect(sink.writes, isEmpty);
    expect(spokenTurns, isEmpty);
    expect(appServices.find<ShortTermMemory>().turns, isEmpty);
    expect(appServices.find<WorkingMemory>().currentUserInput, isNull);
    await subscription.cancel();
  });

  test(
    'late live revocation cannot cancel a newer private speech turn',
    () async {
      final provider = _LiveThenPrivateLlm();
      await replaceRuntime(provider);
      MaasoTtsPlugin.soundEnabled.value = true;
      final oldRevocation = Completer<void>();
      var liveCurrent = true;
      final sink = _LaneAudioSink();
      final live = runtime.runGuardedVoiceChat(
        'A public live turn',
        const [],
        origin: TurnOrigin.live,
        liveAudioSink: sink,
        isCurrent: () => liveCurrent,
        onRevoked: oldRevocation.future,
      );
      await provider.liveStarted.future;
      liveCurrent = false;
      await runtime.interruptConversation();
      provider.releaseLive.complete();
      final liveResult = await live.timeout(const Duration(seconds: 2));
      expect(liveResult.stdout, isNot(contains('late public answer')));
      expect(sink.writes, isEmpty);

      deliveryMode = ConversationDeliveryMode.speech;
      appServices.find<MaasoAgentModeService>().pipelineMode.value =
          AgentPipelineMode.proxyDefault;
      final private = runtime.submitConversation(
        'A private user question',
        database: database,
        respondImmediately: true,
      );
      var privateCompleted = false;
      unawaited(private.done.then((_) => privateCompleted = true));
      await _until(() => spokenTurns.isNotEmpty);
      final speech = spokenTurns.single;
      expect(speech.cancelled, isFalse);
      expect(privateCompleted, isFalse);

      oldRevocation.complete();
      await Future<void>.delayed(Duration.zero);

      expect(speech.cancelled, isFalse);
      expect(privateCompleted, isFalse);
      expect(runtime.canPublishConversationReply('Private answer.'), isTrue);
      speech.unit.finish(SpeechTerminal.completed);
      final result = await private.done.timeout(const Duration(seconds: 2));
      expect(result.execution.isSuccess, isTrue);
      expect(result.cancelled, isFalse);
      expect(result.publishedMessages.map((message) => message.content), [
        'Private answer.',
      ]);
      expect(
        (await database.getMessages('self')).map((message) => message.content),
        ['A private user question', 'Private answer.'],
      );
    },
  );

  test('play lane is exclusive but leaves human input enabled', () async {
    final result = Completer<String>();
    final started = Completer<void>();
    final first = runtime.runGameCommentaryDecision(() {
      started.complete();
      return result.future;
    }, isCurrent: () => true);
    await started.future;
    expect(runtime.turn.isProcessing, isTrue);
    expect(runtime.isSurfacePlayDecisionActive, isTrue);
    expect(runtime.isProcessing.value, isFalse);
    var dispatched = false;
    expect(
      await runtime.runGameCommentaryDecision(() async {
        dispatched = true;
        return 'second';
      }, isCurrent: () => true),
      isNull,
    );
    expect(dispatched, isFalse);
    result.complete('decision');
    expect(await first, 'decision');
    expect(runtime.canAcceptSurfacePlayDecision, isTrue);
  });

  for (final origin in [TurnOrigin.user, TurnOrigin.voice]) {
    test('${origin.name} preempts play and late result is discarded', () async {
      final old = Completer<String>();
      final started = Completer<void>();
      final pending = runtime.runGameCommentaryDecision(() {
        started.complete();
        return old.future;
      }, isCurrent: () => true);
      await started.future;
      final user = await runtime.chat('hello', const [], origin: origin);
      expect(user.isSuccess, isTrue);
      old.complete('late private move');
      expect(await pending, isNull);
      expect(runtime.turn.isProcessing, isFalse);
      expect(runtime.isSurfacePlayDecisionActive, isFalse);
      // Conversational delivery may retain its invitation window after the
      // text result. A game waits until that user-owned session is released.
      await runtime.interruptConversation();
      await Future<void>.delayed(Duration.zero);
      expect(runtime.canAcceptSurfacePlayDecision, isTrue);
    });
  }

  test('stale scope never dispatches or delivers', () async {
    var calls = 0;
    expect(
      await runtime.runGameCommentaryDecision(() async {
        calls++;
        return 'invalid';
      }, isCurrent: () => false),
      isNull,
    );
    expect(calls, 0);
    var current = true;
    final result = Completer<String>();
    final started = Completer<void>();
    final pending = runtime.runGameCommentaryDecision(() {
      started.complete();
      return result.future;
    }, isCurrent: () => current);
    await started.future;
    current = false;
    result.complete('discard');
    expect(await pending, isNull);
  });

  test(
    'actual speech start preempts a game before ASR produces text',
    () async {
      final output = Completer<String>();
      final started = Completer<void>();
      final pending = runtime.runGameCommentaryDecision(() {
        started.complete();
        return output.future;
      }, isCurrent: () => true);
      await started.future;
      EventBus().fire(UserSpeakingStartedEvent());
      await Future<void>.delayed(Duration.zero);
      output.complete('late move during speech');
      expect(await pending, isNull);
      expect(runtime.canAcceptSurfacePlayDecision, isFalse);
      EventBus().fire(
        UserSpeakingEndedEvent(
          duration: const Duration(seconds: 1),
          samples: Float32List(16000),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(runtime.canAcceptSurfacePlayDecision, isTrue);
    },
  );

  test(
    'queued conversation blocks play and emits content-free release',
    () async {
      deliveryMode = ConversationDeliveryMode.text;
      final before = runtime.surfacePlayAvailabilityRevision.value;
      final handle = runtime.submitConversation(
        'Hello',
        database: database,
        respondImmediately: true,
      );
      final admitted = runtime.surfacePlayAvailabilityRevision.value;
      expect(admitted, greaterThan(before));
      expect(runtime.canAcceptSurfacePlayDecision, isFalse);
      await handle.done;
      await Future<void>.delayed(Duration.zero);
      expect(
        runtime.surfacePlayAvailabilityRevision.value,
        greaterThan(admitted),
      );
      await runtime.interruptConversation();
      await Future<void>.delayed(Duration.zero);
      expect(runtime.canAcceptSurfacePlayDecision, isTrue);
    },
  );

  test('ASR handoff blocks play until the owning input releases it', () async {
    final inputOwner = Object();
    var recognizing = true;
    await voiceInputRetirementCoordinator.acquire(
      owner: inputOwner,
      retireCurrentOwner: () async =>
          voiceInputRetirementCoordinator.release(inputOwner),
      hasPendingUserInput: () => recognizing,
    );
    addTearDown(() => voiceInputRetirementCoordinator.release(inputOwner));
    var dispatched = false;
    expect(
      await runtime.runGameCommentaryDecision(() async {
        dispatched = true;
        return 'during ASR';
      }, isCurrent: () => true),
      isNull,
    );
    expect(dispatched, isFalse);
    final before = runtime.surfacePlayAvailabilityRevision.value;
    recognizing = false;
    voiceInputRetirementCoordinator.notifyPriorityChanged(inputOwner);
    expect(runtime.canAcceptSurfacePlayDecision, isTrue);
    expect(runtime.surfacePlayAvailabilityRevision.value, greaterThan(before));
  });

  test('play revocation cancels only its correlated spoken comment', () async {
    MaasoTtsPlugin.soundEnabled.value = true;
    final oldRevoke = Completer<void>();
    final first = runtime.presentGameVoiceComment(
      'A visible game event',
      isCurrent: () => true,
      onRevoked: oldRevoke.future,
    );
    await Future<void>.delayed(Duration.zero);
    expect(spokenTurns, hasLength(1));
    expect(runtime.canAcceptSurfacePlayDecision, isFalse);
    expect(runtime.isProcessing.value, isFalse);
    spokenTurns.first.unit.finish(SpeechTerminal.completed);
    expect(await first, isTrue);
    final nextRevoke = Completer<void>();
    final next = runtime.presentGameVoiceComment(
      'Another visible event',
      isCurrent: () => true,
      onRevoked: nextRevoke.future,
    );
    await Future<void>.delayed(Duration.zero);
    expect(spokenTurns, hasLength(2));
    oldRevoke.complete();
    await Future<void>.delayed(Duration.zero);
    expect(spokenTurns.last.cancelled, isFalse);
    nextRevoke.complete();
    await next;
    expect(spokenTurns.last.cancelled, isTrue);
    expect(runtime.canAcceptSurfacePlayDecision, isTrue);
  });

  test(
    'real style snapshot survives decision end and binds the new speech owner',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      late ConversationStyleSnapshot style;
      final result = await runtime.runGameCommentaryDecision(() async {
        style = await runtime.snapshotGameVoiceStyle();
        expect(style.isCurrent, isTrue);
        return 'A real game reaction';
      }, isCurrent: () => true);
      expect(result, 'A real game reaction');
      expect(runtime.turn.isProcessing, isFalse);
      expect(
        style.isCurrent,
        isTrue,
        reason:
            'Ending generation must not revoke a still-valid style snapshot.',
      );
      final presented = runtime.presentGameVoiceComment(
        result!,
        isCurrent: () => style.isCurrent,
        conversationStyle: style,
      );
      await Future<void>.delayed(Duration.zero);
      expect(spokenTurns, hasLength(1));
      expect(runtime.isSurfacePlayDecisionActive, isTrue);
      spokenTurns.single.unit.finish(SpeechTerminal.completed);
      expect(await presented, isTrue);
      expect(runtime.canAcceptSurfacePlayDecision, isTrue);
    },
  );

  test(
    'actual commentary crosses the runtime decision and presentation owners without a guard cycle',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final stages = <GameCompanionDeliveryStage>[];
      final commentary = GameVoiceCommentaryRuntime(
        runtime: () => runtime,
        isCurrent: (_) => true,
        onDelivery: (_, _, _, stage) => stages.add(stage),
      );
      final result = commentary.comment(
        GameVoiceObservation(
          scopeKey: 'test-owner',
          playerId: 'visible-game',
          generation: 1,
          title: 'Puzzle',
          summary: 'A puzzle',
          publicState: const {'score': 3},
          eventKind: 'progress',
          revision: 1,
          observedAt: DateTime.now(),
        ),
        isCurrent: () => true,
        onRevoked: Completer<void>().future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(spokenTurns, hasLength(1));
      expect(stages, [GameCompanionDeliveryStage.started]);
      spokenTurns.single.unit.finish(SpeechTerminal.completed);
      expect(await result, isTrue);
      expect(stages, [
        GameCompanionDeliveryStage.started,
        GameCompanionDeliveryStage.completed,
      ]);
      expect(runtime.turn.isProcessing, isFalse);
    },
  );

  test(
    'already revoked comments cannot start speech or presentation',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final presentation = appServices.put(AgentReplyPresentationService());
      expect(
        await runtime.presentGameVoiceComment(
          'Too late',
          isCurrent: () => true,
          onRevoked: Future<void>.value(),
        ),
        isFalse,
      );
      expect(spokenTurns, isEmpty);
      expect(presentation.snapshot.isVisible, isFalse);
    },
  );

  test(
    'speech start cancels queued comment without waiting for transcript',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final pending = runtime.presentGameVoiceComment(
        'Game comment',
        isCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(spokenTurns, hasLength(1));
      EventBus().fire(UserSpeakingStartedEvent());
      await Future<void>.delayed(Duration.zero);
      expect(spokenTurns.single.cancelled, isTrue);
      await pending;
      expect(runtime.canAcceptSurfacePlayDecision, isFalse);
    },
  );

  test(
    'provider prompt and exception data stay out of console and caller',
    () async {
      final lines = <String>[];
      await runZoned(
        () async {
          await expectLater(
            runtime.runGameCommentaryDecision(() async {
              // ignore: avoid_print
              print('PRIVATE_HAND_MARKER');
              Log.e('PRIVATE_HAND_MARKER');
              throw StateError('PRIVATE_HAND_MARKER');
            }, isCurrent: () => true),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'code',
                'surface_play_provider_failed',
              ),
            ),
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => lines.add(line),
        ),
      );
      expect(
        lines.where((line) => line.contains('PRIVATE_HAND_MARKER')),
        isEmpty,
      );
    },
  );

  test('busy, stale or muted commentary never paints or speaks', () async {
    final presentation = appServices.put(AgentReplyPresentationService());
    expect(
      await runtime.presentGameVoiceComment(
        'old event',
        isCurrent: () => false,
      ),
      isFalse,
    );
    final result = Completer<String>();
    final started = Completer<void>();
    final pending = runtime.runGameCommentaryDecision(() {
      started.complete();
      return result.future;
    }, isCurrent: () => true);
    await started.future;
    expect(
      await runtime.presentGameVoiceComment('interrupt', isCurrent: () => true),
      isFalse,
    );
    expect(presentation.snapshot.isVisible, isFalse);
    result.complete('done');
    await pending;
    final sound = MaasoTtsPlugin.soundEnabled.value;
    MaasoTtsPlugin.soundEnabled.value = false;
    try {
      expect(
        await runtime.presentGameVoiceComment(
          'Nice move',
          isCurrent: () => true,
        ),
        isFalse,
      );
      expect(presentation.snapshot.isVisible, isFalse);
      expect(presentation.snapshot.isSpeaking, isFalse);
    } finally {
      MaasoTtsPlugin.soundEnabled.value = sound;
    }
  });
}

AgentProfile _profile() => AgentProfile(
  nickname: 'Hiyori',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

class _NoActionLlm implements LLMClient {
  int calls = 0;
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    return '{"reply":"ok","actions":[]}';
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    calls++;
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"ok"}');
  }
}

class _LiveThenPrivateLlm extends _NoActionLlm {
  final liveStarted = Completer<void>();
  final releaseLive = Completer<void>();

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    calls++;
    if (calls == 1) {
      liveStarted.complete();
      await releaseLive.future;
      yield const LLMStreamEvent(
        event: 'reply.delta',
        data: '{"delta":"late public answer"}',
      );
      return;
    }
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode({
        'delta': jsonEncode({
          'actions': [
            {
              'type': 'reply.utterance',
              'text': 'Private answer.',
              'after': 'finish',
            },
          ],
          'reply': 'Private answer.',
        }),
      }),
    );
  }
}

class _LaneTtsEngine implements FullDuplexTTSEngine {
  @override
  bool get isReady => true;

  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) async => true;

  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) async => Uint8List(0);

  @override
  Future<TtsSession> openSession({
    required String turnId,
    String? language,
    String? voice,
  }) async => _LaneTtsSession();
}

class _LaneTtsSession implements TtsSession {
  final _frames = StreamController<TtsAudioFrame>.broadcast();
  int _sequence = 0;

  @override
  Stream<TtsAudioFrame> get audioFrames => _frames.stream;

  @override
  Future<void> sendText(String text, {bool flush = false}) async {
    _frames.add(
      TtsAudioFrame(
        bytes: Uint8List.fromList([1, 0, 2, 0]),
        sampleRate: 24000,
        channels: 1,
        encoding: 'pcm_s16le',
        sequence: ++_sequence,
      ),
    );
  }

  @override
  Future<void> finish() async => _frames.close();

  @override
  Future<void> cancel([String reason = 'cancelled']) async => _frames.close();
}

class _LaneAudioSink implements StreamingAudioSink {
  final starts = <(int, int)>[];
  final writes = <Uint8List>[];

  @override
  Future<void> start({required int sampleRate, required int channels}) async =>
      starts.add((sampleRate, channels));

  @override
  Future<void> write(Uint8List pcmS16le) async => writes.add(pcmS16le);

  @override
  Future<void> stop({bool drain = true}) async {}
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Runtime speech did not reach its boundary');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

class _BlockedVoiceReplyLlm extends _NoActionLlm {
  final started = Completer<void>();
  final result = Completer<void>();
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    if (!started.isCompleted) started.complete();
    await result.future;
    return '{"reply":"late voice reply","actions":[]}';
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await chat(messages, timeout: timeout);
    yield const LLMStreamEvent(
      event: 'reply.delta',
      data: '{"delta":"late voice reply"}',
    );
  }
}

class _PlaySpeechTurn implements SpeechTurnHandle {
  _PlaySpeechTurn(this.turnId);
  @override
  final String turnId;
  late _PlaySpeechUnit unit;
  bool cancelled = false;
  @override
  SpeechUtteranceHandle speak({
    required String utteranceId,
    required String text,
  }) => unit = _PlaySpeechUnit(turnId, utteranceId);
  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    cancelled = true;
    unit.finish(SpeechTerminal.cancelled);
  }

  @override
  Future<void> get drained async {}
}

class _PlaySpeechUnit implements SpeechUtteranceHandle {
  _PlaySpeechUnit(this.turnId, this.utteranceId);
  @override
  final String turnId, utteranceId;
  final Completer<SpeechTerminal> _done = Completer<SpeechTerminal>();
  void finish(SpeechTerminal result) {
    if (!_done.isCompleted) _done.complete(result);
  }

  @override
  Future<bool> get started async => true;
  @override
  Future<SpeechTerminal> get terminal => _done.future;
  @override
  Future<void> get drained async {}
  @override
  Future<void> cancel([String reason = 'cancelled']) async =>
      finish(SpeechTerminal.cancelled);
}
