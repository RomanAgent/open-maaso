import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_recall_safety_gate.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/working_memory.dart';
import 'package:maaso/src/core/services/world_kb_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/identity/application/companion_profile_service.dart';
import 'package:maaso/src/features/identity/data/companion_profile_store.dart';
import 'package:maaso/src/features/identity/domain/companion_profile.dart';
import 'package:sembast/sembast_memory.dart';

const _task = '[PLAN MODE] 先解释原因再列两个步骤：怎样把一段话写得更清楚';
const _privateCanaries = <String>[
  'L01_PRIVATE_CANARY',
  'L2_PRIVATE_CANARY',
  'PRESENCE_PRIVATE_CANARY',
  'MASTER_PRIVATE_NAME',
  'MASTER_PRIVATE_NOTES',
  'MASTER_PRIVATE_SUMMARY',
  'SOUL_PRIVATE_NAME',
  'SOUL_PRIVATE_NOTES',
  'WORLD_PRIVATE_CANARY',
  'PROFILE_PRIVATE_CANARY',
  'WORKING_PRIVATE_CANARY',
  'ENV_PRIVATE_CANARY',
  'SENSOR_PRIVATE_CANARY',
  'ROUTING_PRIVATE_CANARY',
  '"interests":["music","nature"]',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentRuntime runtime;
  late _CapturingLlm llm;
  late _CanaryMemoryBus memory;
  late _CanaryPresence presence;
  late MasterProfileService master;
  late WorkingMemory working;
  late TTSEngine? previousTts;

  Future<void> usePeer({String userId = 'self'}) async {
    await runtime.retireAndDrain();
    runtime = _runtime(llm, agentId: 'peer', userId: userId);
    await runtime.init(enabledSkillIds: const {});
  }

  _LocalBackend useLocal() {
    appServices.put(SecureStorageService());
    appServices.put(MaasoAgentModeService()).pipelineMode.value =
        AgentPipelineMode.localFull;
    appServices.put(LocalBrainService());
    final backend = _LocalBackend();
    appServices.put<LocalLLMBackend>(backend);
    return backend;
  }

  void expectPrivateStateUntouched(Map<String, Object?> before) {
    expect(memory.fullReads, 0);
    expect(memory.recallReads, 0);
    expect(memory.writes, 0);
    expect(presence.reads, 0);
    expect(working.snapshot(), before);
    expect(master.name.value, 'MASTER_PRIVATE_NAME');
    expect(master.notes.value, 'MASTER_PRIVATE_NOTES');
    expect(master.importantSummary.value, 'MASTER_PRIVATE_SUMMARY');
  }

  setUp(() async {
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'public-memory-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(database);
    appServices.put(AgentTaskJobStore());
    llm = _CapturingLlm();
    previousTts = TTSEngineRegistry.current;
    TTSEngineRegistry.current = _SilentEngine();
    runtime = _runtime(llm);
    await runtime.init(enabledSkillIds: const {});
    memory = _CanaryMemoryBus();
    appServices.put<MemoryBus>(memory);
    presence = _CanaryPresence();
    appServices.put<AgentPresenceService>(presence);
    master = appServices.put(MasterProfileService());
    master.name.value = 'MASTER_PRIVATE_NAME';
    master.notes.value = 'MASTER_PRIVATE_NOTES';
    master.importantSummary.value = 'MASTER_PRIVATE_SUMMARY';
    final soul = appServices.put(SoulService());
    soul.name.value = 'SOUL_PRIVATE_NAME';
    soul.age.value = 20;
    soul.gender.value = 'female';
    soul.notes.value = 'SOUL_PRIVATE_NOTES';
    appServices.put(WorldKBService()).notes.value = 'WORLD_PRIVATE_CANARY';
    working = appServices.put(WorkingMemory())
      ..currentUserInput = 'WORKING_PRIVATE_CANARY'
      ..latestEnvCueType = 'private_env'
      ..envCuePayload = {'value': 'ENV_PRIVATE_CANARY'}
      ..localBrainHint = 'ROUTING_PRIVATE_CANARY'
      ..sensorData = {'value': 'SENSOR_PRIVATE_CANARY'};
    await appServices
        .put(
          CompanionProfileService(
            gateway: _CompanionGateway(),
            store: _CompanionStore(),
            isCurrent: () => true,
          ),
        )
        .refresh();
  });

  tearDown(() async {
    await runtime.retireAndDrain().timeout(const Duration(seconds: 5));
    TTSEngineRegistry.current = previousTts;
    await database.close();
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  test('live Persona does not read or mutate account memory', () async {
    final before = working.snapshot();
    await runtime.chat(
      '我叫新的名字，聊聊今天吧',
      const [],
      origin: TurnOrigin.live,
      liveAudioSink: _SilentSink(),
    );
    expect(llm.streamCalls, hasLength(1));
    _expectNoPrivateContent(llm.calls.single);
    expectPrivateStateUntouched(before);
  });

  for (final owner in ['self', 'peer-owner']) {
    test('peer Persona is public even with profile owner $owner', () async {
      await usePeer(userId: owner);
      final before = working.snapshot();
      await runtime.chat('我叫新的名字，聊聊今天吧', const []);
      expect(llm.streamCalls, hasLength(1));
      _expectNoPrivateContent(llm.calls.single);
      expectPrivateStateUntouched(before);
    });
  }

  test('peer structured task does not read private prompt sections', () async {
    // Keeping profile.userId=self catches checks that trust only the profile
    // owner and forget that the runtime itself belongs to another Agent.
    await usePeer();
    final before = working.snapshot();
    await runtime.chat(_task, const []);
    expect(llm.structuredCalls, hasLength(1));
    expect(llm.streamCalls, isEmpty);
    _expectNoPrivateContent(llm.calls.single);
    expectPrivateStateUntouched(before);
  });

  test('private structured turn still receives allowed memory', () async {
    memory.rejectReads = false;
    presence.rejectReads = false;
    await runtime.chat(_task, const []);
    expect(llm.structuredCalls, hasLength(1));
    expect(memory.fullReads, 1);
    expect(memory.recallReads, 1);
    expect(presence.reads, 1);
    expect(memory.writes, 0);
    expect(working.currentUserInput, _task);
    final prompt = _allContent(llm.calls.single);
    for (final canary in [
      'L01_PRIVATE_CANARY',
      'L2_PRIVATE_CANARY',
      'PRESENCE_PRIVATE_CANARY',
      'MASTER_PRIVATE_NAME',
      'MASTER_PRIVATE_NOTES',
      'SOUL_PRIVATE_NAME',
      'SOUL_PRIVATE_NOTES',
      'WORLD_PRIVATE_CANARY',
      'PROFILE_PRIVATE_CANARY',
      '"interests":["music","nature"]',
    ]) {
      expect(prompt, contains(canary), reason: 'private control: $canary');
    }
  });

  test('cached private structured prompt cannot cross owner scope', () async {
    memory.rejectReads = false;
    presence.rejectReads = false;
    await runtime.chat(_task, const []);
    expect(llm.structuredCalls, hasLength(1));
    expect(_allContent(llm.calls.last), contains('MASTER_PRIVATE_NAME'));

    // updateProfile retains the same brain and prompt cache. The only change
    // is its owner, so the public turn must choose a separately scoped entry.
    runtime.updateProfile(runtime.profile.copyWith(userId: 'peer-owner'));
    memory.rejectReads = true;
    presence.rejectReads = true;
    memory.fullReads = 0;
    memory.recallReads = 0;
    presence.reads = 0;
    final before = working.snapshot();
    await runtime.chat(_task, const []);
    expect(llm.structuredCalls, hasLength(2));
    _expectNoPrivateContent(llm.calls.last);
    expectPrivateStateUntouched(before);

    runtime.updateProfile(runtime.profile.copyWith(userId: 'self'));
    memory.rejectReads = false;
    presence.rejectReads = false;
    await runtime.chat(_task, const []);
    expect(llm.structuredCalls, hasLength(3));
    expect(_allContent(llm.calls.last), contains('MASTER_PRIVATE_NAME'));
  });

  for (final live in [true, false]) {
    test(
      '${live ? 'live' : 'peer'} local fallback excludes Master data',
      () async {
        if (!live) await usePeer();
        final backend = useLocal();
        final before = working.snapshot();
        await runtime.chat(
          '我叫新的名字，聊聊今天吧',
          const [],
          origin: live ? TurnOrigin.live : TurnOrigin.user,
          liveAudioSink: live ? _SilentSink() : null,
        );
        expect(llm.calls, isEmpty);
        final context = backend.memories.single!;
        expect(context.conversationStyle!.isPrivate, isFalse);
        expect(context.userName, isNull);
        expect(context.importantSummary, isEmpty);
        expect(context.agentName, 'Maaso');
        expect(context.routingHint, isNull);
        expectPrivateStateUntouched(before);
      },
    );
  }

  test(
    'private local fallback still receives Master name and summary',
    () async {
      memory.rejectReads = false;
      presence.rejectReads = false;
      final backend = useLocal();
      await runtime.chat('聊聊今天吧', const []);
      expect(llm.calls, isEmpty);
      final context = backend.memories.single!;
      expect(context.conversationStyle!.isPrivate, isTrue);
      expect(context.userName, 'MASTER_PRIVATE_NAME');
      expect(context.importantSummary, contains('MASTER_PRIVATE_SUMMARY'));
      expect(memory.recallReads, 1);
      expect(memory.fullReads, 1);
    },
  );
}

AgentRuntime _runtime(
  _CapturingLlm llm, {
  String agentId = 'self',
  String userId = 'self',
}) => AgentRuntime(
  agentId: agentId,
  profile: AgentProfile(
    userId: userId,
    nickname: 'Maaso',
    avatar: '',
    bio: '',
    personalityTraits: const [],
    catchphrase: '',
    longTermMemory: 'PROFILE_PRIVATE_CANARY',
  ),
  llmClient: llm,
  conversationDeliveryMode: ConversationDeliveryMode.legacy,
  prepareTtsForNewTurn: (_) async {},
);

String _allContent(List<Message> messages) =>
    messages.map((message) => message.content).join('\n');

void _expectNoPrivateContent(List<Message> messages) {
  final prompt = _allContent(messages);
  for (final canary in _privateCanaries) {
    expect(prompt, isNot(contains(canary)), reason: 'private leak: $canary');
  }
}

class _CanaryMemoryBus extends MemoryBus {
  bool rejectReads = true;
  int fullReads = 0;
  int recallReads = 0;
  int writes = 0;

  @override
  String fullContextBlock(String query, {AppLocale? locale}) {
    fullReads++;
    if (rejectReads) throw StateError('Public turn read L0/L1');
    return 'L01_PRIVATE_CANARY';
  }

  @override
  Future<MemoryRecallResult> l2RecallResult(
    String query, {
    int k = 5,
    AppLocale? locale,
  }) async {
    recallReads++;
    if (rejectReads) throw StateError('Public turn read L2');
    return const MemoryRecallResult(
      status: MemoryRecallStatus.complete,
      promptBlock: 'L2_PRIVATE_CANARY',
      directCount: 1,
      entangledCount: 0,
      elapsed: Duration.zero,
    );
  }

  @override
  Future<MemoryWriteResult> writeEpisodeWithResult(Episode episode) async {
    writes++;
    throw StateError('Unexpected account memory write');
  }
}

class _CanaryPresence extends AgentPresenceService {
  bool rejectReads = true;
  int reads = 0;

  @override
  String conversationPromptContext({AppLocale? locale}) {
    reads++;
    if (rejectReads) throw StateError('Public turn read private presence');
    return 'PRESENCE_PRIVATE_CANARY';
  }
}

class _CapturingLlm extends LLMClient {
  final calls = <List<Message>>[];
  final structuredCalls = <List<Message>>[];
  final streamCalls = <List<Message>>[];

  @override
  Duration get defaultTimeout => const Duration(seconds: 2);
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls.add(List.of(messages));
    structuredCalls.add(List.of(messages));
    return '{"reply":"收到。","actions":[]}';
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
    streamCalls.add(List.of(messages));
    yield LLMStreamEvent(event: 'reply.delta', data: '{"delta":"收到。"}');
  }
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
    if (!frames.isClosed) await frames.close();
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    if (!frames.isClosed) await frames.close();
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

class _CompanionStore implements CompanionProfileStore {
  @override
  Future<CompanionProfile?> read() async => null;
  @override
  Future<void> write(CompanionProfile profile) async {}
}

class _CompanionGateway implements CompanionProfileGateway {
  @override
  String get requestContextKey => 'private-account';
  @override
  Future<CompanionProfile> fetch({required String expectedContextKey}) async =>
      CompanionProfile(
        version: 1,
        avatarPreset: 'orbit',
        agentGender: 'female',
        interests: ['music', 'nature'],
        onboardingVersion: 1,
      );
  @override
  Future<CompanionProfile> update({
    required String expectedContextKey,
    required CompanionProfile profile,
  }) async => profile;
}
