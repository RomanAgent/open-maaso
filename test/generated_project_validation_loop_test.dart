import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/applets/presentation/applet_save_confirmation.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_source_fixture.dart';

const _unsafeCss = '@import "https://example.invalid/a.css";button{color:red}';
const _differentUnsafeCss = 'button{behavior:url(x);color:blue}';

class _FailFrames extends SurfaceWorkerTestFirstFrameWaiter {
  _FailFrames(this.failures);
  final int failures;
  int calls = 0;
  final documents = <String>[];

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) async {
    documents.add(document);
    if (++calls <= failures) {
      throw const SurfaceWorkerFirstFrameException.fatal(
        SurfaceWorkerFatalReason.runtimeFailed,
      );
    }
  }
}

class _Presentations extends SurfaceRuntime {
  final projects = <SurfaceProject>[];
  @override
  Future<void> show(SurfaceProject project) async {
    projects.add(project);
    await super.show(project);
  }
}

Future<void> _waitTerminal(AgentTaskJobStore store) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!{
    AgentTaskJobStatus.completed,
    AgentTaskJobStatus.failed,
    AgentTaskJobStatus.cancelled,
  }.contains(store.latestForAgent('self')?.status)) {
    if (DateTime.now().isAfter(deadline)) fail('generation did not terminate');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<
  ({
    DBService db,
    AgentTaskJobStore store,
    AgentRuntime runtime,
    _Presentations surface,
  })
>
_start(SourceFixtureClient client, {_FailFrames? waiter}) async {
  final db = appServices.put<DBService>(
    await DBService().init(
      factory: databaseFactoryMemory,
      path: 'repair_loop_${DateTime.now().microsecondsSinceEpoch}.db',
    ),
  );
  appServices.put<AppletSaveConfirmation>((_) async => true);
  appServices.put<SurfaceWorkerFirstFrameWaiter>(
    waiter ?? const SurfaceWorkerTestFirstFrameWaiter(),
  );
  final store = appServices.put(AgentTaskJobStore());
  final surface =
      appServices.put<SurfaceRuntime>(_Presentations()) as _Presentations;
  final runtime = AgentRuntime(
    agentId: 'self',
    profile: AgentProfile(
      nickname: 'Maaso',
      avatar: '',
      bio: '',
      personalityTraits: [],
      catchphrase: '',
    ),
    llmClient: client,
  );
  addTearDown(runtime.dispose);
  return (db: db, store: store, runtime: runtime, surface: surface);
}

List<Object> _initial({String css = sourceCss}) => [
  jsonEncode(sourcePlan),
  jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
  jsonEncode(boundSourceChunk('skin.css', css)),
  jsonEncode(boundSourceChunk('game.js', sourceJs)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          if (call.method == 'getLanguages') return <String>['en-US'];
          if (call.method == 'getVoices') return <Object>[];
          return 1;
        });
  });
  tearDown(appServices.reset);

  test(
    'static source rejection can repair twice without replacing metadata',
    () async {
      final client = SourceFixtureClient([
        ..._initial(css: _unsafeCss),
        jsonEncode(boundSourceChunk('skin.css', _differentUnsafeCss)),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
      ]);
      final host = await _start(client);
      await host.runtime.chat('生成魂斗罗小游戏', const []);
      await _waitTerminal(host.store);
      final job = host.store.latestForAgent('self')!;
      expect(job.status, AgentTaskJobStatus.completed, reason: job.error);
      expect(client.requests, hasLength(6));
      expect(client.ordinaryCalls, 0);
      expect(await host.db.getAllWidgets(), hasLength(1));
      expect(host.surface.projects, hasLength(1));
      final project = host.surface.projects.single;
      expect(project.html, sourceHtml);
      expect(project.css, endsWith(sourceCss));
      expect(project.js, sourceJs);
      expect(project.manifest.actions, isEmpty);
      expect(project.skillInstructions, sourcePlan['skillInstructions']);
      expect(client.requests[4].first.content, contains('self-contained CSS'));
      expect(
        client.requests[5].first.content,
        contains(jsonEncode(_differentUnsafeCss)),
      );
    },
  );

  test(
    'an unchanged rejected source stalls and never publishes a widget',
    () async {
      final client = SourceFixtureClient([
        ..._initial(css: _unsafeCss),
        jsonEncode(boundSourceChunk('skin.css', _unsafeCss)),
      ]);
      final host = await _start(client);
      await host.runtime.chat('生成魂斗罗小游戏', const []);
      await _waitTerminal(host.store);
      final job = host.store.latestForAgent('self')!;
      expect(job.status, AgentTaskJobStatus.failed);
      expect(job.failureCode, GeneratedTaskFailureCode.generationStalled.name);
      expect(client.requests, hasLength(5));
      expect(await host.db.getAllWidgets(), isEmpty);
      expect(host.surface.projects, isEmpty);
    },
  );

  test(
    'two startup failures repair the latest action under one grant and save once',
    () async {
      final waiter = _FailFrames(2);
      final js1 = '$sourceJs\nconst firstRepair=true;';
      final js2 = '$sourceJs\nconst secondRepair=true;';
      final client = SourceFixtureClient([
        ..._initial(),
        jsonEncode(boundSourceChunk('game.js', js1)),
        jsonEncode(boundSourceChunk('game.js', js2)),
      ]);
      final host = await _start(client, waiter: waiter);
      await host.runtime.chat('生成魂斗罗小游戏', const []);
      await _waitTerminal(host.store);
      final job = host.store.latestForAgent('self')!;
      expect(job.status, AgentTaskJobStatus.completed, reason: job.error);
      expect(waiter.calls, 3);
      expect(client.requests, hasLength(6));
      expect(host.surface.projects, hasLength(3));
      expect(await host.db.getAllWidgets(), hasLength(1));
      // Each rejected presentation is discarded and gets its own host ID.
      // The single committed row must point to the final successful attempt.
      final saved = (await host.db.getAllWidgets()).single;
      expect(saved.spec['surfaceId'], host.surface.projects.last.id);
      expect(host.surface.projects.map((p) => p.title).toSet(), {'Tap score'});
      expect(host.surface.projects.map((p) => p.skillInstructions).toSet(), {
        sourcePlan['skillInstructions'],
      });
      expect(host.surface.projects.last.js, js2);
      expect(client.requests[5].first.content, contains(jsonEncode(js1)));
      expect(
        client.requests[5].first.content,
        contains(jsonEncode(sourceHtml)),
      );
      expect(client.requests[5].first.content, contains(jsonEncode(sourceCss)));
      expect(client.requests[5].first.content, contains('runtime_failed'));
    },
  );

  test(
    'static repair does not consume the later startup repair opportunity',
    () async {
      final waiter = _FailFrames(1);
      final client = SourceFixtureClient([
        ..._initial(css: _unsafeCss),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
        jsonEncode(
          boundSourceChunk('game.js', '$sourceJs\nconst repaired=true;'),
        ),
      ]);
      final host = await _start(client, waiter: waiter);
      await host.runtime.chat('生成魂斗罗小游戏', const []);
      await _waitTerminal(host.store);
      final job = host.store.latestForAgent('self')!;
      expect(job.status, AgentTaskJobStatus.completed, reason: job.error);
      expect(waiter.calls, 2);
      expect(client.requests, hasLength(6));
      expect(await host.db.getAllWidgets(), hasLength(1));
    },
  );

  test(
    'repeated startup rejection of identical source is a definite stall',
    () async {
      final waiter = _FailFrames(10);
      final client = SourceFixtureClient([
        ..._initial(),
        jsonEncode(boundSourceChunk('game.js', sourceJs)),
      ]);
      final host = await _start(client, waiter: waiter);
      await host.runtime.chat('生成魂斗罗小游戏', const []);
      await _waitTerminal(host.store);
      final job = host.store.latestForAgent('self')!;
      expect(job.status, AgentTaskJobStatus.failed);
      expect(job.failureCode, GeneratedTaskFailureCode.generationStalled.name);
      expect(client.requests, hasLength(5));
      expect(waiter.calls, 1);
      expect(await host.db.getAllWidgets(), isEmpty);
      expect(host.surface.isVisible.value, isFalse);
    },
  );

  test(
    'revoked skill generation stops the second startup repair before another show',
    () async {
      final waiter = _FailFrames(2);
      final client = SourceFixtureClient([
        ..._initial(),
        jsonEncode(boundSourceChunk('game.js', '$sourceJs\nconst first=true;')),
        jsonEncode(boundSourceChunk('game.js', '$sourceJs\nconst late=true;')),
      ]);
      final host = await _start(client, waiter: waiter);
      client.afterResponse = () {
        if (client.requests.length == 6) {
          unawaited(host.runtime.reloadSkills(const {}));
        }
      };
      await host.runtime.chat('生成魂斗罗小游戏', const []);
      await _waitTerminal(host.store);
      final job = host.store.latestForAgent('self')!;
      expect(job.status, AgentTaskJobStatus.failed);
      expect(
        job.failureCode,
        GeneratedTaskFailureCode.generationAuthorizationUnavailable.name,
      );
      expect(client.requests, hasLength(6));
      expect(waiter.calls, 2);
      expect(await host.db.getAllWidgets(), isEmpty);
      expect(host.surface.isVisible.value, isFalse);
    },
  );

  test(
    'cancel during the second startup repair stops presentation and persistence',
    () async {
      final waiter = _FailFrames(2);
      final client = SourceFixtureClient([
        ..._initial(),
        jsonEncode(boundSourceChunk('game.js', '$sourceJs\nconst first=true;')),
        jsonEncode(boundSourceChunk('game.js', '$sourceJs\nconst late=true;')),
      ]);
      final host = await _start(client, waiter: waiter);
      client.afterResponse = () {
        if (client.requests.length == 6) {
          unawaited(
            host.runtime.cancelBackgroundTaskJob(
              host.store.latestForAgent('self')!.id,
            ),
          );
        }
      };
      await host.runtime.chat('生成魂斗罗小游戏', const []);
      await _waitTerminal(host.store);
      expect(
        host.store.latestForAgent('self')!.status,
        AgentTaskJobStatus.cancelled,
      );
      expect(client.requests, hasLength(6));
      expect(waiter.calls, 2);
      expect(await host.db.getAllWidgets(), isEmpty);
      expect(host.surface.isVisible.value, isFalse);
    },
  );
}
