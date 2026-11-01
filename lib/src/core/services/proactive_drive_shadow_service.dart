import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/companion_drive_engine.dart';
import 'package:maaso/src/core/services/contact_timing_engine.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';

enum ProactiveShadowCandidateBucket { zero, one, twoToThree, fourOrMore }

enum ProactiveShadowLatencyBucket {
  under10ms,
  under50ms,
  under200ms,
  over200ms,
}

enum ProactiveShadowDriveBucket { low, medium, high }

enum ProactiveShadowOccurrence { contact, hold }

enum ProactiveDriveGateOutcome { contact, hold, unavailable }

enum ProactiveShadowComparison {
  legacyReadyShadowContact,
  legacyReadyShadowHold,
  legacySilentShadowContact,
  legacySilentShadowHold,
}

final class ProactiveDriveShadowSnapshot {
  const ProactiveDriveShadowSnapshot({
    this.samples = 0,
    this.evaluations = 0,
    this.errors = 0,
    this.scoringErrors = 0,
    this.outcomes = const <ProactivePreparationStatus, int>{},
    this.candidateBuckets = const <ProactiveShadowCandidateBucket, int>{},
    this.latencyBuckets = const <ProactiveShadowLatencyBucket, int>{},
    this.driveBuckets = const <ProactiveShadowDriveBucket, int>{},
    this.timingBands = const <ContactTimingBand, int>{},
    this.occurrences = const <ProactiveShadowOccurrence, int>{},
    this.comparisons = const <ProactiveShadowComparison, int>{},
    this.gateOutcomes = const <ProactiveDriveGateOutcome, int>{},
    this.scoringLatencyBuckets = const <ProactiveShadowLatencyBucket, int>{},
    this.selectedKinds = const <TypedProactiveCandidateKind, int>{},
  });

  final int samples;
  final int evaluations;
  final int errors;
  final int scoringErrors;
  final Map<ProactivePreparationStatus, int> outcomes;
  final Map<ProactiveShadowCandidateBucket, int> candidateBuckets;
  final Map<ProactiveShadowLatencyBucket, int> latencyBuckets;
  final Map<ProactiveShadowDriveBucket, int> driveBuckets;
  final Map<ContactTimingBand, int> timingBands;
  final Map<ProactiveShadowOccurrence, int> occurrences;
  final Map<ProactiveShadowComparison, int> comparisons;
  final Map<ProactiveDriveGateOutcome, int> gateOutcomes;
  final Map<ProactiveShadowLatencyBucket, int> scoringLatencyBuckets;
  final Map<TypedProactiveCandidateKind, int> selectedKinds;

  ProactiveDriveShadowSnapshot copyWith({
    int? samples,
    int? evaluations,
    int? errors,
    int? scoringErrors,
    Map<ProactivePreparationStatus, int>? outcomes,
    Map<ProactiveShadowCandidateBucket, int>? candidateBuckets,
    Map<ProactiveShadowLatencyBucket, int>? latencyBuckets,
    Map<ProactiveShadowDriveBucket, int>? driveBuckets,
    Map<ContactTimingBand, int>? timingBands,
    Map<ProactiveShadowOccurrence, int>? occurrences,
    Map<ProactiveShadowComparison, int>? comparisons,
    Map<ProactiveDriveGateOutcome, int>? gateOutcomes,
    Map<ProactiveShadowLatencyBucket, int>? scoringLatencyBuckets,
    Map<TypedProactiveCandidateKind, int>? selectedKinds,
  }) => ProactiveDriveShadowSnapshot(
    samples: samples ?? this.samples,
    evaluations: evaluations ?? this.evaluations,
    errors: errors ?? this.errors,
    scoringErrors: scoringErrors ?? this.scoringErrors,
    outcomes: outcomes ?? this.outcomes,
    candidateBuckets: candidateBuckets ?? this.candidateBuckets,
    latencyBuckets: latencyBuckets ?? this.latencyBuckets,
    driveBuckets: driveBuckets ?? this.driveBuckets,
    timingBands: timingBands ?? this.timingBands,
    occurrences: occurrences ?? this.occurrences,
    comparisons: comparisons ?? this.comparisons,
    gateOutcomes: gateOutcomes ?? this.gateOutcomes,
    scoringLatencyBuckets: scoringLatencyBuckets ?? this.scoringLatencyBuckets,
    selectedKinds: selectedKinds ?? this.selectedKinds,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'samples': samples,
    'evaluations': evaluations,
    'errors': errors,
    'scoringErrors': scoringErrors,
    'outcomes': _namedCounts(ProactivePreparationStatus.values, outcomes),
    'candidateBuckets': _namedCounts(
      ProactiveShadowCandidateBucket.values,
      candidateBuckets,
    ),
    'latencyBuckets': _namedCounts(
      ProactiveShadowLatencyBucket.values,
      latencyBuckets,
    ),
    'driveBuckets': _namedCounts(
      ProactiveShadowDriveBucket.values,
      driveBuckets,
    ),
    'timingBands': _namedCounts(ContactTimingBand.values, timingBands),
    'occurrences': _namedCounts(ProactiveShadowOccurrence.values, occurrences),
    'comparisons': _namedCounts(ProactiveShadowComparison.values, comparisons),
    'gateOutcomes': _namedCounts(
      ProactiveDriveGateOutcome.values,
      gateOutcomes,
    ),
    'scoringLatencyBuckets': _namedCounts(
      ProactiveShadowLatencyBucket.values,
      scoringLatencyBuckets,
    ),
    'selectedKinds': _namedCounts(
      TypedProactiveCandidateKind.values,
      selectedKinds,
    ),
  };

  static Map<String, int> _namedCounts<T extends Enum>(
    Iterable<T> values,
    Map<T, int> counts,
  ) => <String, int>{
    for (final value in values) value.name: counts[value] ?? 0,
  };
}

/// Exact shadow output kept only on the Runtime stack until it is bucketed.
final class ProactiveDriveShadowEvaluation {
  const ProactiveDriveShadowEvaluation({
    required this.drives,
    required this.timing,
    required this.selectedOriginalIndex,
    required this.selectedKind,
    required this.elapsed,
  });

  final CompanionDriveSnapshot drives;
  final ContactTimingEstimate timing;
  final int selectedOriginalIndex;
  final TypedProactiveCandidateKind selectedKind;
  final Duration elapsed;
}

/// Fixed-cardinality, account-lifetime diagnostics for legacy preparation and
/// pure drive/timing proposals. No raw text, identifiers, account, locale,
/// timestamp, exact score, or input snapshot is retained here.
final class ProactiveDriveShadowService extends AppService {
  ProactiveDriveShadowService({
    required MaasoFeatureFlagService featureFlags,
    CompanionDriveEngine driveEngine = const CompanionDriveEngine(),
    ContactTimingEngine timingEngine = const ContactTimingEngine(),
    void Function()? observationHook,
  }) : _featureFlags = featureFlags,
       _driveEngine = driveEngine,
       _timingEngine = timingEngine,
       _observationHook = observationHook;

  static const int _maximumCounter = 0x7fffffff;

  final MaasoFeatureFlagService _featureFlags;
  final CompanionDriveEngine _driveEngine;
  final ContactTimingEngine _timingEngine;
  final void Function()? _observationHook;
  final state = const ProactiveDriveShadowSnapshot().obs;

  bool get isCollecting {
    try {
      _observationHook?.call();
      return !isClosed &&
          _featureFlags.isObservationEnabled(MaasoFeatureFlag.proactiveDrive);
    } catch (_) {
      return false;
    }
  }

  ProactiveDriveShadowEvaluation? evaluate(
    ProactiveDriveInput input, {
    required int replaySeed,
    ContactAvailabilityBelief prior = ContactAvailabilityBelief.conservative,
  }) {
    try {
      if (!isCollecting || isClosed || input.candidates.isEmpty) return null;
      final timer = Stopwatch()..start();
      final drives = _driveEngine.evaluate(input.signals);
      ContactTimingEstimate? selected;
      int? selectedOriginalIndex;
      TypedProactiveCandidateKind? selectedKind;
      for (final candidate in input.candidates) {
        final estimate = _timingEngine.evaluate(
          ContactTimingInput(
            elapsedSinceUserActivity: input.elapsedSinceUserActivity,
            presence: input.signals,
            drives: drives,
            candidate: candidate,
            replaySeed: replaySeed + candidate.originalIndex * 7919,
            prior: prior,
          ),
        );
        if (selected == null ||
            estimate.shadowScore.value > selected.shadowScore.value) {
          selected = estimate;
          selectedOriginalIndex = candidate.originalIndex;
          selectedKind = candidate.kind;
        }
      }
      timer.stop();
      if (selected == null ||
          selectedOriginalIndex == null ||
          selectedKind == null) {
        return null;
      }
      return ProactiveDriveShadowEvaluation(
        drives: drives,
        timing: selected,
        selectedOriginalIndex: selectedOriginalIndex,
        selectedKind: selectedKind,
        elapsed: timer.elapsed,
      );
    } catch (_) {
      recordScoringError();
      return null;
    }
  }

  void recordPreparation({
    required ProactivePreparationStatus status,
    required int candidateCount,
    required Duration elapsed,
  }) {
    try {
      _observationHook?.call();
      if (!isCollecting || isClosed) return;
      final current = state.value;
      state.value = current.copyWith(
        samples: _increment(current.samples),
        outcomes: _incremented(current.outcomes, status),
        candidateBuckets: _incremented(
          current.candidateBuckets,
          _candidateBucket(candidateCount),
        ),
        latencyBuckets: _incremented(
          current.latencyBuckets,
          _latencyBucket(elapsed),
        ),
      );
    } catch (_) {
      // Shadow-only diagnostics must never affect the production turn.
    }
  }

  void recordComparison({
    required ProactiveDriveShadowEvaluation evaluation,
    required ProactivePreparationStatus legacyStatus,
  }) {
    try {
      _observationHook?.call();
      if (!isCollecting || isClosed) return;
      final current = state.value;
      final shadowContact = evaluation.timing.shadowOccurrence;
      final legacyReady = legacyStatus == ProactivePreparationStatus.ready;
      final occurrence = shadowContact
          ? ProactiveShadowOccurrence.contact
          : ProactiveShadowOccurrence.hold;
      final comparison = _comparisonFor(legacyReady, shadowContact);
      state.value = current.copyWith(
        evaluations: _increment(current.evaluations),
        driveBuckets: _incremented(
          current.driveBuckets,
          _driveBucket(evaluation.timing.driveMotivation.value),
        ),
        timingBands: _incremented(current.timingBands, evaluation.timing.band),
        occurrences: _incremented(current.occurrences, occurrence),
        comparisons: _incremented(current.comparisons, comparison),
        scoringLatencyBuckets: _incremented(
          current.scoringLatencyBuckets,
          _latencyBucket(evaluation.elapsed),
        ),
        selectedKinds: _incremented(
          current.selectedKinds,
          evaluation.selectedKind,
        ),
      );
    } catch (_) {
      // Shadow-only diagnostics must never affect the production turn.
    }
  }

  void recordEnforcementDecision({
    required ProactiveDriveShadowEvaluation evaluation,
    required bool allowed,
  }) {
    try {
      _observationHook?.call();
      if (!isCollecting || isClosed) return;
      final current = state.value;
      final shadowContact = evaluation.timing.shadowOccurrence;
      state.value = current.copyWith(
        evaluations: _increment(current.evaluations),
        driveBuckets: _incremented(
          current.driveBuckets,
          _driveBucket(evaluation.timing.driveMotivation.value),
        ),
        timingBands: _incremented(current.timingBands, evaluation.timing.band),
        occurrences: _incremented(
          current.occurrences,
          shadowContact
              ? ProactiveShadowOccurrence.contact
              : ProactiveShadowOccurrence.hold,
        ),
        gateOutcomes: _incremented(
          current.gateOutcomes,
          allowed
              ? ProactiveDriveGateOutcome.contact
              : ProactiveDriveGateOutcome.hold,
        ),
        scoringLatencyBuckets: _incremented(
          current.scoringLatencyBuckets,
          _latencyBucket(evaluation.elapsed),
        ),
        selectedKinds: _incremented(
          current.selectedKinds,
          evaluation.selectedKind,
        ),
      );
    } catch (_) {
      // Rollout diagnostics must never alter the production decision.
    }
  }

  void recordEnforcementUnavailable() {
    try {
      _observationHook?.call();
      if (!isCollecting || isClosed) return;
      final current = state.value;
      state.value = current.copyWith(
        gateOutcomes: _incremented(
          current.gateOutcomes,
          ProactiveDriveGateOutcome.unavailable,
        ),
      );
    } catch (_) {
      // Rollout diagnostics must never alter the production decision.
    }
  }

  void recordError() {
    try {
      _observationHook?.call();
      if (!isCollecting || isClosed) return;
      final current = state.value;
      state.value = current.copyWith(errors: _increment(current.errors));
    } catch (_) {
      // Shadow-only diagnostics must never mask a production failure.
    }
  }

  void recordScoringError() {
    try {
      _observationHook?.call();
      if (!isCollecting || isClosed) return;
      final current = state.value;
      state.value = current.copyWith(
        scoringErrors: _increment(current.scoringErrors),
      );
    } catch (_) {
      // Shadow scoring must never mask or alter the production path.
    }
  }

  @override
  void onClose() {
    state.value = const ProactiveDriveShadowSnapshot();
    super.onClose();
  }

  static Map<T, int> _incremented<T>(Map<T, int> source, T key) =>
      Map<T, int>.unmodifiable(<T, int>{
        ...source,
        key: _increment(source[key] ?? 0),
      });

  static int _increment(int value) =>
      value >= _maximumCounter ? _maximumCounter : value + 1;

  static ProactiveShadowComparison _comparisonFor(
    bool legacyReady,
    bool shadowContact,
  ) => switch ((legacyReady, shadowContact)) {
    (true, true) => ProactiveShadowComparison.legacyReadyShadowContact,
    (true, false) => ProactiveShadowComparison.legacyReadyShadowHold,
    (false, true) => ProactiveShadowComparison.legacySilentShadowContact,
    (false, false) => ProactiveShadowComparison.legacySilentShadowHold,
  };

  static ProactiveShadowCandidateBucket _candidateBucket(int count) {
    if (count <= 0) return ProactiveShadowCandidateBucket.zero;
    if (count == 1) return ProactiveShadowCandidateBucket.one;
    if (count <= 3) return ProactiveShadowCandidateBucket.twoToThree;
    return ProactiveShadowCandidateBucket.fourOrMore;
  }

  static ProactiveShadowLatencyBucket _latencyBucket(Duration elapsed) {
    final milliseconds = elapsed.inMilliseconds;
    if (milliseconds < 10) return ProactiveShadowLatencyBucket.under10ms;
    if (milliseconds < 50) return ProactiveShadowLatencyBucket.under50ms;
    if (milliseconds < 200) return ProactiveShadowLatencyBucket.under200ms;
    return ProactiveShadowLatencyBucket.over200ms;
  }

  static ProactiveShadowDriveBucket _driveBucket(double value) {
    if (value < 1 / 3) return ProactiveShadowDriveBucket.low;
    if (value < 2 / 3) return ProactiveShadowDriveBucket.medium;
    return ProactiveShadowDriveBucket.high;
  }
}
