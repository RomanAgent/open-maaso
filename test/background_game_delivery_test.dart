import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/applets/presentation/applet_save_confirmation.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/source_workspace_fixtures.dart';

class _SourceLlm extends LLMClient {
  _SourceLlm({bool game = true})
    : responses = workspaceFixtureResponses(game: game);
  final List<String> responses;
  int calls = 0;
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    return responses.removeAt(0);
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('Unexpected secondary classification');
}

class _FrameGate implements SurfaceWorkerFirstFrameWaiter {
  final started = Completer<void>();
  final result = Completer<void>();
  int? session;
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
    this.session = session;
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  void ready() {
    if (!result.isCompleted) result.complete();
  }
}

class _CommittedDb extends DBService {
  Future<void> Function()? afterCommit;
  @override
  Future<Map<String, Object?>> updateGeneratedSurface(
    int id, {
    String? title,
    required Map<String, Object?> spec,
    String? expectedScopeKey,
    String? expectedSourceFingerprint,
    bool Function(AgentWidget current, String expectedScopeKey)? validateScope,
  }) async {
    final receipt = await super.updateGeneratedSurface(
      id,
      title: title,
      spec: spec,
      expectedScopeKey: expectedScopeKey,
      expectedSourceFingerprint: expectedSourceFingerprint,
      validateScope: validateScope,
    );
    await afterCommit?.call();
    return receipt;
  }
}

class _ClosingSurface extends SurfaceRuntime {
  bool failClose = false;
  final closedSessions = <int>[];
  @override
  Future<void> closeIfSession(int session) async {
    closedSessions.add(session);
    if (failClose) throw StateError('Synthetic presentation cleanup failure');
    await super.closeIfSession(session);
  }
}

class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
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
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}

MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'synthetic-$account',
  refreshToken: 'synthetic-refresh-$account',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

class _DeliveryFixture {
  late _CommittedDb database;
  late AgentTaskJobStore jobs;
  late _ClosingSurface surface;
  late _SourceLlm llm;
  late AgentRuntime runtime;
  final gate = _FrameGate();
  Future<void> init({bool game = true}) async {
    database = _CommittedDb();
    await database.init(
      factory: databaseFactoryMemory,
      path: 'auto-game-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put<DBService>(database);
    jobs = await AgentTaskJobStore(
      persistence: SembastAgentTaskPersistence(database),
      requirePreviewAcceptance: false,
    ).init();
    appServices.put(jobs);
    surface =
        appServices.put<SurfaceRuntime>(_ClosingSurface()) as _ClosingSurface;
    appServices.put<SurfaceWorkerFirstFrameWaiter>(gate);
    llm = _SourceLlm(game: game);
    runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Test companion',
        avatar: '',
        bio: 'test',
        personalityTraits: const [],
        catchphrase: 'ok',
      ),
      llmClient: llm,
      prepareTtsForNewTurn: (_) async {},
    );
    addTearDown(() async {
      final drained = runtime.retireAndDrain();
      gate.ready();
      await drained.timeout(const Duration(seconds: 4));
      await jobs.deactivateAndDrain();
      await database.close();
    });
  }

  Future<void> start({bool game = true}) async {
    final ack = await runtime.chat(
      game ? '生成一个点按计分小游戏' : '创建一个计数器小程序',
      const [],
    );
    expect(ack.isSuccess, isTrue);
    await gate.started.future.timeout(const Duration(seconds: 4));
  }
}

Future<void> _until(bool Function() predicate) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > const Duration(seconds: 4)) {
      throw TimeoutException('Delivery boundary did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => call.method == 'getLanguages'
              ? ['zh-CN']
              : call.method == 'getVoices'
              ? <Object>[]
              : 1,
        );
  });
  tearDown(() async {
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  test('production account mount starts validation without a preview tap', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('final taskJobs = await putOwnedAsync(');
    expect(start, greaterThanOrEqualTo(0));
    final registration = source.substring(
      start,
      source.indexOf('requireMountCurrent();', start),
    );
    expect(registration, contains('requirePreviewAcceptance: false'));
  });

  test(
    'automatic game remains uncommitted until a real-frame result then returns to chat',
    () async {
      final f = _DeliveryFixture();
      await f.init();
      var confirmations = 0;
      appServices.put<AppletSaveConfirmation>((_) async {
        confirmations++;
        return true;
      });
      await f.start();
      final job = f.jobs.jobs.single;
      expect(job.status, AgentTaskJobStatus.running);
      expect(job.stage, AgentTaskStage.validating);
      expect(
        job.progress.any((p) => p.stage == AgentTaskStage.previewReady),
        isFalse,
      );
      expect(f.surface.isVisible.value, isTrue);
      expect(
        isAppletPresentationPending((await f.database.getAllWidgets()).single),
        isTrue,
      );
      f.gate.ready();
      await _until(
        () => f.jobs.byId(job.id)?.status == AgentTaskJobStatus.completed,
      );
      await f.jobs.flush();
      final saved = (await f.database.getAllWidgets()).single;
      expect(isAppletPresentationPending(saved), isFalse);
      expect(f.jobs.byId(job.id)!.widgetId, saved.id);
      expect(f.surface.isVisible.value, isFalse);
      expect(f.surface.closedSessions, [f.gate.session]);
      expect(confirmations, 0);
      final cards = (await f.database.getMessages(
        'self',
      )).where((row) => row.taskReference != null).toList();
      expect(cards, hasLength(1));
      expect(cards.single.taskReference!.taskId, job.taskId);
      await f.surface.show(surfaceProjectFromWidget(saved));
      expect(f.surface.isVisible.value, isTrue);
      expect(f.surface.activeProject.value!.kind, SurfaceKind.fullscreen);
      expect(
        f.surface.activeProject.value!.experienceType,
        SurfaceExperienceType.game,
      );
    },
  );

  test(
    'fatal runtime validation never yields a completed game or saved result',
    () async {
      final f = _DeliveryFixture();
      await f.init();
      await f.start();
      f.gate.result.completeError(
        const SurfaceWorkerFirstFrameException.fatal(
          SurfaceWorkerFatalReason.webViewLoadFailed,
        ),
      );
      await _until(
        () => f.jobs.jobs.single.status == AgentTaskJobStatus.failed,
      );
      expect(await f.database.getAllWidgets(), isEmpty);
      expect(f.surface.isVisible.value, isFalse);
      expect(f.jobs.jobs.single.widgetId, isNull);
    },
  );

  test(
    'cancel while validating compensates the candidate and never completes',
    () async {
      final f = _DeliveryFixture();
      await f.init();
      await f.start();
      final job = f.jobs.jobs.single;
      await f.runtime.cancelBackgroundTaskJob(
        job.id,
        expectedAttempt: job.attempt,
      );
      f.gate.ready();
      await f.runtime.retireAndDrain();
      expect(f.jobs.byId(job.id)!.status, AgentTaskJobStatus.cancelled);
      expect(await f.database.getAllWidgets(), isEmpty);
      expect(f.surface.isVisible.value, isFalse);
    },
  );

  test(
    'account change before the frame receipt cannot publish the old candidate',
    () async {
      appServices.put<SecureStorageService>(_MemoryStorage());
      appServices.put(AppEnvironmentService());
      final auth = appServices.put(
        AuthSessionService(
          httpClient: MockClient((_) async => throw StateError('No network')),
        ),
      );
      auth.session.value = _session('first-owner');
      final f = _DeliveryFixture();
      await f.init();
      await f.start();
      auth.session.value = _session('next-owner');
      f.gate.ready();
      await f.runtime.retireAndDrain();
      expect(f.jobs.jobs.single.status, AgentTaskJobStatus.cancelled);
      expect(await f.database.getAllWidgets(), isEmpty);
    },
  );

  test(
    'delivery closes the exact validation runtime, preserving a replacement host session',
    () async {
      final f = _DeliveryFixture();
      await f.init();
      final next = SurfaceRuntime();
      f.database.afterCommit = () async {
        await next.show(
          SurfaceProject(
            id: 'new-owner-game',
            title: 'Newer game',
            kind: SurfaceKind.fullscreen,
            rendering: SurfaceRendering.canvas,
            transparent: false,
            placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
            manifest: const SurfaceManifest(),
            backend: const {},
            revisions: const [],
            html: '<main>Newer view</main>',
            css: '',
            js: 'window.ready=true;',
          ),
        );
        expect(next.activeSession, f.gate.session);
        appServices.put<SurfaceRuntime>(next, overrideAbstract: true);
      };
      await f.start();
      f.gate.ready();
      await _until(
        () => f.jobs.jobs.single.status == AgentTaskJobStatus.completed,
      );
      expect(next.isVisible.value, isTrue);
      expect(next.activeSurfaceId, 'new-owner-game');
      expect(f.surface.isVisible.value, isFalse);
      expect(f.surface.closedSessions, [f.gate.session]);
      expect(await f.database.getAllWidgets(), hasLength(1));
    },
  );

  test(
    'presentation cleanup failure cannot overturn a committed completion receipt',
    () async {
      final f = _DeliveryFixture();
      await f.init();
      f.surface.failClose = true;
      await f.start();
      f.gate.ready();
      await _until(
        () => f.jobs.jobs.single.status == AgentTaskJobStatus.completed,
      );
      final saved = (await f.database.getAllWidgets()).single;
      expect(isAppletPresentationPending(saved), isFalse);
      expect(f.jobs.jobs.single.widgetId, saved.id);
      expect(f.surface.closedSessions, [f.gate.session]);
    },
  );

  test(
    'utility preview still requires its save confirmation and remains presented',
    () async {
      final f = _DeliveryFixture();
      await f.init(game: false);
      final decision = Completer<bool>();
      var asked = 0;
      appServices.put<AppletSaveConfirmation>((_) {
        asked++;
        return decision.future;
      });
      await f.start(game: false);
      f.gate.ready();
      await _until(() => asked == 1);
      expect(f.jobs.jobs.single.status, AgentTaskJobStatus.running);
      expect(await f.database.getAllWidgets(), isEmpty);
      decision.complete(true);
      await _until(
        () => f.jobs.jobs.single.status == AgentTaskJobStatus.completed,
      );
      expect(f.surface.isVisible.value, isTrue);
      expect(f.surface.closedSessions, isEmpty);
      expect(
        (await f.database.getAllWidgets()).single.spec['experienceType'],
        'utility',
      );
    },
  );
}
