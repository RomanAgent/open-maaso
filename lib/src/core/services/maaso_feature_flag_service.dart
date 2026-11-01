import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:sembast/sembast.dart';

const int maxMaasoFeatureFlagRevision = 0x1fffffffffffff;

/// Cross-cutting rollout gates declared by the Maaso OSS optimization plan.
enum MaasoFeatureFlag {
  actionContractV2,
  proactiveDrive,
  memoryV2,
  voiceProsody,
  naturalConversation,
  avatarProjectionV2,
  embodiedDeviceV1,
  companionActivity;

  String get key => switch (this) {
    MaasoFeatureFlag.actionContractV2 => 'action_contract_v2',
    MaasoFeatureFlag.proactiveDrive => 'proactive_drive',
    MaasoFeatureFlag.memoryV2 => 'memory_v2',
    MaasoFeatureFlag.voiceProsody => 'voice_prosody',
    MaasoFeatureFlag.naturalConversation => 'natural_conversation',
    MaasoFeatureFlag.avatarProjectionV2 => 'avatar_projection_v2',
    MaasoFeatureFlag.embodiedDeviceV1 => 'embodied_device_v1',
    MaasoFeatureFlag.companionActivity => 'companion_activity',
  };

  static MaasoFeatureFlag parse(Object? source) {
    for (final flag in values) {
      if (flag.key == source) return flag;
    }
    throw const FormatException('Maaso feature flag is invalid');
  }
}

enum FeatureRolloutMode {
  off,
  shadow,
  enforce;

  static FeatureRolloutMode parse(Object? source) => switch (source) {
    'off' => FeatureRolloutMode.off,
    'shadow' => FeatureRolloutMode.shadow,
    'enforce' => FeatureRolloutMode.enforce,
    _ => throw const FormatException('feature rollout mode is invalid'),
  };

  FeatureRolloutMode cappedBy(FeatureRolloutMode maximum) =>
      index <= maximum.index ? this : maximum;
}

enum _FeatureFlagLifecycle { created, initializing, active, degraded, retired }

final class MaasoFeatureFlagAssignment {
  const MaasoFeatureFlagAssignment({
    required this.flag,
    required this.mode,
    required this.revision,
    required this.expiresAt,
  });

  final MaasoFeatureFlag flag;
  final FeatureRolloutMode mode;
  final int revision;
  final DateTime expiresAt;

  bool isActiveAt(DateTime value) => expiresAt.isAfter(value.toUtc());

  Map<String, Object?> toJson() => <String, Object?>{
    'flag': flag.key,
    'mode': mode.name,
    'revision': revision,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };

  factory MaasoFeatureFlagAssignment.fromJson(Object? source) {
    if (source is! Map) {
      throw const FormatException('feature flag assignment is invalid');
    }
    final json = Map<String, Object?>.from(source);
    const fields = <String>{'flag', 'mode', 'revision', 'expiresAt'};
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('feature flag assignment fields are invalid');
    }
    final revision = json['revision'];
    if (revision is! int ||
        revision < 1 ||
        revision > maxMaasoFeatureFlagRevision) {
      throw const FormatException('feature flag revision is invalid');
    }
    final expiresAt = _strictUtcTimestamp(json['expiresAt']);
    return MaasoFeatureFlagAssignment(
      flag: MaasoFeatureFlag.parse(json['flag']),
      mode: FeatureRolloutMode.parse(json['mode']),
      revision: revision,
      expiresAt: expiresAt,
    );
  }
}

abstract interface class MaasoFeatureFlagAssignmentStore {
  Future<List<Map<String, Object?>>> readAll();

  Future<void> write(MaasoFeatureFlagAssignment assignment);
}

final class SembastMaasoFeatureFlagAssignmentStore
    implements MaasoFeatureFlagAssignmentStore {
  SembastMaasoFeatureFlagAssignmentStore(this.database);

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('feature_flag_assignments.v1');

  final DBService database;

  @override
  Future<List<Map<String, Object?>>> readAll() async {
    final records = await _store.find(database.raw);
    return records
        .map(
          (record) => record.value['flag'] == record.key
              ? Map<String, Object?>.from(record.value)
              : <String, Object?>{
                  'flag': record.key,
                  'invalidStoredAssignment': true,
                },
        )
        .toList(growable: false);
  }

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) =>
      _store.record(assignment.flag.key).put(database.raw, assignment.toJson());
}

/// Account-owned rollout assignment cache with build-time and runtime caps.
///
/// Memory governance and natural conversation default to enforcement only
/// after a healthy cache read proves this account has no previous assignment
/// for that capability. Explicit, invalid or expired assignments never fall
/// back to that default.
/// Other flags remain assignment-required and default to an `off` build cap.
/// Every mode remains subject to build, runtime and hard maximums.
final class MaasoFeatureFlagService extends AppService {
  MaasoFeatureFlagService({
    required MaasoFeatureFlagAssignmentStore store,
    Map<MaasoFeatureFlag, FeatureRolloutMode>? compileMaximums,
    DateTime Function()? clock,
  }) : _store = store,
       _clock = clock ?? DateTime.now,
       _compileMaximums =
           Map<MaasoFeatureFlag, FeatureRolloutMode>.unmodifiable(
             _completeMaximums(compileMaximums ?? parseCompileMaximums()),
           ) {
    _runtimeMaximums.addAll(_compileMaximums);
  }

  static const String compileMaximumsSource = String.fromEnvironment(
    'MAASO_FEATURE_ROLLOUT_MAXIMA',
  );

  final MaasoFeatureFlagAssignmentStore _store;
  final DateTime Function() _clock;
  final Map<MaasoFeatureFlag, FeatureRolloutMode> _compileMaximums;
  final Map<MaasoFeatureFlag, FeatureRolloutMode> _runtimeMaximums =
      <MaasoFeatureFlag, FeatureRolloutMode>{};
  final Set<MaasoFeatureFlag> _configuredFlags = <MaasoFeatureFlag>{};
  bool _hasUnidentifiedAssignment = false;
  final Map<MaasoFeatureFlag, int> _authorityGenerations =
      <MaasoFeatureFlag, int>{
        for (final flag in MaasoFeatureFlag.values) flag: 0,
      };
  final state = <MaasoFeatureFlag, MaasoFeatureFlagAssignment>{}.obs;
  Future<void> _mutationTail = Future<void>.value();
  _FeatureFlagLifecycle _lifecycle = _FeatureFlagLifecycle.created;

  Future<MaasoFeatureFlagService> init() async {
    if (isClosed || _lifecycle != _FeatureFlagLifecycle.created) {
      throw StateError('maaso_feature_flags_already_initialized');
    }
    _lifecycle = _FeatureFlagLifecycle.initializing;
    final restored = <MaasoFeatureFlag, MaasoFeatureFlagAssignment>{};
    List<Map<String, Object?>> rows;
    var cacheAvailable = false;
    try {
      rows = await _store.readAll();
      cacheAvailable = true;
    } catch (_) {
      rows = const <Map<String, Object?>>[];
      Log.w('[FeatureFlags] assignment cache read failed; rollout remains off');
    }
    if (isClosed || _lifecycle != _FeatureFlagLifecycle.initializing) {
      return this;
    }
    for (final row in rows) {
      try {
        // Remember configuration existence even when its payload is corrupt.
        // In particular, a rejected off assignment is not an unconfigured
        // account that may inherit a default capability.
        _configuredFlags.add(MaasoFeatureFlag.parse(row['flag']));
      } on FormatException {
        // An unidentified row cannot prove this account has never configured
        // a default capability. Keep defaults disabled without altering any valid
        // explicit assignment or another flag's existing evaluation.
        _hasUnidentifiedAssignment = true;
      }
      try {
        final assignment = MaasoFeatureFlagAssignment.fromJson(row);
        final current = restored[assignment.flag];
        if (current == null || assignment.revision > current.revision) {
          restored[assignment.flag] = assignment;
        }
      } on FormatException {
        // Corrupt/unknown cache rows are not active assignments. A known
        // configured flag remains marked, preventing a default fallback.
      }
    }
    // A failed read cannot safely accept revisioned writes: an unseen newer
    // assignment could otherwise be overwritten. Account mount still succeeds
    // with every capability disabled.
    _lifecycle = cacheAvailable
        ? _FeatureFlagLifecycle.active
        : _FeatureFlagLifecycle.degraded;
    state.value =
        Map<MaasoFeatureFlag, MaasoFeatureFlagAssignment>.unmodifiable(
          restored,
        );
    _advanceAllAuthorityGenerations();
    return this;
  }

  /// Process-local epoch for capabilities derived from one rollout flag.
  ///
  /// The epoch advances for assignment, runtime-cap, and lifecycle changes,
  /// including an `off -> enforce` transition that reuses a persisted
  /// assignment revision. Consumers must bind admitted work to this value and
  /// check it again at their final mutation boundary.
  int authorityGeneration(MaasoFeatureFlag flag) =>
      _authorityGenerations[flag] ?? 0;

  FeatureRolloutMode effectiveMode(MaasoFeatureFlag flag, {DateTime? now}) {
    if (_lifecycle != _FeatureFlagLifecycle.active || isClosed) {
      return FeatureRolloutMode.off;
    }
    final assignment = state.value[flag];
    final FeatureRolloutMode mode;
    if (assignment == null) {
      if ((flag != MaasoFeatureFlag.memoryV2 &&
              flag != MaasoFeatureFlag.naturalConversation) ||
          _configuredFlags.contains(flag) ||
          _hasUnidentifiedAssignment) {
        return FeatureRolloutMode.off;
      }
      mode = FeatureRolloutMode.enforce;
    } else if (!assignment.isActiveAt(now ?? _clock())) {
      return FeatureRolloutMode.off;
    } else {
      mode = assignment.mode;
    }
    final compileMaximum = _compileMaximums[flag] ?? FeatureRolloutMode.off;
    final runtimeMaximum = _runtimeMaximums[flag] ?? FeatureRolloutMode.off;
    return mode
        .cappedBy(compileMaximum)
        .cappedBy(runtimeMaximum)
        .cappedBy(_hardMaximum(flag));
  }

  bool isShadowEnabled(MaasoFeatureFlag flag, {DateTime? now}) =>
      effectiveMode(flag, now: now) == FeatureRolloutMode.shadow;

  bool isObservationEnabled(MaasoFeatureFlag flag, {DateTime? now}) =>
      effectiveMode(flag, now: now) != FeatureRolloutMode.off;

  /// Process-local kill/rollback cap. It can only tighten the build cap.
  void setRuntimeMaximum(MaasoFeatureFlag flag, FeatureRolloutMode maximum) {
    _requireActive();
    final compileMaximum = _compileMaximums[flag] ?? FeatureRolloutMode.off;
    _runtimeMaximums[flag] = maximum.cappedBy(compileMaximum);
    _advanceAuthorityGeneration(flag);
    state.refresh();
  }

  void disableAll() {
    _requireActive();
    _disableRuntimeMaximums();
    _advanceAllAuthorityGenerations();
    state.refresh();
  }

  Future<void> assign({
    required MaasoFeatureFlag flag,
    required FeatureRolloutMode mode,
    required int revision,
    required DateTime expiresAt,
  }) {
    if (_lifecycle != _FeatureFlagLifecycle.active || isClosed) {
      return Future<void>.error(StateError('maaso_feature_flags_retired'));
    }
    if (revision < 1 || revision > maxMaasoFeatureFlagRevision) {
      return Future<void>.error(
        ArgumentError.value(
          revision,
          'revision',
          'must be a safe positive int',
        ),
      );
    }
    final expiry = expiresAt.toUtc();
    if (!expiry.isAfter(_clock().toUtc())) {
      return Future<void>.error(
        ArgumentError.value(expiresAt, 'expiresAt', 'must be in the future'),
      );
    }
    return _serializeMutation(() async {
      final current = state.value[flag];
      if (current != null && revision <= current.revision) {
        throw StateError('feature_flag_revision_not_newer');
      }
      final next = MaasoFeatureFlagAssignment(
        flag: flag,
        mode: mode,
        revision: revision,
        expiresAt: expiry,
      );
      await _store.write(next);
      _configuredFlags.add(flag);
      state.value =
          Map<MaasoFeatureFlag, MaasoFeatureFlagAssignment>.unmodifiable(
            <MaasoFeatureFlag, MaasoFeatureFlagAssignment>{
              ...state.value,
              flag: next,
            },
          );
      _advanceAuthorityGeneration(flag);
    });
  }

  Future<void> deactivateAndDrain() {
    _lifecycle = _FeatureFlagLifecycle.retired;
    _disableRuntimeMaximums();
    _advanceAllAuthorityGenerations();
    state.refresh();
    return _mutationTail;
  }

  Future<void> _serializeMutation(Future<void> Function() operation) {
    final previous = _mutationTail;
    final next = previous.then<void>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _mutationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  @override
  void onClose() {
    _lifecycle = _FeatureFlagLifecycle.retired;
    _disableRuntimeMaximums();
    _advanceAllAuthorityGenerations();
    state.value = const <MaasoFeatureFlag, MaasoFeatureFlagAssignment>{};
    super.onClose();
  }

  void _advanceAuthorityGeneration(MaasoFeatureFlag flag) {
    _authorityGenerations[flag] = (_authorityGenerations[flag] ?? 0) + 1;
  }

  void _advanceAllAuthorityGenerations() {
    for (final flag in MaasoFeatureFlag.values) {
      _advanceAuthorityGeneration(flag);
    }
  }

  void _disableRuntimeMaximums() {
    for (final flag in MaasoFeatureFlag.values) {
      _runtimeMaximums[flag] = FeatureRolloutMode.off;
    }
  }

  void _requireActive() {
    if (_lifecycle != _FeatureFlagLifecycle.active || isClosed) {
      throw StateError('maaso_feature_flags_retired');
    }
  }

  static Map<MaasoFeatureFlag, FeatureRolloutMode> parseCompileMaximums([
    String source = compileMaximumsSource,
  ]) {
    final result = <MaasoFeatureFlag, FeatureRolloutMode>{
      for (final flag in MaasoFeatureFlag.values)
        flag:
            flag == MaasoFeatureFlag.memoryV2 ||
                flag == MaasoFeatureFlag.naturalConversation
            ? FeatureRolloutMode.enforce
            : FeatureRolloutMode.off,
    };
    final defaultMaximumsConfigured = <MaasoFeatureFlag>{};
    for (final entry in source.split(',')) {
      final parts = entry.trim().split(':');
      // A malformed explicit entry for a default capability must suppress it.
      // Recognize an equals sign as malformed syntax, not as a missing flag.
      final claimedKey = entry.trim().split(RegExp(r'[:=]')).first.trim();
      if (claimedKey == MaasoFeatureFlag.memoryV2.key ||
          claimedKey == MaasoFeatureFlag.naturalConversation.key) {
        final flag = MaasoFeatureFlag.parse(claimedKey);
        var maximum = FeatureRolloutMode.off;
        if (parts.length == 2) {
          try {
            maximum = FeatureRolloutMode.parse(parts[1].trim());
          } on FormatException {
            // Invalid explicit maxima stay off.
          }
        }
        result[flag] = defaultMaximumsConfigured.contains(flag)
            ? maximum.cappedBy(result[flag]!)
            : maximum;
        defaultMaximumsConfigured.add(flag);
        continue;
      }
      if (parts.length != 2) continue;
      try {
        final flag = MaasoFeatureFlag.parse(parts[0].trim());
        result[flag] = FeatureRolloutMode.parse(parts[1].trim());
      } on FormatException {
        // Unknown keys and invalid modes stay fail-closed.
      }
    }
    return Map<MaasoFeatureFlag, FeatureRolloutMode>.unmodifiable(result);
  }
}

Map<MaasoFeatureFlag, FeatureRolloutMode> _completeMaximums(
  Map<MaasoFeatureFlag, FeatureRolloutMode> source,
) => <MaasoFeatureFlag, FeatureRolloutMode>{
  for (final flag in MaasoFeatureFlag.values)
    flag:
        source[flag] ??
        (flag == MaasoFeatureFlag.memoryV2 ||
                flag == MaasoFeatureFlag.naturalConversation
            ? FeatureRolloutMode.enforce
            : FeatureRolloutMode.off),
};

FeatureRolloutMode _hardMaximum(MaasoFeatureFlag _) =>
    FeatureRolloutMode.enforce;

DateTime _strictUtcTimestamp(Object? source) {
  if (source is! String || !source.endsWith('Z')) {
    throw const FormatException('feature flag expiresAt must be UTC');
  }
  late final DateTime parsed;
  try {
    parsed = DateTime.parse(source);
  } on FormatException {
    throw const FormatException('feature flag expiresAt is invalid');
  }
  if (!parsed.isUtc) {
    throw const FormatException('feature flag expiresAt must be UTC');
  }
  return parsed;
}
