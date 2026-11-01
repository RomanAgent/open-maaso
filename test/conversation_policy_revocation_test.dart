import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/services/conversation_memory_service.dart';
import 'package:maaso/src/core/services/conversation_preference_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  late ConversationMemoryService memory;
  late MemoryWriteCoordinator writer;
  late AgentRuntime runtime;
  late _HeldLlm llm;
  late ConversationPreferenceService preferences;
  MemoryWriteFaultInjector? sourceFault;

  setUp(() async {
    await appServices.reset();
    sourceFault = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'revocation-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(db);
    appServices.put(AgentTaskJobStore());
    const account =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    preferences = appServices.put(
      await ConversationPreferenceService(
        store: SembastConversationPreferenceStore(
          db,
          accountScopeDigest: account,
        ),
        accountScopeDigest: account,
      ).init(),
    );
    memory = appServices.put(
      ConversationMemoryService(
        database: db.raw,
        accountScopeDigest: account,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      ),
    );
    writer = appServices.put(
      MemoryWriteCoordinator(
        database: db.raw,
        episodeStore: EpisodeStore(
          database: db.raw,
          accountScopeDigest: account,
          memoryV2Mode: () => FeatureRolloutMode.enforce,
        ),
        accountScopeDigest: account,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
        governedProjectionFamilies: [memory],
        faultInjector: (point, operation) async =>
            sourceFault?.call(point, operation),
      ),
    );
    memory.bindGovernance(writer);
    llm = _HeldLlm();
    runtime = AgentRuntime(
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
      conversationDeliveryMode: ConversationDeliveryMode.text,
      prepareTtsForNewTurn: (_) async {},
    );
    await runtime.init(enabledSkillIds: const {});
  });

  tearDown(() async {
    for (final stream in llm.streams) {
      unawaited(stream.close());
    }
    await runtime.retireAndDrain().timeout(const Duration(seconds: 5));
    await memory.deactivateAndDrain();
    await writer.deactivateAndDrain();
    await preferences.deactivateAndDrain();
    await db.close();
    await appServices.reset();
  });

  test(
    'settings revision revokes waiting output and the next turn uses the new choice',
    () async {
      final old = runtime.submitConversation(
        '聊聊今天',
        database: db,
        respondImmediately: true,
      );
      await _until(() => llm.calls.length == 1);
      await preferences.setPreferredAddress('阿舟');
      final result = await old.done.timeout(const Duration(seconds: 3));
      expect(result.execution.stdout, isEmpty);
      expect(runtime.canPublishConversationReply('旧回答'), isFalse);
      final next = runtime.submitConversation(
        '接着聊',
        database: db,
        respondImmediately: true,
      );
      await _until(() => llm.calls.length == 2);
      expect(llm.calls.last.map((m) => m.content).join(), contains('阿舟'));
      llm.reply(1, ['收到。']);
      expect((await next.done).execution.stdout, '收到。');
      expect(memory.facts, isEmpty);
    },
  );

  test(
    'a source deleted during preparation is never sent to the model',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      sourceFault = (point, _) async {
        if (point != MemoryWriteFaultPoint.afterCommit || entered.isCompleted) {
          return;
        }
        entered.complete();
        await release.future;
      };
      final turn = runtime.submitConversation(
        '以后别叫我宝',
        database: db,
        respondImmediately: true,
      );
      await entered.future.timeout(const Duration(seconds: 3));
      final source = (await db.getMessages('self')).single;
      await MemoryGovernanceStores.chatMessages
          .record(source.id!)
          .delete(db.raw);
      release.complete();
      expect((await turn.done).execution.stdout, isEmpty);
      expect(llm.calls, isEmpty);
    },
  );

  test(
    'settings edited during preparation supersede the earlier message',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      sourceFault = (point, _) async {
        if (point != MemoryWriteFaultPoint.afterCommit || entered.isCompleted) {
          return;
        }
        entered.complete();
        await release.future;
      };
      final turn = runtime.submitConversation(
        '以后叫我阿舟',
        database: db,
        respondImmediately: true,
      );
      await entered.future.timeout(const Duration(seconds: 3));
      await preferences.setPreferredAddress('小林');
      release.complete();
      expect((await turn.done).execution.stdout, isEmpty);
      expect(llm.calls, isEmpty);
    },
  );

  test(
    'one generation sees two constraints while original sources stay separate',
    () async {
      final first = runtime.submitConversation('这次别开玩笑', database: db);
      final second = runtime.submitConversation(
        '以后叫我阿舟',
        database: db,
        respondImmediately: true,
      );
      await _until(() => llm.calls.length == 1);
      final prompt = llm.calls.single
          .where((m) => m.role == 'system')
          .map((m) => m.content)
          .join('\n');
      expect(prompt, contains('阿舟'));
      expect(prompt, contains('do not joke, tease, or use memes'));
      llm.reply(0, ['收到。']);
      await first.done;
      await second.done;
      final users = (await db.getMessages(
        'self',
      )).where((m) => m.isUserMessage).toList();
      expect(users.map((m) => m.content), ['这次别开玩笑', '以后叫我阿舟']);
      expect(users.map((m) => m.id).toSet(), hasLength(2));
      expect(llm.calls, hasLength(1));
    },
  );

  test(
    'deleting a source cancels a waiting generation before any publication',
    () async {
      final turn = runtime.submitConversation(
        '以后别叫我宝',
        database: db,
        respondImmediately: true,
      );
      await _until(() => llm.calls.length == 1);
      final source = (await db.getMessages('self')).single;
      await MemoryGovernanceStores.chatMessages
          .record(source.id!)
          .delete(db.raw);
      final result = await turn.done.timeout(const Duration(seconds: 3));
      expect(result.execution.stdout, isEmpty);
      expect(runtime.canPublishConversationReply('旧回答。'), isFalse);
      expect(
        (await db.getMessages('self')).where((m) => !m.isUserMessage),
        isEmpty,
      );
    },
  );

  test(
    'contact mute or topic closure promptly revokes a waiting scheduling confirmation',
    () async {
      final proactive = appServices.put(
        await ProactivePreferenceService(
          store: SembastProactivePreferenceStore(
            db,
            accountScopeDigest: 'a' * 64,
          ),
          accountScopeDigest: 'a' * 64,
          generation: 1,
        ).init(),
      );
      addTearDown(proactive.deactivateAndDrain);
      final published = <String>[];
      for (final closeTopic in [false, true]) {
        final callIndex = llm.calls.length;
        final turn = runtime.submitConversation(
          '明天15点问我面试结果',
          onMessage: (message) {
            if (!message.isUserMessage) published.add(message.content);
          },
          database: db,
          respondImmediately: true,
        );
        await _until(() => llm.calls.length == callIndex + 1);
        expect(
          llm.calls.last
              .where((message) => message.role == 'system')
              .map((message) => message.content)
              .join('\n'),
          contains(ProactiveContactObservation.scheduled.replyGuidance!),
        );
        final topic = proactive.effectiveSnapshot.topics.singleWhere(
          (topic) => topic.status == ProactiveTopicStatus.open,
        );
        if (closeTopic) {
          await proactive.closeConversationTopic(topic.id);
        } else {
          await proactive.setHardMuted(true);
        }
        // The stream remains held: cancellation must finish without waiting
        // for the model's ordinary timeout or a later response token.
        final result = await turn.done.timeout(const Duration(seconds: 3));
        expect(result.execution.stdout, isEmpty);
        expect(runtime.canPublishConversationReply('明天15点已经安排好了。'), isFalse);
        expect(published, isEmpty);
        llm.reply(callIndex, ['明天15点已经安排好了。']);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(published, isEmpty);
        expect(
          (await db.getMessages(
            'self',
          )).where((message) => !message.isUserMessage),
          isEmpty,
        );
      }
    },
  );

  test(
    'proactive setting changes do not cancel ordinary chat without contact guidance',
    () async {
      final proactive = appServices.put(
        await ProactivePreferenceService(
          store: SembastProactivePreferenceStore(
            db,
            accountScopeDigest: 'a' * 64,
          ),
          accountScopeDigest: 'a' * 64,
          generation: 1,
        ).init(),
      );
      addTearDown(proactive.deactivateAndDrain);
      final turn = runtime.submitConversation(
        '聊聊今天的晚饭',
        database: db,
        respondImmediately: true,
      );
      var completed = false;
      unawaited(turn.done.then((_) => completed = true));
      await _until(() => llm.calls.length == 1);
      expect(proactive.effectiveSnapshot.topics, isEmpty);
      expect(
        llm.calls.single.map((message) => message.content).join('\n'),
        isNot(contains(ProactiveContactObservation.scheduled.replyGuidance!)),
      );
      await proactive.setContactAgreement(
        enabled: true,
        scope: ProactiveConversationScope.everyday,
      );
      await proactive.setHardMuted(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      llm.reply(0, ['我投番茄炒蛋一票。']);
      final result = await turn.done.timeout(const Duration(seconds: 3));
      expect(result.execution.stdout, '我投番茄炒蛋一票。');
      expect(
        (await db.getMessages('self'))
            .where((message) => !message.isUserMessage)
            .map((message) => message.content),
        ['我投番茄炒蛋一票。'],
      );
    },
  );

  test(
    'natural publication retains displayed prefix when forbidden suffix arrives',
    () async {
      var displayed = false;
      final turn = runtime.submitConversation(
        '别叫我宝',
        onMessage: (m) {
          if (!m.isUserMessage) displayed = true;
        },
        database: db,
        respondImmediately: true,
      );
      await _until(() => llm.calls.length == 1);
      llm.beginReply(0, '收到。');
      await _until(() => displayed);
      llm.endReply(0, '收到。', '宝，继续？');
      final result = await turn.done.timeout(const Duration(seconds: 4));
      expect(result.execution.stdout, '收到。');
      expect(
        (await db.getMessages(
          'self',
        )).where((m) => !m.isUserMessage).map((m) => m.content),
        ['收到。'],
      );
    },
  );
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('model did not start');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _HeldLlm extends LLMClient implements PresentationStreamingLLMClient {
  final calls = <List<Message>>[];
  final streams = <StreamController<LLMStreamEvent>>[];
  @override
  Duration get defaultTimeout => const Duration(seconds: 5);
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      '{"reply":"收到。","actions":[]}';
  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    calls.add(List.of(messages));
    final stream = StreamController<LLMStreamEvent>();
    streams.add(stream);
    return stream.stream;
  }

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => streamChatEvents(messages, timeout: timeout);

  void beginReply(int index, String line) {
    final action = {
      'type': 'reply.utterance',
      'text': line,
      'after': 'continue',
    };
    streams[index].add(
      LLMStreamEvent(
        event: 'reply.delta',
        data: jsonEncode({'delta': '{"actions":[${jsonEncode(action)}'}),
      ),
    );
    streams[index].add(
      LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action)),
    );
  }

  void endReply(int index, String first, String last) {
    final action = {'type': 'reply.utterance', 'text': last, 'after': 'finish'};
    streams[index].add(
      LLMStreamEvent(
        event: 'reply.delta',
        data: jsonEncode({
          'delta':
              ',${jsonEncode(action)}],"reply":${jsonEncode('$first\n$last')}}',
        }),
      ),
    );
    streams[index].add(
      LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action)),
    );
    streams[index].add(const LLMStreamEvent(event: 'done', data: '[DONE]'));
    unawaited(streams[index].close());
  }

  void reply(int index, List<String> lines) {
    final raw = jsonEncode({
      'actions': [
        for (var i = 0; i < lines.length; i++)
          {
            'type': 'reply.utterance',
            'text': lines[i],
            'after': i == lines.length - 1 ? 'finish' : 'continue',
          },
      ],
      'reply': lines.join('\n'),
    });
    streams[index].add(
      LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': raw})),
    );
    for (var i = 0; i < lines.length; i++) {
      streams[index].add(
        LLMStreamEvent(
          event: 'reply.utterance',
          data: jsonEncode({
            'type': 'reply.utterance',
            'text': lines[i],
            'after': i == lines.length - 1 ? 'finish' : 'continue',
          }),
        ),
      );
    }
    streams[index].add(const LLMStreamEvent(event: 'done', data: '[DONE]'));
    unawaited(streams[index].close());
  }
}
