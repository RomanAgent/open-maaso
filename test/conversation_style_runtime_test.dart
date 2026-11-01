import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/services/conversation_memory_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_prompt.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentRuntime runtime;
  late _CapturingLlm llm;
  late MasterProfileService master;
  late TTSEngine? previousTts;
  ConversationMemoryService? conversationMemory;
  MemoryWriteCoordinator? memoryWriter;

  void installConversationMemory({MemoryWriteFaultInjector? faultInjector}) {
    final store = EpisodeStore(
      database: database.raw,
      accountScopeDigest:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      memoryV2Mode: () => FeatureRolloutMode.enforce,
    );
    conversationMemory = appServices.put(
      ConversationMemoryService(
        database: database.raw,
        accountScopeDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      ),
    );
    memoryWriter = appServices.put(
      MemoryWriteCoordinator(
        database: database.raw,
        episodeStore: store,
        accountScopeDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        memoryV2Mode: () => FeatureRolloutMode.enforce,
        governedProjectionFamilies: [conversationMemory!],
        faultInjector: faultInjector,
      ),
    );
    conversationMemory!.bindGovernance(memoryWriter!);
  }

  Future<int> runPersisted(String text, {String? wrapper}) async {
    final message = ChatMessage(
      sessionId: 'self',
      senderId: 'user',
      receiverId: 'self',
      content: text,
      timestamp: DateTime.now(),
      isUserMessage: true,
      turnOrigin: 'user',
    );
    final id = await MemoryGovernanceStores.chatMessages.add(
      database.raw,
      message.toJson(),
    );
    await memoryWriter!.runWithPersistedChatSource(
      messageRecordId: id,
      sessionId: 'self',
      agentId: 'self',
      operation: () =>
          runtime.chat(wrapper ?? text, const [], currentUserText: text),
    );
    return id;
  }

  Future<void> acceptPendingFacts() async {
    final heads = await MemoryGovernanceStores.governedProjectionHeads.find(
      database.raw,
    );
    expect(heads, isNotEmpty);
    for (final head in heads) {
      final row = head.value;
      if (row['reviewState'] != 'pending') continue;
      final id = row['headEpisodeId'] as int;
      final result = await memoryWriter!.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: id,
          expectedHeadEpisodeId: id,
          expectedRevision: row['revision'] as int,
        ),
      );
      expect(result.status, MemoryGovernanceStatus.applied);
    }
  }

  setUp(() async {
    await appServices.reset();
    conversationMemory = null;
    memoryWriter = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'style-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(database);
    appServices.put(AgentTaskJobStore());
    master = appServices.put(MasterProfileService());
    llm = _CapturingLlm();
    previousTts = TTSEngineRegistry.current;
    TTSEngineRegistry.current = _SilentEngine();
    runtime = _runtime(llm);
    await runtime.init(enabledSkillIds: const {});
  });

  tearDown(() async {
    await runtime.retireAndDrain().timeout(const Duration(seconds: 5));
    TTSEngineRegistry.current = previousTts;
    await conversationMemory?.deactivateAndDrain();
    await memoryWriter?.deactivateAndDrain();
    await database.close();
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  test('Plan wrapper preserves the direct user boundary', () async {
    await runtime.chat(
      '[PLAN MODE] make a plan\n今天别开玩笑',
      const [],
      currentUserText: '今天别开玩笑',
    );
    expect(_systems(llm.calls.last), contains(_style(noTeasing: true)));
    await runtime.chat('继续', const []);
    expect(_systems(llm.calls.last), contains(_style(noTeasing: true)));
  });

  test('runtime offline fallback receives the same private snapshot', () async {
    appServices.put(SecureStorageService());
    appServices.put(MaasoAgentModeService()).pipelineMode.value =
        AgentPipelineMode.localFull;
    appServices.put(LocalBrainService());
    final backend = _LocalBackend();
    appServices.put<LocalLLMBackend>(backend);
    await runtime.chat('今天别开玩笑', const []);
    expect(llm.calls, isEmpty);
    final style = backend.memories.single!.conversationStyle!;
    expect(style.isPrivate, isTrue);
    expect(style.noTeasing, isTrue);
    await runtime.chat('继续', const []);
    expect(backend.memories.last!.conversationStyle!.noTeasing, isTrue);
  });

  test(
    'raw boundary reaches Persona immediately without SoulService or name write',
    () async {
      await runtime.chat('别叫我宝', const []);
      expect(llm.calls, hasLength(1));
      expect(_systems(llm.calls.last), contains(_style(addresses: ['宝'])));
      expect(master.name.value, isNull);
      await runtime.chat('聊聊电影吧', const []);
      expect(_systems(llm.calls.last), contains(_style(addresses: ['宝'])));
    },
  );

  for (final origin in TurnOrigin.values) {
    test('${origin.name} can only learn direct human boundaries', () async {
      await runtime.chat(
        '今天别开玩笑',
        const [],
        origin: origin,
        liveAudioSink: origin == TurnOrigin.live ? _SilentSink() : null,
      );
      // Live is tested with a working speech transport: it must reach the LLM.
      expect(llm.calls, hasLength(1));
      final first = _systems(llm.calls.last);
      if (origin == TurnOrigin.live) {
        expect(first, contains(_publicStyle()));
        expect(first, isNot(contains(_style(noTeasing: true))));
      } else {
        expect(first, contains(_style(noTeasing: origin.isHumanAuthored)));
      }
      await runtime.chat('继续聊吧', const []);
      expect(
        _systems(llm.calls.last),
        contains(_style(noTeasing: origin.isHumanAuthored)),
      );
    });
  }

  test('live cannot read or clear a private address boundary', () async {
    await runtime.chat('别叫我privateAlias', const []);
    await runtime.chat(
      '可以开玩笑了',
      const [],
      origin: TurnOrigin.live,
      liveAudioSink: _SilentSink(),
    );
    expect(llm.calls, hasLength(2));
    expect(_systems(llm.calls.last), contains(_publicStyle()));
    expect(_systems(llm.calls.last), isNot(contains('privateAlias')));
    await runtime.chat('继续', const []);
    expect(_systems(llm.calls.last), contains('privateAlias'));
  });

  test(
    'peer runtime does not receive owner relationship or boundary data',
    () async {
      appServices.put(RelationshipService()).state.value = RelationshipState(
        firstMetAt: DateTime(2020),
        stage: RelationshipStage.attuned,
        score: 999,
      );
      await runtime.retireAndDrain();
      runtime = _runtime(llm, agentId: 'peer', userId: 'peer');
      await runtime.init(enabledSkillIds: const {});
      await runtime.chat('别叫我privateAlias', const []);
      expect(_systems(llm.calls.last), contains(_publicStyle()));
      expect(_systems(llm.calls.last), isNot(contains('privateAlias')));
    },
  );

  test(
    'segmented conversation receives the same boundaries and keeps its JSON contract',
    () async {
      await runtime.retireAndDrain();
      runtime = _runtime(llm, delivery: ConversationDeliveryMode.text);
      await runtime.init(enabledSkillIds: const {});
      final turn = runtime.submitConversation('别叫我宝', database: database);
      final result = await turn.done.timeout(const Duration(seconds: 5));
      expect(result.execution.isSuccess, isTrue);
      expect(llm.calls, hasLength(1));
      expect(_systems(llm.calls.single), contains(_style(addresses: ['宝'])));
      expect(_systems(llm.calls.single), contains('reply.utterance'));
      expect(master.name.value, isNull);
    },
  );

  test(
    'structured system turn reads existing restrictions without replacing them',
    () async {
      await runtime.chat('别叫我宝', const []);
      await runtime.chat(
        '今天别开玩笑',
        const [],
        origin: TurnOrigin.notificationInteraction,
      );
      expect(_systems(llm.calls.last), contains(_style(addresses: ['宝'])));
      expect(_systems(llm.calls.last), contains('"actions"'));
      expect(
        _systems(llm.calls.last),
        isNot(contains(_style(addresses: ['宝'], noTeasing: true))),
      );
    },
  );

  test(
    'governed preference survives runtime recreation only after acceptance',
    () async {
      installConversationMemory();
      await runPersisted('以后别叫我宝', wrapper: '[PLAN] 今天制定计划');
      expect(_systems(llm.calls.last), contains('宝'));
      expect(conversationMemory!.facts, isEmpty);
      await runtime.retireAndDrain();
      runtime = _runtime(llm);
      await runtime.init(enabledSkillIds: const {});
      await runtime.chat('继续聊吧', const []);
      expect(_systems(llm.calls.last), isNot(contains('"宝"')));
      await acceptPendingFacts();
      await runtime.chat('继续聊吧', const []);
      expect(_systems(llm.calls.last), contains('"宝"'));
    },
  );

  test(
    'source deletion removes both durable and current-session address rules',
    () async {
      installConversationMemory();
      final source = await runPersisted('以后别叫我宝');
      await acceptPendingFacts();
      await runPersisted('今天别开玩笑');
      await MemoryGovernanceStores.chatMessages
          .record(source)
          .delete(database.raw);
      await conversationMemory!.refresh();
      await runtime.chat('继续聊吧', const []);
      final prompt = _systems(llm.calls.last);
      expect(prompt, isNot(contains('"宝"')));
      expect(prompt, contains(_style(noTeasing: true)));
      await runtime.retireAndDrain();
      runtime = _runtime(llm);
      await runtime.init(enabledSkillIds: const {});
      await runtime.chat('继续聊吧', const []);
      expect(_systems(llm.calls.last), isNot(contains('"宝"')));
    },
  );

  test(
    'ledger deletion clears only the chosen same-source session preference',
    () async {
      installConversationMemory();
      await runPersisted('以后别叫我宝，别给我建议');
      await acceptPendingFacts();
      final address = conversationMemory!.facts.singleWhere(
        (fact) => fact.draft.kind == ConversationFactKind.forbiddenAddress,
      );
      final deleted = await memoryWriter!.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: address.episodeId,
          expectedHeadEpisodeId: address.episodeId,
          expectedRevision: address.revision,
        ),
      );
      expect(deleted.status, MemoryGovernanceStatus.applied);
      await runtime.chat('继续聊吧', const []);
      final prompt = _systems(llm.calls.last);
      expect(prompt, isNot(contains('"宝"')));
      expect(
        prompt,
        contains(
          AgentPromptCatalog.text(
            'runtime.conversation_style.boundary.no_unsolicited_advice',
          ),
        ),
      );
    },
  );

  test(
    'public generation cannot observe or propose owner preferences',
    () async {
      installConversationMemory();
      await runPersisted('以后别叫我宝');
      await acceptPendingFacts();
      final factsBefore = conversationMemory!.facts.length;
      await runtime.chat(
        '以后叫我公开昵称',
        const [],
        origin: TurnOrigin.live,
        liveAudioSink: _SilentSink(),
      );
      expect(_systems(llm.calls.last), contains(_publicStyle()));
      expect(_systems(llm.calls.last), isNot(contains('宝')));
      expect(conversationMemory!.facts, hasLength(factsBefore));
    },
  );

  test(
    'cancel during policy storage cannot let the old turn change its successor',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var blocked = false;
      installConversationMemory(
        faultInjector: (point, _) async {
          if (point != MemoryWriteFaultPoint.afterCommit || blocked) return;
          blocked = true;
          entered.complete();
          await release.future;
        },
      );
      final oldTurn = runPersisted('以后别叫我宝');
      await entered.future.timeout(const Duration(seconds: 5));
      await runtime.interruptConversation();
      final nextTurn = runtime.chat('现在聊新话题', const []);
      release.complete();
      await oldTurn.timeout(const Duration(seconds: 5));
      final nextResult = await nextTurn.timeout(const Duration(seconds: 5));
      expect(nextResult.isSuccess, isTrue);
      expect(llm.calls, hasLength(1));
      expect(
        llm.calls.single.any(
          (message) =>
              message.role == 'user' && message.content.contains('现在聊新话题'),
        ),
        isTrue,
      );
      expect(runtime.turn.isProcessing, isFalse);
    },
  );

  test('new runtime starts with no inherited temporary boundary', () async {
    await runtime.chat('别叫我宝', const []);
    await runtime.retireAndDrain();
    runtime = _runtime(llm);
    await runtime.init(enabledSkillIds: const {});
    await runtime.chat('继续', const []);
    expect(_systems(llm.calls.last), contains(_style()));
    expect(_systems(llm.calls.last), isNot(contains('"宝"')));
  });
}

AgentRuntime _runtime(
  _CapturingLlm llm, {
  String agentId = 'self',
  String userId = 'self',
  ConversationDeliveryMode delivery = ConversationDeliveryMode.legacy,
}) => AgentRuntime(
  agentId: agentId,
  profile: AgentProfile(
    userId: userId,
    nickname: 'Maaso',
    avatar: '',
    bio: '',
    personalityTraits: const [],
    catchphrase: '',
  ),
  llmClient: llm,
  conversationDeliveryMode: delivery,
  prepareTtsForNewTurn: (_) async {},
);

String _systems(List<Message> messages) =>
    messages.where((m) => m.role == 'system').map((m) => m.content).join('\n');
String _style({List<String> addresses = const [], bool noTeasing = false}) =>
    ConversationStylePrompt.render(
      ConversationStyleSnapshot(
        isPrivate: true,
        relationshipStage: RelationshipStage.stranger,
        forbiddenAddresses: addresses,
        noTeasing: noTeasing,
      ),
      locale: AgentPromptCatalog.currentLocale,
    );
String _publicStyle() => ConversationStylePrompt.render(
  ConversationStyleSnapshot(isPrivate: false),
  locale: AgentPromptCatalog.currentLocale,
);

class _CapturingLlm extends LLMClient {
  final calls = <List<Message>>[];
  @override
  Duration get defaultTimeout => const Duration(seconds: 2);
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
  String _reply(List<Message> messages) =>
      _systems(messages).contains('Keep the top-level')
      ? '{"actions":[{"type":"reply.utterance","text":"收到。","after":"finish"}],"reply":"收到。"}'
      : '{"reply":"收到。","actions":[]}';
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls.add(List.of(messages));
    return _reply(messages);
  }

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
    calls.add(List.of(messages));
    final segmented = _systems(messages).contains('Keep the top-level');
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: segmented
          ? '{"delta":${jsonEncode(_reply(messages))}}'
          : '{"delta":"收到。"}',
    );
  }
}

class _SilentEngine implements FullDuplexTTSEngine {
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
  }) async => _SilentSession();
}

class _SilentSession implements TtsSession {
  final frames = StreamController<TtsAudioFrame>.broadcast();
  @override
  Stream<TtsAudioFrame> get audioFrames => frames.stream;
  @override
  Future<void> sendText(String text, {bool flush = false}) async {}
  @override
  Future<void> finish() async {
    await frames.close();
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    await frames.close();
  }
}

class _SilentSink implements StreamingAudioSink {
  @override
  Future<void> start({required int sampleRate, required int channels}) async {}
  @override
  Future<void> write(Uint8List pcmS16le) async {}
  @override
  Future<void> stop({bool drain = true}) async {}
}

class _LocalBackend implements LocalLLMBackend {
  final memories = <LocalMemoryContext?>[];
  @override
  bool get isReady => true;
  @override
  Stream<LocalChatEvent> chatStream(
    String userText,
    List<({String role, String content})> history, {
    required LocalPromptMode mode,
    LocalMemoryContext? memory,
    AppLocale? locale,
  }) async* {
    memories.add(memory);
    yield const LocalChatDelta('[calm]收到。');
    yield const LocalChatDone('[calm]收到。');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
