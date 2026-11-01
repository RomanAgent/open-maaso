import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:sembast/sembast_memory.dart';
import 'support/project_build_v2_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  late ProjectBuildV2Repository repo;
  late bool current;
  final taskId = projectBuildV2Receipt().taskId;
  setUp(() async {
    current = true;
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'project-build-${DateTime.now().microsecondsSinceEpoch}',
    );
    repo = ProjectBuildV2Repository(
      database: db,
      scopeKey: projectBuildV2TestScope,
      isCurrent: () => current,
    );
    await repo.prepareCreate(
      projectBuildV2Input(),
      expectedScopeKey: projectBuildV2TestScope,
    );
    await repo.recordReceipt(
      projectBuildV2Receipt(),
      expectedScopeKey: projectBuildV2TestScope,
    );
  });
  tearDown(() => db.close());

  test(
    'restart recovers exact unacknowledged request and queued projection',
    () async {
      final input = projectBuildV2Input();
      final pending = ProjectBuildV2CreateRequest(
        requestId: 'unacknowledged_0002',
        agentId: input.agentId,
        projectKind: input.projectKind,
        requirements: input.requirements,
        locale: 'zh-CN',
      );
      await repo.prepareCreate(
        pending,
        expectedScopeKey: projectBuildV2TestScope,
      );
      await repo.applyPage(
        taskId,
        projectBuildV2Page([projectBuildV2Events().first]),
        expectedScopeKey: projectBuildV2TestScope,
      );
      final restored = ProjectBuildV2Repository(
        database: db,
        scopeKey: projectBuildV2TestScope,
        isCurrent: () => true,
      );
      final pendingRequests = await restored.pendingRequests(
        expectedScopeKey: projectBuildV2TestScope,
      );
      expect(pendingRequests, hasLength(1));
      expect(pendingRequests.single.create!.toJson(), pending.toJson());
      final projects = await restored.list(
        expectedScopeKey: projectBuildV2TestScope,
      );
      expect(projects.single.snapshot!.status, ProjectBuildV2Status.queued);
      expect(projects.single.appliedTaskSequence, 1);
    },
  );

  test('initial journal run must match accepted create receipt', () async {
    final event = projectBuildV2Events().first;
    final foreign = {
      ...event,
      'runId': projectBuildV2OtherRun,
      'snapshot': {
        ...projectBuildV2Object(event['snapshot']),
        'runId': projectBuildV2OtherRun,
      },
    };
    await expectLater(
      repo.applyPage(
        taskId,
        projectBuildV2Page([foreign]),
        expectedScopeKey: projectBuildV2TestScope,
      ),
      throwsStateError,
    );
    expect(
      (await repo.read(
        taskId,
        expectedScopeKey: projectBuildV2TestScope,
      ))!.appliedTaskSequence,
      0,
    );
  });

  test('receipt and remote head never skip unconsumed journal', () async {
    var row = (await repo.read(
      taskId,
      expectedScopeKey: projectBuildV2TestScope,
    ))!;
    expect(row.appliedTaskSequence, 0);
    expect(row.snapshot, isNull);
    final head = ProjectBuildV2Snapshot.fromJson(
      projectBuildV2Object(projectBuildV2WireFixture()['snapshot']),
    );
    row = await repo.noteRemoteHead(
      head,
      expectedScopeKey: projectBuildV2TestScope,
    );
    expect(row.appliedTaskSequence, 0);
    expect(row.snapshot, isNull);
    row = await repo.applyPage(
      taskId,
      projectBuildV2Page(projectBuildV2Events()),
      expectedScopeKey: projectBuildV2TestScope,
    );
    expect(row.appliedTaskSequence, 3);
    expect(row.snapshot!.sameState(head), isTrue);
    expect(await db.getMessages('self'), isEmpty);
    final restored = ProjectBuildV2Repository(
      database: db,
      scopeKey: projectBuildV2TestScope,
      isCurrent: () => true,
    );
    expect(
      (await restored.read(
        taskId,
        expectedScopeKey: projectBuildV2TestScope,
      ))!.snapshot!.status,
      ProjectBuildV2Status.failed,
    );
  });

  test(
    'duplicate pages are idempotent but changed duplicate is rejected',
    () async {
      final events = projectBuildV2Events();
      final page = projectBuildV2Page(events.take(2).toList());
      await repo.applyPage(
        taskId,
        page,
        expectedScopeKey: projectBuildV2TestScope,
      );
      expect(
        (await repo.applyPage(
          taskId,
          page,
          expectedScopeKey: projectBuildV2TestScope,
        )).appliedTaskSequence,
        2,
      );
      final changed = {
        ...events[1],
        'snapshot': {
          ...projectBuildV2Object(events[1]['snapshot']),
          'statusVersion': 99,
        },
      };
      await expectLater(
        repo.applyPage(
          taskId,
          projectBuildV2Page([changed], after: 1),
          expectedScopeKey: projectBuildV2TestScope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.read(
          taskId,
          expectedScopeKey: projectBuildV2TestScope,
        ))!.appliedTaskSequence,
        2,
      );
    },
  );

  test(
    'bad second event rolls back whole page and gaps cannot fast forward',
    () async {
      final events = projectBuildV2Events();
      final bad = {
        ...events[1],
        'snapshot': {
          ...projectBuildV2Object(events[1]['snapshot']),
          'agentId': 'other_agent',
        },
      };
      await expectLater(
        repo.applyPage(
          taskId,
          projectBuildV2Page([events.first, bad]),
          expectedScopeKey: projectBuildV2TestScope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.read(
          taskId,
          expectedScopeKey: projectBuildV2TestScope,
        ))!.appliedTaskSequence,
        0,
      );
      await expectLater(
        repo.applyPage(
          taskId,
          projectBuildV2Page([events[2]], after: 2),
          expectedScopeKey: projectBuildV2TestScope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.applyPage(
          taskId,
          projectBuildV2Page(events),
          expectedScopeKey: projectBuildV2TestScope,
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
        projectBuildV2Page(projectBuildV2Events()),
        expectedScopeKey: projectBuildV2TestScope,
      );
      final command = ProjectBuildV2Command.fromJson(
        projectBuildV2Object(projectBuildV2WireFixture()['retryCommand']),
        operation: ProjectBuildV2Operation.retry,
      );
      await repo.prepareCommand(
        taskId,
        command,
        expectedScopeKey: projectBuildV2TestScope,
      );
      final receipt = ProjectBuildV2Receipt.fromJson({
        'requestId': command.requestId,
        'taskId': taskId,
        'runId': projectBuildV2OtherRun,
        'attempt': 2,
        'acceptedTaskSequence': 4,
      });
      final acknowledged = await repo.recordReceipt(
        receipt,
        expectedScopeKey: projectBuildV2TestScope,
      );
      expect(acknowledged.appliedTaskSequence, 3);
      expect(acknowledged.snapshot!.attempt, 1);
      final projected = await repo.applyPage(
        taskId,
        projectBuildV2Page([projectBuildV2RetryEvent()], after: 3),
        expectedScopeKey: projectBuildV2TestScope,
      );
      expect(projected.appliedTaskSequence, 4);
      expect(projected.snapshot!.snapshotSequence, 1);
      expect(projected.snapshot!.attempt, 2);
      // An acknowledged old create reply must not replace the newer receipt.
      expect(
        (await repo.recordReceipt(
          projectBuildV2Receipt(),
          expectedScopeKey: projectBuildV2TestScope,
        )).receipt.attempt,
        2,
      );
    },
  );

  test(
    'same nonce with changed input is rejected; no implicit new admission',
    () async {
      final input = projectBuildV2Input();
      await repo.prepareCreate(
        input,
        expectedScopeKey: projectBuildV2TestScope,
      );
      await expectLater(
        repo.prepareCreate(
          ProjectBuildV2CreateRequest(
            requestId: input.requestId,
            agentId: input.agentId,
            projectKind: input.projectKind,
            requirements: 'changed request',
            locale: input.locale,
          ),
          expectedScopeKey: projectBuildV2TestScope,
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
      final other = ProjectBuildV2Repository(
        database: db,
        scopeKey: 'test|other',
        isCurrent: () => true,
      );
      expect(await other.read(taskId, expectedScopeKey: 'test|other'), isNull);
      current = false;
      await expectLater(
        repo.applyPage(
          taskId,
          projectBuildV2Page(projectBuildV2Events()),
          expectedScopeKey: projectBuildV2TestScope,
        ),
        throwsStateError,
      );
      await expectLater(
        repo.read(taskId, expectedScopeKey: projectBuildV2TestScope),
        throwsStateError,
      );
    },
  );

  test(
    'account retirement inside transaction rolls back journal and cursor',
    () async {
      var checks = 0;
      final fenced = ProjectBuildV2Repository(
        database: db,
        scopeKey: projectBuildV2TestScope,
        isCurrent: () => ++checks < 3,
      );
      await expectLater(
        fenced.applyPage(
          taskId,
          projectBuildV2Page(projectBuildV2Events()),
          expectedScopeKey: projectBuildV2TestScope,
        ),
        throwsStateError,
      );
      expect(
        (await repo.read(
          taskId,
          expectedScopeKey: projectBuildV2TestScope,
        ))!.appliedTaskSequence,
        0,
      );
      expect(
        (await repo.applyPage(
          taskId,
          projectBuildV2Page(projectBuildV2Events()),
          expectedScopeKey: projectBuildV2TestScope,
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
          projectBuildV2Page(projectBuildV2Events()),
          expectedScopeKey: projectBuildV2TestScope,
        );
        final command = ProjectBuildV2Command.fromJson(
          projectBuildV2Object(projectBuildV2WireFixture()['retryCommand']),
          operation: ProjectBuildV2Operation.retry,
        );
        await repo.prepareCommand(
          taskId,
          command,
          expectedScopeKey: projectBuildV2TestScope,
        );
        final receipt = ProjectBuildV2Receipt.fromJson({
          'requestId': command.requestId,
          'taskId': taskId,
          'runId': projectBuildV2OtherRun,
          'attempt': 2,
          'acceptedTaskSequence': 4,
        });
        final correct = projectBuildV2RetryEvent();
        const differentRun = 'pb_run_00000000-0000-0000-0000-000000000005';
        final wrong = {
          ...correct,
          'runId': differentRun,
          'snapshot': {
            ...projectBuildV2Object(correct['snapshot']),
            'runId': differentRun,
          },
        };
        if (receiptFirst) {
          await repo.recordReceipt(
            receipt,
            expectedScopeKey: projectBuildV2TestScope,
          );
          await expectLater(
            repo.applyPage(
              taskId,
              projectBuildV2Page([wrong], after: 3),
              expectedScopeKey: projectBuildV2TestScope,
            ),
            throwsStateError,
          );
          expect(
            (await repo.read(
              taskId,
              expectedScopeKey: projectBuildV2TestScope,
            ))!.appliedTaskSequence,
            3,
          );
          await repo.applyPage(
            taskId,
            projectBuildV2Page([correct], after: 3),
            expectedScopeKey: projectBuildV2TestScope,
          );
        } else {
          await repo.applyPage(
            taskId,
            projectBuildV2Page([correct], after: 3),
            expectedScopeKey: projectBuildV2TestScope,
          );
          final badReceipt = ProjectBuildV2Receipt.fromJson({
            ...receipt.toJson(),
            'runId': differentRun,
          });
          await expectLater(
            repo.recordReceipt(
              badReceipt,
              expectedScopeKey: projectBuildV2TestScope,
            ),
            throwsStateError,
          );
          await repo.recordReceipt(
            receipt,
            expectedScopeKey: projectBuildV2TestScope,
          );
        }
        final projected = (await repo.read(
          taskId,
          expectedScopeKey: projectBuildV2TestScope,
        ))!;
        expect(projected.appliedTaskSequence, 4);
        expect(projected.receipt.runId, projected.snapshot!.runId);
        expect(
          await repo.pendingRequests(expectedScopeKey: projectBuildV2TestScope),
          isEmpty,
        );
      },
    );
  }
}
