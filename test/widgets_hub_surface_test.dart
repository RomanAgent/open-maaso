import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:sembast/sembast_memory.dart';

import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/widget_stage_controller.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';

AgentWidget _surfaceWidget({
  bool game = true,
  bool publicWorker = false,
}) => AgentWidget(
  id: 7,
  agentId: 'self',
  title: 'Orbit Surface',
  kind: 'surface',
  spec: {
    'surfaceId': 'surface_7',
    'surfaceKind': 'floatingCanvas',
    'experienceType': game ? 'game' : 'utility',
    'rendering': game || publicWorker ? 'workerCanvas' : 'canvas',
    'html': game || publicWorker ? '' : '<canvas id="orbit"></canvas>',
    'css': game || publicWorker ? '' : '#orbit{width:100%}',
    'js': game || publicWorker
        ? 'Game.define({init(){return {};},update(state){return state;},draw(){return [{type:"clear",color:"#10131a"}];},input(state){return state;}});'
        : 'window.ready=true;',
    'transparent': true,
    'placement': {'x': 0.1, 'y': 0.2, 'width': 0.4, 'height': 0.5},
    'manifest': {
      'actions': [
        {'name': 'pulse', 'schema': <String, Object?>{}},
      ],
    },
    'backend': {
      'collections': ['stars'],
    },
    'revisions': [
      {
        'id': 'rev_1',
        'html': '<canvas id="old"></canvas>',
        'css': '',
        'js': '',
      },
    ],
  },
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
);

Future<DBService> _memoryDatabase() => DBService().init(
  factory: databaseFactoryMemory,
  path: 'widgets_hub_surface_${DateTime.now().microsecondsSinceEpoch}.db',
);

AppCapabilitySnapshotService _surfaceCapabilities(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const {}),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    gameFeedFirstFrameWaiterOverride = null;
  });

  tearDown(() async {
    gameFeedFirstFrameWaiterOverride = null;
    await appServices.reset();
  });

  group('Widgets Hub surfaces', () {
    test('surface items expose generic hub actions', () {
      final actions = surfaceHubActions(_surfaceWidget());

      expect(actions.map((action) => action.kind), [
        SurfaceHubActionKind.open,
        SurfaceHubActionKind.remix,
        SurfaceHubActionKind.duplicate,
        SurfaceHubActionKind.revert,
        SurfaceHubActionKind.share,
        SurfaceHubActionKind.delete,
      ]);
      expect(actions.every((action) => action.enabled), isTrue);
    });

    test('local-only surfaces do not expose public Applet sharing', () {
      final actions = surfaceHubActions(_surfaceWidget(game: false));

      expect(
        actions.map((action) => action.kind),
        isNot(contains(SurfaceHubActionKind.share)),
      );
    });

    test('workerCanvas utility surfaces expose Applet sharing', () {
      final actions = surfaceHubActions(
        _surfaceWidget(game: false, publicWorker: true),
      );

      expect(
        actions.map((action) => action.kind),
        contains(SurfaceHubActionKind.share),
      );
    });

    test('non-surface hub items do not expose surface actions', () {
      final item = AgentWidget(
        id: 3,
        agentId: 'self',
        title: 'Old Item',
        kind: 'widget',
        spec: const {},
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

      expect(surfaceHubActions(item), isEmpty);
    });

    test(
      'presenting a utility on Home rebuilds and shows SurfaceRuntime',
      () async {
        final runtime = appServices.put(SurfaceRuntime());
        final stage = appServices.put(WidgetStageController());
        final item = _surfaceWidget(game: false);

        await presentAgentWidgetOnHome(item);

        expect(stage.active.value, same(item));
        expect(runtime.isVisible.value, isTrue);
        final project = runtime.activeProject.value;
        expect(project, isNotNull);
        expect(project!.id, 'surface_7');
        expect(project.experienceType, SurfaceExperienceType.utility);
        expect(project.title, 'Orbit Surface');
        expect(project.kind, SurfaceKind.floatingCanvas);
        expect(project.rendering, SurfaceRendering.canvas);
        expect(project.html, '<canvas id="orbit"></canvas>');
        expect(project.manifest.validateAction('pulse', {}), isNull);
        expect(project.backend, {
          'collections': ['stars'],
        });
        expect(project.revisions.single.id, 'rev_1');
      },
    );

    test('denied embedded Surface capability performs zero show', () async {
      appServices.put<AppCapabilitySnapshotService>(
        _surfaceCapabilities(AppHostPlatform.web),
      );
      final runtime = appServices.put(_CountingSurfaceRuntime());

      await expectLater(
        runtime.showWithSession(
          surfaceProjectFromWidget(_surfaceWidget(game: false)),
        ),
        throwsA(isA<SurfaceCapabilityUnavailableException>()),
      );

      expect(runtime.showCalls, 0);
      expect(runtime.activeSession, 0);
      expect(runtime.isVisible.value, isFalse);
      expect(runtime.activeProject.value, isNull);
      expect(runtime.document.value, isNull);
    });

    test(
      'Home does not commit a pending Surface after snapshot generation changes',
      () async {
        final snapshots = appServices.put<AppCapabilitySnapshotService>(
          _surfaceCapabilities(AppHostPlatform.macos),
        );
        final runtime = appServices.put(SurfaceRuntime());
        final stage = appServices.put(WidgetStageController());
        final waiter = _BlockingFirstFrameWaiter();
        gameFeedFirstFrameWaiterOverride = waiter;

        final presentation = presentAgentWidgetOnHome(
          _surfaceWidget(game: false, publicWorker: true),
        );
        await waiter.waitStarted.future;
        final pendingSession = runtime.activeSession;

        snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
        waiter.complete();
        await presentation;
        await Future<void>.delayed(Duration.zero);

        expect(pendingSession, greaterThan(0));
        expect(runtime.activeSession, pendingSession);
        expect(runtime.isVisible.value, isFalse);
        expect(runtime.activeProject.value, isNull);
        expect(stage.active.value, isNull);
      },
    );

    testWidgets(
      'Hub does not push a pending Surface after snapshot generation changes',
      (tester) async {
        final snapshots = appServices.put<AppCapabilitySnapshotService>(
          _surfaceCapabilities(AppHostPlatform.macos),
        );
        final waiter = _BlockingFirstFrameWaiter();
        gameFeedFirstFrameWaiterOverride = waiter;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            home: const SizedBox.shrink(),
          ),
        );

        final opening = openAgentWidget(
          _surfaceWidget(game: false, publicWorker: true),
        );
        await tester.pump();
        await waiter.waitStarted.future;
        snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
        waiter.complete();
        await opening;
        await tester.pump();

        expect(rootNavigatorKey.currentState?.canPop(), isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    test('games require an opaque dedicated player instead of Home stage', () {
      expect(shouldPresentAgentWidgetOnHome(_surfaceWidget()), isFalse);
      expect(
        shouldPresentAgentWidgetOnHome(
          _surfaceWidget()
            ..spec['category'] = 'tools'
            ..spec['tags'] = <String>['utility'],
        ),
        isFalse,
      );
      expect(
        shouldPresentAgentWidgetOnHome(_surfaceWidget(game: false)),
        isTrue,
      );
    });

    test(
      'superseded game sessions are never closed by an older owner',
      () async {
        final runtime = appServices.put(SurfaceRuntime());
        final first = surfaceProjectFromWidget(_surfaceWidget());
        final second = SurfaceProject.fromJson(<String, Object?>{
          ...first.toJson(),
          'id': 'surface_other',
          'title': 'Other Surface',
        });

        final firstSession = await runtime.showWithSession(first);
        final secondSession = await runtime.showWithSession(second);
        await runtime.closeIfSession(firstSession);

        expect(secondSession, isNot(firstSession));
        expect(runtime.isVisible.value, isTrue);
        expect(runtime.activeSession, secondSession);
        expect(runtime.activeSurfaceId, 'surface_other');
      },
    );

    test(
      'invalidated lease callback never closes a newer exact session',
      () async {
        final snapshots = appServices.put<AppCapabilitySnapshotService>(
          _surfaceCapabilities(AppHostPlatform.macos),
        );
        final runtime = appServices.put(SurfaceRuntime());
        final first = surfaceProjectFromWidget(_surfaceWidget());
        final second = SurfaceProject.fromJson(<String, Object?>{
          ...first.toJson(),
          'id': 'surface_after_refresh',
          'title': 'After Refresh',
        });

        final firstSession = await runtime.showWithSession(first);
        snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
        final secondSession = await runtime.showWithSession(second);
        await Future<void>.delayed(Duration.zero);

        expect(secondSession, isNot(firstSession));
        expect(runtime.activeSession, secondSession);
        expect(runtime.activeSurfaceId, 'surface_after_refresh');
        expect(runtime.isVisible.value, isTrue);
      },
    );

    test('invalidated Surface lease blocks the next bridge call', () async {
      final snapshots = appServices.put<AppCapabilitySnapshotService>(
        _surfaceCapabilities(AppHostPlatform.macos),
      );
      final runtime = appServices.put(SurfaceRuntime());
      final received = <SurfaceEvent>[];
      final subscription = runtime.onEvent.listen(received.add);

      await runtime.showWithSession(
        surfaceProjectFromWidget(_surfaceWidget(game: false)),
      );
      snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
      runtime.onPageEvent('pulse', const <String, Object?>{});

      expect(
        await runtime.surfaceCall('pulse', const <String, Object?>{}),
        contains('capability unavailable'),
      );
      expect(received, isEmpty);
      await subscription.cancel();
    });

    test('a Surface owned by another scope is never prepared', () async {
      final runtime = appServices.put(SurfaceRuntime());
      final stage = appServices.put(WidgetStageController());
      final item = _surfaceWidget();
      item.spec['appletLocal'] = const <String, Object?>{
        'schemaVersion': 1,
        'scopeKey': 'https://api.example.test|account-a',
      };

      await presentAgentWidgetOnHome(item);

      expect(stage.active.value, isNull);
      expect(runtime.isVisible.value, isFalse);
      expect(runtime.activeProject.value, isNull);
    });

    test(
      'direct Hub open reloads and rejects pending and tombstoned rows',
      () async {
        for (final hiddenSpec in <Map<String, Object?>>[
          const <String, Object?>{appletPresentationPendingKey: true},
          const <String, Object?>{
            'cloudDelete': <String, Object?>{
              'scopeKey': 'device-legacy',
              'clientSurfaceId': 'surface_7',
            },
          },
        ]) {
          final db = await _memoryDatabase();
          appServices.put<DBService>(db);
          final runtime = appServices.put(SurfaceRuntime());
          final stored = _surfaceWidget()
            ..id = null
            ..spec.addAll(hiddenSpec);
          final stale = AgentWidget.fromJson(stored.toJson());
          await db.saveAgentWidget(stored);
          stale.id = stored.id;

          await openAgentWidget(stale);

          expect(runtime.isVisible.value, isFalse, reason: '$hiddenSpec');
          expect(runtime.activeProject.value, isNull, reason: '$hiddenSpec');
          appServices.reset();
          appServices.testMode = true;
        }
      },
    );

    test(
      'direct Home presentation reloads and rejects pending and tombstoned rows',
      () async {
        for (final hiddenSpec in <Map<String, Object?>>[
          const <String, Object?>{appletPresentationPendingKey: true},
          const <String, Object?>{
            'cloudDelete': <String, Object?>{
              'scopeKey': 'device-legacy',
              'clientSurfaceId': 'surface_7',
            },
          },
        ]) {
          final db = await _memoryDatabase();
          appServices.put<DBService>(db);
          final runtime = appServices.put(SurfaceRuntime());
          final stage = appServices.put(WidgetStageController());
          final stored = _surfaceWidget()
            ..id = null
            ..spec.addAll(hiddenSpec);
          final stale = AgentWidget.fromJson(stored.toJson());
          await db.saveAgentWidget(stored);
          stale.id = stored.id;

          await presentAgentWidgetOnHome(stale);

          expect(stage.active.value, isNull, reason: '$hiddenSpec');
          expect(runtime.isVisible.value, isFalse, reason: '$hiddenSpec');
          expect(runtime.activeProject.value, isNull, reason: '$hiddenSpec');
          appServices.reset();
          appServices.testMode = true;
        }
      },
    );

    test(
      'direct presentation trusts the committed DB row over a stale marker',
      () async {
        final db = await _memoryDatabase();
        appServices.put<DBService>(db);
        final runtime = appServices.put(SurfaceRuntime());
        final stage = appServices.put(WidgetStageController());
        final stored = _surfaceWidget(game: false)..id = null;
        await db.saveAgentWidget(stored);
        final stale = AgentWidget.fromJson(stored.toJson(), id: stored.id)
          ..spec[appletPresentationPendingKey] = true;

        await presentAgentWidgetOnHome(stale);

        expect(stage.active.value?.id, stored.id);
        expect(runtime.isVisible.value, isTrue);
        expect(runtime.activeProject.value?.id, 'surface_7');
      },
    );
  });
}

class _CountingSurfaceRuntime extends SurfaceRuntime {
  int showCalls = 0;

  @override
  Future<void> show(SurfaceProject project) async {
    showCalls++;
    await super.show(project);
  }
}

class _BlockingFirstFrameWaiter implements SurfaceWorkerFirstFrameWaiter {
  final Completer<void> waitStarted = Completer<void>();
  final Completer<void> _completion = Completer<void>();

  void complete() {
    if (!_completion.isCompleted) _completion.complete();
  }

  @override
  void beginPresentation({SurfaceRuntime? runtime}) {}

  @override
  void cancelPresentation() {}

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) {
    if (!waitStarted.isCompleted) waitStarted.complete();
    return _completion.future;
  }
}
