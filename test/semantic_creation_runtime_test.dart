import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/presentation/applet_save_confirmation.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/source_workspace_fixtures.dart';

class _Client extends LLMClient {
  final streams = <Stream<String>>[];
  final streamCalls = <List<Message>>[];
  final sourceCalls = <List<Message>>[];
  final sourceReplies = <Completer<String>>[];
  String? repairReply;
  int repairCalls = 0;

  void enqueue(String text) => streams.add(Stream.value(text));
  @override
  Duration get defaultTimeout => const Duration(seconds: 2);
  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    streamCalls.add(messages);
    await for (final fragment in streams.removeAt(0)) {
      yield LLMStreamEvent(
        event: 'reply.delta',
        data: jsonEncode({'delta': fragment}),
      );
    }
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    if (messages.first.content.contains(
      'Repair only the missing semantic decision',
    )) {
      repairCalls++;
      return Future.value(
        repairReply ?? '{"type":"creation.intent","mode":"none"}',
      );
    }
    sourceCalls.add(messages);
    final pending = Completer<String>();
    sourceReplies.add(pending);
    return pending.future;
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnimplementedError();
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnimplementedError();
  void releasePending() {
    for (final pending in sourceReplies) {
      if (!pending.isCompleted) pending.complete('{}');
    }
  }
}

String _envelope(String reply, Map<String, Object?> intent) => jsonEncode({
  'reply': reply,
  'actions': [
    {'type': 'creation.intent', ...intent},
  ],
});

Future<void> _wait(bool Function() predicate) async {
  for (var attempt = 0; attempt < 500 && !predicate(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late AgentRuntime runtime;
  late AgentTaskJobStore jobs;
  late DBService database;
  setUp(() async {
    await appServices.reset();
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'semantic-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(database);
    jobs = appServices.put(AgentTaskJobStore());
    appServices.put<AppletSaveConfirmation>((_) async => true);
    appServices.put<SurfaceWorkerFirstFrameWaiter>(
      const SurfaceWorkerTestFirstFrameWaiter(),
    );
    client = _Client();
    runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Maaso',
        avatar: '',
        bio: 'test',
        personalityTraits: const ['warm'],
        catchphrase: '',
      ),
      llmClient: client,
      semanticCreationEnabled: true,
      prepareTtsForNewTurn: (_) async {},
    );
  });
  tearDown(() async {
    client.releasePending();
    await runtime.retireAndDrain().timeout(const Duration(seconds: 5));
    await database.close();
    await appServices.reset();
  });

  for (final entry in const {'zh': '你好。', 'en': 'Hello.'}.entries) {
    test(
      'ordinary ${entry.key} text is visible before metadata and uses one call',
      () async {
        AppLocalization.updateLocale(
          entry.key == 'en'
              ? const Locale('en', 'US')
              : const Locale('zh', 'CN'),
        );
        final chunks = StreamController<String>();
        client.streams.add(chunks.stream);
        final visible = <String>[];
        final subscription = runtime.onLocalReplyDelta.listen(visible.add);
        addTearDown(subscription.cancel);
        final pending = AgentPromptCatalog.runWithLocale(
          entry.key == 'en' ? AppLocale.en : AppLocale.zh,
          () => runtime.chat(entry.value, const []),
        );
        await _wait(() => client.streamCalls.length == 1);
        expect(
          client.streamCalls.single.map((m) => m.content).join('\n'),
          contains(
            entry.key == 'en'
                ? 'current human message in any language'
                : '完整语义判断',
          ),
        );
        chunks.add('{"reply":"${entry.value}');
        await _wait(() => visible.join().contains(entry.value));
        expect(jobs.jobs, isEmpty);
        expect(client.repairCalls, 0);
        expect(client.sourceCalls, isEmpty);
        chunks.add('","actions":[{"type":"creation.intent","mode":"none"}]}');
        await chunks.close();
        final result = await pending;
        expect(result.stdout, entry.value);
        expect(visible.join(), entry.value);
        expect(client.streamCalls, hasLength(1));
      },
    );
  }

  test(
    'ordinary streaming preserves standalone spaces before intent metadata',
    () async {
      final chunks = StreamController<String>();
      client.streams.add(chunks.stream);
      final visible = <String>[];
      final subscription = runtime.onLocalReplyDelta.listen(visible.add);
      addTearDown(subscription.cancel);
      final pending = runtime.chat('Hello', const []);
      await _wait(() => client.streamCalls.length == 1);
      chunks.add('{"reply":"Hello.');
      await _wait(() => visible.join() == 'Hello.');
      expect(client.repairCalls, 0);
      expect(jobs.jobs, isEmpty);
      chunks.add(' ');
      chunks.add('world.');
      chunks.add(' ');
      chunks.add('How are you?');
      await _wait(() => visible.join() == 'Hello. world. How are you?');
      chunks.add('","actions":[{"type":"creation.intent","mode":"none"}]}');
      await chunks.close();
      final result = await pending;
      expect(result.stdout, 'Hello. world. How are you?');
      expect(client.streamCalls, hasLength(1));
      expect(client.sourceCalls, isEmpty);
      expect(client.repairCalls, 0);
    },
  );

  for (final entry in const {
    '你喜欢玩什么游戏，帮我做一个出来': 'game',
    '底下接住球，撞掉方块还能掉分裂道具，最好能动起来': 'game',
    'Can you pick something fun and make it for me?': 'game',
    '每天乱七八糟的花费，希望这里就能记下来按月份看': 'utility',
    'Somewhere I can log expenses and group them by month would help':
        'utility',
  }.entries) {
    test(
      'semantic model decision admits arbitrary request: ${entry.key}',
      () async {
        client.enqueue(
          _envelope('我来帮你整理这个想法。', {
            'mode': 'create',
            'kind': entry.value,
            'requirements': '完整保留玩法、控件、分页和用户想法。',
          }),
        );
        final result = await runtime.chat(entry.key, const []);
        expect(result.isSuccess, isTrue);
        await _wait(() => client.sourceCalls.length == 1);
        expect(client.streamCalls, hasLength(1));
        expect(client.repairCalls, 0);
        expect(jobs.jobs, hasLength(1));
        expect(jobs.jobs.single.userText, entry.key);
        expect(jobs.jobs.single.projectBrief, contains(entry.key));
        expect(
          client.sourceCalls.single.first.content,
          contains('finite file plan'),
        );
        expect(client.sourceCalls.single.last.content, contains(entry.key));
      },
    );
  }

  for (final acceptance in ['好', '行', '就这个', 'Looks good', 'You decide']) {
    test(
      'contextual confirmation is semantic, not a phrase allowlist: $acceptance',
      () async {
        client.enqueue(
          _envelope('可以试试一个收集光点改变重力的作品。', {
            'mode': 'propose',
            'kind': 'game',
            'requirements': '收集光点改变重力，支持暂停和多页面导航。',
          }),
        );
        await runtime.chat('有什么有趣的点子', const []);
        expect(jobs.jobs, isEmpty);
        final controller = StreamController<String>();
        client.streams.add(controller.stream);
        final pending = runtime.chat(acceptance, const []);
        await _wait(() => client.streamCalls.length == 2);
        final context = client.streamCalls.last
            .singleWhere(
              (m) =>
                  m.content.startsWith('Host-owned current creation context'),
            )
            .content;
        final data =
            jsonDecode(context.substring(context.indexOf('\n') + 1)) as Map;
        final id = (data['pendingProposal'] as Map)['id'];
        controller.add(
          _envelope('可以。', {
            'mode': 'confirm',
            'proposalId': id,
            'requirements': '标题叫“重力花园”。',
          }),
        );
        await controller.close();
        await pending;
        await _wait(() => client.sourceCalls.length == 1);
        expect(jobs.jobs, hasLength(1));
        expect(jobs.jobs.single.projectBrief, contains('收集光点改变重力'));
        expect(jobs.jobs.single.projectBrief, contains('重力花园'));
      },
    );
  }

  test('expired or fabricated proposal identity cannot create', () async {
    client.enqueue(
      _envelope('可以。', {'mode': 'confirm', 'proposalId': 'stale-proposal'}),
    );
    final result = await runtime.chat('好', const []);
    expect(jobs.jobs, isEmpty);
    expect(client.sourceCalls, isEmpty);
    expect(result.stdout, contains('提案'));
  });

  test('late creation data after Stop never creates a task', () async {
    final chunks = StreamController<String>();
    client.streams.add(chunks.stream);
    final pending = runtime.chat('你选一个好玩的做出来', const []);
    await _wait(() => client.streamCalls.length == 1);
    chunks.add('{"reply":"我先看看你的想法。');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await runtime.interruptConversation();
    chunks.add(
      '","actions":[{"type":"creation.intent","mode":"create","kind":"game","requirements":"完整互动作品"}]}',
    );
    await chunks.close();
    await pending;
    expect(jobs.jobs, isEmpty);
    expect(client.sourceCalls, isEmpty);
  });

  test(
    'missing semantic metadata is repaired without asking user to rewrite',
    () async {
      client.enqueue('{"reply":"我来帮你做。","actions":[]}');
      client.repairReply =
          '{"type":"creation.intent","mode":"create","kind":"game","requirements":"完整实现用户的互动想法。"}';
      await runtime.chat('想让这些方块能拖来拖去凑成图案', const []);
      await _wait(() => client.sourceCalls.length == 1);
      expect(client.repairCalls, 1);
      expect(jobs.jobs, hasLength(1));
    },
  );

  test(
    'native retry restores the admitted scope after an indirect confirmation',
    () async {
      await runtime.init();
      final original = jobs.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '好',
        projectBrief: '按确认的需求完整实现一个能操作的作品。',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      jobs.fail(original.id, 'test_interruption');
      expect(
        runtime.retryBackgroundTaskJob(original.id, expectedAttempt: 1),
        isTrue,
      );
      final responses = workspaceFixtureResponses(game: true);
      for (var index = 0; index < responses.length; index++) {
        await _wait(() => client.sourceReplies.length > index);
        client.sourceReplies[index].complete(responses[index]);
      }
      await _wait(
        () =>
            jobs.jobs.last.status == AgentTaskJobStatus.completed ||
            jobs.jobs.last.status == AgentTaskJobStatus.failed,
      );
      expect(
        jobs.jobs.last.status,
        AgentTaskJobStatus.completed,
        reason: jobs.jobs.last.error,
      );
      expect(jobs.jobs.last.userText, '好');
      expect(jobs.jobs.last.projectBrief, original.projectBrief);
    },
  );

  for (final invalid in [
    {'mode': 'invented'},
    {'mode': 'create', 'kind': 'game'},
  ]) {
    test('malformed metadata gets one repair: $invalid', () async {
      client.enqueue(_envelope('我来整理这个想法。', invalid));
      client.repairReply =
          '{"type":"creation.intent","mode":"create","kind":"utility","requirements":"完整实现自由拖动并归类物件的交互页面。"}';
      await runtime.chat('想把这些东西拖来拖去，按自己的方式归类', const []);
      await _wait(() => client.sourceCalls.length == 1);
      expect(client.repairCalls, 1);
      expect(client.streamCalls, hasLength(1));
      expect(jobs.jobs, hasLength(1));
      expect(jobs.jobs.single.projectBrief, contains('按自己的方式归类'));
    });
  }

  test(
    'unrepairable metadata cannot silently create or retry forever',
    () async {
      client.enqueue(_envelope('I can help with that.', {'mode': 'invented'}));
      client.repairReply = '{"type":"creation.intent","mode":"invented"}';
      final result = await runtime.chat(
        'Make something I can arrange myself',
        const [],
      );
      expect(result.isSuccess, isFalse);
      expect(client.repairCalls, 1);
      expect(client.streamCalls, hasLength(1));
      expect(client.sourceCalls, isEmpty);
      expect(jobs.jobs, isEmpty);
    },
  );

  test(
    'semantic status reads the actual task without starting source work',
    () async {
      final job = jobs.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '好',
        projectBrief: '已经确认的完整互动作品要求。',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      jobs.fail(job.id, 'test_interruption');
      client.enqueue(
        _envelope('我看看实际记录。', {'mode': 'status', 'taskId': job.id}),
      );
      final result = await runtime.chat('那个弄得怎么样啦', const []);
      expect(result.stdout, contains(jobs.statusText(jobs.byId(job.id)!)));
      expect(client.repairCalls, 0);
      expect(client.sourceCalls, isEmpty);
      expect(jobs.jobs, hasLength(1));
      expect(jobs.jobs.single.attempt, 1);
    },
  );

  test(
    'semantic retry uses the admitted brief and exact task identity',
    () async {
      final job = jobs.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '好',
        projectBrief: '完整保留原来的重力互动、暂停和二级页面。',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      jobs.fail(job.id, 'test_interruption');
      client.enqueue(_envelope('我继续写。', {'mode': 'retry', 'taskId': job.id}));
      final result = await runtime.chat(
        'Let’s have another go at that',
        const [],
      );
      expect(result.isSuccess, isTrue);
      await _wait(() => client.sourceCalls.length == 1);
      expect(jobs.jobs, hasLength(2));
      expect(jobs.jobs.last.id, isNot(job.id));
      expect(jobs.jobs.last.parentJobId, job.id);
      expect(jobs.jobs.last.attempt, 2);
      expect(jobs.jobs.last.projectBrief, job.projectBrief);
      expect(client.sourceCalls.single.last.content, contains('二级页面'));
      expect(client.repairCalls, 0);
    },
  );

  test(
    'natural missing metadata repair failure is bounded to one call',
    () async {
      await runtime.retireAndDrain();
      runtime = AgentRuntime(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: 'test',
          personalityTraits: const ['warm'],
          catchphrase: '',
        ),
        llmClient: client,
        semanticCreationEnabled: true,
        conversationDeliveryMode: ConversationDeliveryMode.text,
        prepareTtsForNewTurn: (_) async {},
      );
      client.enqueue(
        jsonEncode({
          'actions': [
            {
              'type': 'reply.utterance',
              'text': 'Let me think about that.',
              'after': 'finish',
            },
          ],
          'reply': 'Let me think about that.',
        }),
      );
      client.repairReply = '{"type":"creation.intent","mode":"invalid"}';
      final turn = runtime.submitConversation(
        'Make an interactive page for me',
        database: database,
        respondImmediately: true,
        onMessage: (_) {},
      );
      await turn.done;
      expect(client.repairCalls, 1);
      expect(client.streamCalls, hasLength(1));
      expect(client.sourceCalls, isEmpty);
      expect(jobs.jobs, isEmpty);
    },
  );

  test(
    'natural delivery publishes first unit before intent and uses queued receipt for terminal',
    () async {
      await runtime.retireAndDrain();
      runtime = AgentRuntime(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: 'test',
          personalityTraits: const ['warm'],
          catchphrase: '',
        ),
        llmClient: client,
        semanticCreationEnabled: true,
        conversationDeliveryMode: ConversationDeliveryMode.text,
        prepareTtsForNewTurn: (_) async {},
      );
      final chunks = StreamController<String>();
      client.streams.add(chunks.stream);
      final visible = <String>[];
      final turn = runtime.submitConversation(
        '让形状能拖动组合出图案',
        database: database,
        respondImmediately: true,
        onMessage: (message) {
          if (!message.isUserMessage) visible.add(message.content);
        },
      );
      await _wait(() => client.streamCalls.length == 1);
      chunks.add(
        '{"actions":[{"type":"reply.utterance","text":"我先理清你的想法。","after":"continue"},',
      );
      await _wait(() => visible.contains('我先理清你的想法。'));
      expect(jobs.jobs, isEmpty);
      expect(client.sourceCalls, isEmpty);
      chunks.add(
        '{"type":"reply.utterance","text":"我已经开始制作。","after":"finish"},{"type":"creation.intent","mode":"create","kind":"game","requirements":"拖动形状组合图案，可重置和进入下一页。"}],"reply":"我先理清你的想法。我已经开始制作。"}',
      );
      await chunks.close();
      await turn.done;
      expect(jobs.jobs, hasLength(1));
      expect(visible, isNot(contains('我已经开始制作。')));
      expect(visible.last, contains('写一个小游戏'));
      expect(client.streamCalls, hasLength(1));
    },
  );
}
