import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_recall_safety_gate.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/intent/freeform_creation_resolver.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';

import 'project_build_v2_delivery_test.dart' as delivery;

const _freeformRequest =
    '生成一个底下有条杠，球会掉下来然后杠必须接住，上方的方块碰到球就消失，'
    '消完进入下一关，方块掉落道具后可以让球分裂';

class _ControlledModel extends LLMClient {
  final calls = <List<Message>>[];
  final _responses = <Completer<String>>[];
  bool _closed = false;

  @override
  Duration get defaultTimeout => const Duration(seconds: 10);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    calls.add(List<Message>.unmodifiable(messages));
    final response = Completer<String>();
    _responses.add(response);
    if (_closed) response.complete('{}');
    return response.future;
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('Unexpected alternate request');

  int get classificationCount => calls
      .where(
        (call) => call.first.content == FreeformCreationResolver.instruction,
      )
      .length;

  String classifiedRequest(int call) =>
      (jsonDecode(calls[call].last.content) as Map)['request'] as String;

  void complete(int call, String response) =>
      _responses[call].complete(response);

  void fail(int call) => _responses[call].completeError(
    StateError('synthetic_provider_unavailable'),
  );

  void close() {
    _closed = true;
    for (final response in _responses) {
      if (!response.isCompleted) response.complete('{}');
    }
  }
}

class _Fixture {
  _Fixture(this.harness);

  final delivery.Harness harness;
  final models = <_ControlledModel>[];
  final runtimes = <AgentRuntime>[];

  AgentRuntime runtime(_ControlledModel model) {
    models.add(model);
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Synthetic companion',
        avatar: '',
        bio: 'Offline runtime boundary test',
        personalityTraits: const ['warm'],
        catchphrase: 'ok',
      ),
      llmClient: model,
      prepareTtsForNewTurn: (_) async {},
    );
    runtimes.add(runtime);
    return runtime;
  }

  Future<void> close() async {
    for (final runtime in runtimes.reversed) {
      final drained = runtime.retireAndDrain();
      for (final model in models) {
        model.close();
      }
      await drained.timeout(const Duration(seconds: 5));
    }
    await harness.close();
  }
}

Future<_Fixture> _fixture() async {
  final harness = delivery.Harness(
    appletScope: AppletLocalOwnership.currentScopeKey(),
  );
  await harness.init();
  appServices.put<DBService>(harness.db);
  appServices.put<AgentTaskJobStore>(harness.jobs);
  appServices.put<ProjectBuildV2Tasks>(harness.tasks);
  final fixture = _Fixture(harness);
  addTearDown(fixture.close);
  return fixture;
}

Future<void> _waitFor(bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      throw TimeoutException('Runtime boundary was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _DelayedRecall extends MemoryBus {
  final started = Completer<void>();
  final result = Completer<MemoryRecallResult>();

  @override
  Future<MemoryRecallResult> l2RecallResult(
    String query, {
    int k = 5,
    AppLocale? locale,
  }) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  @override
  String fullContextBlock(String query, {AppLocale? locale}) => '';

  @override
  String l3Block({AppLocale? locale}) => '';

  void settle() => result.complete(
    const MemoryRecallResult(
      status: MemoryRecallStatus.empty,
      promptBlock: '',
      directCount: 0,
      entangledCount: 0,
      elapsed: Duration.zero,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          if (call.method == 'getLanguages') return ['zh-CN', 'en-US'];
          if (call.method == 'getVoices') return <Object>[];
          return 1;
        });
  });
  tearDown(() async {
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  for (final origin in [TurnOrigin.user, TurnOrigin.voice]) {
    for (final raw in ['我只想聊天，不要制作任何作品', '翻译“生成一个打砖块小游戏”']) {
      test(
        '${origin.name} original text cannot gain authority from augmented commands: $raw',
        () async {
          final f = await _fixture();
          final model = _ControlledModel();
          final runtime = f.runtime(model);
          final answer = runtime.chat(
            '生成一个打砖块小游戏',
            [Message.assistant('我现在就开始给你写小游戏。')],
            currentUserText: raw,
            origin: origin,
          );
          await _waitFor(() => model.calls.length == 1);
          expect(model.classificationCount, 0);
          expect(model.calls.single.last.content, contains(raw));
          model.complete(
            0,
            '我按你的原话继续。<task_handoff>{"kind":"game","query":"打砖块","confidence":1.0}</task_handoff>',
          );
          expect((await answer).isSuccess, isTrue);
          expect(f.harness.jobs.jobs, isEmpty);
          expect(f.harness.posts, isEmpty);
          expect(model.calls, hasLength(1));
          expect(await f.harness.db.getAllWidgets(), isEmpty);
        },
      );
    }
  }

  for (final rejected in [
    'not valid classifier JSON',
    '{"kind":"unknown"}',
    '{"kind":"game","actions":[]}',
    '{"kind":"game","kind":"utility"}',
    'provider_failure',
  ]) {
    test(
      'failed classification cannot stream a persona creation promise: $rejected',
      () async {
        final f = await _fixture();
        final model = _ControlledModel();
        final runtime = f.runtime(model);
        final deltas = <String>[];
        final subscription = runtime.onLocalReplyDelta.listen(deltas.add);
        addTearDown(subscription.cancel);
        final answer = runtime.chat(_freeformRequest, const []);
        await _waitFor(() => model.calls.length == 1);
        expect(model.classifiedRequest(0), _freeformRequest);
        if (rejected == 'provider_failure') {
          model.fail(0);
        } else {
          model.complete(0, rejected);
        }
        final result = await answer;
        expect(result.isSuccess, isFalse);
        expect(
          result.stderr,
          anyOf(contains('代码还没有开始写'), contains('coding has not started')),
        );
        expect(
          result.stderr,
          anyOf(
            contains('不用补写“小游戏”或缩减内容'),
            contains('do not need to add “game” or reduce its content'),
          ),
        );
        expect(result.stdout, isEmpty);
        expect(deltas, isEmpty);
        expect(model.classificationCount, 1);
        expect(model.calls, hasLength(1));
        expect(f.harness.jobs.jobs, isEmpty);
        expect(f.harness.posts, isEmpty);
        expect(await f.harness.db.getAllWidgets(), isEmpty);
      },
    );
  }

  test(
    'Stop after classification fences task admission after recall',
    () async {
      final f = await _fixture();
      final recall = _DelayedRecall();
      appServices.put<MemoryBus>(recall);
      final model = _ControlledModel();
      final runtime = f.runtime(model);
      final answer = runtime.chat(_freeformRequest, const []);
      await _waitFor(() => model.calls.length == 1);
      model.complete(0, '{"kind":"game"}');
      await recall.started.future;
      await runtime.interruptConversation();
      recall.settle();
      expect((await answer).stdout, isEmpty);
      expect(f.harness.jobs.jobs, isEmpty);
      expect(f.harness.posts, isEmpty);
      expect(model.calls, hasLength(1));
      expect(runtime.isProcessing.value, isFalse);
      expect(await f.harness.db.getAllWidgets(), isEmpty);
    },
  );

  test('late recall cannot enqueue or release a newer current turn', () async {
    final f = await _fixture();
    final recall = _DelayedRecall();
    appServices.put<MemoryBus>(recall);
    final model = _ControlledModel();
    final runtime = f.runtime(model);
    final first = runtime.chat(_freeformRequest, const []);
    await _waitFor(() => model.calls.length == 1);
    model.complete(0, '{"kind":"game"}');
    await recall.started.future;
    await runtime.interruptConversation();
    final second = runtime.chat('今天和我聊聊天', const []);
    recall.settle();
    await _waitFor(() => model.calls.length == 2);
    expect((await first).stdout, isEmpty);
    expect(runtime.isProcessing.value, isTrue);
    expect(f.harness.jobs.jobs, isEmpty);
    model.complete(1, '好，我在听。');
    expect((await second).stdout, '好，我在听。');
    expect(runtime.isProcessing.value, isFalse);
    expect(model.classificationCount, 1);
    expect(model.calls, hasLength(2));
    expect(f.harness.posts, isEmpty);
  });

  test(
    'valid none classification keeps ordinary content conversation',
    () async {
      final f = await _fixture();
      final model = _ControlledModel();
      final runtime = f.runtime(model);
      const request = '做一段角色在月亮上漫步时的对白内容';
      expect(FreeformCreationResolver.needsResolution(request), isTrue);
      final answer = runtime.chat(request, const []);
      await _waitFor(() => model.calls.length == 1);
      expect(model.classifiedRequest(0), request);
      model.complete(0, '{"kind":"none"}');
      await _waitFor(() => model.calls.length == 2);
      model.complete(1, '月亮上的脚步很轻，今晚我们可以慢慢聊。');
      final result = await answer;
      expect(result.isSuccess, isTrue);
      expect(result.stdout, '月亮上的脚步很轻，今晚我们可以慢慢聊。');
      expect(model.classificationCount, 1);
      expect(model.calls, hasLength(2));
      expect(f.harness.jobs.jobs, isEmpty);
      expect(f.harness.posts, isEmpty);
      expect(await f.harness.db.getAllWidgets(), isEmpty);
    },
  );
}
