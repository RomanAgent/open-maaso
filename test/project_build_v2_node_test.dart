import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_node.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';
import 'package:sembast/sembast_io.dart';

const scope = 'node-test|owner', outer = 'device-legacy';
Map<String, Object?> wire() => projectBuildV2Object(
  jsonDecode(
    File('tool/fixtures/project_build_node_wire_v2.json').readAsStringSync(),
  ),
);
List<Map<String, Object?>> events(Map<String, Object?> data) =>
    (projectBuildV2Object(data['eventsPage'])['events']! as List)
        .map(projectBuildV2Object)
        .toList();
ProjectBuildV2EventPage page(
  List<Map<String, Object?>> events, {
  int after = 0,
}) => ProjectBuildV2EventPage.fromJson(
  {
    'events': events,
    'nextTaskSequence': events.isEmpty ? after : events.last['taskSequence'],
    'hasMore': false,
  },
  taskId: projectBuildV2Object(wire()['snapshot'])['taskId']! as String,
  afterTaskSequence: after,
);
ProjectBuildV2Node node(
  String id, {
  String? parent,
  int revision = 1,
  String status = 'queued',
  List<String> dependencies = const [],
}) => ProjectBuildV2Node.fromJson({
  'nodeId': id,
  'parentId': parent,
  'dependencyIds': dependencies,
  'revision': revision,
  'status': status,
  'kind': 'tool',
  'title': 'Tool $id',
  'summary': '',
  'details': '',
  'evidence': [],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DBService db;
  late ProjectBuildV2Repository repo;
  late AgentTaskJobStore jobs;
  late AgentTaskJob job;
  late Map<String, Object?> fixture;
  late String taskId;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    directory = await Directory.systemTemp.createTemp('maaso-public-nodes-');
    db = await DBService().init(
      factory: databaseFactoryIo,
      path: '${directory.path}/account.db',
    );
    repo = ProjectBuildV2Repository(
      database: db,
      scopeKey: scope,
      isCurrent: () => true,
    );
    jobs = appServices.put(
      await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(db),
      ).init(),
    );
    fixture = wire();
    final input = ProjectBuildV2CreateRequest.fromJson(
      projectBuildV2Object(fixture['createRequest']),
    );
    final receipt = ProjectBuildV2Receipt.fromJson(
      projectBuildV2Object(fixture['createReceipt']),
    );
    taskId = receipt.taskId;
    await repo.prepareCreate(input, expectedScopeKey: scope);
    await repo.recordReceipt(receipt, expectedScopeKey: scope);
    job = jobs.startProjectBuildV2(
      agentId: input.agentId,
      userText: input.requirements,
      appletScopeKey: outer,
      projectKind: input.projectKind,
      binding: ProjectBuildV2TaskBinding(
        scopeKey: scope,
        createRequestId: input.requestId,
        taskId: null,
        pendingCommand: ProjectBuildV2TaskPendingCommand(
          operation: ProjectBuildV2TaskOperation.create,
          requestId: input.requestId,
        ),
      ),
    );
    jobs.updateProjectBuildV2Binding(
      job.id,
      job.projectBuildV2!.copyWith(taskId: taskId),
      expectedScopeKey: outer,
    );
    await jobs.flush();
  });
  tearDown(() async {
    await jobs.flush();
    await appServices.reset();
    await db.close();
    await directory.delete(recursive: true);
  });
  Future<void> project(
    List<Map<String, Object?>> entries, {
    int after = 0,
  }) async {
    await repo.applyPage(
      taskId,
      page(entries, after: after),
      expectedScopeKey: scope,
    );
    for (final entry in entries) {
      jobs.applyProjectBuildV2Event(
        job.taskId,
        ProjectBuildV2Event.fromJson(entry),
        expectedScopeKey: outer,
        agentId: 'self',
      );
    }
    await jobs.flush();
  }

  test(
    'mixed compact node golden replays actual headers and current DAG without snapshot nodes',
    () async {
      final stream = page(events(fixture));
      expect(stream.events.whereType<ProjectBuildV2NodeDelta>(), hasLength(6));
      for (final delta in stream.events.whereType<ProjectBuildV2NodeDelta>()) {
        expect(delta.toJson().containsKey('snapshot'), isFalse);
      }
      final head = ProjectBuildV2Snapshot.fromJson(
        projectBuildV2Object(fixture['snapshot']),
      );
      await repo.noteRemoteHead(head, expectedScopeKey: scope);
      expect(
        (await repo.read(taskId, expectedScopeKey: scope))!.appliedTaskSequence,
        0,
      );
      expect(
        (await repo.read(taskId, expectedScopeKey: scope))!.nodes,
        isEmpty,
      );
      await project(events(fixture));
      final persisted = (await repo.read(taskId, expectedScopeKey: scope))!;
      expect(persisted.nodes.map((n) => n.toJson()), fixture['expectedNodes']);
      expect(persisted.snapshot!.sameState(head), isTrue);
      final current = jobs.byId(job.id)!;
      expect(
        current.projectBuildV2!.nodes.map((n) => n.toJson()),
        fixture['expectedNodes'],
      );
      expect(current.status, AgentTaskJobStatus.completed);
      expect(current.progress.where((p) => p.nodeId != null), hasLength(6));
      expect(current.progress.every((p) => p.isValid), isTrue);
      final deltaHead = stream.events
          .take(6)
          .fold<ProjectBuildV2Snapshot?>(
            null,
            (previous, event) => event.resolveSnapshot(previous),
          )!;
      await repo.noteRemoteHead(deltaHead, expectedScopeKey: scope);
      final before = current.progress.length;
      await project(events(fixture));
      expect(jobs.byId(job.id)!.progress.length, before);
    },
  );
  test(
    'out of order node revision rolls back full transaction; duplicate payload conflict rejects',
    () async {
      final entries = events(fixture);
      final bad = projectBuildV2Object(entries[3]['node']);
      entries[3] = {
        ...entries[3],
        'node': {...bad, 'revision': 4},
      };
      await expectLater(
        repo.applyPage(
          taskId,
          page(entries.take(4).toList()),
          expectedScopeKey: scope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.read(taskId, expectedScopeKey: scope))!.appliedTaskSequence,
        0,
      );
      expect(
        (await repo.read(taskId, expectedScopeKey: scope))!.nodes,
        isEmpty,
      );
      await project(events(fixture));
      final duplicate = events(fixture);
      duplicate[3] = {
        ...duplicate[3],
        'node': {
          ...projectBuildV2Object(duplicate[3]['node']),
          'summary': 'changed duplicate',
        },
      };
      await expectLater(
        repo.applyPage(taskId, page(duplicate), expectedScopeKey: scope),
        throwsStateError,
      );
    },
  );
  test(
    'node header cannot change task state run attempt or claim receipt acceptance',
    () async {
      await project(events(fixture).take(2).toList());
      for (final mutation in [
        {'attempt': 2},
        {'statusVersion': 8},
        {'runId': 'pb_run_00000000-0000-0000-0000-000000000099'},
      ]) {
        await expectLater(
          repo.applyPage(
            taskId,
            page([
              {...events(fixture)[2], ...mutation},
            ], after: 2),
            expectedScopeKey: scope,
          ),
          throwsStateError,
        );
      }
      await repo.prepareCommand(
        taskId,
        ProjectBuildV2Command(
          operation: ProjectBuildV2Operation.cancel,
          requestId: 'cancel_node_boundary',
          expectedRunId: jobs.byId(job.id)!.projectBuildV2!.snapshot!.runId,
          expectedStatusVersion: 2,
        ),
        expectedScopeKey: scope,
      );
      await project(events(fixture).sublist(2, 4), after: 2);
      final receipt = ProjectBuildV2Receipt.fromJson({
        ...projectBuildV2Object(fixture['createReceipt']),
        'requestId': 'cancel_node_boundary',
        'acceptedTaskSequence': 3,
      });
      await expectLater(
        repo.recordReceipt(receipt, expectedScopeKey: scope),
        throwsStateError,
      );
    },
  );
  test(
    'file reopen preserves projection and bounded journal replay reconstructs a missing card',
    () async {
      await project(events(fixture).take(6).toList());
      await jobs.flush();
      await appServices.reset();
      await db.close();
      db = await DBService().init(
        factory: databaseFactoryIo,
        path: '${directory.path}/account.db',
      );
      repo = ProjectBuildV2Repository(
        database: db,
        scopeKey: scope,
        isCurrent: () => true,
      );
      jobs = appServices.put(
        await AgentTaskJobStore(
          persistence: SembastAgentTaskPersistence(db),
        ).init(),
      );
      expect(jobs.byId(job.id)!.projectBuildV2!.nodes, hasLength(2));
      final recovered = AgentTaskJobStore();
      final projection = (await repo.read(taskId, expectedScopeKey: scope))!;
      final root = recovered.restoreProjectBuildV2(
        agentId: 'self',
        userText: projection.input.requirements,
        appletScopeKey: outer,
        projectKind: projection.input.projectKind,
        createdAt: projection.snapshot!.createdAt,
        binding: ProjectBuildV2TaskBinding(
          scopeKey: scope,
          createRequestId: projection.input.requestId,
          taskId: taskId,
        ),
      );
      var cursor = 0;
      do {
        final chunk = await repo.readEvents(
          taskId,
          afterTaskSequence: cursor,
          limit: 2,
          expectedScopeKey: scope,
        );
        for (final event in chunk.events) {
          recovered.applyProjectBuildV2Event(
            root.id,
            event,
            expectedScopeKey: outer,
            agentId: 'self',
          );
        }
        cursor = chunk.nextTaskSequence;
        if (!chunk.hasMore) break;
      } while (true);
      expect(
        recovered.byId(root.id)!.projectBuildV2!.nodes.map((n) => n.toJson()),
        projection.nodes.map((n) => n.toJson()),
      );
      await project(events(fixture).skip(6).toList(), after: 6);
      expect(jobs.byId(job.id)!.projectBuildV2!.appliedTaskSequence, 10);
    },
  );
  test(
    'transport checkpoint cannot replace node projection without consumed deltas',
    () async {
      await project(events(fixture).take(4).toList());
      final current = jobs.byId(job.id)!;
      final binding = current.projectBuildV2!;
      final forged = ProjectBuildV2Node.fromJson({
        ...binding.nodes.single.toJson(),
        'summary': 'not from journal',
      });
      expect(
        () => jobs.updateProjectBuildV2Binding(
          job.id,
          binding.copyWith(nodes: [forged]),
          expectedScopeKey: outer,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'retry resets only current node projection while preserving previous attempt journal',
    () async {
      final all = events(fixture), previous = projectBuildV2Object(all[7]);
      final header = all
          .take(8)
          .map(ProjectBuildV2Event.fromJson)
          .fold<ProjectBuildV2Snapshot?>(null, (s, e) => e.resolveSnapshot(s))!;
      Map<String, Object?> state(
        int taskSequence,
        int sequence,
        int attempt,
        String run,
        String type,
        String status,
        int version,
      ) => {
        'taskSequence': taskSequence,
        'sequence': sequence,
        'taskId': taskId,
        'runId': run,
        'type': type,
        'at':
            '2026-09-28T08:00:${(taskSequence - 1).toString().padLeft(2, '0')}Z',
        'snapshot': {
          ...header.toJson(),
          'runId': run,
          'attempt': attempt,
          'status': status,
          'statusVersion': version,
          'snapshotSequence': sequence,
          'snapshotTaskSequence': taskSequence,
          'updatedAt':
              '2026-09-28T08:00:${(taskSequence - 1).toString().padLeft(2, '0')}Z',
          'errorCode': status == 'failed' ? 'worker_failed' : '',
        },
      };
      final run = previous['runId']! as String,
          newRun = 'pb_run_00000000-0000-0000-0000-000000000099';
      await project([
        ...all.take(8),
        state(9, 9, 1, run, 'run.failed', 'failed', 9),
      ]);
      await project([
        state(10, 1, 2, newRun, 'run.retried', 'queued', 1),
        state(11, 2, 2, newRun, 'run.claimed', 'running', 2),
      ], after: 9);
      final latest = jobs.latestForTask(
        job.taskId,
        appletScopeKey: outer,
        agentId: 'self',
      )!;
      expect(latest.attempt, 2);
      expect(latest.projectBuildV2!.nodes, isEmpty);
      expect(jobs.byId(job.id)!.projectBuildV2!.nodes, hasLength(2));
      expect(
        (await repo.read(taskId, expectedScopeKey: scope))!.nodes,
        isEmpty,
      );
      final delta = {
        ...all[2],
        'taskSequence': 12,
        'sequence': 3,
        'runId': newRun,
        'attempt': 2,
        'statusVersion': 3,
        'at': '2026-09-28T08:00:11Z',
      };
      await project([delta], after: 11);
      expect(
        (await repo.read(
          taskId,
          expectedScopeKey: scope,
        ))!.nodes.single.revision,
        1,
      );
    },
  );
  test(
    'full Unicode public details remain in node model while chat excerpts remain bounded',
    () async {
      final all = events(fixture),
          changed = projectBuildV2Object(all[2]['node']);
      final longTitle = List.filled(120, '😀').join(),
          details = List.filled(2048, '😀').join();
      final initial = {
        ...changed,
        'title': longTitle,
        'details': details,
        'evidence': [
          {'kind': 'validation', 'outcome': 'passed', 'label': longTitle},
        ],
      };
      await project([
        ...all.take(2),
        {...all[2], 'node': initial},
      ]);
      final latest = jobs.byId(job.id)!;
      expect(latest.projectBuildV2!.nodes.single.details, details);
      expect(latest.progress.last.isValid, isTrue);
      expect(latest.progress.last.description.length, lessThanOrEqualTo(160));
      expect(
        latest.progress.last.evidence.single.label.length,
        lessThanOrEqualTo(120),
      );
    },
  );
  test(
    'node topology depth state evidence and per-attempt budgets stay bounded',
    () {
      var nodes = <ProjectBuildV2Node>[];
      for (var i = 0; i < 8; i++) {
        nodes = applyProjectBuildV2Node(
          nodes,
          node('n$i', parent: i == 0 ? null : 'n${i - 1}'),
        );
      }
      expect(
        () => applyProjectBuildV2Node(nodes, node('n8', parent: 'n7')),
        throwsStateError,
      );
      expect(
        () => applyProjectBuildV2Node(
          nodes,
          node('unknown_dep', dependencies: ['missing']),
        ),
        throwsStateError,
      );
      expect(
        () => applyProjectBuildV2Node(
          nodes,
          node('n0', revision: 2, status: 'succeeded'),
        ),
        throwsStateError,
      );
      nodes = applyProjectBuildV2Node(
        nodes,
        node('n0', revision: 2, status: 'running'),
      );
      nodes = applyProjectBuildV2Node(
        nodes,
        node('n0', revision: 3, status: 'failed'),
      );
      expect(
        () => applyProjectBuildV2Node(
          nodes,
          node('n0', revision: 4, status: 'running'),
        ),
        throwsStateError,
      );
      var bounded = <ProjectBuildV2Node>[];
      for (var i = 0; i < 120; i++) {
        bounded = applyProjectBuildV2Node(bounded, node('node$i'));
      }
      expect(
        () => applyProjectBuildV2Node(bounded, node('node120')),
        throwsStateError,
      );
      expect(
        () => ProjectBuildV2Node.fromJson({
          ...node('x').toJson(),
          'title': '   ',
        }),
        throwsFormatException,
      );
      expect(
        () => ProjectBuildV2Node.fromJson({
          ...node('x').toJson(),
          'details': 'raw\ncontrol',
        }),
        throwsFormatException,
      );
      expect(
        () => ProjectBuildV2Node.fromJson({
          ...node('x').toJson(),
          'evidence': [
            {
              'kind': 'validation',
              'outcome': 'passed',
              'label': 'ok',
              'count': null,
            },
          ],
        }),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'DAG shows parent hierarchy and public real-revision detail history',
    (tester) async {
      await tester.runAsync(() => project(events(fixture)));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentTaskChatCard(
              reference: jobs.cardFor(job).taskReference!,
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看生成过程'));
      await tester.pumpAndSettle();
      final compile = find.byKey(
        ValueKey('task-node-toggle-${job.id}:compile'),
      );
      await tester.scrollUntilVisible(
        compile,
        160,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Compile offline project'), findsOneWidget);
      await Scrollable.ensureVisible(tester.element(compile), alignment: 0.4);
      await tester.pumpAndSettle();
      await tester.tap(compile);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('task-node-details-${job.id}:compile')),
        findsOneWidget,
      );
      expect(find.textContaining('Compile checks'), findsWidgets);
      expect(
        jobs
            .byId(job.id)!
            .progress
            .where((p) => p.nodeId == 'compile')
            .map((p) => p.nodeStatus),
        ['queued', 'running', 'succeeded'],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
