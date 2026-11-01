import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_delete.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_bundle_install_authority.dart';
import 'support/project_bundle_v2_fixture.dart';

Future<ProjectBuildV2DeletionProof> deletionProof(
  ValidatedProjectBundleV2 bundle, {
  String scope = 'test|owner',
  int headVersion = 1,
  bool Function()? isCurrent,
}) async {
  final db = await DBService().init(
    factory: databaseFactoryMemory,
    path: 'delete-proof-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    final repo = ProjectBuildV2Repository(
      database: db,
      scopeKey: scope,
      isCurrent: isCurrent ?? () => true,
    );
    final proof = await testOwnedBundleProof(
      bundle,
      'a' * 64,
      scopeKey: scope,
      headVersion: headVersion,
    );
    await repo.recordOwnedProjects(
      ProjectBuildV2OwnedProjects.fromJson({
        'schemaVersion': 2,
        'projects': [proof.project.toJson()],
      }),
      expectedScopeKey: scope,
    );
    final request = ProjectBuildV2DeleteRequest(
      requestId: 'delete-fixture-0001',
      expectedRevision: bundle.manifest.revisionId,
      expectedHeadVersion: headVersion,
    );
    await repo.prepareProjectDeletion(
      bundle.manifest.projectId,
      request,
      expectedScopeKey: scope,
    );
    return await repo.recordProjectDeletionReceipt(
      ProjectBuildV2DeleteReceipt.fromJson({
        'requestId': request.requestId,
        'projectId': bundle.manifest.projectId,
        'deletedRevisionId': bundle.manifest.revisionId,
        'deletedAt': '2026-09-30T12:00:00Z',
        'headVersion': headVersion + 1,
      }),
      expectedScopeKey: scope,
    );
  } finally {
    await db.close();
  }
}

ValidatedProjectBundleV2 otherProject(ValidatedProjectBundleV2 bundle) {
  const nextId = 'pb_project_00000000-0000-0000-0000-000000000099';
  const json = ProjectJsonCanonicalizer();
  final bytes = {
    for (final entry in bundle.files.entries) entry.key: entry.value,
  };
  for (final path in ['project.json', 'routes.json', 'agent.protocol.json']) {
    final fields = {
      ...json.parseBytes(bytes[path]!)! as Map<String, Object?>,
      'projectId': nextId,
    };
    bytes[path] = json.canonicalBytes(fields);
  }
  final lines = utf8.decode(bytes['agent.md']!).split('\n');
  lines[1] = json.canonicalize({
    ...json.parse(lines[1])! as Map<String, Object?>,
    'projectId': nextId,
    'protocolSha256': projectBundleV2BytesDigest(bytes['agent.protocol.json']!),
  });
  bytes['agent.md'] = utf8.encode(lines.join('\n'));
  final files = [
    for (final file in bundle.manifest.files)
      ProjectBundleV2File(
        path: file.path,
        mimeType: file.mimeType,
        role: file.role,
        bytes: bytes[file.path]!,
      ),
  ];
  final old = bundle.manifest;
  return const ProjectBundleV2Codec().verify(
    ProjectBundleV2Manifest.create(
      projectId: nextId,
      revisionId: old.revisionId,
      contentManifestId: old.contentManifestId,
      requirementRevision: old.requirementRevision,
      requirementDigest: old.requirementDigest,
      baseRevision: old.baseRevision,
      projectKind: old.projectKind,
      files: files.map((file) => file.metadata),
    ),
    files,
  );
}

void main() {
  late Directory directory;
  late Database database;
  late ProjectBundleInstallationStore store;
  final account = AccountStorageScope(
    environmentKey: 'test',
    accountUuid: 'owner',
  );
  ProjectBundleInstallationStore mount() => ProjectBundleInstallationStore(
    database: database,
    accountScope: account,
    applicationSupportRoot: directory,
    projectBuildScopeKey: 'test|owner',
    isCurrent: () => true,
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bundle-delete-');
    database = await databaseFactoryIo.openDatabase('${directory.path}/db');
    store = mount();
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await database.close();
    await directory.delete(recursive: true);
  });
  Future<void> purge(ProjectBuildV2DeletionProof proof) =>
      store.purgeDeletedProject(
        proof,
        expectedScopeKey: store.scopeKey,
        expectedProjectBuildScopeKey: 'test|owner',
      );
  Future<File> blob(String digest) async =>
      (await directory
                  .list(recursive: true)
                  .where((file) => file.path.endsWith('/$digest'))
                  .toList())
              .single
          as File;

  test(
    'delete revokes before await, removes every local role, preserves shared blobs',
    () async {
      final bundle = productionBundleFixture(),
          other = otherProject(productionBundleFixture());
      final installed = await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      final retained = await store.stageCandidate(
        other,
        expectedScopeKey: store.scopeKey,
      );
      for (final role in ProjectBundleDataRole.values) {
        await store.saveApplicationData(
          bundle.candidateDigest,
          {'private': role.name},
          expectedScopeKey: store.scopeKey,
          role: role,
          expectedDataVersion: 0,
        );
      }
      final receipt = await deletionProof(bundle);
      final revoked = <String>[];
      final subscription = store.onProjectRevoked.listen(revoked.add);
      final pendingWrite = store.saveApplicationData(
        bundle.candidateDigest,
        {'late': true},
        expectedScopeKey: store.scopeKey,
        role: ProjectBundleDataRole.installed,
        expectedDataVersion: 1,
      );
      final writeExpectation = expectLater(pendingWrite, throwsStateError);
      final deleting = purge(receipt);
      expect(installed.isCurrent, isFalse);
      expect(retained.isCurrent, isTrue);
      expect(revoked, [bundle.manifest.projectId]);
      await deleting;
      await writeExpectation;
      await subscription.cancel();
      expect(
        await store.openCandidate(
          bundle.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ),
        isNull,
      );
      final rows = await stringMapStoreFactory
          .store('project_bundle_data.v1')
          .find(database);
      expect(rows, isEmpty);
      expect(
        (await store.openCandidate(
          other.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ))!.candidateDigest,
        other.candidateDigest,
      );
      final shared = bundle.manifest.files.singleWhere(
        (f) => f.path == 'assets/dot.png',
      );
      expect(
        await (await blob(shared.sha256)).readAsBytes(),
        bundle.files[shared.path],
      );
      await expectLater(
        store.stageCandidate(bundle, expectedScopeKey: store.scopeKey),
        throwsStateError,
      );
      await purge(receipt); // Original acknowledgement replay is harmless.
      await store.deactivateAndDrain();
      await database.close();
      database = await databaseFactoryIo.openDatabase('${directory.path}/db');
      store = mount();
      await expectLater(
        store.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: store.scopeKey,
        ),
        throwsStateError,
      );
      await expectLater(
        store.stageCandidate(bundle, expectedScopeKey: store.scopeKey),
        throwsStateError,
      );
      await purge(receipt);
    },
  );

  test(
    'failed file cleanup retains tombstone and replay resumes after restart',
    () async {
      final bundle = productionBundleFixture();
      await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      final digest = bundle.manifest.files
          .singleWhere((f) => f.path == 'assets/dot.png')
          .sha256;
      final file = await blob(digest);
      final unrelated = File('${directory.path}/unrelated');
      await unrelated.writeAsString('keep');
      await file.delete();
      await Link(file.path).create(unrelated.path);
      final receipt = await deletionProof(bundle);
      await expectLater(purge(receipt), throwsStateError);
      expect(await unrelated.readAsString(), 'keep');
      expect(
        await store.openCandidate(
          bundle.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ),
        isNull,
      );
      await store.deactivateAndDrain();
      await database.close();
      database = await databaseFactoryIo.openDatabase('${directory.path}/db');
      store = mount();
      await Link(file.path).delete();
      await purge(receipt);
      final rows = await stringMapStoreFactory
          .store('project_bundle_deleted.v2')
          .find(database);
      expect(rows.single.value['cleanupComplete'], isTrue);
      expect(rows.single.value['pendingBlobs'], isEmpty);
      expect(await unrelated.readAsString(), 'keep');
    },
  );

  test(
    'unrelated corrupt cache cannot prevent a durable deletion tombstone',
    () async {
      final bundle = productionBundleFixture(),
          other = otherProject(productionBundleFixture());
      await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      await store.stageCandidate(other, expectedScopeKey: store.scopeKey);
      final foreignRow = stringMapStoreFactory
          .store('project_bundle_installations.v2')
          .record(jsonEncode([store.scopeKey, other.candidateDigest]));
      final original = (await foreignRow.get(database))!;
      await foreignRow.put(database, {
        ...original,
        'manifest': <String, Object?>{},
      });
      final receipt = await deletionProof(bundle);
      await expectLater(purge(receipt), throwsFormatException);
      await store.deactivateAndDrain();
      await database.close();
      database = await databaseFactoryIo.openDatabase('${directory.path}/db');
      store = mount();
      await expectLater(
        store.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: store.scopeKey,
        ),
        throwsStateError,
      );
      await expectLater(
        store.openCandidate(
          bundle.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ),
        throwsStateError,
      );
      final tombstone =
          (await stringMapStoreFactory
                  .store('project_bundle_deleted.v2')
                  .find(database))
              .single
              .value;
      expect(tombstone['metadataComplete'], isFalse);
      await foreignRow.put(database, original);
      await purge(receipt);
      expect(
        await store.openCandidate(
          bundle.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ),
        isNull,
      );
      expect(
        (await store.openCandidate(
          other.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ))!.candidateDigest,
        other.candidateDigest,
      );
    },
  );

  test('foreign or retired proof cannot revoke a current package', () async {
    final bundle = productionBundleFixture();
    final installed = await testInstallBundle(
      store,
      bundle,
      expectedScopeKey: store.scopeKey,
      expectedCurrentCandidateDigest: null,
    );
    final foreign = await deletionProof(bundle, scope: 'test|someone-else');
    expect(() => purge(foreign), throwsStateError);
    expect(installed.isCurrent, isTrue);
    var live = true;
    final expired = await deletionProof(bundle, isCurrent: () => live);
    live = false;
    expect(() => purge(expired), throwsStateError);
    expect(installed.isCurrent, isTrue);
  });

  test(
    'an interrupted staging ledger owns its orphan blobs until deletion',
    () async {
      final bundle = productionBundleFixture(),
          other = otherProject(productionBundleFixture());
      await store.stageCandidate(other, expectedScopeKey: store.scopeKey);
      final asset = bundle.manifest.files.singleWhere(
        (f) => f.path == 'assets/dot.png',
      );
      final shared = await blob(asset.sha256);
      final unrelated = File('${directory.path}/untouched');
      await unrelated.writeAsString('private');
      await shared.delete();
      await Link(shared.path).create(unrelated.path);
      await expectLater(
        store.stageCandidate(bundle, expectedScopeKey: store.scopeKey),
        throwsStateError,
      );
      final staging = stringMapStoreFactory.store('project_bundle_staging.v2');
      expect(await staging.count(database), 1);
      final orphan = bundle.manifest.files.singleWhere(
        (f) => f.path == 'agent.md',
      );
      final orphanFile = await blob(orphan.sha256);
      expect(await orphanFile.exists(), isTrue);
      await Link(shared.path).delete();
      await shared.writeAsBytes(bundle.files[asset.path]!, flush: true);
      final receipt = await deletionProof(bundle);
      await purge(receipt);
      expect(await staging.count(database), 0);
      expect(await orphanFile.exists(), isFalse);
      expect(await shared.readAsBytes(), other.files[asset.path]);
      expect(await unrelated.readAsString(), 'private');
    },
  );
}
