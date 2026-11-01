import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/data/project_applet_action_journal.dart';
import 'package:sembast/sembast_memory.dart';
import 'project_bundle_deletion_test.dart' show deletionProof;
import 'support/project_bundle_v2_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var sequence = 0;
  test(
    'scoped deletion proof fences future writes and does not remove another project',
    () async {
      final db = await databaseFactoryMemory.openDatabase(
        'applet-journal-${sequence++}',
      );
      final bundle = productionBundleFixture();
      final journal = ProjectAppletActionJournal(
        database: db,
        scopeKey: 'storage',
        repositoryScopeKey: 'test|owner',
        processId: 'process',
        isCurrent: () => true,
      );
      Future<Object> reserve(String project, String request) => journal.reserve(
        projectId: project,
        candidateDigest: 'a' * 64,
        sessionId: 'session',
        controlEpoch: 1,
        requestId: request,
        actionId: 'app.set',
        identityDigest: 'b' * 64,
        canContinue: () => true,
      );
      await reserve(bundle.manifest.projectId, 'request_deleted');
      await reserve('retained', 'request_retained');
      final proof = await deletionProof(bundle);
      await journal.purgeDeletedProject(proof);
      expect(
        await journal.read(
          'session',
          'request_deleted',
          canContinue: () => true,
        ),
        isNull,
      );
      expect(
        await journal.read(
          'session',
          'request_retained',
          canContinue: () => true,
        ),
        isNotNull,
      );
      await expectLater(
        reserve(bundle.manifest.projectId, 'request_late'),
        throwsStateError,
      );
      await journal.purgeDeletedProject(proof);
      final wrong = ProjectAppletActionJournal(
        database: db,
        scopeKey: 'other-storage',
        repositoryScopeKey: 'test|different-owner',
        processId: 'process',
        isCurrent: () => true,
      );
      await expectLater(wrong.purgeDeletedProject(proof), throwsStateError);
      await db.close();
    },
  );

  test(
    'pending capacity is bounded and terminal entries can be reclaimed',
    () async {
      final db = await databaseFactoryMemory.openDatabase(
        'applet-journal-${sequence++}',
      );
      final journal = ProjectAppletActionJournal(
        database: db,
        scopeKey: 'storage',
        repositoryScopeKey: 'test|owner',
        processId: 'process',
        isCurrent: () => true,
        maximumEntries: 16,
      );
      Future<Object> reserve(int index) => journal.reserve(
        projectId: 'project',
        candidateDigest: 'a' * 64,
        sessionId: 'session',
        controlEpoch: 1,
        requestId: 'request_$index',
        actionId: 'app.set',
        identityDigest: 'b' * 64,
        canContinue: () => true,
      );
      for (var index = 0; index < 16; index++) {
        await reserve(index);
      }
      await expectLater(reserve(16), throwsStateError);
      const receipt = {
        'requestId': 'request_0',
        'actionId': 'app.set',
        'status': 'applied',
        'stateVersion': 2,
      };
      await journal.settle(
        'session',
        'request_0',
        'b' * 64,
        receipt,
        canContinue: () => true,
      );
      await journal.settle(
        'session',
        'request_0',
        'b' * 64,
        receipt,
        canContinue: () => true,
      );
      await expectLater(
        journal.settle('session', 'request_0', 'b' * 64, {
          ...receipt,
          'status': 'failed',
        }, canContinue: () => true),
        throwsStateError,
      );
      await reserve(16);
      expect(
        await journal.read('session', 'request_0', canContinue: () => true),
        isNull,
      );
      expect(
        await journal.read('session', 'request_16', canContinue: () => true),
        isNotNull,
      );
      await db.close();
    },
  );
}
