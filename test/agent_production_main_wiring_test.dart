import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/main.dart').readAsStringSync();

  test('metrics and rollout register before account bootstrap IO', () {
    final metrics = source.indexOf(
      'appServices.put(\n    AgentProductionMetricsService()',
    );
    final rollout = source.indexOf(
      'appServices.put(\n    AgentCapabilityRolloutService(',
    );
    final bootstrapStart = source.indexOf(
      'Future<void> _bootstrapApplication(',
    );
    final firstStartupAwait = source.indexOf(
      'await SpUtils.init()',
      bootstrapStart,
    );
    expect(metrics, greaterThan(bootstrapStart));

    expect(metrics, greaterThanOrEqualTo(0));
    expect(rollout, greaterThan(metrics));
    expect(firstStartupAwait, greaterThan(rollout));
    expect(source, contains('requestPublicWrites: false'));
  });

  test('UI control receives the live rollout gate through its coordinator', () {
    expect(source, contains('AgentUiControlService('));
    expect(source, contains('coordinator: AgentUiControlCoordinator('));
    expect(source, contains('isControlEnabled: () =>'));
    expect(
      source,
      contains('capabilityRollout.current.pageAgentControlEnabled'),
    );
    expect(
      source,
      contains('controlEnabledChanges: capabilityRollout.changes.map('),
    );
    expect(source, contains('(rollout) => rollout.pageAgentControlEnabled'));
  });

  test(
    'cold start is captured before heavier post-frame work is scheduled',
    () {
      final firstFrameMetric = source.indexOf(
        'productionMetrics.recordColdStart(coldStartStopwatch.elapsed)',
      );
      final deferredBoot = source.indexOf('_schedulePostFrameBootTasks();');
      final runAppCall = source.indexOf('runApp(', deferredBoot);

      expect(firstFrameMetric, greaterThanOrEqualTo(0));
      expect(firstFrameMetric, lessThan(deferredBoot));
      expect(deferredBoot, lessThan(runAppCall));
    },
  );
}
