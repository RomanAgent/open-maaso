import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_task_binding.dart';
import 'package:maaso/src/features/project_build/data/project_build_repository.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_build_fixtures.dart';
import 'support/creator_task_fixtures.dart' as creator;

const _appletScope = 'device-legacy';

ProjectBuildTaskBinding _binding({
  bool pending = true,
  String scope = projectBuildTestScope,
}) => ProjectBuildTaskBinding(
  scopeKey: scope,
  createRequestId: projectBuildInput().requestId,
  pendingCommand: pending
      ? ProjectBuildTaskPendingCommand(
          operation: ProjectBuildTaskOperation.create,
          requestId: projectBuildInput().requestId,
        )
      : null,
);

AgentTaskJob _start(AgentTaskJobStore store) => store.startProjectBuild(
  agentId: projectBuildInput().agentId,
  userText: projectBuildInput().requirements,
  appletScopeKey: _appletScope,
  projectKind: projectBuildInput().projectKind,
  binding: _binding(),
);

AgentTaskJob _receipt(AgentTaskJobStore store, AgentTaskJob job) =>
    store.updateProjectBuildBinding(
      job.id,
      job.projectBuild!.copyWith(
        taskId: projectBuildReceipt().taskId,
        pendingCommand: job.projectBuild!.pendingCommand!.copyWith(
          acceptedTaskSequence: 1,
        ),
      ),
      expectedScopeKey: _appletScope,
    );

AgentTaskJob _apply(
  AgentTaskJobStore store,
  String root,
  Map<String, Object?> raw,
) => store.applyProjectBuildEvent(
  root,
  ProjectBuildEvent.fromJson(raw),
  expectedScopeKey: _appletScope,
  agentId: projectBuildInput().agentId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentTaskJobStore store;
  setUp(() async {
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'project-task-${DateTime.now().microsecondsSinceEpoch}',
    );
    store = await AgentTaskJobStore(
      persistence: SembastAgentTaskPersistence(database),
    ).init();
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await database.close();
  });

  test(
    'receipt is transport-only and only journal events append real stages',
    () async {
      final root = _start(store);
      expect(root.executionKind, AgentTaskExecutionKind.projectBuild);
      expect(root.isProjectBuild, isTrue);
      expect(root.isServerBacked, isTrue);
      expect(root.isCreatorImage, isFalse);
      expect(_start(store).id, root.id);
      final accepted = _receipt(store, root);
      expect(accepted.projectBuild!.appliedTaskSequence, 0);
      expect(accepted.stage, AgentTaskStage.synchronizing);
      expect(accepted.progress, hasLength(1));
      final first = ProjectBuildEvent.fromJson(projectBuildEvents().first);
      expect(
        () => store.updateProjectBuildBinding(
          root.id,
          accepted.projectBuild!.copyWith(snapshot: first.snapshot),
          expectedScopeKey: _appletScope,
        ),
        throwsStateError,
      );
      var current = accepted;
      for (final event in projectBuildEvents()) {
        current = _apply(store, root.id, event);
      }
      expect(current.status, AgentTaskJobStatus.failed);
      expect(current.progress.map((event) => event.stage), [
        AgentTaskStage.submitting,
        AgentTaskStage.queued,
        AgentTaskStage.generating,
        AgentTaskStage.failed,
      ]);
      expect(
        current.progress.last.evidence.single.reference,
        startsWith('pbe-3-'),
      );
      expect(
        () => current.progress.last.evidence.clear(),
        throwsUnsupportedError,
      );
      expect(() => root.progress.clear(), throwsUnsupportedError);
      expect(
        store.completeCommittedPresentation(current.id).status,
        AgentTaskJobStatus.failed,
      );
      await store.flush();
      expect(
        await database.getMessages(projectBuildInput().agentId),
        hasLength(1),
      );
    },
  );

  test(
    'same or old events are idempotent, conflicting duplicates and gaps are rejected',
    () {
      final root = _start(store);
      _receipt(store, root);
      final events = projectBuildEvents();
      expect(() => _apply(store, root.id, events[1]), throwsStateError);
      for (final event in events) {
        _apply(store, root.id, event);
      }
      final count = store.byId(root.id)!.progress.length;
      for (final event in events) {
        _apply(store, root.id, event);
      }
      expect(store.byId(root.id)!.progress, hasLength(count));
      final conflicting = {...events[1], 'type': 'run.checkpointed'};
      expect(() => _apply(store, root.id, conflicting), throwsStateError);
      expect(store.byId(root.id)!.projectBuild!.appliedTaskSequence, 3);
    },
  );

  test(
    'retry creates a separate attempt with one card and independent run sequence',
    () async {
      final root = _start(store);
      _receipt(store, root);
      for (final event in projectBuildEvents()) {
        _apply(store, root.id, event);
      }
      final failed = store.byId(root.id)!;
      final pending = ProjectBuildTaskPendingCommand(
        operation: ProjectBuildTaskOperation.retry,
        requestId: 'retry-original-request',
        expectedRunId: failed.projectBuild!.snapshot!.runId,
        expectedStatusVersion: failed.projectBuild!.snapshot!.statusVersion,
      );
      final preparing = store.updateProjectBuildBinding(
        root.id,
        failed.projectBuild!.copyWith(pendingCommand: pending),
        expectedScopeKey: _appletScope,
      );
      store.updateProjectBuildBinding(
        root.id,
        preparing.projectBuild!.copyWith(
          pendingCommand: pending.copyWith(acceptedTaskSequence: 4),
        ),
        expectedScopeKey: _appletScope,
      );
      final next = _apply(store, root.id, projectBuildRetryEvent());
      expect(next.id, isNot(root.id));
      expect(next.taskId, root.id);
      expect(next.attempt, 2);
      expect(next.projectBuild!.snapshot!.snapshotSequence, 1);
      expect(next.projectBuild!.appliedTaskSequence, 4);
      expect(next.projectBuild!.pendingCommand, isNull);
      expect(next.progress.map((event) => event.stage), [
        AgentTaskStage.queued,
      ]);
      expect(store.byId(root.id)!.status, AgentTaskJobStatus.failed);
      expect(store.byId(root.id)!.projectBuild!.pendingCommand, isNull);
      expect(store.isCurrentAttempt(root), isFalse);
      for (final event in [...projectBuildEvents(), projectBuildRetryEvent()]) {
        _apply(store, root.id, event);
      }
      expect(store.jobs, hasLength(2));
      await store.flush();
      expect(
        await database.getMessages(projectBuildInput().agentId),
        hasLength(1),
      );
      final restored = await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(database),
      ).init();
      addTearDown(restored.deactivateAndDrain);
      expect(restored.byId(next.id)!.projectBuild!.appliedTaskSequence, 4);
      expect(restored.byId(next.id)!.stage, AgentTaskStage.synchronizing);
      expect(restored.byId(next.id)!.progress, hasLength(1));
      expect(restored.byId(root.id)!.progress, hasLength(4));
    },
  );

  test(
    'restore can rebind the durable original create nonce without inventing progress',
    () async {
      final input = projectBuildInput();
      final root = store.restoreProjectBuild(
        agentId: input.agentId,
        userText: input.requirements,
        appletScopeKey: _appletScope,
        projectKind: input.projectKind,
        binding: _binding(pending: false),
        createdAt: DateTime.utc(2026, 9, 28),
      );
      expect(root.progress, isEmpty);
      final pending = store.updateProjectBuildBinding(
        root.id,
        _binding(),
        expectedScopeKey: _appletScope,
      );
      final accepted = _receipt(store, pending);
      expect(accepted.progress, isEmpty);
      final projected = _apply(store, root.id, projectBuildEvents().first);
      expect(projected.progress.map((event) => event.stage), [
        AgentTaskStage.queued,
      ]);
      expect(projected.projectBuild!.pendingCommand, isNull);
      expect(
        () => store.restoreProjectBuild(
          agentId: input.agentId,
          userText: input.requirements,
          appletScopeKey: _appletScope,
          projectKind: input.projectKind,
          binding: projected.projectBuild!,
          createdAt: root.createdAt,
        ),
        throwsStateError,
      );
      await store.flush();
    },
  );

  test(
    'scope, execution-kind and pending-command boundaries reject foreign data',
    () {
      final root = _start(store);
      final accepted = _receipt(store, root);
      expect(
        () => store.updateProjectBuildBinding(
          root.id,
          accepted.projectBuild!,
          expectedScopeKey: 'other-applet',
        ),
        throwsStateError,
      );
      expect(
        () => store.updateProjectBuildBinding(
          root.id,
          ProjectBuildTaskBinding(
            scopeKey: 'other|account',
            createRequestId: root.projectBuild!.createRequestId,
          ),
          expectedScopeKey: _appletScope,
        ),
        throwsStateError,
      );
      expect(
        () => store.applyProjectBuildEvent(
          root.id,
          ProjectBuildEvent.fromJson(projectBuildEvents().first),
          expectedScopeKey: _appletScope,
          agentId: 'other-agent',
        ),
        throwsStateError,
      );
      expect(
        () => store.updateServerBinding(
          root.id,
          creator.taskBinding(),
          expectedScopeKey: _appletScope,
        ),
        throwsStateError,
      );
      expect(
        () => store.updateProjectBuildBinding(
          root.id,
          accepted.projectBuild!.copyWith(clearPending: true),
          expectedScopeKey: _appletScope,
        ),
        throwsStateError,
      );
      final wire = root.toJson();
      expect(
        AgentTaskJob.tryParse({...wire, 'executionKind': 'local'}),
        isNull,
      );
      expect(
        AgentTaskJob.tryParse({
          ...wire,
          'serverImage': creator.taskBinding().toJson(),
        }),
        isNull,
      );
      final altered = {
        ...root.projectBuild!.toJson(),
        'appliedTaskSequence': 99,
      };
      expect(
        () => ProjectBuildTaskBinding.fromJson(altered),
        throwsFormatException,
      );
    },
  );

  test(
    'project controls coexist with the backwards-compatible image slot',
    () async {
      final project = _start(store);
      final image = store.startServerImage(
        agentId: 'self',
        userText: 'image',
        appletScopeKey: _appletScope,
        binding: creator.taskBinding(),
      );
      final imageControls = _Controls();
      final projectControls = _Controls();
      store.serverControls = imageControls;
      store.registerControls(
        AgentTaskExecutionKind.projectBuild,
        projectControls,
      );
      expect(store.controlsFor(image), same(imageControls));
      expect(store.controlsFor(project), same(projectControls));
      expect(image.executionKind, AgentTaskExecutionKind.creatorImage);
      expect(image.isServerBacked, isTrue);
      final legacyImage = image.toJson()..remove('executionKind');
      expect(AgentTaskJob.tryParse(legacyImage)!.isCreatorImage, isTrue);
      expect(
        () => store.registerControls(
          AgentTaskExecutionKind.projectBuild,
          _Controls(),
        ),
        throwsStateError,
      );
      store.unregisterControls(
        AgentTaskExecutionKind.projectBuild,
        _Controls(),
      );
      expect(store.controlsFor(project), same(projectControls));
      store.unregisterControls(
        AgentTaskExecutionKind.projectBuild,
        projectControls,
      );
      expect(store.controlsFor(project), isNull);
      expect(store.controlsFor(image), same(imageControls));
      await store.deactivateAndDrain();
      expect(store.controlsFor(image), isNull);
    },
  );

  test(
    'durable old-version command reattaches after journal advance and settles without a new nonce',
    () async {
      final repository = ProjectBuildRepository(
        database: database,
        scopeKey: projectBuildTestScope,
        isCurrent: () => true,
      );
      await repository.prepareCreate(
        projectBuildInput(),
        expectedScopeKey: projectBuildTestScope,
      );
      await repository.recordReceipt(
        projectBuildReceipt(),
        expectedScopeKey: projectBuildTestScope,
      );
      final events = projectBuildEvents();
      await repository.applyPage(
        projectBuildReceipt().taskId,
        projectBuildPage(events.take(2).toList()),
        expectedScopeKey: projectBuildTestScope,
      );
      final root = _start(store);
      _receipt(store, root);
      _apply(store, root.id, events[0]);
      final running = _apply(store, root.id, events[1]);
      final command = ProjectBuildCommand(
        operation: ProjectBuildOperation.cancel,
        requestId: 'original-durable-cancel',
        expectedRunId: running.projectBuild!.snapshot!.runId,
        expectedStatusVersion: running.projectBuild!.snapshot!.statusVersion,
      );
      await repository.prepareCommand(
        projectBuildReceipt().taskId,
        command,
        expectedScopeKey: projectBuildTestScope,
      );
      final cancelling = {
        ...events[2],
        'type': 'run.cancel_requested',
        'snapshot': {
          ...projectBuildObject(events[2]['snapshot']),
          'status': 'cancelling',
          'errorCode': '',
        },
      };
      await repository.applyPage(
        projectBuildReceipt().taskId,
        projectBuildPage([cancelling], after: 2),
        expectedScopeKey: projectBuildTestScope,
      );
      final advanced = _apply(store, root.id, cancelling);
      expect(
        advanced.projectBuild!.snapshot!.statusVersion,
        greaterThan(command.expectedStatusVersion),
      );
      final pending = (await repository.pendingRequests(
        expectedScopeKey: projectBuildTestScope,
      )).single;
      final restored = store.restoreProjectBuildPendingCommand(
        root.id,
        pending,
        expectedScopeKey: _appletScope,
        expectedRepositoryScopeKey: projectBuildTestScope,
      );
      expect(
        restored.projectBuild!.pendingCommand!.requestId,
        command.requestId,
      );
      expect(
        restored.projectBuild!.pendingCommand!.expectedStatusVersion,
        command.expectedStatusVersion,
      );
      expect(restored.progress, hasLength(advanced.progress.length));
      final acknowledged = store.updateProjectBuildBinding(
        root.id,
        restored.projectBuild!.copyWith(
          pendingCommand: restored.projectBuild!.pendingCommand!.copyWith(
            acceptedTaskSequence: 3,
          ),
        ),
        expectedScopeKey: _appletScope,
      );
      final settled = store.updateProjectBuildBinding(
        root.id,
        acknowledged.projectBuild!.copyWith(clearPending: true),
        expectedScopeKey: _appletScope,
      );
      expect(settled.projectBuild!.pendingCommand, isNull);
      expect(settled.projectBuild!.appliedTaskSequence, 3);
      expect(settled.status, AgentTaskJobStatus.cancelling);
      expect(settled.progress, hasLength(advanced.progress.length));
    },
  );

  test(
    'durable pending request carries repository scope and cannot attach across accounts',
    () async {
      final root = _start(store);
      final other = ProjectBuildRepository(
        database: database,
        scopeKey: 'other|account',
        isCurrent: () => true,
      );
      await other.prepareCreate(
        projectBuildInput(),
        expectedScopeKey: 'other|account',
      );
      final foreign = (await other.pendingRequests(
        expectedScopeKey: 'other|account',
      )).single;
      expect(
        () => store.restoreProjectBuildPendingCommand(
          root.id,
          foreign,
          expectedScopeKey: _appletScope,
          expectedRepositoryScopeKey: projectBuildTestScope,
        ),
        throwsStateError,
      );
      expect(
        () => store.restoreProjectBuildPendingCommand(
          root.id,
          foreign,
          expectedScopeKey: _appletScope,
          expectedRepositoryScopeKey: 'other|account',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'disk reopen preserves event fingerprints and rejects fake completion',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'maaso-project-task-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/account.db';
      final firstDb = await DBService().init(
        factory: databaseFactoryIo,
        path: path,
      );
      final firstPersistence = SembastAgentTaskPersistence(firstDb);
      final firstStore = await AgentTaskJobStore(
        persistence: firstPersistence,
      ).init();
      final root = _start(firstStore);
      _receipt(firstStore, root);
      final queued = _apply(firstStore, root.id, projectBuildEvents().first);
      await firstStore.flush();
      await firstPersistence.writeJob(
        queued
            .copyWith(
              status: AgentTaskJobStatus.completed,
              stage: AgentTaskStage.completed,
            )
            .toJson(),
        firstStore.cardFor(queued),
      );
      await firstStore.deactivateAndDrain();
      await firstDb.close();
      final nextDb = await DBService().init(
        factory: databaseFactoryIo,
        path: path,
      );
      final nextStore = await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(nextDb),
      ).init();
      addTearDown(() async {
        await nextStore.deactivateAndDrain();
        await nextDb.close();
      });
      final restored = nextStore.byId(root.id)!;
      expect(restored.status, AgentTaskJobStatus.running);
      expect(
        restored.projectBuild!.snapshot!.status,
        ProjectBuildStatus.queued,
      );
      expect(restored.stage, AgentTaskStage.synchronizing);
      expect(restored.progress, hasLength(2));
      _apply(nextStore, root.id, projectBuildEvents().first);
      expect(nextStore.byId(root.id)!.progress, hasLength(2));
      expect(nextStore.byId(root.id)!.projectBuild!.appliedTaskSequence, 1);
    },
  );
}

class _Controls implements AgentServerTaskControls {
  @override
  bool canControl(AgentTaskJob job, {required bool retry}) => true;
  @override
  Future<bool> cancel(String jobId, {required int expectedAttempt}) async =>
      true;
  @override
  Future<bool> retry(String jobId, {required int expectedAttempt}) async =>
      true;
}
