import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/companion_drive_engine.dart';
import 'package:maaso/src/core/services/contact_timing_engine.dart';

void main() {
  const engine = ContactTimingEngine();

  test('Poisson hazard matches the configured deterministic rate', () {
    final estimate = engine.evaluate(
      _input(
        elapsed: const Duration(minutes: 30),
        drives: _drives(connectionNeed: 0.5),
        salience: 0.5,
      ),
    );

    final expected = 1 - math.exp(-0.15 * 0.5);
    expect(estimate.hazardProbability.value, closeTo(expected, 1e-12));
  });

  test('hazard rises with elapsed time, connection need, and salience', () {
    final short = engine.evaluate(
      _input(
        elapsed: const Duration(minutes: 10),
        drives: _drives(connectionNeed: 0.2),
        salience: 0.2,
      ),
    );
    final longer = engine.evaluate(
      _input(
        elapsed: const Duration(hours: 1),
        drives: _drives(connectionNeed: 0.2),
        salience: 0.2,
      ),
    );
    final connected = engine.evaluate(
      _input(
        elapsed: const Duration(hours: 1),
        drives: _drives(connectionNeed: 0.8),
        salience: 0.2,
      ),
    );
    final salient = engine.evaluate(
      _input(
        elapsed: const Duration(hours: 1),
        drives: _drives(connectionNeed: 0.8),
        salience: 0.9,
      ),
    );

    expect(
      short.hazardProbability.value,
      lessThan(longer.hazardProbability.value),
    );
    expect(
      longer.hazardProbability.value,
      lessThan(connected.hazardProbability.value),
    );
    expect(
      connected.hazardProbability.value,
      lessThan(salient.hazardProbability.value),
    );
  });

  test('cold prior can observe but cannot reach the consider band', () {
    final estimate = engine.evaluate(
      _input(
        elapsed: const Duration(days: 30),
        presence: _presence(
          silence: 1,
          engagement: 0,
          resting: 0,
          attendingUser: 0,
        ),
        drives: _drives(connectionNeed: 1, pride: 0, arousal: 1, immersion: 0),
        salience: 1,
        benefit: 1,
        resolution: 1,
      ),
    );

    expect(estimate.band, isNot(ContactTimingBand.consider));
    expect(
      estimate.shadowScore.value,
      lessThan(const ContactTimingConfig().considerThreshold),
    );
  });

  test(
    'availability evidence raises the posterior and busy evidence lowers it',
    () {
      final available = engine.evaluate(
        _input(
          presence: _presence(
            silence: 1,
            engagement: 0,
            resting: 0,
            attendingUser: 0,
          ),
        ),
      );
      final busy = engine.evaluate(
        _input(
          presence: _presence(
            silence: 0,
            engagement: 1,
            resting: 1,
            attendingUser: 1,
          ),
        ),
      );

      expect(
        available.availabilityProbability.value,
        greaterThan(ContactAvailabilityBelief.conservative.probability.value),
      );
      expect(
        busy.availabilityProbability.value,
        lessThan(ContactAvailabilityBelief.conservative.probability.value),
      );
    },
  );

  test('feedback updates are bounded and weight dismissal most strongly', () {
    const prior = ContactAvailabilityBelief.conservative;
    final responded = prior.updated(ContactAvailabilityFeedback.responded);
    final ignored = prior.updated(ContactAvailabilityFeedback.ignored);
    final dismissed = prior.updated(ContactAvailabilityFeedback.dismissed);

    expect(responded.probability.value, greaterThan(prior.probability.value));
    expect(ignored.probability.value, lessThan(prior.probability.value));
    expect(dismissed.probability.value, lessThan(ignored.probability.value));
    final saturated = ContactAvailabilityBelief.bounded(
      availableMass: 100000,
      unavailableMass: double.nan,
    );
    expect(saturated.availableMass, ContactAvailabilityBelief.maximumMass);
    expect(saturated.unavailableMass, 4);
    expect(saturated.probability.value, inInclusiveRange(0.0, 1.0));
  });

  test('replay seed and bounded elapsed time make estimates replayable', () {
    final input = _input(
      elapsed: const Duration(hours: 3),
      replaySeed: 9125539,
    );
    final first = engine.evaluate(input);
    final second = engine.evaluate(input);
    final lowReplaySample = engine.evaluate(
      _input(elapsed: const Duration(hours: 3), replaySeed: 7),
    );
    final highReplaySample = engine.evaluate(
      _input(elapsed: const Duration(hours: 3), replaySeed: 123456789),
    );
    final negative = engine.evaluate(
      _input(elapsed: const Duration(seconds: -1)),
    );
    final sevenDays = engine.evaluate(_input(elapsed: const Duration(days: 7)));
    final beyondMaximum = engine.evaluate(
      _input(elapsed: const Duration(days: 30)),
    );

    expect(_estimateValues(second), _estimateValues(first));
    expect(second.band, first.band);
    expect(second.shadowOccurrence, first.shadowOccurrence);
    expect(lowReplaySample.shadowOccurrence, isTrue);
    expect(highReplaySample.shadowOccurrence, isFalse);
    expect(negative.hazardProbability, UnitSignal.zero);
    expect(beyondMaximum.hazardProbability, sevenDays.hazardProbability);
  });

  test('binary entropy is bounded with its peak at an even belief', () {
    expect(ContactTimingEngine.binaryEntropy(0), 0);
    expect(ContactTimingEngine.binaryEntropy(1), 0);
    expect(ContactTimingEngine.binaryEntropy(-4), 0);
    expect(ContactTimingEngine.binaryEntropy(4), 0);
    expect(ContactTimingEngine.binaryEntropy(0.5), closeTo(1, 1e-12));
    expect(
      ContactTimingEngine.binaryEntropy(0.2),
      lessThan(ContactTimingEngine.binaryEntropy(0.5)),
    );
  });

  test('warmed shadow scoring stays below a 10ms P95 budget', () {
    final input = _input(elapsed: const Duration(hours: 2), replaySeed: 42);
    for (var index = 0; index < 200; index++) {
      engine.evaluate(input);
    }

    final elapsedMicros = <int>[];
    for (var sample = 0; sample < 1000; sample++) {
      final timer = Stopwatch()..start();
      engine.evaluate(input);
      timer.stop();
      elapsedMicros.add(timer.elapsedMicroseconds);
    }
    elapsedMicros.sort();
    final p95 = elapsedMicros[(elapsedMicros.length * 0.95).ceil() - 1];

    expect(p95, lessThan(10000));
  });
}

ContactTimingInput _input({
  Duration elapsed = const Duration(hours: 1),
  CompanionDriveSignals? presence,
  CompanionDriveSnapshot? drives,
  num salience = 0.5,
  num benefit = 0.7,
  num resolution = 0.4,
  ContactAvailabilityBelief prior = ContactAvailabilityBelief.conservative,
  int replaySeed = 7,
}) => ContactTimingInput(
  elapsedSinceUserActivity: elapsed,
  presence: presence ?? _presence(),
  drives: drives ?? _drives(),
  candidate: TypedProactiveCandidate(
    originalIndex: 0,
    kind: TypedProactiveCandidateKind.quietPresence,
    signals: ProactiveCandidateSignals(
      salience: UnitSignal.clamped(salience),
      userBenefit: UnitSignal.clamped(benefit),
      resolutionPotential: UnitSignal.clamped(resolution),
      sourceBacked: false,
      evidenceBacked: false,
    ),
  ),
  prior: prior,
  replaySeed: replaySeed,
);

CompanionDriveSignals _presence({
  num silence = 0.5,
  num engagement = 0.5,
  num resting = 0,
  num attendingUser = 0,
}) => CompanionDriveSignals(
  interactionSilence: UnitSignal.clamped(silence),
  energy: UnitSignal.neutral,
  engagement: UnitSignal.clamped(engagement),
  positiveAffect: UnitSignal.neutral,
  negativeAffect: UnitSignal.zero,
  activation: UnitSignal.neutral,
  selfFocus: UnitSignal.neutral,
  defensiveRestraint: UnitSignal.neutral,
  resting: UnitSignal.clamped(resting),
  attendingUser: UnitSignal.clamped(attendingUser),
);

CompanionDriveSnapshot _drives({
  num connectionNeed = 0.5,
  num valence = 0.5,
  num arousal = 0.5,
  num immersion = 0.5,
  num pride = 0.5,
}) => CompanionDriveSnapshot(
  connectionNeed: UnitSignal.clamped(connectionNeed),
  valence: UnitSignal.clamped(valence),
  arousal: UnitSignal.clamped(arousal),
  immersion: UnitSignal.clamped(immersion),
  pride: UnitSignal.clamped(pride),
);

List<Object> _estimateValues(ContactTimingEstimate estimate) => <Object>[
  estimate.hazardProbability.value,
  estimate.availabilityProbability.value,
  estimate.expectedBenefit.value,
  estimate.informationGain.value,
  estimate.driveMotivation.value,
  estimate.shadowScore.value,
  estimate.posterior.availableMass,
  estimate.posterior.unavailableMass,
];
