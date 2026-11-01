import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:sembast/sembast_memory.dart';
import 'support/creator_task_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  late SembastAgentTaskPersistence persistence;
  late AgentTaskJobStore store;
  setUp(() async {
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'creator-attempt-${DateTime.now().microsecondsSinceEpoch}',
    );
    persistence = SembastAgentTaskPersistence(db);
    store = await AgentTaskJobStore(persistence: persistence).init();
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await db.close();
  });
  Future<AgentTaskJob> pendingRetry() async {
    final created = store.startServerImage(
      agentId: 'self',
      userText: 'Image',
      appletScopeKey: testAppletScope,
      binding: taskBinding(),
    );
    store.updateServerBinding(
      created.id,
      created.serverImage!.copyWith(receipt: taskReceipt()),
      expectedScopeKey: testAppletScope,
    );
    store.applyServerSnapshot(
      created.id,
      taskSnapshot(1, CreatorTaskStatus.queued),
      expectedScopeKey: testAppletScope,
      agentId: 'self',
    );
    final failed = store.applyServerSnapshot(
      created.id,
      taskSnapshot(2, CreatorTaskStatus.failed),
      expectedScopeKey: testAppletScope,
      agentId: 'self',
    );
    final pending = store.updateServerBinding(
      failed.id,
      failed.serverImage!.copyWith(
        pendingCommand: const CreatorTaskCommand(
          operation: CreatorTaskOperation.retry,
          requestId: 'retry_request',
          expectedAttemptId: attemptId,
        ),
      ),
      expectedScopeKey: testAppletScope,
    );
    await store.flush();
    return pending;
  }

  test(
    'second row failure rolls back retirement and preserves original retry nonce',
    () async {
      final pending = await pendingRetry();
      final retired = pending.toJson();
      retired['serverImage'] = pending.serverImage!
          .copyWith(clearPending: true)
          .toJson();
      await expectLater(
        persistence.writeServerAttempt(
          retired: retired,
          next: {
            ...pending.toJson(),
            'id': 'job_999999_9',
            'unsupported': Object(),
          },
          card: store.cardFor(pending),
        ),
        throwsA(anything),
      );
      final rows = await persistence.readJobs();
      expect(rows, hasLength(1));
      expect(
        AgentTaskJob.tryParse(
          rows.single,
        )!.serverImage!.pendingCommand!.requestId,
        'retry_request',
      );
      expect(await db.getMessages('self'), hasLength(1));
      final next = store.applyServerSnapshot(
        pending.id,
        taskSnapshot(3, CreatorTaskStatus.queued, attempt: 2),
        expectedScopeKey: testAppletScope,
        agentId: 'self',
      );
      await store.flush();
      final restored = await AgentTaskJobStore(persistence: persistence).init();
      expect(restored.byId(pending.id)!.isActive, isFalse);
      expect(restored.byId(next.id)!.attempt, 2);
      expect(restored.byId(next.id)!.serverImage!.serverSequence, 3);
      expect(await db.getMessages('self'), hasLength(1));
      await restored.deactivateAndDrain();
    },
  );
  test(
    'failed atomic transition cannot be bypassed by a later single-row progress write',
    () async {
      final pending = await pendingRetry();
      final fail = _FailAtomic(persistence);
      final recovering = await AgentTaskJobStore(persistence: fail).init();
      fail.normalWrites = 0;
      recovering.applyServerSnapshot(
        pending.id,
        taskSnapshot(3, CreatorTaskStatus.queued, attempt: 2),
        expectedScopeKey: testAppletScope,
        agentId: 'self',
      );
      recovering.applyServerSnapshot(
        pending.id,
        taskSnapshot(4, CreatorTaskStatus.running, attempt: 2),
        expectedScopeKey: testAppletScope,
        agentId: 'self',
      );
      await expectLater(recovering.flush(), throwsStateError);
      expect(fail.normalWrites, 0);
      final rows = await persistence.readJobs();
      expect(rows, hasLength(1));
      expect(
        AgentTaskJob.tryParse(
          rows.single,
        )!.serverImage!.pendingCommand!.requestId,
        'retry_request',
      );
      await expectLater(recovering.deactivateAndDrain(), throwsStateError);
    },
  );
}

class _FailAtomic implements AgentTaskPersistence, AgentTaskAttemptPersistence {
  _FailAtomic(this.delegate);
  final AgentTaskPersistence delegate;
  int normalWrites = 0;
  @override
  Future<List<Map<String, Object?>>> readJobs() => delegate.readJobs();
  @override
  Future<void> writeJob(Map<String, Object?> job, ChatMessage card) {
    normalWrites++;
    return delegate.writeJob(job, card);
  }

  @override
  Future<void> writeServerAttempt({
    required Map<String, Object?> retired,
    required Map<String, Object?> next,
    required ChatMessage card,
  }) async => throw StateError('simulated commit failure');
}
