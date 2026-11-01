import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentRuntime runtime;
  late _CapturingLlm llm;
  late AgentTaskJobStore jobs;
  late TTSEngine? previousTts;
  late StreamSubscription<String> thoughtsSubscription;
  final thoughts = <String>[];

  setUp(() async {
    await appServices.reset();
    thoughts.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'routing-runtime-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(database);
    jobs = appServices.put(AgentTaskJobStore());
    previousTts = TTSEngineRegistry.current;
    TTSEngineRegistry.current = _SilentEngine();
    llm = _CapturingLlm();
    runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        userId: 'self',
        nickname: 'Maaso',
        avatar: '',
        bio: '',
        personalityTraits: const [],
        catchphrase: '',
        longTermMemory: '',
      ),
      llmClient: llm,
      conversationDeliveryMode: ConversationDeliveryMode.legacy,
      prepareTtsForNewTurn: (_) async {},
    );
    await runtime.init(enabledSkillIds: const {});
    thoughtsSubscription = runtime.onThinking.listen(thoughts.add);
  });

  tearDown(() async {
    await runtime.retireAndDrain().timeout(const Duration(seconds: 5));
    await thoughtsSubscription.cancel();
    TTSEngineRegistry.current = previousTts;
    await database.close();
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  for (final text in [
    'Explain what the word weather means',
    '别查天气，只解释气压的定义',
    '剧本里这句“连接蓝牙并发送照片”听起来像命令吗',
  ]) {
    test(
      'non-action prompt and acknowledgement agree with grant: $text',
      () async {
        final result = await runtime.chat(text, const []);
        expect(result.isSuccess, isTrue);
        expect(llm.calls, hasLength(1));
        final userMessages = llm.calls.single
            .where((message) => message.role == 'user')
            .map((message) => message.content)
            .join('\n');
        expect(
          userMessages,
          contains(text),
          reason: 'original text stays intact',
        );
        for (final locale in [AppLocale.en, AppLocale.zh]) {
          expect(
            userMessages,
            isNot(
              contains(
                AgentPromptCatalog.text(
                  'runtime.policy.search',
                  locale: locale,
                ),
              ),
            ),
          );
        }
        expect(userMessages, isNot(contains('tracks=expression,voice,skill')));
        expect(thoughts, isEmpty, reason: 'no promise to search or generate');
        expect(jobs.jobs, isEmpty);
      },
    );
  }

  test(
    'search policy does not announce execution while the tool is disabled',
    () async {
      await runtime.chat('Search for the latest space mission news', const []);
      expect(llm.calls, hasLength(1));
      final content = llm.calls.single
          .map((message) => message.content)
          .join('\n');
      expect(
        content,
        contains(AgentPromptCatalog.text('runtime.policy.search')),
      );
      expect(thoughts, isEmpty);
    },
  );

  test('non-action explanation cannot accept a model task handoff', () async {
    llm.handoff = true;
    await runtime.chat(
      'Explain what the phrase “generate a game” means',
      const [],
    );
    expect(llm.calls, hasLength(1));
    expect(jobs.jobs, isEmpty);
    expect(thoughts, isEmpty);
  });

  test('fixture exposes the old weather policy mismatch', () {
    final raw = TurnPolicyEngine(agentId: 'self').decide(
      TurnContext(
        userText: 'Explain what the word weather means',
        routing: null,
        hasOpenSurface: false,
        online: true,
        cloudAvailable: true,
        autoPlanEnabled: false,
        nativeToolsEnabled: false,
        brainHasNativeTools: false,
        forcedPlan: false,
      ),
    );
    expect(raw.shouldSearch, isTrue);
    expect(raw.acknowledgement, isNotNull);
  });
}

class _CapturingLlm extends LLMClient {
  final calls = <List<Message>>[];
  bool handoff = false;
  @override
  Duration get defaultTimeout => const Duration(seconds: 2);
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls.add(List.of(messages));
    return '{"reply":"这是词语解释。","actions":[]}';
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
    if (handoff) {
      yield const LLMStreamEvent(
        event: 'task.handoff',
        data: '{"kind":"game","query":"maze","confidence":1}',
      );
    }
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode({'delta': '这是词语解释。'}),
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
    if (!frames.isClosed) await frames.close();
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    if (!frames.isClosed) await frames.close();
  }
}
