import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'package:sembast/sembast_memory.dart';

import 'project_bundle_verified_fixture.dart';

final _authorities =
    Expando<
      Map<
        String,
        ({VerifiedProjectBundlePermit permit, Map<String, Object?> report})
      >
    >();

/// Synthetic owner inventory is committed through the real private-proof
/// constructor. This is unit-test evidence only, never server/browser evidence.
Future<ProjectBuildV2OwnedRevision> testOwnedBundleProof(
  ValidatedProjectBundleV2 bundle,
  String reportDigest, {
  required String scopeKey,
  required int headVersion,
}) async {
  final db = await DBService().init(
    factory: databaseFactoryMemory,
    path: 'bundle-proof-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    final repo = ProjectBuildV2Repository(
      database: db,
      scopeKey: scopeKey,
      isCurrent: () => true,
    );
    final manifest = bundle.manifest;
    final revisions = <Map<String, Object?>>[
      if (manifest.baseRevision != null)
        {
          'revisionId': manifest.baseRevision,
          'baseRevision': null,
          'candidateDigest': 'a' * 64,
          'reportDigest': 'b' * 64,
          'createdAt': '2026-09-28T00:00:00Z',
        },
      {
        'revisionId': manifest.revisionId,
        'baseRevision': manifest.baseRevision,
        'candidateDigest': bundle.candidateDigest,
        'reportDigest': reportDigest,
        'createdAt': '2026-09-28T00:00:00Z',
      },
    ];
    await repo.recordOwnedProjects(
      ProjectBuildV2OwnedProjects.fromJson({
        'schemaVersion': 2,
        'projects': [
          {
            'projectId': manifest.projectId,
            'agentId': 'self',
            'projectKind': manifest.projectKind,
            'title': 'Unit fixture',
            'currentRevisionId': manifest.revisionId,
            'revisionCount': revisions.length,
            'headVersion': headVersion,
            'createdAt': '2026-09-28T00:00:00Z',
            'updatedAt': '2026-09-28T00:00:00Z',
          },
        ],
      }),
      expectedScopeKey: scopeKey,
    );
    final proofs = await repo.recordOwnedRevisions(
      ProjectBuildV2OwnedRevisions.fromJson({
        'schemaVersion': 2,
        'projectId': manifest.projectId,
        'currentRevisionId': manifest.revisionId,
        'currentHeadVersion': headVersion,
        'revisions': revisions,
      }),
      expectedScopeKey: scopeKey,
    );
    return proofs.singleWhere(
      (proof) => proof.revisionId == manifest.revisionId,
    );
  } finally {
    await db.close();
  }
}

Future<InstalledProjectBundleV2> testInstallBundle(
  ProjectBundleInstallationStore store,
  ValidatedProjectBundleV2 bundle, {
  required String expectedScopeKey,
  required String? expectedCurrentCandidateDigest,
  int? expectedHeadVersion,
  int? authoritativeHeadVersion,
  VerifiedProjectBundlePermit? permit,
  Map<String, Object?>? verificationReport,
}) async {
  final local = await store.openCurrent(
    bundle.manifest.projectId,
    expectedScopeKey: expectedScopeKey,
  );
  if (permit == null) {
    if (verificationReport != null) {
      throw ArgumentError('Supply the permit for an explicit test report');
    }
    final cached = _authorities[store] ??= {};
    var auth = cached[bundle.candidateDigest];
    if (auth == null) {
      final signed = await testBundlePermit(bundle);
      auth = (permit: signed.permit, report: signed.report);
      cached[bundle.candidateDigest] = auth;
    }
    permit = auth.permit;
    verificationReport = auth.report;
  }
  final proof = await testOwnedBundleProof(
    bundle,
    permit.reportDigest,
    scopeKey: store.projectBuildScopeKey!,
    headVersion:
        authoritativeHeadVersion ??
        (local?.candidateDigest == bundle.candidateDigest
            ? local!.headVersion!
            : (local?.headVersion ?? 0) + 1),
  );
  return store.install(
    bundle,
    expectedScopeKey: expectedScopeKey,
    expectedCurrentCandidateDigest: expectedCurrentCandidateDigest,
    expectedHeadVersion: expectedHeadVersion ?? local?.headVersion,
    expectedProjectBuildScopeKey: store.projectBuildScopeKey!,
    ownedRevision: proof,
    permit: permit,
    verificationReport: verificationReport!,
  );
}
