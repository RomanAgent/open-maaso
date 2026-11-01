import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/companion_drive_engine.dart';
import 'package:maaso/src/core/services/contact_timing_engine.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/proactive_drive_rollout_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 8, 29, 9);

  setUp(resetAppProviderContainerForTest);
  tearDown(resetAppProviderContainerForTest);

  test('compile rollout ceiling parser is bounded and fail closed', () {
    expect(
      ProactiveDriveRolloutService.parseCompileEnforceMaximumBasisPoints('0'),
      0,
    );
    expect(
      ProactiveDriveRolloutService.parseCompileEnforceMaximumBasisPoints(
        '10000',
      ),
      10000,
    );
    expect(
      ProactiveDriveRolloutService.parseCompileEnforceMaximumBasisPoints(
        '10001',
      ),
      0,
    );
    expect(
      ProactiveDriveRolloutService.parseCompileEnforceMaximumBasisPoints(
        'invalid',
      ),
      0,
    );
  });

  test('account cohort is stable and 5/25/100 percent sets are monotonic', () {
    final fixtures = <String>[
      for (var index = 0; index < 2000; index++) 'account-digest-$index',
    ];
    final first = <String>{
      for (final digest in fixtures)
        if (ProactiveDriveRolloutService.cohortBucketFor(digest)! < 500) digest,
    };
    final quarter = <String>{
      for (final digest in fixtures)
        if (ProactiveDriveRolloutService.cohortBucketFor(digest)! < 2500)
          digest,
    };
    final all = <String>{
      for (final digest in fixtures)
        if (ProactiveDriveRolloutService.cohortBucketFor(digest)! < 10000)
          digest,
    };

    expect(first, isNotEmpty);
    expect(quarter.length, greaterThan(first.length));
    expect(all, fixtures.toSet());
    expect(quarter.containsAll(first), isTrue);
    expect(all.containsAll(quarter), isTrue);
    expect(
      ProactiveDriveRolloutService.cohortBucketFor('account-digest-42'),
      3422,
    );
    expect(ProactiveDriveRolloutService.cohortBucketFor(''), isNull);
  });

  test(
    'enforce starts at 5 percent and runtime target stays under build cap',
    () async {
      final flags = await _enforceFlags(now);
      addTearDown(flags.closeLifecycle);
      final insideFive = _digestInRange(0, 500);
      final outsideFive = _digestInRange(500, 10000);
      final included = ProactiveDriveRolloutService(
        featureFlags: flags,
        accountScopeDigest: insideFive,
        compileEnforceMaximumBasisPoints: 10000,
      );
      final excluded = ProactiveDriveRolloutService(
        featureFlags: flags,
        accountScopeDigest: outsideFive,
        compileEnforceMaximumBasisPoints: 10000,
      );
      addTearDown(included.closeLifecycle);
      addTearDown(excluded.closeLifecycle);

      expect(included.runtimeEnforceBasisPoints, 500);
      expect(included.effectiveMode(), FeatureRolloutMode.enforce);
      expect(excluded.effectiveMode(), FeatureRolloutMode.shadow);

      excluded.setRuntimeEnforceBasisPoints(10000);
      expect(excluded.effectiveMode(), FeatureRolloutMode.enforce);
      expect(excluded.runtimeEnforceBasisPoints, 10000);
      expect(
        () => excluded.setRuntimeEnforceBasisPoints(25000),
        throwsArgumentError,
      );

      final capped = ProactiveDriveRolloutService(
        featureFlags: flags,
        accountScopeDigest: insideFive,
        compileEnforceMaximumBasisPoints: 500,
        initialEnforceBasisPoints: 10000,
      );
      addTearDown(capped.closeLifecycle);
      expect(capped.runtimeEnforceBasisPoints, 500);
      capped.setRuntimeEnforceBasisPoints(2500);
      expect(capped.runtimeEnforceBasisPoints, 500);
    },
  );

  test('posterior readiness falls back to legacy before admission', () async {
    final flags = await _enforceFlags(now);
    final rollout = ProactiveDriveRolloutService(
      featureFlags: flags,
      accountScopeDigest: 'ready-account',
      compileEnforceMaximumBasisPoints: 10000,
      initialEnforceBasisPoints: 10000,
    );
    addTearDown(rollout.closeLifecycle);
    addTearDown(flags.closeLifecycle);

    expect(
      rollout.propose(
        estimate: _estimate(ContactTimingBand.consider),
        selectedOriginalIndex: 1,
        candidateCount: 2,
        posteriorSamples: 4,
      ),
      isNull,
    );
    final admitted = rollout.propose(
      estimate: _estimate(ContactTimingBand.consider),
      selectedOriginalIndex: 1,
      candidateCount: 2,
      posteriorSamples: 5,
    );
    expect(admitted, isNotNull);
    expect(admitted!.decision, ProactiveDriveAdmissionDecision.contact);
    expect(admitted.selectedOriginalIndex, 1);
    expect(rollout.isCurrent(admitted), isTrue);
  });

  test(
    'production admission uses deterministic band, not shadow sample',
    () async {
      final flags = await _enforceFlags(now);
      final rollout = ProactiveDriveRolloutService(
        featureFlags: flags,
        accountScopeDigest: 'band-account',
        compileEnforceMaximumBasisPoints: 10000,
        initialEnforceBasisPoints: 10000,
        minimumPosteriorSamples: 0,
      );
      addTearDown(rollout.closeLifecycle);
      addTearDown(flags.closeLifecycle);

      final hold = rollout.propose(
        estimate: _estimate(ContactTimingBand.observe, shadowOccurrence: true),
        selectedOriginalIndex: 0,
        candidateCount: 1,
        posteriorSamples: 0,
      );
      final contact = rollout.propose(
        estimate: _estimate(ContactTimingBand.consider),
        selectedOriginalIndex: 0,
        candidateCount: 1,
        posteriorSamples: 0,
      );

      expect(hold!.decision, ProactiveDriveAdmissionDecision.hold);
      expect(hold.selectedOriginalIndex, isNull);
      expect(contact!.decision, ProactiveDriveAdmissionDecision.contact);
    },
  );

  test(
    'invalid selected index and policy failure produce a bounded hold',
    () async {
      final flags = await _enforceFlags(now);
      final rollout = ProactiveDriveRolloutService(
        featureFlags: flags,
        accountScopeDigest: 'invalid-index-account',
        compileEnforceMaximumBasisPoints: 10000,
        initialEnforceBasisPoints: 10000,
        minimumPosteriorSamples: 0,
        contactPolicy: (_) => throw StateError('injected policy failure'),
      );
      addTearDown(rollout.closeLifecycle);
      addTearDown(flags.closeLifecycle);

      final failed = rollout.propose(
        estimate: _estimate(ContactTimingBand.consider),
        selectedOriginalIndex: 0,
        candidateCount: 1,
        posteriorSamples: 0,
      );
      final invalid = rollout.propose(
        estimate: _estimate(ContactTimingBand.consider),
        selectedOriginalIndex: 2,
        candidateCount: 1,
        posteriorSamples: 0,
      );

      expect(failed!.decision, ProactiveDriveAdmissionDecision.hold);
      expect(invalid!.decision, ProactiveDriveAdmissionDecision.hold);
    },
  );

  test(
    'runtime and feature kill switches invalidate old admissions across ABA',
    () async {
      final flags = await _enforceFlags(now);
      final rollout = ProactiveDriveRolloutService(
        featureFlags: flags,
        accountScopeDigest: 'kill-switch-account',
        compileEnforceMaximumBasisPoints: 10000,
        initialEnforceBasisPoints: 10000,
        minimumPosteriorSamples: 0,
      );
      addTearDown(rollout.closeLifecycle);
      addTearDown(flags.closeLifecycle);

      final first = rollout.propose(
        estimate: _estimate(ContactTimingBand.consider),
        selectedOriginalIndex: 0,
        candidateCount: 1,
        posteriorSamples: 0,
      )!;
      rollout.disableEnforcement();
      expect(rollout.effectiveMode(), FeatureRolloutMode.shadow);
      expect(rollout.isCurrent(first), isFalse);
      rollout.setRuntimeEnforceBasisPoints(10000);
      expect(rollout.effectiveMode(), FeatureRolloutMode.enforce);
      expect(rollout.isCurrent(first), isFalse);

      final second = rollout.propose(
        estimate: _estimate(ContactTimingBand.consider),
        selectedOriginalIndex: 0,
        candidateCount: 1,
        posteriorSamples: 0,
      )!;
      flags.setRuntimeMaximum(
        MaasoFeatureFlag.proactiveDrive,
        FeatureRolloutMode.off,
      );
      expect(rollout.effectiveMode(), FeatureRolloutMode.off);
      flags.setRuntimeMaximum(
        MaasoFeatureFlag.proactiveDrive,
        FeatureRolloutMode.enforce,
      );
      expect(rollout.effectiveMode(), FeatureRolloutMode.enforce);
      expect(rollout.isCurrent(second), isFalse);
    },
  );
}

Future<MaasoFeatureFlagService> _enforceFlags(DateTime now) async {
  final flags = await MaasoFeatureFlagService(
    store: _MemoryStore(),
    compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
      MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.enforce,
    },
    clock: () => now,
  ).init();
  await flags.assign(
    flag: MaasoFeatureFlag.proactiveDrive,
    mode: FeatureRolloutMode.enforce,
    revision: 1,
    expiresAt: now.add(const Duration(hours: 1)),
  );
  return flags;
}

String _digestInRange(int minimum, int maximum) {
  for (var index = 0; index < 100000; index++) {
    final candidate = 'cohort-fixture-$index';
    final bucket = ProactiveDriveRolloutService.cohortBucketFor(candidate)!;
    if (bucket >= minimum && bucket < maximum) return candidate;
  }
  throw StateError('no deterministic cohort fixture found');
}

ContactTimingEstimate _estimate(
  ContactTimingBand band, {
  bool shadowOccurrence = false,
}) => ContactTimingEstimate(
  hazardProbability: UnitSignal.one,
  availabilityProbability: UnitSignal.one,
  expectedBenefit: UnitSignal.one,
  informationGain: UnitSignal.zero,
  driveMotivation: UnitSignal.one,
  shadowScore: UnitSignal.one,
  band: band,
  posterior: ContactAvailabilityBelief.bounded(
    availableMass: 12,
    unavailableMass: 2,
  ),
  shadowOccurrence: shadowOccurrence,
);

final class _MemoryStore implements MaasoFeatureFlagAssignmentStore {
  final List<Map<String, Object?>> _rows = <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      _rows.map(Map<String, Object?>.from).toList(growable: false);

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    _rows.removeWhere((row) => row['flag'] == assignment.flag.key);
    _rows.add(assignment.toJson());
  }
}
