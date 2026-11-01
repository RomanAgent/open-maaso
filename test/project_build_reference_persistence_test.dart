import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/project_build/data/project_build_reference_admission_store.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_delete.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_reference.dart';
import 'package:maaso/src/features/project_build/domain/project_reference_selection.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:sembast/sembast_io.dart';

const scope = 'https://reference.invalid|account';
const applet = 'test|account';

Map<String, Object?> fixture(String path) => projectBuildV2Object(
  jsonDecode(File('tool/fixtures/$path').readAsStringSync()),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final wire = fixture('project_build_wire_v2.json');
  final inventory = fixture('project_build_inventory_wire_v2.json');
  final draft = ProjectBuildV2CreateRequest.fromJson(
    projectBuildV2Object(wire['createRequest']),
  );
  final selection = ProjectReferenceSelection(
    scopeKey: applet,
    references: [
      ProjectReferenceImage(
        sha256: 'a' * 64,
        byteLength: 80,
        mime: 'image/jpeg',
        purpose: ProjectReferencePurpose.layout,
      ),
    ],
  );
  final receiptJSON = <String, Object?>{
    'schemaVersion': 2,
    'referenceId': 'ref_10000000-0000-4000-8000-000000000001',
    'originalSha256': 'a' * 64,
    'sha256': 'b' * 64,
    'byteLength': 80,
    'mediaType': 'image/jpeg',
    'width': 8,
    'height': 6,
    'expiresAt': '2026-10-02T00:00:00Z',
    'purpose': 'layout',
  };
  final receipt = ProjectBuildReferenceReceipt.fromJson(receiptJSON);
  late Directory directory;
  late DBService db;
  late ProjectBuildV2Repository repo;
  bool current = true;
  Future<void> open() async {
    db = await DBService().init(
      factory: databaseFactoryIo,
      path: '${directory.path}/references.db',
    );
    repo = ProjectBuildV2Repository(
      database: db,
      scopeKey: scope,
      isCurrent: () => current,
    );
  }

  Future<ProjectBuildReferenceAdmission> prepare() async {
    await repo.referenceAdmissions.saveSelection(
      selection,
      expectedAppletScopeKey: applet,
    );
    return repo.referenceAdmissions.prepare(draft, selection, [
      'fixed_upload_0001',
    ]);
  }

  setUp(() async {
    current = true;
    directory = await Directory.systemTemp.createTemp('maaso-reference-test-');
    await open();
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'real file restart keeps the exact upload and frozen create identities',
    () async {
      await prepare();
      await db.close();
      await open();
      final restored = (await repo.referenceAdmissions.pending()).single;
      expect(restored.uploadRequestIds, ['fixed_upload_0001']);
      expect(restored.selection.toJson(), selection.toJson());
      await repo.referenceAdmissions.recordReceipt(draft.requestId, 0, receipt);
      final frozen = await repo.referenceAdmissions.freeze(draft.requestId);
      await db.close();
      await open();
      final pending = (await repo.referenceAdmissions.pending()).single;
      expect(pending.frozenRequest!.toJson(), frozen.frozenRequest!.toJson());
      await repo.prepareCreate(pending.frozenRequest!, expectedScopeKey: scope);
      await repo.referenceAdmissions.markPrepared(draft.requestId);
      await db.close();
      await open();
      expect(await repo.referenceAdmissions.pending(), isEmpty);
      expect(
        (await repo.pendingRequests(
          expectedScopeKey: scope,
        )).single.create!.toJson(),
        frozen.frozenRequest!.toJson(),
      );
      final other = ProjectBuildReferenceAdmissionStore(
        database: db.raw,
        scopeKey: '$scope-other-environment',
        isCurrent: () => true,
      );
      expect(await other.read(draft.requestId), isNull);
      expect(await other.pending(), isEmpty);
      current = false;
      await expectLater(
        repo.referenceAdmissions.read(draft.requestId),
        throwsStateError,
      );
    },
  );

  test(
    'nonce purpose and receipt replacement cannot mutate a frozen request',
    () async {
      await prepare();
      final changed = ProjectReferenceSelection(
        scopeKey: applet,
        references: [
          ProjectReferenceImage(
            sha256: 'a' * 64,
            byteLength: 80,
            mime: 'image/jpeg',
            purpose: ProjectReferencePurpose.asset,
          ),
        ],
      );
      await repo.referenceAdmissions.saveSelection(
        changed,
        expectedAppletScopeKey: applet,
      );
      await expectLater(
        repo.referenceAdmissions.prepare(draft, changed, ['fixed_upload_0001']),
        throwsStateError,
      );
      await expectLater(
        repo.referenceAdmissions.recordReceipt(
          draft.requestId,
          0,
          ProjectBuildReferenceReceipt.fromJson({
            ...receiptJSON,
            'purpose': 'asset',
          }),
        ),
        throwsStateError,
      );
      expect(
        (await repo.referenceAdmissions.read(draft.requestId))!.receipts.single,
        isNull,
      );
      await repo.referenceAdmissions.recordReceipt(draft.requestId, 0, receipt);
      final frozen = await repo.referenceAdmissions.freeze(draft.requestId);
      await expectLater(
        repo.referenceAdmissions.recordReceipt(
          draft.requestId,
          0,
          ProjectBuildReferenceReceipt.fromJson({
            ...receiptJSON,
            'sha256': 'c' * 64,
          }),
        ),
        throwsStateError,
      );
      expect(
        (await repo.referenceAdmissions.read(
          draft.requestId,
        ))!.frozenRequest!.toJson(),
        frozen.frozenRequest!.toJson(),
      );
    },
  );

  test(
    'deleted project removes its admission metadata while shared chat media stays',
    () async {
      await prepare();
      await repo.referenceAdmissions.recordReceipt(draft.requestId, 0, receipt);
      final frozen = await repo.referenceAdmissions.freeze(draft.requestId);
      await repo.prepareCreate(frozen.frozenRequest!, expectedScopeKey: scope);
      final accepted = ProjectBuildV2Receipt.fromJson(
        projectBuildV2Object(wire['createReceipt']),
      );
      await repo.recordReceipt(accepted, expectedScopeKey: scope);
      await repo.applyPage(
        accepted.taskId,
        ProjectBuildV2EventPage.fromJson(
          projectBuildV2Object(wire['eventsPage']),
          taskId: accepted.taskId,
          afterTaskSequence: 0,
        ),
        expectedScopeKey: scope,
      );
      await repo.recordOwnedProjects(
        ProjectBuildV2OwnedProjects.fromJson(inventory['projects']),
        expectedScopeKey: scope,
      );
      await repo.recordOwnedRevisions(
        ProjectBuildV2OwnedRevisions.fromJson(inventory['revisions']),
        expectedScopeKey: scope,
      );
      final saved = ProjectBuildV2Snapshot.fromJson(
        projectBuildV2Object(wire['snapshot']),
      ).savedRevision!;
      final delete = ProjectBuildV2DeleteRequest(
        requestId: 'delete_reference_01',
        expectedRevision: saved.revisionId,
        expectedHeadVersion: 1,
      );
      await repo.prepareProjectDeletion(
        saved.projectId,
        delete,
        expectedScopeKey: scope,
      );
      final proof = await repo.recordProjectDeletionReceipt(
        ProjectBuildV2DeleteReceipt.fromJson({
          'requestId': delete.requestId,
          'projectId': saved.projectId,
          'deletedRevisionId': saved.revisionId,
          'headVersion': 2,
          'deletedAt': '2026-10-01T00:00:00Z',
        }),
        expectedScopeKey: scope,
      );
      final chat = stringMapStoreFactory.store('unrelated_chat_media_fixture');
      await chat.record('keep').put(db.raw, {'original': true});
      await repo.referenceAdmissions.purge(proof);
      expect(await repo.referenceAdmissions.read(draft.requestId), isNull);
      expect(
        await stringMapStoreFactory
            .store('project_build_reference_selections.v1')
            .count(db.raw),
        0,
      );
      expect(await chat.record('keep').get(db.raw), {'original': true});
      await db.close();
      await open();
      expect(await repo.referenceAdmissions.pending(), isEmpty);
      await expectLater(
        repo.prepareCreate(frozen.frozenRequest!, expectedScopeKey: scope),
        throwsStateError,
      );
    },
  );

  test(
    'legacy missing purpose remains missing and malformed new receipts are refused',
    () {
      final legacy = {...receiptJSON}..remove('purpose');
      expect(
        ProjectBuildReferenceReceipt.fromJson(
          legacy,
        ).toJson().containsKey('purpose'),
        isFalse,
      );
      expect(
        ProjectBuildReferenceInput.fromJson({
          'referenceId': receipt.referenceId,
          'sha256': receipt.sha256,
        }).toJson().containsKey('purpose'),
        isFalse,
      );
      for (final bad in [
        {...receiptJSON, 'purpose': null},
        {...receiptJSON, 'purpose': 'publish'},
        {...receiptJSON, 'schemaVersion': 2.0},
        {...receiptJSON, 'byteLength': 2 * 1024 * 1024 + 1},
        {...receiptJSON, 'width': 4097},
      ]) {
        expect(
          () => ProjectBuildReferenceReceipt.fromJson(bad),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'delete before reference freeze fences old cards late receipts and future drafts',
    () async {
      final projects = ProjectBuildV2OwnedProjects.fromJson(
        inventory['projects'],
      );
      final project = projects.projects.single;
      await repo.recordOwnedProjects(projects, expectedScopeKey: scope);
      await repo.recordOwnedRevisions(
        ProjectBuildV2OwnedRevisions.fromJson(inventory['revisions']),
        expectedScopeKey: scope,
      );
      await prepare(); // Independent new-project draft shares the source selection.
      final editing = ProjectBuildV2CreateRequest.fromJson({
        ...draft.toJson(),
        'requestId': 'edit_before_upload_01',
        'projectId': project.projectId,
        'baseRevision': project.currentRevisionId,
        'baseHeadVersion': project.headVersion,
      });
      await repo.referenceAdmissions.prepare(editing, selection, [
        'editing_upload_01',
      ]);
      final binding = ProjectBuildV2TaskBinding(
        scopeKey: scope,
        createRequestId: editing.requestId,
        referenceSelectionDigest: selection.sourceIdentityDigest,
        pendingCommand: ProjectBuildV2TaskPendingCommand(
          operation: ProjectBuildV2TaskOperation.create,
          requestId: editing.requestId,
        ),
      );
      final jobs = await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(db),
      ).init();
      final job = jobs.startProjectBuildV2(
        agentId: editing.agentId,
        userText: editing.requirements,
        appletScopeKey: applet,
        projectKind: editing.projectKind,
        binding: binding,
      );
      await jobs.flush();
      final delete = ProjectBuildV2DeleteRequest(
        requestId: 'delete_before_freeze',
        expectedRevision: project.currentRevisionId,
        expectedHeadVersion: project.headVersion,
      );
      await repo.prepareProjectDeletion(
        project.projectId,
        delete,
        expectedScopeKey: scope,
      );
      final proof = await repo.recordProjectDeletionReceipt(
        ProjectBuildV2DeleteReceipt.fromJson({
          'requestId': delete.requestId,
          'projectId': project.projectId,
          'deletedRevisionId': project.currentRevisionId,
          'headVersion': project.headVersion + 1,
          'deletedAt': '2026-10-01T00:00:00Z',
        }),
        expectedScopeKey: scope,
      );
      expect(proof.createRequestIds, contains(editing.requestId));
      // The metadata cleanup has not run yet; the durable tombstone already wins.
      expect(
        (await repo.referenceAdmissions.pending()).map((a) => a.requestId),
        [draft.requestId],
      );
      await expectLater(
        repo.referenceAdmissions.assertDispatchable(editing.requestId),
        throwsStateError,
      );
      await expectLater(
        repo.referenceAdmissions.recordReceipt(editing.requestId, 0, receipt),
        throwsStateError,
      );
      final removed = await jobs.purgeProjectBuildV2(
        proof,
        expectedScopeKey: applet,
        expectedRepositoryScopeKey: scope,
      );
      expect(removed, contains(job.id));
      expect(
        () => jobs.startProjectBuildV2(
          agentId: editing.agentId,
          userText: editing.requirements,
          appletScopeKey: applet,
          projectKind: editing.projectKind,
          binding: binding,
        ),
        throwsStateError,
      );
      await repo.referenceAdmissions.purge(proof);
      expect(
        await stringMapStoreFactory
            .store('project_build_reference_selections.v1')
            .count(db.raw),
        1,
      );
      await jobs.deactivateAndDrain();
      await db.close();
      await open();
      expect(
        (await repo.referenceAdmissions.pending()).map((a) => a.requestId),
        [draft.requestId],
      );
      await expectLater(
        repo.referenceAdmissions.prepare(editing, selection, [
          'editing_upload_01',
        ]),
        throwsStateError,
      );
      final freshEdit = ProjectBuildV2CreateRequest.fromJson({
        ...editing.toJson(),
        'requestId': 'new_nonce_after_delete',
      });
      await expectLater(
        repo.referenceAdmissions.prepare(freshEdit, selection, [
          'later_upload_01',
        ]),
        throwsStateError,
      );
      final restoredJobs = await AgentTaskJobStore(
        persistence: SembastAgentTaskPersistence(db),
      ).init();
      expect(restoredJobs.jobs, isEmpty);
      expect(
        restoredJobs.isTaskDeleted(job.id, expectedScopeKey: applet),
        isTrue,
      );
      await restoredJobs.deactivateAndDrain();
    },
  );

  test(
    'shared Go legacy and purpose fixtures preserve exact create identity and digest',
    () {
      for (final name in [
        'project_reference_wire_v2.json',
        'project_reference_purpose_wire_v2.json',
      ]) {
        final f = fixture(name);
        final request = ProjectBuildV2CreateRequest.fromJson(
          projectBuildV2Object(f['createRequest']),
        );
        final received = ProjectBuildReferenceReceipt.fromJson(
          f['uploadReceipt'],
        );
        expect(request.toJson(), f['createRequest']);
        expect(
          request.referenceInputs.single.toJson(),
          received.input.toJson(),
        );
        final canonical = const ProjectJsonCanonicalizer().canonicalBytes({
          'requirements': request.requirements,
          'locale': request.locale,
          'projectKind': request.projectKind.name,
          'referenceInputs': f['referenceDescriptors'],
        });
        expect(
          hashes.sha256.convert(canonical).toString(),
          f['requirementDigest'],
        );
      }
    },
  );
}
