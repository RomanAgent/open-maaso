import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_service.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_surface_factory.dart';
import 'package:maaso/src/features/companion_activity/domain/activity_points_ledger.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  const factory = CompanionActivitySurfaceFactory();
  final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 3);
  final now = DateTime.utc(2026, 8, 30, 8);

  CompanionActivitySnapshot snapshot({String title = 'Walk together'}) =>
      CompanionActivitySnapshot(
        templates: <ActivityTaskTemplate>[
          ActivityTaskTemplate(
            id: 'template-walk',
            scope: scope,
            title: title,
            cadence: ActivityCadence.daily,
            defaultAwardPoints: 20,
          ),
        ],
        tasks: <ActivityTask>[
          ActivityTask(
            id: 'activity-1',
            templateId: 'template-walk',
            scope: scope,
            cadence: ActivityCadence.daily,
            title: title,
            awardPoints: 20,
            availableAt: now,
            dueAt: now.add(const Duration(hours: 12)),
          ),
        ],
        evidence: const [],
        ledger: ActivityPointsLedger.empty(scope),
      );

  final streak = ActivityStreakSnapshot(
    current: 2,
    longest: 5,
    asOf: ActivityLocalDate(2026, 8, 30),
    completedDates: <ActivityLocalDate>[],
  );

  test('builds a validator-safe offline self-contained surface', () {
    final bundle = factory.build(
      snapshot: snapshot(),
      streak: streak,
      accountId: scope.accountId,
      facadeGeneration: scope.facadeGeneration,
      agentId: 'self',
      generatedAt: now,
    );

    expect(SurfaceProjectValidator.diagnoseForShow(bundle.project), isEmpty);
    expect(bundle.project.js, isEmpty);
    expect(bundle.project.backend['mode'], 'offline_snapshot');
    expect(bundle.project.backend['rewardFulfillment'], 'virtualOnly');
    expect(bundle.project.html, contains('Virtual rewards only'));
    final source = <String>[
      bundle.project.html,
      bundle.project.css,
      bundle.project.js,
      jsonEncode(bundle.project.manifest.toJson()),
    ].join('\n').toLowerCase();
    for (final forbidden in <String>[
      'http://',
      'https://',
      '<iframe',
      '<script',
      '<link',
      '@import',
      'fetch(',
      'xmlhttprequest',
      'websocket',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('escapes task title instead of injecting HTML', () {
    final bundle = factory.build(
      snapshot: snapshot(title: '<img src=x onerror=alert(1)>'),
      streak: streak,
      accountId: scope.accountId,
      facadeGeneration: scope.facadeGeneration,
      agentId: 'self',
      generatedAt: now,
    );

    expect(bundle.project.html, contains('&lt;img'));
    expect(bundle.project.html, isNot(contains('<img')));
  });

  test('surface widget round-trips and persists through DBService', () async {
    final bundle = factory.build(
      snapshot: snapshot(),
      streak: streak,
      accountId: scope.accountId,
      facadeGeneration: scope.facadeGeneration,
      agentId: 'self',
      generatedAt: now,
    );
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'companion_activity_surface.db',
    );

    expect(bundle.widget.kind, 'surface');
    expect(bundle.widget.isSurface, isTrue);
    await database.saveAgentWidget(bundle.widget);
    final restoredWidget = (await database.getAllWidgets()).single;
    final restoredProject = factory.projectFromWidget(restoredWidget);

    expect(restoredWidget.kind, 'surface');
    expect(restoredProject.toJson(), bundle.project.toJson());
    expect(SurfaceProjectValidator.diagnoseForShow(restoredProject), isEmpty);
    await database.close();
  });

  test('rejects non-surface widget restoration', () {
    final widget = AgentWidget(
      agentId: 'self',
      title: 'Wrong kind',
      kind: 'widget',
      spec: const <String, Object?>{},
      createdAt: now,
    );

    expect(() => factory.projectFromWidget(widget), throwsArgumentError);
  });

  test('revalidates persisted surface content before restoration', () {
    final bundle = factory.build(
      snapshot: snapshot(),
      streak: streak,
      accountId: scope.accountId,
      facadeGeneration: scope.facadeGeneration,
      agentId: 'self',
      generatedAt: now,
    );
    final tampered = AgentWidget(
      agentId: bundle.widget.agentId,
      title: bundle.widget.title,
      kind: 'surface',
      spec: <String, Object?>{
        ...bundle.widget.spec,
        'html': '<iframe src="https://example.com"></iframe>',
      },
      createdAt: bundle.widget.createdAt,
    );

    expect(() => factory.projectFromWidget(tampered), throwsStateError);
  });
}
