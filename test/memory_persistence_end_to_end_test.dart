import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/embedding_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';
import 'package:maaso/src/core/services/memory_recall_safety_gate.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/working_memory.dart';
import 'package:maaso/src/core/services/world_kb_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/skills/memory_skill.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _scopeA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _scopeB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _now = DateTime.utc(2026, 9, 22, 12);
const _fact = 'I prefer oolong tea.';
const _synonymQuery =
    '[PLAN MODE] Explain beverage preference and suggest two options';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'maaso-memory-lifecycle-',
    );
    path = '${directory.path}/memory.db';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });
  tearDown(() async {
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
    await directory.delete(recursive: true);
  });

  test(
    'explicit remember survives file reopen and real semantic recall reaches the runtime prompt',
    () async {
      var h = await _DiskMemory.open(path);
      addTearDown(() => h.close());
      final receipt = await h.remember(
        source: 'Please remember: $_fact',
        fact: _fact,
      );
      expect(receipt['status'], 'success');
      expect(receipt['reviewState'], 'accepted');
      await h.store.waitForIdle();
      await h.close();
      expect(await File(path).length(), greaterThan(0));

      final timings = <String>[];
      h = await _DiskMemory.open(
        path,
        timings: timings,
        gateBudget: const Duration(seconds: 2),
      );
      addTearDown(h.close);
      final persisted = await h.store.recent();
      expect(persisted.single.what, _fact);
      expect(persisted.single.embedding, [1.0, 0.0]);
      // This composition test checks persistence, governed semantic retrieval,
      // and the actual runtime prompt. Its cold retrieval gets a semantic
      // budget; the independent deadline tests retain the production defaults.
      await h.store.prepareRecallIndex();
      final recalled = await h.bus.l2RecallResult(_synonymQuery);
      expect(recalled.status, MemoryRecallStatus.complete);
      expect(recalled.directCount, 1);
      expect(recalled.promptBlock, contains(_fact));
      final preparedRecall = _PreparedRecallBus(_synonymQuery, recalled);
      await appServices.delete<MemoryBus>(force: true);
      appServices.put<MemoryBus>(preparedRecall);
      final llm = _CapturingLlm();
      final oldTts = TTSEngineRegistry.current;
      TTSEngineRegistry.current = _SilentEngine();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: AgentProfile(
          userId: 'self',
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const [],
          catchphrase: '',
        ),
        llmClient: llm,
        conversationDeliveryMode: ConversationDeliveryMode.legacy,
        prepareTtsForNewTurn: (_) async {},
      );
      try {
        await runtime.init(enabledSkillIds: const {});
        await runtime.chat(_synonymQuery, const []);
        expect(preparedRecall.calls, 1);
        expect(identical(preparedRecall.delivered, recalled), isTrue);
        expect(llm.requests, 1);
        expect(llm.prompts, hasLength(1));
        final actualPrompt = llm.prompts.last;
        expect(actualPrompt, contains(MemoryRecallSafetyGate.beginMarker));
        expect(actualPrompt, contains(_fact));
        expect(actualPrompt, contains(MemoryRecallSafetyGate.endMarker));
      } finally {
        print('MEMORY_PERSISTENCE_TIMINGS ${timings.join(', ')}');
        await runtime.retireAndDrain();
        TTSEngineRegistry.current = oldTts;
      }
    },
  );

  test(
    'explicit save does not authorize an unrelated model proposal',
    () async {
      final h = await _DiskMemory.open(path);
      addTearDown(h.close);
      final receipt = await h.remember(
        source: 'Please remember: $_fact',
        fact: 'unrelated model paraphrase',
      );
      expect(receipt['status'], 'pending_review');
      expect(receipt['reason'], 'explicit_save_not_grounded');
      expect((await h.bus.l2RecallResult('paraphrase')).promptBlock, isEmpty);
    },
  );

  test(
    'an unprepared cold index cannot overrun the default recall deadline',
    () async {
      var h = await _DiskMemory.open(path);
      addTearDown(() => h.close());
      await h.remember(source: 'Please remember: $_fact', fact: _fact);
      await h.store.waitForIdle();
      await h.close();
      final entered = Completer<void>();
      final release = Completer<void>();
      h = await _DiskMemory.open(
        path,
        recallFault: (point) async {
          if (point == EpisodeRecallIndexFaultPoint.afterHighWatermark) {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
        },
      );
      final recalling = h.bus.l2RecallResult('beverage preference');
      await entered.future;
      try {
        final result = await recalling.timeout(
          const Duration(milliseconds: 100),
        );
        expect(result.status, MemoryRecallStatus.timedOut);
        expect(result.promptBlock, isEmpty);
      } finally {
        release.complete();
        await h.store.waitForIdle();
      }
      expect(
        (await h.bus.l2RecallResult('beverage preference')).promptBlock,
        contains(_fact),
      );
    },
  );

  test(
    'cold first synonym recall succeeds after restart with a fast provider',
    () async {
      var h = await _DiskMemory.open(path);
      addTearDown(() => h.close());
      await h.remember(source: 'Please remember: $_fact', fact: _fact);
      await h.store.waitForIdle();
      await h.close();
      h = await _DiskMemory.open(path);
      addTearDown(h.close);
      final first = await h.bus.l2RecallResult('beverage preference');
      expect(first.status, MemoryRecallStatus.complete);
      expect(first.promptBlock, contains(_fact));
      expect((await h.store.recent()).single.what, _fact);
      await h.store.waitForIdle();
      final later = await h.bus.l2RecallResult('beverage preference');
      expect(later.status, MemoryRecallStatus.complete);
      expect(later.promptBlock, contains(_fact));
    },
  );

  test(
    'pending survives restart without leaking, then owner acceptance becomes recallable',
    () async {
      var h = await _DiskMemory.open(path);
      addTearDown(() => h.close());
      final receipt = await h.remember(
        source: 'I chose oolong tea today.',
        fact: _fact,
      );
      expect(receipt['status'], 'pending_review');
      final id = receipt['episodeId'] as int;
      expect((await h.bus.l2RecallResult('oolong')).promptBlock, isEmpty);
      await h.close();
      h = await _DiskMemory.open(path);
      expect((await h.bus.l2RecallResult('oolong')).promptBlock, isEmpty);
      final accepted = await h.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.accept,
          targetEpisodeId: id,
          expectedHeadEpisodeId: id,
          expectedRevision: 1,
        ),
      );
      expect(accepted.status, MemoryGovernanceStatus.applied);
      expect(accepted.episode!.revision, 2);
      await h.close();
      h = await _DiskMemory.open(path);
      addTearDown(h.close);
      expect(
        (await h.bus.l2RecallResult('oolong')).promptBlock,
        contains(_fact),
      );
      expect(
        await h.store.isRecallEligible(
          Episode.fromJson(
            (await MemoryGovernanceStores.episodes.record(id).get(h.db.raw))!,
          ),
        ),
        isFalse,
      );
    },
  );

  test(
    'governed edits and forgetting persist and remove superseded prompt data',
    () async {
      var h = await _DiskMemory.open(path);
      addTearDown(() => h.close());
      final receipt = await h.remember(
        source: 'Please remember: $_fact',
        fact: _fact,
      );
      final id = receipt['episodeId'] as int;
      final edited = await h.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.edit,
          targetEpisodeId: id,
          expectedHeadEpisodeId: id,
          expectedRevision: 1,
          edit: const MemoryEpisodeEdit(what: 'I prefer jasmine tea.'),
        ),
      );
      expect(edited.status, MemoryGovernanceStatus.applied);
      await h.close();
      h = await _DiskMemory.open(path);
      expect(
        (await h.bus.l2RecallResult('jasmine')).promptBlock,
        contains('jasmine'),
      );
      expect(
        (await h.bus.l2RecallResult('oolong')).promptBlock,
        isNot(contains(_fact)),
      );
      final forgotten = await h.ledger.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: edited.episodeId!,
          expectedHeadEpisodeId: edited.episodeId!,
          expectedRevision: 2,
        ),
      );
      expect(forgotten.status, MemoryGovernanceStatus.applied);
      await h.close();
      h = await _DiskMemory.open(path);
      addTearDown(h.close);
      expect((await h.bus.l2RecallResult('tea')).promptBlock, isEmpty);
      expect(
        (await h.ledger.getDetail(
          forgotten.episodeId!,
        ))!.entry.episode.reviewState,
        EpisodeReviewState.tombstoned,
      );
    },
  );

  test('same persisted file cannot expose another account scope', () async {
    var h = await _DiskMemory.open(path);
    addTearDown(() => h.close());
    final receipt = await h.remember(
      source: 'Please remember: $_fact',
      fact: _fact,
    );
    await h.close();
    h = await _DiskMemory.open(path, scope: _scopeB);
    expect((await h.bus.l2RecallResult('oolong')).promptBlock, isEmpty);
    expect(await h.ledger.getDetail(receipt['episodeId'] as int), isNull);
    await h.close();
    h = await _DiskMemory.open(path);
    addTearDown(h.close);
    expect((await h.bus.l2RecallResult('oolong')).promptBlock, contains(_fact));
  });

  test(
    'logout drain waits for admitted commit and restart retains the completed write',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var blocked = false;
      var h = await _DiskMemory.open(
        path,
        fault: (point, _) async {
          if (point != MemoryWriteFaultPoint.beforeCommit || blocked) return;
          blocked = true;
          entered.complete();
          await release.future;
        },
      );
      final writing = h.remember(
        source: 'Please remember: $_fact',
        fact: _fact,
      );
      await entered.future;
      var drained = false;
      final drain = h.writer.deactivateAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      release.complete();
      expect((await writing)['status'], 'success');
      await drain;
      expect(h.writer.acceptsWrites, isFalse);
      await expectLater(
        h.writer.writeEpisode(Episode(when: _now, what: 'late')),
        throwsStateError,
      );
      await h.close();
      h = await _DiskMemory.open(path);
      addTearDown(h.close);
      expect(
        (await h.bus.l2RecallResult('oolong')).promptBlock,
        contains(_fact),
      );
    },
  );
}

class _DiskMemory {
  _DiskMemory(
    this.db,
    this.store,
    this.writer,
    this.gate,
    this.bus,
    this.ledger,
  );
  final DBService db;
  final EpisodeStore store;
  final MemoryWriteCoordinator writer;
  final MemoryRecallSafetyGate gate;
  final MemoryBus bus;
  final MemoryLedgerService ledger;
  bool _closed = false;

  static Future<_DiskMemory> open(
    String path, {
    String scope = _scopeA,
    MemoryWriteFaultInjector? fault,
    List<String>? timings,
    EpisodeRecallIndexFaultInjector? recallFault,
    Duration gateBudget = const Duration(milliseconds: 45),
  }) async {
    appServices.testMode = true;
    final db = await DBService().init(factory: databaseFactoryIo, path: path);
    appServices.put(db);
    final watch = Stopwatch()..start();
    void record(String phase) =>
        timings?.add('$phase=${watch.elapsedMicroseconds}us');
    appServices.put<EmbeddingService>(_SemanticFixture(record));
    final store = appServices.put<EpisodeStore>(
      _MeasuredEpisodeStore(
        database: db.raw,
        accountScopeDigest: scope,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
        clock: () => _now,
        record: record,
        recallFault: recallFault,
      ),
    );
    final writer = appServices.put(
      MemoryWriteCoordinator(
        database: db.raw,
        episodeStore: store,
        accountScopeDigest: scope,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
        clock: () => _now,
        linkEpisode: (_) async {},
        removeEpisodeLinks: (_) async {},
        projectMilestone: (_) async {},
        faultInjector: fault,
      ),
    );
    final gate = appServices.put(
      MemoryRecallSafetyGate(episodeStore: store, budget: gateBudget),
    );
    final bus = appServices.put(
      MemoryBus(
        memoryV2Mode: () => FeatureRolloutMode.enforce,
        recallSafetyGate: gate,
      ),
    );
    final ledger = MemoryLedgerService(
      database: db.raw,
      coordinator: writer,
      memoryBus: bus,
      accountScopeDigest: scope,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      clock: () => _now,
    );
    appServices.put(WorkingMemory());
    appServices.put(ShortTermMemory());
    appServices.put(SoulService());
    appServices.put(MasterProfileService());
    appServices.put(WorldKBService());
    appServices.put(AgentTaskJobStore());
    return _DiskMemory(db, store, writer, gate, bus, ledger);
  }

  Future<Map<String, dynamic>> remember({
    required String source,
    required String fact,
  }) async {
    final messageId = await MemoryGovernanceStores.chatMessages.add(
      db.raw,
      ChatMessage(
        sessionId: 'self',
        senderId: 'user',
        receiverId: 'self',
        content: source,
        timestamp: _now,
        isUserMessage: true,
        turnOrigin: ChatMessageTurnOrigins.user,
      ).toJson(),
    );
    return writer.runWithPersistedChatSource(
      messageRecordId: messageId,
      sessionId: 'self',
      agentId: 'self',
      operation: () async {
        final output = await MemorySkill().methods['remember']!([
          {'fact': fact},
        ]);
        return jsonDecode(output as String) as Map<String, dynamic>;
      },
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await gate.deactivateAndDrain();
    await ledger.deactivateAndDrain();
    await writer.deactivateAndDrain();
    await store.deactivateAndDrain();
    await db.close();
    await appServices.reset();
  }
}

/// Deterministic vectors exercise semantic lookup without claiming provider
/// retrieval quality, calling a model, or replacing persistence/governance.
class _SemanticFixture extends EmbeddingService {
  _SemanticFixture([this.record]);
  final void Function(String)? record;
  @override
  bool get isAvailable => true;
  @override
  Future<List<double>?> embed(String text) async {
    record?.call('embedding.ready');
    return const [1, 0];
  }
}

class _MeasuredEpisodeStore extends EpisodeStore {
  _MeasuredEpisodeStore({
    required super.database,
    required super.accountScopeDigest,
    required super.memoryV2Mode,
    required super.clock,
    required this.record,
    EpisodeRecallIndexFaultInjector? recallFault,
  }) : super(
         recallIndexFaultInjector: (point) async {
           record('index.${point.name}');
           await recallFault?.call(point);
         },
       );
  final void Function(String) record;
  @override
  Future<List<Episode>> search(String query, {int limit = 5}) async {
    record('search.start');
    try {
      return await super.search(query, limit: limit);
    } finally {
      record('search.end');
    }
  }

  @override
  Future<List<Episode>> searchForRecall(
    String query, {
    int limit = 5,
    required Duration semanticBudget,
  }) async {
    record('recall.start');
    try {
      return await super.searchForRecall(
        query,
        limit: limit,
        semanticBudget: semanticBudget,
      );
    } finally {
      record('recall.end');
    }
  }
}

/// Transfers the real gate result unchanged into a single runtime prompt.
/// It does not synthesize facts, skip the preceding governance/retrieval, or
/// assert that the runtime's default 50 ms deadline was met by cold disk I/O.
class _PreparedRecallBus extends MemoryBus {
  _PreparedRecallBus(this.query, this.result);
  final String query;
  final MemoryRecallResult result;
  int calls = 0;
  MemoryRecallResult? delivered;

  @override
  Future<MemoryRecallResult> l2RecallResult(
    String actualQuery, {
    int k = 5,
    AppLocale? locale,
  }) async {
    expect(actualQuery, query);
    calls++;
    delivered = result;
    return result;
  }
}

class _CapturingLlm extends LLMClient {
  final prompts = <String>[];
  int requests = 0;
  @override
  Duration get defaultTimeout => const Duration(seconds: 2);
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    requests++;
    return '{}';
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    requests++;
    prompts.add(messages.map((m) => m.content).join('\n'));
    return '{"reply":"Noted.","actions":[]}';
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
    requests++;
    prompts.add(messages.map((m) => m.content).join('\n'));
    yield LLMStreamEvent(event: 'reply.delta', data: '{"delta":"Noted."}');
  }
}

class _SilentEngine implements TTSEngine {
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
}
