import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:sembast/sembast_memory.dart';
import 'support/creator_task_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  late AgentTaskJobStore store;
  late SembastAgentTaskPersistence persistence;
  setUp(() async {
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'server-tasks-${DateTime.now().microsecondsSinceEpoch}',
    );
    persistence = SembastAgentTaskPersistence(db);
    store = await AgentTaskJobStore(persistence: persistence).init();
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await db.close();
  });
  AgentTaskJob start() {
    final job = store.startServerImage(
      agentId: 'self',
      userText: 'generate picture',
      appletScopeKey: testAppletScope,
      binding: taskBinding(),
    );
    return store.updateServerBinding(
      job.id,
      job.serverImage!.copyWith(receipt: taskReceipt()),
      expectedScopeKey: testAppletScope,
    );
  }

  AgentTaskJob apply(
    String root,
    int sequence,
    CreatorTaskStatus status, {
    int attempt = 1,
  }) => store.applyServerSnapshot(
    root,
    taskSnapshot(sequence, status, attempt: attempt),
    expectedScopeKey: testAppletScope,
    agentId: 'self',
  );
  test(
    'restored server status is projected from its authoritative checkpoint',
    () async {
      final first = start();
      final queued = apply(first.id, 1, CreatorTaskStatus.queued);
      await store.flush();
      final stale = queued.copyWith(
        status: AgentTaskJobStatus.completed,
        stage: AgentTaskStage.completed,
      );
      await persistence.writeJob(stale.toJson(), store.cardFor(stale));
      final restored = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(restored.deactivateAndDrain);
      expect(restored.byId(first.id)!.status, AgentTaskJobStatus.running);
      expect(restored.byId(first.id)!.stage, AgentTaskStage.synchronizing);
    },
  );

  test(
    'local committed Surface cannot prove a server image completed',
    () async {
      final job = start();
      apply(job.taskId, 1, CreatorTaskStatus.queued);
      await store.flush();
      final item = AgentWidget(
        agentId: 'self',
        title: 'Unrelated local Surface',
        kind: 'surface',
        createdAt: DateTime.now(),
        spec: {'taskJobId': job.id, 'surfaceId': 'local'},
      );
      AppletLocalOwnership.stamp(item, scopeKey: testAppletScope);
      await db.saveAgentWidget(item);
      final recovered = await AgentTaskJobStore(
        persistence: persistence,
      ).init();
      addTearDown(recovered.deactivateAndDrain);
      expect(
        recovered.byId(job.id)!.serverImage!.snapshot!.status,
        CreatorTaskStatus.queued,
      );
      expect(recovered.byId(job.id)!.widgetId, isNull);
      expect(recovered.byId(job.id)!.status, AgentTaskJobStatus.running);
    },
  );

  test(
    'server restore waits for reconciliation while local work remains interrupted',
    () async {
      final local = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: 'clock',
        appletScopeKey: testAppletScope,
      );
      final server = start();
      apply(server.taskId, 1, CreatorTaskStatus.queued);
      apply(server.taskId, 2, CreatorTaskStatus.running);
      await store.flush();
      final reopened = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(reopened.deactivateAndDrain);
      expect(reopened.byId(local.id)!.stage, AgentTaskStage.interrupted);
      final restored = reopened.byId(server.id)!;
      expect(restored.status, AgentTaskJobStatus.running);
      expect(restored.stage, AgentTaskStage.synchronizing);
      expect(restored.serverImage!.serverSequence, 2);
      expect(restored.error, isEmpty);
    },
  );
  test(
    'receipts and duplicates do not manufacture progress or rewind authoritative state',
    () async {
      final job = start();
      expect(job.progress.map((e) => e.stage), [AgentTaskStage.submitting]);
      apply(job.taskId, 1, CreatorTaskStatus.queued);
      final running = apply(job.taskId, 2, CreatorTaskStatus.running);
      final duplicate = apply(job.taskId, 2, CreatorTaskStatus.running);
      expect(duplicate.progress.length, running.progress.length);
      final checkpoint = store.updateServerBinding(
        job.id,
        running.serverImage!.copyWith(receipt: taskReceipt()),
        expectedScopeKey: testAppletScope,
      );
      expect(checkpoint.serverImage!.serverSequence, 2);
      expect(checkpoint.status, AgentTaskJobStatus.running);
      expect(
        () => apply(job.taskId, 2, CreatorTaskStatus.completed),
        throwsStateError,
      );
      expect(
        () => apply(job.taskId, 4, CreatorTaskStatus.failed),
        throwsStateError,
      );
      expect(
        store.completeCommittedPresentation(job.id).status,
        AgentTaskJobStatus.running,
      );
      expect(store.cancel(job.id).status, AgentTaskJobStatus.running);
    },
  );
  test(
    'server attempts append local rows with one stable chat card and independent counters',
    () async {
      final first = start();
      apply(first.taskId, 1, CreatorTaskStatus.queued);
      apply(first.taskId, 2, CreatorTaskStatus.running);
      final failed = apply(first.taskId, 3, CreatorTaskStatus.failed);
      expect(store.retry(failed.id).id, failed.id);
      final second = apply(
        first.taskId,
        4,
        CreatorTaskStatus.queued,
        attempt: 2,
      );
      expect(second.attempt, 2);
      expect(second.id, isNot(first.id));
      expect(second.taskId, first.id);
      expect(second.progress.single.sequence, 1);
      expect(second.serverImage!.serverSequence, 4);
      // Device/server clock skew can put the older attempt last after restore.
      store.jobs.assignAll([second, store.byId(first.id)!]);
      expect(
        store.latestForAgent('self', appletScopeKey: testAppletScope)!.id,
        second.id,
      );
      expect(
        store.latestForAgent(
          'self',
          appletScopeKey: testAppletScope,
          statuses: {AgentTaskJobStatus.failed},
        ),
        isNull,
      );
      expect(apply(first.taskId, 3, CreatorTaskStatus.failed).id, second.id);
      await store.flush();
      final cards = await db.getMessages('self');
      expect(cards, hasLength(1));
      expect(cards.single.taskReference!.taskId, first.id);
      expect(cards.single.isModelContextEligible, isFalse);
    },
  );
  test(
    'pending command and origin survive codec without granting local Surface control',
    () {
      final first = start();
      final decoded = AgentTaskJob.tryParse(first.toJson())!;
      expect(decoded.isServerBacked, isTrue);
      expect(decoded.serverImage!.pendingCommand!.requestId, createRequestId);
      final forged = {...first.toJson(), 'executionLocation': 'local'};
      expect(AgentTaskJob.tryParse(forged), isNull);
      final fakeSurface = {...first.toJson(), 'widgetId': 7};
      expect(AgentTaskJob.tryParse(fakeSurface), isNull);
      final local = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: 'game',
      );
      expect(AgentTaskJob.tryParse(local.toJson())!.isServerBacked, isFalse);
    },
  );
}
