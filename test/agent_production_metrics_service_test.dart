import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_production_metrics_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_routing_observability.dart';

void main() {
  test('exports only fixed-cardinality numeric production metrics', () {
    final metrics = AgentProductionMetricsService(retainedRouteLimit: 1);

    metrics
      ..recordColdStart(const Duration(milliseconds: 12))
      ..recordColdStart(const Duration(milliseconds: 99))
      ..recordRuntimeEnsure(
        const Duration(milliseconds: 4),
        AgentRuntimeEnsureOutcome.created,
      )
      ..recordRuntimeEnsure(
        const Duration(milliseconds: 2),
        AgentRuntimeEnsureOutcome.reused,
      )
      ..recordRuntimeEnsure(
        const Duration(milliseconds: 8),
        AgentRuntimeEnsureOutcome.error,
      )
      ..recordFirstResponse(
        const Duration(milliseconds: 30),
        AgentFirstResponseOutcome.success,
      )
      ..recordFirstResponse(
        const Duration(milliseconds: 50),
        AgentFirstResponseOutcome.error,
      );
    metrics.routing
      ..recordRouting(
        SkillRoutingObservation(
          routingLatency: const Duration(microseconds: 350),
          catalogSize: 10000,
          candidateCount: 3,
          selectedK: 2,
          promptCostUnits: 400,
          promptBytesEstimate: 800,
          disposition: SkillRouteDisposition.selected,
        ),
      )
      ..recordActivation(SkillActivationOutcome.selected);

    final snapshot = metrics.snapshot();
    expect(snapshot.coldStart.count, 1);
    expect(snapshot.coldStart.totalMicros, 12000);
    expect(snapshot.runtimeEnsure.count, 3);
    expect(
      snapshot.runtimeEnsureOutcomeCounts,
      <AgentRuntimeEnsureOutcome, int>{
        AgentRuntimeEnsureOutcome.created: 1,
        AgentRuntimeEnsureOutcome.reused: 1,
        AgentRuntimeEnsureOutcome.error: 1,
      },
    );
    expect(snapshot.firstResponse.count, 2);
    expect(
      snapshot.firstResponseOutcomeCounts,
      <AgentFirstResponseOutcome, int>{
        AgentFirstResponseOutcome.success: 1,
        AgentFirstResponseOutcome.error: 1,
      },
    );
    expect(snapshot.routing.routingCount, 1);
    expect(snapshot.routing.activationCount, 1);

    final encoded = jsonEncode(snapshot.toJson());
    for (final forbidden in <String>[
      'user_text',
      'prompt_text',
      'skill_id',
      'agent_id',
      'account',
      'page_scope',
      'locale',
      'timestamp',
    ]) {
      expect(encoded, isNot(contains(forbidden)));
    }
  });

  test('negative durations fail closed', () {
    final metrics = AgentProductionMetricsService();

    expect(
      () => metrics.recordColdStart(const Duration(microseconds: -1)),
      throwsRangeError,
    );
    expect(
      () => metrics.recordRuntimeEnsure(
        const Duration(microseconds: -1),
        AgentRuntimeEnsureOutcome.error,
      ),
      throwsRangeError,
    );
    expect(
      () => metrics.recordFirstResponse(
        const Duration(microseconds: -1),
        AgentFirstResponseOutcome.error,
      ),
      throwsRangeError,
    );
  });
}
