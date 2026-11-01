import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';

/// Opt-in interoperability check against the actual isolated runner outputs.
/// Synthetic fixture-only runs cannot silently satisfy this evidence gate.
void main() {
  final evidence = Platform.environment['MAASO_RUNNER_EVIDENCE'];
  test(
    'Dart accepts actual Chromium/Go signed realtime report',
    () async {
      final bundle = const ProjectBundleV2Codec().decodeString(
        await File('$evidence/cooperative-dodge.bundle.json').readAsString(),
      );
      final report =
          jsonDecode(
                await File(
                  '$evidence/cooperative-dodge.report.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final keys =
          jsonDecode(
                await File(
                  '$evidence/realtime-trusted-test-keys.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final verifier = ProjectBundleVerificationService(
        trustedKeys: keys.map(
          (key, value) => MapEntry(key, base64Decode(value as String)),
        ),
        isCurrent: () => true,
        allowDevelopmentIsolation: true,
      );
      final permit = await verifier.verifyReport(bundle, report);
      expect(permit.isCurrent, isTrue);
      expect(permit.productionIsolation, isFalse);
      expect(permit.candidateDigest, bundle.candidateDigest);
      expect(bundle.protocol.rulesId, 'cooperative-dodge.v1');
      final production = ProjectBundleVerificationService(
        trustedKeys: keys.map(
          (key, value) => MapEntry(key, base64Decode(value as String)),
        ),
        isCurrent: () => true,
      );
      await expectLater(
        production.verifyReport(bundle, report),
        throwsFormatException,
      );
    },
    skip: evidence == null
        ? 'Actual isolated-runner output directory required'
        : false,
  );
}
