import 'dart:async';
import 'dart:convert';
import 'support/creator_task_fixtures.dart';
import 'support/source_workspace_fixtures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/presentation/applet_save_confirmation.dart';
import 'package:sembast/sembast_memory.dart';

class _Llm implements LLMClient {
  int calls = 0;
  final responses = workspaceFixtureResponses(game: false, title: 'Clock');
  @override
  Duration get defaultTimeout => const Duration(seconds: 2);
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    return responses.removeAt(0);
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnimplementedError();
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
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
  }) async* {
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode({'delta': await chat(messages)}),
    );
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('task did not reach expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentTaskJobStore store;
  late SurfaceRuntime surface;
  late AgentRuntime runtime;
  late _Llm llm;
  var saveConfirmations = 0;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => call.method == 'getLanguages'
              ? <String>['en-US']
              : call.method == 'getVoices'
              ? <Object>[]
              : 1,
        );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'task-preview-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put(database);
    store = appServices.put(
      await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(database),
        requirePreviewAcceptance: true,
      ).init(),
    );
    surface = appServices.put(SurfaceRuntime());
    saveConfirmations = 0;
    appServices.put<AppletSaveConfirmation>((_) async {
      saveConfirmations++;
      return true;
    });
    appServices.put<SurfaceWorkerFirstFrameWaiter>(
      const SurfaceWorkerTestFirstFrameWaiter(),
    );
    llm = _Llm();
    runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Hiyori',
        avatar: '',
        bio: 'test',
        personalityTraits: const ['warm'],
        catchphrase: 'ok',
      ),
      llmClient: llm,
    );
    await runtime.init();
  });
  tearDown(() async {
    await runtime.retireAndDrain();
    await store.deactivateAndDrain();
    await appServices.reset();
    await database.close();
  });

  test(
    'server task control does not fall through to an older local task or model',
    () async {
      final local = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: 'old local',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      final server = store.startServerImage(
        agentId: 'self',
        userText: 'image',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
        binding: taskBinding(),
      );
      final controls = _ServerControls();
      store.serverControls = controls;
      await runtime.chat('取消任务', const []);
      expect(controls.cancelled, server.id);
      expect(store.byId(local.id)!.status, AgentTaskJobStatus.running);
      expect(store.byId(server.id)!.status, AgentTaskJobStatus.running);
      expect(llm.calls, 0);
      expect(
        runtime.openBackgroundTaskPreview(server.id, expectedAttempt: 1),
        isFalse,
      );
      expect(
        runtime.retryBackgroundTaskJob(server.id, expectedAttempt: 1),
        isFalse,
      );
      await runtime.cancelBackgroundTaskJob(server.id, expectedAttempt: 1);
      expect(store.byId(server.id)!.status, AgentTaskJobStatus.running);
      await runtime.retireAndDrain();
      expect(store.byId(server.id)!.status, AgentTaskJobStatus.running);
    },
  );

  test(
    'a server image does not occupy the local generated-task retry slot',
    () async {
      final local = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '创建一个时钟小程序',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      store.fail(local.id, 'local interrupted');
      final server = store.startServerImage(
        agentId: 'self',
        userText: 'image',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
        binding: taskBinding(),
      );
      expect(
        runtime.retryBackgroundTaskJob(local.id, expectedAttempt: 1),
        isTrue,
      );
      await _until(
        () =>
            store
                .latestForTask(
                  local.taskId,
                  appletScopeKey: local.appletScopeKey,
                  agentId: 'self',
                )!
                .stage ==
            AgentTaskStage.previewReady,
      );
      expect(store.byId(server.id)!.status, AgentTaskJobStatus.running);
      expect(llm.calls, 4);
    },
  );

  test(
    'generation stays in its task until explicit preview, then keeps save boundary',
    () async {
      await runtime.chat('创建一个时钟小程序', const []);
      await _until(
        () =>
            store.latestForAgent('self')?.stage == AgentTaskStage.previewReady,
      );
      final job = store.latestForAgent('self')!;
      expect(surface.isVisible.value, isFalse);
      expect(saveConfirmations, 0);
      expect(await database.getAllWidgets(), isEmpty);
      expect(
        runtime.openBackgroundTaskPreview(job.id, expectedAttempt: 99),
        isFalse,
      );
      expect(
        runtime.openBackgroundTaskPreview(job.id, expectedAttempt: job.attempt),
        isTrue,
      );
      expect(
        runtime.openBackgroundTaskPreview(job.id, expectedAttempt: job.attempt),
        isFalse,
      );
      await _until(
        () => store.byId(job.id)?.status == AgentTaskJobStatus.completed,
      );
      await store.flush();
      expect(saveConfirmations, 1);
      final saved = (await database.getAllWidgets()).single;
      expect(saved.spec['taskJobId'], job.id);
      expect(store.byId(job.id)?.widgetId, saved.id);
      expect(
        (await database.getMessages(
          'self',
        )).where((m) => m.taskReference != null),
        hasLength(1),
      );
    },
  );

  test('cancel preview has no surface, widget, or save confirmation', () async {
    await runtime.chat('创建一个时钟小程序', const []);
    await _until(
      () => store.latestForAgent('self')?.stage == AgentTaskStage.previewReady,
    );
    final job = store.latestForAgent('self')!;
    await runtime.cancelBackgroundTaskJob(job.id, expectedAttempt: job.attempt);
    await _until(
      () => store.byId(job.id)?.status == AgentTaskJobStatus.cancelled,
    );
    expect(
      runtime.openBackgroundTaskPreview(job.id, expectedAttempt: job.attempt),
      isFalse,
    );
    expect(surface.isVisible.value, isFalse);
    expect(await database.getAllWidgets(), isEmpty);
    expect(saveConfirmations, 0);
  });

  test(
    'old attempt and foreign scope controls never touch a newer task',
    () async {
      final old = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '创建时钟小程序',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      store.fail(old.id, 'failed');
      final newer = store.retry(old.id);
      expect(
        runtime.retryBackgroundTaskJob(old.id, expectedAttempt: 1),
        isFalse,
      );
      await runtime.cancelBackgroundTaskJob(old.id, expectedAttempt: 1);
      expect(store.byId(newer.id)?.status, AgentTaskJobStatus.running);
      final foreign = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: 'foreign',
        appletScopeKey: 'other-account',
      );
      await runtime.cancelBackgroundTaskJob(foreign.id, expectedAttempt: 1);
      expect(store.byId(foreign.id)?.status, AgentTaskJobStatus.running);
      store.fail(foreign.id, 'failed');
      expect(
        runtime.retryBackgroundTaskJob(foreign.id, expectedAttempt: 1),
        isFalse,
      );
      expect(llm.calls, 0);
    },
  );

  test(
    'retry restored local request starts one new attempt without runtime chat',
    () async {
      final job = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '创建一个时钟小程序',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      store.fail(job.id, 'local_process_interrupted');
      expect(
        runtime.retryBackgroundTaskJob(job.id, expectedAttempt: 1),
        isTrue,
      );
      expect(
        runtime.retryBackgroundTaskJob(job.id, expectedAttempt: 1),
        isFalse,
      );
      final retry = store.latestForTask(
        job.id,
        appletScopeKey: job.appletScopeKey,
        agentId: 'self',
      )!;
      expect(retry.attempt, 2);
      expect(retry.taskId, job.id);
      await _until(
        () => store.byId(retry.id)?.stage == AgentTaskStage.previewReady,
      );
      expect(llm.calls, 4);
      expect(runtime.turn.isProcessing, isFalse);
      await runtime.cancelBackgroundTaskJob(retry.id, expectedAttempt: 2);
    },
  );
}

class _ServerControls implements AgentServerTaskControls {
  String? cancelled;
  @override
  bool canControl(AgentTaskJob job, {required bool retry}) => !retry;
  @override
  Future<bool> cancel(String jobId, {required int expectedAttempt}) async {
    cancelled = jobId;
    return true;
  }

  @override
  Future<bool> retry(String jobId, {required int expectedAttempt}) async =>
      false;
}
