/// A finite value clamped to the closed interval 0..1.
///
/// Drive and timing code uses this wrapper so malformed or non-finite shadow
/// inputs fail closed before they reach a score or metric bucket.
final class UnitSignal {
  const UnitSignal._(this.value);

  factory UnitSignal.clamped(num raw, {num fallback = 0}) {
    final candidate = raw.toDouble();
    final fallbackValue = fallback.toDouble();
    final finite = candidate.isFinite
        ? candidate
        : fallbackValue.isFinite
        ? fallbackValue
        : 0.0;
    return UnitSignal._(finite.clamp(0.0, 1.0).toDouble());
  }

  static const zero = UnitSignal._(0);
  static const neutral = UnitSignal._(0.5);
  static const one = UnitSignal._(1);

  final double value;

  UnitSignal get complement => UnitSignal._(1 - value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is UnitSignal && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Trusted, bounded projections from the existing [AgentPresenceState].
///
/// This type deliberately contains no account, topic, evidence, text, locale,
/// timestamp, clock, or persistence handle. Presence remains the only state
/// machine; the drive engine is a pure projection over this one-turn snapshot.
final class CompanionDriveSignals {
  const CompanionDriveSignals({
    required this.interactionSilence,
    required this.energy,
    required this.engagement,
    required this.positiveAffect,
    required this.negativeAffect,
    required this.activation,
    required this.selfFocus,
    required this.defensiveRestraint,
    required this.resting,
    required this.attendingUser,
  });

  final UnitSignal interactionSilence;
  final UnitSignal energy;
  final UnitSignal engagement;
  final UnitSignal positiveAffect;
  final UnitSignal negativeAffect;
  final UnitSignal activation;
  final UnitSignal selfFocus;
  final UnitSignal defensiveRestraint;
  final UnitSignal resting;
  final UnitSignal attendingUser;
}

/// The five Jiwen-inspired axes used by proactive shadow and rollout scoring.
final class CompanionDriveSnapshot {
  const CompanionDriveSnapshot({
    required this.connectionNeed,
    required this.valence,
    required this.arousal,
    required this.immersion,
    required this.pride,
  });

  final UnitSignal connectionNeed;
  final UnitSignal valence;
  final UnitSignal arousal;
  final UnitSignal immersion;
  final UnitSignal pride;
}

/// Fixed candidate classes. No raw topic key or evidence identifier crosses
/// into the shadow scorer.
enum TypedProactiveCandidateKind {
  quietPresence,
  timeOfDay,
  recentAffect,
  relationshipMilestone,
  relationshipStage,
  anniversary,
  environmentObservation,
}

/// Bounded candidate features consumed by [ContactTimingEngine].
final class ProactiveCandidateSignals {
  const ProactiveCandidateSignals({
    required this.salience,
    required this.userBenefit,
    required this.resolutionPotential,
    required this.sourceBacked,
    required this.evidenceBacked,
  });

  final UnitSignal salience;
  final UnitSignal userBenefit;
  final UnitSignal resolutionPotential;
  final bool sourceBacked;
  final bool evidenceBacked;
}

/// A privacy-safe wrapper around one existing proactive candidate.
///
/// [originalIndex] exists only to preserve and verify the legacy ordering. It
/// is never used as a metric label and the wrapper intentionally does not keep
/// a reference to the legacy candidate.
final class TypedProactiveCandidate {
  const TypedProactiveCandidate({
    required this.originalIndex,
    required this.kind,
    required this.signals,
  }) : assert(originalIndex >= 0);

  final int originalIndex;
  final TypedProactiveCandidateKind kind;
  final ProactiveCandidateSignals signals;
}

/// One immutable input captured from Presence for scoring or shadow replay.
final class ProactiveDriveInput {
  ProactiveDriveInput({
    required this.signals,
    required Iterable<TypedProactiveCandidate> candidates,
    required Duration elapsedSinceUserActivity,
  }) : candidates = List<TypedProactiveCandidate>.unmodifiable(candidates),
       elapsedSinceUserActivity = _boundedElapsed(elapsedSinceUserActivity);

  static const Duration maximumElapsed = Duration(days: 7);

  final CompanionDriveSignals signals;
  final List<TypedProactiveCandidate> candidates;
  final Duration elapsedSinceUserActivity;

  static Duration _boundedElapsed(Duration value) {
    if (value.isNegative) return Duration.zero;
    if (value > maximumElapsed) return maximumElapsed;
    return value;
  }
}

/// Stateless drive projection. It owns no tick, clock, RNG, persistence, or
/// global service and therefore cannot become a second Presence state machine.
final class CompanionDriveEngine {
  const CompanionDriveEngine();

  CompanionDriveSnapshot evaluate(CompanionDriveSignals input) {
    final silence = input.interactionSilence.value;
    final energy = input.energy.value;
    final engagement = input.engagement.value;
    final positive = input.positiveAffect.value;
    final negative = input.negativeAffect.value;
    final activation = input.activation.value;
    final selfFocus = input.selfFocus.value;
    final restraint = input.defensiveRestraint.value;

    final connectionNeed = UnitSignal.clamped(
      0.62 * silence + 0.20 * negative + 0.18 * (1 - engagement),
    );
    final valence = UnitSignal.clamped(
      0.50 + 0.32 * (positive - negative) + 0.36 * (energy - 0.50),
      fallback: 0.5,
    );
    final immersion = UnitSignal.clamped(
      0.75 * selfFocus + 0.25 * (1 - engagement),
    );
    final pride = UnitSignal.clamped(
      0.50 +
          0.25 * restraint +
          0.20 * immersion.value -
          0.40 * connectionNeed.value,
      fallback: 0.5,
    );
    final arousal = UnitSignal.clamped(
      0.70 * engagement +
          0.20 * activation +
          0.10 * connectionNeed.value * restraint,
    );

    return CompanionDriveSnapshot(
      connectionNeed: connectionNeed,
      valence: valence,
      arousal: arousal,
      immersion: immersion,
      pride: pride,
    );
  }
}
