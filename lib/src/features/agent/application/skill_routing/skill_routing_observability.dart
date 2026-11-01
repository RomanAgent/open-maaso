import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_explanation.dart';

/// Result of one executable Host Skill activation attempt.
///
/// This deliberately records no skill identifier. Keeping the dimensions
/// finite prevents a large or user-defined catalog from creating unbounded
/// metric cardinality.
enum SkillActivationOutcome { selected, denied, stale, error }

/// Numeric, privacy-safe measurements for one deterministic routing pass.
///
/// User text, skill identifiers, account identifiers, page names, locale, and
/// free-form failure reasons are intentionally absent. Callers must compute
/// byte/cost estimates before recording the observation and must never pass
/// prompt content to this API.
class SkillRoutingObservation {
  factory SkillRoutingObservation({
    required Duration routingLatency,
    required int catalogSize,
    required int candidateCount,
    required int selectedK,
    required int promptCostUnits,
    required int promptBytesEstimate,
    required SkillRouteDisposition disposition,
    SkillRoutingExplanation explanation = SkillRoutingExplanation.unknown,
  }) {
    final routingLatencyMicros = routingLatency.inMicroseconds;
    _requireMetric(routingLatencyMicros, 'routingLatency.inMicroseconds');
    _requireMetric(catalogSize, 'catalogSize');
    _requireMetric(candidateCount, 'candidateCount');
    _requireMetric(selectedK, 'selectedK');
    _requireMetric(promptCostUnits, 'promptCostUnits');
    _requireMetric(promptBytesEstimate, 'promptBytesEstimate');
    if (candidateCount > catalogSize) {
      throw ArgumentError.value(
        candidateCount,
        'candidateCount',
        'must not exceed catalogSize',
      );
    }
    if (selectedK > candidateCount) {
      throw ArgumentError.value(
        selectedK,
        'selectedK',
        'must not exceed candidateCount',
      );
    }
    if (disposition == SkillRouteDisposition.selected && selectedK == 0) {
      throw ArgumentError.value(
        selectedK,
        'selectedK',
        'must be positive when the disposition is selected',
      );
    }
    if (disposition != SkillRouteDisposition.selected && selectedK != 0) {
      throw ArgumentError.value(
        selectedK,
        'selectedK',
        'must be zero unless the disposition is selected',
      );
    }
    return SkillRoutingObservation._(
      routingLatencyMicros: routingLatencyMicros,
      catalogSize: catalogSize,
      candidateCount: candidateCount,
      selectedK: selectedK,
      promptCostUnits: promptCostUnits,
      promptBytesEstimate: promptBytesEstimate,
      disposition: disposition,
      explanation: explanation,
    );
  }

  const SkillRoutingObservation._({
    required this.routingLatencyMicros,
    required this.catalogSize,
    required this.candidateCount,
    required this.selectedK,
    required this.promptCostUnits,
    required this.promptBytesEstimate,
    required this.disposition,
    required this.explanation,
  });

  /// Largest integer that remains exact when encoded by the Web runtime.
  static const int maxMetricValue = 0x1fffffffffffff;

  final int routingLatencyMicros;
  final int catalogSize;
  final int candidateCount;
  final int selectedK;
  final int promptCostUnits;
  final int promptBytesEstimate;
  final SkillRouteDisposition disposition;
  final SkillRoutingExplanation explanation;

  Map<String, Object> toJson() => <String, Object>{
    'routing_latency_micros': routingLatencyMicros,
    'catalog_size': catalogSize,
    'candidate_count': candidateCount,
    'selected_k': selectedK,
    'prompt_cost_units': promptCostUnits,
    'prompt_bytes_estimate': promptBytesEstimate,
    'disposition': disposition.name,
    'explanation': explanation.toJson(),
  };

  static void _requireMetric(int value, String name) {
    if (value < 0 || value > maxMetricValue) {
      throw RangeError.range(value, 0, maxMetricValue, name);
    }
  }
}

/// Saturating aggregate for one non-negative metric.
class SkillRoutingMetricSummary {
  const SkillRoutingMetricSummary({required this.total, required this.max});

  final int total;
  final int max;

  Map<String, int> toJson() => <String, int>{'total': total, 'max': max};
}

/// Immutable, bounded export of routing health.
///
/// Every map has enum-bounded keys and [recentRoutes] is capped by the
/// collector's retention limit. The snapshot is safe to hand to an exporter;
/// it contains no user text, timestamps, account/locale labels, page scopes,
/// or skill identifiers.
class SkillRoutingMetricsSnapshot {
  SkillRoutingMetricsSnapshot._({
    required this.routingCount,
    required this.activationCount,
    required this.routingLatencyMicros,
    required this.catalogSize,
    required this.candidateCount,
    required this.selectedK,
    required this.promptCostUnits,
    required this.promptBytesEstimate,
    required Map<SkillRouteDisposition, int> dispositionCounts,
    required Map<SkillActivationOutcome, int> activationOutcomeCounts,
    required List<int> latencyBucketUpperBoundsMicros,
    required List<int> latencyBucketCounts,
    required List<SkillRoutingObservation> recentRoutes,
    required this.explanations,
  }) : dispositionCounts = Map.unmodifiable(dispositionCounts),
       activationOutcomeCounts = Map.unmodifiable(activationOutcomeCounts),
       latencyBucketUpperBoundsMicros = List.unmodifiable(
         latencyBucketUpperBoundsMicros,
       ),
       latencyBucketCounts = List.unmodifiable(latencyBucketCounts),
       recentRoutes = List.unmodifiable(recentRoutes);

  final int routingCount;
  final int activationCount;
  final SkillRoutingMetricSummary routingLatencyMicros;
  final SkillRoutingMetricSummary catalogSize;
  final SkillRoutingMetricSummary candidateCount;
  final SkillRoutingMetricSummary selectedK;
  final SkillRoutingMetricSummary promptCostUnits;
  final SkillRoutingMetricSummary promptBytesEstimate;
  final Map<SkillRouteDisposition, int> dispositionCounts;
  final Map<SkillActivationOutcome, int> activationOutcomeCounts;
  final List<int> latencyBucketUpperBoundsMicros;

  /// One overflow bucket follows the last upper bound.
  final List<int> latencyBucketCounts;

  final List<SkillRoutingObservation> recentRoutes;
  final Map<String, Object> explanations;

  Map<String, Object> toJson() => <String, Object>{
    'schema_version': 1,
    'routing_count': routingCount,
    'activation_count': activationCount,
    'routing_latency_micros': <String, Object>{
      ...routingLatencyMicros.toJson(),
      'bucket_upper_bounds': latencyBucketUpperBoundsMicros,
      'bucket_counts': latencyBucketCounts,
    },
    'catalog_size': catalogSize.toJson(),
    'candidate_count': candidateCount.toJson(),
    'selected_k': selectedK.toJson(),
    'prompt_cost_units': promptCostUnits.toJson(),
    'prompt_bytes_estimate': promptBytesEstimate.toJson(),
    'dispositions': <String, int>{
      for (final disposition in SkillRouteDisposition.values)
        disposition.name: dispositionCounts[disposition] ?? 0,
    },
    'activation_outcomes': <String, int>{
      for (final outcome in SkillActivationOutcome.values)
        outcome.name: activationOutcomeCounts[outcome] ?? 0,
    },
    'recent_routes': <Map<String, Object>>[
      for (final route in recentRoutes) route.toJson(),
    ],
    'explanations': explanations,
  };
}

/// Bounded, synchronous in-memory routing metrics collector.
///
/// Dart async callers in one isolate cannot interleave a synchronous method,
/// so each mutation is atomic with respect to those callers. Isolates do not
/// share mutable memory; a multi-isolate host should export one snapshot per
/// isolate and merge the fixed numeric fields outside this collector.
class SkillRoutingMetricsCollector {
  factory SkillRoutingMetricsCollector({int retainedRouteLimit = 64}) {
    if (retainedRouteLimit < 0 || retainedRouteLimit > maxRetainedRoutes) {
      throw RangeError.range(
        retainedRouteLimit,
        0,
        maxRetainedRoutes,
        'retainedRouteLimit',
      );
    }
    return SkillRoutingMetricsCollector._(retainedRouteLimit);
  }

  SkillRoutingMetricsCollector._(this.retainedRouteLimit)
    : _recentRoutes = List<SkillRoutingObservation?>.filled(
        retainedRouteLimit,
        null,
      ),
      _dispositionCounts = List<int>.filled(
        SkillRouteDisposition.values.length,
        0,
      ),
      _activationOutcomeCounts = List<int>.filled(
        SkillActivationOutcome.values.length,
        0,
      ),
      _latencyBucketCounts = List<int>.filled(
        latencyBucketUpperBoundsMicros.length + 1,
        0,
      );

  static const int maxRetainedRoutes = 256;

  static const List<int> latencyBucketUpperBoundsMicros = <int>[
    250,
    500,
    1000,
    2500,
    5000,
    10000,
    25000,
    50000,
    100000,
    250000,
    1000000,
  ];

  final int retainedRouteLimit;
  final _explanations = SkillRoutingExplanationMetrics();
  final List<SkillRoutingObservation?> _recentRoutes;
  final List<int> _dispositionCounts;
  final List<int> _activationOutcomeCounts;
  final List<int> _latencyBucketCounts;

  int _routingCount = 0;
  int _activationCount = 0;
  int _recentWriteIndex = 0;
  int _recentCount = 0;

  int _routingLatencyTotal = 0;
  int _routingLatencyMax = 0;
  int _catalogSizeTotal = 0;
  int _catalogSizeMax = 0;
  int _candidateCountTotal = 0;
  int _candidateCountMax = 0;
  int _selectedKTotal = 0;
  int _selectedKMax = 0;
  int _promptCostTotal = 0;
  int _promptCostMax = 0;
  int _promptBytesTotal = 0;
  int _promptBytesMax = 0;

  void recordRouting(SkillRoutingObservation observation) {
    _explanations.record(observation.explanation);
    _routingCount = _increment(_routingCount);
    _routingLatencyTotal = _add(
      _routingLatencyTotal,
      observation.routingLatencyMicros,
    );
    _routingLatencyMax = _greater(
      _routingLatencyMax,
      observation.routingLatencyMicros,
    );
    _catalogSizeTotal = _add(_catalogSizeTotal, observation.catalogSize);
    _catalogSizeMax = _greater(_catalogSizeMax, observation.catalogSize);
    _candidateCountTotal = _add(
      _candidateCountTotal,
      observation.candidateCount,
    );
    _candidateCountMax = _greater(
      _candidateCountMax,
      observation.candidateCount,
    );
    _selectedKTotal = _add(_selectedKTotal, observation.selectedK);
    _selectedKMax = _greater(_selectedKMax, observation.selectedK);
    _promptCostTotal = _add(_promptCostTotal, observation.promptCostUnits);
    _promptCostMax = _greater(_promptCostMax, observation.promptCostUnits);
    _promptBytesTotal = _add(
      _promptBytesTotal,
      observation.promptBytesEstimate,
    );
    _promptBytesMax = _greater(
      _promptBytesMax,
      observation.promptBytesEstimate,
    );
    final dispositionIndex = observation.disposition.index;
    _dispositionCounts[dispositionIndex] = _increment(
      _dispositionCounts[dispositionIndex],
    );
    final bucketIndex = _latencyBucketIndex(observation.routingLatencyMicros);
    _latencyBucketCounts[bucketIndex] = _increment(
      _latencyBucketCounts[bucketIndex],
    );
    _retain(observation);
  }

  void recordActivation(SkillActivationOutcome outcome) {
    _activationCount = _increment(_activationCount);
    _activationOutcomeCounts[outcome.index] = _increment(
      _activationOutcomeCounts[outcome.index],
    );
  }

  SkillRoutingMetricsSnapshot snapshot() => SkillRoutingMetricsSnapshot._(
    routingCount: _routingCount,
    activationCount: _activationCount,
    routingLatencyMicros: SkillRoutingMetricSummary(
      total: _routingLatencyTotal,
      max: _routingLatencyMax,
    ),
    catalogSize: SkillRoutingMetricSummary(
      total: _catalogSizeTotal,
      max: _catalogSizeMax,
    ),
    candidateCount: SkillRoutingMetricSummary(
      total: _candidateCountTotal,
      max: _candidateCountMax,
    ),
    selectedK: SkillRoutingMetricSummary(
      total: _selectedKTotal,
      max: _selectedKMax,
    ),
    promptCostUnits: SkillRoutingMetricSummary(
      total: _promptCostTotal,
      max: _promptCostMax,
    ),
    promptBytesEstimate: SkillRoutingMetricSummary(
      total: _promptBytesTotal,
      max: _promptBytesMax,
    ),
    dispositionCounts: <SkillRouteDisposition, int>{
      for (final disposition in SkillRouteDisposition.values)
        disposition: _dispositionCounts[disposition.index],
    },
    activationOutcomeCounts: <SkillActivationOutcome, int>{
      for (final outcome in SkillActivationOutcome.values)
        outcome: _activationOutcomeCounts[outcome.index],
    },
    latencyBucketUpperBoundsMicros: latencyBucketUpperBoundsMicros,
    latencyBucketCounts: _latencyBucketCounts,
    recentRoutes: _recentRoutesInOrder(),
    explanations: _explanations.snapshot(),
  );

  void _retain(SkillRoutingObservation observation) {
    if (_recentRoutes.isEmpty) return;
    _recentRoutes[_recentWriteIndex] = observation;
    _recentWriteIndex = (_recentWriteIndex + 1) % _recentRoutes.length;
    if (_recentCount < _recentRoutes.length) _recentCount++;
  }

  List<SkillRoutingObservation> _recentRoutesInOrder() {
    if (_recentCount == 0) return const <SkillRoutingObservation>[];
    final start = (_recentWriteIndex - _recentCount) % _recentRoutes.length;
    return <SkillRoutingObservation>[
      for (var offset = 0; offset < _recentCount; offset++)
        _recentRoutes[(start + offset) % _recentRoutes.length]!,
    ];
  }

  static int _latencyBucketIndex(int latencyMicros) {
    for (
      var index = 0;
      index < latencyBucketUpperBoundsMicros.length;
      index++
    ) {
      if (latencyMicros <= latencyBucketUpperBoundsMicros[index]) return index;
    }
    return latencyBucketUpperBoundsMicros.length;
  }

  static int _increment(int value) =>
      value >= SkillRoutingObservation.maxMetricValue
      ? SkillRoutingObservation.maxMetricValue
      : value + 1;

  static int _add(int current, int value) {
    final remaining = SkillRoutingObservation.maxMetricValue - current;
    return value >= remaining
        ? SkillRoutingObservation.maxMetricValue
        : current + value;
  }

  static int _greater(int current, int candidate) =>
      candidate > current ? candidate : current;
}
