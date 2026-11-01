import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/skills/freeform_surface_skill.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_draft.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/applets/application/applet_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  late SurfaceRuntime runtime;
  late FreeformSurfaceSkill skill;
  late AgentWidget item;
  const scope = 'device-legacy';

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    db = appServices.put(
      await DBService().init(
        factory: databaseFactoryMemory,
        path: 'draft-${DateTime.now().microsecondsSinceEpoch}.db',
      ),
    );
    runtime = SurfaceRuntime();
    skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
    final spec = <String, Object?>{
      'surfaceId': 'draft-test',
      'surfaceKind': 'card',
      'rendering': 'dom',
      'experienceType': 'utility',
      'html': '<main>V1</main>',
      'css': '',
      'js': '',
      'manifest': {'actions': [], 'events': []},
      'backend': {},
      'revisions': [],
    };
    spec['versionHistory'] = SurfaceVersionHistory.create(
      spec,
      title: 'Original',
    ).toJson();
    item = AgentWidget(
      agentId: 'self',
      title: 'Original',
      kind: 'surface',
      spec: spec,
      createdAt: DateTime.now(),
    );
    AppletLocalOwnership.stamp(item);
    item.id = await db.saveAgentWidget(item);
    await runtime.show(
      SurfaceProject.fromJson({
        ...spec,
        'id': 'draft-test',
        'title': 'Original',
      }),
    );
  });
  tearDown(() async {
    await runtime.close();
    runtime.onClose();
    await appServices.reset();
    await db.close();
  });

  Future<Map<String, dynamic>> edit([
    Map<String, Object?> patch = const {'html': '<main>V2</main>'},
  ]) async =>
      jsonDecode(
            await skill.methods['editSurface']!([
                  jsonEncode({'surfaceId': 'draft-test', ...patch}),
                ])
                as String,
          )
          as Map<String, dynamic>;

  test(
    'edit saves a candidate without changing current source, history, or active session',
    () async {
      final before = surfaceVersionFingerprint(item.spec, title: item.title);
      final session = runtime.activeSession;
      final result = await edit();
      expect(result['status'], 'draft_ready');
      expect(result['applied'], isFalse);
      final saved = (await db.getAllWidgets()).single;
      expect(saved.spec['html'], '<main>V1</main>');
      expect(surfaceVersionFingerprint(saved.spec, title: saved.title), before);
      expect(runtime.activeSession, session);
      expect(runtime.activeProject.value!.html, '<main>V1</main>');
      final draft = SurfaceVersionDraft.tryParse(
        saved.spec['pendingVersionDraft'],
      )!;
      expect(draft.id, result['draftId']);
      expect(draft.source['html'], '<main>V2</main>');
      expect(
        () => (draft.source['manifest'] as Map)['x'] = 'mutate',
        throwsUnsupportedError,
      );
      expect(
        SurfaceVersionHistory.read(saved.spec, title: saved.title).versions,
        hasLength(1),
      );
    },
  );

  test('explicit apply alone issues V2 and leaves V1 intact', () async {
    final result = await edit();
    final saved = (await db.getAllWidgets()).single;
    final applied = await applyAppletVersionDraft(
      item: saved,
      draftId: result['draftId'] as String,
      scopeKey: scope,
      firstFrameReady: true,
    );
    expect(applied.spec['pendingVersionDraft'], isNull);
    expect(applied.spec['html'], '<main>V2</main>');
    final history = SurfaceVersionHistory.read(
      applied.spec,
      title: applied.title,
    );
    expect(history.versions.map((v) => v.number), [1, 2]);
    expect(history.versions.first.source['html'], '<main>V1</main>');
    await expectLater(
      applyAppletVersionDraft(
        item: saved,
        draftId: result['draftId'] as String,
        scopeKey: scope,
        firstFrameReady: true,
      ),
      throwsStateError,
    );
    expect(
      SurfaceVersionHistory.read(
        (await db.getAllWidgets()).single.spec,
        title: applied.title,
      ).versions,
      hasLength(2),
    );
  });

  test(
    'a superseded draft is rejected even while the base version is unchanged',
    () async {
      final first = await edit();
      final firstItem = (await db.getAllWidgets()).single;
      final second = await edit({'html': '<main>Different candidate</main>'});
      await expectLater(
        applyAppletVersionDraft(
          item: firstItem,
          draftId: first['draftId'] as String,
          scopeKey: scope,
          firstFrameReady: true,
        ),
        throwsStateError,
      );
      final current = (await db.getAllWidgets()).single;
      expect(current.spec['html'], '<main>V1</main>');
      expect(
        SurfaceVersionDraft.tryParse(current.spec['pendingVersionDraft'])!.id,
        second['draftId'],
      );
    },
  );

  test(
    'changed base source rejects apply and preserves a newer usable version',
    () async {
      final result = await edit();
      final candidate = (await db.getAllWidgets()).single;
      await db.updateWidget(
        item.id!,
        spec: {...candidate.spec, 'html': '<main>Other edit</main>'},
      );
      await expectLater(
        applyAppletVersionDraft(
          item: candidate,
          draftId: result['draftId'] as String,
          scopeKey: scope,
          firstFrameReady: true,
        ),
        throwsStateError,
      );
      expect(
        (await db.getAllWidgets()).single.spec['html'],
        '<main>Other edit</main>',
      );
    },
  );

  test(
    'foreign scope, deleted record, and forged candidate cannot be applied',
    () async {
      final result = await edit();
      final candidate = (await db.getAllWidgets()).single;
      await expectLater(
        applyAppletVersionDraft(
          item: candidate,
          draftId: result['draftId'] as String,
          scopeKey: 'other-account',
          firstFrameReady: true,
        ),
        throwsStateError,
      );
      final forged = Map<String, Object?>.from(
        candidate.spec['pendingVersionDraft'] as Map,
      );
      forged['source'] = {...(forged['source'] as Map), 'html': 'tampered'};
      expect(SurfaceVersionDraft.tryParse(forged), isNull);
      await db.deleteWidget(item.id!);
      await expectLater(
        applyAppletVersionDraft(
          item: candidate,
          draftId: result['draftId'] as String,
          scopeKey: scope,
          firstFrameReady: true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'first-frame failure creates no candidate and leaves current runtime intact',
    () async {
      appServices.put<SurfaceWorkerFirstFrameWaiter>(_RejectedFrame());
      final session = runtime.activeSession;
      final result = await edit({
        'rendering': 'webApp',
        'html': '<main><button id="go">Run</button></main>',
        'js': 'document.querySelector("#go").addEventListener("click",()=>{});',
      });
      expect(result['error'], isNotNull);
      expect(
        (await db.getAllWidgets()).single.spec['pendingVersionDraft'],
        isNull,
      );
      expect(runtime.activeSession, session);
      expect(runtime.activeProject.value!.html, '<main>V1</main>');
    },
  );

  test('cloud metadata arriving after preview survives apply', () async {
    final result = await edit();
    final candidate = (await db.getAllWidgets()).single;
    await db.updateWidgetSpecField(item.id!, 'cloud', {
      'revisionNo': 8,
      'publishedRevisionNo': 5,
    });
    final applied = await applyAppletVersionDraft(
      item: candidate,
      draftId: result['draftId'] as String,
      scopeKey: scope,
      firstFrameReady: true,
    );
    expect((applied.spec['cloud'] as Map)['publishedRevisionNo'], 5);
    expect((applied.spec['cloud'] as Map)['revisionNo'], 8);
  });
}

class _RejectedFrame implements SurfaceWorkerFirstFrameWaiter {
  @override
  void beginPresentation({SurfaceRuntime? runtime}) {}
  @override
  void cancelPresentation() {}
  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) async => throw const SurfaceWorkerFirstFrameException.timeout();
}
