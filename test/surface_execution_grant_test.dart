import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/surface/surface_execution_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_interaction_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test(
    'utility preview does not persist until the user confirms saving',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'utility_confirm.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.utility,
      );
      final surface = SurfaceRuntime();
      final decision = Completer<bool>();
      final preview = Completer<SurfaceProject>();
      final receipts = <SurfacePresentationReceipt>[];
      final result = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        skillManager: authorization.manager,
        surfaceRuntime: surface,
        surfaceExecutionGrant: authorization.surfaceGrant,
        expectedAppletScopeKey: scopeKey,
        onSurfacePresented: receipts.add,
        confirmAppletSave: (project) {
          preview.complete(project);
          return decision.future;
        },
        speak: (_) async {},
      ).execute(_surfaceEnvelope(SurfaceExperienceType.utility));
      final project = await preview.future;
      expect(surface.isVisible.value, isTrue);
      expect(project.category, 'tools');
      expect(project.skillInstructions, isNotEmpty);
      expect(await db.getAllWidgets(), isEmpty);
      expect(receipts, isEmpty);
      decision.complete(true);
      expect((await result).ok, isTrue);
      final saved = (await db.getAllWidgets()).single;
      expect(saved.spec['category'], 'tools');
      expect(saved.spec['skillInstructions'], project.skillInstructions);
      expect(receipts.single.widgetId, saved.id);
    },
  );

  test(
    'declining preview leaves no saved applet or completion receipt',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'utility_decline.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.utility,
      );
      final surface = SurfaceRuntime();
      var declined = false;
      final receipts = <SurfacePresentationReceipt>[];
      final result = await AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        skillManager: authorization.manager,
        surfaceRuntime: surface,
        surfaceExecutionGrant: authorization.surfaceGrant,
        expectedAppletScopeKey: scopeKey,
        confirmAppletSave: (_) async => false,
        onSurfaceSaveDeclined: () => declined = true,
        onSurfacePresented: receipts.add,
        speak: (_) async {},
      ).execute(_surfaceEnvelope(SurfaceExperienceType.utility));
      expect(result.ok, isTrue);
      expect(declined, isTrue);
      expect(surface.isVisible.value, isFalse);
      expect(await db.getAllWidgets(), isEmpty);
      expect(receipts, isEmpty);
    },
  );

  test('confirmation cannot save a closed or replaced preview', () async {
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'utility_stale_preview.db',
    );
    appServices.put<DBService>(db);
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final surface = SurfaceRuntime();
    final result = await AgentActionExecutor(
      agentId: 'self',
      locale: AppLocale.en,
      skillManager: authorization.manager,
      surfaceRuntime: surface,
      surfaceExecutionGrant: authorization.surfaceGrant,
      expectedAppletScopeKey: scopeKey,
      confirmAppletSave: (_) async {
        await surface.close();
        return true;
      },
      speak: (_) async {},
    ).execute(_surfaceEnvelope(SurfaceExperienceType.utility));
    expect(result.ok, isFalse);
    expect(await db.getAllWidgets(), isEmpty);
  });

  test(
    'surface.show is denied by default without touching the runtime',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'surface_denied_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final surface = SurfaceRuntime();
      final result = await AgentActionExecutor(
        confirmAppletSave: (_) async => true,
        agentId: 'self',
        locale: AppLocale.en,
        skillManager: SkillManager(),
        surfaceRuntime: surface,
        speak: (_) async {},
      ).execute(_surfaceEnvelope(SurfaceExperienceType.utility));

      expect(result.ok, isFalse);
      expect(result.errors.single, contains('surface_not_granted'));
      expect(surface.isVisible.value, isFalse);
      expect(surface.activeProject.value, isNull);
      expect(await db.getAllWidgets(), isEmpty);
    },
  );

  test(
    'exact host, agent, scope and experience grant permits one show',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'surface_receipt_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final surface = SurfaceRuntime();
      final receipts = <SurfacePresentationReceipt>[];
      final executor = AgentActionExecutor(
        confirmAppletSave: (_) async => true,
        agentId: 'self',
        locale: AppLocale.en,
        skillManager: authorization.manager,
        surfaceRuntime: surface,
        surfaceExecutionGrant: authorization.surfaceGrant,
        expectedAppletScopeKey: scopeKey,
        onSurfacePresented: receipts.add,
        speak: (_) async {},
      );

      final result = await executor.execute(
        _surfaceEnvelope(SurfaceExperienceType.game),
      );

      expect(result.errors, isEmpty);
      expect(surface.isVisible.value, isTrue);
      expect(
        surface.activeProject.value?.experienceType,
        SurfaceExperienceType.game,
      );
      expect(receipts, hasLength(1));
      expect(receipts.single.surfaceId, surface.activeProject.value?.id);
      expect(receipts.single.widgetId, isNotNull);
      expect(receipts.single.agentId, 'self');
      expect(receipts.single.appletScopeKey, scopeKey);
      expect(await db.getAllWidgets(), hasLength(1));
    },
  );

  test(
    'worker presentation waits for the first-frame seam before persisting',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'surface_nested_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final waiter = _RecordingFirstFrameWaiter();
      final receipts = <SurfacePresentationReceipt>[];

      final result =
          await AgentActionExecutor(
            confirmAppletSave: (_) async => true,
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: SurfaceRuntime(),
            surfaceExecutionGrant: authorization.surfaceGrant,
            expectedAppletScopeKey: scopeKey,
            surfaceWorkerFirstFrameWaiter: waiter,
            onSurfacePresented: receipts.add,
            speak: (_) async {},
          ).execute(
            _surfaceEnvelope(
              SurfaceExperienceType.game,
              workerSource:
                  "Game.define({init(){return {};},update(s){return s;},draw(){const board=[{type:'clear',color:'#000'}];return [board];},input(s){return s;}});",
            ),
          );

      expect(result.ok, isTrue);
      expect(waiter.sessions, hasLength(1));
      expect(receipts, hasLength(1));
      expect(await db.getAllWidgets(), hasLength(1));
    },
  );

  test(
    'webApp game waits for first frame before committing persistence',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'surface_web_app_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final lifecycle = <String>[];
      final cloud = _RecordingInitialSyncCloudService(
        database: db,
        lifecycle: lifecycle,
      );
      appServices.put<AgentGameCloudService>(cloud);
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final waiter = _OrderingFirstFrameWaiter(lifecycle);
      final receipts = <SurfacePresentationReceipt>[];

      final result =
          await AgentActionExecutor(
            confirmAppletSave: (_) async => true,
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: SurfaceRuntime(),
            surfaceExecutionGrant: authorization.surfaceGrant,
            expectedAppletScopeKey: scopeKey,
            surfaceWorkerFirstFrameWaiter: waiter,
            onSurfacePresented: receipts.add,
            speak: (_) async {},
          ).execute(
            _surfaceEnvelope(
              SurfaceExperienceType.game,
              rendering: SurfaceRendering.webApp,
              html: '<main><button id="play">Play</button></main>',
              js: 'document.querySelector("#play").onclick = () => {};',
            ),
          );

      expect(result.ok, isTrue);
      expect(cloud.syncCalls, 1);
      expect(waiter.sessions, hasLength(1));
      expect(lifecycle, <String>['sync', 'first-frame']);
      expect(receipts, hasLength(1));
      final stored = (await db.getAllWidgets()).single;
      expect(stored.spec['rendering'], SurfaceRendering.webApp.name);
      expect(isAppletPresentationPending(stored), isFalse);
    },
  );

  test(
    'webApp timeout compensates both candidates after one source repair',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path:
            'surface_web_app_timeout_'
            '${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final lifecycle = <String>[];
      final cloud = _RecordingInitialSyncCloudService(
        database: db,
        lifecycle: lifecycle,
      );
      appServices.put<AgentGameCloudService>(cloud);
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final surface = SurfaceRuntime();
      final receipts = <SurfacePresentationReceipt>[];
      var repairCalls = 0;

      final result =
          await AgentActionExecutor(
            confirmAppletSave: (_) async => true,
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: surface,
            surfaceExecutionGrant: authorization.surfaceGrant,
            expectedAppletScopeKey: scopeKey,
            surfaceWorkerFirstFrameWaiter: _OrderingFirstFrameWaiter(
              lifecycle,
              error: const SurfaceWorkerFirstFrameException.timeout(),
            ),
            onSurfacePresented: receipts.add,
            speak: (_) async {},
          ).execute(
            _surfaceEnvelope(
              SurfaceExperienceType.game,
              rendering: SurfaceRendering.webApp,
              html: '<main><button>Play</button></main>',
              js: 'document.querySelector("button").onclick = () => {};',
            ),
            surfaceWorkerRepair: (original, reason) async {
              repairCalls++;
              return original;
            },
          );

      expect(result.ok, isFalse);
      expect(result.errors.single, contains('first_frame_timeout'));
      expect(cloud.syncCalls, 2);
      expect(cloud.compensationCalls, 2);
      expect(lifecycle, <String>[
        'sync',
        'first-frame',
        'compensate',
        'sync',
        'first-frame',
        'compensate',
      ]);
      expect(repairCalls, 1);
      expect(receipts, isEmpty);
      expect(await db.getAllWidgets(), isEmpty);
      expect(surface.isVisible.value, isFalse);
    },
  );

  test(
    'primitive first-frame draw is compensated without receipt or event',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'surface_primitive_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final surface = SurfaceRuntime();
      final receipts = <SurfacePresentationReceipt>[];
      var widgetCreatedEvents = 0;
      final subscription = EventBus().on<WidgetCreatedEvent>().listen((_) {
        widgetCreatedEvents++;
      });
      addTearDown(subscription.cancel);

      final result =
          await AgentActionExecutor(
            confirmAppletSave: (_) async => true,
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: surface,
            surfaceExecutionGrant: authorization.surfaceGrant,
            expectedAppletScopeKey: scopeKey,
            surfaceWorkerFirstFrameWaiter: _RecordingFirstFrameWaiter(
              error: const SurfaceWorkerFirstFrameException.fatal(
                SurfaceWorkerFatalReason.invalidDrawCommands,
              ),
            ),
            onSurfacePresented: receipts.add,
            speak: (_) async {},
          ).execute(
            _surfaceEnvelope(
              SurfaceExperienceType.game,
              workerSource:
                  "Game.define({init(){return {};},update(s){return s;},draw(){return [null];},input(s){return s;}});",
            ),
          );
      await Future<void>.delayed(Duration.zero);

      expect(result.ok, isFalse);
      expect(result.errors.single, contains('invalid_draw_commands'));
      expect(receipts, isEmpty);
      expect(widgetCreatedEvents, 0);
      expect(await db.getAllWidgets(), isEmpty);
      expect(surface.isVisible.value, isFalse);
    },
  );

  test(
    'first-frame repair retries only the Surface action and consumes one grant',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'surface_repair_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final waiter = _RecordingFirstFrameWaiter(
        errorSequence: <Object?>[
          const SurfaceWorkerFirstFrameException.fatal(
            SurfaceWorkerFatalReason.invalidDrawCommands,
          ),
          null,
        ],
      );
      final receipts = <SurfacePresentationReceipt>[];
      final emotionEvents = <String>[];
      var widgetCreatedEvents = 0;
      final subscription = EventBus().on<EmotionStateEvent>().listen((event) {
        if (event.agentId == 'self' && event.semanticLabel != null) {
          emotionEvents.add(event.semanticLabel!);
        }
      });
      final widgetSubscription = EventBus().on<WidgetCreatedEvent>().listen((
        _,
      ) {
        widgetCreatedEvents++;
      });
      addTearDown(subscription.cancel);
      addTearDown(widgetSubscription.cancel);
      final surfaceAction = _surfaceEnvelope(
        SurfaceExperienceType.game,
      ).actions.single;
      final spoken = <String>[];
      final envelope = AgentActionEnvelope(
        reply: '',
        actions: <AgentAction>[
          const AgentAction(
            type: 'emotion.set',
            data: <String, Object?>{'type': 'emotion.set', 'emotion': 'happy'},
          ),
          surfaceAction,
          const AgentAction(
            type: 'emotion.set',
            data: <String, Object?>{'type': 'emotion.set', 'emotion': 'calm'},
          ),
          const AgentAction(
            type: 'voice.speak',
            data: <String, Object?>{
              'type': 'voice.speak',
              'text': 'game ready',
            },
          ),
        ],
      );
      var repairCalls = 0;

      final result =
          await AgentActionExecutor(
            confirmAppletSave: (_) async => true,
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: SurfaceRuntime(),
            surfaceExecutionGrant: authorization.surfaceGrant,
            expectedAppletScopeKey: scopeKey,
            surfaceWorkerFirstFrameWaiter: waiter,
            onSurfacePresented: receipts.add,
            speak: (line) async => spoken.add(line),
          ).execute(
            envelope,
            surfaceWorkerRepair: (original, reason) async {
              repairCalls++;
              expect(
                reason.reason,
                SurfaceWorkerFatalReason.invalidDrawCommands,
              );
              return original;
            },
          );

      expect(result.ok, isTrue);
      expect(repairCalls, 1);
      expect(waiter.sessions, hasLength(2));
      expect(emotionEvents, <String>['happy', 'calm']);
      expect(spoken, <String>['game ready']);
      expect(receipts, hasLength(1));
      expect(widgetCreatedEvents, 1);
      expect(await db.getAllWidgets(), hasLength(1));
    },
  );

  for (final repeated in [false, true]) {
    test(
      'host repeated startup repair $repeated keeps one consumed grant and one receipt',
      () async {
        final db = await DBService().init(
          factory: databaseFactoryMemory,
          path: 'repeated_surface_repair_$repeated.db',
        );
        appServices.put<DBService>(db);
        final scopeKey = AppletLocalOwnership.currentScopeKey();
        final authorization = _authorization(
          agentId: 'self',
          scopeKey: scopeKey,
          experienceType: SurfaceExperienceType.game,
        );
        final waiter = _RecordingFirstFrameWaiter(
          errorSequence: [
            const SurfaceWorkerFirstFrameException.fatal(
              SurfaceWorkerFatalReason.runtimeFailed,
            ),
            const SurfaceWorkerFirstFrameException.fatal(
              SurfaceWorkerFatalReason.runtimeFailed,
            ),
            null,
          ],
        );
        final surface = SurfaceRuntime();
        final receipts = <SurfacePresentationReceipt>[];
        final spoken = <String>[];
        var repairs = 0;
        final envelope = _surfaceEnvelope(
          SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html:
              '<main><canvas id="game"></canvas><button id="start">Start</button></main>',
          js: 'document.querySelector("#game");',
        );
        final withVoice = AgentActionEnvelope(
          reply: '',
          actions: [
            ...envelope.actions,
            const AgentAction(
              type: 'voice.speak',
              data: {'text': 'ready once'},
            ),
          ],
        );
        final result =
            await AgentActionExecutor(
              agentId: 'self',
              locale: AppLocale.en,
              skillManager: authorization.manager,
              surfaceRuntime: surface,
              surfaceWorkerFirstFrameWaiter: waiter,
              surfaceExecutionGrant: authorization.surfaceGrant,
              expectedAppletScopeKey: scopeKey,
              allowRepeatedSurfaceWorkerRepair: repeated,
              onSurfacePresented: receipts.add,
              speak: (line) async => spoken.add(line),
            ).execute(
              withVoice,
              surfaceWorkerRepair: (original, reason) async {
                repairs++;
                expect(reason.reason, SurfaceWorkerFatalReason.runtimeFailed);
                return original;
              },
            );
        expect(result.ok, repeated);
        expect(repairs, repeated ? 2 : 1);
        expect(waiter.sessions, hasLength(repeated ? 3 : 2));
        expect(waiter.cancelCalls, 2);
        expect(receipts, hasLength(repeated ? 1 : 0));
        expect(await db.getAllWidgets(), hasLength(repeated ? 1 : 0));
        expect(spoken, repeated ? ['ready once'] : isEmpty);
        expect(authorization.surfaceGrant.isCurrent, isFalse);
        expect(authorization.surfaceGrant.authorityIsCurrent, isTrue);
        final replay = await AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          surfaceRuntime: surface,
          surfaceExecutionGrant: authorization.surfaceGrant,
          expectedAppletScopeKey: scopeKey,
          speak: (_) async {},
        ).execute(envelope);
        expect(replay.ok, isFalse);
        expect(replay.errors.single, contains('surface_not_granted'));
        expect(waiter.sessions, hasLength(repeated ? 3 : 2));
      },
    );
  }

  for (final interruption in ['cancel', 'host-revoke']) {
    test(
      'repeated repair still stops at $interruption after complete compensation',
      () async {
        final db = await DBService().init(
          factory: databaseFactoryMemory,
          path: 'repeated_surface_repair_$interruption.db',
        );
        appServices.put<DBService>(db);
        final scopeKey = AppletLocalOwnership.currentScopeKey();
        final authorization = _authorization(
          agentId: 'self',
          scopeKey: scopeKey,
          experienceType: SurfaceExperienceType.game,
        );
        final waiter = _RecordingFirstFrameWaiter(
          error: const SurfaceWorkerFirstFrameException.fatal(
            SurfaceWorkerFatalReason.runtimeFailed,
          ),
        );
        final surface = SurfaceRuntime();
        final receipts = <SurfacePresentationReceipt>[];
        var cancel = false;
        var repairs = 0;
        var cleanupSettled = 0;
        final result =
            await AgentActionExecutor(
              agentId: 'self',
              locale: AppLocale.en,
              skillManager: authorization.manager,
              surfaceRuntime: surface,
              surfaceWorkerFirstFrameWaiter: waiter,
              surfaceExecutionGrant: authorization.surfaceGrant,
              expectedAppletScopeKey: scopeKey,
              allowRepeatedSurfaceWorkerRepair: true,
              shouldCancel: () => cancel,
              onSurfacePresented: receipts.add,
              onSurfaceCancellationSettled: () => cleanupSettled++,
              speak: (_) async {},
            ).execute(
              _surfaceEnvelope(
                SurfaceExperienceType.game,
                rendering: SurfaceRendering.webApp,
                html: '<main><canvas></canvas></main>',
                js: 'document.querySelector("canvas");',
              ),
              surfaceWorkerRepair: (original, _) async {
                repairs++;
                expect(await db.getAllWidgets(), isEmpty);
                expect(surface.isVisible.value, isFalse);
                if (repairs == 2) {
                  if (interruption == 'cancel') {
                    cancel = true;
                  } else {
                    authorization.registry.reload(const <String>{});
                  }
                }
                return original;
              },
            );
        expect(result.ok, isFalse);
        expect(repairs, 2);
        expect(waiter.sessions, hasLength(2));
        expect(await db.getAllWidgets(), isEmpty);
        expect(receipts, isEmpty);
        expect(surface.isVisible.value, isFalse);
        if (interruption == 'cancel') expect(cleanupSettled, greaterThan(0));
      },
    );
  }

  test(
    'second pending compensation stops repeated repair before a third show',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'repeated_surface_pending_compensation.db',
      );
      appServices.put<DBService>(db);
      final cloud = _SecondPendingCompensationCloudService(
        database: db,
        lifecycle: [],
      );
      appServices.put<AgentGameCloudService>(cloud);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final surface = _CountingSurfaceRuntime();
      final receipts = <SurfacePresentationReceipt>[];
      var repairs = 0;
      final result =
          await AgentActionExecutor(
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: surface,
            surfaceExecutionGrant: authorization.surfaceGrant,
            expectedAppletScopeKey: scopeKey,
            allowRepeatedSurfaceWorkerRepair: true,
            surfaceWorkerFirstFrameWaiter: _RecordingFirstFrameWaiter(
              error: const SurfaceWorkerFirstFrameException.fatal(
                SurfaceWorkerFatalReason.runtimeFailed,
              ),
            ),
            onSurfacePresented: receipts.add,
            speak: (_) async {},
          ).execute(
            _surfaceEnvelope(
              SurfaceExperienceType.game,
              rendering: SurfaceRendering.webApp,
              html: '<main><canvas></canvas></main>',
              js: 'document.querySelector("canvas");',
            ),
            surfaceWorkerRepair: (original, _) async {
              repairs++;
              return original;
            },
          );
      expect(result.ok, isFalse);
      expect(cloud.compensationCalls, 2);
      expect(repairs, 1);
      expect(surface.showCalls, 2);
      expect(surface.isVisible.value, isFalse);
      expect(receipts, isEmpty);
      expect(
        isAppletPresentationPending((await db.getAllWidgets()).single),
        isTrue,
      );
    },
  );

  for (final mismatch in const <String>['experienceType', 'rendering']) {
    test('first-frame repair rejects a changed $mismatch boundary', () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path:
            'surface_repair_${mismatch}_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: mismatch == 'experienceType'
            ? SurfaceExperienceType.game
            : SurfaceExperienceType.utility,
      );
      final original = mismatch == 'experienceType'
          ? _surfaceEnvelope(SurfaceExperienceType.game).actions.single
          : _workerSurfaceAction(SurfaceExperienceType.utility);
      final waiter = _RecordingFirstFrameWaiter(
        error: const SurfaceWorkerFirstFrameException.fatal(
          SurfaceWorkerFatalReason.invalidDrawCommands,
        ),
      );
      final surface = _CountingSurfaceRuntime();
      var repairCalls = 0;

      final result =
          await AgentActionExecutor(
            confirmAppletSave: (_) async => true,
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: surface,
            surfaceExecutionGrant: authorization.surfaceGrant,
            expectedAppletScopeKey: scopeKey,
            surfaceWorkerFirstFrameWaiter: waiter,
            speak: (_) async {},
          ).execute(
            AgentActionEnvelope(reply: '', actions: <AgentAction>[original]),
            surfaceWorkerRepair: (action, _) async {
              repairCalls++;
              return mismatch == 'experienceType'
                  ? _copySurfaceAction(
                      action,
                      experienceType: SurfaceExperienceType.utility,
                    )
                  : _copySurfaceAction(action, rendering: SurfaceRendering.dom);
            },
          );

      expect(result.ok, isFalse);
      expect(repairCalls, 1);
      expect(waiter.sessions, hasLength(1));
      expect(surface.showCalls, 1);
      expect(await db.getAllWidgets(), isEmpty);
      expect(surface.isVisible.value, isFalse);
    });
  }

  test('cleanup failure prevents first-frame repair and a second show', () async {
    final db = _CleanupFailingDatabase();
    await db.init(
      factory: databaseFactoryMemory,
      path:
          'surface_cleanup_failure_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(db);
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.game,
    );
    final surface = _CountingSurfaceRuntime();
    var repairCalls = 0;

    final result =
        await AgentActionExecutor(
          confirmAppletSave: (_) async => true,
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          surfaceRuntime: surface,
          surfaceExecutionGrant: authorization.surfaceGrant,
          expectedAppletScopeKey: scopeKey,
          surfaceWorkerFirstFrameWaiter: _RecordingFirstFrameWaiter(
            error: const SurfaceWorkerFirstFrameException.fatal(
              SurfaceWorkerFatalReason.invalidDrawCommands,
            ),
          ),
          speak: (_) async {},
        ).execute(
          _surfaceEnvelope(SurfaceExperienceType.game),
          surfaceWorkerRepair: (action, _) async {
            repairCalls++;
            return action;
          },
        );

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('surface_cleanup_failed'));
    expect(repairCalls, 0);
    expect(surface.showCalls, 1);
    expect(surface.isVisible.value, isFalse);
    expect(await db.getAllWidgets(), hasLength(1));
  });

  test(
    'pending cloud compensation prevents repair, receipt, event and second show',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path:
            'surface_pending_cleanup_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(db);
      final cloud = _PendingCompensationCloudService(database: db);
      appServices.put<AgentGameCloudService>(cloud);
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final surface = _CountingSurfaceRuntime();
      final receipts = <SurfacePresentationReceipt>[];
      var widgetCreatedEvents = 0;
      final subscription = EventBus().on<WidgetCreatedEvent>().listen((_) {
        widgetCreatedEvents++;
      });
      addTearDown(subscription.cancel);
      var repairCalls = 0;

      final result =
          await AgentActionExecutor(
            confirmAppletSave: (_) async => true,
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: surface,
            surfaceExecutionGrant: authorization.surfaceGrant,
            expectedAppletScopeKey: scopeKey,
            surfaceWorkerFirstFrameWaiter: _RecordingFirstFrameWaiter(
              error: const SurfaceWorkerFirstFrameException.fatal(
                SurfaceWorkerFatalReason.invalidDrawCommands,
              ),
            ),
            onSurfacePresented: receipts.add,
            speak: (_) async {},
          ).execute(
            _surfaceEnvelope(SurfaceExperienceType.game),
            surfaceWorkerRepair: (action, _) async {
              repairCalls++;
              return action;
            },
          );

      expect(result.ok, isFalse);
      expect(cloud.compensationCalls, 1);
      expect(repairCalls, 0);
      expect(surface.showCalls, 1);
      expect(receipts, isEmpty);
      expect(widgetCreatedEvents, 0);
      final pending = (await db.getAllWidgets()).single;
      expect(isAppletPresentationPending(pending), isTrue);
      expect(surface.isVisible.value, isFalse);
    },
  );

  test('ordinary DOM surface never waits for worker first frame', () async {
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'surface_dom_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(db);
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final waiter = _RecordingFirstFrameWaiter(
      error: StateError('ordinary surface must not wait'),
    );

    final result = await AgentActionExecutor(
      confirmAppletSave: (_) async => true,
      agentId: 'self',
      locale: AppLocale.en,
      skillManager: authorization.manager,
      surfaceRuntime: SurfaceRuntime(),
      surfaceExecutionGrant: authorization.surfaceGrant,
      expectedAppletScopeKey: scopeKey,
      surfaceWorkerFirstFrameWaiter: waiter,
      speak: (_) async {},
    ).execute(_surfaceEnvelope(SurfaceExperienceType.utility));

    expect(result.ok, isTrue);
    expect(waiter.sessions, isEmpty);
    expect(await db.getAllWidgets(), hasLength(1));
  });

  test('failed begin never cancels a worker claim owned elsewhere', () async {
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'surface_claim_owner_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(db);
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.game,
    );
    final waiter = _RecordingFirstFrameWaiter(beginError: StateError('busy'));

    final result = await AgentActionExecutor(
      confirmAppletSave: (_) async => true,
      agentId: 'self',
      locale: AppLocale.en,
      skillManager: authorization.manager,
      surfaceRuntime: SurfaceRuntime(),
      surfaceExecutionGrant: authorization.surfaceGrant,
      expectedAppletScopeKey: scopeKey,
      surfaceWorkerFirstFrameWaiter: waiter,
      speak: (_) async {},
    ).execute(_surfaceEnvelope(SurfaceExperienceType.game));

    expect(result.ok, isFalse);
    expect(waiter.cancelCalls, 0);
    expect(waiter.sessions, isEmpty);
    expect(await db.getAllWidgets(), isEmpty);
  });

  test('wrong agent, scope or experience type fails closed', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.game,
    );
    final registered = authorization.manager.findSkill('FreeformSurface');
    expect(
      authorization.surfaceGrant.allows(
        agentId: 'other',
        appletScopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
        registeredSurfaceSkill: registered,
      ),
      isFalse,
    );
    expect(
      authorization.surfaceGrant.allows(
        agentId: 'self',
        appletScopeKey: '$scopeKey-other',
        experienceType: SurfaceExperienceType.game,
        registeredSurfaceSkill: registered,
      ),
      isFalse,
    );
    expect(
      authorization.surfaceGrant.allows(
        agentId: 'self',
        appletScopeKey: scopeKey,
        experienceType: SurfaceExperienceType.utility,
        registeredSurfaceSkill: registered,
      ),
      isFalse,
    );

    final surface = SurfaceRuntime();
    final result = await AgentActionExecutor(
      confirmAppletSave: (_) async => true,
      agentId: 'self',
      locale: AppLocale.en,
      skillManager: authorization.manager,
      surfaceRuntime: surface,
      surfaceExecutionGrant: authorization.surfaceGrant,
      expectedAppletScopeKey: scopeKey,
      speak: (_) async {},
    ).execute(_surfaceEnvelope(SurfaceExperienceType.utility));
    expect(result.ok, isFalse);
    expect(result.errors.single, contains('surface_not_granted'));
    expect(surface.isVisible.value, isFalse);
  });

  test('multiple surface shows are rejected before any side effect', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final surface = SurfaceRuntime();
    final executor = AgentActionExecutor(
      confirmAppletSave: (_) async => true,
      agentId: 'self',
      locale: AppLocale.en,
      skillManager: authorization.manager,
      surfaceRuntime: surface,
      surfaceExecutionGrant: authorization.surfaceGrant,
      expectedAppletScopeKey: scopeKey,
      speak: (_) async {},
    );
    final action = _surfaceEnvelope(
      SurfaceExperienceType.utility,
    ).actions.single;

    final result = await executor.execute(
      AgentActionEnvelope(
        reply: 'done',
        actions: <AgentAction>[action, action],
      ),
    );

    expect(result.observations, isEmpty);
    expect(result.errors, hasLength(1));
    expect(result.errors.single, contains('surface_not_granted'));
    expect(surface.isVisible.value, isFalse);
  });

  test(
    'invalid surface source is rejected before preceding actions run',
    () async {
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.game,
      );
      final surface = SurfaceRuntime();
      final spoken = <String>[];
      final emotions = <EmotionStateEvent>[];
      final receipts = <SurfacePresentationReceipt>[];
      final subscription = EventBus().on<EmotionStateEvent>().listen(
        emotions.add,
      );
      addTearDown(subscription.cancel);
      final validAction = _surfaceEnvelope(
        SurfaceExperienceType.game,
      ).actions.single;
      final invalidSurface =
          Map<String, Object?>.from(validAction['surface']! as Map)
            ..['js'] =
                "Game.define({init(){return {};},update(s){setTimeout(()=>{},1);return s;},draw(){return [];},input(s){return s;}});";
      final executor = AgentActionExecutor(
        confirmAppletSave: (_) async => true,
        agentId: 'self',
        locale: AppLocale.en,
        skillManager: authorization.manager,
        surfaceRuntime: surface,
        surfaceExecutionGrant: authorization.surfaceGrant,
        expectedAppletScopeKey: scopeKey,
        onSurfacePresented: receipts.add,
        speak: spoken.add,
      );

      final result = await executor.execute(
        AgentActionEnvelope(
          reply: 'done',
          actions: <AgentAction>[
            AgentAction(
              type: 'emotion.set',
              data: const <String, Object?>{'emotion': 'happy'},
            ),
            AgentAction(
              type: 'surface.show',
              data: <String, Object?>{'surface': invalidSurface},
            ),
            AgentAction(
              type: 'voice.speak',
              data: const <String, Object?>{'text': 'done'},
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(result.ok, isFalse);
      expect(result.errors.single, contains('declarative Game API'));
      expect(emotions, isEmpty);
      expect(spoken, isEmpty);
      expect(receipts, isEmpty);
      expect(authorization.surfaceGrant.isCurrent, isTrue);
      expect(surface.isVisible.value, isFalse);
    },
  );

  test('one grant cannot be replayed across two executors', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final firstSurface = SurfaceRuntime();
    final secondSurface = SurfaceRuntime();
    AgentActionExecutor executor(SurfaceRuntime surface) => AgentActionExecutor(
      confirmAppletSave: (_) async => true,
      agentId: 'self',
      locale: AppLocale.en,
      skillManager: authorization.manager,
      surfaceRuntime: surface,
      surfaceExecutionGrant: authorization.surfaceGrant,
      expectedAppletScopeKey: scopeKey,
      speak: (_) async {},
    );

    final results = await Future.wait([
      executor(
        firstSurface,
      ).execute(_surfaceEnvelope(SurfaceExperienceType.utility)),
      executor(
        secondSurface,
      ).execute(_surfaceEnvelope(SurfaceExperienceType.utility)),
    ]);

    expect(results.where((result) => result.ok), hasLength(1));
    expect(results.where((result) => !result.ok), hasLength(1));
    expect(
      <bool>[
        firstSurface.isVisible.value,
        secondSurface.isVisible.value,
      ].where((visible) => visible),
      hasLength(1),
    );
  });

  test('skill.call cannot use the FreeformSurface creation channel', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final surface = SurfaceRuntime();
    final tool = SkillManager.nativeToolName(
      authorization.surfaceSkill,
      'showSurface',
    );
    final showAction = _surfaceEnvelope(
      SurfaceExperienceType.utility,
    ).actions.single;
    final result =
        await AgentActionExecutor(
          confirmAppletSave: (_) async => true,
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          surfaceRuntime: surface,
          executableHostGrant: authorization.hostGrant,
          surfaceExecutionGrant: authorization.surfaceGrant,
          expectedAppletScopeKey: scopeKey,
          speak: (_) async {},
        ).execute(
          AgentActionEnvelope(
            reply: 'done',
            actions: <AgentAction>[
              AgentAction(
                type: 'skill.call',
                data: <String, Object?>{
                  'tool': tool,
                  'args': <String, Object?>{
                    'experienceType': SurfaceExperienceType.utility.name,
                  },
                },
              ),
              showAction,
            ],
          ),
        );

    expect(authorization.surfaceSkill.showCalls, 0);
    expect(result.errors, hasLength(1));
    expect(result.errors.single, contains('surface_not_granted'));
    expect(result.observations, isEmpty);
    expect(surface.isVisible.value, isFalse);
  });

  test('legacy reopen project-body creation is rejected preflight', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final tool = SkillManager.nativeToolName(
      authorization.surfaceSkill,
      'reopenSurface',
    );
    final result =
        await AgentActionExecutor(
          confirmAppletSave: (_) async => true,
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          executableHostGrant: authorization.hostGrant,
          expectedAppletScopeKey: scopeKey,
          speak: (_) async {},
        ).execute(
          _skillCallEnvelope(tool, <String, Object?>{
            'title': 'Bypass',
            'html': '<main>bypass</main>',
          }),
        );

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('surface_not_granted'));
    expect(authorization.surfaceSkill.calls['reopenSurface'] ?? 0, 0);
  });

  test(
    'an edit grant permits one call bound to the visible surface id',
    () async {
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.utility,
      );
      const targetId = 'active-surface';
      final surfaceRuntime = SurfaceRuntime();
      await surfaceRuntime.show(_visibleSurface(targetId));
      final interactionGrant = SurfaceInteractionGrant.issue(
        executableHostGrant: authorization.hostGrant,
        agentId: 'self',
        appletScopeKey: scopeKey,
        request: const SurfaceInteractionRequest(
          operation: SurfaceInteractionOperation.edit,
          targetSurfaceId: targetId,
        ),
        surfaceRuntime: surfaceRuntime,
      );
      final tool = SkillManager.nativeToolName(
        authorization.surfaceSkill,
        'editSurface',
      );
      final executor = AgentActionExecutor(
        confirmAppletSave: (_) async => true,
        agentId: 'self',
        locale: AppLocale.en,
        skillManager: authorization.manager,
        surfaceRuntime: surfaceRuntime,
        executableHostGrant: authorization.hostGrant,
        surfaceInteractionGrant: interactionGrant,
        expectedAppletScopeKey: scopeKey,
        speak: (_) async {},
      );

      final result = await executor.execute(
        _skillCallEnvelope(tool, const <String, Object?>{
          'surfaceId': targetId,
          'html': '<main>edited</main>',
        }),
      );

      expect(result.ok, isTrue);
      expect(authorization.surfaceSkill.calls['editSurface'], 1);
    },
  );

  test('an edit grant rejects a different surface id', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final surfaceRuntime = SurfaceRuntime();
    await surfaceRuntime.show(_visibleSurface('active-surface'));
    final interactionGrant = SurfaceInteractionGrant.issue(
      executableHostGrant: authorization.hostGrant,
      agentId: 'self',
      appletScopeKey: scopeKey,
      request: const SurfaceInteractionRequest(
        operation: SurfaceInteractionOperation.edit,
        targetSurfaceId: 'active-surface',
      ),
      surfaceRuntime: surfaceRuntime,
    );
    final tool = SkillManager.nativeToolName(
      authorization.surfaceSkill,
      'editSurface',
    );

    final result =
        await AgentActionExecutor(
          confirmAppletSave: (_) async => true,
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          surfaceRuntime: surfaceRuntime,
          executableHostGrant: authorization.hostGrant,
          surfaceInteractionGrant: interactionGrant,
          expectedAppletScopeKey: scopeKey,
          speak: (_) async {},
        ).execute(
          _skillCallEnvelope(tool, const <String, Object?>{
            'surfaceId': 'other-surface',
            'html': '<main>wrong target</main>',
          }),
        );

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('surface_not_granted'));
    expect(authorization.surfaceSkill.calls['editSurface'] ?? 0, 0);
  });

  test('an edit grant rejects conflicting target aliases', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final surfaceRuntime = SurfaceRuntime();
    await surfaceRuntime.show(_visibleSurface('active-surface'));
    final interactionGrant = SurfaceInteractionGrant.issue(
      executableHostGrant: authorization.hostGrant,
      agentId: 'self',
      appletScopeKey: scopeKey,
      request: const SurfaceInteractionRequest(
        operation: SurfaceInteractionOperation.edit,
        targetSurfaceId: 'active-surface',
      ),
      surfaceRuntime: surfaceRuntime,
    );
    final tool = SkillManager.nativeToolName(
      authorization.surfaceSkill,
      'editSurface',
    );

    final result =
        await AgentActionExecutor(
          confirmAppletSave: (_) async => true,
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          surfaceRuntime: surfaceRuntime,
          executableHostGrant: authorization.hostGrant,
          surfaceInteractionGrant: interactionGrant,
          expectedAppletScopeKey: scopeKey,
          speak: (_) async {},
        ).execute(
          _skillCallEnvelope(tool, const <String, Object?>{
            'surfaceId': 'active-surface',
            'id': 42,
            'html': '<main>wrong persisted target</main>',
          }),
        );

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('surface_not_granted'));
    expect(authorization.surfaceSkill.calls['editSurface'] ?? 0, 0);
  });

  test('an edit grant rejects the legacy id alias without surfaceId', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final surfaceRuntime = SurfaceRuntime();
    await surfaceRuntime.show(_visibleSurface('42'));
    final interactionGrant = SurfaceInteractionGrant.issue(
      executableHostGrant: authorization.hostGrant,
      agentId: 'self',
      appletScopeKey: scopeKey,
      request: const SurfaceInteractionRequest(
        operation: SurfaceInteractionOperation.edit,
        targetSurfaceId: '42',
      ),
      surfaceRuntime: surfaceRuntime,
    );
    final tool = SkillManager.nativeToolName(
      authorization.surfaceSkill,
      'editSurface',
    );

    final result =
        await AgentActionExecutor(
          confirmAppletSave: (_) async => true,
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          surfaceRuntime: surfaceRuntime,
          executableHostGrant: authorization.hostGrant,
          surfaceInteractionGrant: interactionGrant,
          expectedAppletScopeKey: scopeKey,
          speak: (_) async {},
        ).execute(
          _skillCallEnvelope(tool, const <String, Object?>{
            'id': 42,
            'html': '<main>ambiguous persisted target</main>',
          }),
        );

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('surface_not_granted'));
    expect(authorization.surfaceSkill.calls['editSurface'] ?? 0, 0);
  });

  test(
    'closing or switching the visible surface revokes an edit grant',
    () async {
      for (final replacementId in <String?>[null, 'replacement-surface']) {
        final scopeKey = AppletLocalOwnership.currentScopeKey();
        final authorization = _authorization(
          agentId: 'self',
          scopeKey: scopeKey,
          experienceType: SurfaceExperienceType.utility,
        );
        final surfaceRuntime = SurfaceRuntime();
        await surfaceRuntime.show(_visibleSurface('active-surface'));
        final interactionGrant = SurfaceInteractionGrant.issue(
          executableHostGrant: authorization.hostGrant,
          agentId: 'self',
          appletScopeKey: scopeKey,
          request: const SurfaceInteractionRequest(
            operation: SurfaceInteractionOperation.edit,
            targetSurfaceId: 'active-surface',
          ),
          surfaceRuntime: surfaceRuntime,
        );
        if (replacementId == null) {
          await surfaceRuntime.close();
        } else {
          await surfaceRuntime.show(_visibleSurface(replacementId));
        }
        final tool = SkillManager.nativeToolName(
          authorization.surfaceSkill,
          'editSurface',
        );

        final result =
            await AgentActionExecutor(
              confirmAppletSave: (_) async => true,
              agentId: 'self',
              locale: AppLocale.en,
              skillManager: authorization.manager,
              surfaceRuntime: surfaceRuntime,
              executableHostGrant: authorization.hostGrant,
              surfaceInteractionGrant: interactionGrant,
              expectedAppletScopeKey: scopeKey,
              speak: (_) async {},
            ).execute(
              _skillCallEnvelope(tool, const <String, Object?>{
                'surfaceId': 'active-surface',
                'html': '<main>stale edit</main>',
              }),
            );

        expect(result.ok, isFalse, reason: 'replacement=$replacementId');
        expect(result.errors.single, contains('surface_not_granted'));
        expect(authorization.surfaceSkill.calls['editSurface'] ?? 0, 0);
      }
    },
  );

  test('a takeover during an async edit invalidates its checkpoint', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
      editBarrier: () async {
        entered.complete();
        await release.future;
        SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
      },
    );
    final surfaceRuntime = SurfaceRuntime();
    await surfaceRuntime.show(_visibleSurface('active-surface'));
    final interactionGrant = SurfaceInteractionGrant.issue(
      executableHostGrant: authorization.hostGrant,
      agentId: 'self',
      appletScopeKey: scopeKey,
      request: const SurfaceInteractionRequest(
        operation: SurfaceInteractionOperation.edit,
        targetSurfaceId: 'active-surface',
      ),
      surfaceRuntime: surfaceRuntime,
    );
    final tool = SkillManager.nativeToolName(
      authorization.surfaceSkill,
      'editSurface',
    );
    final execution =
        AgentActionExecutor(
          confirmAppletSave: (_) async => true,
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          surfaceRuntime: surfaceRuntime,
          executableHostGrant: authorization.hostGrant,
          surfaceInteractionGrant: interactionGrant,
          expectedAppletScopeKey: scopeKey,
          speak: (_) async {},
        ).execute(
          _skillCallEnvelope(tool, const <String, Object?>{
            'surfaceId': 'active-surface',
            'html': '<main>stale async edit</main>',
          }),
        );

    await entered.future;
    await surfaceRuntime.close();
    release.complete();
    final result = await execution;

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('surface_not_granted'));
  });

  test(
    'a host reload during an async edit invalidates its checkpoint',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final authorization = _authorization(
        agentId: 'self',
        scopeKey: scopeKey,
        experienceType: SurfaceExperienceType.utility,
        editBarrier: () async {
          entered.complete();
          await release.future;
          SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
        },
      );
      final surfaceRuntime = SurfaceRuntime();
      await surfaceRuntime.show(_visibleSurface('active-surface'));
      final interactionGrant = SurfaceInteractionGrant.issue(
        executableHostGrant: authorization.hostGrant,
        agentId: 'self',
        appletScopeKey: scopeKey,
        request: const SurfaceInteractionRequest(
          operation: SurfaceInteractionOperation.edit,
          targetSurfaceId: 'active-surface',
        ),
        surfaceRuntime: surfaceRuntime,
      );
      final tool = SkillManager.nativeToolName(
        authorization.surfaceSkill,
        'editSurface',
      );
      final execution =
          AgentActionExecutor(
            confirmAppletSave: (_) async => true,
            agentId: 'self',
            locale: AppLocale.en,
            skillManager: authorization.manager,
            surfaceRuntime: surfaceRuntime,
            executableHostGrant: authorization.hostGrant,
            surfaceInteractionGrant: interactionGrant,
            expectedAppletScopeKey: scopeKey,
            speak: (_) async {},
          ).execute(
            _skillCallEnvelope(tool, const <String, Object?>{
              'surfaceId': 'active-surface',
              'html': '<main>stale async edit</main>',
            }),
          );

      await entered.future;
      authorization.registry.reload(const <String>{});
      release.complete();
      final result = await execution;

      expect(result.ok, isFalse);
      expect(result.errors.single, contains('surface_not_granted'));
    },
  );

  test('list requests cannot mint model execution authority', () {
    expect(
      SurfaceInteractionAuthority.resolve(
        text: 'list my surfaces',
        activeSurfaceId: '',
      ),
      isNull,
    );
  });

  test('a host reload revokes an already issued surface grant', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    authorization.registry.reload(const <String>{});
    final surface = SurfaceRuntime();

    final result = await AgentActionExecutor(
      confirmAppletSave: (_) async => true,
      agentId: 'self',
      locale: AppLocale.en,
      skillManager: authorization.manager,
      surfaceRuntime: surface,
      surfaceExecutionGrant: authorization.surfaceGrant,
      expectedAppletScopeKey: scopeKey,
      speak: (_) async {},
    ).execute(_surfaceEnvelope(SurfaceExperienceType.utility));

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('surface_not_granted'));
    expect(surface.isVisible.value, isFalse);
  });

  test('a Freeform handler error fails the structured action', () async {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final authorization = _authorization(
      agentId: 'self',
      scopeKey: scopeKey,
      experienceType: SurfaceExperienceType.utility,
    );
    final surfaceRuntime = SurfaceRuntime();
    await surfaceRuntime.show(_visibleSurface('active-surface'));
    authorization.surfaceSkill.results['revertSurface'] =
        '{"error":"revision_not_found"}';
    final interactionGrant = SurfaceInteractionGrant.issue(
      executableHostGrant: authorization.hostGrant,
      agentId: 'self',
      appletScopeKey: scopeKey,
      request: const SurfaceInteractionRequest(
        operation: SurfaceInteractionOperation.revert,
        targetSurfaceId: 'active-surface',
      ),
      surfaceRuntime: surfaceRuntime,
    );
    final tool = SkillManager.nativeToolName(
      authorization.surfaceSkill,
      'revertSurface',
    );
    final spoken = <String>[];

    final result =
        await AgentActionExecutor(
          confirmAppletSave: (_) async => true,
          agentId: 'self',
          locale: AppLocale.en,
          skillManager: authorization.manager,
          surfaceRuntime: surfaceRuntime,
          executableHostGrant: authorization.hostGrant,
          surfaceInteractionGrant: interactionGrant,
          expectedAppletScopeKey: scopeKey,
          speak: spoken.add,
        ).execute(
          AgentActionEnvelope(
            reply: 'The surface was restored.',
            actions: <AgentAction>[
              AgentAction(
                type: 'voice.speak',
                data: const <String, Object?>{
                  'text': 'The surface was restored.',
                },
              ),
              AgentAction(
                type: 'skill.call',
                data: <String, Object?>{
                  'tool': tool,
                  'args': const <String, Object?>{
                    'surfaceId': 'active-surface',
                  },
                },
              ),
            ],
          ),
        );

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('revision_not_found'));
    expect(spoken, isEmpty);
  });
}

({
  LazyHostSkillRegistry registry,
  SkillManager manager,
  ExecutableHostGrant hostGrant,
  SurfaceExecutionGrant surfaceGrant,
  _SurfaceHostSkill surfaceSkill,
})
_authorization({
  required String agentId,
  required String scopeKey,
  required SurfaceExperienceType experienceType,
  Future<void> Function()? editBarrier,
}) {
  final registry = LazyHostSkillRegistry(
    agentId: agentId,
    specs: <SkillSpec>[
      SkillSpec(
        id: 'freeform_surface',
        name: 'surface',
        description: 'surface',
        icon: Icons.layers_rounded,
        color: Colors.blue,
        category: SkillCategory.expression,
        factory: (_) => _SurfaceHostSkill(editBarrier: editBarrier),
        hostRouting: HostSkillRoutingManifest(
          skillName: 'FreeformSurface',
          summary: 'Creates one explicitly requested surface.',
          methods: <String>[
            'showSurface',
            'editSurface',
            'listSurfaces',
            'reopenSurface',
            'revertSurface',
          ],
          terms: <String>['surface'],
        ),
      ),
    ],
  );
  final descriptor = registry.descriptorFor('FreeformSurface')!;
  final hostGrant = registry.issueGrant(
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[descriptor],
      maxSkills: 1,
      promptBudget: 4096,
    ),
  );
  final surfaceSkill = hostGrant.activatedSkills.single as _SurfaceHostSkill;
  final manager = SkillManager()..registerSkill(surfaceSkill);
  return (
    registry: registry,
    manager: manager,
    hostGrant: hostGrant,
    surfaceGrant: SurfaceExecutionGrant.issue(
      executableHostGrant: hostGrant,
      agentId: agentId,
      appletScopeKey: scopeKey,
      experienceType: experienceType,
    ),
    surfaceSkill: surfaceSkill,
  );
}

AgentActionEnvelope _surfaceEnvelope(
  SurfaceExperienceType experienceType, {
  String? workerSource,
  SurfaceRendering? rendering,
  String? html,
  String? js,
}) => AgentActionEnvelope(
  reply: 'done',
  actions: <AgentAction>[
    AgentAction(
      type: 'surface.show',
      data: <String, Object?>{
        'surface': <String, Object?>{
          'title': 'Granted Surface',
          'experienceType': experienceType.name,
          'kind': 'fullscreen',
          'rendering':
              rendering?.name ??
              (experienceType == SurfaceExperienceType.game
                  ? 'workerCanvas'
                  : 'dom'),
          'html':
              html ??
              (experienceType == SurfaceExperienceType.game
                  ? ''
                  : '<main>ready</main>'),
          'css': '',
          'js':
              js ??
              (experienceType == SurfaceExperienceType.game
                  ? workerSource ??
                        "Game.define({init(){return {};},update(s){return s;},draw(){return [{type:'clear',color:'#000'}];},input(s){return s;}});"
                  : ''),
          'manifest': const <String, Object?>{
            'events': <Object?>[],
            'actions': <Object?>[],
          },
        },
      },
    ),
  ],
);

AgentAction _workerSurfaceAction(SurfaceExperienceType experienceType) =>
    _copySurfaceAction(
      _surfaceEnvelope(SurfaceExperienceType.game).actions.single,
      experienceType: experienceType,
    );

AgentAction _copySurfaceAction(
  AgentAction action, {
  SurfaceExperienceType? experienceType,
  SurfaceRendering? rendering,
}) {
  final data = Map<String, Object?>.from(action.data);
  final surface = Map<String, Object?>.from(data['surface']! as Map);
  if (experienceType != null) {
    surface['experienceType'] = experienceType.name;
  }
  if (rendering != null) {
    surface['rendering'] = rendering.name;
    if (rendering == SurfaceRendering.dom) {
      surface['html'] = '<main>ready</main>';
      surface['css'] = '';
      surface['js'] = '';
    }
  }
  data['surface'] = surface;
  return AgentAction(type: action.type, data: data);
}

class _CountingSurfaceRuntime extends SurfaceRuntime {
  int showCalls = 0;

  @override
  Future<void> show(SurfaceProject project) async {
    showCalls++;
    await super.show(project);
  }
}

class _CleanupFailingDatabase extends DBService {
  @override
  Future<void> deleteWidgetValidated(
    int id, {
    required bool Function(AgentWidget current) validate,
  }) async {
    throw StateError('synthetic_cleanup_failure');
  }
}

class _PendingCompensationCloudService extends AgentGameCloudService {
  _PendingCompensationCloudService({required DBService database})
    : super(
        database: database,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token',
        accountScope: () => AppletLocalOwnership.deviceLegacyScope,
      );

  int compensationCalls = 0;

  @override
  Future<void> schedulePrivateSync(AgentWidget widget) async {}

  @override
  Future<AgentGameCompensationStatus> compensateUnpresented(
    AgentWidget widget, {
    required String expectedScopeKey,
  }) async {
    compensationCalls++;
    return AgentGameCompensationStatus.pending;
  }
}

class _RecordingInitialSyncCloudService extends AgentGameCloudService {
  _RecordingInitialSyncCloudService({
    required DBService database,
    required this.lifecycle,
  }) : _database = database,
       super(
         database: database,
         httpClient: MockClient((_) async => http.Response('{}', 200)),
         baseUri: () => Uri.parse('https://api.example.test/'),
         accessToken: () async => 'token',
         accountScope: () => AppletLocalOwnership.deviceLegacyScope,
       );

  final DBService _database;
  final List<String> lifecycle;
  int syncCalls = 0;
  int compensationCalls = 0;

  @override
  Future<void> schedulePrivateSync(AgentWidget widget) {
    syncCalls++;
    lifecycle.add('sync');
    return Future<void>.value();
  }

  @override
  Future<AgentGameCloudMetadata> syncNewBeforePresent(
    AgentWidget widget,
  ) async {
    syncCalls++;
    lifecycle.add('sync');
    return AgentGameCloudMetadata(
      gameId: 'web-app-cloud-id',
      revisionNo: 1,
      sourceSha256: List<String>.filled(64, 'a').join(),
      syncState: AgentGameSyncState.synced,
      scopeKey: AppletLocalOwnership.deviceLegacyScope,
    );
  }

  @override
  Future<AgentGameCompensationStatus> compensateUnpresented(
    AgentWidget widget, {
    required String expectedScopeKey,
  }) async {
    compensationCalls++;
    lifecycle.add('compensate');
    final widgetId = widget.id;
    if (widgetId != null) {
      await _database.deleteWidgetValidated(
        widgetId,
        validate: (current) =>
            current.agentId == widget.agentId &&
            AppletLocalOwnership.storedScopeKey(current) == expectedScopeKey &&
            isAppletPresentationPending(current),
      );
    }
    return AgentGameCompensationStatus.complete;
  }
}

class _SecondPendingCompensationCloudService
    extends _RecordingInitialSyncCloudService {
  _SecondPendingCompensationCloudService({
    required super.database,
    required super.lifecycle,
  });

  @override
  Future<AgentGameCompensationStatus> compensateUnpresented(
    AgentWidget widget, {
    required String expectedScopeKey,
  }) async {
    if (compensationCalls == 1) {
      compensationCalls++;
      return AgentGameCompensationStatus.pending;
    }
    return super.compensateUnpresented(
      widget,
      expectedScopeKey: expectedScopeKey,
    );
  }
}

class _OrderingFirstFrameWaiter extends _RecordingFirstFrameWaiter {
  _OrderingFirstFrameWaiter(this.lifecycle, {super.error});

  final List<String> lifecycle;

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) {
    lifecycle.add('first-frame');
    return super.waitForFirstFrame(
      session: session,
      document: document,
      timeout: timeout,
    );
  }
}

class _RecordingFirstFrameWaiter implements SurfaceWorkerFirstFrameWaiter {
  _RecordingFirstFrameWaiter({
    this.error,
    this.beginError,
    this.errorSequence = const <Object?>[],
  });

  final Object? error;
  final Object? beginError;
  final List<Object?> errorSequence;
  final List<int> sessions = <int>[];
  int cancelCalls = 0;

  @override
  void beginPresentation({SurfaceRuntime? runtime}) {
    final failure = beginError;
    if (failure != null) throw failure;
  }

  @override
  void cancelPresentation() {
    cancelCalls++;
  }

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) async {
    sessions.add(session);
    final attempt = sessions.length - 1;
    final failure = attempt < errorSequence.length
        ? errorSequence[attempt]
        : error;
    if (failure != null) throw failure;
  }
}

AgentActionEnvelope _skillCallEnvelope(
  String tool,
  Map<String, Object?> arguments,
) => AgentActionEnvelope(
  reply: '',
  actions: <AgentAction>[
    AgentAction(
      type: 'skill.call',
      data: <String, Object?>{'tool': tool, 'args': arguments},
    ),
  ],
);

class _SurfaceHostSkill extends AgentSkill {
  _SurfaceHostSkill({this.editBarrier});

  final Future<void> Function()? editBarrier;
  final Map<String, int> calls = <String, int>{};
  final Map<String, String> results = <String, String>{};

  int get showCalls => calls['showSurface'] ?? 0;

  @override
  String get skillName => 'FreeformSurface';

  @override
  String get description => 'surface';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    for (final method in const <String>[
      'showSurface',
      'editSurface',
      'listSurfaces',
      'reopenSurface',
      'revertSurface',
    ])
      method: (_) async {
        calls[method] = (calls[method] ?? 0) + 1;
        if (method == 'editSurface' && editBarrier != null) {
          await editBarrier!();
        }
        return results[method] ?? '{}';
      },
  };
}

SurfaceProject _visibleSurface(String id) =>
    SurfaceProject.fromJson(<String, Object?>{
      'id': id,
      'title': id,
      'kind': 'fullscreen',
      'rendering': 'dom',
      'html': '<main>ready</main>',
    });
