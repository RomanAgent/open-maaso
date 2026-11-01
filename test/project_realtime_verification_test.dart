import 'dart:convert';
import 'package:cryptography/cryptography.dart' as signatures;
import 'package:flutter_test/flutter_test.dart';
import 'support/surface_play_example_factory_fixture.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

void main() {
  const jcs = ProjectJsonCanonicalizer();
  late ValidatedProjectBundleV2 bundle;
  late signatures.SimpleKeyPair key;
  late List<int> publicKey;
  late ProjectBundleVerificationService service;
  var current = true;
  setUp(() async {
    bundle = SurfacePlayExampleFactory.build(
      projectId: 'pb_project_00000000-0000-0000-0000-000000000001',
      revisionId: 'pb_revision_00000000-0000-0000-0000-000000000002',
      contentManifestId: 'pb_manifest_00000000-0000-0000-0000-000000000003',
      requirementDigest: 'a' * 64,
      rulesId: 'cooperative-dodge.v1',
    );
    key = await signatures.Ed25519().newKeyPair();
    publicKey = (await key.extractPublicKey()).bytes;
    current = true;
    service = ProjectBundleVerificationService(
      trustedKeys: {'test-only': publicKey},
      isCurrent: () => current,
      allowDevelopmentIsolation: true,
    );
  });
  Future<Map<String, Object?>> report({
    void Function(Map<String, Object?>)? change,
  }) async {
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
          for (final r in bundle.routes) 'platform.route.${r.routeId}',
          for (final f in bundle.manifest.files)
            if (f.role == ProjectBundleV2FileRole.asset)
              'platform.asset.${f.path}',
          'platform.game_rules',
          'platform.game_controls',
          if (bundle.protocol.isRealtime) ...[
            'platform.realtime_controls',
            'platform.realtime_expiry',
            'platform.realtime_frames',
          ],
          'project.self_test.fixture',
        ])
          {'id': id, 'passed': true},
      ],
      'screenshots': [
        for (final r in bundle.routes)
          {
            'routeId': r.routeId,
            'sha256': 'b' * 64,
            'byteLength': 100,
            'width': 375,
            'height': 812,
          },
      ],
    };
    change?.call(payload);
    final signature = await signatures.Ed25519().sign(
      jcs.canonicalBytes(payload),
      keyPair: key,
    );
    return {
      'payload': payload,
      'keyId': 'test-only',
      'signature': base64Encode(signature.bytes),
    };
  }

  test(
    'realtime candidate requires all three separately signed platform checks',
    () async {
      for (final missing in [
        'platform.realtime_controls',
        'platform.realtime_expiry',
        'platform.realtime_frames',
      ]) {
        final raw = await report(
          change: (p) =>
              (p['checks'] as List).removeWhere((v) => v['id'] == missing),
        );
        await expectLater(
          service.verifyReport(bundle, raw),
          throwsFormatException,
          reason: missing,
        );
      }
      expect(
        (await service.verifyReport(bundle, await report())).isCurrent,
        isTrue,
      );
    },
  );
  test(
    'previous trusted turn games retain their existing verification contract',
    () async {
      for (final rules in [
        'gomoku.v1',
        'cooperative-switches.v1',
        'private-cards.v1',
      ]) {
        bundle = SurfacePlayExampleFactory.build(
          projectId: 'pb_project_00000000-0000-0000-0000-000000000001',
          revisionId: 'pb_revision_00000000-0000-0000-0000-000000000002',
          contentManifestId: 'pb_manifest_00000000-0000-0000-0000-000000000003',
          requirementDigest: 'a' * 64,
          rulesId: rules,
        );
        expect(
          (await service.verifyReport(bundle, await report())).isCurrent,
          isTrue,
        );
      }
    },
  );
}
