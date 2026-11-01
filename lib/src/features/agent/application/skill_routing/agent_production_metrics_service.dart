import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_observability.dart';

enum AgentRuntimeEnsureOutcome { created, reused, error }

enum AgentFirstResponseOutcome { success, error }

/// Immutable fixed-cardinality latency export.
class AgentLatencyMetricsSnapshot {
  AgentLatencyMetricsSnapshot._({
    required this.count,
    required this.totalMicros,
    required this.maxMicros,
    required List<int> bucketUpperBoundsMicros,
    required List<int> bucketCounts,
  }) : bucketUpperBoundsMicros = List<int>.unmodifiable(
         bucketUpperBoundsMicros,
       ),
       bucketCounts = List<int>.unmodifiable(bucketCounts);

  final int count;
  final int totalMicros;
  final int maxMicros;
  final List<int> bucketUpperBoundsMicros;

  /// One overflow bucket follows the final upper bound.
  final List<int> bucketCounts;

  Map<String, Object> toJson() => <String, Object>{
    'count': count,
    'total_micros': totalMicros,
    'max_micros': maxMicros,
    'bucket_upper_bounds': bucketUpperBoundsMicros,
    'bucket_counts': bucketCounts,
  };
}

/// Privacy-safe process-local production metrics snapshot.
///
/// The schema contains only numeric aggregates and enum-bounded outcomes. It
/// deliberately excludes text, identifiers, page/locale dimensions,
/// timestamps, and free-form error values.
class AgentProductionMetricsSnapshot {
  AgentProductionMetricsSnapshot._({
    required this.coldStart,
    required this.runtimeEnsure,
    required this.firstResponse,
    required Map<AgentRuntimeEnsureOutcome, int> runtimeEnsureOutcomeCounts,
    required Map<AgentFirstResponseOutcome, int> firstResponseOutcomeCounts,
    required this.routing,
  }) : runtimeEnsureOutcomeCounts = Map.unmodifiable(
         runtimeEnsureOutcomeCounts,
       ),
       firstResponseOutcomeCounts = Map.unmodifiable(
         firstResponseOutcomeCounts,
       );

  final AgentLatencyMetricsSnapshot coldStart;
  final AgentLatencyMetricsSnapshot runtimeEnsure;
  final AgentLatencyMetricsSnapshot firstResponse;
  final Map<AgentRuntimeEnsureOutcome, int> runtimeEnsureOutcomeCounts;
  final Map<AgentFirstResponseOutcome, int> firstResponseOutcomeCounts;
  final SkillRoutingMetricsSnapshot routing;

  Map<String, Object> toJson() => <String, Object>{
    'schema_version': 1,
    'cold_start': coldStart.toJson(),
    'runtime_ensure': <String, Object>{
      ...runtimeEnsure.toJson(),
      'outcomes': <String, int>{
        for (final outcome in AgentRuntimeEnsureOutcome.values)
          outcome.name: runtimeEnsureOutcomeCounts[outcome] ?? 0,
      },
    },
    'first_response': <String, Object>{
      ...firstResponse.toJson(),
      'outcomes': <String, int>{
        for (final outcome in AgentFirstResponseOutcome.values)
          outcome.name: firstResponseOutcomeCounts[outcome] ?? 0,
      },
    },
    'routing': routing.toJson(),
  };
}

/// Synchronous, zero-I/O owner for production Agent latency and routing data.
///
/// Registration is safe on the startup path: the service starts no timers,
/// reads no storage, performs no network calls, and exports nothing by itself.
class AgentProductionMetricsService extends AppService {
  AgentProductionMetricsService({int retainedRouteLimit = 0})
    : routing = SkillRoutingMetricsCollector(
        retainedRouteLimit: retainedRouteLimit,
      );

  static const List<int> latencyBucketUpperBoundsMicros = <int>[
    1000,
    2500,
    5000,
    10000,
    25000,
    50000,
    100000,
    250000,
    500000,
    1000000,
    2500000,
    5000000,
    10000000,
    30000000,
  ];

  final SkillRoutingMetricsCollector routing;
  final _LatencyAccumulator _coldStart = _LatencyAccumulator();
  final _LatencyAccumulator _runtimeEnsure = _LatencyAccumulator();
  final _LatencyAccumulator _firstResponse = _LatencyAccumulator();
  final List<int> _runtimeEnsureOutcomeCounts = List<int>.filled(
    AgentRuntimeEnsureOutcome.values.length,
    0,
  );
  final List<int> _firstResponseOutcomeCounts = List<int>.filled(
    AgentFirstResponseOutcome.values.length,
    0,
  );
  bool _coldStartRecorded = false;

  /// Records time to the first Flutter frame at most once per process.
  void recordColdStart(Duration latency) {
    _validateLatency(latency);
    if (_coldStartRecorded) return;
    _coldStartRecorded = true;
    _coldStart.record(latency.inMicroseconds);
  }

  void recordRuntimeEnsure(
    Duration latency,
    AgentRuntimeEnsureOutcome outcome,
  ) {
    _validateLatency(latency);
    _runtimeEnsure.record(latency.inMicroseconds);
    _runtimeEnsureOutcomeCounts[outcome.index] = _increment(
      _runtimeEnsureOutcomeCounts[outcome.index],
    );
  }

  void recordFirstResponse(
    Duration latency,
    AgentFirstResponseOutcome outcome,
  ) {
    _validateLatency(latency);
    _firstResponse.record(latency.inMicroseconds);
    _firstResponseOutcomeCounts[outcome.index] = _increment(
      _firstResponseOutcomeCounts[outcome.index],
    );
  }

  AgentProductionMetricsSnapshot snapshot() => AgentProductionMetricsSnapshot._(
    coldStart: _coldStart.snapshot(),
    runtimeEnsure: _runtimeEnsure.snapshot(),
    firstResponse: _firstResponse.snapshot(),
    runtimeEnsureOutcomeCounts: <AgentRuntimeEnsureOutcome, int>{
      for (final outcome in AgentRuntimeEnsureOutcome.values)
        outcome: _runtimeEnsureOutcomeCounts[outcome.index],
    },
    firstResponseOutcomeCounts: <AgentFirstResponseOutcome, int>{
      for (final outcome in AgentFirstResponseOutcome.values)
        outcome: _firstResponseOutcomeCounts[outcome.index],
    },
    routing: routing.snapshot(),
  );

  static void _validateLatency(Duration latency) {
    final micros = latency.inMicroseconds;
    if (micros < 0 || micros > SkillRoutingObservation.maxMetricValue) {
      throw RangeError.range(
        micros,
        0,
        SkillRoutingObservation.maxMetricValue,
        'latency.inMicroseconds',
      );
    }
  }

  static int _increment(int value) =>
      value >= SkillRoutingObservation.maxMetricValue
      ? SkillRoutingObservation.maxMetricValue
      : value + 1;
}

class _LatencyAccumulator {
  _LatencyAccumulator()
    : _bucketCounts = List<int>.filled(
        AgentProductionMetricsService.latencyBucketUpperBoundsMicros.length + 1,
        0,
      );

  final List<int> _bucketCounts;
  int _count = 0;
  int _totalMicros = 0;
  int _maxMicros = 0;

  void record(int micros) {
    _count = AgentProductionMetricsService._increment(_count);
    final remaining = SkillRoutingObservation.maxMetricValue - _totalMicros;
    _totalMicros = micros >= remaining
        ? SkillRoutingObservation.maxMetricValue
        : _totalMicros + micros;
    if (micros > _maxMicros) _maxMicros = micros;
    final bucket = _bucketIndex(micros);
    _bucketCounts[bucket] = AgentProductionMetricsService._increment(
      _bucketCounts[bucket],
    );
  }

  AgentLatencyMetricsSnapshot snapshot() => AgentLatencyMetricsSnapshot._(
    count: _count,
    totalMicros: _totalMicros,
    maxMicros: _maxMicros,
    bucketUpperBoundsMicros:
        AgentProductionMetricsService.latencyBucketUpperBoundsMicros,
    bucketCounts: _bucketCounts,
  );

  static int _bucketIndex(int micros) {
    final bounds = AgentProductionMetricsService.latencyBucketUpperBoundsMicros;
    for (var index = 0; index < bounds.length; index++) {
      if (micros <= bounds[index]) return index;
    }
    return bounds.length;
  }
}
