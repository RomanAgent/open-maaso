import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/intent/freeform_creation_resolver.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';

import 'project_build_v2_delivery_test.dart' as delivery;

const _breakout =
    '生成一个底下有条杠，球会掉下来然后杠必须要接住，上面有很多小方块，'
    '球接触小方块小方块就会消失掉，全部小方块消失掉即可进入下一关，'
    '小方块消掉的时候会掉下道具，可以让球分裂开来';

class _ControlledLlm extends LLMClient {
  final calls = <List<Message>>[];
  final responses = <Completer<String>>[];
  bool closed = false;

  @override
  Duration get defaultTimeout => const Duration(seconds: 10);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    calls.add(List<Message>.unmodifiable(messages));
    final response = Completer<String>();
    responses.add(response);
    if (closed) response.complete('{}');
    return response.future;
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('Semantic resolution must retain message roles');

  void complete(int call, String text) => responses[call].complete(text);

  int get classificationCount => calls
      .where(
        (call) => call.first.content == FreeformCreationResolver.instruction,
      )
      .length;

  String requestAt(int call) =>
      (jsonDecode(calls[call].last.content) as Map)['request'] as String;

  void close() {
    closed = true;
    for (final response in responses) {
      if (!response.isCompleted) response.complete('{}');
    }
  }
}

class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}

MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'synthetic-$account',
  refreshToken: 'synthetic-refresh-$account',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

class _Fixture {
  _Fixture(this.harness);
  final delivery.Harness harness;
  final runtimes = <AgentRuntime>[];
  final llms = <_ControlledLlm>[];

  AgentRuntime runtime(_ControlledLlm llm) {
    llms.add(llm);
    final value = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Test companion',
        avatar: '',
        bio: 'Synthetic test agent',
        personalityTraits: const ['warm'],
        catchphrase: 'ok',
      ),
      llmClient: llm,
      prepareTtsForNewTurn: (_) async {},
    );
    runtimes.add(value);
    return value;
  }

  Future<void> close() async {
    for (final runtime in runtimes.reversed) {
      final drained = runtime.retireAndDrain();
      for (final llm in llms) {
        llm.close();
      }
      await drained.timeout(const Duration(seconds: 5));
    }
    await harness.close();
  }
}

Future<_Fixture> _fixture({bool enabled = true}) async {
  final harness = delivery.Harness(
    appletScope: AppletLocalOwnership.currentScopeKey(),
  );
  await harness.init(enabled: enabled);
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
      throw TimeoutException('Production runtime did not reach the boundary');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void _expectPlan(_ControlledLlm llm, int call, String request) {
  expect(
    llm.calls[call].first.content,
    isNot(FreeformCreationResolver.instruction),
  );
  expect(llm.calls[call].last.role, 'user');
  expect(
    llm.calls[call].last.content,
    contains(SurfaceCreationAuthority.normalizeRequest(request)),
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
    test(
      'actual ${origin.name} turn queues unnamed gameplay as a local game',
      () async {
        final f = await _fixture();
        final llm = _ControlledLlm();
        final runtime = f.runtime(llm);
        final answer = runtime.chat(_breakout, const [], origin: origin);
        await _waitFor(() => llm.calls.length == 1);
        expect(llm.requestAt(0), _breakout);
        expect(f.harness.jobs.jobs, isEmpty);
        llm.complete(0, '{"kind":"game"}');
        expect((await answer).isSuccess, isTrue);
        await _waitFor(() => llm.calls.length == 2);
        final job = f.harness.jobs.jobs.single;
        expect(job.taskKind, AgentTaskKind.gameGeneration);
        expect(job.userText, _breakout);
        expect(job.isServerBacked, isFalse);
        expect(job.status, AgentTaskJobStatus.running);
        expect(f.harness.posts, isEmpty);
        expect(llm.classificationCount, 1);
        _expectPlan(llm, 1, _breakout);
        expect(await f.harness.db.getAllWidgets(), isEmpty);
      },
    );
  }

  test(
    'actual unnamed utility turn uses the same local production path',
    () async {
      final f = await _fixture(enabled: false);
      const request = '做一个可以录入我每天的咖啡杯数并按颜色比较周趋势的工具';
      final llm = _ControlledLlm();
      final runtime = f.runtime(llm);
      final answer = runtime.chat(request, const []);
      await _waitFor(() => llm.calls.length == 1);
      expect(llm.requestAt(0), request);
      llm.complete(0, '{"kind":"utility"}');
      expect((await answer).isSuccess, isTrue);
      await _waitFor(() => llm.calls.length == 2);
      final job = f.harness.jobs.jobs.single;
      expect(job.taskKind, AgentTaskKind.surfaceGeneration);
      expect(job.userText, request);
      expect(job.isServerBacked, isFalse);
      expect(f.harness.posts, isEmpty);
      _expectPlan(llm, 1, request);
    },
  );

  test(
    'new freeform regeneration cannot retry an unrelated failed request',
    () async {
      final f = await _fixture();
      const old = '生成一个旧的点按计分小游戏';
      final previous = f.harness.jobs.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: old,
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      f.harness.jobs.fail(previous.id, 'synthetic old failure');
      const request = '重新生成一个飞船随我拖动、收集不同颜色星星并在碰撞后变形的作品';
      final llm = _ControlledLlm();
      final runtime = f.runtime(llm);
      final answer = runtime.chat(request, const []);
      await _waitFor(() => llm.calls.length == 1);
      llm.complete(0, '{"kind":"game"}');
      expect((await answer).isSuccess, isTrue);
      await _waitFor(() => llm.calls.length == 2);
      expect(f.harness.jobs.jobs, hasLength(2));
      final next = f.harness.jobs.jobs.last;
      expect(next.userText, SurfaceCreationAuthority.normalizeRequest(request));
      expect(next.parentJobId, isNull);
      expect(next.attempt, 1);
      expect(
        f.harness.jobs.byId(previous.id)!.status,
        AgentTaskJobStatus.failed,
      );
      expect(f.harness.jobs.byId(previous.id)!.userText, old);
      _expectPlan(llm, 1, request);
      expect(llm.calls[1].last.content, isNot(contains(old)));
    },
  );

  test('new freeform request retires a pending duplicate choice', () async {
    final f = await _fixture();
    const old = '生成一个旧的点按计分小游戏';
    final previous = f.harness.jobs.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: old,
      appletScopeKey: AppletLocalOwnership.currentScopeKey(),
    );
    f.harness.jobs.complete(previous.id, summary: 'synthetic installed task');
    final llm = _ControlledLlm();
    final runtime = f.runtime(llm);
    final duplicate = await runtime.chat(old, const []);
    expect(duplicate.stdout, contains('覆盖'));
    expect(llm.calls, isEmpty);
    const request = '重新生成一个按住屏幕可改变重力并让岛屿长出新道路的作品';
    final answer = runtime.chat(request, const []);
    await _waitFor(() => llm.calls.length == 1);
    llm.complete(0, '{"kind":"game"}');
    expect((await answer).isSuccess, isTrue);
    await _waitFor(() => llm.calls.length == 2);
    final next = f.harness.jobs.jobs.last;
    expect(next.userText, SurfaceCreationAuthority.normalizeRequest(request));
    expect(next.parentJobId, isNull);
    expect(
      f.harness.jobs.byId(previous.id)!.status,
      AgentTaskJobStatus.completed,
    );
    _expectPlan(llm, 1, request);
    expect(llm.calls[1].last.content, isNot(contains(old)));
  });

  test(
    'persisted exact task retry retains unnamed request without reclassification',
    () async {
      final f = await _fixture();
      final initialLlm = _ControlledLlm();
      final initial = f.runtime(initialLlm);
      final answer = initial.chat(_breakout, const []);
      await _waitFor(() => initialLlm.calls.length == 1);
      initialLlm.complete(0, '{"kind":"game"}');
      expect((await answer).isSuccess, isTrue);
      for (var call = 1; call <= 3; call++) {
        await _waitFor(() => initialLlm.calls.length > call);
        initialLlm.complete(call, 'not a valid source plan');
      }
      await _waitFor(
        () => f.harness.jobs.jobs.single.status == AgentTaskJobStatus.failed,
      );
      final previous = f.harness.jobs.jobs.single;
      expect(previous.userText, _breakout);
      await f.harness.jobs.flush();
      await initial.retireAndDrain();
      final restored = await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(f.harness.db),
      ).init();
      f.harness.jobs = restored;
      appServices.put<AgentTaskJobStore>(restored, overrideAbstract: true);
      expect(restored.byId(previous.id)!.userText, _breakout);
      final retryLlm = _ControlledLlm();
      final restarted = f.runtime(retryLlm);
      await restarted.init();
      expect(
        restarted.retryBackgroundTaskJob(
          previous.id,
          expectedAttempt: previous.attempt,
        ),
        isTrue,
      );
      await _waitFor(() => retryLlm.calls.length == 1);
      expect(retryLlm.classificationCount, 0);
      final retry = restored.jobs.last;
      expect(retry.parentJobId, previous.id);
      expect(retry.attempt, previous.attempt + 1);
      expect(retry.userText, _breakout);
      expect(retry.taskKind, AgentTaskKind.gameGeneration);
      _expectPlan(retryLlm, 0, _breakout);
      expect(f.harness.posts, isEmpty);
    },
  );

  test(
    'Stop during semantic resolution cannot queue a task after its late result',
    () async {
      final f = await _fixture();
      final llm = _ControlledLlm();
      final runtime = f.runtime(llm);
      final answer = runtime.chat(_breakout, const []);
      await _waitFor(() => llm.calls.length == 1);
      await runtime.interruptConversation();
      llm.complete(0, '{"kind":"game"}');
      await answer;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(f.harness.jobs.jobs, isEmpty);
      expect(llm.calls, hasLength(1));
      expect(f.harness.posts, isEmpty);
    },
  );

  test(
    'scope change during semantic resolution discards the old human task',
    () async {
      appServices.put<SecureStorageService>(_MemoryStorage());
      appServices.put(AppEnvironmentService());
      final auth = appServices.put(
        AuthSessionService(
          httpClient: MockClient(
            (_) async => throw StateError('No network in this test'),
          ),
        ),
      );
      auth.session.value = _session('owner-a');
      final f = await _fixture();
      final llm = _ControlledLlm();
      final runtime = f.runtime(llm);
      final answer = runtime.chat(_breakout, const []);
      await _waitFor(() => llm.calls.length == 1);
      auth.session.value = _session('owner-b');
      llm.complete(0, '{"kind":"game"}');
      await answer;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(f.harness.jobs.jobs, isEmpty);
      expect(llm.calls, hasLength(1));
      expect(f.harness.posts, isEmpty);
    },
  );

  test('late semantic result cannot take over a newer active turn', () async {
    final f = await _fixture();
    final llm = _ControlledLlm();
    final runtime = f.runtime(llm);
    final first = runtime.chat(_breakout, const []);
    await _waitFor(() => llm.calls.length == 1);
    await runtime.interruptConversation();
    final second = runtime.chat('今天和我聊聊天', const []);
    await _waitFor(() => llm.calls.length == 2);
    llm.complete(0, '{"kind":"game"}');
    await first;
    expect(f.harness.jobs.jobs, isEmpty);
    expect(runtime.isProcessing.value, isTrue);
    llm.complete(1, '好呀，我在听。');
    expect((await second).isSuccess, isTrue);
    expect(f.harness.jobs.jobs, isEmpty);
    expect(llm.calls, hasLength(2));
    expect(runtime.isProcessing.value, isFalse);
  });

  test(
    'semantic resolution binds current human text instead of augmented history',
    () async {
      final f = await _fixture();
      final llm = _ControlledLlm();
      final runtime = f.runtime(llm);
      final answer = runtime.chat(
        'Earlier context: make a weather dashboard.\nCurrent user: $_breakout',
        [Message.user('之前我只是在讨论小游戏的玩法。')],
        currentUserText: _breakout,
      );
      await _waitFor(() => llm.calls.length == 1);
      expect(llm.requestAt(0), _breakout);
      expect(llm.calls[0].last.content, isNot(contains('weather dashboard')));
      llm.complete(0, '{"kind":"game"}');
      expect((await answer).isSuccess, isTrue);
      await _waitFor(() => llm.calls.length == 2);
      expect(f.harness.jobs.jobs.single.userText, _breakout);
      expect(f.harness.jobs.jobs.single.taskKind, AgentTaskKind.gameGeneration);
    },
  );
}
