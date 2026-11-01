import 'support/project_bundle_install_authority.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:sembast/sembast_io.dart';

import 'support/project_bundle_v2_fixture.dart';

void main() {
  late Directory directory;
  late Database database;
  late ProjectBundleInstallationStore store;
  late AccountStorageScope scope;
  var current = true;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('maaso-bundle-install-');
    database = await databaseFactoryIo.openDatabase(
      '${directory.path}/account.db',
    );
    scope = AccountStorageScope(environmentKey: 'test', accountUuid: 'owner-a');
    current = true;
    store = ProjectBundleInstallationStore(
      projectBuildScopeKey: 'test|owner',
      database: database,
      accountScope: scope,
      applicationSupportRoot: directory,
      isCurrent: () => current,
    );
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'staging is durable without moving installed head and accept is explicit CAS',
    () async {
      final first = productionBundleFixture(),
          second = productionBundleFixture(revision: 3);
      final staged = await store.stageCandidate(
        first,
        expectedScopeKey: store.scopeKey,
      );
      expect(staged.isAccepted, isFalse);
      expect(
        await store.openCurrent(
          first.manifest.projectId,
          expectedScopeKey: store.scopeKey,
        ),
        isNull,
      );
      expect(
        (await store.openCandidate(
          first.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ))!.isAccepted,
        isFalse,
      );
      await testInstallBundle(
        store,
        first,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      await store.stageCandidate(second, expectedScopeKey: store.scopeKey);
      expect(
        (await store.openCurrent(
          first.manifest.projectId,
          expectedScopeKey: store.scopeKey,
        ))!.candidateDigest,
        first.candidateDigest,
      );
      expect(
        (await store.openCandidate(
          second.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ))!.isAccepted,
        isFalse,
      );
      await expectLater(
        testInstallBundle(
          store,
          second,
          expectedScopeKey: store.scopeKey,
          expectedCurrentCandidateDigest: null,
        ),
        throwsStateError,
      );
      final accepted = await testInstallBundle(
        store,
        second,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: first.candidateDigest,
      );
      expect(accepted.isAccepted, isTrue);
      expect(
        (await store.openCurrent(
          first.manifest.projectId,
          expectedScopeKey: store.scopeKey,
        ))!.candidateDigest,
        second.candidateDigest,
      );
    },
  );

  test(
    'real file and Sembast reopen retain an offline package, routes and assets',
    () async {
      final bundle = productionBundleFixture();
      final installed = await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: null,
      );
      expect(installed.isScopeCurrent, isTrue);
      expect(
        await store.readAsset(
          bundle.candidateDigest,
          'assets/dot.png',
          expectedScopeKey: scope.storageNamespace,
        ),
        bundle.files['assets/dot.png'],
      );
      await store.deactivateAndDrain();
      expect(installed.isScopeCurrent, isFalse);
      await database.close();
      database = await databaseFactoryIo.openDatabase(
        '${directory.path}/account.db',
      );
      store = ProjectBundleInstallationStore(
        projectBuildScopeKey: 'test|owner',
        database: database,
        accountScope: scope,
        applicationSupportRoot: directory,
        isCurrent: () => current,
      );
      final reopened = await store.openCurrent(
        bundle.manifest.projectId,
        expectedScopeKey: scope.storageNamespace,
      );
      expect(reopened!.candidateDigest, bundle.candidateDigest);
      expect(reopened.bundle.routes.map((route) => route.routeId), [
        'home',
        'details',
      ]);
      expect(reopened.bundle.agentMarkdown, bundle.agentMarkdown);
      expect(reopened.bundle.runtimeHtml, contains('__MAASO_CONFIG_JSON__'));
      await expectLater(
        store.readAsset(
          bundle.candidateDigest,
          'src/main.js',
          expectedScopeKey: scope.storageNamespace,
        ),
        throwsStateError,
      );
      await expectLater(
        store.readAsset(
          bundle.candidateDigest,
          '../account.db',
          expectedScopeKey: scope.storageNamespace,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'competing install CAS preserves one head and old revisions remain readable',
    () async {
      final first = productionBundleFixture();
      final second = productionBundleFixture(revision: 3);
      final third = productionBundleFixture(revision: 4);
      await testInstallBundle(
        store,
        first,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: null,
      );
      final results = await Future.wait<Object>(
        [second, third].map(
          (bundle) => testInstallBundle(
            store,
            bundle,
            expectedScopeKey: scope.storageNamespace,
            expectedCurrentCandidateDigest: first.candidateDigest,
          ).then<Object>((value) => value, onError: (Object error) => error),
        ),
      );
      expect(results.whereType<InstalledProjectBundleV2>(), hasLength(1));
      expect(results.whereType<StateError>(), hasLength(1));
      final head = await store.openCurrent(
        first.manifest.projectId,
        expectedScopeKey: scope.storageNamespace,
      );
      expect(
        head!.candidateDigest,
        results.whereType<InstalledProjectBundleV2>().single.candidateDigest,
      );
      expect(
        (await store.openCandidate(
          first.candidateDigest,
          expectedScopeKey: scope.storageNamespace,
        ))!.candidateDigest,
        first.candidateDigest,
      );
      final repeated = await testInstallBundle(
        store,
        head.bundle,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: first.candidateDigest,
      );
      expect(repeated.candidateDigest, head.candidateDigest);
    },
  );

  test(
    'cached reports stay immutable and old pinned report digests survive re-verification',
    () async {
      final bundle = productionBundleFixture();
      // The cache deliberately does not certify these objects. Execution must
      // still obtain a real Ed25519-verified permit from the separate verifier.
      final first = <String, Object?>{
        'payload': {'candidateDigest': bundle.candidateDigest, 'check': 1},
        'keyId': 'fixture',
        'signature': 'untrusted',
      };
      final second = <String, Object?>{
        'payload': {'candidateDigest': bundle.candidateDigest, 'check': 2},
        'keyId': 'fixture',
        'signature': 'untrusted',
      };
      final firstDigest = projectBundleV2JsonDigest(first);
      final installed = await store.stageCandidate(
        bundle,
        expectedScopeKey: scope.storageNamespace,
        verificationReport: first,
      );
      expect(installed.verificationReport, first);
      expect(
        () => installed.verificationReport!['keyId'] = 'changed',
        throwsUnsupportedError,
      );
      await store.stageCandidate(
        bundle,
        expectedScopeKey: scope.storageNamespace,
        verificationReport: second,
      );
      final old = await store.openCandidate(
        bundle.candidateDigest,
        expectedScopeKey: scope.storageNamespace,
        reportDigest: firstDigest,
      );
      expect(old!.verificationReport, first);
      final latest = await store.openCandidate(
        bundle.candidateDigest,
        expectedScopeKey: scope.storageNamespace,
      );
      expect(latest!.verificationReport, second);
      await expectLater(
        store.openCandidate(
          bundle.candidateDigest,
          expectedScopeKey: scope.storageNamespace,
          reportDigest: 'f' * 64,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'preview data is isolated, user data uses CAS and code installs never overwrite it',
    () async {
      final first = productionBundleFixture();
      final second = productionBundleFixture(revision: 3);
      await testInstallBundle(
        store,
        first,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: null,
      );
      final user = await store.saveApplicationData(
        first.candidateDigest,
        {
          'items': ['personal'],
        },
        expectedScopeKey: scope.storageNamespace,
        role: ProjectBundleDataRole.installed,
        expectedDataVersion: 0,
      );
      expect(user.version, 1);
      expect(
        () => (user.values['items'] as List).clear(),
        throwsUnsupportedError,
      );
      final preview = await store.readApplicationData(
        first.candidateDigest,
        expectedScopeKey: scope.storageNamespace,
        role: ProjectBundleDataRole.preview,
      );
      expect(preview.values, isEmpty);
      await store.saveApplicationData(
        first.candidateDigest,
        {
          'items': ['test only'],
        },
        expectedScopeKey: scope.storageNamespace,
        role: ProjectBundleDataRole.preview,
        expectedDataVersion: 0,
      );
      await expectLater(
        store.saveApplicationData(
          first.candidateDigest,
          {
            'items': ['stale'],
          },
          expectedScopeKey: scope.storageNamespace,
          role: ProjectBundleDataRole.installed,
          expectedDataVersion: 0,
        ),
        throwsStateError,
      );
      await testInstallBundle(
        store,
        second,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: first.candidateDigest,
      );
      final next = await store.readApplicationData(
        second.candidateDigest,
        expectedScopeKey: scope.storageNamespace,
        role: ProjectBundleDataRole.installed,
      );
      expect(next.values, isEmpty);
      expect(next.version, 0);
      final oldData = await store.readApplicationData(
        first.candidateDigest,
        expectedScopeKey: scope.storageNamespace,
        role: ProjectBundleDataRole.installed,
      );
      expect(oldData.values, {
        'items': ['personal'],
      });
      expect(oldData.version, 1);
      final nextPreview = await store.readApplicationData(
        second.candidateDigest,
        expectedScopeKey: scope.storageNamespace,
        role: ProjectBundleDataRole.preview,
      );
      expect(nextPreview.values, isEmpty);
    },
  );

  test(
    'retired scope cannot publish an install or read a previous account',
    () async {
      final bundle = productionBundleFixture();
      final installing = testInstallBundle(
        store,
        bundle,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: null,
      );
      current = false;
      await expectLater(installing, throwsStateError);
      current = true;
      expect(
        await store.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: scope.storageNamespace,
        ),
        isNull,
      );
      await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: null,
      );
      final foreignScope = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'owner-b',
      );
      final foreign = ProjectBundleInstallationStore(
        database: database,
        accountScope: foreignScope,
        applicationSupportRoot: directory,
        isCurrent: () => true,
      );
      addTearDown(foreign.deactivateAndDrain);
      expect(
        await foreign.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: foreign.scopeKey,
        ),
        isNull,
      );
      await expectLater(
        store.openCandidate(
          bundle.candidateDigest,
          expectedScopeKey: foreign.scopeKey,
        ),
        throwsStateError,
      );
      await store.deactivateAndDrain();
      await expectLater(
        store.openCandidate(
          bundle.candidateDigest,
          expectedScopeKey: scope.storageNamespace,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'hash corruption is detected and a verified re-download can atomically repair a blob',
    () async {
      final bundle = productionBundleFixture();
      await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: null,
      );
      final digest = bundle.manifest.files
          .singleWhere((entry) => entry.path == 'assets/dot.png')
          .sha256;
      final blob =
          (await directory
                      .list(recursive: true)
                      .where(
                        (entry) =>
                            entry is File && entry.path.endsWith('/$digest'),
                      )
                      .toList())
                  .single
              as File;
      await blob.writeAsString('corrupt', flush: true);
      await expectLater(
        store.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: scope.storageNamespace,
        ),
        throwsStateError,
      );
      await store.stageCandidate(
        bundle,
        expectedScopeKey: scope.storageNamespace,
      );
      expect(
        (await store.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: scope.storageNamespace,
        ))!.candidateDigest,
        bundle.candidateDigest,
      );
    },
  );

  test('declared asset lookup never follows a substituted symlink', () async {
    final bundle = productionBundleFixture();
    await testInstallBundle(
      store,
      bundle,
      expectedScopeKey: scope.storageNamespace,
      expectedCurrentCandidateDigest: null,
    );
    final digest = bundle.manifest.files
        .singleWhere((entry) => entry.path == 'assets/dot.png')
        .sha256;
    final blob =
        (await directory
                    .list(recursive: true)
                    .where(
                      (entry) =>
                          entry is File && entry.path.endsWith('/$digest'),
                    )
                    .toList())
                .single
            as File;
    final target = File('${directory.path}/unrelated.txt');
    await target.writeAsString('private unrelated data');
    await blob.delete();
    await Link(blob.path).create(target.path);
    await expectLater(
      store.readAsset(
        bundle.candidateDigest,
        'assets/dot.png',
        expectedScopeKey: scope.storageNamespace,
      ),
      throwsStateError,
    );
    await expectLater(
      testInstallBundle(
        store,
        bundle,
        expectedScopeKey: scope.storageNamespace,
        expectedCurrentCandidateDigest: bundle.candidateDigest,
      ),
      throwsStateError,
    );
    expect(await target.readAsString(), 'private unrelated data');
  });
}
