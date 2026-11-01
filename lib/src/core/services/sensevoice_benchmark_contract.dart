import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

/// Versioned, metadata-only contract for an offline SenseVoice benchmark.
///
/// This contract deliberately has no model factory, byte transport, network,
/// FFI, or runtime registration surface. A separate release tool may consume
/// the JSON contract, but production startup must not import such a tool.
final class SenseVoiceBenchmarkInput {
  SenseVoiceBenchmarkInput({
    required this.runId,
    required this.platform,
    required this.upstreamCommit,
    required this.datasetId,
    required this.datasetManifestSha256,
    required this.datasetLicenseSpdx,
    required this.sampleCount,
    required this.warmupRuns,
    required this.measuredRuns,
    required DateTime createdAt,
  }) : createdAt = createdAt.toUtc() {
    _boundedToken(runId, field: 'runId', maximum: 96);
    if (!_desktopPlatforms.contains(platform)) {
      throw ArgumentError.value(platform, 'platform', 'must be desktop');
    }
    _commit(upstreamCommit, field: 'upstreamCommit');
    _boundedToken(datasetId, field: 'datasetId', maximum: 128);
    _sha256(datasetManifestSha256, field: 'datasetManifestSha256');
    _boundedToken(datasetLicenseSpdx, field: 'datasetLicenseSpdx', maximum: 96);
    _positive(sampleCount, field: 'sampleCount');
    _nonNegative(warmupRuns, field: 'warmupRuns');
    _positive(measuredRuns, field: 'measuredRuns');
    if (measuredRuns > 100 || warmupRuns > 100) {
      throw ArgumentError('benchmark run counts must be at most 100');
    }
  }

  static const int schemaVersion = 1;

  final String runId;
  final AppHostPlatform platform;
  final String upstreamCommit;
  final String datasetId;
  final String datasetManifestSha256;
  final String datasetLicenseSpdx;
  final int sampleCount;
  final int warmupRuns;
  final int measuredRuns;
  final DateTime createdAt;

  String get fingerprint =>
      sha256.convert(utf8.encode(_canonicalJson(toJson()))).toString();

  Map<String, Object> toJson() => <String, Object>{
    'schemaVersion': schemaVersion,
    'runId': runId,
    'platform': platform.name,
    'upstreamCommit': upstreamCommit,
    'datasetId': datasetId,
    'datasetManifestSha256': datasetManifestSha256,
    'datasetLicenseSpdx': datasetLicenseSpdx,
    'sampleCount': sampleCount,
    'warmupRuns': warmupRuns,
    'measuredRuns': measuredRuns,
    'createdAt': createdAt.toIso8601String(),
  };

  factory SenseVoiceBenchmarkInput.fromJson(Map<String, Object?> json) {
    _exactKeys(json, const <String>{
      'schemaVersion',
      'runId',
      'platform',
      'upstreamCommit',
      'datasetId',
      'datasetManifestSha256',
      'datasetLicenseSpdx',
      'sampleCount',
      'warmupRuns',
      'measuredRuns',
      'createdAt',
    });
    _schema(json['schemaVersion']);
    return SenseVoiceBenchmarkInput(
      runId: _string(json, 'runId'),
      platform: _platform(_string(json, 'platform')),
      upstreamCommit: _string(json, 'upstreamCommit'),
      datasetId: _string(json, 'datasetId'),
      datasetManifestSha256: _string(json, 'datasetManifestSha256'),
      datasetLicenseSpdx: _string(json, 'datasetLicenseSpdx'),
      sampleCount: _integer(json, 'sampleCount'),
      warmupRuns: _integer(json, 'warmupRuns'),
      measuredRuns: _integer(json, 'measuredRuns'),
      createdAt: _date(json, 'createdAt'),
    );
  }
}

/// Fixed release thresholds. They are not supplied by benchmark input or
/// release manifests, preventing a candidate from relaxing its own gate.
abstract final class SenseVoiceBenchmarkThresholds {
  static const int minimumSuccessfulSamples = 100;
  static const double maximumMedianLatencyMs = 250;
  static const double maximumP95LatencyMs = 600;
  static const double maximumP95RealtimeFactor = 0.60;
  static const double maximumCharacterErrorRate = 0.15;
  static const int maximumPeakResidentBytes = 768 * 1024 * 1024;
  static const int maximumBundledModelBytes = 300 * 1024 * 1024;
  static const int maximumUnpackedModelBytes = 500 * 1024 * 1024;
  static const int maximumCrashes = 0;
  static const int maximumTimeouts = 0;
}

enum SenseVoiceBenchmarkFailure {
  inputMismatch,
  insufficientSuccessfulSamples,
  medianLatency,
  p95Latency,
  realtimeFactor,
  characterErrorRate,
  peakResidentMemory,
  crash,
  timeout,
}

final class SenseVoiceBenchmarkVerdict {
  const SenseVoiceBenchmarkVerdict(this.failures);

  final List<SenseVoiceBenchmarkFailure> failures;

  bool get passed => failures.isEmpty;
}

/// Strict output produced by a benchmark runner outside the app runtime.
final class SenseVoiceBenchmarkResult {
  SenseVoiceBenchmarkResult({
    required this.runId,
    required this.inputFingerprint,
    required this.upstreamCommit,
    required this.successfulSamples,
    required this.medianLatencyMs,
    required this.p95LatencyMs,
    required this.p95RealtimeFactor,
    required this.characterErrorRate,
    required this.peakResidentBytes,
    required this.crashes,
    required this.timeouts,
    required DateTime completedAt,
  }) : completedAt = completedAt.toUtc() {
    _boundedToken(runId, field: 'runId', maximum: 96);
    _sha256(inputFingerprint, field: 'inputFingerprint');
    _commit(upstreamCommit, field: 'upstreamCommit');
    _nonNegative(successfulSamples, field: 'successfulSamples');
    _finiteNonNegative(medianLatencyMs, field: 'medianLatencyMs');
    _finiteNonNegative(p95LatencyMs, field: 'p95LatencyMs');
    _finiteNonNegative(p95RealtimeFactor, field: 'p95RealtimeFactor');
    _finiteRange(characterErrorRate, field: 'characterErrorRate', maximum: 1);
    _nonNegative(peakResidentBytes, field: 'peakResidentBytes');
    _nonNegative(crashes, field: 'crashes');
    _nonNegative(timeouts, field: 'timeouts');
  }

  static const int schemaVersion = 1;

  final String runId;
  final String inputFingerprint;
  final String upstreamCommit;
  final int successfulSamples;
  final double medianLatencyMs;
  final double p95LatencyMs;
  final double p95RealtimeFactor;
  final double characterErrorRate;
  final int peakResidentBytes;
  final int crashes;
  final int timeouts;
  final DateTime completedAt;

  String get fingerprint =>
      sha256.convert(utf8.encode(_canonicalJson(toJson()))).toString();

  SenseVoiceBenchmarkVerdict evaluate(SenseVoiceBenchmarkInput input) {
    final failures = <SenseVoiceBenchmarkFailure>[];
    if (runId != input.runId ||
        inputFingerprint != input.fingerprint ||
        upstreamCommit != input.upstreamCommit ||
        completedAt.isBefore(input.createdAt)) {
      failures.add(SenseVoiceBenchmarkFailure.inputMismatch);
    }
    if (successfulSamples <
            SenseVoiceBenchmarkThresholds.minimumSuccessfulSamples ||
        successfulSamples > input.sampleCount) {
      failures.add(SenseVoiceBenchmarkFailure.insufficientSuccessfulSamples);
    }
    if (medianLatencyMs >
        SenseVoiceBenchmarkThresholds.maximumMedianLatencyMs) {
      failures.add(SenseVoiceBenchmarkFailure.medianLatency);
    }
    if (p95LatencyMs > SenseVoiceBenchmarkThresholds.maximumP95LatencyMs) {
      failures.add(SenseVoiceBenchmarkFailure.p95Latency);
    }
    if (p95RealtimeFactor >
        SenseVoiceBenchmarkThresholds.maximumP95RealtimeFactor) {
      failures.add(SenseVoiceBenchmarkFailure.realtimeFactor);
    }
    if (characterErrorRate >
        SenseVoiceBenchmarkThresholds.maximumCharacterErrorRate) {
      failures.add(SenseVoiceBenchmarkFailure.characterErrorRate);
    }
    if (peakResidentBytes >
        SenseVoiceBenchmarkThresholds.maximumPeakResidentBytes) {
      failures.add(SenseVoiceBenchmarkFailure.peakResidentMemory);
    }
    if (crashes > SenseVoiceBenchmarkThresholds.maximumCrashes) {
      failures.add(SenseVoiceBenchmarkFailure.crash);
    }
    if (timeouts > SenseVoiceBenchmarkThresholds.maximumTimeouts) {
      failures.add(SenseVoiceBenchmarkFailure.timeout);
    }
    return SenseVoiceBenchmarkVerdict(List.unmodifiable(failures));
  }

  Map<String, Object> toJson() => <String, Object>{
    'schemaVersion': schemaVersion,
    'runId': runId,
    'inputFingerprint': inputFingerprint,
    'upstreamCommit': upstreamCommit,
    'successfulSamples': successfulSamples,
    'medianLatencyMs': medianLatencyMs,
    'p95LatencyMs': p95LatencyMs,
    'p95RealtimeFactor': p95RealtimeFactor,
    'characterErrorRate': characterErrorRate,
    'peakResidentBytes': peakResidentBytes,
    'crashes': crashes,
    'timeouts': timeouts,
    'completedAt': completedAt.toIso8601String(),
  };

  factory SenseVoiceBenchmarkResult.fromJson(Map<String, Object?> json) {
    _exactKeys(json, const <String>{
      'schemaVersion',
      'runId',
      'inputFingerprint',
      'upstreamCommit',
      'successfulSamples',
      'medianLatencyMs',
      'p95LatencyMs',
      'p95RealtimeFactor',
      'characterErrorRate',
      'peakResidentBytes',
      'crashes',
      'timeouts',
      'completedAt',
    });
    _schema(json['schemaVersion']);
    return SenseVoiceBenchmarkResult(
      runId: _string(json, 'runId'),
      inputFingerprint: _string(json, 'inputFingerprint'),
      upstreamCommit: _string(json, 'upstreamCommit'),
      successfulSamples: _integer(json, 'successfulSamples'),
      medianLatencyMs: _number(json, 'medianLatencyMs'),
      p95LatencyMs: _number(json, 'p95LatencyMs'),
      p95RealtimeFactor: _number(json, 'p95RealtimeFactor'),
      characterErrorRate: _number(json, 'characterErrorRate'),
      peakResidentBytes: _integer(json, 'peakResidentBytes'),
      crashes: _integer(json, 'crashes'),
      timeouts: _integer(json, 'timeouts'),
      completedAt: _date(json, 'completedAt'),
    );
  }
}

final class SenseVoiceArtifactEvidence {
  SenseVoiceArtifactEvidence({required this.path, required this.sha256}) {
    _relativePath(path, field: 'path');
    _sha256(sha256, field: 'sha256');
  }

  final String path;
  final String sha256;

  Map<String, Object> toJson() => <String, Object>{
    'path': path,
    'sha256': sha256,
  };

  factory SenseVoiceArtifactEvidence.fromJson(Map<String, Object?> json) {
    _exactKeys(json, const <String>{'path', 'sha256'});
    return SenseVoiceArtifactEvidence(
      path: _string(json, 'path'),
      sha256: _string(json, 'sha256'),
    );
  }
}

final class SenseVoiceCycloneDxEvidence {
  SenseVoiceCycloneDxEvidence({
    required this.path,
    required this.sha256,
    required this.specVersion,
  }) {
    _relativePath(path, field: 'sbom.path');
    _sha256(sha256, field: 'sbom.sha256');
    if (specVersion != '1.5' && specVersion != '1.6') {
      throw ArgumentError.value(
        specVersion,
        'specVersion',
        'must be 1.5 or 1.6',
      );
    }
  }

  static const String format = 'CycloneDX';
  static const String mediaType = 'application/vnd.cyclonedx+json';

  final String path;
  final String sha256;
  final String specVersion;

  Map<String, Object> toJson() => <String, Object>{
    'path': path,
    'sha256': sha256,
    'format': format,
    'specVersion': specVersion,
    'mediaType': mediaType,
  };

  factory SenseVoiceCycloneDxEvidence.fromJson(Map<String, Object?> json) {
    _exactKeys(json, const <String>{
      'path',
      'sha256',
      'format',
      'specVersion',
      'mediaType',
    });
    if (_string(json, 'format') != format ||
        _string(json, 'mediaType') != mediaType) {
      throw const FormatException('SBOM must be CycloneDX JSON');
    }
    return SenseVoiceCycloneDxEvidence(
      path: _string(json, 'path'),
      sha256: _string(json, 'sha256'),
      specVersion: _string(json, 'specVersion'),
    );
  }
}

final class SenseVoiceLegalReview {
  SenseVoiceLegalReview({
    required this.reviewId,
    required this.reviewerKeyId,
    required this.upstreamCommit,
    required this.benchmarkInputFingerprint,
    required this.benchmarkResultFingerprint,
    required this.distributionEvidenceFingerprint,
    required DateTime signedAt,
    required this.signatureAlgorithm,
    required this.signature,
  }) : signedAt = signedAt.toUtc() {
    _boundedToken(reviewId, field: 'reviewId', maximum: 128);
    _boundedToken(reviewerKeyId, field: 'reviewerKeyId', maximum: 128);
    _commit(upstreamCommit, field: 'upstreamCommit');
    _sha256(benchmarkInputFingerprint, field: 'benchmarkInputFingerprint');
    _sha256(benchmarkResultFingerprint, field: 'benchmarkResultFingerprint');
    _sha256(
      distributionEvidenceFingerprint,
      field: 'distributionEvidenceFingerprint',
    );
    if (signatureAlgorithm != 'ed25519') {
      throw ArgumentError.value(
        signatureAlgorithm,
        'signatureAlgorithm',
        'must be ed25519',
      );
    }
    try {
      final decoded = base64Decode(signature);
      if (decoded.length != 64 || base64Encode(decoded) != signature) {
        throw const FormatException();
      }
    } on FormatException {
      throw ArgumentError.value(
        signature,
        'signature',
        'must be a canonical 64-byte Ed25519 signature',
      );
    }
  }

  static const int schemaVersion = 1;
  static const String approvalScope = 'sensevoice_desktop_distribution';

  final String reviewId;
  final String reviewerKeyId;
  final String upstreamCommit;
  final String benchmarkInputFingerprint;
  final String benchmarkResultFingerprint;
  final String distributionEvidenceFingerprint;
  final DateTime signedAt;
  final String signatureAlgorithm;
  final String signature;

  String get canonicalPayload => _canonicalJson(<String, Object>{
    'schemaVersion': schemaVersion,
    'approvalScope': approvalScope,
    'reviewId': reviewId,
    'reviewerKeyId': reviewerKeyId,
    'upstreamCommit': upstreamCommit,
    'benchmarkInputFingerprint': benchmarkInputFingerprint,
    'benchmarkResultFingerprint': benchmarkResultFingerprint,
    'distributionEvidenceFingerprint': distributionEvidenceFingerprint,
    'signedAt': signedAt.toIso8601String(),
    'signatureAlgorithm': signatureAlgorithm,
  });

  Map<String, Object> toJson() => <String, Object>{
    'schemaVersion': schemaVersion,
    'approvalScope': approvalScope,
    'reviewId': reviewId,
    'reviewerKeyId': reviewerKeyId,
    'upstreamCommit': upstreamCommit,
    'benchmarkInputFingerprint': benchmarkInputFingerprint,
    'benchmarkResultFingerprint': benchmarkResultFingerprint,
    'distributionEvidenceFingerprint': distributionEvidenceFingerprint,
    'signedAt': signedAt.toIso8601String(),
    'signatureAlgorithm': signatureAlgorithm,
    'signature': signature,
  };

  factory SenseVoiceLegalReview.fromJson(Map<String, Object?> json) {
    _exactKeys(json, const <String>{
      'schemaVersion',
      'approvalScope',
      'reviewId',
      'reviewerKeyId',
      'upstreamCommit',
      'benchmarkInputFingerprint',
      'benchmarkResultFingerprint',
      'distributionEvidenceFingerprint',
      'signedAt',
      'signatureAlgorithm',
      'signature',
    });
    _schema(json['schemaVersion']);
    if (_string(json, 'approvalScope') != approvalScope) {
      throw const FormatException('invalid legal review approval scope');
    }
    return SenseVoiceLegalReview(
      reviewId: _string(json, 'reviewId'),
      reviewerKeyId: _string(json, 'reviewerKeyId'),
      upstreamCommit: _string(json, 'upstreamCommit'),
      benchmarkInputFingerprint: _string(json, 'benchmarkInputFingerprint'),
      benchmarkResultFingerprint: _string(json, 'benchmarkResultFingerprint'),
      distributionEvidenceFingerprint: _string(
        json,
        'distributionEvidenceFingerprint',
      ),
      signedAt: _date(json, 'signedAt'),
      signatureAlgorithm: _string(json, 'signatureAlgorithm'),
      signature: _string(json, 'signature'),
    );
  }
}

/// Measured release/startup footprint for one host platform.
final class SenseVoicePlatformFootprint {
  SenseVoicePlatformFootprint({
    required this.bundledModelBytes,
    required this.downloadedModelBytes,
    required this.unpackedModelBytes,
    required this.downloadCalls,
    required this.registrationCalls,
    required this.loadCalls,
    required this.inferenceCalls,
    required this.defaultEnabled,
  }) {
    _nonNegative(bundledModelBytes, field: 'bundledModelBytes');
    _nonNegative(downloadedModelBytes, field: 'downloadedModelBytes');
    _nonNegative(unpackedModelBytes, field: 'unpackedModelBytes');
    _nonNegative(downloadCalls, field: 'downloadCalls');
    _nonNegative(registrationCalls, field: 'registrationCalls');
    _nonNegative(loadCalls, field: 'loadCalls');
    _nonNegative(inferenceCalls, field: 'inferenceCalls');
  }

  final int bundledModelBytes;
  final int downloadedModelBytes;
  final int unpackedModelBytes;
  final int downloadCalls;
  final int registrationCalls;
  final int loadCalls;
  final int inferenceCalls;
  final bool defaultEnabled;

  Map<String, Object> toJson() => <String, Object>{
    'bundledModelBytes': bundledModelBytes,
    'downloadedModelBytes': downloadedModelBytes,
    'unpackedModelBytes': unpackedModelBytes,
    'downloadCalls': downloadCalls,
    'registrationCalls': registrationCalls,
    'loadCalls': loadCalls,
    'inferenceCalls': inferenceCalls,
    'defaultEnabled': defaultEnabled,
  };

  factory SenseVoicePlatformFootprint.fromJson(Map<String, Object?> json) {
    _exactKeys(json, const <String>{
      'bundledModelBytes',
      'downloadedModelBytes',
      'unpackedModelBytes',
      'downloadCalls',
      'registrationCalls',
      'loadCalls',
      'inferenceCalls',
      'defaultEnabled',
    });
    final enabled = json['defaultEnabled'];
    if (enabled is! bool) {
      throw const FormatException('defaultEnabled must be a bool');
    }
    return SenseVoicePlatformFootprint(
      bundledModelBytes: _integer(json, 'bundledModelBytes'),
      downloadedModelBytes: _integer(json, 'downloadedModelBytes'),
      unpackedModelBytes: _integer(json, 'unpackedModelBytes'),
      downloadCalls: _integer(json, 'downloadCalls'),
      registrationCalls: _integer(json, 'registrationCalls'),
      loadCalls: _integer(json, 'loadCalls'),
      inferenceCalls: _integer(json, 'inferenceCalls'),
      defaultEnabled: enabled,
    );
  }
}

final class SenseVoiceDistributionManifest {
  SenseVoiceDistributionManifest({
    required this.releaseId,
    required this.upstreamCommit,
    required this.sourceLicense,
    required this.modelLicense,
    required this.notice,
    required this.sbom,
    required this.legalReview,
    required Map<AppHostPlatform, SenseVoicePlatformFootprint> footprints,
  }) : footprints = Map.unmodifiable(footprints) {
    _boundedToken(releaseId, field: 'releaseId', maximum: 128);
    _commit(upstreamCommit, field: 'upstreamCommit');
    if (footprints.keys.toSet().length != AppHostPlatform.values.length ||
        !footprints.keys.toSet().containsAll(AppHostPlatform.values)) {
      throw ArgumentError('footprints must contain every host platform');
    }
  }

  static const int schemaVersion = 1;

  final String releaseId;
  final String upstreamCommit;
  final SenseVoiceArtifactEvidence sourceLicense;
  final SenseVoiceArtifactEvidence modelLicense;
  final SenseVoiceArtifactEvidence notice;
  final SenseVoiceCycloneDxEvidence sbom;
  final SenseVoiceLegalReview legalReview;
  final Map<AppHostPlatform, SenseVoicePlatformFootprint> footprints;

  String get evidenceFingerprint => evidenceFingerprintFor(
    releaseId: releaseId,
    upstreamCommit: upstreamCommit,
    sourceLicense: sourceLicense,
    modelLicense: modelLicense,
    notice: notice,
    sbom: sbom,
    footprints: footprints,
  );

  static String evidenceFingerprintFor({
    required String releaseId,
    required String upstreamCommit,
    required SenseVoiceArtifactEvidence sourceLicense,
    required SenseVoiceArtifactEvidence modelLicense,
    required SenseVoiceArtifactEvidence notice,
    required SenseVoiceCycloneDxEvidence sbom,
    required Map<AppHostPlatform, SenseVoicePlatformFootprint> footprints,
  }) => sha256
      .convert(
        utf8.encode(
          _canonicalJson(<String, Object>{
            'schemaVersion': schemaVersion,
            'releaseId': releaseId,
            'upstreamCommit': upstreamCommit,
            'sourceLicense': sourceLicense.toJson(),
            'modelLicense': modelLicense.toJson(),
            'notice': notice.toJson(),
            'sbom': sbom.toJson(),
            'footprints': <String, Object>{
              for (final platform in AppHostPlatform.values)
                platform.name: footprints[platform]?.toJson() ?? const {},
            },
          }),
        ),
      )
      .toString();

  Map<String, Object> toJson() => <String, Object>{
    'schemaVersion': schemaVersion,
    'releaseId': releaseId,
    'upstreamCommit': upstreamCommit,
    'sourceLicense': sourceLicense.toJson(),
    'modelLicense': modelLicense.toJson(),
    'notice': notice.toJson(),
    'sbom': sbom.toJson(),
    'legalReview': legalReview.toJson(),
    'footprints': <String, Object>{
      for (final platform in AppHostPlatform.values)
        platform.name: footprints[platform]!.toJson(),
    },
  };

  factory SenseVoiceDistributionManifest.fromJson(Map<String, Object?> json) {
    _exactKeys(json, const <String>{
      'schemaVersion',
      'releaseId',
      'upstreamCommit',
      'sourceLicense',
      'modelLicense',
      'notice',
      'sbom',
      'legalReview',
      'footprints',
    });
    _schema(json['schemaVersion']);
    final footprintJson = _object(json, 'footprints');
    _exactKeys(
      footprintJson,
      AppHostPlatform.values.map((e) => e.name).toSet(),
    );
    return SenseVoiceDistributionManifest(
      releaseId: _string(json, 'releaseId'),
      upstreamCommit: _string(json, 'upstreamCommit'),
      sourceLicense: SenseVoiceArtifactEvidence.fromJson(
        _object(json, 'sourceLicense'),
      ),
      modelLicense: SenseVoiceArtifactEvidence.fromJson(
        _object(json, 'modelLicense'),
      ),
      notice: SenseVoiceArtifactEvidence.fromJson(_object(json, 'notice')),
      sbom: SenseVoiceCycloneDxEvidence.fromJson(_object(json, 'sbom')),
      legalReview: SenseVoiceLegalReview.fromJson(_object(json, 'legalReview')),
      footprints: <AppHostPlatform, SenseVoicePlatformFootprint>{
        for (final platform in AppHostPlatform.values)
          platform: SenseVoicePlatformFootprint.fromJson(
            _object(footprintJson, platform.name),
          ),
      },
    );
  }
}

/// Release tooling must verify bytes and signatures outside the app process.
/// Implementations should use a trusted-key store and hash the staged bundle.
abstract interface class SenseVoiceDistributionEvidenceVerifier {
  bool artifactMatches(SenseVoiceArtifactEvidence evidence);

  bool sbomMatches(SenseVoiceCycloneDxEvidence evidence);

  bool legalSignatureMatches(SenseVoiceLegalReview review);
}

enum SenseVoiceDistributionFailure {
  benchmark,
  upstreamCommit,
  sourceLicense,
  modelLicense,
  notice,
  cycloneDxSbom,
  legalReviewBinding,
  legalReviewSignature,
  mobileOrWebFootprint,
  desktopDefault,
  desktopStartupActivity,
  desktopArtifactSize,
  unbenchmarkedDesktopArtifact,
  evidenceVerifier,
}

final class SenseVoiceDistributionVerdict {
  const SenseVoiceDistributionVerdict(this.failures);

  final List<SenseVoiceDistributionFailure> failures;

  bool get approved => failures.isEmpty;
}

/// Fail-closed distribution gate. It evaluates evidence only and cannot load,
/// register, download, or invoke SenseVoice.
abstract final class SenseVoiceDistributionGate {
  static SenseVoiceDistributionVerdict evaluate({
    required SenseVoiceBenchmarkInput benchmarkInput,
    required SenseVoiceBenchmarkResult benchmarkResult,
    required SenseVoiceDistributionManifest manifest,
    required SenseVoiceDistributionEvidenceVerifier verifier,
  }) {
    final failures = <SenseVoiceDistributionFailure>[];
    if (!benchmarkResult.evaluate(benchmarkInput).passed) {
      failures.add(SenseVoiceDistributionFailure.benchmark);
    }
    if (manifest.upstreamCommit != benchmarkInput.upstreamCommit ||
        manifest.upstreamCommit != benchmarkResult.upstreamCommit) {
      failures.add(SenseVoiceDistributionFailure.upstreamCommit);
    }
    if (manifest.legalReview.upstreamCommit != manifest.upstreamCommit ||
        manifest.legalReview.benchmarkInputFingerprint !=
            benchmarkInput.fingerprint ||
        manifest.legalReview.benchmarkResultFingerprint !=
            benchmarkResult.fingerprint ||
        manifest.legalReview.distributionEvidenceFingerprint !=
            manifest.evidenceFingerprint ||
        manifest.legalReview.signedAt.isBefore(benchmarkResult.completedAt)) {
      failures.add(SenseVoiceDistributionFailure.legalReviewBinding);
    }

    try {
      if (!verifier.artifactMatches(manifest.sourceLicense)) {
        failures.add(SenseVoiceDistributionFailure.sourceLicense);
      }
      if (!verifier.artifactMatches(manifest.modelLicense)) {
        failures.add(SenseVoiceDistributionFailure.modelLicense);
      }
      if (!verifier.artifactMatches(manifest.notice)) {
        failures.add(SenseVoiceDistributionFailure.notice);
      }
      if (!verifier.sbomMatches(manifest.sbom)) {
        failures.add(SenseVoiceDistributionFailure.cycloneDxSbom);
      }
      if (!verifier.legalSignatureMatches(manifest.legalReview)) {
        failures.add(SenseVoiceDistributionFailure.legalReviewSignature);
      }
    } catch (_) {
      failures.add(SenseVoiceDistributionFailure.evidenceVerifier);
    }

    for (final entry in manifest.footprints.entries) {
      final footprint = entry.value;
      if (_desktopPlatforms.contains(entry.key)) {
        if (footprint.defaultEnabled) {
          failures.add(SenseVoiceDistributionFailure.desktopDefault);
        }
        if (footprint.downloadCalls != 0 ||
            footprint.registrationCalls != 0 ||
            footprint.loadCalls != 0 ||
            footprint.inferenceCalls != 0 ||
            footprint.downloadedModelBytes != 0) {
          failures.add(SenseVoiceDistributionFailure.desktopStartupActivity);
        }
        if (footprint.bundledModelBytes >
                SenseVoiceBenchmarkThresholds.maximumBundledModelBytes ||
            footprint.unpackedModelBytes >
                SenseVoiceBenchmarkThresholds.maximumUnpackedModelBytes ||
            (footprint.bundledModelBytes == 0) !=
                (footprint.unpackedModelBytes == 0)) {
          failures.add(SenseVoiceDistributionFailure.desktopArtifactSize);
        }
        if (entry.key != benchmarkInput.platform &&
            (footprint.bundledModelBytes != 0 ||
                footprint.unpackedModelBytes != 0)) {
          failures.add(
            SenseVoiceDistributionFailure.unbenchmarkedDesktopArtifact,
          );
        }
      } else if (footprint.bundledModelBytes != 0 ||
          footprint.downloadedModelBytes != 0 ||
          footprint.unpackedModelBytes != 0 ||
          footprint.downloadCalls != 0 ||
          footprint.registrationCalls != 0 ||
          footprint.loadCalls != 0 ||
          footprint.inferenceCalls != 0 ||
          footprint.defaultEnabled) {
        failures.add(SenseVoiceDistributionFailure.mobileOrWebFootprint);
      }
    }

    return SenseVoiceDistributionVerdict(List.unmodifiable(failures.toSet()));
  }
}

const Set<AppHostPlatform> _desktopPlatforms = <AppHostPlatform>{
  AppHostPlatform.macos,
  AppHostPlatform.windows,
  AppHostPlatform.linux,
};

final RegExp _commitPattern = RegExp(r'^[0-9a-f]{40}$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:+-]*$');

String _canonicalJson(Object? value) {
  Object? normalize(Object? current) {
    if (current is Map) {
      final keys = current.keys.cast<String>().toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: normalize(current[key]),
      };
    }
    if (current is List) {
      return current.map(normalize).toList(growable: false);
    }
    return current;
  }

  return jsonEncode(normalize(value));
}

void _exactKeys(Map<String, Object?> value, Set<String> expected) {
  if (value.keys.toSet().length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw FormatException(
      'expected fields ${expected.toList()..sort()}, got ${value.keys.toList()..sort()}',
    );
  }
}

void _schema(Object? value) {
  if (value != 1) {
    throw const FormatException('unsupported schemaVersion');
  }
}

String _string(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) {
    throw FormatException('$field must be a string');
  }
  return value;
}

int _integer(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int) {
    throw FormatException('$field must be an integer');
  }
  return value;
}

double _number(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! num) {
    throw FormatException('$field must be a number');
  }
  return value.toDouble();
}

Map<String, Object?> _object(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! Map) {
    throw FormatException('$field must be an object');
  }
  try {
    return value.cast<String, Object?>();
  } on TypeError {
    throw FormatException('$field must have string keys');
  }
}

DateTime _date(Map<String, Object?> json, String field) {
  final value = _string(json, field);
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !value.endsWith('Z')) {
    throw FormatException('$field must be an ISO-8601 UTC instant');
  }
  return parsed.toUtc();
}

AppHostPlatform _platform(String value) {
  for (final platform in AppHostPlatform.values) {
    if (platform.name == value) return platform;
  }
  throw FormatException('unsupported platform: $value');
}

void _boundedToken(
  String value, {
  required String field,
  required int maximum,
}) {
  if (value.length > maximum || !_tokenPattern.hasMatch(value)) {
    throw ArgumentError.value(value, field, 'must be a bounded token');
  }
}

void _relativePath(String value, {required String field}) {
  if (value.isEmpty ||
      value.length > 256 ||
      !RegExp(
        r'^[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$',
      ).hasMatch(value) ||
      value.split('/').any((segment) => segment == '.' || segment == '..')) {
    throw ArgumentError.value(value, field, 'must be a safe relative path');
  }
}

void _sha256(String value, {required String field}) {
  if (!_sha256Pattern.hasMatch(value)) {
    throw ArgumentError.value(value, field, 'must be lowercase SHA-256');
  }
}

void _commit(String value, {required String field}) {
  if (!_commitPattern.hasMatch(value)) {
    throw ArgumentError.value(value, field, 'must be a pinned 40-hex commit');
  }
}

void _positive(int value, {required String field}) {
  if (value <= 0) throw ArgumentError.value(value, field, 'must be positive');
}

void _nonNegative(int value, {required String field}) {
  if (value < 0) {
    throw ArgumentError.value(value, field, 'must be non-negative');
  }
}

void _finiteNonNegative(double value, {required String field}) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError.value(value, field, 'must be finite and non-negative');
  }
}

void _finiteRange(
  double value, {
  required String field,
  required double maximum,
}) {
  if (!value.isFinite || value < 0 || value > maximum) {
    throw ArgumentError.value(value, field, 'must be between 0 and $maximum');
  }
}
