import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late _ControlledLlm llm;
  late AgentRuntime runtime;

  setUp(() async {
    await appServices.reset();
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          return switch (call.method) {
            'getLanguages' => <String>['zh-CN'],
            'getVoices' => <Object>[],
            'getCurrentPosition' => 0,
            _ => 1,
          };
        });
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'runtime-conversation-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(AgentTaskJobStore());
    appServices.put(ShortTermMemory());
    llm = _ControlledLlm();
    runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Tina',
        avatar: '',
        bio: 'test',
        personalityTraits: const ['warm'],
        catchphrase: 'ok',
      ),
      llmClient: llm,
      conversationDeliveryMode: ConversationDeliveryMode.text,
      prepareTtsForNewTurn: (_) async {},
    );
    await runtime.init(enabledSkillIds: const {});
  });

  tearDown(() async {
    llm.releaseCleanup();
    await runtime.retireAndDrain().timeout(const Duration(seconds: 4));
    await database.close();
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  test(
    'actual runtime makes one request and publishes three durable units',
    () async {
      final deltas = <String>[];
      final aggregates = <AgentReplyCompletedEvent>[];
      final deltaSub = runtime.onLocalReplyDelta.listen(deltas.add);
      final aggregateSub = EventBus().on<AgentReplyCompletedEvent>().listen(
        aggregates.add,
      );
      addTearDown(deltaSub.cancel);
      addTearDown(aggregateSub.cancel);
      final observed = <ChatMessage>[];
      final handle = runtime.submitConversation(
        '今天吃啥好呢',
        database: database,
        onMessage: observed.add,
      );
      await _waitUntil(() => llm.calls.length == 1);
      expect(
        llm.calls.single.map((m) => m.content).join(),
        contains('reply.utterance'),
      );
      final outputContract = llm.calls.single
          .map((message) => message.content)
          .singleWhere((content) => content.contains('Keep the top-level'));
      expect(
        outputContract,
        contains('Keep the top-level "actions" field before "reply"'),
      );
      final exactContractLine = outputContract
          .split('\n')
          .singleWhere((line) => line.startsWith('Return exactly '));
      expect(
        exactContractLine.indexOf('"actions"'),
        lessThan(exactContractLine.indexOf('"reply"')),
      );
      llm.respond(0, _mealReply);
      await _waitUntil(() => observed.any((m) => !m.isUserMessage));
      expect(runtime.isProcessing.value, isTrue);
      final result = await handle.done.timeout(const Duration(seconds: 6));
      final rows = await database.getMessages('self');
      expect(result.execution.isSuccess, isTrue);
      expect(rows.map((m) => m.content), [
        '今天吃啥好呢',
        '今天呀，嗯，我想想',
        '猪脚饭？',
        '或者看你想吃啥，我都行',
      ]);
      expect(rows.skip(1).map((m) => m.sequence), [0, 1, 2]);
      expect(rows.every((m) => m.turnId == handle.turnId), isTrue);
      expect(observed.map((m) => m.id), rows.map((m) => m.id));
      expect(llm.calls, hasLength(1));
      expect(deltas, isEmpty);
      expect(aggregates, isEmpty);
      expect(runtime.isProcessing.value, isFalse);
      final memory = appServices.find<ShortTermMemory>().toContextBlock();
      expect('猪脚饭？'.allMatches(memory), hasLength(1));
    },
  );

  test(
    'new input drops the optional tail and sees only delivered history',
    () async {
      final observed = <ChatMessage>[];
      final first = runtime.submitConversation(
        '今天吃啥好呢',
        database: database,
        onMessage: observed.add,
      );
      await _waitUntil(() => llm.calls.length == 1);
      llm.respond(0, _mealReply);
      await _waitUntil(
        () => observed.where((m) => !m.isUserMessage).length == 2,
      );
      final second = runtime.submitConversation('昨天吃过了', database: database);
      await _waitUntil(() => llm.calls.length == 2);
      final history = llm.calls[1].map((m) => m.content).join();
      expect(history, contains('猪脚饭？'));
      expect(history, isNot(contains('或者看你想吃啥，我都行')));
      expect((await first.done).cancelled, isTrue);
      expect(runtime.isProcessing.value, isTrue);
      llm.respond(1, '{"reply":"那今天吃面吧？🍜","actions":[]}');
      expect((await second.done).execution.stdout, '那今天吃面吧？');
      final rows = await database.getMessages('self');
      expect(rows.map((m) => m.content), [
        '今天吃啥好呢',
        '今天呀，嗯，我想想',
        '猪脚饭？',
        '昨天吃过了',
        '那今天吃面吧？',
      ]);
      expect(runtime.isProcessing.value, isFalse);
    },
  );

  test(
    'no-token Stop releases the turn while retirement drains transport cleanup',
    () async {
      llm.holdCleanup = true;
      final first = runtime.submitConversation('你觉得这样对吗', database: database);
      await _waitUntil(() => llm.calls.length == 1);
      await first.cancel().timeout(const Duration(seconds: 1));
      expect((await first.done).cancelled, isTrue);
      expect(runtime.isProcessing.value, isFalse);
      llm.holdCleanup = false;
      final second = runtime.submitConversation('我换个问题', database: database);
      await _waitUntil(() => llm.calls.length == 2);
      llm.respond(1, '{"reply":"你说，我在听。","actions":[]}');
      expect((await second.done).execution.stdout, '你说，我在听。');
      var drained = false;
      final drain = runtime.retireAndDrain().then((_) => drained = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(drained, isFalse);
      llm.releaseCleanup();
      await drain.timeout(const Duration(seconds: 1));
      final rows = await database.getMessages('self');
      expect(rows.map((m) => m.content), ['你觉得这样对吗', '我换个问题', '你说，我在听。']);
    },
  );

  test('invalid mixed actions are never published or executed', () async {
    final handle = runtime.submitConversation('今天吃什么', database: database);
    await _waitUntil(() => llm.calls.length == 1);
    llm.respond(
      0,
      '{"reply":"raw must not leak","actions":[{"type":"reply.utterance","text":"raw must not leak","after":"finish"},{"type":"skill.call","skill":"FreeformSurface","method":"show"}]}',
    );
    final result = await handle.done;
    expect(result.execution.isSuccess, isFalse);
    expect(result.publishedMessages, isEmpty);
    expect(
      (await database.getMessages('self')).every((m) => m.isUserMessage),
      isTrue,
    );
    expect(appServices.find<AgentTaskJobStore>().jobs, isEmpty);
    expect(llm.calls, hasLength(1));
  });

  test(
    'natural admission cannot turn synthetic origins into human authority',
    () async {
      expect(
        () => runtime.submitConversation(
          'hello',
          database: database,
          origin: TurnOrigin.proactivePresence,
        ),
        throwsArgumentError,
      );
      expect(llm.calls, isEmpty);
      expect(await database.getMessages('self'), isEmpty);
    },
  );
}

final _mealReply = jsonEncode({
  'reply': '今天呀，嗯，我想想猪脚饭？或者看你想吃啥，我都行',
  'actions': [
    {
      'type': 'reply.utterance',
      'text': '今天呀，嗯，我想想',
      'after': 'continue',
      'pause': 'brief',
    },
    {
      'type': 'reply.utterance',
      'text': '猪脚饭？',
      'after': 'optional',
      'pause': 'invite',
    },
    {'type': 'reply.utterance', 'text': '或者看你想吃啥，我都行', 'after': 'finish'},
  ],
});

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('runtime condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _ControlledLlm extends LLMClient {
  final calls = <List<Message>>[];
  final streams = <StreamController<LLMStreamEvent>>[];
  final cleanup = <Completer<void>>[];
  bool holdCleanup = false;
  @override
  Duration get defaultTimeout => const Duration(seconds: 15);
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('unexpected aggregate call');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected route call');
  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    calls.add(List.of(messages));
    final gate = holdCleanup ? Completer<void>() : null;
    if (gate != null) cleanup.add(gate);
    final stream = StreamController<LLMStreamEvent>(
      onCancel: () => gate?.future,
    );
    streams.add(stream);
    return stream.stream;
  }

  void respond(int index, String text) {
    streams[index].add(
      LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': text})),
    );
    streams[index].add(const LLMStreamEvent(event: 'done', data: '[DONE]'));
    unawaited(streams[index].close());
  }

  void releaseCleanup() {
    for (final gate in cleanup) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}
