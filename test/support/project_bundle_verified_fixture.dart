import 'dart:convert';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

/// Unit-test authority only. This fixture does not attest browser execution.
Future<
  ({
    ProjectBundleVerificationService verifier,
    VerifiedProjectBundlePermit permit,
    Map<String, Object?> report,
  })
>
testBundlePermit(
  ValidatedProjectBundleV2 bundle, {
  bool Function()? isCurrent,
}) async {
  final key = await crypto.Ed25519().newKeyPair();
  final verifier = ProjectBundleVerificationService(
    trustedKeys: {'unit-test': (await key.extractPublicKey()).bytes},
    isCurrent: isCurrent ?? () => true,
    allowDevelopmentIsolation: true,
  );
  final payload = <String, Object?>{
    'schemaVersion': 2,
    'profile': 'maaso.project.verification.v2',
    'candidateDigest': bundle.candidateDigest,
    'projectId': bundle.manifest.projectId,
    'revisionId': bundle.manifest.revisionId,
    'contentDigest': bundle.manifest.contentDigest,
    'artifactDigest': bundle.manifest.artifactDigest,
    'runnerImageDigest': 'sha256:${'a' * 64}',
    'runtime': '',
    'productionIsolation': false,
    'toolchainVersion': 'maaso-web-2.0.0',
    'createdAt': '2026-09-28T10:00:00Z',
    'scope': 'platform_and_project_self_tests',
    'requirementsQualityEvaluated': false,
    'elapsedMs': 100,
    'environment': {
      'toolchainVersion': 'maaso-web-2.0.0',
      'node': 'v22.0.0',
      'esbuild': '0.25.12',
      'playwright': '1.63.0',
    },
    'checks': [
      for (final id in [
        'platform.compile',
        'platform.first_frame',
        'platform.offline',
        'platform.no_runtime_errors',
        for (final route in bundle.routes) 'platform.route.${route.routeId}',
        for (final file in bundle.manifest.files)
          if (file.role == ProjectBundleV2FileRole.asset)
            'platform.asset.${file.path}',
        for (final action in bundle.protocol.actions)
          'platform.action.${action['id']}',
        if (bundle.protocol.isTrustedGame) ...[
          'platform.game_rules',
          'platform.game_controls',
          if (bundle.protocol.rulesId == 'cooperative-dodge.v1') ...[
            'platform.realtime_controls',
            'platform.realtime_expiry',
            'platform.realtime_frames',
          ],
        ],
        'project.self_test.fixture',
      ])
        {'id': id, 'passed': true},
    ],
    'screenshots': [
      for (final route in bundle.routes)
        {
          'routeId': route.routeId,
          'sha256': 'b' * 64,
          'byteLength': 100,
          'width': 375,
          'height': 812,
        },
    ],
  };
  final signature = await crypto.Ed25519().sign(
    const ProjectJsonCanonicalizer().canonicalBytes(payload),
    keyPair: key,
  );
  final report = <String, Object?>{
    'payload': payload,
    'keyId': 'unit-test',
    'signature': base64Encode(signature.bytes),
  };
  return (
    verifier: verifier,
    permit: await verifier.verifyReport(bundle, report),
    report: report,
  );
}
