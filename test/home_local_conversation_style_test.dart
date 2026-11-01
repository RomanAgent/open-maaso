import 'dart:convert';

import 'package:maaso/src/core/services/conversation_memory_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late _RecordingLocalBackend backend;
  late HomeController home;
  ConversationMemoryService? conversationMemory;
  MemoryWriteCoordinator? memoryWriter;

  setUp(() async {
    await appServices.reset();
    conversationMemory = null;
    memoryWriter = null;
    appServices.testMode = true;
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path:
          'home-local-conversation-style-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    appServices.put(AgentRuntimeRegistry());
    appServices.put(AgentTaskJobStore());
    appServices.put<AgentCoreController>(_IdleCore());
    appServices.put(LocalBrainService());
    backend = _RecordingLocalBackend();
    appServices.put<LocalLLMBackend>(backend);
    final relationship = appServices.put(RelationshipService());
    await relationship.init(firstMetFallback: DateTime(2026, 1, 1));
    relationship.state.value!.stage = RelationshipStage.trusted;
    home = appServices.put(HomeController());
  });

  tearDown(() async {
    await conversationMemory?.deactivateAndDrain();
    await memoryWriter?.deactivateAndDrain();
    await appServices.reset();
    await database.close();
  });

  test(
    'Home fallback does not inherit closeness from a legacy score',
    () async {
      home.inputController.text = '今天别开玩笑';
      await home.send();

      final style = backend.memories.single!.conversationStyle!;
      expect(style.isPrivate, isTrue);
      expect(style.expressionStage, RelationshipExpressionStage.newlyMet);
      expect(style.noTeasing, isTrue);
      expect(home.latestBubble.value, '收到。');
      expect(appServices.find<AgentRuntimeRegistry>().get('self'), isNull);
    },
  );

  test(
    'Home fallback binds saved raw input for reviewed long-term preferences',
    () async {
      const account =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final store = EpisodeStore(
        database: database.raw,
        accountScopeDigest: account,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      );
      conversationMemory = appServices.put(
        ConversationMemoryService(
          database: database.raw,
          accountScopeDigest: account,
          memoryV2Mode: () => FeatureRolloutMode.enforce,
        ),
      );
      memoryWriter = appServices.put(
        MemoryWriteCoordinator(
          database: database.raw,
          episodeStore: store,
          accountScopeDigest: account,
          memoryV2Mode: () => FeatureRolloutMode.enforce,
          governedProjectionFamilies: [conversationMemory!],
        ),
      );
      conversationMemory!.bindGovernance(memoryWriter!);
      home.inputController.text = '以后别叫我宝';
      await home.send();
      expect(
        backend.memories.last!.conversationStyle!.forbiddenAddresses,
        contains('宝'),
      );
      expect(conversationMemory!.facts, isEmpty);
      final heads = await MemoryGovernanceStores.governedProjectionHeads.find(
        database.raw,
      );
      expect(heads, isNotEmpty);
      for (final head in heads) {
        final row = head.value;
        final id = row['headEpisodeId'] as int;
        final accepted = await memoryWriter!.review(
          MemoryGovernanceCommand(
            action: MemoryGovernanceAction.accept,
            targetEpisodeId: id,
            expectedHeadEpisodeId: id,
            expectedRevision: row['revision'] as int,
          ),
        );
        expect(accepted.status, MemoryGovernanceStatus.applied);
      }
      await appServices.delete<HomeController>(force: true);
      home = appServices.put(HomeController());
      home.inputController.text = '你好';
      await home.send();
      expect(
        backend.memories.last!.conversationStyle!.forbiddenAddresses,
        contains('宝'),
      );
    },
  );

  test(
    'realtime mode typed chat uses the same boundary and trusted source',
    () async {
      const account =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      appServices.put(SecureStorageService());
      appServices.put(MaasoAgentModeService()).pipelineMode.value =
          AgentPipelineMode.volcRealtimeAudio;
      final proxy =
          appServices.put<LLMProxyService>(_RecordingProxy())
              as _RecordingProxy;
      final store = EpisodeStore(
        database: database.raw,
        accountScopeDigest: account,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      );
      conversationMemory = appServices.put(
        ConversationMemoryService(
          database: database.raw,
          accountScopeDigest: account,
          memoryV2Mode: () => FeatureRolloutMode.enforce,
        ),
      );
      memoryWriter = appServices.put(
        MemoryWriteCoordinator(
          database: database.raw,
          episodeStore: store,
          accountScopeDigest: account,
          memoryV2Mode: () => FeatureRolloutMode.enforce,
          governedProjectionFamilies: [conversationMemory!],
        ),
      );
      conversationMemory!.bindGovernance(memoryWriter!);
      home.inputController.text = '以后别叫我宝';
      await home.send();
      expect(proxy.sourceText, '以后别叫我宝');
      expect(
        proxy.histories.single
            .where((message) => message['role'] == 'system')
            .any((message) => message['content']!.contains('"宝"')),
        isTrue,
      );
      expect(
        await MemoryGovernanceStores.governedProjectionHeads.count(
          database.raw,
        ),
        greaterThan(0),
      );
      expect(backend.memories, isEmpty);
      final messages = await database.getMessages('self');
      expect(messages.last.deliveryStatus, 'published');
      expect(messages.last.turnOrigin, 'user');
    },
  );

  test('plan wrapper does not hide a direct conversation boundary', () async {
    home.planRequested.value = true;
    home.inputController.text = '今天别开玩笑';
    await home.send();

    // The plan preamble selects the existing local action path. It must still
    // use the direct user sentence to recognize the current boundary.
    final request = backend.actionRequests.single;
    final system = request.singleWhere((message) => message.role == 'system');
    expect(
      system.content,
      contains(
        AgentPromptCatalog.text(
          'runtime.conversation_style.compact.boundary.no_teasing',
        ),
      ),
    );
    final user = request.singleWhere((message) => message.role == 'user');
    expect((jsonDecode(user.content) as Map)['user'], isNot('今天别开玩笑'));
    final messages = await database.getMessages('self');
    expect(messages.first.content, '今天别开玩笑');
  });

  test(
    'Home sends original text alongside the attached runtime plan wrapper',
    () async {
      await appServices.delete<HomeController>(force: true);
      await appServices.delete<AgentRuntimeRegistry>(force: true);
      final runtime = _RecordingRuntime();
      addTearDown(runtime.dispose);
      appServices.put<AgentRuntimeRegistry>(_AttachedRegistry(runtime));
      await database.saveAgentProfile(runtime.profile);
      home = appServices.put(HomeController());
      home.planRequested.value = true;
      home.inputController.text = '今天别开玩笑';
      await home.send();

      expect(runtime.requests, hasLength(1));
      expect(runtime.requests.single.currentUserText, '今天别开玩笑');
      expect(runtime.requests.single.text, isNot('今天别开玩笑'));
      expect(runtime.requests.single.text, contains('今天别开玩笑'));
      expect(backend.memories, isEmpty);
      final messages = await database.getMessages('self');
      expect(messages.first.content, '今天别开玩笑');
      expect(home.latestBubble.value, '收到。');
    },
  );

  test(
    'Home local action answers receive the same remembered boundary',
    () async {
      home.inputController.text = '以后别叫我宝';
      await home.send();
      expect(
        backend.memories.single!.conversationStyle!.forbiddenAddresses,
        contains('宝'),
      );

      home.inputController.text = '把买牛奶加到待办清单';
      await home.send();

      expect(backend.actionRequests, isNotEmpty);
      final messages = backend.actionRequests.single;
      final system = messages.singleWhere(
        (message) => message.role == 'system',
      );
      expect(system.content, contains('宝'));
      final user = messages.singleWhere((message) => message.role == 'user');
      final request = jsonDecode(user.content) as Map<String, dynamic>;
      expect(request['user'], '把买牛奶加到待办清单');
      expect(
        (request['skills'] as List).map((skill) => (skill as Map)['id']),
        contains('todo'),
      );
      expect(home.latestBubble.value, '我会遵守你的称呼偏好。');
      expect(backend.memories, hasLength(1));
    },
  );

  test('recreating Home drops its in-memory fallback boundaries', () async {
    home.inputController.text = '以后别叫我宝';
    await home.send();
    expect(
      backend.memories.single!.conversationStyle!.forbiddenAddresses,
      contains('宝'),
    );
    await appServices.delete<HomeController>(force: true);
    home = appServices.put(HomeController());
    home.inputController.text = '你好';
    await home.send();
    expect(
      backend.memories.last!.conversationStyle!.forbiddenAddresses,
      isEmpty,
    );
  });

  test(
    'account scope change clears fallback boundaries before generation',
    () async {
      home.inputController.text = '以后别叫我宝';
      await home.send();
      expect(
        backend.memories.single!.conversationStyle!.forbiddenAddresses,
        contains('宝'),
      );

      // Register after Home initialization so this specifically covers the
      // per-turn scope fence when no scope watcher was available at startup.
      appServices.put(SecureStorageService());
      appServices.put(AppEnvironmentService());
      final auth = appServices.put(AuthSessionService());
      auth.session.value = MaasoAuthSession(
        accountUuid: 'next-account',
        accessToken: 'test-token',
        refreshToken: 'test-refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      home.inputController.text = '你好';
      await home.send();
      expect(
        backend.memories.last!.conversationStyle!.forbiddenAddresses,
        isEmpty,
      );
    },
  );
}

class _IdleCore extends AgentCoreController {
  @override
  // Keep the profile absent so Home exercises its runtime-less fallback.
  // ignore: must_call_super
  void onInit() {}
}

class _RecordingLocalBackend implements LocalLLMBackend {
  final memories = <LocalMemoryContext?>[];
  final texts = <String>[];
  final actionRequests = <List<({String role, String content})>>[];

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
    texts.add(userText);
    memories.add(memory);
    yield const LocalChatDelta('[calm]收到。');
    yield const LocalChatDone('[calm]收到。');
  }

  @override
  Future<String?> agentAction(
    List<({String role, String content})> messages,
  ) async {
    actionRequests.add(messages);
    return '{"type":"finish","text":"我会遵守你的称呼偏好。"}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AttachedRegistry extends AgentRuntimeRegistry {
  _AttachedRegistry(this.runtime);
  final AgentRuntime runtime;

  @override
  AgentRuntime? get(String agentId) => agentId == 'self' ? runtime : null;

  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async => runtime;
}

class _RecordingRuntime extends AgentRuntime {
  _RecordingRuntime()
    : super(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const [],
          catchphrase: '',
        ),
        llmClient: _UnusedLlm(),
      );

  final requests = <({String text, String? currentUserText})>[];

  @override
  Future<ExecutionResult> chat(
    String text,
    List<Message> history, {
    TurnOrigin origin = TurnOrigin.user,
    String? currentUserText,
    StreamingAudioSink? liveAudioSink,
    String? expectedAppletScopeKey,
  }) async {
    requests.add((text: text, currentUserText: currentUserText));
    return ExecutionResult.success('收到。');
  }
}

class _UnusedLlm implements LLMClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingProxy extends LLMProxyService {
  final histories = <List<Map<String, String>>>[];
  String? sourceText;

  @override
  Future<String> chat(
    String prompt, {
    AppLocale? locale,
    List<Map<String, String>>? history,
  }) async {
    histories.add(List.of(history ?? []));
    sourceText =
        (await appServices
                .find<MemoryWriteCoordinator>()
                .currentPersistedUserSource())
            ?.text;
    return '收到。';
  }
}
