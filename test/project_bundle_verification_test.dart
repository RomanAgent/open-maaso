import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart' as signatures;
import 'package:flutter_test/flutter_test.dart';
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
    final fixture =
        jcs.parse(
              File(
                'tool/fixtures/project_bundle_v2_golden.json',
              ).readAsStringSync(),
            )
            as Map;
    bundle = const ProjectBundleV2Codec().decode(fixture['bundle']);
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
          for (final a in bundle.protocol.actions) 'platform.action.${a['id']}',
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
    'signature binds the complete candidate and permit retires with scope',
    () async {
      final raw = await report();
      final digest = projectBundleV2BytesDigest(jcs.canonicalBytes(raw));
      final permit = await service.verifyReport(
        bundle,
        raw,
        expectedReportDigest: digest,
      );
      expect(permit.isCurrent, isTrue);
      expect(permit.candidateDigest, bundle.candidateDigest);
      expect(permit.productionIsolation, isFalse);
      current = false;
      expect(permit.isCurrent, isFalse);
      await expectLater(service.verifyReport(bundle, raw), throwsStateError);
    },
  );
  test(
    'tampering, unknown signing keys and report digest mismatch fail closed',
    () async {
      final raw = await report();
      (raw['payload']! as Map)['elapsedMs'] = 101;
      await expectLater(
        service.verifyReport(bundle, raw),
        throwsFormatException,
      );
      final trusted = await report();
      final unknown = ProjectBundleVerificationService(
        trustedKeys: {},
        isCurrent: () => true,
        allowDevelopmentIsolation: true,
      );
      await expectLater(
        unknown.verifyReport(bundle, trusted),
        throwsFormatException,
      );
      await expectLater(
        service.verifyReport(bundle, trusted, expectedReportDigest: 'c' * 64),
        throwsFormatException,
      );
    },
  );
  test(
    'valid signature cannot bless another revision or omit platform gates',
    () async {
      for (final mutate in <void Function(Map<String, Object?>)>[
        (p) => p['candidateDigest'] = 'c' * 64,
        (p) => (p['checks']! as List).removeWhere(
          (v) => (v as Map)['id'] == 'platform.first_frame',
        ),
        (p) => (p['checks']! as List).add({
          'id': 'platform.compile',
          'passed': true,
        }),
        (p) => p['screenshots'] = [],
        (p) => p['productionIsolation'] = true,
      ]) {
        await expectLater(
          service.verifyReport(bundle, await report(change: mutate)),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'development container reports require explicit development policy',
    () async {
      final strict = ProjectBundleVerificationService(
        trustedKeys: {'test-only': publicKey},
        isCurrent: () => true,
      );
      await expectLater(
        strict.verifyReport(bundle, await report()),
        throwsFormatException,
      );
    },
  );
  test('deactivation revokes all previously issued permits', () async {
    final permit = await service.verifyReport(bundle, await report());
    service.deactivate();
    expect(permit.isCurrent, isFalse);
  });
}
