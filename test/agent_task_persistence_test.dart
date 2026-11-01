import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late SembastAgentTaskPersistence persistence;
  late AgentTaskJobStore store;

  setUp(() async {
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'tasks-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    persistence = SembastAgentTaskPersistence(database);
    store = await AgentTaskJobStore(persistence: persistence).init();
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await database.close();
  });

  AgentTaskJob start() => store.start(
    agentId: 'self',
    taskKind: AgentTaskKind.surfaceGeneration,
    userText: '创建一个时钟',
    appletScopeKey: 'device-legacy',
  );

  test(
    'reference inputs retain their exact revision, purpose and summary across retry and restore',
    () async {
      final reference = ProjectReferenceInputSnapshot(
        scopeKey: 'device-legacy',
        visualSummary: 'Original image description',
        inputRevision: 4,
        references: [
          ProjectReferenceImage(
            sha256: 'a' * 64,
            byteLength: 12,
            mime: 'image/jpeg',
            purpose: ProjectReferencePurpose.layout,
          ),
        ],
      );
      final first = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '创建一个时钟',
        appletScopeKey: 'device-legacy',
        referenceInput: reference,
      );
      store.fail(first.id, 'failed');
      final second = store.retry(first.id);
      expect(second.referenceInput!.digest, reference.digest);
      await store.flush();
      final reopened = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(reopened.deactivateAndDrain);
      final restored = reopened.byId(second.id)!.referenceInput!;
      expect(restored.toJson(), reference.toJson());
      expect(restored.inputRevision, 4);
      final malformed = first.toJson()..['appletScopeKey'] = 'other-scope';
      expect(AgentTaskJob.tryParse(malformed), isNull);
      expect(
        () => store.start(
          agentId: 'self',
          taskKind: AgentTaskKind.gameGeneration,
          userText: '创建游戏',
          appletScopeKey: 'other-scope',
          referenceInput: reference,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'public node evidence survives retry and reopening without rewriting history',
    () async {
      final first = start();
      final firstProgress = store
          .recordProgress(
            first.id,
            expectedAttempt: 1,
            stage: AgentTaskStage.validating,
            description: '检查首个候选',
            details: '操作契约未通过。\n保留本次检查记录。',
            evidence: const [
              AgentTaskEvidence(
                kind: AgentTaskEvidenceKind.validation,
                outcome: AgentTaskEvidenceOutcome.failed,
                label: '操作契约',
                count: 1,
              ),
            ],
          )
          .progress
          .last
          .toJson();
      store.fail(first.id, 'validation_failed');
      final second = store.retry(first.id);
      store.recordProgress(
        second.id,
        expectedAttempt: 2,
        stage: AgentTaskStage.saving,
        description: '保存已检查的作品',
        details: '作品保存回执已记录。',
        evidence: const [
          AgentTaskEvidence(
            kind: AgentTaskEvidenceKind.artifact,
            outcome: AgentTaskEvidenceOutcome.completed,
            label: '作品版本',
            reference: 'surface-1',
          ),
        ],
      );
      store.completeCommittedPresentation(second.id);
      await store.flush();

      final reopened = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(reopened.deactivateAndDrain);
      final restoredFirst = reopened.byId(first.id)!;
      final restoredSecond = reopened.byId(second.id)!;
      expect(restoredFirst.progress[1].toJson(), firstProgress);
      expect(restoredFirst.progress.map((event) => event.sequence), [1, 2, 3]);
      expect(restoredSecond.progress.map((event) => event.sequence), [1, 2, 3]);
      expect(restoredSecond.progress[1].evidence.single.reference, 'surface-1');
      expect(restoredSecond.attempt, 2);
      expect(restoredSecond.taskId, first.id);
      expect(restoredSecond.status, AgentTaskJobStatus.completed);
      expect(
        () => restoredFirst.progress[1].evidence.clear(),
        throwsUnsupportedError,
      );
      expect(await database.getMessages('self'), hasLength(1));
    },
  );

  test(
    'committed receipt recovery keeps earlier public details intact',
    () async {
      final job = start();
      store.recordProgress(
        job.id,
        expectedAttempt: 1,
        stage: AgentTaskStage.saving,
        description: '正在保存作品',
        evidence: const [
          AgentTaskEvidence(
            kind: AgentTaskEvidenceKind.execution,
            outcome: AgentTaskEvidenceOutcome.started,
            label: '本地保存',
          ),
        ],
      );
      await store.flush();
      final item = AgentWidget(
        agentId: 'self',
        title: 'Clock',
        kind: 'surface',
        createdAt: DateTime.now(),
        spec: {'surfaceId': 'clock', 'taskJobId': job.id},
      );
      AppletLocalOwnership.stamp(item, scopeKey: job.appletScopeKey);
      await database.saveAgentWidget(item);

      final reopened = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(reopened.deactivateAndDrain);
      final restored = reopened.byId(job.id)!;
      expect(restored.status, AgentTaskJobStatus.completed);
      expect(restored.progress.map((event) => event.sequence), [1, 2, 3]);
      expect(restored.progress[1].description, '正在保存作品');
      expect(
        restored.progress[1].evidence.single.outcome,
        AgentTaskEvidenceOutcome.started,
      );
      expect(restored.progress.last.stage, AgentTaskStage.completed);
      expect(restored.progress.last.description, isEmpty);
    },
  );

  test(
    'task, event journal and one chat reference survive attempts and reopen',
    () async {
      final first = start();
      store.updateStage(first.id, AgentTaskStage.validating);
      store.fail(first.id, 'validation failed');
      final second = store.retry(first.id);
      store.updateStage(
        second.id,
        AgentTaskStage.saving,
        surfaceId: 'surface-1',
        widgetId: 7,
      );
      store.completeCommittedPresentation(second.id);
      await store.flush();
      final cards = await database.getMessages('self');
      expect(cards, hasLength(1));
      expect(cards.single.taskReference?.taskId, first.id);
      expect(cards.single.isModelContextEligible, isFalse);
      final reopened = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(reopened.deactivateAndDrain);
      final latest = reopened.latestForTask(
        first.id,
        appletScopeKey: 'device-legacy',
        agentId: 'self',
      )!;
      expect(latest.id, second.id);
      expect(latest.attempt, 2);
      expect(latest.status, AgentTaskJobStatus.completed);
      expect(latest.widgetId, 7);
      expect(latest.progress.map((event) => event.sequence), [1, 2, 3]);
      expect((await database.getMessages('self')).length, 1);
    },
  );

  test(
    'all unfinished local states restore as interrupted, never pretend running',
    () async {
      final running = start();
      final awaiting = start();
      store.awaitInput(awaiting.id, '哪个颜色？');
      final cancelling = start();
      store.requestCancel(cancelling.id);
      await store.flush();
      final restored = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(restored.deactivateAndDrain);
      for (final original in [running, awaiting, cancelling]) {
        final job = restored.byId(original.id)!;
        expect(job.status, AgentTaskJobStatus.failed);
        expect(job.stage, AgentTaskStage.interrupted);
        expect(job.pendingPrompt, isEmpty);
        expect(job.progress.last.stage, AgentTaskStage.interrupted);
      }
      expect(
        restored.latestForTask(
          running.id,
          appletScopeKey: 'other',
          agentId: 'self',
        ),
        isNull,
      );
    },
  );

  test('repeated old retry cannot create a sibling execution', () {
    final job = start();
    store.fail(job.id, 'failed');
    final retry = store.retry(job.id);
    expect(store.retry(job.id).id, job.id);
    expect(store.jobs, hasLength(2));
    expect(store.isCurrentAttempt(job), isFalse);
    expect(store.isCurrentAttempt(retry), isTrue);
  });

  test(
    'execution attempt wins even when the restored clock order goes backwards',
    () {
      final first = start();
      store.fail(first.id, 'failed');
      final second = store.retry(first.id);
      store.jobs.assignAll([second, first]);
      expect(
        store
            .latestForTask(
              first.taskId,
              appletScopeKey: first.appletScopeKey,
              agentId: first.agentId,
            )
            ?.id,
        second.id,
      );
      expect(store.isCurrentAttempt(first), isFalse);
      expect(store.isCurrentAttempt(second), isTrue);
    },
  );

  for (final pending in [false, true]) {
    test(
      'recovery trusts only a committed scoped artifact (pending=$pending)',
      () async {
        final job = start();
        await store.flush();
        final item = AgentWidget(
          agentId: 'self',
          title: 'Clock',
          kind: 'surface',
          createdAt: DateTime.now(),
          spec: {'surfaceId': 'clock', 'taskJobId': job.id},
        );
        AppletLocalOwnership.stamp(item, scopeKey: job.appletScopeKey);
        if (pending) markAppletPresentationPending(item);
        await database.saveAgentWidget(item);
        final restored = await AgentTaskJobStore(
          persistence: persistence,
        ).init();
        addTearDown(restored.deactivateAndDrain);
        final actual = restored.byId(job.id)!;
        expect(
          actual.status,
          pending ? AgentTaskJobStatus.failed : AgentTaskJobStatus.completed,
        );
        expect(actual.widgetId, pending ? isNull : item.id);
      },
    );
  }

  test('preview acceptance binds attempt and completes exactly once', () async {
    final job = start();
    final preview = store.awaitPreview(job.id);
    expect(store.byId(job.id)?.stage, AgentTaskStage.previewReady);
    expect(store.acceptPreview(job.id, expectedAttempt: 2), isFalse);
    expect(store.acceptPreview(job.id, expectedAttempt: 1), isTrue);
    expect(store.acceptPreview(job.id, expectedAttempt: 1), isFalse);
    expect(await preview, isTrue);
    expect(store.byId(job.id)?.status, AgentTaskJobStatus.running);
  });

  test(
    'cancelling or draining releases a deferred preview without presentation',
    () async {
      final first = start();
      final firstPreview = store.awaitPreview(first.id);
      store.cancel(first.id);
      expect(await firstPreview, isFalse);
      final second = start();
      final secondPreview = store.awaitPreview(second.id);
      await store.deactivateAndDrain();
      expect(await secondPreview, isFalse);
      expect(() => start(), throwsStateError);
    },
  );

  test(
    'task reference round trips and invalid shapes retain legacy compatibility',
    () {
      final card = store.cardFor(start());
      final parsed = ChatMessage.fromJson(card.toJson());
      expect(parsed.taskReference?.taskId, card.taskReference!.taskId);
      expect(
        ChatMessage.fromJson({
          ...card.toJson(),
          'taskReference': {'taskId': '../../other'},
        }).taskReference,
        isNull,
      );
      final legacy = ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: 'hello',
        timestamp: DateTime.now(),
      );
      expect(
        ChatMessage.fromJson(legacy.toJson()).isModelContextEligible,
        isTrue,
      );
    },
  );

  test(
    'failed persistence is observable at flush rather than a false durable ack',
    () async {
      final failed = AgentTaskJobStore(persistence: _FailingPersistence());
      failed.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: 'game',
      );
      await expectLater(failed.flush(), throwsStateError);
    },
  );
}

class _FailingPersistence implements AgentTaskPersistence {
  @override
  Future<List<Map<String, Object?>>> readJobs() async => [];
  @override
  Future<void> writeJob(Map<String, Object?> job, ChatMessage card) async =>
      throw StateError('disk full');
}
