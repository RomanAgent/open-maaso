import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_build_v2_fixtures.dart';
import 'support/creator_task_fixtures.dart' as creator;

const _appletScope = 'device-legacy';

ProjectBuildV2TaskBinding _binding({
  bool pending = true,
  String scope = projectBuildV2TestScope,
}) => ProjectBuildV2TaskBinding(
  scopeKey: scope,
  createRequestId: projectBuildV2Input().requestId,
  pendingCommand: pending
      ? ProjectBuildV2TaskPendingCommand(
          operation: ProjectBuildV2TaskOperation.create,
          requestId: projectBuildV2Input().requestId,
        )
      : null,
);

AgentTaskJob _start(AgentTaskJobStore store) => store.startProjectBuildV2(
  agentId: projectBuildV2Input().agentId,
  userText: projectBuildV2Input().requirements,
  appletScopeKey: _appletScope,
  projectKind: projectBuildV2Input().projectKind,
  binding: _binding(),
);

AgentTaskJob _receipt(AgentTaskJobStore store, AgentTaskJob job) =>
    store.updateProjectBuildV2Binding(
      job.id,
      job.projectBuildV2!.copyWith(
        taskId: projectBuildV2Receipt().taskId,
        pendingCommand: job.projectBuildV2!.pendingCommand!.copyWith(
          acceptedTaskSequence: 1,
        ),
      ),
      expectedScopeKey: _appletScope,
    );

AgentTaskJob _apply(
  AgentTaskJobStore store,
  String root,
  Map<String, Object?> raw,
) => store.applyProjectBuildV2Event(
  root,
  ProjectBuildV2Event.fromJson(raw),
  expectedScopeKey: _appletScope,
  agentId: projectBuildV2Input().agentId,
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
      expect(root.executionKind, AgentTaskExecutionKind.projectBuildV2);
      expect(root.isProjectBuildV2, isTrue);
      expect(root.isServerBacked, isTrue);
      expect(root.isCreatorImage, isFalse);
      expect(_start(store).id, root.id);
      final accepted = _receipt(store, root);
      expect(accepted.projectBuildV2!.appliedTaskSequence, 0);
      expect(accepted.stage, AgentTaskStage.synchronizing);
      expect(accepted.progress, hasLength(1));
      final first = ProjectBuildV2Event.fromJson(projectBuildV2Events().first);
      expect(
        () => store.updateProjectBuildV2Binding(
          root.id,
          accepted.projectBuildV2!.copyWith(
            snapshot: (first as ProjectBuildV2StateEvent).snapshot,
          ),
          expectedScopeKey: _appletScope,
        ),
        throwsStateError,
      );
      var current = accepted;
      for (final event in projectBuildV2Events()) {
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
        await database.getMessages(projectBuildV2Input().agentId),
        hasLength(1),
      );
    },
  );

  test(
    'same or old events are idempotent, conflicting duplicates and gaps are rejected',
    () {
      final root = _start(store);
      _receipt(store, root);
      final events = projectBuildV2Events();
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
      expect(store.byId(root.id)!.projectBuildV2!.appliedTaskSequence, 3);
    },
  );

  test(
    'retry creates a separate attempt with one card and independent run sequence',
    () async {
      final root = _start(store);
      _receipt(store, root);
      for (final event in projectBuildV2Events()) {
        _apply(store, root.id, event);
      }
      final failed = store.byId(root.id)!;
      final pending = ProjectBuildV2TaskPendingCommand(
        operation: ProjectBuildV2TaskOperation.retry,
        requestId: 'retry-original-request',
        expectedRunId: failed.projectBuildV2!.snapshot!.runId,
        expectedStatusVersion: failed.projectBuildV2!.snapshot!.statusVersion,
      );
      final preparing = store.updateProjectBuildV2Binding(
        root.id,
        failed.projectBuildV2!.copyWith(pendingCommand: pending),
        expectedScopeKey: _appletScope,
      );
      store.updateProjectBuildV2Binding(
        root.id,
        preparing.projectBuildV2!.copyWith(
          pendingCommand: pending.copyWith(acceptedTaskSequence: 4),
        ),
        expectedScopeKey: _appletScope,
      );
      final next = _apply(store, root.id, projectBuildV2RetryEvent());
      expect(next.id, isNot(root.id));
      expect(next.taskId, root.id);
      expect(next.attempt, 2);
      expect(next.projectBuildV2!.snapshot!.snapshotSequence, 1);
      expect(next.projectBuildV2!.appliedTaskSequence, 4);
      expect(next.projectBuildV2!.pendingCommand, isNull);
      expect(next.progress.map((event) => event.stage), [
        AgentTaskStage.queued,
      ]);
      expect(store.byId(root.id)!.status, AgentTaskJobStatus.failed);
      expect(store.byId(root.id)!.projectBuildV2!.pendingCommand, isNull);
      expect(store.isCurrentAttempt(root), isFalse);
      for (final event in [
        ...projectBuildV2Events(),
        projectBuildV2RetryEvent(),
      ]) {
        _apply(store, root.id, event);
      }
      expect(store.jobs, hasLength(2));
      await store.flush();
      expect(
        await database.getMessages(projectBuildV2Input().agentId),
        hasLength(1),
      );
      final restored = await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(database),
      ).init();
      addTearDown(restored.deactivateAndDrain);
      expect(restored.byId(next.id)!.projectBuildV2!.appliedTaskSequence, 4);
      expect(restored.byId(next.id)!.stage, AgentTaskStage.synchronizing);
      expect(restored.byId(next.id)!.progress, hasLength(1));
      expect(restored.byId(root.id)!.progress, hasLength(4));
    },
  );

  test(
    'restore can rebind the durable original create nonce without inventing progress',
    () async {
      final input = projectBuildV2Input();
      final root = store.restoreProjectBuildV2(
        agentId: input.agentId,
        userText: input.requirements,
        appletScopeKey: _appletScope,
        projectKind: input.projectKind,
        binding: _binding(pending: false),
        createdAt: DateTime.utc(2026, 9, 28),
      );
      expect(root.progress, isEmpty);
      final pending = store.updateProjectBuildV2Binding(
        root.id,
        _binding(),
        expectedScopeKey: _appletScope,
      );
      final accepted = _receipt(store, pending);
      expect(accepted.progress, isEmpty);
      final projected = _apply(store, root.id, projectBuildV2Events().first);
      expect(projected.progress.map((event) => event.stage), [
        AgentTaskStage.queued,
      ]);
      expect(projected.projectBuildV2!.pendingCommand, isNull);
      expect(
        () => store.restoreProjectBuildV2(
          agentId: input.agentId,
          userText: input.requirements,
          appletScopeKey: _appletScope,
          projectKind: input.projectKind,
          binding: projected.projectBuildV2!,
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
        () => store.updateProjectBuildV2Binding(
          root.id,
          accepted.projectBuildV2!,
          expectedScopeKey: 'other-applet',
        ),
        throwsStateError,
      );
      expect(
        () => store.updateProjectBuildV2Binding(
          root.id,
          ProjectBuildV2TaskBinding(
            scopeKey: 'other|account',
            createRequestId: root.projectBuildV2!.createRequestId,
          ),
          expectedScopeKey: _appletScope,
        ),
        throwsStateError,
      );
      expect(
        () => store.applyProjectBuildV2Event(
          root.id,
          ProjectBuildV2Event.fromJson(projectBuildV2Events().first),
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
        () => store.updateProjectBuildV2Binding(
          root.id,
          accepted.projectBuildV2!.copyWith(clearPending: true),
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
        ...root.projectBuildV2!.toJson(),
        'appliedTaskSequence': 99,
      };
      expect(
        () => ProjectBuildV2TaskBinding.fromJson(altered),
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
        AgentTaskExecutionKind.projectBuildV2,
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
          AgentTaskExecutionKind.projectBuildV2,
          _Controls(),
        ),
        throwsStateError,
      );
      store.unregisterControls(
        AgentTaskExecutionKind.projectBuildV2,
        _Controls(),
      );
      expect(store.controlsFor(project), same(projectControls));
      store.unregisterControls(
        AgentTaskExecutionKind.projectBuildV2,
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
      final repository = ProjectBuildV2Repository(
        database: database,
        scopeKey: projectBuildV2TestScope,
        isCurrent: () => true,
      );
      await repository.prepareCreate(
        projectBuildV2Input(),
        expectedScopeKey: projectBuildV2TestScope,
      );
      await repository.recordReceipt(
        projectBuildV2Receipt(),
        expectedScopeKey: projectBuildV2TestScope,
      );
      final events = projectBuildV2Events();
      await repository.applyPage(
        projectBuildV2Receipt().taskId,
        projectBuildV2Page(events.take(2).toList()),
        expectedScopeKey: projectBuildV2TestScope,
      );
      final root = _start(store);
      _receipt(store, root);
      _apply(store, root.id, events[0]);
      final running = _apply(store, root.id, events[1]);
      final command = ProjectBuildV2Command(
        operation: ProjectBuildV2Operation.cancel,
        requestId: 'original-durable-cancel',
        expectedRunId: running.projectBuildV2!.snapshot!.runId,
        expectedStatusVersion: running.projectBuildV2!.snapshot!.statusVersion,
      );
      await repository.prepareCommand(
        projectBuildV2Receipt().taskId,
        command,
        expectedScopeKey: projectBuildV2TestScope,
      );
      final cancelling = {
        ...events[2],
        'type': 'run.cancel_requested',
        'snapshot': {
          ...projectBuildV2Object(events[2]['snapshot']),
          'status': 'cancelling',
          'errorCode': '',
        },
      };
      await repository.applyPage(
        projectBuildV2Receipt().taskId,
        projectBuildV2Page([cancelling], after: 2),
        expectedScopeKey: projectBuildV2TestScope,
      );
      final advanced = _apply(store, root.id, cancelling);
      expect(
        advanced.projectBuildV2!.snapshot!.statusVersion,
        greaterThan(command.expectedStatusVersion),
      );
      final pending = (await repository.pendingRequests(
        expectedScopeKey: projectBuildV2TestScope,
      )).single;
      final restored = store.restoreProjectBuildV2PendingCommand(
        root.id,
        pending,
        expectedScopeKey: _appletScope,
        expectedRepositoryScopeKey: projectBuildV2TestScope,
      );
      expect(
        restored.projectBuildV2!.pendingCommand!.requestId,
        command.requestId,
      );
      expect(
        restored.projectBuildV2!.pendingCommand!.expectedStatusVersion,
        command.expectedStatusVersion,
      );
      expect(restored.progress, hasLength(advanced.progress.length));
      final acknowledged = store.updateProjectBuildV2Binding(
        root.id,
        restored.projectBuildV2!.copyWith(
          pendingCommand: restored.projectBuildV2!.pendingCommand!.copyWith(
            acceptedTaskSequence: 3,
          ),
        ),
        expectedScopeKey: _appletScope,
      );
      final settled = store.updateProjectBuildV2Binding(
        root.id,
        acknowledged.projectBuildV2!.copyWith(clearPending: true),
        expectedScopeKey: _appletScope,
      );
      expect(settled.projectBuildV2!.pendingCommand, isNull);
      expect(settled.projectBuildV2!.appliedTaskSequence, 3);
      expect(settled.status, AgentTaskJobStatus.cancelling);
      expect(settled.progress, hasLength(advanced.progress.length));
    },
  );

  test(
    'durable pending request carries repository scope and cannot attach across accounts',
    () async {
      final root = _start(store);
      final other = ProjectBuildV2Repository(
        database: database,
        scopeKey: 'other|account',
        isCurrent: () => true,
      );
      await other.prepareCreate(
        projectBuildV2Input(),
        expectedScopeKey: 'other|account',
      );
      final foreign = (await other.pendingRequests(
        expectedScopeKey: 'other|account',
      )).single;
      expect(
        () => store.restoreProjectBuildV2PendingCommand(
          root.id,
          foreign,
          expectedScopeKey: _appletScope,
          expectedRepositoryScopeKey: projectBuildV2TestScope,
        ),
        throwsStateError,
      );
      expect(
        () => store.restoreProjectBuildV2PendingCommand(
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
      final queued = _apply(firstStore, root.id, projectBuildV2Events().first);
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
        restored.projectBuildV2!.snapshot!.status,
        ProjectBuildV2Status.queued,
      );
      expect(restored.stage, AgentTaskStage.synchronizing);
      expect(restored.progress, hasLength(2));
      _apply(nextStore, root.id, projectBuildV2Events().first);
      expect(nextStore.byId(root.id)!.progress, hasLength(2));
      expect(nextStore.byId(root.id)!.projectBuildV2!.appliedTaskSequence, 1);
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
