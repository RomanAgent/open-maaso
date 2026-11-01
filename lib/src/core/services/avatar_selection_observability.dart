import 'package:maaso/src/core/services/avatar_selection_outbox.dart';

/// Account-lifetime state of the authoritative Avatar selection lane.
enum AvatarSelectionObservabilityLifecycle { active, sealing, retired }

/// Fixed operation dimensions exposed by Avatar selection diagnostics.
enum AvatarSelectionObservedOperation {
  currentRead,
  selectionCommit,
  exactReplay,
  compensation,
  recovery,
  retirement,
  worldFence,
  drain,
}

/// Fixed completion dimensions exposed by Avatar selection diagnostics.
enum AvatarSelectionObservedOutcome {
  succeeded,
  noChange,
  rolledForward,
  compensated,
  superseded,
  versionConflict,
  ambiguousFailure,
  rejected,
  timedOut,
  failed,
}

/// Coarse latency dimensions avoid retaining exact operation timing.
enum AvatarSelectionLatencyBucket {
  under100ms,
  under500ms,
  under2s,
  under10s,
  tenSecondsOrMore,
}

/// Coarse age of the single durable obligation allowed per Agent lane.
enum AvatarSelectionOutboxAgeBucket {
  under1m,
  under5m,
  under1h,
  under24h,
  dayOrMore,
}

/// Immutable, fixed-cardinality Avatar selection diagnostics.
///
/// This type deliberately contains no account, agent, model, request,
/// idempotency, digest, URL, path, token, error, or other free-text field.
final class AvatarSelectionObservabilitySnapshot {
  const AvatarSelectionObservabilitySnapshot._({
    required this.lifecycle,
    required this.currentProven,
    required this.currentVersion,
    required this.outboxObserved,
    required this.outboxPresent,
    required this.outboxStage,
    required this.outboxResolution,
    required this.outboxAgeBucket,
    required this.inFlight,
    required this.operationCounts,
    required this.outcomeCounts,
    required this.retryTotal,
    required this.retryMax,
    required this.latencyBuckets,
  });

  final AvatarSelectionObservabilityLifecycle lifecycle;
  final bool currentProven;
  final int? currentVersion;
  final bool outboxObserved;
  final bool outboxPresent;
  final AvatarSelectionOutboxStage? outboxStage;
  final AvatarSelectionOutboxResolution? outboxResolution;
  final AvatarSelectionOutboxAgeBucket? outboxAgeBucket;
  final int inFlight;
  final Map<AvatarSelectionObservedOperation, int> operationCounts;
  final Map<AvatarSelectionObservedOutcome, int> outcomeCounts;
  final int retryTotal;
  final int retryMax;
  final Map<AvatarSelectionLatencyBucket, int> latencyBuckets;

  /// Fixed-schema export for metrics sinks that cannot consume enum-key maps.
  Map<String, Object?> toMetrics() => <String, Object?>{
    'lifecycle': lifecycle.name,
    'currentProven': currentProven,
    'currentVersion': currentVersion,
    'outboxObserved': outboxObserved,
    'outboxPresent': outboxPresent,
    'outboxStage': outboxStage?.name,
    'outboxResolution': outboxResolution?.name,
    'outboxAgeBucket': outboxAgeBucket?.name,
    'inFlight': inFlight,
    'operationCounts': _namedCounts(
      AvatarSelectionObservedOperation.values,
      operationCounts,
    ),
    'outcomeCounts': _namedCounts(
      AvatarSelectionObservedOutcome.values,
      outcomeCounts,
    ),
    'retryTotal': retryTotal,
    'retryMax': retryMax,
    'latencyBuckets': _namedCounts(
      AvatarSelectionLatencyBucket.values,
      latencyBuckets,
    ),
  };

  static Map<String, int> _namedCounts<T extends Enum>(
    Iterable<T> values,
    Map<T, int> counts,
  ) => Map<String, int>.unmodifiable(<String, int>{
    for (final value in values) value.name: counts[value] ?? 0,
  });
}

/// Opaque handle for one operation admitted by [AvatarSelectionObservability].
///
/// The handle retains only a fixed operation enum and monotonic duration.
final class AvatarSelectionObservation {
  AvatarSelectionObservation._({
    required Object owner,
    required this.operation,
    required Duration startedAt,
    required bool countedInFlight,
  }) : _owner = owner,
       _startedAt = startedAt,
       _countedInFlight = countedInFlight;

  final Object _owner;
  final AvatarSelectionObservedOperation operation;
  final Duration _startedAt;
  final bool _countedInFlight;

  bool _ended = false;
  int _retries = 0;
}

/// Privacy-safe, best-effort diagnostics for authoritative Avatar selection.
///
/// All dimensions are fixed enums, booleans, bounded integers, or coarse
/// duration buckets. Observation methods never retain identifiers, requests,
/// assets, exception objects, stack traces, or arbitrary text.
final class AvatarSelectionObservability {
  AvatarSelectionObservability({
    Duration Function()? monotonicClock,
    DateTime Function()? wallClock,
    int maximumCounter = 0x7fffffff,
  }) : _clock = monotonicClock ?? _newMonotonicClock(),
       _wallClock = wallClock ?? DateTime.now,
       _maximumCounter = maximumCounter {
    if (maximumCounter <= 0) {
      throw ArgumentError.value(
        maximumCounter,
        'maximumCounter',
        'must be positive',
      );
    }
  }

  static const int _maximumVersion = 9007199254740991;

  final Duration Function() _clock;
  final DateTime Function() _wallClock;
  final int _maximumCounter;
  final Object _owner = Object();

  AvatarSelectionObservabilityLifecycle _lifecycle =
      AvatarSelectionObservabilityLifecycle.active;
  bool _currentProven = false;
  int? _currentVersion;
  bool _outboxObserved = false;
  bool _outboxPresent = false;
  AvatarSelectionOutboxStage? _outboxStage;
  AvatarSelectionOutboxResolution? _outboxResolution;
  DateTime? _outboxCreatedAt;
  int _inFlight = 0;
  int _retryTotal = 0;
  int _retryMax = 0;
  final Map<AvatarSelectionObservedOperation, int> _operationCounts =
      <AvatarSelectionObservedOperation, int>{};
  final Map<AvatarSelectionObservedOutcome, int> _outcomeCounts =
      <AvatarSelectionObservedOutcome, int>{};
  final Map<AvatarSelectionLatencyBucket, int> _latencyBuckets =
      <AvatarSelectionLatencyBucket, int>{};

  AvatarSelectionObservabilitySnapshot get snapshot =>
      AvatarSelectionObservabilitySnapshot._(
        lifecycle: _lifecycle,
        currentProven: _currentProven,
        currentVersion: _currentVersion,
        outboxObserved: _outboxObserved,
        outboxPresent: _outboxPresent,
        outboxStage: _outboxStage,
        outboxResolution: _outboxResolution,
        outboxAgeBucket: _outboxCreatedAt == null
            ? null
            : _ageBucket(_outboxCreatedAt!),
        inFlight: _inFlight,
        operationCounts: _completeCounts(
          AvatarSelectionObservedOperation.values,
          _operationCounts,
        ),
        outcomeCounts: _completeCounts(
          AvatarSelectionObservedOutcome.values,
          _outcomeCounts,
        ),
        retryTotal: _retryTotal,
        retryMax: _retryMax,
        latencyBuckets: _completeCounts(
          AvatarSelectionLatencyBucket.values,
          _latencyBuckets,
        ),
      );

  void observeLifecycle(AvatarSelectionObservabilityLifecycle lifecycle) {
    _lifecycle = lifecycle;
  }

  /// Records only proof state and the contract's non-identifying CAS version.
  /// Invalid versions fail closed to an unproven, absent version.
  void observeCurrent({required bool proven, required int? version}) {
    final validVersion =
        version != null && version >= 0 && version <= _maximumVersion;
    _currentVersion = validVersion ? version : null;
    _currentProven = proven && validVersion;
  }

  /// Observes only the durable stage and resolution of an outbox entry.
  ///
  /// All identifying fields on [AvatarSelectionOutboxEntry] are intentionally
  /// ignored and never copied into this object's state.
  void observeOutbox(AvatarSelectionOutboxEntry? entry) {
    _outboxObserved = true;
    _outboxPresent = entry != null;
    _outboxStage = entry?.stage;
    _outboxResolution = entry?.resolution;
    _outboxCreatedAt = entry?.createdAt;
  }

  AvatarSelectionObservation begin(AvatarSelectionObservedOperation operation) {
    _operationCounts[operation] = _increment(_operationCounts[operation] ?? 0);
    final countedInFlight = _inFlight < _maximumCounter;
    if (countedInFlight) _inFlight += 1;
    return AvatarSelectionObservation._(
      owner: _owner,
      operation: operation,
      startedAt: _now(),
      countedInFlight: countedInFlight,
    );
  }

  /// Records one retry for an active operation. Foreign or completed handles
  /// are ignored so diagnostics cannot alter the production path.
  void retry(AvatarSelectionObservation observation) {
    if (!_isActive(observation)) return;
    observation._retries = _increment(observation._retries);
    _retryTotal = _increment(_retryTotal);
    if (observation._retries > _retryMax) {
      _retryMax = observation._retries;
    }
  }

  /// Completes an observation exactly once and records a coarse latency.
  void end(
    AvatarSelectionObservation observation, {
    required AvatarSelectionObservedOutcome outcome,
  }) {
    if (!_isActive(observation)) return;
    observation._ended = true;
    if (observation._countedInFlight && _inFlight > 0) _inFlight -= 1;
    _outcomeCounts[outcome] = _increment(_outcomeCounts[outcome] ?? 0);
    _recordLatency(_now() - observation._startedAt);
  }

  /// Records an already-measured operation without changing [snapshot]'s
  /// in-flight count.
  void record({
    required AvatarSelectionObservedOperation operation,
    required AvatarSelectionObservedOutcome outcome,
    required Duration latency,
    int retries = 0,
  }) {
    _operationCounts[operation] = _increment(_operationCounts[operation] ?? 0);
    _outcomeCounts[outcome] = _increment(_outcomeCounts[outcome] ?? 0);
    final boundedRetries = _boundedNonNegative(retries);
    _retryTotal = _saturatingAdd(_retryTotal, boundedRetries);
    if (boundedRetries > _retryMax) _retryMax = boundedRetries;
    _recordLatency(latency);
  }

  bool _isActive(AvatarSelectionObservation observation) =>
      identical(observation._owner, _owner) && !observation._ended;

  void _recordLatency(Duration latency) {
    final bucket = _latencyBucket(latency.isNegative ? Duration.zero : latency);
    _latencyBuckets[bucket] = _increment(_latencyBuckets[bucket] ?? 0);
  }

  int _boundedNonNegative(int value) {
    if (value <= 0) return 0;
    return value >= _maximumCounter ? _maximumCounter : value;
  }

  int _increment(int value) =>
      value >= _maximumCounter ? _maximumCounter : value + 1;

  int _saturatingAdd(int current, int amount) {
    if (amount <= 0 || current >= _maximumCounter) return current;
    final remaining = _maximumCounter - current;
    return amount >= remaining ? _maximumCounter : current + amount;
  }

  Duration _now() {
    try {
      final value = _clock();
      return value.isNegative ? Duration.zero : value;
    } on Object {
      return Duration.zero;
    }
  }

  static Map<T, int> _completeCounts<T extends Enum>(
    Iterable<T> values,
    Map<T, int> counts,
  ) => Map<T, int>.unmodifiable(<T, int>{
    for (final value in values) value: counts[value] ?? 0,
  });

  static AvatarSelectionLatencyBucket _latencyBucket(Duration latency) {
    if (latency < const Duration(milliseconds: 100)) {
      return AvatarSelectionLatencyBucket.under100ms;
    }
    if (latency < const Duration(milliseconds: 500)) {
      return AvatarSelectionLatencyBucket.under500ms;
    }
    if (latency < const Duration(seconds: 2)) {
      return AvatarSelectionLatencyBucket.under2s;
    }
    if (latency < const Duration(seconds: 10)) {
      return AvatarSelectionLatencyBucket.under10s;
    }
    return AvatarSelectionLatencyBucket.tenSecondsOrMore;
  }

  AvatarSelectionOutboxAgeBucket? _ageBucket(DateTime createdAt) {
    try {
      final age = _wallClock().toUtc().difference(createdAt.toUtc());
      final safeAge = age.isNegative ? Duration.zero : age;
      if (safeAge < const Duration(minutes: 1)) {
        return AvatarSelectionOutboxAgeBucket.under1m;
      }
      if (safeAge < const Duration(minutes: 5)) {
        return AvatarSelectionOutboxAgeBucket.under5m;
      }
      if (safeAge < const Duration(hours: 1)) {
        return AvatarSelectionOutboxAgeBucket.under1h;
      }
      if (safeAge < const Duration(hours: 24)) {
        return AvatarSelectionOutboxAgeBucket.under24h;
      }
      return AvatarSelectionOutboxAgeBucket.dayOrMore;
    } on Object {
      return null;
    }
  }

  static Duration Function() _newMonotonicClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}
