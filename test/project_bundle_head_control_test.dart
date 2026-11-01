import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_bundle_install_authority.dart';
import 'support/project_bundle_v2_fixture.dart';
import 'support/project_bundle_verified_fixture.dart';

void main() {
  late Database database;
  late Directory directory;
  late ProjectBundleInstallationStore store;
  const repositoryScope = 'test|owner';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bundle-head-');
    database = await databaseFactoryMemory.openDatabase(directory.path);
    store = ProjectBundleInstallationStore(
      database: database,
      accountScope: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'owner',
      ),
      applicationSupportRoot: directory,
      projectBuildScopeKey: repositoryScope,
      isCurrent: () => true,
    );
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'A to B to A keeps bytes and saved data but rejects delayed controls',
    () async {
      final a = productionBundleFixture(),
          b = productionBundleFixture(revision: 3);
      final auth = await testBundlePermit(a);
      final proof1 = await testOwnedBundleProof(
        a,
        auth.permit.reportDigest,
        scopeKey: repositoryScope,
        headVersion: 1,
      );
      final proof3 = await testOwnedBundleProof(
        a,
        auth.permit.reportDigest,
        scopeKey: repositoryScope,
        headVersion: 3,
      );
      final first = await store.install(
        a,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
        expectedHeadVersion: null,
        expectedProjectBuildScopeKey: repositoryScope,
        ownedRevision: proof1,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      expect(first.headVersion, 1);
      await store.saveApplicationData(
        a.candidateDigest,
        {'saved': 'A'},
        expectedScopeKey: store.scopeKey,
        role: ProjectBundleDataRole.installed,
        expectedDataVersion: 0,
      );
      await testInstallBundle(
        store,
        b,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: a.candidateDigest,
        authoritativeHeadVersion: 2,
      );
      final back = await store.install(
        a,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: b.candidateDigest,
        expectedHeadVersion: 2,
        expectedProjectBuildScopeKey: repositoryScope,
        ownedRevision: proof3,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      expect(back.headVersion, 3);
      expect(back.candidateDigest, first.candidateDigest);
      expect(
        (await store.readApplicationData(
          a.candidateDigest,
          expectedScopeKey: store.scopeKey,
          role: ProjectBundleDataRole.installed,
        )).values,
        {'saved': 'A'},
      );
      await expectLater(
        store.install(
          a,
          expectedScopeKey: store.scopeKey,
          expectedCurrentCandidateDigest: a.candidateDigest,
          expectedHeadVersion: 3,
          expectedProjectBuildScopeKey: repositoryScope,
          ownedRevision: proof1,
          permit: auth.permit,
          verificationReport: auth.report,
        ),
        throwsStateError,
      );
      final proof4 = await testOwnedBundleProof(
        b,
        (await testBundlePermit(b)).permit.reportDigest,
        scopeKey: repositoryScope,
        headVersion: 4,
      );
      // Same source bytes have returned, but the old version-1 CAS must fail.
      final bAuth = await testBundlePermit(b);
      final next = await testOwnedBundleProof(
        b,
        bAuth.permit.reportDigest,
        scopeKey: repositoryScope,
        headVersion: proof4.currentHeadVersion,
      );
      await expectLater(
        store.install(
          b,
          expectedScopeKey: store.scopeKey,
          expectedCurrentCandidateDigest: a.candidateDigest,
          expectedHeadVersion: 1,
          expectedProjectBuildScopeKey: repositoryScope,
          ownedRevision: next,
          permit: bAuth.permit,
          verificationReport: bAuth.report,
        ),
        throwsStateError,
      );
      final replay = await store.install(
        a,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: b.candidateDigest,
        expectedHeadVersion: 2,
        expectedProjectBuildScopeKey: repositoryScope,
        ownedRevision: proof3,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      expect(replay.headVersion, 3);
      expect(
        (await store.openCandidate(
          a.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ))!.headVersion,
        isNull,
      );
    },
  );

  test(
    'legacy missing counter remains readable and only same owned head may adopt',
    () async {
      final bundle = productionBundleFixture();
      final auth = await testBundlePermit(bundle);
      final proof = await testOwnedBundleProof(
        bundle,
        auth.permit.reportDigest,
        scopeKey: repositoryScope,
        headVersion: 7,
      );
      await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
        authoritativeHeadVersion: 7,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      final record = stringMapStoreFactory
          .store('project_bundle_current.v2')
          .record(jsonEncode([store.scopeKey, bundle.manifest.projectId]));
      final original = (await record.get(database))!;
      await record.put(database, {...original}..remove('headVersion'));
      expect(
        (await store.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: store.scopeKey,
        ))!.headVersion,
        isNull,
      );
      await expectLater(
        store.install(
          bundle,
          expectedScopeKey: store.scopeKey,
          expectedCurrentCandidateDigest: bundle.candidateDigest,
          expectedHeadVersion: null,
          expectedProjectBuildScopeKey: repositoryScope,
          ownedRevision: proof,
          permit: auth.permit,
          verificationReport: auth.report,
        ),
        throwsStateError,
      );
      final adopted = await store.adoptCurrentHead(
        proof,
        expectedScopeKey: store.scopeKey,
        expectedProjectBuildScopeKey: repositoryScope,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      expect(adopted.headVersion, 7);
      expect(await record.get(database), original);
      final old = await testOwnedBundleProof(
        bundle,
        auth.permit.reportDigest,
        scopeKey: repositoryScope,
        headVersion: 6,
      );
      await expectLater(
        store.adoptCurrentHead(
          old,
          expectedScopeKey: store.scopeKey,
          expectedProjectBuildScopeKey: repositoryScope,
          permit: auth.permit,
          verificationReport: auth.report,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'foreign owned proof and expired permits never install a head',
    () async {
      final bundle = productionBundleFixture();
      var live = true;
      final auth = await testBundlePermit(bundle, isCurrent: () => live);
      final foreign = await testOwnedBundleProof(
        bundle,
        auth.permit.reportDigest,
        scopeKey: 'other|owner',
        headVersion: 1,
      );
      expect(
        () => store.install(
          bundle,
          expectedScopeKey: store.scopeKey,
          expectedCurrentCandidateDigest: null,
          expectedHeadVersion: null,
          expectedProjectBuildScopeKey: repositoryScope,
          ownedRevision: foreign,
          permit: auth.permit,
          verificationReport: auth.report,
        ),
        throwsStateError,
      );
      final proof = await testOwnedBundleProof(
        bundle,
        auth.permit.reportDigest,
        scopeKey: repositoryScope,
        headVersion: 1,
      );
      live = false;
      expect(
        () => store.install(
          bundle,
          expectedScopeKey: store.scopeKey,
          expectedCurrentCandidateDigest: null,
          expectedHeadVersion: null,
          expectedProjectBuildScopeKey: repositoryScope,
          ownedRevision: proof,
          permit: auth.permit,
          verificationReport: auth.report,
        ),
        throwsStateError,
      );
      expect(
        await store.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: store.scopeKey,
        ),
        isNull,
      );
    },
  );
}
