import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sembast/sembast_memory.dart';

import 'package:maaso/src/features/agent/application/skills/freeform_surface_skill.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/applets/application/applet_version_history.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_draft.dart';

Future<DBService> _memDb() => DBService().init(
  factory: databaseFactoryMemory,
  path: 'surface_persistence_${DateTime.now().microsecondsSinceEpoch}.db',
);

Future<AgentWidget> _applyLatestDraft(DBService database) async {
  final item = (await database.getAllWidgets()).single;
  final draft = SurfaceVersionDraft.tryParse(item.spec['pendingVersionDraft']);
  expect(draft, isNotNull);
  return applyAppletVersionDraft(
    item: item,
    draftId: draft!.id,
    scopeKey: AppletLocalOwnership.currentScopeKey(),
    firstFrameReady: true,
  );
}

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test('surface widget kind is recognized', () {
    final widget = AgentWidget(
      agentId: 'self',
      title: 'Surface',
      kind: 'surface',
      spec: {'surfaceId': 'surface_1', 'surfaceKind': 'floatingCanvas'},
      createdAt: DateTime(2026, 6, 30),
    );

    expect(widget.isSurface, isTrue);
  });

  test(
    'validated widget insert rolls back when the post-write guard changes',
    () async {
      final db = await _memDb();
      final widget = AgentWidget(
        agentId: 'self',
        title: 'Guarded Surface',
        kind: 'surface',
        spec: const <String, Object?>{
          'surfaceId': 'guarded-surface',
          'surfaceKind': 'floatingCanvas',
        },
        createdAt: DateTime.utc(2026, 8, 8),
      );
      var validations = 0;

      await expectLater(
        db.saveAgentWidgetValidated(
          widget,
          validate: (_) {
            validations++;
            if (validations > 1) throw StateError('scope changed');
          },
        ),
        throwsStateError,
      );

      expect(validations, 2);
      expect(await db.getAllWidgets(), isEmpty);
    },
  );

  test(
    'validated widget mutations roll back when post-write scope guards change',
    () async {
      final db = await _memDb();
      final widget = _scopedSurfaceWidget(
        title: 'Original',
        surfaceId: 'transaction-surface',
        scopeKey: 'scope-a',
        seen: false,
      );
      await db.saveAgentWidget(widget);
      final originalCreatedAt = widget.createdAt;

      var markValidations = 0;
      await expectLater(
        db.markWidgetSeenValidated(
          widget.id!,
          validate: (_) => ++markValidations == 1,
        ),
        throwsStateError,
      );
      expect(markValidations, 2);
      expect((await db.getAllWidgets()).single.seen, isFalse);

      var updateValidations = 0;
      await expectLater(
        db.updateGeneratedSurface(
          widget.id!,
          title: 'Changed',
          spec: <String, Object?>{
            ...widget.spec,
            'html': '<main>changed</main>',
          },
          expectedScopeKey: 'scope-a',
          validateScope: (_, expected) {
            expect(expected, 'scope-a');
            return ++updateValidations == 1;
          },
        ),
        throwsStateError,
      );
      expect(updateValidations, 2);
      var saved = (await db.getAllWidgets()).single;
      expect(saved.title, 'Original');
      expect(saved.spec['html'], '<main>original</main>');

      await db.markWidgetSeen(widget.id!);
      var resurfaceValidations = 0;
      await expectLater(
        db.resurfaceWidget(
          widget.id!,
          expectedScopeKey: 'scope-a',
          validateScope: (_, expected) {
            expect(expected, 'scope-a');
            return ++resurfaceValidations == 1;
          },
        ),
        throwsStateError,
      );
      expect(resurfaceValidations, 2);
      saved = (await db.getAllWidgets()).single;
      expect(saved.seen, isTrue);
      expect(saved.createdAt, originalCreatedAt);

      var deleteValidations = 0;
      await expectLater(
        db.deleteWidgetValidated(
          widget.id!,
          validate: (_) => ++deleteValidations == 1,
        ),
        throwsStateError,
      );
      expect(deleteValidations, 2);
      expect(await db.getAllWidgets(), hasLength(1));
    },
  );

  test(
    'all saved-surface entries discard an A result after switching to B',
    () async {
      final db = await _gatedMemDb();
      appServices.put<DBService>(db);
      final auth = await _signIn('account-a');
      final scopeA = AppletLocalOwnership.currentScopeKey();
      auth.session.value = _session('account-b');
      final scopeB = AppletLocalOwnership.currentScopeKey();
      final widgetA = _scopedSurfaceWidget(
        title: 'Account A Surface',
        surfaceId: 'surface-a',
        scopeKey: scopeA,
        seen: true,
      );
      final widgetB = _scopedSurfaceWidget(
        title: 'Account B Surface',
        surfaceId: 'surface-b',
        scopeKey: scopeB,
        seen: true,
      );
      await db.saveAgentWidget(widgetA);
      await db.saveAgentWidget(widgetB);
      final originalA = jsonEncode(widgetA.toJson());
      final originalB = jsonEncode(widgetB.toJson());
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final invocations = <String, List<dynamic>>{
        'showSurface': <dynamic>[
          jsonEncode(_surfacePayload(title: 'Late Account A Surface')),
        ],
        'editSurface': <dynamic>[
          jsonEncode(<String, Object?>{
            'id': widgetA.id,
            'title': 'Cross-account edit',
            'html': '<main>cross-account edit</main>',
          }),
        ],
        'revertSurface': <dynamic>[
          jsonEncode(<String, Object?>{
            'id': widgetA.id,
            'revisionId': 'revision-a',
          }),
        ],
        'reopenSurface': <dynamic>[
          jsonEncode(<String, Object?>{'id': widgetA.id}),
        ],
        'listSurfaces': <dynamic>[],
      };

      for (final invocation in invocations.entries) {
        auth.session.value = _session('account-a');
        db.gateNextRead();
        final pending = skill.methods[invocation.key]!(invocation.value);
        await db.readStarted.future;
        auth.session.value = _session('account-b');
        db.releaseRead();

        final result = jsonDecode(await pending as String) as Map;
        expect(
          result['error'],
          'applet_quota_unavailable',
          reason: invocation.key,
        );
        expect(runtime.isVisible.value, isFalse, reason: invocation.key);

        final stored = await db.getAllWidgets();
        expect(
          jsonEncode(
            stored.singleWhere((item) => item.id == widgetA.id).toJson(),
          ),
          originalA,
          reason: invocation.key,
        );
        expect(
          jsonEncode(
            stored.singleWhere((item) => item.id == widgetB.id).toJson(),
          ),
          originalB,
          reason: invocation.key,
        );

        final bListRaw =
            await skill.methods['listSurfaces']!(<dynamic>[]) as String;
        final bSurfaces =
            (jsonDecode(bListRaw) as Map<String, dynamic>)['surfaces'] as List;
        expect(bSurfaces.map((item) => (item as Map)['title']), <String>[
          'Account B Surface',
        ], reason: invocation.key);
      }

      auth.session.value = _session('account-a');
      final aListRaw =
          await skill.methods['listSurfaces']!(<dynamic>[]) as String;
      final aSurfaces =
          (jsonDecode(aListRaw) as Map<String, dynamic>)['surfaces'] as List;
      expect(aSurfaces.map((item) => (item as Map)['title']), <String>[
        'Account A Surface',
      ]);
    },
  );

  test(
    'scope change during show closes the session and does not remember it',
    () async {
      final auth = await _signIn('account-a');
      final runtime = _DelayedSurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final pending = skill.methods['showSurface']!(<dynamic>[
        jsonEncode(_surfacePayload(title: 'Account A Memory')),
      ]);
      await runtime.showStarted.future;
      auth.session.value = _session('account-b');
      runtime.releaseShow();

      final result = jsonDecode(await pending as String) as Map;
      expect(result['error'], 'applet_quota_unavailable');
      expect(runtime.isVisible.value, isFalse);
      expect(runtime.activeProject.value, isNull);

      final bListRaw =
          await skill.methods['listSurfaces']!(<dynamic>[]) as String;
      expect(
        (jsonDecode(bListRaw) as Map<String, dynamic>)['surfaces'],
        isEmpty,
      );
      auth.session.value = _session('account-a');
      final aListRaw =
          await skill.methods['listSurfaces']!(<dynamic>[]) as String;
      expect(
        (jsonDecode(aListRaw) as Map<String, dynamic>)['surfaces'],
        isEmpty,
      );
    },
  );

  test(
    'signed-in local creation is shown and retained without a cloud service',
    () async {
      final db = await _memDb();
      appServices.put<DBService>(db);
      final auth = await _signIn('account-a');
      await _registerEmptyInventoryCatalog(auth);
      final runtime = _CountingSurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final raw =
          await skill.methods['showSurface']!(<dynamic>[
                jsonEncode(_workerGamePayload()),
              ])
              as String;
      final result = jsonDecode(raw) as Map;

      expect(result['error'], isNull);
      expect(result['widgetId'], isA<int>());
      expect(runtime.showCalls, 1);
      expect(runtime.isVisible.value, isTrue);
      expect(runtime.activeProject.value?.id, result['surfaceId']);

      final widgets = await db.getAllWidgets();
      expect(widgets, hasLength(1));
      expect(
        AppletLocalOwnership.storedScopeKey(widgets.single),
        AppletLocalOwnership.currentScopeKey(),
      );
      final cloud = AgentGameCloudMetadata.fromSpec(
        widgets.single.spec['cloud'],
      );
      expect(cloud.syncState, AgentGameSyncState.pending);
      expect(cloud.hasPublished, isFalse);
      final listRaw =
          await skill.methods['listSurfaces']!(<dynamic>[]) as String;
      expect((jsonDecode(listRaw) as Map)['surfaces'], hasLength(1));
    },
  );

  test('showSurface saves a complete surface widget and lists it', () async {
    final db = await _memDb();
    appServices.put<DBService>(db);
    final runtime = SurfaceRuntime();
    final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

    final raw =
        await skill.methods['showSurface']!([jsonEncode(_surfacePayload())])
            as String;
    final result = jsonDecode(raw) as Map<String, dynamic>;

    expect(result['surfaceId'], isA<String>());
    expect(result['widgetId'], isA<int>());
    expect(runtime.activeProject.value?.id, result['surfaceId']);

    final widgets = await db.getAllWidgets();
    expect(widgets, hasLength(1));
    final widget = widgets.single;
    expect(widget.id, result['widgetId']);
    expect(widget.isSurface, isTrue);
    expect(widget.kind, 'surface');
    expect(widget.title, 'Orbit Toy');
    expect(widget.subtitle, 'A playful orbit simulator for learning gravity.');
    expect(widget.spec['surfaceId'], result['surfaceId']);
    expect(widget.spec['surfaceKind'], 'floatingCanvas');
    expect(widget.spec['html'], '<canvas id="orbit"></canvas>');
    expect(widget.spec['css'], '#orbit{width:100%}');
    expect(widget.spec['js'], 'window.ready=true;');
    expect(widget.spec['transparent'], isTrue);
    expect(widget.spec['rendering'], 'canvas');
    expect(widget.spec['placement'], {
      'x': 0.1,
      'y': 0.2,
      'width': 0.7,
      'height': 0.5,
    });
    expect(widget.spec['manifest'], {
      'events': [
        {
          'name': 'tap_star',
          'schema': {'id': 'string'},
        },
      ],
      'actions': [
        {
          'name': 'pulse',
          'schema': {'speed': 'number'},
        },
      ],
      'instructions': 'React to star taps.',
    });
    expect(widget.spec['backend'], {
      'collections': ['stars'],
    });
    expect(widget.spec['revisions'], isEmpty);

    final listRaw = await skill.methods['listSurfaces']!([]) as String;
    final list = jsonDecode(listRaw) as Map<String, dynamic>;
    final surfaces = list['surfaces'] as List<dynamic>;
    expect(surfaces, hasLength(1));
    expect(surfaces.single['id'], widget.id);
    expect(surfaces.single['surfaceId'], result['surfaceId']);
    expect(surfaces.single['title'], 'Orbit Toy');
    expect(surfaces.single['surface'], 'floatingCanvas');
    expect(surfaces.single['rendering'], 'canvas');
    expect(surfaces.single['revisionCount'], 0);
  });

  for (final failure in <String, SurfaceWorkerFirstFrameException>{
    'timeout': const SurfaceWorkerFirstFrameException.timeout(),
    'fatal': const SurfaceWorkerFirstFrameException.fatal(
      SurfaceWorkerFatalReason.webViewLoadFailed,
    ),
  }.entries) {
    test(
      'webApp ${failure.key} before first frame leaves no saved Surface',
      () async {
        final db = await _memDb();
        appServices.put<DBService>(db);
        final waiter = _RejectingFirstFrameWaiter(failure.value);
        appServices.put<SurfaceWorkerFirstFrameWaiter>(
          waiter,
          overrideAbstract: true,
        );
        final runtime = SurfaceRuntime();
        final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

        final raw =
            await skill.methods['showSurface']!(<dynamic>[
                  jsonEncode(_webAppGamePayload()),
                ])
                as String;
        final result = jsonDecode(raw) as Map<String, dynamic>;

        expect(result['error'], 'execution_failed');
        expect(waiter.beginCalls, 1);
        expect(waiter.waitCalls, 1);
        expect(waiter.cancelCalls, 1);
        expect(waiter.timeout, const Duration(seconds: 15));
        expect(waiter.document, contains('<button id="start">Play</button>'));
        expect(runtime.isVisible.value, isFalse);
        expect(runtime.activeProject.value, isNull);
        expect(await db.getAllWidgets(), isEmpty);

        final listRaw =
            await skill.methods['listSurfaces']!(<dynamic>[]) as String;
        expect((jsonDecode(listRaw) as Map)['surfaces'], isEmpty);
      },
    );
  }

  test(
    'pending and tombstoned saved surfaces cannot be listed reopened or edited',
    () async {
      for (final hiddenSpec in <Map<String, Object?>>[
        const <String, Object?>{appletPresentationPendingKey: true},
        const <String, Object?>{
          'cloudDelete': <String, Object?>{
            'scopeKey': AppletLocalOwnership.deviceLegacyScope,
            'clientSurfaceId': 'hidden-surface',
          },
        },
      ]) {
        final db = await _memDb();
        appServices.put<DBService>(db);
        final runtime = _CountingSurfaceRuntime();
        final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
        final shown =
            jsonDecode(
                  await skill.methods['showSurface']!(<dynamic>[
                        jsonEncode(_surfacePayload(title: 'Hidden Surface')),
                      ])
                      as String,
                )
                as Map<String, dynamic>;
        final widgetId = shown['widgetId'] as int;
        await runtime.close();
        for (final entry in hiddenSpec.entries) {
          await db.updateWidgetSpecField(widgetId, entry.key, entry.value);
        }
        final widget = (await db.getAllWidgets()).single;
        final original = jsonEncode(widget.toJson());

        final listRaw =
            await skill.methods['listSurfaces']!(<dynamic>[]) as String;
        expect(
          (jsonDecode(listRaw) as Map<String, dynamic>)['surfaces'],
          isEmpty,
        );

        for (final method in <String>['reopenSurface', 'editSurface']) {
          final payload = <String, Object?>{'id': widget.id};
          if (method == 'editSurface') {
            payload['html'] = '<main>must not persist</main>';
          }
          final raw =
              await skill.methods[method]!(<dynamic>[jsonEncode(payload)])
                  as String;
          expect(
            (jsonDecode(raw) as Map<String, dynamic>)['error'],
            'surface_not_found',
            reason: '$method with $hiddenSpec',
          );
        }

        expect(runtime.showCalls, 1);
        expect(
          jsonEncode((await db.getAllWidgets()).single.toJson()),
          original,
        );
        appServices.reset();
        appServices.testMode = true;
      }
    },
  );

  test(
    'a deleted persisted surface cannot fall back to stale skill memory',
    () async {
      final db = await _memDb();
      appServices.put<DBService>(db);
      final runtime = _CountingSurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
      final shown =
          jsonDecode(
                await skill.methods['showSurface']!(<dynamic>[
                      jsonEncode(_surfacePayload(title: 'Deleted Surface')),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final widgetId = shown['widgetId'] as int;
      final surfaceId = shown['surfaceId'] as String;
      final edited =
          jsonDecode(
                await skill.methods['editSurface']!(<dynamic>[
                      jsonEncode(<String, Object?>{
                        'surfaceId': surfaceId,
                        'html': '<main>persisted revision</main>',
                      }),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      expect(edited['surfaceId'], surfaceId);
      expect(runtime.showCalls, 1);
      await runtime.close();
      await db.deleteWidget(widgetId);

      final listRaw =
          await skill.methods['listSurfaces']!(<dynamic>[]) as String;
      final results = <String, Map<String, dynamic>>{};
      for (final invocation in <String, Map<String, Object?>>{
        'reopenSurface': <String, Object?>{'surfaceId': surfaceId},
        'editSurface': <String, Object?>{
          'surfaceId': surfaceId,
          'html': '<main>must not return</main>',
        },
        'revertSurface': <String, Object?>{'surfaceId': surfaceId},
      }.entries) {
        results[invocation.key] =
            jsonDecode(
                  await skill.methods[invocation.key]!(<dynamic>[
                        jsonEncode(invocation.value),
                      ])
                      as String,
                )
                as Map<String, dynamic>;
      }

      expect(
        (jsonDecode(listRaw) as Map<String, dynamic>)['surfaces'],
        isEmpty,
      );
      for (final result in results.entries) {
        expect(result.value['error'], 'surface_not_found', reason: result.key);
      }
      expect(runtime.showCalls, 1);
      expect(runtime.isVisible.value, isFalse);
      expect(await db.getAllWidgets(), isEmpty);
    },
  );

  test(
    'showSurface rejects empty surfaces and does not persist them',
    () async {
      final db = await _memDb();
      appServices.put<DBService>(db);
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final raw =
          await skill.methods['showSurface']!([
                jsonEncode({
                  'title': '大富翁 Mini',
                  'surface': 'fullscreen',
                  'rendering': 'canvas',
                  'html': '<main></main>',
                  'css': 'body{margin:0}',
                  'js': '',
                }),
              ])
              as String;
      final result = jsonDecode(raw) as Map<String, dynamic>;

      expect(result['error'], 'execution_failed');
      expect(runtime.isVisible.value, isFalse);
      expect(await db.getAllWidgets(), isEmpty);
    },
  );

  test(
    'showSurface preserves ordinary network source when saving a webApp game',
    () async {
      final db = await _memDb();
      appServices.put<DBService>(db);
      appServices.put<SurfaceWorkerFirstFrameWaiter>(
        const SurfaceWorkerTestFirstFrameWaiter(),
        overrideAbstract: true,
      );
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
      final payload = <String, Object?>{
        ..._webAppGamePayload(),
        'js':
            '${_webAppGamePayload()['js']}\nfetch("https://example.com/score");',
      };

      final raw =
          await skill.methods['showSurface']!(<dynamic>[jsonEncode(payload)])
              as String;
      final result = jsonDecode(raw) as Map<String, dynamic>;

      expect(result['error'], isNull);
      expect(result['widgetId'], isA<int>());
      expect(runtime.isVisible.value, isTrue);
      final saved = (await db.getAllWidgets()).single;
      expect(saved.spec['js'], payload['js']);
      expect(runtime.activeProject.value?.js, payload['js']);
    },
  );

  test(
    'reopenSurface opens a saved surface and resurfaces widget id opens',
    () async {
      final db = await _memDb();
      appServices.put<DBService>(db);
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final shown =
          jsonDecode(
                await skill.methods['showSurface']!([
                      jsonEncode(_surfacePayload(title: 'Saved Canvas')),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final widgetId = shown['widgetId'] as int;
      await runtime.close();
      await db.markWidgetSeen(widgetId);

      final raw =
          await skill.methods['reopenSurface']!([
                jsonEncode({'id': widgetId}),
              ])
              as String;
      final result = jsonDecode(raw) as Map<String, dynamic>;

      expect(result['surfaceId'], shown['surfaceId']);
      expect(result['widgetId'], widgetId);
      expect(runtime.isVisible.value, isTrue);
      expect(runtime.activeProject.value?.title, 'Saved Canvas');
      expect(runtime.activeProject.value?.html, '<canvas id="orbit"></canvas>');

      final reopened = (await db.getAllWidgets()).singleWhere(
        (widget) => widget.id == widgetId,
      );
      expect(reopened.seen, isFalse);
    },
  );

  test(
    'editSurface creates a draft and explicit apply stores the previous source revision',
    () async {
      final db = await _memDb();
      appServices.put<DBService>(db);
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final shown =
          jsonDecode(
                await skill.methods['showSurface']!([
                      jsonEncode(_surfacePayload()),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final widgetId = shown['widgetId'] as int;
      final surfaceId = shown['surfaceId'] as String;

      final raw =
          await skill.methods['editSurface']!([
                jsonEncode({
                  'surfaceId': surfaceId,
                  'title': 'Orbit Toy v2',
                  'category': 'travel',
                  'skillInstructions':
                      'Configure an orbit-inspired travel route.',
                  'html': '<section id="orbit">new</section>',
                  'css': '#orbit{color:red}',
                  'js': 'window.ready=false;',
                  'manifest': {
                    'actions': [
                      {
                        'name': 'reset',
                        'schema': {'hard': 'bool'},
                      },
                    ],
                    'instructions': 'Reset when asked.',
                  },
                  'backend': {
                    'collections': ['stars', 'logs'],
                  },
                }),
              ])
              as String;
      final result = jsonDecode(raw) as Map<String, dynamic>;

      expect(result['surfaceId'], surfaceId);
      expect(result['widgetId'], widgetId);
      expect(result['status'], 'draft_ready');
      expect(result['applied'], isFalse);
      expect(runtime.activeProject.value?.html, '<canvas id="orbit"></canvas>');
      expect(
        (await db.getAllWidgets()).single.spec['html'],
        '<canvas id="orbit"></canvas>',
      );
      await _applyLatestDraft(db);

      final widgets = await db.getAllWidgets();
      expect(widgets, hasLength(1));
      final widget = widgets.single;
      expect(widget.id, widgetId);
      expect(widget.title, 'Orbit Toy v2');
      expect(widget.spec['category'], 'travel');
      expect(
        widget.spec['skillInstructions'],
        'Configure an orbit-inspired travel route.',
      );
      expect(widget.spec['surfaceId'], surfaceId);
      expect(widget.spec['html'], '<section id="orbit">new</section>');
      expect(widget.spec['css'], '#orbit{color:red}');
      expect(widget.spec['js'], 'window.ready=false;');
      expect(widget.spec['manifest'], {
        'events': <Object?>[],
        'actions': [
          {
            'name': 'reset',
            'schema': {'hard': 'bool'},
          },
        ],
        'instructions': 'Reset when asked.',
      });
      expect(widget.spec['backend'], {
        'collections': ['stars', 'logs'],
      });

      final revisions = widget.spec['revisions'] as List<dynamic>;
      expect(revisions, hasLength(1));
      final revision = revisions.single as Map;
      expect(revision['id'], isA<String>());
      expect(revision['category'], 'tools');
      expect(
        revision['skillInstructions'],
        'Adjust pulse speed to explore gravity.',
      );
      final roundTrip = SurfaceProject.fromJson(widget.spec).revisions.single;
      expect(roundTrip.category, 'tools');
      expect(
        roundTrip.skillInstructions,
        'Adjust pulse speed to explore gravity.',
      );
      expect(revision['createdAt'], isA<String>());
      expect(revision['html'], '<canvas id="orbit"></canvas>');
      expect(revision['css'], '#orbit{width:100%}');
      expect(revision['js'], 'window.ready=true;');
      expect(revision['manifest'], {
        'events': [
          {
            'name': 'tap_star',
            'schema': {'id': 'string'},
          },
        ],
        'actions': [
          {
            'name': 'pulse',
            'schema': {'speed': 'number'},
          },
        ],
        'instructions': 'React to star taps.',
      });
      expect(revision['backend'], {
        'collections': ['stars'],
      });
    },
  );

  test(
    'editSurface preserves network code through an explicit game version apply',
    () async {
      final db = await _memDb();
      appServices.put<DBService>(db);
      appServices.put<SurfaceWorkerFirstFrameWaiter>(
        const SurfaceWorkerTestFirstFrameWaiter(),
        overrideAbstract: true,
      );
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
      final shown =
          jsonDecode(
                await skill.methods['showSurface']!(<dynamic>[
                      jsonEncode(_webAppGamePayload()),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final originalSource = runtime.activeProject.value!.js;
      final editedSource =
          '$originalSource\nfetch("https://example.com/score");';

      final raw =
          await skill.methods['editSurface']!(<dynamic>[
                jsonEncode(<String, Object?>{
                  'surfaceId': shown['surfaceId'],
                  'js': editedSource,
                }),
              ])
              as String;
      final result = jsonDecode(raw) as Map<String, dynamic>;

      expect(result['error'], isNull);
      expect(result['status'], 'draft_ready');
      expect((await db.getAllWidgets()).single.spec['js'], originalSource);
      final applied = await _applyLatestDraft(db);
      expect(applied.spec['js'], editedSource);
      final revisions = applied.spec['revisions'] as List<dynamic>;
      expect((revisions.single as Map)['js'], originalSource);
    },
  );

  test('revertSurface restores a saved revision in the same widget', () async {
    final db = await _memDb();
    appServices.put<DBService>(db);
    final runtime = SurfaceRuntime();
    final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

    final shown =
        jsonDecode(
              await skill.methods['showSurface']!([
                    jsonEncode(_surfacePayload()),
                  ])
                  as String,
            )
            as Map<String, dynamic>;
    final widgetId = shown['widgetId'] as int;

    await skill.methods['editSurface']!([
      jsonEncode({
        'id': widgetId,
        'category': 'travel',
        'skillInstructions': 'Configure a route.',
        'html': '<section>edited</section>',
        'css': 'section{color:blue}',
        'js': 'window.edited=true;',
        'manifest': {
          'actions': [
            {'name': 'edited', 'schema': <String, Object?>{}},
          ],
        },
        'backend': {
          'collections': ['edited'],
        },
      }),
    ]);

    await _applyLatestDraft(db);
    final edited = (await db.getAllWidgets()).single;
    final revision = (edited.spec['revisions'] as List).single as Map;

    final raw =
        await skill.methods['revertSurface']!([
              jsonEncode({'surfaceId': shown['surfaceId']}),
            ])
            as String;
    final result = jsonDecode(raw) as Map<String, dynamic>;

    expect(result['surfaceId'], shown['surfaceId']);
    expect(result['widgetId'], widgetId);
    expect(result['revisionId'], revision['id']);
    expect(runtime.activeProject.value?.html, '<canvas id="orbit"></canvas>');

    final reverted = (await db.getAllWidgets()).single;
    expect(reverted.id, widgetId);
    expect(reverted.spec['category'], 'tools');
    expect(
      reverted.spec['skillInstructions'],
      'Adjust pulse speed to explore gravity.',
    );
    expect(reverted.spec['html'], '<canvas id="orbit"></canvas>');
    expect(reverted.spec['css'], '#orbit{width:100%}');
    expect(reverted.spec['js'], 'window.ready=true;');
    expect(reverted.spec['manifest'], {
      'events': [
        {
          'name': 'tap_star',
          'schema': {'id': 'string'},
        },
      ],
      'actions': [
        {
          'name': 'pulse',
          'schema': {'speed': 'number'},
        },
      ],
      'instructions': 'React to star taps.',
    });
    expect(reverted.spec['backend'], {
      'collections': ['stars'],
    });
    expect(reverted.spec['revisions'], hasLength(2));
  });

  test(
    'consecutive implicit restores append versions and preserve the complete history',
    () async {
      final db = await _memDb();
      appServices.put<DBService>(db);
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final shown =
          jsonDecode(
                await skill.methods['showSurface']!([
                      jsonEncode(_surfacePayload(title: 'Version 0')),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final surfaceId = shown['surfaceId'] as String;

      await skill.methods['editSurface']!([
        jsonEncode({
          'surfaceId': surfaceId,
          'title': 'Version 1',
          'html': '<main>version 1</main>',
          'placement': {'x': 0.2, 'y': 0.3, 'width': 0.6, 'height': 0.4},
          'transparent': false,
          'rendering': 'svg',
          'experienceType': 'utility',
          'surface': 'fullscreen',
        }),
      ]);
      await _applyLatestDraft(db);
      await skill.methods['editSurface']!([
        jsonEncode({
          'surfaceId': surfaceId,
          'title': 'Version 2',
          'html': '<main>version 2</main>',
          'placement': {'x': 0, 'y': 0, 'width': 1, 'height': 1},
          'transparent': true,
          'rendering': 'canvas',
          'experienceType': 'utility',
          'surface': 'card',
        }),
      ]);
      await _applyLatestDraft(db);

      await skill.methods['revertSurface']!([
        jsonEncode({'surfaceId': surfaceId}),
      ]);
      var reverted = (await db.getAllWidgets()).single;
      expect(reverted.title, 'Version 1');
      expect(reverted.spec['html'], '<main>version 1</main>');
      expect(reverted.spec['placement'], {
        'x': 0.2,
        'y': 0.3,
        'width': 0.6,
        'height': 0.4,
      });
      expect(reverted.spec['transparent'], false);
      expect(reverted.spec['rendering'], 'svg');
      expect(reverted.spec['experienceType'], 'utility');
      expect(reverted.spec['surfaceKind'], 'fullscreen');
      expect(reverted.spec['revisions'], hasLength(3));

      await skill.methods['revertSurface']!([
        jsonEncode({'surfaceId': surfaceId}),
      ]);
      reverted = (await db.getAllWidgets()).single;
      expect(reverted.title, 'Version 0');
      expect(reverted.spec['html'], '<canvas id="orbit"></canvas>');
      expect(reverted.spec['placement'], {
        'x': 0.1,
        'y': 0.2,
        'width': 0.7,
        'height': 0.5,
      });
      expect(reverted.spec['transparent'], true);
      expect(reverted.spec['rendering'], 'canvas');
      expect(reverted.spec['experienceType'], 'utility');
      expect(reverted.spec['surfaceKind'], 'floatingCanvas');
      expect(reverted.spec['revisions'], hasLength(4));
    },
  );

  test(
    'revertSurface restores manifest and backend for in-memory revisions',
    () async {
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final shown =
          jsonDecode(
                await skill.methods['showSurface']!([
                      jsonEncode(_surfacePayload(title: 'Memory Surface')),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final surfaceId = shown['surfaceId'] as String;

      await skill.methods['editSurface']!([
        jsonEncode({
          'surfaceId': surfaceId,
          'html': '<section>edited</section>',
          'css': 'section{color:blue}',
          'js': 'window.edited=true;',
          'manifest': {
            'actions': [
              {'name': 'edited', 'schema': <String, Object?>{}},
            ],
          },
          'backend': {
            'collections': ['edited'],
          },
        }),
      ]);

      final revision = runtime.activeProject.value!.revisions.single;

      final raw =
          await skill.methods['revertSurface']!([
                jsonEncode({'surfaceId': surfaceId, 'revisionId': revision.id}),
              ])
              as String;
      final result = jsonDecode(raw) as Map<String, dynamic>;

      expect(result['surfaceId'], surfaceId);
      expect(result['revisionId'], revision.id);
      expect(runtime.activeProject.value?.html, '<canvas id="orbit"></canvas>');
      expect(runtime.activeProject.value?.manifest.toJson(), {
        'events': [
          {
            'name': 'tap_star',
            'schema': {'id': 'string'},
          },
        ],
        'actions': [
          {
            'name': 'pulse',
            'schema': {'speed': 'number'},
          },
        ],
        'instructions': 'React to star taps.',
      });
      expect(runtime.activeProject.value?.backend, {
        'collections': ['stars'],
      });
      expect(runtime.activeProject.value?.revisions, hasLength(2));
    },
  );

  test('listSurfaces falls back to in-memory surfaces without DB', () async {
    final runtime = SurfaceRuntime();
    final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

    final shown =
        jsonDecode(
              await skill.methods['showSurface']!([
                    jsonEncode(_surfacePayload(title: 'Memory Only')),
                  ])
                  as String,
            )
            as Map<String, dynamic>;

    final listRaw = await skill.methods['listSurfaces']!([]) as String;
    final list = jsonDecode(listRaw) as Map<String, dynamic>;
    final surfaces = list['surfaces'] as List<dynamic>;

    expect(surfaces, hasLength(1));
    expect(surfaces.single['id'], shown['surfaceId']);
    expect(surfaces.single['surfaceId'], shown['surfaceId']);
    expect(surfaces.single['title'], 'Memory Only');
  });

  test(
    'a never-persisted memory surface survives later DB registration',
    () async {
      final runtime = _CountingSurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
      final shown =
          jsonDecode(
                await skill.methods['showSurface']!(<dynamic>[
                      jsonEncode(_surfacePayload(title: 'Memory Authority')),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final surfaceId = shown['surfaceId'] as String;
      appServices.put<DBService>(await _memDb());

      final listRaw =
          await skill.methods['listSurfaces']!(<dynamic>[]) as String;
      final reopened =
          jsonDecode(
                await skill.methods['reopenSurface']!(<dynamic>[
                      jsonEncode(<String, Object?>{'surfaceId': surfaceId}),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final edited =
          jsonDecode(
                await skill.methods['editSurface']!(<dynamic>[
                      jsonEncode(<String, Object?>{
                        'surfaceId': surfaceId,
                        'html': '<main>memory edit</main>',
                      }),
                    ])
                    as String,
              )
              as Map<String, dynamic>;
      final reverted =
          jsonDecode(
                await skill.methods['revertSurface']!(<dynamic>[
                      jsonEncode(<String, Object?>{'surfaceId': surfaceId}),
                    ])
                    as String,
              )
              as Map<String, dynamic>;

      expect(
        (jsonDecode(listRaw) as Map<String, dynamic>)['surfaces'],
        hasLength(1),
      );
      expect(reopened['surfaceId'], surfaceId);
      expect(edited['surfaceId'], surfaceId);
      expect(reverted['surfaceId'], surfaceId);
      expect(runtime.showCalls, 4);
      expect(await appServices.find<DBService>().getAllWidgets(), isEmpty);
    },
  );
}

Map<String, Object?> _surfacePayload({String title = 'Orbit Toy'}) => {
  'title': title,
  'summary': '  A playful orbit simulator\nfor learning gravity.  ',
  'category': 'tools',
  'skillInstructions': 'Adjust pulse speed to explore gravity.',
  'surface': 'floatingCanvas',
  'rendering': 'canvas',
  'html': '<canvas id="orbit"></canvas>',
  'css': '#orbit{width:100%}',
  'js': 'window.ready=true;',
  'transparent': true,
  'placement': {'x': 0.1, 'y': 0.2, 'width': 0.7, 'height': 0.5},
  'manifest': {
    'events': [
      {
        'name': 'tap_star',
        'schema': {'id': 'string'},
      },
    ],
    'actions': [
      {
        'name': 'pulse',
        'schema': {'speed': 'number'},
      },
    ],
    'instructions': 'React to star taps.',
  },
  'backend': {
    'collections': ['stars'],
  },
};

Map<String, Object?> _webAppGamePayload() => <String, Object?>{
  'title': 'Web App Game',
  'summary': 'A rich local game.',
  'experienceType': 'game',
  'surface': 'fullscreen',
  'rendering': 'webApp',
  'html': '<main><button id="start">Play</button></main>',
  'css': 'main{min-height:100vh}button{touch-action:manipulation}',
  'js': '''
document.querySelector('#start').addEventListener('click', function () {
  document.body.dataset.started = 'true';
});
''',
  'manifest': const <String, Object?>{},
};

Map<String, Object?> _workerGamePayload() => <String, Object?>{
  'title': 'Cloud Orbit',
  'summary': 'A cloud-synced orbit game.',
  'experienceType': 'game',
  'surface': 'fullscreen',
  'rendering': 'workerCanvas',
  'html': '',
  'css': '',
  'js': _workerGameJs,
  'manifest': <String, Object?>{
    'actions': <Object?>[
      <String, Object?>{'name': 'pulse', 'schema': <String, Object?>{}},
    ],
  },
};

const String _workerGameJs = '''
Game.define({
  init({width,height,dpr}) { return {x: width / 2, y: height / 2}; },
  update(state, frame) { return state; },
  draw(state, frame) {
    return [
      {type: 'clear', color: '#10131a'},
      {type: 'circle', x: state.x, y: state.y, r: 12, fillColor: '#66ddff'}
    ];
  },
  input(state, event) { return state; }
});
''';

Future<_GatedDBService> _gatedMemDb() async {
  final db = _GatedDBService();
  await db.init(
    factory: databaseFactoryMemory,
    path: 'surface_scope_${DateTime.now().microsecondsSinceEpoch}.db',
  );
  return db;
}

Future<AuthSessionService> _signIn(String account) async {
  appServices.put<SecureStorageService>(_MemorySecureStorage());
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(
      httpClient: MockClient((_) async {
        throw UnimplementedError('Auth HTTP is not expected');
      }),
    ),
  );
  await auth.init();
  auth.session.value = _session(account);
  return auth;
}

Future<void> _registerEmptyInventoryCatalog(AuthSessionService auth) async {
  final locale = appServices.put(LocaleConfigService());
  await locale.init();
  appServices.put<AppletCatalogService>(
    AppletCatalogService(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/applets/mine');
        return http.Response(
          jsonEncode(<String, Object?>{
            'code': 'OK',
            'data': <String, Object?>{
              'schemaVersion': 1,
              'items': <Object?>[],
              'quota': <String, Object?>{'used': 0, 'limit': 5},
            },
          }),
          200,
        );
      }),
      environment: appServices.find<AppEnvironmentService>(),
      auth: auth,
      locale: locale,
    ),
  );
}

MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'token-$account',
  refreshToken: 'refresh-$account',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

AgentWidget _scopedSurfaceWidget({
  required String title,
  required String surfaceId,
  required String scopeKey,
  required bool seen,
}) {
  final widget = AgentWidget(
    agentId: 'self',
    title: title,
    kind: 'surface',
    spec: <String, Object?>{
      'surfaceId': surfaceId,
      'surfaceKind': 'floatingCanvas',
      'experienceType': 'applet',
      'html': '<main>original</main>',
      'css': 'main{display:block}',
      'js': '',
      'manifest': const <String, Object?>{},
      'backend': const <String, Object?>{},
      'placement': const <String, Object?>{
        'x': 0.1,
        'y': 0.2,
        'width': 0.7,
        'height': 0.5,
      },
      'transparent': true,
      'rendering': 'canvas',
      'revisions': const <Object?>[
        <String, Object?>{
          'id': 'revision-a',
          'createdAt': '2026-08-08T00:00:00.000Z',
          'html': '<main>revision</main>',
          'css': 'main{display:block}',
          'js': '',
          'manifest': <String, Object?>{},
          'backend': <String, Object?>{},
        },
      ],
    },
    createdAt: DateTime.utc(2026, 8, 8),
    seen: seen,
  );
  AppletLocalOwnership.stamp(widget, scopeKey: scopeKey);
  return widget;
}

class _GatedDBService extends DBService {
  Completer<void> readStarted = Completer<void>();
  Completer<void> _readRelease = Completer<void>();
  bool _gateRead = false;

  void gateNextRead() {
    readStarted = Completer<void>();
    _readRelease = Completer<void>();
    _gateRead = true;
  }

  void releaseRead() {
    if (!_readRelease.isCompleted) _readRelease.complete();
  }

  @override
  Future<List<AgentWidget>> getAllWidgets() async {
    if (_gateRead) {
      _gateRead = false;
      readStarted.complete();
      await _readRelease.future;
    }
    return super.getAllWidgets();
  }
}

class _DelayedSurfaceRuntime extends SurfaceRuntime {
  final Completer<void> showStarted = Completer<void>();
  final Completer<void> _showRelease = Completer<void>();

  void releaseShow() {
    if (!_showRelease.isCompleted) _showRelease.complete();
  }

  @override
  Future<void> show(SurfaceProject project) async {
    showStarted.complete();
    await _showRelease.future;
    await super.show(project);
  }
}

class _CountingSurfaceRuntime extends SurfaceRuntime {
  int showCalls = 0;

  @override
  Future<void> show(SurfaceProject project) async {
    showCalls++;
    await super.show(project);
  }
}

class _RejectingFirstFrameWaiter implements SurfaceWorkerFirstFrameWaiter {
  _RejectingFirstFrameWaiter(this.failure);

  final SurfaceWorkerFirstFrameException failure;
  int beginCalls = 0;
  int waitCalls = 0;
  int cancelCalls = 0;
  Duration? timeout;
  String? document;

  @override
  void beginPresentation({SurfaceRuntime? runtime}) {
    beginCalls++;
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
    waitCalls++;
    this.document = document;
    this.timeout = timeout;
    throw failure;
  }
}

class _MemorySecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
