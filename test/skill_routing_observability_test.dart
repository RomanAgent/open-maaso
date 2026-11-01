import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_observability.dart';

void main() {
  test('records deterministic route and activation counters', () {
    final collector = SkillRoutingMetricsCollector(retainedRouteLimit: 2);
    collector.recordRouting(
      _observation(
        latencyMicros: 7,
        catalogSize: 100,
        candidateCount: 3,
        selectedK: 2,
        promptCostUnits: 80,
        promptBytesEstimate: 320,
        disposition: SkillRouteDisposition.selected,
      ),
    );
    collector.recordRouting(
      _observation(
        latencyMicros: 260,
        catalogSize: 200,
        candidateCount: 4,
        disposition: SkillRouteDisposition.clarify,
      ),
    );
    collector.recordRouting(
      _observation(
        latencyMicros: 2000000,
        catalogSize: 10000,
        candidateCount: 0,
        disposition: SkillRouteDisposition.noTool,
      ),
    );
    collector
      ..recordActivation(SkillActivationOutcome.selected)
      ..recordActivation(SkillActivationOutcome.selected)
      ..recordActivation(SkillActivationOutcome.denied)
      ..recordActivation(SkillActivationOutcome.stale)
      ..recordActivation(SkillActivationOutcome.error);

    final snapshot = collector.snapshot();
    expect(snapshot.routingCount, 3);
    expect(snapshot.activationCount, 5);
    expect(snapshot.routingLatencyMicros.total, 2000267);
    expect(snapshot.routingLatencyMicros.max, 2000000);
    expect(snapshot.catalogSize.total, 10300);
    expect(snapshot.catalogSize.max, 10000);
    expect(snapshot.candidateCount.total, 7);
    expect(snapshot.candidateCount.max, 4);
    expect(snapshot.selectedK.total, 2);
    expect(snapshot.promptCostUnits.total, 80);
    expect(snapshot.promptBytesEstimate.total, 320);
    expect(snapshot.dispositionCounts, <SkillRouteDisposition, int>{
      SkillRouteDisposition.noTool: 1,
      SkillRouteDisposition.clarify: 1,
      SkillRouteDisposition.selected: 1,
    });
    expect(
      snapshot.activationOutcomeCounts[SkillActivationOutcome.selected],
      2,
    );
    expect(snapshot.activationOutcomeCounts[SkillActivationOutcome.denied], 1);
    expect(snapshot.activationOutcomeCounts[SkillActivationOutcome.stale], 1);
    expect(snapshot.activationOutcomeCounts[SkillActivationOutcome.error], 1);
    expect(
      snapshot.latencyBucketCounts.reduce((a, b) => a + b),
      snapshot.routingCount,
    );
    expect(
      snapshot.recentRoutes.map((route) => route.routingLatencyMicros),
      <int>[260, 2000000],
    );
  });

  test('retention and exported dimensions stay bounded and privacy safe', () {
    final collector = SkillRoutingMetricsCollector(retainedRouteLimit: 8);
    for (var index = 0; index < 1000; index++) {
      collector.recordRouting(
        _observation(
          latencyMicros: index,
          catalogSize: 10000,
          candidateCount: 0,
          disposition: SkillRouteDisposition.noTool,
        ),
      );
    }

    final snapshot = collector.snapshot();
    final exported = snapshot.toJson();
    expect(snapshot.routingCount, 1000);
    expect(snapshot.recentRoutes, hasLength(8));
    expect(snapshot.recentRoutes.first.routingLatencyMicros, 992);
    expect(snapshot.recentRoutes.last.routingLatencyMicros, 999);
    expect(
      snapshot.dispositionCounts,
      hasLength(SkillRouteDisposition.values.length),
    );
    expect(
      snapshot.activationOutcomeCounts,
      hasLength(SkillActivationOutcome.values.length),
    );
    expect(
      snapshot.latencyBucketCounts,
      hasLength(
        SkillRoutingMetricsCollector.latencyBucketUpperBoundsMicros.length + 1,
      ),
    );
    expect(
      () => snapshot.recentRoutes.add(
        _observation(
          latencyMicros: 1,
          catalogSize: 1,
          candidateCount: 0,
          disposition: SkillRouteDisposition.noTool,
        ),
      ),
      throwsUnsupportedError,
    );

    _expectPrivacySafeExport(exported);
    final encoded = jsonEncode(exported);
    for (final forbidden in <String>[
      'query',
      'prompt_text',
      'skill_id',
      'account',
      'locale',
      'page_scope',
      'timestamp',
    ]) {
      expect(encoded, isNot(contains(forbidden)));
    }
  });

  test('synchronous recording is safe for concurrent async callers', () async {
    final collector = SkillRoutingMetricsCollector(retainedRouteLimit: 0);
    final observation = _observation(
      latencyMicros: 100,
      catalogSize: 10000,
      candidateCount: 0,
      disposition: SkillRouteDisposition.noTool,
    );

    await Future.wait(<Future<void>>[
      for (var index = 0; index < 1000; index++)
        Future<void>(() {
          collector.recordRouting(observation);
          collector.recordActivation(
            SkillActivationOutcome.values[index %
                SkillActivationOutcome.values.length],
          );
        }),
    ]);

    final snapshot = collector.snapshot();
    expect(snapshot.routingCount, 1000);
    expect(snapshot.activationCount, 1000);
    expect(snapshot.recentRoutes, isEmpty);
    for (final outcome in SkillActivationOutcome.values) {
      expect(snapshot.activationOutcomeCounts[outcome], 250);
    }
  });

  test('invalid cross-field metrics fail closed', () {
    expect(
      () => _observation(
        latencyMicros: 1,
        catalogSize: 1,
        candidateCount: 2,
        disposition: SkillRouteDisposition.noTool,
      ),
      throwsArgumentError,
    );
    expect(
      () => _observation(
        latencyMicros: 1,
        catalogSize: 2,
        candidateCount: 1,
        selectedK: 1,
        disposition: SkillRouteDisposition.clarify,
      ),
      throwsArgumentError,
    );
    expect(
      () => _observation(
        latencyMicros: 1,
        catalogSize: 2,
        candidateCount: 1,
        disposition: SkillRouteDisposition.selected,
      ),
      throwsArgumentError,
    );
    expect(
      () => SkillRoutingMetricsCollector(
        retainedRouteLimit: SkillRoutingMetricsCollector.maxRetainedRoutes + 1,
      ),
      throwsRangeError,
    );
  });
}

SkillRoutingObservation _observation({
  required int latencyMicros,
  required int catalogSize,
  required int candidateCount,
  int selectedK = 0,
  int promptCostUnits = 0,
  int promptBytesEstimate = 0,
  required SkillRouteDisposition disposition,
}) => SkillRoutingObservation(
  routingLatency: Duration(microseconds: latencyMicros),
  catalogSize: catalogSize,
  candidateCount: candidateCount,
  selectedK: selectedK,
  promptCostUnits: promptCostUnits,
  promptBytesEstimate: promptBytesEstimate,
  disposition: disposition,
);

void _expectPrivacySafeExport(Object? value) {
  const allowedKeys = <String>{
    'schema_version',
    'routing_count',
    'activation_count',
    'routing_latency_micros',
    'catalog_size',
    'candidate_count',
    'selected_k',
    'prompt_cost_units',
    'prompt_bytes_estimate',
    'dispositions',
    'activation_outcomes',
    'recent_routes',
    'total',
    'max',
    'bucket_upper_bounds',
    'bucket_counts',
    'disposition',
    'noTool',
    'clarify',
    'selected',
    'denied',
    'stale',
    'error',
    'explanation',
    'explanations',
    'reason',
    'reasons',
    'router_disposition',
    'router_dispositions',
    'confidence_band',
    'confidence_bands',
    'margin_band',
    'margin_bands',
    'policy_added_count',
    'page_added_count',
    'policy_added_total',
    'page_added_total',
    'unknown',
    'noLexicalMatch',
    'nonActionContext',
    'insufficientEvidence',
    'lowConfidence',
    'ambiguous',
    'promptBudgetExhausted',
    'belowQuarter',
    'quarterToHalf',
    'halfToThreeQuarters',
    'atLeastThreeQuarters',
  };
  const allowedStringValues = <String>{
    'unknown',
    'noLexicalMatch',
    'nonActionContext',
    'insufficientEvidence',
    'lowConfidence',
    'ambiguous',
    'promptBudgetExhausted',
    'belowQuarter',
    'quarterToHalf',
    'halfToThreeQuarters',
    'atLeastThreeQuarters',
    'noTool',
    'clarify',
    'selected',
    'denied',
    'stale',
    'error',
  };
  if (value is Map) {
    for (final entry in value.entries) {
      expect(entry.key, isA<String>());
      expect(allowedKeys, contains(entry.key));
      _expectPrivacySafeExport(entry.value);
    }
    return;
  }
  if (value is Iterable) {
    for (final item in value) {
      _expectPrivacySafeExport(item);
    }
    return;
  }
  if (value is String) expect(allowedStringValues, contains(value));
  if (value != null) {
    expect(value is num || value is bool || value is String, isTrue);
  }
}
