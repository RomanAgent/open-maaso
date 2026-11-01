import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/creator/domain/creator_draft.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_task_binding.dart';
import 'support/creator_task_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CreatorTaskHarness h;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    h = CreatorTaskHarness();
    await h.init();
  });
  tearDown(() => h.close());

  test(
    'image tracker ignores project jobs and preserves its independent control slot',
    () async {
      final project = h.jobs.startProjectBuild(
        agentId: 'self',
        userText: 'create applet',
        appletScopeKey: h.appletScope,
        projectKind: ProjectBuildKind.applet,
        binding: ProjectBuildTaskBinding(
          scopeKey: h.scope,
          createRequestId: 'project-create-request',
          pendingCommand: ProjectBuildTaskPendingCommand(
            operation: ProjectBuildTaskOperation.create,
            requestId: 'project-create-request',
          ),
        ),
      );
      expect(h.tasks.canControl(project, retry: false), isFalse);
      expect(h.tasks.canControl(project, retry: true), isFalse);
      await h.start();
      expect(h.latest.isCreatorImage, isTrue);
      expect(h.jobs.byId(project.id)!.projectBuild!.snapshot, isNull);
      expect(h.jobs.controlsFor(h.latest), same(h.tasks));
      expect(h.server.creates, 1);
    },
  );

  test(
    'Creator queues one durable intent without legacy generation or auto apply',
    () async {
      await h.start();
      expect(h.server.creates, 1);
      expect(h.assets.legacyCalls, 0);
      expect(h.latest.stage, AgentTaskStage.queued);
      expect((await h.repository.get(h.draft.id))!.asset, isNull);
      await h.finish();
      expect(h.latest.status, AgentTaskJobStatus.completed);
      expect(h.assets.downloads, 0);
      expect(
        (await h.repository.get(h.draft.id))!.status,
        CreatorDraftStatus.draft,
      );
      expect(await h.database.getMessages('self'), hasLength(1));
    },
  );

  test(
    'accepted create with lost reply replays same flushed request and ordered events',
    () async {
      h.server.loseCreateAck = true;
      await h.start();
      expect(h.latest.serverImage!.serverSequence, 0);
      expect(h.latest.status, AgentTaskJobStatus.running);
      final before = h.latest.serverImage!.pendingCommand!.requestId;
      final restored = await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(h.database),
      ).init();
      expect(
        restored.jobs.single.serverImage!.pendingCommand!.requestId,
        before,
      );
      await restored.deactivateAndDrain();
      await h.tasks.synchronize(h.latest.taskId);
      expect(h.server.creates, 2);
      expect(h.server.receipts, hasLength(1));
      expect(h.latest.serverImage!.pendingCommand, isNull);
      expect(h.latest.serverImage!.serverSequence, 1);
      final count = h.latest.progress.length;
      await h.tasks.synchronize(h.latest.taskId);
      expect(h.latest.progress.length, count);
      expect(h.assets.legacyCalls, 0);
    },
  );

  test(
    'offline keeps real server state; reconnect appends missed stages exactly once',
    () async {
      await h.start();
      h.server.offline = true;
      await h.tasks.synchronize(h.latest.taskId);
      expect(h.latest.status, AgentTaskJobStatus.running);
      expect(h.latest.serverImage!.snapshot!.status, CreatorTaskStatus.queued);
      expect(h.latest.serverImage!.syncIssue, isNotEmpty);
      h.server.offline = false;
      await h.finish();
      expect(h.latest.serverImage!.serverSequence, 3);
      final stages = h.latest.progress.map((p) => p.stage).toList();
      expect(stages, [
        AgentTaskStage.submitting,
        AgentTaskStage.queued,
        AgentTaskStage.generating,
        AgentTaskStage.completed,
      ]);
      await h.tasks.synchronize(h.latest.taskId);
      expect(h.latest.progress.length, 4);
    },
  );

  test(
    'lost cancel receipt and explicit retry retain command nonce and add one attempt/card',
    () async {
      await h.start();
      h.server.loseCommandAck = true;
      await h.tasks.cancel(h.latest.id, expectedAttempt: 1);
      final command = h.latest.serverImage!.pendingCommand!;
      expect(command.operation, CreatorTaskOperation.cancel);
      await h.tasks.synchronize(h.latest.taskId);
      expect(h.latest.status, AgentTaskJobStatus.cancelled);
      expect(
        h.server.requests
            .where((r) => r.url.path.endsWith('/cancel'))
            .map((r) => r.body)
            .toSet(),
        hasLength(1),
      );
      expect(h.tasks.canControl(h.latest, retry: true), isTrue);
      final old = h.latest;
      await h.tasks.retry(old.id, expectedAttempt: 1);
      expect(h.latest.attempt, 2);
      expect(h.latest.taskId, old.taskId);
      expect(h.latest.serverImage!.serverSequence, 3);
      expect(h.jobs.jobs, hasLength(2));
      expect(h.jobs.byId(old.id)!.isActive, isFalse);
      expect(h.jobs.byId(old.id)!.serverImage!.pendingCommand, isNull);
      await h.jobs.flush();
      final restored = await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(h.database),
      ).init();
      expect(restored.byId(old.id)!.isActive, isFalse);
      expect(
        restored
            .latestForTask(
              old.taskId,
              appletScopeKey: old.appletScopeKey,
              agentId: 'self',
            )!
            .attempt,
        2,
      );
      await restored.deactivateAndDrain();
      expect(await h.database.getMessages('self'), hasLength(1));
      await expectLater(
        h.tasks.cancel(old.id, expectedAttempt: 1),
        throwsA(anything),
      );
    },
  );

  test(
    'account ABA rejects late acknowledgement; logout drains but never cancels remote task',
    () async {
      h.server.pause = Completer<void>();
      final started = h.tasks.enqueue(h.draft);
      await h.server.entered.future;
      await started;
      h.current = false;
      h.changes.notifyListeners();
      h.current = true;
      h.changes.notifyListeners();
      h.server.pause!.complete();
      h.server.pause = null;
      await h.tasks.synchronize(h.latest.taskId);
      expect(h.latest.serverImage!.snapshot, isNull);
      await h.tasks.deactivateAndDrain();
      expect(h.server.commands, 0);
      expect(h.assets.sealed, isTrue);
      expect(
        h.latest.serverImage!.pendingCommand!.operation,
        CreatorTaskOperation.create,
      );
    },
  );

  test(
    'preview is inert until actually displayed and explicit apply; no publication',
    () async {
      await h.start();
      await h.finish();
      final preview = await h.tasks.preview(h.latest.id, expectedAttempt: 1);
      expect(h.assets.downloads, 1);
      expect((await h.repository.get(h.draft.id))!.asset, isNull);
      await expectLater(h.tasks.applyPreview(preview), throwsStateError);
      preview.markPresented();
      final applied = await h.tasks.applyPreview(preview);
      expect(
        applied.asset!.id,
        h.latest.serverImage!.snapshot!.artifact!.assetId,
      );
      expect(applied.status, CreatorDraftStatus.ready);
      expect(h.latest.serverImage!.applied, isTrue);
      expect(
        (await h.repository.get(h.draft.id))!.asset!.id,
        applied.asset!.id,
      );
      expect(
        h.server.requests.any((r) => r.url.path.contains('publish')),
        isFalse,
      );
      preview.close();
      await expectLater(h.tasks.applyPreview(preview), throwsStateError);
    },
  );

  test(
    'changed draft or retired account cannot receive a previously previewed image',
    () async {
      await h.start();
      await h.finish();
      final preview = await h.tasks.preview(h.latest.id, expectedAttempt: 1);
      preview.markPresented();
      await h.repository.save(
        CreatorDraft.fromJson({
          ...h.draft.toJson(),
          'title': 'Edited after request',
        }),
      );
      await expectLater(h.tasks.applyPreview(preview), throwsStateError);
      expect((await h.repository.get(h.draft.id))!.asset, isNull);
      h.current = false;
      h.changes.notifyListeners();
      expect(h.tasks.isPreviewCurrent(preview), isFalse);
      await expectLater(h.tasks.applyPreview(preview), throwsA(anything));
      expect(h.server.commands, 0);
    },
  );

  test('failed local command persistence never starts HTTP', () async {
    await h.close();
    appServices.testMode = true;
    h = CreatorTaskHarness();
    await h.init(persistence: FailingTaskPersistence());
    h.expectPersistenceFailure = true;
    await expectLater(h.tasks.enqueue(h.draft), throwsStateError);
    expect(h.server.requests, isEmpty);
    expect(h.tasks.isAvailable, isFalse);
  });

  test('result must match completed artifact before any download', () async {
    await h.start();
    await h.finish();
    h.server.badArtifact = true;
    await expectLater(
      h.tasks.preview(h.latest.id, expectedAttempt: 1),
      throwsStateError,
    );
    expect(h.assets.downloads, 0);
    expect((await h.repository.get(h.draft.id))!.asset, isNull);
  });
}

class FailingTaskPersistence implements AgentTaskPersistence {
  @override
  Future<List<Map<String, Object?>>> readJobs() async => [];
  @override
  Future<void> writeJob(Map<String, Object?> job, ChatMessage card) async =>
      throw StateError('disk failed');
}
