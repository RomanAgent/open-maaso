import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'today-only U2A keeps one active task across midnight and releases it after completion',
    () async {
      await appServices.reset();
      appServices.testMode = true;
      final db = appServices.put(
        await DBService().init(
          factory: databaseFactoryMemory,
          path: 'task-day.db',
        ),
      );
      appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
      final tasks = appServices.put(AgentTaskJobStore());
      var now = DateTime.now();
      final controller = U2aChatController(clock: () => now);
      addTearDown(() async {
        controller.onClose();
        await appServices.reset();
        await db.close();
      });
      final job = tasks.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: 'create game',
        appletScopeKey: 'device-legacy',
      );
      final original = tasks.cardFor(job)..id = 1;
      controller.messages.add(original);
      expect(controller.todayMessages, hasLength(1));
      now = now.add(const Duration(days: 1));
      expect(controller.todayMessages.single.taskReference?.taskId, job.taskId);
      tasks.complete(job.id);
      expect(controller.todayMessages, isEmpty);
      expect(controller.messages.single.id, 1);
      tasks.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: 'foreign task',
        appletScopeKey: 'other-account',
      );
      expect(controller.todayMessages, isEmpty);
    },
  );
}
