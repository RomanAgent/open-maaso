import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace_persistence.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'draft checkpoint survives reopening without becoming a saved app',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'source-draft.db',
      );
      addTearDown(db.close);
      final store = SourceWorkspacePersistence(db);
      final snapshot = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest('完整的游戏要求'),
        experienceType: 'game',
      );
      await store.write(
        scopeKey: 'owner-a',
        jobId: 'job-a',
        attempt: 1,
        snapshot: snapshot,
        requireCurrent: () {},
      );
      final restored = await SourceWorkspacePersistence(db).read(
        scopeKey: 'owner-a',
        jobId: 'job-a',
        requirementSha256: snapshot.requirementSha256,
        requireCurrent: () {},
      );
      expect(restored!.toJson(), snapshot.toJson());
      expect(await db.getAllWidgets(), isEmpty);
      expect(
        await store.read(
          scopeKey: 'owner-b',
          jobId: 'job-a',
          requirementSha256: snapshot.requirementSha256,
          requireCurrent: () {},
        ),
        isNull,
      );
      expect(
        await store.read(
          scopeKey: 'owner-a',
          jobId: 'job-a',
          requirementSha256: sourceWorkspaceDigest('其他要求'),
          requireCurrent: () {},
        ),
        isNull,
      );
    },
  );

  test('older attempts and stale scopes cannot replace a draft', () async {
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'source-fences.db',
    );
    addTearDown(db.close);
    final store = SourceWorkspacePersistence(db);
    final snapshot = SourceWorkspaceSnapshot(
      requirementSha256: sourceWorkspaceDigest('游戏'),
      experienceType: 'game',
    );
    await store.write(
      scopeKey: 'owner-a',
      jobId: 'job-a',
      attempt: 2,
      snapshot: snapshot,
      requireCurrent: () {},
    );
    await expectLater(
      store.write(
        scopeKey: 'owner-a',
        jobId: 'job-a',
        attempt: 1,
        snapshot: snapshot,
        requireCurrent: () {},
      ),
      throwsA(isA<GeneratedTaskFailure>()),
    );
    await expectLater(
      store.write(
        scopeKey: 'owner-a',
        jobId: 'job-b',
        attempt: 1,
        snapshot: snapshot,
        requireCurrent: () => throw const GeneratedTaskFailure(
          GeneratedTaskFailureCode.interrupted,
        ),
      ),
      throwsA(isA<GeneratedTaskFailure>()),
    );
    expect(
      await store.read(
        scopeKey: 'owner-a',
        jobId: 'job-b',
        requirementSha256: snapshot.requirementSha256,
        requireCurrent: () {},
      ),
      isNull,
    );
  });

  test(
    'cancellation inside a draft transaction rolls back its write',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'source-transaction-cancel.db',
      );
      addTearDown(db.close);
      final store = SourceWorkspacePersistence(db);
      final snapshot = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest('保留完整要求'),
        experienceType: 'utility',
      );
      var checks = 0;
      await expectLater(
        store.write(
          scopeKey: 'owner-a',
          jobId: 'cancelled-job',
          attempt: 1,
          snapshot: snapshot,
          requireCurrent: () {
            checks++;
            // Before transaction, inside transaction, after read, after put.
            if (checks == 4) {
              throw const GeneratedTaskFailure(
                GeneratedTaskFailureCode.interrupted,
              );
            }
          },
        ),
        throwsA(isA<GeneratedTaskFailure>()),
      );
      expect(checks, 4);
      expect(
        await store.read(
          scopeKey: 'owner-a',
          jobId: 'cancelled-job',
          requirementSha256: snapshot.requirementSha256,
          requireCurrent: () {},
        ),
        isNull,
      );
    },
  );

  test(
    'unlimited production has no total deadline and keeps user wait handling',
    () async {
      final budget = GeneratedTaskBudget.unlimited();
      addTearDown(budget.close);
      expect(budget.hasDeadline, isFalse);
      expect(budget.isExpired, isFalse);
      expect(
        budget.requestTimeout(const Duration(minutes: 5)),
        const Duration(minutes: 5),
      );
      expect(() => budget.remaining, throwsStateError);
      budget.pauseForUser();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      budget.resume();
      budget.requireRemaining();
      expect(budget.isExpired, isFalse);
    },
  );
}
