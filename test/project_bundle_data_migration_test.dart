import 'support/project_bundle_install_authority.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_data_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:sembast/sembast_memory.dart';
import 'support/project_bundle_v2_fixture.dart';
import 'support/project_bundle_verified_fixture.dart';

Map<String, Object?> schema(
  String key, {
  int maxLength = 128,
  bool flag = false,
}) => {
  'type': 'object',
  'properties': {
    key: {'type': 'string', 'maxLength': maxLength},
    if (flag) 'enabled': {'type': 'boolean'},
  },
  'required': [key, if (flag) 'enabled'],
  'additionalProperties': false,
};
ValidatedProjectBundleV2 bundleWith(int revision, Map<String, Object?> fields) {
  final base = productionBundleFixture(revision: revision);
  final project = {...base.project, ...fields};
  final files = [
    for (final metadata in base.manifest.files)
      ProjectBundleV2File(
        path: metadata.path,
        mimeType: metadata.mimeType,
        role: metadata.role,
        bytes: metadata.path == 'project.json'
            ? const ProjectJsonCanonicalizer().canonicalBytes(project)
            : base.files[metadata.path]!,
      ),
  ];
  final manifest = ProjectBundleV2Manifest.create(
    projectId: base.manifest.projectId,
    revisionId: base.manifest.revisionId,
    contentManifestId: base.manifest.contentManifestId,
    requirementRevision: base.manifest.requirementRevision,
    requirementDigest: base.manifest.requirementDigest,
    baseRevision: base.manifest.baseRevision,
    projectKind: base.manifest.projectKind,
    files: files.map((file) => file.metadata),
  );
  return const ProjectBundleV2Codec().verify(manifest, files);
}

void main() {
  const repositoryScope = 'test|owner';
  late Directory directory;
  late DBService db;
  late ProjectBundleInstallationStore store;
  bool current = true;
  setUp(() async {
    current = true;
    directory = await Directory.systemTemp.createTemp('project-migration-');
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: directory.path,
    );
    store = ProjectBundleInstallationStore(
      database: db.raw,
      accountScope: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'owner',
      ),
      projectBuildScopeKey: repositoryScope,
      applicationSupportRoot: directory,
      isCurrent: () => current,
    );
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await db.close();
    await directory.delete(recursive: true);
  });
  Future<void> install(
    ValidatedProjectBundleV2 value, {
    String? previous,
  }) async {
    await testInstallBundle(
      store,
      value,
      expectedScopeKey: store.scopeKey,
      expectedCurrentCandidateDigest: previous,
    );
  }

  Future<ProjectBundleApplicationData> read(ValidatedProjectBundleV2 value) =>
      store.readApplicationData(
        value.candidateDigest,
        expectedScopeKey: store.scopeKey,
        role: ProjectBundleDataRole.installed,
      );
  Future<ProjectBundleApplicationData> save(
    ValidatedProjectBundleV2 value,
    Map<String, Object?> data, {
    int version = 0,
  }) => store.saveApplicationData(
    value.candidateDigest,
    data,
    expectedScopeKey: store.scopeKey,
    role: ProjectBundleDataRole.installed,
    expectedDataVersion: version,
  );

  test(
    'shared Dart/Go data-schema fixtures use identical acceptance and digest',
    () {
      final fixtures =
          jsonDecode(
                File(
                  'tool/fixtures/project_bundle_data_schema_v2.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final fixture in fixtures['valid'] as List) {
        final fields = Map<String, Object?>.from(
          (fixture as Map)['projectFields'] as Map,
        );
        expect(
          ProjectBundleDataContract.fromProject(fields)?.digest,
          fixture['expectedSchemaDigest'],
          reason: fixture['name'] as String,
        );
        bundleWith(2, fields);
      }
      for (final fixture in fixtures['invalid'] as List) {
        expect(
          () => bundleWith(
            2,
            Map<String, Object?>.from((fixture as Map)['projectFields'] as Map),
          ),
          throwsFormatException,
          reason: fixture['name'] as String,
        );
      }
    },
  );

  test(
    'historical completion must be committed journal, never a remote completed head',
    () async {
      final raw =
          jsonDecode(
                File(
                  'tool/fixtures/project_build_wire_v2.json',
                ).readAsStringSync(),
              )
              as Map;
      final candidate = ProjectBuildV2Candidate.fromJson(
        projectBuildV2Object(raw['candidateDocument']),
      );
      final verifier = ProjectBundleVerificationService(
        trustedKeys: projectBuildV2Object(
          raw['trustedVerifierKeys'],
        ).map((key, value) => MapEntry(key, base64Decode(value! as String))),
        isCurrent: () => current,
        allowDevelopmentIsolation: true,
      );
      final permit = await verifier.verifyReport(
        candidate.bundle,
        candidate.report,
      );
      final repo = ProjectBuildV2Repository(
        database: db,
        scopeKey: repositoryScope,
        isCurrent: () => current,
      );
      final request = ProjectBuildV2CreateRequest.fromJson(
        projectBuildV2Object(raw['createRequest']),
      );
      await repo.prepareCreate(request, expectedScopeKey: repositoryScope);
      final created = await repo.recordReceipt(
        ProjectBuildV2Receipt.fromJson(
          projectBuildV2Object(raw['createReceipt']),
        ),
        expectedScopeKey: repositoryScope,
      );
      expect(
        () => store.cacheAcceptedHistorical(
          candidate.bundle,
          expectedScopeKey: store.scopeKey,
          expectedProjectBuildScopeKey: repositoryScope,
          completion: created,
          permit: permit,
          verificationReport: candidate.report,
        ),
        throwsStateError,
      );
      final completion = await repo.applyPage(
        candidate.taskId,
        ProjectBuildV2EventPage.fromJson(
          projectBuildV2Object(raw['eventsPage']),
          taskId: candidate.taskId,
          afterTaskSequence: 0,
        ),
        expectedScopeKey: repositoryScope,
      );
      final restored = await store.cacheAcceptedHistorical(
        candidate.bundle,
        expectedScopeKey: store.scopeKey,
        expectedProjectBuildScopeKey: repositoryScope,
        completion: completion,
        permit: permit,
        verificationReport: candidate.report,
      );
      expect(restored.isAccepted, isTrue);
      expect(
        await store.openCurrent(
          candidate.projectId,
          expectedScopeKey: store.scopeKey,
        ),
        isNull,
      );
    },
  );

  test(
    'strict source metadata rejects partial, unbounded and executable migration declarations',
    () {
      for (final metadata in <Map<String, Object?>>[
        {'dataSchemaVersion': 1},
        {'dataSchema': schema('name')},
        {'dataSchemaVersion': 0, 'dataSchema': schema('name')},
        {'dataSchemaVersion': 1000001, 'dataSchema': schema('name')},
        {
          'dataSchemaVersion': 1,
          'dataSchema': {
            'type': 'object',
            'properties': {},
            'required': [],
            'additionalProperties': true,
          },
        },
        {
          'dataSchemaVersion': 1,
          'dataSchema': schema('name'),
          'dataMigration': {
            'fromSchemaDigest': 'f' * 64,
            'steps': [
              {'op': 'eval', 'source': 'malicious()'},
            ],
          },
        },
        {
          'dataSchemaVersion': 1,
          'dataSchema': schema('name'),
          'dataMigration': {
            'fromSchemaDigest': 'f' * 64,
            'steps': [
              {'op': 'rename', 'from': 'same', 'to': 'same'},
            ],
          },
        },
        {
          'dataSchemaVersion': 1,
          'dataSchema': schema('name'),
          'dataMigration': {
            'fromSchemaDigest': 'f' * 64,
            'steps': [
              {'op': 'default', 'key': 'name', 'value': 9},
            ],
          },
        },
        {
          'dataSchemaVersion': 1,
          'dataSchema': schema('name'),
          'dataMigration': {
            'fromSchemaDigest': 'f' * 64,
            'steps': List.generate(
              33,
              (_) => {'op': 'default', 'key': 'name', 'value': 'x'},
            ),
          },
        },
      ]) {
        expect(() => bundleWith(2, metadata), throwsFormatException);
      }
    },
  );
  test(
    'schema digest is stable, snapshots immutable, and writes enforce the declared shape',
    () async {
      final first = bundleWith(2, {
        'dataSchemaVersion': 1,
        'dataSchema': schema('name'),
      });
      final contract = ProjectBundleDataContract.fromProject(first.project)!;
      expect(
        contract.digest,
        projectBundleV2JsonDigest({'schema': schema('name'), 'version': 1}),
      );
      expect(() => contract.schema['type'] = 'string', throwsUnsupportedError);
      await install(first);
      expect((await read(first)).version, 0);
      await expectLater(
        save(first, {'name': 9}),
        throwsA(isA<ProjectBundleDataUpgradeException>()),
      );
      expect((await read(first)).version, 0);
      await save(first, {'name': 'old'});
      await expectLater(
        save(first, {'name': 'new', 'extra': true}, version: 1),
        throwsA(isA<ProjectBundleDataUpgradeException>()),
      );
      expect((await read(first)).values, {'name': 'old'});
    },
  );
  test(
    'same schema upgrade atomically copies the latest old snapshot and preserves old revision',
    () async {
      final fields = {'dataSchemaVersion': 1, 'dataSchema': schema('name')};
      final first = bundleWith(2, fields), second = bundleWith(3, fields);
      await install(first);
      await save(first, {'name': 'before'});
      await save(first, {'name': 'latest'}, version: 1);
      await install(second, previous: first.candidateDigest);
      expect((await read(second)).values, {'name': 'latest'});
      expect((await read(second)).version, 1);
      expect((await read(first)).version, 2);
      await save(second, {'name': 'new revision'}, version: 1);
      expect((await read(first)).values, {'name': 'latest'});
      await install(second, previous: first.candidateDigest);
      expect((await read(second)).values, {'name': 'new revision'});
    },
  );
  test(
    'rename/default migration validates final snapshot and never overwrites old data',
    () async {
      final first = bundleWith(2, {
        'dataSchemaVersion': 1,
        'dataSchema': schema('oldName'),
      });
      final old = ProjectBundleDataContract.fromProject(first.project)!;
      final second = bundleWith(3, {
        'dataSchemaVersion': 2,
        'dataSchema': schema('name', flag: true),
        'dataMigration': {
          'fromSchemaDigest': old.digest,
          'steps': [
            {'op': 'rename', 'from': 'oldName', 'to': 'name'},
            {'op': 'default', 'key': 'enabled', 'value': true},
          ],
        },
      });
      await install(first);
      await save(first, {'oldName': 'personal'});
      await install(second, previous: first.candidateDigest);
      expect((await read(second)).values, {
        'name': 'personal',
        'enabled': true,
      });
      expect((await read(first)).values, {'oldName': 'personal'});
      await install(first, previous: second.candidateDigest);
      expect((await read(first)).values, {
        'oldName': 'personal',
      }, reason: 'accepted rollback retains its own snapshot');
    },
  );
  test(
    'missing migration or invalid result rolls back candidate acceptance, data and head',
    () async {
      final first = bundleWith(2, {
        'dataSchemaVersion': 1,
        'dataSchema': schema('name'),
      });
      final old = ProjectBundleDataContract.fromProject(first.project)!;
      await install(first);
      await save(first, {'name': 'too long'});
      final variants = [
        bundleWith(3, {
          'dataSchemaVersion': 2,
          'dataSchema': schema('name', maxLength: 2),
        }),
        bundleWith(4, {
          'dataSchemaVersion': 2,
          'dataSchema': schema('name', maxLength: 2),
          'dataMigration': {'fromSchemaDigest': old.digest, 'steps': []},
        }),
        bundleWith(5, {}),
      ];
      for (final next in variants) {
        await store.stageCandidate(next, expectedScopeKey: store.scopeKey);
        await expectLater(
          install(next, previous: first.candidateDigest),
          throwsA(isA<ProjectBundleDataUpgradeException>()),
        );
        expect(
          (await store.openCurrent(
            first.manifest.projectId,
            expectedScopeKey: store.scopeKey,
          ))!.candidateDigest,
          first.candidateDigest,
        );
        expect(
          (await store.openCandidate(
            next.candidateDigest,
            expectedScopeKey: store.scopeKey,
          ))!.isAccepted,
          isFalse,
        );
        expect((await read(next)).version, 0);
      }
      expect((await read(first)).values, {'name': 'too long'});
    },
  );
  test(
    'migration never overwrites rename destinations; empty DSL can declare compatible widening',
    () {
      final target = ProjectBundleDataContract.fromProject({
        'dataSchemaVersion': 2,
        'dataSchema': schema('name'),
        'dataMigration': {
          'fromSchemaDigest': 'f' * 64,
          'steps': [
            {'op': 'rename', 'from': 'old', 'to': 'name'},
          ],
        },
      })!;
      expect(
        () => target.migrate({'old': 'a', 'name': 'b'}, sourceDigest: 'f' * 64),
        throwsA(isA<ProjectBundleDataUpgradeException>()),
      );
      final widening = ProjectBundleDataContract.fromProject({
        'dataSchemaVersion': 2,
        'dataSchema': schema('name'),
        'dataMigration': {'fromSchemaDigest': 'f' * 64, 'steps': []},
      })!;
      expect(widening.migrate({'name': 'a'}, sourceDigest: 'f' * 64), {
        'name': 'a',
      });
      expect(
        () => widening.migrate({'name': 'a'}, sourceDigest: 'e' * 64),
        throwsA(isA<ProjectBundleDataUpgradeException>()),
      );
    },
  );
  test(
    'competing migrated installs have one CAS winner and no partial target snapshot',
    () async {
      final fields = {'dataSchemaVersion': 1, 'dataSchema': schema('name')};
      final first = bundleWith(2, fields),
          second = bundleWith(3, fields),
          third = bundleWith(4, fields);
      await install(first);
      await save(first, {'name': 'durable'});
      final outcomes = await Future.wait(
        [second, third].map((b) async {
          try {
            await install(b, previous: first.candidateDigest);
            return true;
          } catch (_) {
            return false;
          }
        }),
      );
      expect(outcomes.where((ok) => ok), hasLength(1));
      final winning = outcomes[0] ? second : third,
          losing = outcomes[0] ? third : second;
      expect((await read(winning)).values, {'name': 'durable'});
      expect(
        await store.openCandidate(
          losing.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ),
        isNull,
      );
      expect((await read(first)).values, {'name': 'durable'});
    },
  );
  test(
    'historical accepted cache requires scoped owned proof and signature and does not move head',
    () async {
      final fields = {'dataSchemaVersion': 1, 'dataSchema': schema('name')};
      final old = bundleWith(2, fields), newer = bundleWith(3, fields);
      final auth = await testBundlePermit(old),
          nextAuth = await testBundlePermit(newer);
      await install(newer);
      await save(newer, {'name': 'current local data'});
      Future<ProjectBuildV2OwnedRevision> proofFor(String scope) async {
        final repo = ProjectBuildV2Repository(
          database: db,
          scopeKey: scope,
          isCurrent: () => current,
        );
        await repo.recordOwnedProjects(
          ProjectBuildV2OwnedProjects.fromJson({
            'schemaVersion': 2,
            'projects': [
              {
                'projectId': old.manifest.projectId,
                'agentId': 'self',
                'projectKind': 'applet',
                'title': 'Saved work',
                'currentRevisionId': newer.manifest.revisionId,
                'revisionCount': 2,
                'headVersion': 2,
                'createdAt': '2026-09-28T00:00:00Z',
                'updatedAt': '2026-09-28T00:00:00Z',
              },
            ],
          }),
          expectedScopeKey: scope,
        );
        final revisions = await repo.recordOwnedRevisions(
          ProjectBuildV2OwnedRevisions.fromJson({
            'schemaVersion': 2,
            'projectId': old.manifest.projectId,
            'currentRevisionId': newer.manifest.revisionId,
            'currentHeadVersion': 2,
            'revisions': [
              {
                'revisionId': old.manifest.revisionId,
                'baseRevision': null,
                'candidateDigest': old.candidateDigest,
                'reportDigest': auth.permit.reportDigest,
                'createdAt': '2026-09-28T00:00:00Z',
              },
              {
                'revisionId': newer.manifest.revisionId,
                'baseRevision': old.manifest.revisionId,
                'candidateDigest': newer.candidateDigest,
                'reportDigest': nextAuth.permit.reportDigest,
                'createdAt': '2026-09-28T00:00:00Z',
              },
            ],
          }),
          expectedScopeKey: scope,
        );
        return revisions.singleWhere(
          (r) => r.revisionId == old.manifest.revisionId,
        );
      }

      final proof = await proofFor(repositoryScope),
          foreign = await proofFor('foreign|owner');
      expect(
        () => store.cacheAcceptedHistorical(
          old,
          expectedScopeKey: store.scopeKey,
          expectedProjectBuildScopeKey: repositoryScope,
          ownedRevision: foreign,
          permit: auth.permit,
          verificationReport: auth.report,
        ),
        throwsStateError,
      );
      final restored = await store.cacheAcceptedHistorical(
        old,
        expectedScopeKey: store.scopeKey,
        expectedProjectBuildScopeKey: repositoryScope,
        ownedRevision: proof,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      expect(restored.isAccepted, isTrue);
      expect(
        (await store.openCurrent(
          old.manifest.projectId,
          expectedScopeKey: store.scopeKey,
        ))!.candidateDigest,
        newer.candidateDigest,
      );
      // Merely caching server acceptance must not suppress the first local
      // activation's schema migration from the actual current head.
      await install(old, previous: newer.candidateDigest);
      expect((await read(old)).values, {'name': 'current local data'});
      expect((await read(newer)).values, {'name': 'current local data'});
      auth.verifier.deactivate();
      expect(
        () => store.cacheAcceptedHistorical(
          old,
          expectedScopeKey: store.scopeKey,
          expectedProjectBuildScopeKey: repositoryScope,
          ownedRevision: proof,
          permit: auth.permit,
          verificationReport: auth.report,
        ),
        throwsStateError,
      );
    },
  );
}
