import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_proxy_tts_engine.dart';
import 'package:maaso/src/core/services/maaso_streaming_tts_session.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentRuntime runtime;
  late _ReplyLlm llm;
  late AgentReplyPresentationService presentation;
  late List<_SpeechTurn> speechTurns;
  late List<AvatarAct> cues;
  var preparations = 0;
  var failOpen = false;

  AgentRuntime createRuntime(
    ConversationDeliveryMode mode, {
    bool injectSpeech = true,
    bool semanticCreation = false,
  }) => AgentRuntime(
    agentId: 'self',
    profile: AgentProfile(
      nickname: 'Tina',
      avatar: '',
      bio: 'test',
      personalityTraits: const ['warm'],
      catchphrase: 'ok',
    ),
    llmClient: llm,
    conversationDeliveryMode: mode,
    semanticCreationEnabled: semanticCreation,
    prepareTtsForNewTurn: (_) async {
      preparations++;
    },
    openConversationSpeechTurn: injectSpeech
        ? ({required turnId, required text}) {
            if (failOpen) throw StateError('engine unavailable');
            final speech = _SpeechTurn(turnId, text);
            speechTurns.add(speech);
            return speech;
          }
        : null,
    applyConversationBodyCue: (act, mayContinue) async {
      if (mayContinue()) cues.add(act);
      return const AvatarBehaviorResult(applied: true, reason: 'test');
    },
  );

  setUp(() async {
    await appServices.reset();
    MaasoTtsPlugin.soundEnabled.value = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          return switch (call.method) {
            'getLanguages' => <String>['zh-CN'],
            'getVoices' => <Object>[],
            _ => 1,
          };
        });
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'speech-runtime-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(AgentTaskJobStore());
    appServices.put(ShortTermMemory());
    presentation = appServices.put(AgentReplyPresentationService());
    llm = _ReplyLlm();
    speechTurns = [];
    cues = [];
    preparations = 0;
    failOpen = false;
    runtime = createRuntime(ConversationDeliveryMode.speech);
    await runtime.init(enabledSkillIds: const {});
  });

  tearDown(() async {
    for (final speech in speechTurns) {
      speech.releaseDrain();
    }
    await runtime.retireAndDrain().timeout(const Duration(seconds: 4));
    await database.close();
    await appServices.reset();
    MaasoTtsPlugin.soundEnabled.value = true;
    TTSEngineRegistry.current = null;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('maaso/streaming_audio_sink'),
          null,
        );
  });

  Future<ConversationTurnHandle> begin({bool single = false}) async {
    final handle = runtime.submitConversation('今天吃啥好呢', database: database);
    await _until(() => llm.streams.isNotEmpty);
    llm.respond(llm.streams.length - 1, _reply(single: single));
    await _until(
      () => speechTurns.isNotEmpty && speechTurns.last.units.isNotEmpty,
    );
    return handle;
  }

  test(
    'durable publication, real start cue, terminal clock and one voice turn',
    () async {
      final handle = await begin();
      final speech = speechTurns.single;
      expect(preparations, 1);
      expect(speech.text, 'English');
      expect(llm.presentationCalls, 1);
      expect(llm.standardCalls, 0);
      expect((await database.getMessages('self')).map((m) => m.content), [
        '今天吃啥好呢',
        '今天想吃点什么口味的？',
      ]);
      expect(cues, isEmpty);
      expect(presentation.snapshot.isSpeaking, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(speech.units, hasLength(1));
      expect(runtime.isProcessing.value, isTrue);

      speech.units.first.start();
      await _until(() => cues.length == 1);
      expect(presentation.snapshot.isSpeaking, isTrue);
      speech.units.first.end(SpeechTerminal.completed);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(speech.units, hasLength(1));
      await _until(() => speech.units.length == 2);
      expect(presentation.snapshot.text, '猪脚饭怎么样？');
      expect(presentation.snapshot.isSpeaking, isFalse);
      speech.units.last.start();
      await _until(() => cues.length == 2);
      var finished = false;
      unawaited(handle.done.then((_) => finished = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(finished, isFalse);
      speech.units.last.end(SpeechTerminal.completed);
      final result = await handle.done;
      expect(result.execution.isSuccess, isTrue);
      expect(result.cancelled, isFalse);
      expect(result.publishedMessages, hasLength(2));
      expect(await database.getMessages('self'), hasLength(3));
      expect(speechTurns, hasLength(1));
      expect(preparations, 1);
    },
  );

  test(
    'first durable bubble and speech start happen before provider done',
    () async {
      final observed = <String>[];
      final handle = AgentPromptCatalog.runWithLocale(
        AppLocale.zh,
        () => runtime.submitConversation(
          '今天吃啥好呢',
          database: database,
          onMessage: (message) {
            if (!message.isUserMessage) observed.add(message.content);
          },
        ),
      );
      await _until(() => llm.streams.isNotEmpty);
      const first = <String, Object?>{
        'type': 'reply.utterance',
        'text': 'OK...',
        'after': 'continue',
      };
      const terminal = <String, Object?>{
        'type': 'reply.utterance',
        'text': '那就吃猪脚饭吧。',
        'after': 'finish',
      };
      llm.add(0, _rawDelta('{"actions":[${jsonEncode(first)}'));
      llm.add(0, _typedEvent(first));

      await _until(
        () =>
            observed.length == 1 &&
            speechTurns.isNotEmpty &&
            speechTurns.single.units.isNotEmpty,
      );
      final speech = speechTurns.single;
      expect(observed, ['OK...']);
      expect(speech.text, '中文', reason: 'turn locale freezes the TTS voice');
      expect(llm.doneSent, isFalse);
      expect(runtime.isProcessing.value, isTrue);
      expect((await database.getMessages('self')).map((m) => m.content), [
        '今天吃啥好呢',
        'OK...',
      ]);

      speech.units.first.start();
      await _until(() => presentation.snapshot.isSpeaking);
      expect(
        llm.doneSent,
        isFalse,
        reason: 'first audio precedes provider done',
      );

      llm.add(0, _rawDelta(',${jsonEncode(terminal)}'));
      llm.add(0, _typedEvent(terminal));
      llm.add(0, _rawDelta('],"reply":"OK...那就吃猪脚饭吧。"}'));
      await Future<void>.delayed(Duration.zero);
      expect(observed, ['OK...'], reason: 'terminal remains provisional');
      llm.finish(0);
      speech.units.first.end(SpeechTerminal.completed);
      await _until(() => speech.units.length == 2);
      speech.units.last.start();
      speech.units.last.end(SpeechTerminal.completed);

      final result = await handle.done.timeout(const Duration(seconds: 4));
      expect(result.execution.isSuccess, isTrue);
      expect(observed, ['OK...', '那就吃猪脚饭吧。']);
      expect((await database.getMessages('self')).map((m) => m.content), [
        '今天吃啥好呢',
        'OK...',
        '那就吃猪脚饭吧。',
      ]);
      expect(speechTurns, hasLength(1));
    },
  );

  test(
    'production submission freezes locale while database admission is blocked',
    () async {
      await runtime.retireAndDrain();
      await database.close();
      final blockingDatabase = _BlockingAdmissionDatabase();
      await blockingDatabase.init(
        factory: databaseFactoryMemory,
        path: 'speech-runtime-locale-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(blockingDatabase.release);
      database = blockingDatabase;
      appServices.put<SecureStorageService>(SecureStorageService());
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;
      runtime = createRuntime(ConversationDeliveryMode.speech);
      await runtime.init(enabledSkillIds: const {});

      final handle = runtime.submitConversation('今天吃啥好呢', database: database);
      await blockingDatabase.entered.future.timeout(const Duration(seconds: 1));
      locale.locale.value = AppLocale.en;
      blockingDatabase.release();
      await _until(() => llm.streams.isNotEmpty);

      final prompt = llm.presentationMessages.single
          .map((message) => message.content)
          .join('\n');
      expect(prompt, contains('结合最近对话和用户当前语气'));
      expect(prompt, isNot(contains('Respond naturally using the recent')));

      const first = <String, Object?>{
        'type': 'reply.utterance',
        'text': 'OK...',
        'after': 'continue',
      };
      const terminal = <String, Object?>{
        'type': 'reply.utterance',
        'text': '那就吃猪脚饭吧。',
        'after': 'finish',
      };
      llm.add(0, _rawDelta('{"actions":[${jsonEncode(first)}'));
      llm.add(0, _typedEvent(first));
      await _until(
        () => speechTurns.isNotEmpty && speechTurns.single.units.isNotEmpty,
      );
      expect(speechTurns.single.text, '中文');
      expect(llm.doneSent, isFalse, reason: 'speech opens lazily before done');

      llm.add(0, _rawDelta(',${jsonEncode(terminal)}'));
      llm.add(0, _typedEvent(terminal));
      llm.add(0, _rawDelta('],"reply":"OK...那就吃猪脚饭吧。"}'));
      llm.finish(0);
      speechTurns.single.units.first.start();
      speechTurns.single.units.first.end(SpeechTerminal.completed);
      await _until(() => speechTurns.single.units.length == 2);
      speechTurns.single.units.last.start();
      speechTurns.single.units.last.end(SpeechTerminal.completed);

      final result = await handle.done.timeout(const Duration(seconds: 4));
      expect(result.execution.isSuccess, isTrue);
      expect(result.cancelled, isFalse);
    },
  );

  test(
    'publication failure cancels an open provider and fences late events',
    () async {
      await runtime.retireAndDrain();
      await database.close();
      final failingDatabase = _FailingPublicationDatabase();
      await failingDatabase.init(
        factory: databaseFactoryMemory,
        path: 'speech-runtime-failing-${DateTime.now().microsecondsSinceEpoch}',
      );
      database = failingDatabase;
      runtime = createRuntime(ConversationDeliveryMode.text);
      await runtime.init(enabledSkillIds: const {});

      final handle = runtime.submitConversation('今天吃啥好呢', database: database);
      await _until(() => llm.streams.isNotEmpty);
      const first = <String, Object?>{
        'type': 'reply.utterance',
        'text': '我想想。',
        'after': 'continue',
      };
      llm.add(0, _rawDelta('{"actions":[${jsonEncode(first)}'));
      llm.add(0, _typedEvent(first));

      final result = await handle.done.timeout(const Duration(seconds: 1));
      expect(result.execution.isSuccess, isFalse);
      expect(llm.cancelledStreams, contains(0));
      expect((await database.getMessages('self')).map((m) => m.content), [
        '今天吃啥好呢',
      ]);

      const late = <String, Object?>{
        'type': 'reply.utterance',
        'text': '迟到内容。',
        'after': 'finish',
      };
      llm.add(0, _rawDelta(',${jsonEncode(late)}],"reply":"我想想。迟到内容。"}'));
      llm.add(0, _typedEvent(late));
      llm.finish(0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect((await database.getMessages('self')).map((m) => m.content), [
        '今天吃啥好呢',
      ]);
    },
  );

  test(
    'new turn during synthesis rejects old start and preserves current bubble',
    () async {
      final first = await begin();
      final old = speechTurns.single.units.single;
      final second = runtime.submitConversation('我换个问题', database: database);
      await _until(() => llm.streams.length == 2);
      llm.respond(
        1,
        _reply(single: true).replaceAll('今天想吃点什么口味的？', '换个角度聊也可以。'),
      );
      await _until(
        () => speechTurns.length == 2 && speechTurns.last.units.isNotEmpty,
      );
      final current = speechTurns.last.units.single;
      current.start();
      await _until(() => cues.length == 1);
      old.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cues, hasLength(1));
      expect(presentation.snapshot.isSpeaking, isTrue);
      expect(presentation.snapshot.text, '换个角度聊也可以。');
      expect((await first.done).cancelled, isTrue);
      current.end(SpeechTerminal.completed);
      expect((await second.done).cancelled, isFalse);
    },
  );

  for (final terminal in [SpeechTerminal.failed, SpeechTerminal.timedOut]) {
    test(
      '$terminal downgrades the rest to text without replay or retry',
      () async {
        final handle = await begin();
        speechTurns.single.units.single.end(terminal);
        final result = await handle.done.timeout(const Duration(seconds: 4));
        expect(result.execution.isSuccess, isTrue);
        expect(result.cancelled, isFalse);
        expect(result.publishedMessages, hasLength(2));
        expect(speechTurns.single.units, hasLength(1));
        expect(cues, hasLength(2));
        expect(presentation.snapshot.isSpeaking, isFalse);
      },
    );
  }

  test(
    'player cancellation marks the logical turn cancelled before closing',
    () async {
      final handle = await begin();
      speechTurns.single.units.single.end(SpeechTerminal.cancelled);
      final result = await handle.done;
      expect(result.cancelled, isTrue);
      expect(result.publishedMessages, hasLength(1));
      expect(cues, isEmpty);
      expect(runtime.isProcessing.value, isFalse);
    },
  );

  test(
    'Stop releases UI but account retirement waits for physical synthesis',
    () async {
      final handle = await begin();
      final speech = speechTurns.single;
      // Attach the physical tail before Runtime captures it for this handle.
      // This turn-level tail also covers any final engine cleanup.
      speech.holdDrain();
      await handle.cancel();
      expect((await handle.done).cancelled, isTrue);
      var drained = false;
      final retirement = runtime.retireAndDrain().then((_) => drained = true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(drained, isFalse);
      speech.releaseDrain();
      await retirement.timeout(const Duration(seconds: 2));
    },
  );

  test('speech setup failure still publishes text and its cue', () async {
    failOpen = true;
    final handle = runtime.submitConversation('今天吃啥好呢', database: database);
    await _until(() => llm.streams.isNotEmpty);
    llm.respond(0, _reply(single: true));
    final result = await handle.done;
    expect(result.execution.isSuccess, isTrue);
    expect(result.publishedMessages, hasLength(1));
    expect(cues, hasLength(1));
    expect(speechTurns, isEmpty);
  });

  for (final scopedGame in [false, true]) {
    test(
      'mobile proxy speech uses correlated PCM with complete identity (game=$scopedGame)',
      () async {
        await runtime.retireAndDrain();
        MaasoTtsPlugin.soundEnabled.value = !scopedGame;
        final socket = _RuntimeTtsSocket();
        final engine = MaasoProxyTtsEngine(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => 'token',
          socketConnector: (_, _) async => socket,
        );
        TTSEngineRegistry.current = engine;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final sinkCalls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('maaso/streaming_audio_sink'),
              (call) async {
                sinkCalls.add(call);
                final arguments = Map<Object?, Object?>.of(
                  call.arguments as Map,
                );
                final generation = arguments['generation'];
                return {
                  'generation': generation,
                  'terminal': switch (call.method) {
                    'start' => 'started',
                    'write' => 'accepted',
                    'stop' =>
                      arguments['drain'] == true ? 'completed' : 'cancelled',
                    _ => throw StateError(
                      'unexpected sink method ${call.method}',
                    ),
                  },
                };
              },
            );
        runtime = createRuntime(
          ConversationDeliveryMode.speech,
          injectSpeech: false,
        );
        await runtime.init(enabledSkillIds: const {});

        final handle = runtime.submitConversation(
          '今天吃啥好呢',
          database: database,
          spokenRepliesAllowed: scopedGame ? () => true : null,
        );
        await _until(() => llm.streams.isNotEmpty);
        llm.respond(0, _reply(single: true));
        final result = await handle.done.timeout(const Duration(seconds: 4));

        expect(result.execution.isSuccess, isTrue);
        final textRequest = socket.sent
            .map((message) => jsonDecode(message) as Map<String, dynamic>)
            .singleWhere((message) => message['type'] == 'text');
        expect(textRequest['turnId'], handle.turnId);
        expect(textRequest['textSeq'], 1);
        expect(textRequest['utteranceId'], isNotEmpty);
        expect(textRequest['segmentOrdinal'], 1);
        expect(sinkCalls.map((call) => call.method), [
          'start',
          'write',
          'stop',
        ]);
        expect(MaasoTtsPlugin.soundEnabled.value, !scopedGame);
        if (scopedGame)
          expect(MaasoTtsPlugin.permitsPlaybackEvents('self'), isFalse);
        engine.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('maaso/streaming_audio_sink'),
              null,
            );
      },
    );
  }

  test('one multi-sentence bubble is one complete speech unit', () async {
    const text = '嗯。今天可以慢慢来，不必一下子做完。先挑一件最轻松的事情吧！';
    final handle = runtime.submitConversation('我今天有点累', database: database);
    await _until(() => llm.streams.isNotEmpty);
    llm.respond(
      0,
      jsonEncode({
        'actions': [
          {'type': 'reply.utterance', 'text': text, 'after': 'finish'},
        ],
        'reply': text,
      }),
    );
    await _until(
      () => speechTurns.isNotEmpty && speechTurns.single.units.isNotEmpty,
    );
    expect(speechTurns.single.spokenTexts, [text]);
    speechTurns.single.units.single.start();
    speechTurns.single.units.single.end(SpeechTerminal.completed);
    final result = await handle.done;
    expect(result.publishedMessages.map((m) => m.content), [text]);
    expect(speechTurns.single.units, hasLength(1));
  });

  test(
    'legacy reply prefix waits for its complete bubble before speech',
    () async {
      await runtime.retireAndDrain();
      runtime = createRuntime(
        ConversationDeliveryMode.legacy,
        semanticCreation: true,
      );
      await runtime.init(enabledSkillIds: const {});
      const text = '听起来你今天很累。先缓一缓，喝口水再说吧。';
      final pending = runtime.chat('我今天有点累', const []);
      await _until(() => llm.streams.isNotEmpty);
      llm.add(0, _rawDelta('{"reply":"听起来你今天很累。'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        speechTurns,
        isEmpty,
        reason: 'one visible paragraph is not sentence-level speech',
      );
      llm.respond(
        0,
        '先缓一缓，喝口水再说吧。","actions":[{"type":"creation.intent","mode":"none"}]}',
      );
      expect((await pending).stdout, text);
      await _until(
        () => speechTurns.isNotEmpty && speechTurns.single.units.isNotEmpty,
      );
      expect(speechTurns.single.spokenTexts, [text]);
      speechTurns.single.units.single.start();
      speechTurns.single.units.single.end(SpeechTerminal.completed);
    },
  );

  test(
    'muted ordinary conversation preserves all semantic bubbles as text',
    () async {
      MaasoTtsPlugin.soundEnabled.value = false;
      final handle = runtime.submitConversation('今天吃啥好呢', database: database);
      await _until(() => llm.streams.isNotEmpty);
      llm.respond(0, _reply());
      final result = await handle.done;
      expect(result.execution.isSuccess, isTrue);
      expect(result.publishedMessages, hasLength(2));
      expect(speechTurns, isEmpty);
      expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
    },
  );

  test(
    'game speech revocation prevents a queued later bubble from playing',
    () async {
      MaasoTtsPlugin.soundEnabled.value = false;
      final revoke = Completer<void>();
      final handle = runtime.submitConversation(
        '今天吃啥好呢',
        database: database,
        spokenRepliesAllowed: () => true,
        onSpeechRevoked: revoke.future,
      );
      await _until(() => llm.streams.isNotEmpty);
      llm.respond(0, _reply());
      await _until(
        () => speechTurns.isNotEmpty && speechTurns.single.units.isNotEmpty,
      );
      speechTurns.single.units.single.start();
      revoke.complete();
      await handle.done;
      expect(speechTurns.single.cancelled, isTrue);
      expect(speechTurns.single.units, hasLength(1));
      expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
    },
  );

  test(
    'text mode applies only published cues without opening a speech turn',
    () async {
      await runtime.retireAndDrain();
      runtime = createRuntime(ConversationDeliveryMode.text);
      await runtime.init(enabledSkillIds: const {});
      final handle = runtime.submitConversation('今天吃啥好呢', database: database);
      await _until(() => llm.streams.isNotEmpty);
      llm.respond(0, _reply(single: true));
      expect((await handle.done).execution.isSuccess, isTrue);
      expect(cues, hasLength(1));
      expect(speechTurns, isEmpty);
    },
  );
}

String _reply({bool single = false}) => jsonEncode({
  'reply': single ? '今天想吃点什么口味的？' : '今天想吃点什么口味的？\n猪脚饭怎么样？',
  'actions': [
    {
      'type': 'reply.utterance',
      'text': '今天想吃点什么口味的？',
      'after': single ? 'finish' : 'continue',
      'body': {
        'mood': 'thinking',
        'gesture': 'none',
        'gaze': 'user',
        'style': 'subtle',
      },
    },
    if (!single)
      {
        'type': 'reply.utterance',
        'text': '猪脚饭怎么样？',
        'after': 'finish',
        'body': {'mood': 'happy', 'gesture': 'explain', 'style': 'subtle'},
      },
  ],
});

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('runtime speech condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _ReplyLlm extends LLMClient implements PresentationStreamingLLMClient {
  final streams = <StreamController<LLMStreamEvent>>[];
  final presentationMessages = <List<Message>>[];
  final cancelledStreams = <int>{};
  int standardCalls = 0;
  int presentationCalls = 0;
  bool doneSent = false;
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('unexpected aggregate');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected route');
  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    standardCalls++;
    return _openStream();
  }

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    presentationCalls++;
    presentationMessages.add(List<Message>.unmodifiable(messages));
    return _openStream();
  }

  Stream<LLMStreamEvent> _openStream() {
    final index = streams.length;
    final stream = StreamController<LLMStreamEvent>(
      onCancel: () => cancelledStreams.add(index),
    );
    streams.add(stream);
    return stream.stream;
  }

  void respond(int index, String reply) {
    add(index, _rawDelta(reply));
    finish(index);
  }

  void add(int index, LLMStreamEvent event) => streams[index].add(event);

  void finish(int index) {
    doneSent = true;
    streams[index].add(const LLMStreamEvent(event: 'done', data: '[DONE]'));
    unawaited(streams[index].close());
  }
}

LLMStreamEvent _rawDelta(String text) =>
    LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': text}));

LLMStreamEvent _typedEvent(Map<String, Object?> action) =>
    LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action));

class _FailingPublicationDatabase extends DBService {
  @override
  Future<ChatMessage?> publishConversationUtterance(
    ChatMessage message, {
    bool Function()? shouldContinue,
    ConversationPublicationTransaction? publication,
  }) async {
    throw StateError('publication failed');
  }
}

class _BlockingAdmissionDatabase extends DBService {
  final entered = Completer<void>();
  final _release = Completer<void>();

  @override
  Future<List<ChatMessage>> getRecentMessages(
    String sessionId, {
    int limit = 8,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await _release.future;
    return super.getRecentMessages(sessionId, limit: limit);
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

class _SpeechTurn implements SpeechTurnHandle {
  _SpeechTurn(this.turnId, this.text);
  @override
  final String turnId;
  final String text;
  final units = <_SpeechUnit>[];
  final spokenTexts = <String>[];
  Completer<void>? _physicalDrain;
  bool cancelled = false;
  @override
  SpeechUtteranceHandle speak({
    required String utteranceId,
    required String text,
  }) {
    if (cancelled) throw StateError('closed turn');
    spokenTexts.add(text);
    final unit = _SpeechUnit(turnId, utteranceId);
    units.add(unit);
    return unit;
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    cancelled = true;
    for (final unit in units) {
      await unit.cancel(reason);
    }
  }

  void holdDrain() => _physicalDrain = Completer<void>();
  void releaseDrain() {
    if (_physicalDrain?.isCompleted == false) _physicalDrain!.complete();
  }

  @override
  Future<void> get drained => _physicalDrain?.future ?? Future<void>.value();
}

class _SpeechUnit implements SpeechUtteranceHandle {
  _SpeechUnit(this.turnId, this.utteranceId);
  @override
  final String turnId;
  @override
  final String utteranceId;
  final _start = Completer<bool>();
  final _end = Completer<SpeechTerminal>();
  void start() {
    if (!_start.isCompleted) _start.complete(true);
  }

  void end(SpeechTerminal outcome) {
    if (!_start.isCompleted && outcome != SpeechTerminal.cancelled) {
      _start.complete(false);
    }
    if (!_end.isCompleted) _end.complete(outcome);
  }

  @override
  Future<bool> get started => _start.future;
  @override
  Future<SpeechTerminal> get terminal => _end.future;
  @override
  Future<void> cancel([String reason = 'cancelled']) async =>
      end(SpeechTerminal.cancelled);
  @override
  Future<void> get drained => Future<void>.value();
}

class _RuntimeTtsSocket implements MaasoTtsSocket {
  final incoming = StreamController<dynamic>();
  final sent = <String>[];

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  void add(String data) {
    sent.add(data);
    final message = jsonDecode(data) as Map<String, dynamic>;
    if (message['type'] == 'start') {
      scheduleMicrotask(() {
        incoming.add(
          jsonEncode({
            'type': 'started',
            'turnId': message['turnId'],
            'segmentProtocol': 1,
          }),
        );
      });
      return;
    }
    if (message['type'] != 'text' || message['textSeq'] == null) return;
    scheduleMicrotask(() {
      final identity = {
        'turnId': message['turnId'],
        'textSeq': message['textSeq'],
        'utteranceId': message['utteranceId'],
        'segmentOrdinal': message['segmentOrdinal'],
      };
      incoming.add(jsonEncode({'type': 'segment_started', ...identity}));
      incoming.add(
        jsonEncode({
          'type': 'audio',
          ...identity,
          'seq': 1,
          'sampleRate': 24000,
          'channels': 1,
          'encoding': 'pcm_s16le',
          'audioBase64': base64Encode([1, 0, 2, 0]),
        }),
      );
      incoming.add(
        jsonEncode({
          'type': 'segment_done',
          ...identity,
          'status': 'completed',
        }),
      );
    });
  }

  @override
  Future<void> close([int? code, String? reason]) => incoming.close();
}
