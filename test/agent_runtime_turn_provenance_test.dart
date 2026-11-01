import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/working_memory.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TTSEngine? previousTts;
  late bool previousSound;

  setUp(() {
    previousTts = TTSEngineRegistry.current;
    previousSound = MaasoTtsPlugin.soundEnabled.value;
    TTSEngineRegistry.current = _ProvenanceTtsEngine();
  });

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    for (final channel in <MethodChannel>[
      const MethodChannel('xyz.luan/audioplayers.global'),
      const MethodChannel('xyz.luan/audioplayers'),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
    }
  });

  tearDown(() {
    appServices.reset();
    TTSEngineRegistry.current = previousTts;
    MaasoTtsPlugin.soundEnabled.value = previousSound;
  });

  tearDownAll(() {
    for (final channel in <MethodChannel>[
      const MethodChannel('flutter_tts'),
      const MethodChannel('xyz.luan/audioplayers.global'),
      const MethodChannel('xyz.luan/audioplayers'),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  for (final origin in TurnOrigin.values) {
    test('${origin.name} provenance controls human evidence writes', () async {
      appServices.testMode = true;
      appServices.reset();
      appServices.put(SecureStorageService());
      final mode = appServices.put(MaasoAgentModeService());
      mode.pipelineMode.value = AgentPipelineMode.directCloud;

      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'turn-origin-${origin.name}.db',
      );
      appServices.put(database);
      final relationship = appServices.put(RelationshipService());
      await relationship.init(firstMetFallback: DateTime(2026, 1, 1));
      final working = appServices.put(WorkingMemory());
      final shortTerm = appServices.put(await ShortTermMemory().init());
      appServices.put(AgentTaskJobStore());

      final llm = _NoActionLlm();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
        prepareTtsForNewTurn: (_) async {},
      );
      addTearDown(runtime.dispose);
      addTearDown(database.close);

      MaasoTtsPlugin.soundEnabled.value = origin == TurnOrigin.live;
      final sink = _ProvenanceAudioSink();
      final result = origin == TurnOrigin.live
          ? await runtime.runGuardedVoiceChat(
              'origin-${origin.name}',
              const <Message>[],
              origin: TurnOrigin.live,
              liveAudioSink: sink,
              isCurrent: () => true,
            )
          : await runtime.chat(
              'origin-${origin.name}',
              const <Message>[],
              origin: origin,
            );

      expect(result.isSuccess, isTrue);
      if (origin == TurnOrigin.live) {
        expect(result.stdout, 'ok');
        expect(llm.toolCalls, 0);
        expect(sink.writes, isNotEmpty);
        expect(sink.starts, [(24000, 1)]);
        expect(sink.stops, [isTrue]);
      }
      expect(
        relationship.state.value?.lastActiveDate != null,
        origin.isHumanAuthored,
      );
      expect(
        shortTerm.turns.map((turn) => turn.content),
        origin.isHumanAuthored
            ? <String>['origin-${origin.name}', 'ok']
            : isEmpty,
      );
      expect(
        working.currentUserInput,
        origin.isHumanAuthored ? 'origin-${origin.name}' : isNull,
      );
    });
  }
}

AgentProfile _profile() => AgentProfile(
  nickname: 'Hiyori',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

class _NoActionLlm implements LLMClient {
  int toolCalls = 0;
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      '{"reply":"ok","actions":[]}';

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) {
    toolCalls++;
    throw UnsupportedError('not used');
  }

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
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"ok"}');
  }
}

class _ProvenanceTtsEngine implements FullDuplexTTSEngine {
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
  }) async => _ProvenanceTtsSession();
}

class _ProvenanceTtsSession implements TtsSession {
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

class _ProvenanceAudioSink implements StreamingAudioSink {
  final starts = <(int, int)>[];
  final writes = <Uint8List>[];
  final stops = <bool>[];

  @override
  Future<void> start({required int sampleRate, required int channels}) async =>
      starts.add((sampleRate, channels));

  @override
  Future<void> write(Uint8List pcmS16le) async => writes.add(pcmS16le);

  @override
  Future<void> stop({bool drain = true}) async => stops.add(drain);
}
