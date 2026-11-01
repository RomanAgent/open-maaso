import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/sensevoice_benchmark_contract.dart';

void main() {
  group('SenseVoice distribution hard gate', () {
    test(
      'approves only verified, benchmark-bound desktop-default-off evidence',
      () {
        final fixture = _Fixture();
        final verifier = _Verifier();

        final verdict = fixture.evaluate(verifier: verifier);

        expect(verdict.approved, isTrue);
        expect(verdict.failures, isEmpty);
        expect(verifier.artifactsChecked, 3);
        expect(verifier.sbomChecked, 1);
        expect(verifier.signatureChecked, 1);
        expect(
          SenseVoiceDistributionManifest.fromJson(
            fixture.manifest.toJson(),
          ).toJson(),
          fixture.manifest.toJson(),
        );
      },
    );

    test(
      'requires verified source/model LICENSE, NOTICE, SBOM, and signature',
      () {
        final cases = <SenseVoiceDistributionFailure, _Verifier>{
          SenseVoiceDistributionFailure.sourceLicense: _Verifier(
            rejectedPath: 'legal/source-LICENSE.txt',
          ),
          SenseVoiceDistributionFailure.modelLicense: _Verifier(
            rejectedPath: 'legal/model-LICENSE.txt',
          ),
          SenseVoiceDistributionFailure.notice: _Verifier(
            rejectedPath: 'legal/NOTICE.txt',
          ),
          SenseVoiceDistributionFailure.cycloneDxSbom: _Verifier(sbom: false),
          SenseVoiceDistributionFailure.legalReviewSignature: _Verifier(
            signature: false,
          ),
        };

        for (final entry in cases.entries) {
          final verdict = _Fixture().evaluate(verifier: entry.value);
          expect(verdict.approved, isFalse, reason: entry.key.name);
          expect(verdict.failures, contains(entry.key), reason: entry.key.name);
        }
      },
    );

    test(
      'verifier errors fail closed and cannot skip remaining gate checks',
      () {
        final fixture = _Fixture(
          footprints: _footprints(
            overrides: <AppHostPlatform, SenseVoicePlatformFootprint>{
              AppHostPlatform.android: _zeroFootprint(loadCalls: 1),
            },
          ),
        );

        final verdict = fixture.evaluate(
          verifier: _Verifier(throwsError: true),
        );

        expect(verdict.approved, isFalse);
        expect(
          verdict.failures,
          containsAll(<SenseVoiceDistributionFailure>[
            SenseVoiceDistributionFailure.evidenceVerifier,
            SenseVoiceDistributionFailure.mobileOrWebFootprint,
          ]),
        );
      },
    );

    test(
      'mobile and web require exactly zero bytes, calls, and enablement',
      () {
        const restricted = <AppHostPlatform>{
          AppHostPlatform.web,
          AppHostPlatform.android,
          AppHostPlatform.ios,
          AppHostPlatform.fuchsia,
        };
        final badFootprints = <SenseVoicePlatformFootprint>[
          _zeroFootprint(bundledModelBytes: 1),
          _zeroFootprint(downloadedModelBytes: 1),
          _zeroFootprint(downloadCalls: 1),
          _zeroFootprint(registrationCalls: 1),
          _zeroFootprint(loadCalls: 1),
          _zeroFootprint(inferenceCalls: 1),
          _zeroFootprint(defaultEnabled: true),
        ];

        for (final platform in restricted) {
          for (final footprint in badFootprints) {
            final fixture = _Fixture(
              footprints: _footprints(
                overrides: <AppHostPlatform, SenseVoicePlatformFootprint>{
                  platform: footprint,
                },
              ),
            );
            final verdict = fixture.evaluate(verifier: _Verifier());
            expect(
              verdict.failures,
              contains(SenseVoiceDistributionFailure.mobileOrWebFootprint),
              reason: '${platform.name}: ${footprint.toJson()}',
            );
          }
        }
      },
    );

    test('desktop is default off with zero startup calls on every host', () {
      const desktops = <AppHostPlatform>{
        AppHostPlatform.macos,
        AppHostPlatform.windows,
        AppHostPlatform.linux,
      };
      for (final platform in desktops) {
        var fixture = _Fixture(
          footprints: _footprints(
            overrides: <AppHostPlatform, SenseVoicePlatformFootprint>{
              platform: _zeroFootprint(
                bundledModelBytes: 42,
                defaultEnabled: true,
              ),
            },
          ),
        );
        expect(
          fixture.evaluate(verifier: _Verifier()).failures,
          contains(SenseVoiceDistributionFailure.desktopDefault),
          reason: platform.name,
        );

        fixture = _Fixture(
          footprints: _footprints(
            overrides: <AppHostPlatform, SenseVoicePlatformFootprint>{
              platform: _zeroFootprint(bundledModelBytes: 42, loadCalls: 1),
            },
          ),
        );
        expect(
          fixture.evaluate(verifier: _Verifier()).failures,
          contains(SenseVoiceDistributionFailure.desktopStartupActivity),
          reason: platform.name,
        );
      }
    });

    test('benchmark, commit, and signed review are inseparably bound', () {
      final fixture = _Fixture();
      final mismatchedCommit = 'f123456789012345678901234567890123456789';
      final manifest = _manifest(
        fixture.input,
        fixture.result,
        upstreamCommit: mismatchedCommit,
      );

      final verdict = SenseVoiceDistributionGate.evaluate(
        benchmarkInput: fixture.input,
        benchmarkResult: fixture.result,
        manifest: manifest,
        verifier: _Verifier(),
      );

      expect(verdict.approved, isFalse);
      expect(
        verdict.failures,
        contains(SenseVoiceDistributionFailure.upstreamCommit),
      );

      final changedInput = _benchmarkInput(datasetId: 'different-dataset');
      final rebound = SenseVoiceDistributionGate.evaluate(
        benchmarkInput: changedInput,
        benchmarkResult: fixture.result,
        manifest: fixture.manifest,
        verifier: _Verifier(),
      );
      expect(
        rebound.failures,
        containsAll(<SenseVoiceDistributionFailure>[
          SenseVoiceDistributionFailure.benchmark,
          SenseVoiceDistributionFailure.legalReviewBinding,
        ]),
      );
    });

    test('signed review binds result and the complete release evidence', () {
      final fixture = _Fixture();
      final changedLicense = SenseVoiceArtifactEvidence(
        path: 'legal/source-LICENSE-v2.txt',
        sha256:
            '0123456789012345678901234567890123456789012345678901234567890123',
      );
      final tampered = SenseVoiceDistributionManifest(
        releaseId: fixture.manifest.releaseId,
        upstreamCommit: fixture.manifest.upstreamCommit,
        sourceLicense: changedLicense,
        modelLicense: fixture.manifest.modelLicense,
        notice: fixture.manifest.notice,
        sbom: fixture.manifest.sbom,
        legalReview: fixture.manifest.legalReview,
        footprints: fixture.manifest.footprints,
      );

      expect(
        SenseVoiceDistributionGate.evaluate(
          benchmarkInput: fixture.input,
          benchmarkResult: fixture.result,
          manifest: tampered,
          verifier: _Verifier(),
        ).failures,
        contains(SenseVoiceDistributionFailure.legalReviewBinding),
      );
    });

    test('only the benchmarked desktop may carry a model artifact', () {
      final fixture = _Fixture(
        footprints: _footprints(
          overrides: <AppHostPlatform, SenseVoicePlatformFootprint>{
            AppHostPlatform.windows: _zeroFootprint(
              bundledModelBytes: 10,
              unpackedModelBytes: 20,
            ),
          },
        ),
      );

      expect(
        fixture.evaluate(verifier: _Verifier()).failures,
        contains(SenseVoiceDistributionFailure.unbenchmarkedDesktopArtifact),
      );
    });

    test('desktop artifacts obey packed and unpacked size limits', () {
      final fixture = _Fixture(
        footprints: _footprints(
          overrides: <AppHostPlatform, SenseVoicePlatformFootprint>{
            AppHostPlatform.macos: _zeroFootprint(
              bundledModelBytes:
                  SenseVoiceBenchmarkThresholds.maximumBundledModelBytes + 1,
              unpackedModelBytes:
                  SenseVoiceBenchmarkThresholds.maximumUnpackedModelBytes + 1,
            ),
          },
        ),
      );

      expect(
        fixture.evaluate(verifier: _Verifier()).failures,
        contains(SenseVoiceDistributionFailure.desktopArtifactSize),
      );
    });

    test('artifact evidence rejects drive, encoded, and traversal paths', () {
      for (final path in <String>[
        r'C:\legal\LICENSE',
        'legal/%2e%2e/LICENSE',
        'legal/../LICENSE',
        '/legal/LICENSE',
      ]) {
        expect(
          () => SenseVoiceArtifactEvidence(path: path, sha256: 'a' * 64),
          throwsArgumentError,
          reason: path,
        );
      }
    });

    test('legal review requires an exact 64-byte Ed25519 signature', () {
      final fixture = _Fixture();
      expect(
        () => SenseVoiceLegalReview(
          reviewId: 'legal-short-signature',
          reviewerKeyId: 'maaso-legal-key-01',
          upstreamCommit: fixture.input.upstreamCommit,
          benchmarkInputFingerprint: fixture.input.fingerprint,
          benchmarkResultFingerprint: fixture.result.fingerprint,
          distributionEvidenceFingerprint: fixture.manifest.evidenceFingerprint,
          signedAt: fixture.result.completedAt,
          signatureAlgorithm: 'ed25519',
          signature: base64Encode(List<int>.filled(32, 7)),
        ),
        throwsArgumentError,
      );
    });

    test(
      'manifest parser rejects incomplete platforms and non-CycloneDX SBOM',
      () {
        final fixture = _Fixture();
        final missingPlatform = _deepCopy(fixture.manifest.toJson());
        (missingPlatform['footprints']! as Map<String, Object?>).remove('web');
        expect(
          () => SenseVoiceDistributionManifest.fromJson(missingPlatform),
          throwsFormatException,
        );

        final wrongSbom = _deepCopy(fixture.manifest.toJson());
        (wrongSbom['sbom']! as Map<String, Object?>)['format'] = 'SPDX';
        expect(
          () => SenseVoiceDistributionManifest.fromJson(wrongSbom),
          throwsFormatException,
        );
      },
    );
  });
}

final class _Fixture {
  _Fixture({Map<AppHostPlatform, SenseVoicePlatformFootprint>? footprints})
    : input = _benchmarkInput() {
    result = _benchmarkResult(input);
    manifest = _manifest(input, result, footprints: footprints);
  }

  final SenseVoiceBenchmarkInput input;
  late final SenseVoiceBenchmarkResult result;
  late final SenseVoiceDistributionManifest manifest;

  SenseVoiceDistributionVerdict evaluate({
    required SenseVoiceDistributionEvidenceVerifier verifier,
  }) => SenseVoiceDistributionGate.evaluate(
    benchmarkInput: input,
    benchmarkResult: result,
    manifest: manifest,
    verifier: verifier,
  );
}

final class _Verifier implements SenseVoiceDistributionEvidenceVerifier {
  _Verifier({
    this.rejectedPath,
    this.sbom = true,
    this.signature = true,
    this.throwsError = false,
  });

  final String? rejectedPath;
  final bool sbom;
  final bool signature;
  final bool throwsError;
  int artifactsChecked = 0;
  int sbomChecked = 0;
  int signatureChecked = 0;

  @override
  bool artifactMatches(SenseVoiceArtifactEvidence evidence) {
    artifactsChecked += 1;
    if (throwsError) throw StateError('verification unavailable');
    return evidence.path != rejectedPath;
  }

  @override
  bool sbomMatches(SenseVoiceCycloneDxEvidence evidence) {
    sbomChecked += 1;
    return sbom;
  }

  @override
  bool legalSignatureMatches(SenseVoiceLegalReview review) {
    signatureChecked += 1;
    return signature && review.canonicalPayload.contains(review.reviewId);
  }
}

SenseVoiceBenchmarkInput _benchmarkInput({
  String datasetId = 'maaso-speech-eval-v1',
}) => SenseVoiceBenchmarkInput(
  runId: 'sensevoice-macos-arm64-001',
  platform: AppHostPlatform.macos,
  upstreamCommit: 'a123456789012345678901234567890123456789',
  datasetId: datasetId,
  datasetManifestSha256:
      'b123456789012345678901234567890123456789012345678901234567890123',
  datasetLicenseSpdx: 'CC-BY-4.0',
  sampleCount: 120,
  warmupRuns: 3,
  measuredRuns: 10,
  createdAt: DateTime.utc(2026, 8, 30, 8),
);

SenseVoiceBenchmarkResult _benchmarkResult(SenseVoiceBenchmarkInput input) =>
    SenseVoiceBenchmarkResult(
      runId: input.runId,
      inputFingerprint: input.fingerprint,
      upstreamCommit: input.upstreamCommit,
      successfulSamples: 120,
      medianLatencyMs: 120,
      p95LatencyMs: 300,
      p95RealtimeFactor: 0.4,
      characterErrorRate: 0.08,
      peakResidentBytes: 512 * 1024 * 1024,
      crashes: 0,
      timeouts: 0,
      completedAt: input.createdAt.add(const Duration(minutes: 5)),
    );

SenseVoiceDistributionManifest _manifest(
  SenseVoiceBenchmarkInput input,
  SenseVoiceBenchmarkResult result, {
  String? upstreamCommit,
  SenseVoiceLegalReview? legalReview,
  Map<AppHostPlatform, SenseVoicePlatformFootprint>? footprints,
}) {
  const releaseId = 'sensevoice-candidate-001';
  final commit = upstreamCommit ?? input.upstreamCommit;
  final sourceLicense = SenseVoiceArtifactEvidence(
    path: 'legal/source-LICENSE.txt',
    sha256: 'c123456789012345678901234567890123456789012345678901234567890123',
  );
  final modelLicense = SenseVoiceArtifactEvidence(
    path: 'legal/model-LICENSE.txt',
    sha256: 'd123456789012345678901234567890123456789012345678901234567890123',
  );
  final notice = SenseVoiceArtifactEvidence(
    path: 'legal/NOTICE.txt',
    sha256: 'e123456789012345678901234567890123456789012345678901234567890123',
  );
  final sbom = SenseVoiceCycloneDxEvidence(
    path: 'sbom/sensevoice.cdx.json',
    sha256: 'f123456789012345678901234567890123456789012345678901234567890123',
    specVersion: '1.6',
  );
  final resolvedFootprints = footprints ?? _footprints();
  final evidenceFingerprint =
      SenseVoiceDistributionManifest.evidenceFingerprintFor(
        releaseId: releaseId,
        upstreamCommit: commit,
        sourceLicense: sourceLicense,
        modelLicense: modelLicense,
        notice: notice,
        sbom: sbom,
        footprints: resolvedFootprints,
      );
  return SenseVoiceDistributionManifest(
    releaseId: releaseId,
    upstreamCommit: commit,
    sourceLicense: sourceLicense,
    modelLicense: modelLicense,
    notice: notice,
    sbom: sbom,
    legalReview:
        legalReview ??
        _legalReview(
          input,
          result,
          distributionEvidenceFingerprint: evidenceFingerprint,
          upstreamCommit: commit,
        ),
    footprints: resolvedFootprints,
  );
}

SenseVoiceLegalReview _legalReview(
  SenseVoiceBenchmarkInput input,
  SenseVoiceBenchmarkResult result, {
  required String distributionEvidenceFingerprint,
  String? upstreamCommit,
}) => SenseVoiceLegalReview(
  reviewId: 'legal-2026-001',
  reviewerKeyId: 'maaso-legal-key-01',
  upstreamCommit: upstreamCommit ?? input.upstreamCommit,
  benchmarkInputFingerprint: input.fingerprint,
  benchmarkResultFingerprint: result.fingerprint,
  distributionEvidenceFingerprint: distributionEvidenceFingerprint,
  signedAt: result.completedAt.add(const Duration(minutes: 5)),
  signatureAlgorithm: 'ed25519',
  signature: base64Encode(List<int>.filled(64, 7)),
);

Map<AppHostPlatform, SenseVoicePlatformFootprint> _footprints({
  Map<AppHostPlatform, SenseVoicePlatformFootprint> overrides =
      const <AppHostPlatform, SenseVoicePlatformFootprint>{},
}) => <AppHostPlatform, SenseVoicePlatformFootprint>{
  for (final platform in AppHostPlatform.values)
    platform:
        overrides[platform] ??
        _zeroFootprint(
          bundledModelBytes: platform == AppHostPlatform.macos ? 42 : 0,
          unpackedModelBytes: platform == AppHostPlatform.macos ? 84 : 0,
        ),
};

SenseVoicePlatformFootprint _zeroFootprint({
  int bundledModelBytes = 0,
  int downloadedModelBytes = 0,
  int? unpackedModelBytes,
  int downloadCalls = 0,
  int registrationCalls = 0,
  int loadCalls = 0,
  int inferenceCalls = 0,
  bool defaultEnabled = false,
}) => SenseVoicePlatformFootprint(
  bundledModelBytes: bundledModelBytes,
  downloadedModelBytes: downloadedModelBytes,
  unpackedModelBytes:
      unpackedModelBytes ?? (bundledModelBytes == 0 ? 0 : bundledModelBytes),
  downloadCalls: downloadCalls,
  registrationCalls: registrationCalls,
  loadCalls: loadCalls,
  inferenceCalls: inferenceCalls,
  defaultEnabled: defaultEnabled,
);

Map<String, Object?> _deepCopy(Map<String, Object> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
