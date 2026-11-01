import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_gateway.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_delete.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_head.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:sembast/sembast_memory.dart';

const scope = 'head|owner';
Map<String, Object?> f(String name) => projectBuildV2Object(
  jsonDecode(File('tool/fixtures/$name').readAsStringSync()),
);
Map<String, Object?> obj(Object? value) => projectBuildV2Object(value);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final h = f('project_head_v2_wire.json'),
      w = f('project_build_wire_v2.json'),
      i = f('project_build_inventory_wire_v2.json');
  final project = (obj(h['head2'])['projects']! as List).single as Map;
  final projectId = project['projectId']! as String;
  ProjectBuildV2OwnedRevisions history(int version, {bool fork = false}) {
    final all = obj(h['revisionsAfterFork']);
    final revision =
        (obj(h['head$version'])['projects']! as List).single as Map;
    final second = obj(h['secondRevisionDocument'])['revisionId'];
    final first = obj(h['firstRevisionDocument'])['revisionId'];
    return ProjectBuildV2OwnedRevisions.fromJson({
      ...all,
      'currentHeadVersion': version,
      'currentRevisionId': revision['currentRevisionId'],
      'revisions': (all['revisions']! as List)
          .where(
            (r) =>
                fork ||
                obj(r)['revisionId'] == first ||
                obj(r)['revisionId'] == second,
          )
          .toList(),
    });
  }

  late DBService db;
  late ProjectBuildV2Repository repo;
  bool current = true;
  setUp(() async {
    current = true;
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'head-${DateTime.now().microsecondsSinceEpoch}',
    );
    repo = ProjectBuildV2Repository(
      database: db,
      scopeKey: scope,
      isCurrent: () => current,
    );
  });
  tearDown(() => db.close());

  test(
    'Go head fixture accepts rollback and fork without rewriting signed bundle',
    () {
      final head = ProjectBuildV2OwnedProjects.fromJson(
        h['head3'],
      ).projects.single;
      expect(head.headVersion, 3);
      final dag = history(4, fork: true);
      expect(dag.revisions, hasLength(3));
      expect(
        dag.isAncestor(
          obj(h['firstRevisionDocument'])['revisionId']! as String,
          dag.currentRevisionId,
        ),
        isTrue,
      );
      for (final key in [
        'firstRevisionDocument',
        'secondRevisionDocument',
        'thirdRevisionDocument',
      ]) {
        final candidate = ProjectBuildV2Candidate.fromJson(obj(h[key]));
        expect(
          candidate.reference.baseHeadVersion,
          key == 'firstRevisionDocument'
              ? null
              : key == 'secondRevisionDocument'
              ? 1
              : 3,
        );
      }
      expect(
        ProjectBuildV2Receipt.fromJson(
          obj(h['thirdAcceptReceipt']),
        ).savedRevision!.headVersion,
        4,
      );
      expect(
        ProjectBuildV2DeleteReceipt.fromJson(h['deleteReceipt']).headVersion,
        5,
      );
    },
  );
  test(
    'counter is required, integral and bounded; stale bodies cannot be patched',
    () {
      final accept = obj(w['acceptRequest']);
      for (final value in [null, -1, 0.5, projectBuildV2MaximumSequence]) {
        expect(
          () => ProjectBuildV2Command.fromJson({
            ...accept,
            'expectedHeadVersion': value,
          }, operation: ProjectBuildV2Operation.accept),
          throwsFormatException,
        );
      }
      expect(
        () => ProjectBuildV2Command.fromJson(
          {...accept}..remove('expectedHeadVersion'),
          operation: ProjectBuildV2Operation.accept,
        ),
        throwsFormatException,
      );
      expect(
        () => ProjectBuildV2CreateRequest.fromJson({
          ...obj(w['createRequest']),
          'projectId': projectId,
          'baseRevision': project['currentRevisionId'],
        }),
        throwsFormatException,
      );
      final snap = obj(w['snapshot']);
      expect(
        () => ProjectBuildV2Snapshot.fromJson({
          ...snap,
          'savedRevision': {...obj(snap['savedRevision']), 'headVersion': 2},
        }),
        throwsFormatException,
      );
      expect(
        () => ProjectBuildV2OwnedRevisions.fromJson({
          ...history(4, fork: true).toJson(),
          'currentRevisionId':
              'pb_revision_00000000-0000-0000-0000-000000000099',
        }),
        throwsFormatException,
      );
      final bad = history(4, fork: true).toJson(),
          nodes = (bad['revisions']! as List).map(obj).toList();
      nodes[0]['baseRevision'] = nodes[0]['revisionId'];
      expect(
        () =>
            ProjectBuildV2OwnedRevisions.fromJson({...bad, 'revisions': nodes}),
        throwsFormatException,
      );
    },
  );
  test(
    'rollback intent replays nonce after restart and rejects ABA with same revision',
    () async {
      await repo.recordOwnedProjects(
        ProjectBuildV2OwnedProjects.fromJson(h['head2']),
        expectedScopeKey: scope,
      );
      await repo.recordOwnedRevisions(history(2), expectedScopeKey: scope);
      final request = ProjectBuildV2RollbackRequest.fromJson(
        h['rollbackRequest'],
      );
      await repo.prepareProjectRollback(
        projectId,
        request,
        expectedScopeKey: scope,
      );
      final restored = ProjectBuildV2Repository(
        database: db,
        scopeKey: scope,
        isCurrent: () => current,
      );
      expect(
        (await restored.pendingProjectRollbacks(
          expectedScopeKey: scope,
        )).single.request.toJson(),
        request.toJson(),
      );
      await restored.recordProjectRollbackReceipt(
        ProjectBuildV2RollbackReceipt.fromJson(h['rollbackReceipt']),
        expectedScopeKey: scope,
      );
      await restored.recordOwnedProjects(
        ProjectBuildV2OwnedProjects.fromJson(h['head3']),
        expectedScopeKey: scope,
      );
      await restored.recordOwnedRevisions(history(3), expectedScopeKey: scope);
      expect(
        (await restored.prepareProjectRollback(
          projectId,
          request,
          expectedScopeKey: scope,
        )).receipt!.headVersion,
        3,
      );
      await restored.finishProjectRollback(
        request.requestId,
        expectedScopeKey: scope,
      );
      await expectLater(
        restored.prepareProjectDeletion(
          projectId,
          ProjectBuildV2DeleteRequest(
            requestId: 'stale_delete_01',
            expectedRevision:
                obj(h['firstRevisionDocument'])['revisionId']! as String,
            expectedHeadVersion: 1,
          ),
          expectedScopeKey: scope,
        ),
        throwsStateError,
      );
      await expectLater(
        restored.recordOwnedProjects(
          ProjectBuildV2OwnedProjects.fromJson(h['head1']),
          expectedScopeKey: scope,
        ),
        throwsStateError,
      );
      expect(
        (await restored.ownedRevision(
          projectId,
          request.targetRevision,
          expectedScopeKey: scope,
        ))!.currentHeadVersion,
        3,
      );
    },
  );
  test(
    'delete receipt atomically erases journal/cards and fences late persisted writes',
    () async {
      final input = ProjectBuildV2CreateRequest.fromJson(
            obj(w['createRequest']),
          ),
          receipt = ProjectBuildV2Receipt.fromJson(obj(w['createReceipt']));
      await repo.prepareCreate(input, expectedScopeKey: scope);
      await repo.recordReceipt(receipt, expectedScopeKey: scope);
      final page = ProjectBuildV2EventPage.fromJson(
        obj(w['eventsPage']),
        taskId: receipt.taskId,
        afterTaskSequence: 0,
      );
      await repo.applyPage(receipt.taskId, page, expectedScopeKey: scope);
      await repo.recordOwnedProjects(
        ProjectBuildV2OwnedProjects.fromJson(i['projects']),
        expectedScopeKey: scope,
      );
      await repo.recordOwnedRevisions(
        ProjectBuildV2OwnedRevisions.fromJson(i['revisions']),
        expectedScopeKey: scope,
      );
      final persistence = SembastAgentTaskPersistence(db),
          jobs = await AgentTaskJobStore(persistence: persistence).init();
      final job = jobs.restoreProjectBuildV2(
        agentId: input.agentId,
        userText: input.requirements,
        appletScopeKey: scope,
        projectKind: input.projectKind,
        createdAt: DateTime.utc(2026),
        binding: ProjectBuildV2TaskBinding(
          scopeKey: scope,
          createRequestId: input.requestId,
          taskId: receipt.taskId,
        ),
      );
      for (final event in page.events) {
        jobs.applyProjectBuildV2Event(
          job.id,
          event,
          expectedScopeKey: scope,
          agentId: input.agentId,
        );
      }
      await jobs.flush();
      final late = jobs.jobs.last,
          saved = ProjectBuildV2Snapshot.fromJson(
            obj(w['snapshot']),
          ).savedRevision!;
      final request = ProjectBuildV2DeleteRequest(
        requestId: 'delete_original_01',
        expectedRevision: saved.revisionId,
        expectedHeadVersion: 1,
      );
      await repo.prepareProjectDeletion(
        saved.projectId,
        request,
        expectedScopeKey: scope,
      );
      final proof = await repo.recordProjectDeletionReceipt(
        ProjectBuildV2DeleteReceipt.fromJson({
          'requestId': request.requestId,
          'projectId': saved.projectId,
          'deletedRevisionId': saved.revisionId,
          'headVersion': 2,
          'deletedAt': '2026-09-30T00:00:00Z',
        }),
        expectedScopeKey: scope,
      );
      expect(await repo.list(expectedScopeKey: scope), isEmpty);
      await expectLater(
        repo.recordReceipt(receipt, expectedScopeKey: scope),
        throwsStateError,
      );
      final roots = await jobs.purgeProjectBuildV2(
        proof,
        expectedScopeKey: scope,
        expectedRepositoryScopeKey: scope,
      );
      expect(roots, contains(job.id));
      expect(jobs.isTaskDeleted(job.id, expectedScopeKey: scope), isTrue);
      expect(jobs.isTaskDeleted(job.id, expectedScopeKey: 'other'), isFalse);
      expect(
        await jobs.purgeProjectBuildV2(
          proof,
          expectedScopeKey: scope,
          expectedRepositoryScopeKey: scope,
        ),
        contains(job.id),
      );
      final reopened = await AgentTaskJobStore(persistence: persistence).init();
      expect(reopened.isTaskDeleted(job.id, expectedScopeKey: scope), isTrue);
      expect(
        await reopened.purgeProjectBuildV2(
          proof,
          expectedScopeKey: scope,
          expectedRepositoryScopeKey: scope,
        ),
        contains(job.id),
      );
      await reopened.deactivateAndDrain();
      expect(jobs.jobs, isEmpty);
      await persistence.writeJob(late.toJson(), jobs.cardFor(late));
      expect(await persistence.readJobs(), isEmpty);
      expect(await intMapStoreFactory.store('chat_messages').count(db.raw), 0);
      await repo.finishProjectDeletion(proof, expectedScopeKey: scope);
      expect(
        await repo.pendingProjectDeletions(expectedScopeKey: scope),
        isEmpty,
      );
      expect(
        (await repo.pendingProjectDeletions(
          expectedScopeKey: scope,
          includeCompleted: true,
        )).single.request.toJson(),
        request.toJson(),
      );
      current = false;
      expect(proof.isScopeCurrent, isFalse);
      await expectLater(
        persistence.purgeProjectBuildV2(
          proof,
          expectedScopeKey: scope,
          expectedRepositoryScopeKey: scope,
        ),
        throwsStateError,
      );
      await jobs.deactivateAndDrain();
    },
  );
  test(
    'legacy local rows are retained read-only and never become a new counter request',
    () async {
      final snapshot = obj(w['snapshot']);
      final legacy = {
        ...snapshot,
        'candidate': {...obj(snapshot['candidate'])}..remove('baseHeadVersion'),
        'savedRevision': {...obj(snapshot['savedRevision'])}
          ..remove('headVersion'),
      };
      final binding = ProjectBuildV2TaskBinding(
        scopeKey: scope,
        createRequestId: 'legacy_create_01',
        taskId: snapshot['taskId']! as String,
        snapshot: ProjectBuildV2Snapshot.fromJson(snapshot),
      );
      final raw = {...binding.toJson(), 'snapshot': legacy};
      final restored = ProjectBuildV2TaskBinding.fromJson(raw);
      expect(restored.isLegacyReadOnly, isTrue);
      expect(restored.snapshot, isNull);
      expect(
        obj(restored.toJson()['snapshot'])['candidate'],
        legacy['candidate'],
      );
      final body = {
        ...obj(w['createRequest']),
        'requestId': 'legacy_edit_01',
        'projectId': snapshot['projectId'],
        'baseRevision': obj(snapshot['candidate'])['revisionId'],
      };
      final store = stringMapStoreFactory.store('project_build_v2_intents');
      await store.record(jsonEncode([scope, body['requestId']])).put(db.raw, {
        'scopeKey': scope,
        'operation': 'create',
        'body': body,
      });
      expect(await repo.pendingRequests(expectedScopeKey: scope), isEmpty);
      expect(
        await repo.legacyCreateRequestIds(expectedScopeKey: scope),
        contains(body['requestId']),
      );
      expect((await store.find(db.raw)).single.value['body'], body);
    },
  );
  test(
    'gateway binds rollback/delete counters and body before accepting receipt',
    () async {
      final bodies = <Object?>[];
      var forge = false;
      final gateway = HttpProjectBuildV2Gateway(
        baseUri: () => Uri.parse('https://unit.invalid/'),
        contextKey: () => scope,
        accessToken: () async => 'test',
        isCurrent: () => true,
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body));
          final data = obj(
            h[request.url.path.endsWith('/delete')
                ? 'deleteReceipt'
                : 'rollbackReceipt'],
          );
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'message': '',
              'traceId': 'unit',
              'data': {...data, if (forge) 'headVersion': 1},
            }),
            200,
          );
        }),
      );
      final rollback = ProjectBuildV2RollbackRequest.fromJson(
        h['rollbackRequest'],
      );
      expect(
        (await gateway.rollbackProject(
          projectId: projectId,
          request: rollback,
          expectedContextKey: scope,
        )).headVersion,
        3,
      );
      expect(bodies.single, rollback.toJson());
      forge = true;
      await expectLater(
        gateway.deleteProject(
          projectId: projectId,
          request: ProjectBuildV2DeleteRequest.fromJson(h['deleteRequest']),
          expectedContextKey: scope,
        ),
        throwsA(isA<ProjectBuildV2RequestException>()),
      );
      await gateway.deactivateAndDrain();
    },
  );
}
