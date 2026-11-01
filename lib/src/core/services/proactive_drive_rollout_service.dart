import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/contact_timing_engine.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';

typedef ProactiveDriveContactPolicy =
    bool Function(ContactTimingEstimate estimate);

enum ProactiveDriveAdmissionDecision { contact, hold }

/// One synchronous, account-local proposal bound to the rollout epoch that
/// produced it. The runtime must revalidate it immediately before applying a
/// hold or candidate filter.
final class ProactiveDriveAdmission {
  const ProactiveDriveAdmission._({
    required this.decision,
    required this.selectedOriginalIndex,
    required int assignmentRevision,
    required int rolloutGeneration,
  }) : _assignmentRevision = assignmentRevision,
       _rolloutGeneration = rolloutGeneration;

  final ProactiveDriveAdmissionDecision decision;
  final int? selectedOriginalIndex;
  final int _assignmentRevision;
  final int _rolloutGeneration;
}

/// Account-stable rollout gate for proactive drive/timing enforcement.
///
/// The feature assignment remains the authority for off/shadow/enforce. An
/// enforce assignment is additionally capped by a deterministic account
/// cohort so the first production step can stay at 5%. Enforcement begins only
/// after bounded feedback has warmed the posterior; new/degraded accounts stay
/// on the complete legacy path instead of entering a cold-start silent loop.
/// The service retains only the bucket, never the account scope digest used to
/// derive it.
final class ProactiveDriveRolloutService extends AppService {
  ProactiveDriveRolloutService({
    required MaasoFeatureFlagService featureFlags,
    required String accountScopeDigest,
    int? compileEnforceMaximumBasisPoints,
    int initialEnforceBasisPoints = initialEnforceBasisPointsDefault,
    int minimumPosteriorSamples = minimumPosteriorSamplesDefault,
    ProactiveDriveContactPolicy? contactPolicy,
  }) : _featureFlags = featureFlags,
       _compileEnforceMaximumBasisPoints = _validatedBasisPoints(
         compileEnforceMaximumBasisPoints ??
             parseCompileEnforceMaximumBasisPoints(),
       ),
       _initialEnforceBasisPoints = _validatedBasisPoints(
         initialEnforceBasisPoints,
       ),
       _minimumPosteriorSamples = _validatedSampleCount(
         minimumPosteriorSamples,
       ),
       _cohortBucket = cohortBucketFor(accountScopeDigest),
       _contactPolicy =
           contactPolicy ??
           ((estimate) => estimate.band == ContactTimingBand.consider) {
    _runtimeEnforceBasisPoints =
        _initialEnforceBasisPoints > _compileEnforceMaximumBasisPoints
        ? _compileEnforceMaximumBasisPoints
        : _initialEnforceBasisPoints;
    _featureFlagWorker = _featureFlags.state.listen((_) {
      _rolloutGeneration++;
    });
  }

  static const int totalBasisPoints = 10000;
  static const int initialEnforceBasisPointsDefault = 500;
  static const int minimumPosteriorSamplesDefault = 5;
  static const String compileEnforceMaximumBasisPointsSource =
      String.fromEnvironment(
        'MAASO_PROACTIVE_DRIVE_ENFORCE_MAX_BASIS_POINTS',
        defaultValue: '500',
      );

  final MaasoFeatureFlagService _featureFlags;
  final int _compileEnforceMaximumBasisPoints;
  final int _initialEnforceBasisPoints;
  final int _minimumPosteriorSamples;
  final int? _cohortBucket;
  final ProactiveDriveContactPolicy _contactPolicy;
  late final Worker _featureFlagWorker;
  late int _runtimeEnforceBasisPoints;
  int _rolloutGeneration = 1;

  int get compileEnforceMaximumBasisPoints => _compileEnforceMaximumBasisPoints;

  int get runtimeEnforceBasisPoints => _runtimeEnforceBasisPoints;

  int get minimumPosteriorSamples => _minimumPosteriorSamples;

  /// Returns the mode applicable to this account for the current turn.
  ///
  /// Accounts outside the enforce cohort continue in shadow so diagnostics
  /// and feedback remain available while the legacy policy owns delivery.
  FeatureRolloutMode effectiveMode({DateTime? now}) {
    if (isClosed) return FeatureRolloutMode.off;
    final assigned = _featureFlags.effectiveMode(
      MaasoFeatureFlag.proactiveDrive,
      now: now,
    );
    if (assigned != FeatureRolloutMode.enforce) return assigned;
    final bucket = _cohortBucket;
    if (bucket == null || bucket >= _runtimeEnforceBasisPoints) {
      return FeatureRolloutMode.shadow;
    }
    return FeatureRolloutMode.enforce;
  }

  ProactiveDriveAdmission? propose({
    required ContactTimingEstimate estimate,
    required int selectedOriginalIndex,
    required int candidateCount,
    required int posteriorSamples,
    DateTime? now,
  }) {
    if (effectiveMode(now: now) != FeatureRolloutMode.enforce) return null;
    if (posteriorSamples < _minimumPosteriorSamples) return null;
    final assignment =
        _featureFlags.state.value[MaasoFeatureFlag.proactiveDrive];
    if (assignment == null) return null;
    final rolloutGeneration = _rolloutGeneration;
    final validIndex =
        selectedOriginalIndex >= 0 && selectedOriginalIndex < candidateCount;
    var allowed = false;
    try {
      allowed = validIndex && _contactPolicy(estimate);
    } catch (_) {
      allowed = false;
    }
    return ProactiveDriveAdmission._(
      decision: allowed
          ? ProactiveDriveAdmissionDecision.contact
          : ProactiveDriveAdmissionDecision.hold,
      selectedOriginalIndex: allowed ? selectedOriginalIndex : null,
      assignmentRevision: assignment.revision,
      rolloutGeneration: rolloutGeneration,
    );
  }

  bool isCurrent(ProactiveDriveAdmission admission, {DateTime? now}) {
    if (isClosed ||
        admission._rolloutGeneration != _rolloutGeneration ||
        effectiveMode(now: now) != FeatureRolloutMode.enforce) {
      return false;
    }
    return _featureFlags
            .state
            .value[MaasoFeatureFlag.proactiveDrive]
            ?.revision ==
        admission._assignmentRevision;
  }

  /// Process-local rollout cap. Values can never exceed the build cap.
  void setRuntimeEnforceBasisPoints(int value) {
    if (isClosed) throw StateError('proactive_drive_rollout_retired');
    final validated = _validatedBasisPoints(value);
    final next = validated > _compileEnforceMaximumBasisPoints
        ? _compileEnforceMaximumBasisPoints
        : validated;
    if (next == _runtimeEnforceBasisPoints) return;
    _runtimeEnforceBasisPoints = next;
    _rolloutGeneration++;
  }

  void disableEnforcement() => setRuntimeEnforceBasisPoints(0);

  @override
  void onClose() {
    _featureFlagWorker.dispose();
    _runtimeEnforceBasisPoints = 0;
    _rolloutGeneration++;
    super.onClose();
  }

  static int parseCompileEnforceMaximumBasisPoints([
    String source = compileEnforceMaximumBasisPointsSource,
  ]) {
    final parsed = int.tryParse(source.trim());
    if (parsed == null || parsed < 0 || parsed > totalBasisPoints) return 0;
    return parsed;
  }

  static int? cohortBucketFor(String accountScopeDigest) {
    final digest = accountScopeDigest.trim();
    if (digest.isEmpty) return null;
    final bytes = sha256
        .convert(
          utf8.encode(
            'com.futurpals.maaso.proactive-drive-rollout.v1\u0000$digest',
          ),
        )
        .bytes;
    final prefix =
        bytes[0] * 0x1000000 + bytes[1] * 0x10000 + bytes[2] * 0x100 + bytes[3];
    return prefix % totalBasisPoints;
  }

  static int _validatedBasisPoints(int value) {
    if (value < 0 || value > totalBasisPoints) {
      throw ArgumentError.value(
        value,
        'basisPoints',
        'must be between 0 and $totalBasisPoints',
      );
    }
    return value;
  }

  static int _validatedSampleCount(int value) {
    if (value < 0 || value > 1000000) {
      throw ArgumentError.value(
        value,
        'minimumPosteriorSamples',
        'must be between 0 and 1000000',
      );
    }
    return value;
  }
}
