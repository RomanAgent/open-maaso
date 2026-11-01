import 'dart:math' as math;

import 'package:maaso/src/core/services/companion_drive_engine.dart';

enum ContactAvailabilityFeedback { responded, dismissed, ignored }

/// A bounded Beta belief for whether the user is available for contact.
final class ContactAvailabilityBelief {
  const ContactAvailabilityBelief._({
    required this.availableMass,
    required this.unavailableMass,
  });

  factory ContactAvailabilityBelief.bounded({
    required num availableMass,
    required num unavailableMass,
  }) => ContactAvailabilityBelief._(
    availableMass: _boundedMass(availableMass, fallback: 1),
    unavailableMass: _boundedMass(unavailableMass, fallback: 4),
  );

  static const conservative = ContactAvailabilityBelief._(
    availableMass: 1,
    unavailableMass: 4,
  );
  static const double maximumMass = 64;

  final double availableMass;
  final double unavailableMass;

  UnitSignal get probability =>
      UnitSignal.clamped(availableMass / (availableMass + unavailableMass));

  ContactAvailabilityBelief updated(ContactAvailabilityFeedback feedback) {
    return switch (feedback) {
      ContactAvailabilityFeedback.responded => _withEvidence(available: 1),
      ContactAvailabilityFeedback.dismissed => _withEvidence(unavailable: 2),
      ContactAvailabilityFeedback.ignored => _withEvidence(unavailable: 1.25),
    };
  }

  ContactAvailabilityBelief _withEvidence({
    double available = 0,
    double unavailable = 0,
  }) => ContactAvailabilityBelief.bounded(
    availableMass: availableMass + available,
    unavailableMass: unavailableMass + unavailable,
  );

  static double _boundedMass(num raw, {required double fallback}) {
    final value = raw.toDouble();
    if (!value.isFinite || value <= 0) return fallback;
    return value.clamp(0.001, maximumMass).toDouble();
  }
}

enum ContactTimingBand { hold, observe, consider }

final class ContactTimingConfig {
  const ContactTimingConfig({
    this.baseRatePerHour = 0.15,
    this.observeThreshold = 0.15,
    this.considerThreshold = 0.35,
  }) : assert(baseRatePerHour >= 0),
       assert(observeThreshold >= 0 && observeThreshold <= 1),
       assert(considerThreshold >= observeThreshold && considerThreshold <= 1);

  final double baseRatePerHour;
  final double observeThreshold;
  final double considerThreshold;
}

final class ContactTimingInput {
  const ContactTimingInput({
    required this.elapsedSinceUserActivity,
    required this.presence,
    required this.drives,
    required this.candidate,
    this.prior = ContactAvailabilityBelief.conservative,
    required this.replaySeed,
  });

  final Duration elapsedSinceUserActivity;
  final CompanionDriveSignals presence;
  final CompanionDriveSnapshot drives;
  final TypedProactiveCandidate candidate;
  final ContactAvailabilityBelief prior;
  final int replaySeed;
}

/// A bounded estimate. [shadowOccurrence] remains a replayable diagnostic
/// sample and is never an authorization or delivery decision. Enforcement uses
/// the deterministic [band] through a separately versioned rollout admission.
final class ContactTimingEstimate {
  const ContactTimingEstimate({
    required this.hazardProbability,
    required this.availabilityProbability,
    required this.expectedBenefit,
    required this.informationGain,
    required this.driveMotivation,
    required this.shadowScore,
    required this.band,
    required this.posterior,
    required this.shadowOccurrence,
  });

  final UnitSignal hazardProbability;
  final UnitSignal availabilityProbability;
  final UnitSignal expectedBenefit;
  final UnitSignal informationGain;
  final UnitSignal driveMotivation;
  final UnitSignal shadowScore;
  final ContactTimingBand band;
  final ContactAvailabilityBelief posterior;
  final bool shadowOccurrence;
}

/// Pure Poisson/Beta timing estimator inspired by revive-companion.
///
/// It has no clock, mutable posterior, RNG, persistence, policy, or side-effect
/// dependency. The caller supplies elapsed time and a stable replay seed.
final class ContactTimingEngine {
  const ContactTimingEngine({this.config = const ContactTimingConfig()});

  final ContactTimingConfig config;

  ContactTimingEstimate evaluate(ContactTimingInput input) {
    final presence = input.presence;
    final silence = presence.interactionSilence.value;
    final engagement = presence.engagement.value;
    final attendingUser = presence.attendingUser.value;
    final resting = presence.resting.value;

    final availableEvidence = UnitSignal.clamped(
      (0.55 * (1 - engagement) + 0.30 * silence + 0.15 * (1 - attendingUser)) *
          (1 - resting),
    );
    final busyEvidence = UnitSignal.clamped(
      math.max(
        resting,
        0.65 * engagement + 0.25 * attendingUser + 0.10 * (1 - silence),
      ),
    );
    final posterior = ContactAvailabilityBelief.bounded(
      // One turn of inferred availability cannot overpower the conservative
      // cold prior. Busy evidence remains stronger so uncertainty fails quiet.
      availableMass: input.prior.availableMass + availableEvidence.value,
      unavailableMass: input.prior.unavailableMass + 2 * busyEvidence.value,
    );
    final availability = posterior.probability;

    final elapsed = _boundedElapsed(input.elapsedSinceUserActivity);
    final hours =
        elapsed.inMicroseconds / const Duration(hours: 1).inMicroseconds;
    final salience = input.candidate.signals.salience.value;
    final lambda = math.max(
      0.0,
      config.baseRatePerHour *
          (0.50 + input.drives.connectionNeed.value) *
          (0.75 + 0.50 * salience),
    );
    final hazard = UnitSignal.clamped(1 - math.exp(-lambda * hours));

    final motivation = UnitSignal.clamped(
      0.55 * input.drives.connectionNeed.value +
          0.15 * input.drives.pride.complement.value +
          0.15 * input.drives.arousal.value +
          0.15 * input.drives.immersion.complement.value,
    );
    final rawBenefit = UnitSignal.clamped(
      0.70 * input.candidate.signals.userBenefit.value +
          0.30 * motivation.value,
    );
    final expectedBenefit = UnitSignal.clamped(
      availability.value * rawBenefit.value,
    );
    final informationGain = UnitSignal.clamped(
      availability.value *
          binaryEntropy(availability.value) *
          input.candidate.signals.resolutionPotential.value,
    );
    final score = UnitSignal.clamped(
      hazard.value *
          (0.85 * expectedBenefit.value + 0.15 * informationGain.value),
    );
    final band = score.value >= config.considerThreshold
        ? ContactTimingBand.consider
        : score.value >= config.observeThreshold
        ? ContactTimingBand.observe
        : ContactTimingBand.hold;

    return ContactTimingEstimate(
      hazardProbability: hazard,
      availabilityProbability: availability,
      expectedBenefit: expectedBenefit,
      informationGain: informationGain,
      driveMotivation: motivation,
      shadowScore: score,
      band: band,
      posterior: posterior,
      shadowOccurrence: _stableUnitSample(input.replaySeed) < score.value,
    );
  }

  static double binaryEntropy(double rawProbability) {
    final probability = rawProbability.clamp(0.0, 1.0).toDouble();
    if (probability <= 0 || probability >= 1) return 0;
    return -(probability * math.log(probability) +
            (1 - probability) * math.log(1 - probability)) /
        math.ln2;
  }

  static Duration _boundedElapsed(Duration value) {
    if (value.isNegative) return Duration.zero;
    if (value > ProactiveDriveInput.maximumElapsed) {
      return ProactiveDriveInput.maximumElapsed;
    }
    return value;
  }

  static double _stableUnitSample(int seed) {
    const modulus = 2147483647;
    var normalized = seed % (modulus - 1);
    if (normalized < 0) normalized += modulus - 1;
    final state = normalized + 1;
    // Park-Miller's largest intermediate is below 2^46, so JavaScript and
    // Dart VM preserve the same exact integer before the modulo operation.
    final mixed = (state * 16807) % modulus;
    return mixed / modulus;
  }
}
