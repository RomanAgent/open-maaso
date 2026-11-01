import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/sensevoice_benchmark_contract.dart';

void main() {
  group('SenseVoice benchmark contract', () {
    test('strict input and output round-trip with immutable binding', () {
      final input = _input();
      final decodedInput = SenseVoiceBenchmarkInput.fromJson(input.toJson());
      final result = _passingResult(decodedInput);
      final decodedResult = SenseVoiceBenchmarkResult.fromJson(result.toJson());

      expect(decodedInput.fingerprint, input.fingerprint);
      expect(decodedResult.evaluate(decodedInput).passed, isTrue);
      expect(decodedResult.inputFingerprint, decodedInput.fingerprint);
    });

    test('input rejects mobile runs and unpinned upstream revisions', () {
      expect(
        () => _input(platform: AppHostPlatform.android),
        throwsArgumentError,
      );
      expect(() => _input(upstreamCommit: 'main'), throwsArgumentError);
    });

    test('parsers reject unknown, missing, and wrong-typed fields', () {
      final withUnknown = <String, Object?>{
        ..._input().toJson(),
        'relaxedThreshold': true,
      };
      expect(
        () => SenseVoiceBenchmarkInput.fromJson(withUnknown),
        throwsFormatException,
      );

      final missing = <String, Object?>{..._passingResult(_input()).toJson()}
        ..remove('crashes');
      expect(
        () => SenseVoiceBenchmarkResult.fromJson(missing),
        throwsFormatException,
      );

      final wrongType = <String, Object?>{
        ..._input().toJson(),
        'sampleCount': 100.0,
      };
      expect(
        () => SenseVoiceBenchmarkInput.fromJson(wrongType),
        throwsFormatException,
      );
    });

    test('fixed thresholds cannot be supplied by benchmark JSON', () {
      expect(SenseVoiceBenchmarkThresholds.minimumSuccessfulSamples, 100);
      expect(SenseVoiceBenchmarkThresholds.maximumMedianLatencyMs, 250);
      expect(SenseVoiceBenchmarkThresholds.maximumP95LatencyMs, 600);
      expect(SenseVoiceBenchmarkThresholds.maximumP95RealtimeFactor, 0.60);
      expect(SenseVoiceBenchmarkThresholds.maximumCharacterErrorRate, 0.15);
      expect(
        SenseVoiceBenchmarkThresholds.maximumPeakResidentBytes,
        768 * 1024 * 1024,
      );

      final json = <String, Object?>{
        ..._input().toJson(),
        'maximumCharacterErrorRate': 1.0,
      };
      expect(
        () => SenseVoiceBenchmarkInput.fromJson(json),
        throwsFormatException,
      );
    });

    test('every threshold and input binding fails closed', () {
      final input = _input();

      SenseVoiceBenchmarkFailure failureFor(SenseVoiceBenchmarkResult result) =>
          result.evaluate(input).failures.single;

      expect(
        failureFor(_passingResult(input, successfulSamples: 99)),
        SenseVoiceBenchmarkFailure.insufficientSuccessfulSamples,
      );
      expect(
        failureFor(_passingResult(input, medianLatencyMs: 250.01)),
        SenseVoiceBenchmarkFailure.medianLatency,
      );
      expect(
        failureFor(_passingResult(input, p95LatencyMs: 600.01)),
        SenseVoiceBenchmarkFailure.p95Latency,
      );
      expect(
        failureFor(_passingResult(input, p95RealtimeFactor: 0.61)),
        SenseVoiceBenchmarkFailure.realtimeFactor,
      );
      expect(
        failureFor(_passingResult(input, characterErrorRate: 0.151)),
        SenseVoiceBenchmarkFailure.characterErrorRate,
      );
      expect(
        failureFor(
          _passingResult(input, peakResidentBytes: 768 * 1024 * 1024 + 1),
        ),
        SenseVoiceBenchmarkFailure.peakResidentMemory,
      );
      expect(
        failureFor(_passingResult(input, crashes: 1)),
        SenseVoiceBenchmarkFailure.crash,
      );
      expect(
        failureFor(_passingResult(input, timeouts: 1)),
        SenseVoiceBenchmarkFailure.timeout,
      );
      expect(
        failureFor(_passingResult(input, inputFingerprint: 'f' * 64)),
        SenseVoiceBenchmarkFailure.inputMismatch,
      );
    });

    test('metrics reject NaN, infinity, negative, and invalid CER', () {
      final input = _input();
      expect(
        () => _passingResult(input, medianLatencyMs: double.nan),
        throwsArgumentError,
      );
      expect(
        () => _passingResult(input, p95LatencyMs: double.infinity),
        throwsArgumentError,
      );
      expect(
        () => _passingResult(input, p95RealtimeFactor: -0.1),
        throwsArgumentError,
      );
      expect(
        () => _passingResult(input, characterErrorRate: 1.1),
        throwsArgumentError,
      );
    });
  });
}

SenseVoiceBenchmarkInput _input({
  AppHostPlatform platform = AppHostPlatform.macos,
  String upstreamCommit = 'a123456789012345678901234567890123456789',
}) => SenseVoiceBenchmarkInput(
  runId: 'sensevoice-macos-arm64-001',
  platform: platform,
  upstreamCommit: upstreamCommit,
  datasetId: 'maaso-speech-eval-v1',
  datasetManifestSha256:
      'b123456789012345678901234567890123456789012345678901234567890123',
  datasetLicenseSpdx: 'CC-BY-4.0',
  sampleCount: 120,
  warmupRuns: 3,
  measuredRuns: 10,
  createdAt: DateTime.utc(2026, 8, 30, 8),
);

SenseVoiceBenchmarkResult _passingResult(
  SenseVoiceBenchmarkInput input, {
  String? inputFingerprint,
  int successfulSamples = 120,
  double medianLatencyMs = 120,
  double p95LatencyMs = 300,
  double p95RealtimeFactor = 0.4,
  double characterErrorRate = 0.08,
  int peakResidentBytes = 512 * 1024 * 1024,
  int crashes = 0,
  int timeouts = 0,
}) => SenseVoiceBenchmarkResult(
  runId: input.runId,
  inputFingerprint: inputFingerprint ?? input.fingerprint,
  upstreamCommit: input.upstreamCommit,
  successfulSamples: successfulSamples,
  medianLatencyMs: medianLatencyMs,
  p95LatencyMs: p95LatencyMs,
  p95RealtimeFactor: p95RealtimeFactor,
  characterErrorRate: characterErrorRate,
  peakResidentBytes: peakResidentBytes,
  crashes: crashes,
  timeouts: timeouts,
  completedAt: input.createdAt.add(const Duration(minutes: 5)),
);
