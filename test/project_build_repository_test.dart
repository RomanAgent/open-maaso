import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/project_build/data/project_build_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';
import 'package:sembast/sembast_memory.dart';
import 'support/project_build_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  late ProjectBuildRepository repo;
  late bool current;
  final taskId = projectBuildReceipt().taskId;
  setUp(() async {
    current = true;
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'project-build-${DateTime.now().microsecondsSinceEpoch}',
    );
    repo = ProjectBuildRepository(
      database: db,
      scopeKey: projectBuildTestScope,
      isCurrent: () => current,
    );
    await repo.prepareCreate(
      projectBuildInput(),
      expectedScopeKey: projectBuildTestScope,
    );
    await repo.recordReceipt(
      projectBuildReceipt(),
      expectedScopeKey: projectBuildTestScope,
    );
  });
  tearDown(() => db.close());

  test(
    'restart recovers exact unacknowledged request and queued projection',
    () async {
      final input = projectBuildInput();
      final pending = ProjectBuildCreateRequest(
        requestId: 'unacknowledged_0002',
        agentId: input.agentId,
        projectKind: input.projectKind,
        requirements: input.requirements,
        locale: 'zh-CN',
      );
      await repo.prepareCreate(
        pending,
        expectedScopeKey: projectBuildTestScope,
      );
      await repo.applyPage(
        taskId,
        projectBuildPage([projectBuildEvents().first]),
        expectedScopeKey: projectBuildTestScope,
      );
      final restored = ProjectBuildRepository(
        database: db,
        scopeKey: projectBuildTestScope,
        isCurrent: () => true,
      );
      final pendingRequests = await restored.pendingRequests(
        expectedScopeKey: projectBuildTestScope,
      );
      expect(pendingRequests, hasLength(1));
      expect(pendingRequests.single.create!.toJson(), pending.toJson());
      final projects = await restored.list(
        expectedScopeKey: projectBuildTestScope,
      );
      expect(projects.single.snapshot!.status, ProjectBuildStatus.queued);
      expect(projects.single.appliedTaskSequence, 1);
    },
  );

  test('initial journal run must match accepted create receipt', () async {
    final event = projectBuildEvents().first;
    final foreign = {
      ...event,
      'runId': projectBuildOtherRun,
      'snapshot': {
        ...projectBuildObject(event['snapshot']),
        'runId': projectBuildOtherRun,
      },
    };
    await expectLater(
      repo.applyPage(
        taskId,
        projectBuildPage([foreign]),
        expectedScopeKey: projectBuildTestScope,
      ),
      throwsStateError,
    );
    expect(
      (await repo.read(
        taskId,
        expectedScopeKey: projectBuildTestScope,
      ))!.appliedTaskSequence,
      0,
    );
  });

  test('receipt and remote head never skip unconsumed journal', () async {
    var row = (await repo.read(
      taskId,
      expectedScopeKey: projectBuildTestScope,
    ))!;
    expect(row.appliedTaskSequence, 0);
    expect(row.snapshot, isNull);
    final head = ProjectBuildSnapshot.fromJson(
      projectBuildObject(projectBuildWireFixture()['snapshot']),
    );
    row = await repo.noteRemoteHead(
      head,
      expectedScopeKey: projectBuildTestScope,
    );
    expect(row.appliedTaskSequence, 0);
    expect(row.snapshot, isNull);
    row = await repo.applyPage(
      taskId,
      projectBuildPage(projectBuildEvents()),
      expectedScopeKey: projectBuildTestScope,
    );
    expect(row.appliedTaskSequence, 3);
    expect(row.snapshot!.sameState(head), isTrue);
    expect(await db.getMessages('self'), isEmpty);
    final restored = ProjectBuildRepository(
      database: db,
      scopeKey: projectBuildTestScope,
      isCurrent: () => true,
    );
    expect(
      (await restored.read(
        taskId,
        expectedScopeKey: projectBuildTestScope,
      ))!.snapshot!.status,
      ProjectBuildStatus.failed,
    );
  });

  test(
    'duplicate pages are idempotent but changed duplicate is rejected',
    () async {
      final events = projectBuildEvents();
      final page = projectBuildPage(events.take(2).toList());
      await repo.applyPage(
        taskId,
        page,
        expectedScopeKey: projectBuildTestScope,
      );
      expect(
        (await repo.applyPage(
          taskId,
          page,
          expectedScopeKey: projectBuildTestScope,
        )).appliedTaskSequence,
        2,
      );
      final changed = {
        ...events[1],
        'snapshot': {
          ...projectBuildObject(events[1]['snapshot']),
          'statusVersion': 99,
        },
      };
      await expectLater(
        repo.applyPage(
          taskId,
          projectBuildPage([changed], after: 1),
          expectedScopeKey: projectBuildTestScope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.read(
          taskId,
          expectedScopeKey: projectBuildTestScope,
        ))!.appliedTaskSequence,
        2,
      );
    },
  );

  test(
    'bad second event rolls back whole page and gaps cannot fast forward',
    () async {
      final events = projectBuildEvents();
      final bad = {
        ...events[1],
        'snapshot': {
          ...projectBuildObject(events[1]['snapshot']),
          'agentId': 'other_agent',
        },
      };
      await expectLater(
        repo.applyPage(
          taskId,
          projectBuildPage([events.first, bad]),
          expectedScopeKey: projectBuildTestScope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.read(
          taskId,
          expectedScopeKey: projectBuildTestScope,
        ))!.appliedTaskSequence,
        0,
      );
      await expectLater(
        repo.applyPage(
          taskId,
          projectBuildPage([events[2]], after: 2),
          expectedScopeKey: projectBuildTestScope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.applyPage(
          taskId,
          projectBuildPage(events),
          expectedScopeKey: projectBuildTestScope,
        )).appliedTaskSequence,
        3,
      );
    },
  );

  test(
    'retry receipt does not reset transport cursor; run sequence resets',
    () async {
      await repo.applyPage(
        taskId,
        projectBuildPage(projectBuildEvents()),
        expectedScopeKey: projectBuildTestScope,
      );
      final command = ProjectBuildCommand.fromJson(
        projectBuildObject(projectBuildWireFixture()['retryCommand']),
        operation: ProjectBuildOperation.retry,
      );
      await repo.prepareCommand(
        taskId,
        command,
        expectedScopeKey: projectBuildTestScope,
      );
      final receipt = ProjectBuildReceipt.fromJson({
        'requestId': command.requestId,
        'taskId': taskId,
        'runId': projectBuildOtherRun,
        'attempt': 2,
        'acceptedTaskSequence': 4,
      });
      final acknowledged = await repo.recordReceipt(
        receipt,
        expectedScopeKey: projectBuildTestScope,
      );
      expect(acknowledged.appliedTaskSequence, 3);
      expect(acknowledged.snapshot!.attempt, 1);
      final projected = await repo.applyPage(
        taskId,
        projectBuildPage([projectBuildRetryEvent()], after: 3),
        expectedScopeKey: projectBuildTestScope,
      );
      expect(projected.appliedTaskSequence, 4);
      expect(projected.snapshot!.snapshotSequence, 1);
      expect(projected.snapshot!.attempt, 2);
      // An acknowledged old create reply must not replace the newer receipt.
      expect(
        (await repo.recordReceipt(
          projectBuildReceipt(),
          expectedScopeKey: projectBuildTestScope,
        )).receipt.attempt,
        2,
      );
    },
  );

  test(
    'same nonce with changed input is rejected; no implicit new admission',
    () async {
      final input = projectBuildInput();
      await repo.prepareCreate(input, expectedScopeKey: projectBuildTestScope);
      await expectLater(
        repo.prepareCreate(
          ProjectBuildCreateRequest(
            requestId: input.requestId,
            agentId: input.agentId,
            projectKind: input.projectKind,
            requirements: 'changed request',
            locale: input.locale,
          ),
          expectedScopeKey: projectBuildTestScope,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'scope mismatch and retired mount cannot read or write a projection',
    () async {
      await expectLater(
        repo.read(taskId, expectedScopeKey: 'test|other'),
        throwsStateError,
      );
      final other = ProjectBuildRepository(
        database: db,
        scopeKey: 'test|other',
        isCurrent: () => true,
      );
      expect(await other.read(taskId, expectedScopeKey: 'test|other'), isNull);
      current = false;
      await expectLater(
        repo.applyPage(
          taskId,
          projectBuildPage(projectBuildEvents()),
          expectedScopeKey: projectBuildTestScope,
        ),
        throwsStateError,
      );
      await expectLater(
        repo.read(taskId, expectedScopeKey: projectBuildTestScope),
        throwsStateError,
      );
    },
  );

  test(
    'account retirement inside transaction rolls back journal and cursor',
    () async {
      var checks = 0;
      final fenced = ProjectBuildRepository(
        database: db,
        scopeKey: projectBuildTestScope,
        isCurrent: () => ++checks < 3,
      );
      await expectLater(
        fenced.applyPage(
          taskId,
          projectBuildPage(projectBuildEvents()),
          expectedScopeKey: projectBuildTestScope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.read(
          taskId,
          expectedScopeKey: projectBuildTestScope,
        ))!.appliedTaskSequence,
        0,
      );
      expect(
        (await repo.applyPage(
          taskId,
          projectBuildPage(projectBuildEvents()),
          expectedScopeKey: projectBuildTestScope,
        )).appliedTaskSequence,
        3,
      );
    },
  );
  for (final receiptFirst in [true, false]) {
    test(
      'receipt/event identity matches in either arrival order: receiptFirst=$receiptFirst',
      () async {
        await repo.applyPage(
          taskId,
          projectBuildPage(projectBuildEvents()),
          expectedScopeKey: projectBuildTestScope,
        );
        final command = ProjectBuildCommand.fromJson(
          projectBuildObject(projectBuildWireFixture()['retryCommand']),
          operation: ProjectBuildOperation.retry,
        );
        await repo.prepareCommand(
          taskId,
          command,
          expectedScopeKey: projectBuildTestScope,
        );
        final receipt = ProjectBuildReceipt.fromJson({
          'requestId': command.requestId,
          'taskId': taskId,
          'runId': projectBuildOtherRun,
          'attempt': 2,
          'acceptedTaskSequence': 4,
        });
        final correct = projectBuildRetryEvent();
        const differentRun = 'pb_run_00000000-0000-0000-0000-000000000005';
        final wrong = {
          ...correct,
          'runId': differentRun,
          'snapshot': {
            ...projectBuildObject(correct['snapshot']),
            'runId': differentRun,
          },
        };
        if (receiptFirst) {
          await repo.recordReceipt(
            receipt,
            expectedScopeKey: projectBuildTestScope,
          );
          await expectLater(
            repo.applyPage(
              taskId,
              projectBuildPage([wrong], after: 3),
              expectedScopeKey: projectBuildTestScope,
            ),
            throwsStateError,
          );
          expect(
            (await repo.read(
              taskId,
              expectedScopeKey: projectBuildTestScope,
            ))!.appliedTaskSequence,
            3,
          );
          await repo.applyPage(
            taskId,
            projectBuildPage([correct], after: 3),
            expectedScopeKey: projectBuildTestScope,
          );
        } else {
          await repo.applyPage(
            taskId,
            projectBuildPage([correct], after: 3),
            expectedScopeKey: projectBuildTestScope,
          );
          final badReceipt = ProjectBuildReceipt.fromJson({
            ...receipt.toJson(),
            'runId': differentRun,
          });
          await expectLater(
            repo.recordReceipt(
              badReceipt,
              expectedScopeKey: projectBuildTestScope,
            ),
            throwsStateError,
          );
          await repo.recordReceipt(
            receipt,
            expectedScopeKey: projectBuildTestScope,
          );
        }
        final projected = (await repo.read(
          taskId,
          expectedScopeKey: projectBuildTestScope,
        ))!;
        expect(projected.appliedTaskSequence, 4);
        expect(projected.receipt.runId, projected.snapshot!.runId);
        expect(
          await repo.pendingRequests(expectedScopeKey: projectBuildTestScope),
          isEmpty,
        );
      },
    );
  }
}
