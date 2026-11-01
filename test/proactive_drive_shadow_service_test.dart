import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/companion_drive_engine.dart';
import 'package:maaso/src/core/services/contact_timing_engine.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/proactive_drive_shadow_service.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 8, 28, 8);

  setUp(resetAppProviderContainerForTest);
  tearDown(resetAppProviderContainerForTest);

  test(
    'shadow metrics use fixed-cardinality buckets and contain no raw data',
    () async {
      final flags = await MaasoFeatureFlagService(
        store: _MemoryStore(),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
        },
        clock: () => now,
      ).init();
      await flags.assign(
        flag: MaasoFeatureFlag.proactiveDrive,
        mode: FeatureRolloutMode.shadow,
        revision: 1,
        expiresAt: now.add(const Duration(hours: 1)),
      );
      final shadow = ProactiveDriveShadowService(featureFlags: flags);

      final evaluation = shadow.evaluate(_driveInput(), replaySeed: 424242);
      expect(evaluation, isNotNull);
      shadow.recordComparison(
        evaluation: evaluation!,
        legacyStatus: ProactivePreparationStatus.ready,
      );

      shadow.recordPreparation(
        status: ProactivePreparationStatus.ready,
        candidateCount: 1,
        elapsed: const Duration(milliseconds: 20),
      );
      shadow.recordPreparation(
        status: ProactivePreparationStatus.silenced,
        candidateCount: 4,
        elapsed: const Duration(milliseconds: 250),
      );
      shadow.recordError();

      final snapshot = shadow.state.value;
      expect(snapshot.samples, 2);
      expect(snapshot.evaluations, 1);
      expect(snapshot.errors, 1);
      expect(snapshot.scoringErrors, 0);
      expect(snapshot.outcomes[ProactivePreparationStatus.ready], 1);
      expect(snapshot.outcomes[ProactivePreparationStatus.silenced], 1);
      expect(snapshot.candidateBuckets[ProactiveShadowCandidateBucket.one], 1);
      expect(
        snapshot.candidateBuckets[ProactiveShadowCandidateBucket.fourOrMore],
        1,
      );
      expect(
        snapshot.latencyBuckets[ProactiveShadowLatencyBucket.under50ms],
        1,
      );
      expect(
        snapshot.latencyBuckets[ProactiveShadowLatencyBucket.over200ms],
        1,
      );
      expect(_sum(snapshot.driveBuckets), 1);
      expect(_sum(snapshot.timingBands), 1);
      expect(_sum(snapshot.occurrences), 1);
      expect(_sum(snapshot.comparisons), 1);
      expect(_sum(snapshot.scoringLatencyBuckets), 1);
      expect(
        snapshot.selectedKinds[TypedProactiveCandidateKind.recentAffect],
        1,
      );

      final json = snapshot.toJson();
      expect(json.keys, <String>{
        'samples',
        'evaluations',
        'errors',
        'scoringErrors',
        'outcomes',
        'candidateBuckets',
        'latencyBuckets',
        'driveBuckets',
        'timingBands',
        'occurrences',
        'comparisons',
        'gateOutcomes',
        'scoringLatencyBuckets',
        'selectedKinds',
      });
      final encoded = json.toString().toLowerCase();
      for (final forbidden in <String>[
        'account',
        'topic',
        'sourceevent',
        'text',
        'locale',
        'timestamp',
        'shadowscore',
        'exactscore',
        'raw-user-secret-sentinel',
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }
    },
  );

  test('off and runtime kill modes never collect observations', () async {
    final flags = await MaasoFeatureFlagService(
      store: _MemoryStore(),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
      clock: () => now,
    ).init();
    final shadow = ProactiveDriveShadowService(featureFlags: flags);

    shadow.recordPreparation(
      status: ProactivePreparationStatus.ready,
      candidateCount: 1,
      elapsed: Duration.zero,
    );
    expect(shadow.evaluate(_driveInput(), replaySeed: 1), isNull);
    expect(shadow.state.value.samples, 0);
    expect(shadow.state.value.evaluations, 0);

    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    flags.disableAll();
    shadow.recordPreparation(
      status: ProactivePreparationStatus.ready,
      candidateCount: 1,
      elapsed: Duration.zero,
    );
    expect(shadow.evaluate(_driveInput(), replaySeed: 1), isNull);
    expect(shadow.state.value.samples, 0);
    expect(shadow.state.value.evaluations, 0);
  });

  test(
    'six-candidate shadow evaluation stays below a 10ms P95 budget',
    () async {
      final flags = await MaasoFeatureFlagService(
        store: _MemoryStore(),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
        },
        clock: () => now,
      ).init();
      await flags.assign(
        flag: MaasoFeatureFlag.proactiveDrive,
        mode: FeatureRolloutMode.shadow,
        revision: 1,
        expiresAt: now.add(const Duration(hours: 1)),
      );
      final shadow = ProactiveDriveShadowService(featureFlags: flags);
      final input = _driveInput(candidateCount: 6);
      for (var index = 0; index < 100; index++) {
        expect(shadow.evaluate(input, replaySeed: index), isNotNull);
      }

      final elapsedMicros = <int>[];
      for (var sample = 0; sample < 500; sample++) {
        final timer = Stopwatch()..start();
        shadow.evaluate(input, replaySeed: sample);
        timer.stop();
        elapsedMicros.add(timer.elapsedMicroseconds);
      }
      elapsedMicros.sort();
      final p95 = elapsedMicros[(elapsedMicros.length * 0.95).ceil() - 1];

      expect(p95, lessThan(10000));
    },
  );

  test('observation failures are contained and collect nothing', () async {
    final flags = await MaasoFeatureFlagService(
      store: _MemoryStore(),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
      clock: () => now,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final shadow = ProactiveDriveShadowService(
      featureFlags: flags,
      observationHook: () => throw StateError('injected_observation_failure'),
    );

    expect(shadow.isCollecting, isFalse);
    expect(
      () => shadow.recordPreparation(
        status: ProactivePreparationStatus.ready,
        candidateCount: 1,
        elapsed: Duration.zero,
      ),
      returnsNormally,
    );
    expect(shadow.recordError, returnsNormally);
    expect(shadow.evaluate(_driveInput(), replaySeed: 1), isNull);
    expect(shadow.state.value.samples, 0);
    expect(shadow.state.value.errors, 0);
    expect(shadow.state.value.scoringErrors, 0);
  });

  test('learned availability prior changes only the shadow estimate', () async {
    final flags = await MaasoFeatureFlagService(
      store: _MemoryStore(),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
      clock: () => now,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final shadow = ProactiveDriveShadowService(featureFlags: flags);
    final conservative = shadow.evaluate(_driveInput(), replaySeed: 77)!;
    final learned = shadow.evaluate(
      _driveInput(),
      replaySeed: 77,
      prior: ContactAvailabilityBelief.bounded(
        availableMass: 12,
        unavailableMass: 2,
      ),
    )!;

    expect(
      learned.timing.availabilityProbability.value,
      greaterThan(conservative.timing.availabilityProbability.value),
    );
    expect(
      learned.timing.shadowScore.value,
      greaterThan(conservative.timing.shadowScore.value),
    );
    expect(shadow.state.value.evaluations, 0);
    expect(shadow.state.value.samples, 0);
  });

  test(
    'enforce diagnostics retain exact selected index without a fake baseline',
    () async {
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
      final shadow = ProactiveDriveShadowService(featureFlags: flags);
      final input = ProactiveDriveInput(
        signals: _driveInput().signals,
        candidates: <TypedProactiveCandidate>[
          TypedProactiveCandidate(
            originalIndex: 0,
            kind: TypedProactiveCandidateKind.recentAffect,
            signals: ProactiveCandidateSignals(
              salience: UnitSignal.clamped(0.2),
              userBenefit: UnitSignal.clamped(0.2),
              resolutionPotential: UnitSignal.clamped(0.2),
              sourceBacked: true,
              evidenceBacked: true,
            ),
          ),
          TypedProactiveCandidate(
            originalIndex: 1,
            kind: TypedProactiveCandidateKind.recentAffect,
            signals: ProactiveCandidateSignals(
              salience: UnitSignal.one,
              userBenefit: UnitSignal.one,
              resolutionPotential: UnitSignal.one,
              sourceBacked: true,
              evidenceBacked: true,
            ),
          ),
        ],
        elapsedSinceUserActivity: const Duration(hours: 4),
      );

      final evaluation = shadow.evaluate(input, replaySeed: 7)!;
      expect(evaluation.selectedOriginalIndex, 1);
      shadow.recordEnforcementDecision(evaluation: evaluation, allowed: true);

      expect(shadow.state.value.evaluations, 1);
      expect(
        shadow.state.value.gateOutcomes[ProactiveDriveGateOutcome.contact],
        1,
      );
      expect(shadow.state.value.comparisons, isEmpty);
    },
  );

  test('unavailable enforce scoring has a fixed-cardinality outcome', () async {
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
    final shadow = ProactiveDriveShadowService(featureFlags: flags);

    shadow.recordEnforcementUnavailable();

    expect(
      shadow.state.value.gateOutcomes[ProactiveDriveGateOutcome.unavailable],
      1,
    );
    expect(shadow.state.value.evaluations, 0);
  });
}

ProactiveDriveInput _driveInput({int candidateCount = 1}) =>
    ProactiveDriveInput(
      signals: CompanionDriveSignals(
        interactionSilence: UnitSignal.one,
        energy: UnitSignal.clamped(0.8),
        engagement: UnitSignal.clamped(0.2),
        positiveAffect: UnitSignal.clamped(0.7),
        negativeAffect: UnitSignal.clamped(0.1),
        activation: UnitSignal.clamped(0.5),
        selfFocus: UnitSignal.clamped(0.8),
        defensiveRestraint: UnitSignal.clamped(0.3),
        resting: UnitSignal.zero,
        attendingUser: UnitSignal.zero,
      ),
      candidates: <TypedProactiveCandidate>[
        for (var index = 0; index < candidateCount; index++)
          TypedProactiveCandidate(
            originalIndex: index,
            kind: const <TypedProactiveCandidateKind>[
              TypedProactiveCandidateKind.recentAffect,
              TypedProactiveCandidateKind.relationshipMilestone,
              TypedProactiveCandidateKind.relationshipStage,
              TypedProactiveCandidateKind.timeOfDay,
              TypedProactiveCandidateKind.environmentObservation,
              TypedProactiveCandidateKind.quietPresence,
            ][index % 6],
            signals: ProactiveCandidateSignals(
              salience: UnitSignal.clamped(0.6 + index * 0.05),
              userBenefit: UnitSignal.clamped(0.9 - index * 0.05),
              resolutionPotential: UnitSignal.clamped(0.7),
              sourceBacked: true,
              evidenceBacked: true,
            ),
          ),
      ],
      elapsedSinceUserActivity: const Duration(hours: 2),
    );

int _sum<T>(Map<T, int> values) =>
    values.values.fold(0, (total, value) => total + value);

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
