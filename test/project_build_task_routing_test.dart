import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_task_binding.dart';
import 'package:sembast/sembast_memory.dart';
import 'support/project_build_fixtures.dart';

class _NoModel implements LLMClient {
  int calls = 0;
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Cloud task control must not invoke a model');
  }
}

class _Controls implements AgentServerTaskControls {
  final calls = <String>[];
  bool enabled = true;
  @override
  bool canControl(AgentTaskJob job, {required bool retry}) => enabled;
  @override
  Future<bool> cancel(String jobId, {required int expectedAttempt}) async {
    calls.add('cancel:$jobId:$expectedAttempt');
    return true;
  }

  @override
  Future<bool> retry(String jobId, {required int expectedAttempt}) async {
    calls.add('retry:$jobId:$expectedAttempt');
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentTaskJobStore store;
  late _Controls images;
  late _Controls projects;
  late AgentTaskJob job;
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
    database = appServices.put(
      await DBService().init(
        factory: databaseFactoryMemory,
        path: 'project-routing-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    store = appServices.put(AgentTaskJobStore());
    images = _Controls();
    projects = _Controls();
    store.serverControls = images;
    store.registerControls(AgentTaskExecutionKind.projectBuild, projects);
    final input = projectBuildInput();
    job = store.startProjectBuild(
      agentId: 'self',
      userText: input.requirements,
      appletScopeKey: 'device-legacy',
      projectKind: ProjectBuildKind.applet,
      binding: ProjectBuildTaskBinding(
        scopeKey: projectBuildTestScope,
        createRequestId: input.requestId,
        pendingCommand: ProjectBuildTaskPendingCommand(
          operation: ProjectBuildTaskOperation.create,
          requestId: input.requestId,
        ),
      ),
    );
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await appServices.reset();
    await database.close();
  });

  test(
    'natural task commands select project controls without image or model fallback',
    () async {
      final llm = _NoModel();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Test',
          avatar: '',
          bio: 'test',
          personalityTraits: const ['warm'],
          catchphrase: 'ok',
        ),
        llmClient: llm,
      );
      addTearDown(runtime.retireAndDrain);
      await runtime.init();
      await runtime.chat('取消任务', const []);
      expect(projects.calls, ['cancel:${job.id}:1']);
      expect(images.calls, isEmpty);
      expect(llm.calls, 0);
      projects.enabled = false;
      await runtime.chat('取消任务', const []);
      expect(projects.calls, hasLength(1));
      expect(images.calls, isEmpty);
      expect(llm.calls, 0);
      expect(
        runtime.retryBackgroundTaskJob(job.id, expectedAttempt: 1),
        isFalse,
      );
      expect(
        runtime.openBackgroundTaskPreview(job.id, expectedAttempt: 1),
        isFalse,
      );
      await runtime.cancelBackgroundTaskJob(job.id, expectedAttempt: 1);
      expect(store.byId(job.id)!.status, AgentTaskJobStatus.running);
    },
  );

  test(
    'Home controls work without hosted chat and reject stale attempt',
    () async {
      final registry = appServices.put(
        AgentRuntimeRegistry(hostExecutionEnabled: false),
      );
      addTearDown(registry.shutdown);
      final home = HomeController();
      addTearDown(home.inputController.dispose);
      await home.cancelTaskJob(job.id, expectedAttempt: 2);
      expect(projects.calls, isEmpty);
      await home.cancelTaskJob(job.id, expectedAttempt: 1);
      await home.retryTaskJob(job.id, expectedAttempt: 1);
      expect(projects.calls, ['cancel:${job.id}:1', 'retry:${job.id}:1']);
      expect(images.calls, isEmpty);
      expect(registry.canHostExecution, isFalse);
    },
  );

  test(
    'account lifecycle restores projects before execution and drains before task store',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final mount = source.substring(
        source.indexOf('Future<AccountRuntimeLease> _mountAccountRuntime'),
        source.indexOf('Future<AccountRuntimeLease> _mountAgentExecution'),
      );
      expect(mount, contains('ProjectBuildRepository('));
      expect(mount, contains('ProjectBuildTasks('));
      expect(mount, contains('enableCreation: false'));
      expect(mount, contains('canRecoverDispatch: () async => false'));
      final start = source.indexOf(
        'Future<void> _drainAccountRuntimeProducers',
      );
      final end = source.indexOf('void _registerDefaultVadServices', start);
      final drain = source.substring(start, end);
      expect(
        drain,
        contains('maybeFind<ProjectBuildTasks>()?.deactivateAndDrain()'),
      );
      final dependency = drain.indexOf('await projectBuildDrain;');
      final storeDrain = drain.indexOf(
        'maybeFind<AgentTaskJobStore>()?.deactivateAndDrain()',
      );
      expect(dependency, greaterThanOrEqualTo(0));
      expect(storeDrain, greaterThan(dependency));
    },
  );
}
