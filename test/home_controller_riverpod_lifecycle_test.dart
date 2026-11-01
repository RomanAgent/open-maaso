import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:sembast/sembast_memory.dart';

class _IdleAgentCoreController extends AgentCoreController {
  @override
  // Test double intentionally suppresses AgentCoreController's async profile
  // bootstrap so this test isolates HomeController's route initialization.
  // ignore: must_call_super
  void onInit() {}
}

class _HomeControllerResolver extends ConsumerWidget {
  const _HomeControllerResolver();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appServicesProvider);
    appServices.find<HomeController>();
    return const SizedBox();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'home-controller-riverpod-lifecycle.db',
    );
    appServices.put<DBService>(db);
    appServices.put(AgentRuntimeRegistry());
    appServices.put<AgentCoreController>(_IdleAgentCoreController());
    final taskJobs = appServices.put(AgentTaskJobStore());
    taskJobs.start(
      agentId: 'self',
      taskKind: AgentTaskKind.skillTask,
      userText: 'remember this task',
      appletScopeKey: AppletLocalOwnership.currentScopeKey(),
    );
    appServices.lazyPut<HomeController>(HomeController.new);
  });

  tearDown(() async {
    await appServices.reset();
  });

  testWidgets(
    'lazy HomeController initialization does not mutate providers during build',
    (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: _HomeControllerResolver()),
        ),
      );

      expect(tester.takeException(), isNull);
      final controller = appServices.find<HomeController>();
      final taskJobs = appServices.find<AgentTaskJobStore>();
      expect(controller.latestTaskJob.value?.userText, 'remember this task');

      taskJobs.start(
        agentId: 'self',
        taskKind: AgentTaskKind.skillTask,
        userText: 'other account task',
        appletScopeKey: 'https://other.example|other-account',
      );
      expect(controller.latestTaskJob.value?.userText, 'remember this task');

      final currentTask = taskJobs.start(
        agentId: 'self',
        taskKind: AgentTaskKind.skillTask,
        userText: 'current account task',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      expect(controller.latestTaskJob.value?.userText, 'current account task');

      taskJobs.awaitInput(currentTask.id, 'Choose a mode');
      controller.dismissTaskJobStatus();
      expect(controller.latestTaskJob.value?.pendingPrompt, 'Choose a mode');
      await appServices.delete<HomeController>(force: true);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cold hydration prefers an awaiting job over a newer terminal job',
    (tester) async {
      final taskJobs = appServices.find<AgentTaskJobStore>();
      final earlier = taskJobs.jobs.single;
      final later = taskJobs.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: 'newer terminal task',
        appletScopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      taskJobs.complete(later.id, summary: 'surface opened');
      taskJobs.awaitInput(earlier.id, 'Choose a mode');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: _HomeControllerResolver()),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final controller = appServices.find<HomeController>();
      expect(controller.latestTaskJob.value?.id, earlier.id);
      expect(controller.latestTaskJob.value?.pendingPrompt, 'Choose a mode');
      await appServices.delete<HomeController>(force: true);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('Home dock hides an Applet until its presentation commits', () async {
    final database = appServices.find<DBService>();
    AgentWidget surface(String title, {bool pending = false}) {
      final widget = AgentWidget(
        agentId: 'self',
        title: title,
        kind: 'surface',
        spec: <String, Object?>{
          'surfaceId': 'surface_$title',
          'experienceType': 'game',
          if (pending) appletPresentationPendingKey: true,
        },
        createdAt: DateTime.now(),
      );
      AppletLocalOwnership.stamp(widget);
      return widget;
    }

    await database.saveAgentWidget(surface('Committed'));
    await database.saveAgentWidget(surface('Pending', pending: true));
    final controller = appServices.find<HomeController>();

    await controller.loadDock();

    expect(controller.dockWidgets.map((widget) => widget.title), <String>[
      'Committed',
    ]);

    final completed = appServices.find<AgentTaskJobStore>().start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: 'Generate a committed Applet',
      appletScopeKey: AppletLocalOwnership.currentScopeKey(),
    );
    appServices.find<AgentTaskJobStore>().complete(completed.id);
    await pumpEventQueue();

    expect(
      appServices.find<AgentTaskJobStore>().byId(completed.id)?.status,
      AgentTaskJobStatus.completed,
    );
    expect(controller.latestTaskJob.value?.status, AgentTaskJobStatus.running);
    expect(controller.dockWidgets.map((widget) => widget.title), ['Committed']);
  });
}
