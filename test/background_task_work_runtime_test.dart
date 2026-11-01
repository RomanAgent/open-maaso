import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';

import 'project_build_v2_delivery_test.dart' as delivery;

class _HostAvatar extends AvatarRuntime {
  final work = <(String, AvatarBackgroundTaskWorkPhase)>[];
  @override
  final isReady = true.obs;
  @override
  final presentationReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  @override
  bool get supportsHostBackgroundTaskWorkPresentation => true;
  @override
  Future<AvatarBackgroundTaskWorkResult> setBackgroundTaskWork({
    required String sessionId,
    required AvatarBackgroundTaskWorkPhase phase,
  }) async {
    work.add((sessionId, phase));
    return const AvatarBackgroundTaskWorkResult(
      AvatarBackgroundTaskWorkDisposition.applied,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _NoGenerationModel implements LLMClient {
  int calls = 0;
  String? semanticReply;
  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    calls++;
    final reply = semanticReply;
    if (reply == null) throw StateError('Unexpected foreground model call');
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode({'delta': reply}),
    );
  }

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('A V2 task must not run foreground generation');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late delivery.Harness harness;
  late _HostAvatar avatar;
  late _NoGenerationModel model;
  late AgentRuntime runtime;
  late GoRouter router;
  late bool previousSound;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          if (call.method == 'getLanguages') return ['en-US'];
          if (call.method == 'getVoices') return <Object>[];
          return 1;
        });
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
    appServices.put(SecureStorageService());
    appServices.put(MaasoAgentModeService()).pipelineMode.value =
        AgentPipelineMode.proxyDefault;
    router = GoRouter(
      initialLocation: AppRouteCatalog.home,
      routes: [
        GoRoute(
          path: AppRouteCatalog.home,
          builder: (_, _) => const SizedBox.shrink(),
        ),
      ],
    );
    await router.routerDelegate.setNewRoutePath(
      router.configuration.findMatch(Uri.parse(AppRouteCatalog.home)),
    );
    appNavigation.configure(router);
    avatar = _HostAvatar();
    appServices.put(ActiveAvatarRuntime()).register(avatar);
    harness = delivery.Harness(appletScope: 'device-legacy');
    await harness.init();
    // Synthetic gateway stays queued until this test applies genuine typed
    // journal events. No bundle is installed, shown, or saved as a user work.
    harness.specialRequest = (request) async {
      if (request.method == 'POST') {
        harness.head = 1;
        final body = projectBuildV2Object(jsonDecode(request.body));
        return delivery.ok({
          ...projectBuildV2Object(harness.f['createReceipt']),
          'requestId': body['requestId'],
        });
      }
      return null;
    };
    appServices.put(harness.db);
    final flags = appServices.put(
      MaasoFeatureFlagService(
        store: SembastMaasoFeatureFlagAssignmentStore(harness.db),
      ),
    );
    expect(
      flags.effectiveMode(MaasoFeatureFlag.avatarProjectionV2),
      FeatureRolloutMode.off,
    );
    appServices.put(harness.jobs);
    appServices.put(harness.tasks);
    model = _NoGenerationModel();
    runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Test',
        avatar: '',
        bio: '',
        personalityTraits: [],
        catchphrase: '',
      ),
      llmClient: model,
      prepareTtsForNewTurn: (_) async {},
    );
    await runtime.init();
    previousSound = MaasoTtsPlugin.soundEnabled.value;
    MaasoTtsPlugin.soundEnabled.value = false;
  });
  tearDown(() async {
    await runtime.retireAndDrain();
    await harness.close();
    router.dispose();
    await appServices.reset();
    MaasoTtsPlugin.soundEnabled.value = previousSound;
  });

  Future<AgentTaskJob> start() async {
    final result = await runtime.chat('帮我制作一个待办清单小程序', const []);
    expect(result.isSuccess, isTrue);
    expect(model.calls, 0);
    final job = harness.jobs.jobs.single;
    expect(job.isProjectBuildV2, isTrue);
    await harness.tasks.synchronize(job.taskId);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return harness.jobs.byId(job.id)!;
  }

  void apply(AgentTaskJob job, Map<String, Object?> event) {
    harness.jobs.applyProjectBuildV2Event(
      job.taskId,
      ProjectBuildV2Event.fromJson(event),
      expectedScopeKey: harness.appletScope,
      agentId: 'self',
    );
  }

  Future<void> flushBodyMicrotasks() async {
    // Intentionally shorter than the controller's 250ms retirement watchdog:
    // the Runtime's synchronous store listener must end the exact owner now.
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> finishWriting(
    AgentTaskJob job,
    Map<String, Object?> fixture,
  ) async {
    await harness.tasks.synchronize(job.taskId);
    apply(job, delivery.events(fixture)[1]);
    apply(job, delivery.events(fixture)[2]);
    await flushBodyMicrotasks();
    expect(harness.jobs.byId(job.id)!.status, AgentTaskJobStatus.awaitingInput);
  }

  Future<({AgentTaskJob job, Map<String, Object?> fixture})>
  startSecond() async {
    final snapshot = projectBuildV2Object(harness.f['snapshot']);
    final taskId = snapshot['taskId'] as String;
    final runId = snapshot['runId'] as String;
    final secondTaskId = '${taskId.substring(0, taskId.length - 2)}15';
    final secondRunId = '${runId.substring(0, runId.length - 2)}16';
    // The second fake gateway task has independent opaque task/run identities.
    // Bundle contents are never fetched or evaluated by this lifecycle test.
    final secondFixture = projectBuildV2Object(
      jsonDecode(
        jsonEncode(
          harness.f,
        ).replaceAll(taskId, secondTaskId).replaceAll(runId, secondRunId),
      ),
    );
    harness.specialRequest = (request) async {
      if (request.method == 'POST') {
        final body = projectBuildV2Object(jsonDecode(request.body));
        return delivery.ok({
          ...projectBuildV2Object(secondFixture['createReceipt']),
          'requestId': body['requestId'],
        });
      }
      if (request.url.path.contains(secondTaskId)) {
        if (request.url.path.endsWith('/events')) {
          final after = int.parse(
            request.url.queryParameters['afterTaskSequence']!,
          );
          return delivery.ok({
            'events': delivery.events(secondFixture).sublist(after, 1),
            'nextTaskSequence': 1,
            'hasMore': false,
          });
        }
        return delivery.ok(delivery.events(secondFixture).first['snapshot']);
      }
      return null;
    };
    final result = await runtime.chat('制作一个独立的月相日历小程序', const []);
    expect(result.isSuccess, isTrue);
    await flushBodyMicrotasks();
    expect(harness.jobs.jobs, hasLength(2));
    final job = harness.jobs.jobs.last;
    await harness.tasks.synchronize(job.taskId);
    return (job: job, fixture: secondFixture);
  }

  Future<AgentTaskJob> prepareSoloRetry() async {
    final job = await start();
    final original = delivery.events(harness.f);
    final failedSnapshot = projectBuildV2Object(original[2]['snapshot'])
      ..remove('candidate');
    final failedEvent = {
      ...original[2],
      'type': 'run.failed',
      'snapshot': {
        ...failedSnapshot,
        'status': 'failed',
        'errorCode': 'worker_failed',
      },
    };
    final runId = failedSnapshot['runId'] as String;
    final retryRunId = '${runId.substring(0, runId.length - 2)}36';
    final wireEvents = [
      ...original.take(2),
      failedEvent,
      {
        ...original[2],
        'type': 'run.retried',
        'runId': retryRunId,
        'sequence': 1,
        'taskSequence': 4,
        'at': '2026-09-28T08:00:03Z',
        'snapshot': {
          ...failedSnapshot,
          'runId': retryRunId,
          'attempt': 2,
          'status': 'queued',
          'statusVersion': 1,
          'snapshotSequence': 1,
          'snapshotTaskSequence': 4,
          'updatedAt': '2026-09-28T08:00:03Z',
          'errorCode': '',
        },
      },
      for (final index in [1, 2])
        {
          ...original[index],
          'runId': retryRunId,
          'taskSequence': index + 4,
          'at': '2026-09-28T08:00:0${index + 3}Z',
          'snapshot': {
            ...projectBuildV2Object(original[index]['snapshot']),
            'runId': retryRunId,
            'attempt': 2,
            'snapshotTaskSequence': index + 4,
            'updatedAt': '2026-09-28T08:00:0${index + 3}Z',
          },
        },
    ];
    harness.f['eventsPage'] = {'events': wireEvents};
    harness.head = 3;
    await harness.tasks.synchronize(job.taskId);
    await flushBodyMicrotasks();
    final failed = harness.jobs.byId(job.id)!;
    expect(failed.status, AgentTaskJobStatus.failed);
    expect(avatar.work.map((entry) => entry.$2), [
      AvatarBackgroundTaskWorkPhase.start,
      AvatarBackgroundTaskWorkPhase.end,
    ]);
    harness.specialRequest = (request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/retry')) {
        final body = projectBuildV2Object(jsonDecode(request.body));
        harness.head = 4;
        return delivery.ok({
          ...projectBuildV2Object(harness.f['createReceipt']),
          'requestId': body['requestId'],
          'runId': retryRunId,
          'attempt': 2,
          'acceptedTaskSequence': 4,
        });
      }
      return null;
    };
    return failed;
  }

  test(
    'normal off V2 admission starts work once without a model call',
    () async {
      final job = await start();
      expect(avatar.work.map((entry) => entry.$2), [
        AvatarBackgroundTaskWorkPhase.start,
      ]);
      apply(job, delivery.events(harness.f)[1]);
      await flushBodyMicrotasks();
      expect(avatar.work, hasLength(1));
    },
  );

  test(
    'unrelated task events neither end nor replay the current owner',
    () async {
      await start();
      expect(avatar.work, hasLength(1));
      final other = harness.jobs.start(
        agentId: 'another-agent',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: 'Recovered unrelated task',
        appletScopeKey: harness.appletScope,
      );
      harness.jobs.complete(other.id);
      await flushBodyMicrotasks();
      expect(avatar.work, hasLength(1));
    },
  );

  test(
    'foreground conversation Stop does not stop the independent task posture',
    () async {
      final job = await start();
      final session = avatar.work.single.$1;
      await runtime.interruptConversation();
      await flushBodyMicrotasks();
      expect(harness.jobs.byId(job.id)!.status, AgentTaskJobStatus.running);
      expect(avatar.work, [(session, AvatarBackgroundTaskWorkPhase.start)]);
      expect(model.calls, 0);
      apply(job, delivery.events(harness.f)[1]);
      apply(job, delivery.events(harness.f)[2]);
      await flushBodyMicrotasks();
      expect(avatar.work, [
        (session, AvatarBackgroundTaskWorkPhase.start),
        (session, AvatarBackgroundTaskWorkPhase.end),
      ]);
    },
  );

  test('preview-ready V2 job promptly ends work and never replays', () async {
    final job = await start();
    expect(avatar.work, hasLength(1));
    final session = avatar.work.single.$1;
    apply(job, delivery.events(harness.f)[1]);
    apply(job, delivery.events(harness.f)[2]);
    await flushBodyMicrotasks();
    expect(harness.jobs.byId(job.id)!.status, AgentTaskJobStatus.awaitingInput);
    expect(avatar.work, [
      (session, AvatarBackgroundTaskWorkPhase.start),
      (session, AvatarBackgroundTaskWorkPhase.end),
    ]);
    apply(job, delivery.events(harness.f)[3]);
    await flushBodyMicrotasks();
    expect(avatar.work, hasLength(2));
  });

  for (final firstIndex in [0, 1]) {
    test(
      'two concurrent jobs keep one session until both finish writing, first=$firstIndex',
      () async {
        final first = await start();
        final second = await startSecond();
        final session = avatar.work.single.$1;
        expect(avatar.work, [(session, AvatarBackgroundTaskWorkPhase.start)]);
        final jobs = [first, second.job];
        final fixtures = [harness.f, second.fixture];
        await finishWriting(jobs[firstIndex], fixtures[firstIndex]);
        expect(avatar.work, [(session, AvatarBackgroundTaskWorkPhase.start)]);
        expect(
          harness.jobs.byId(jobs[1 - firstIndex].id)!.status,
          AgentTaskJobStatus.running,
        );
        await finishWriting(jobs[1 - firstIndex], fixtures[1 - firstIndex]);
        expect(avatar.work, [
          (session, AvatarBackgroundTaskWorkPhase.start),
          (session, AvatarBackgroundTaskWorkPhase.end),
        ]);
        expect(model.calls, 0);
      },
    );
  }

  test(
    'cancelling one concurrent job preserves the other job work session',
    () async {
      final first = await start();
      final second = await startSecond();
      final session = avatar.work.single.$1;
      apply(first, delivery.events(harness.f)[1]);
      final event = delivery.events(harness.f)[2];
      final snapshot = projectBuildV2Object(event['snapshot'])
        ..remove('candidate');
      apply(first, {
        ...event,
        'type': 'run.cancel_requested',
        'snapshot': {...snapshot, 'status': 'cancelling', 'errorCode': ''},
      });
      await flushBodyMicrotasks();
      expect(
        harness.jobs.byId(second.job.id)!.status,
        AgentTaskJobStatus.running,
      );
      expect(avatar.work, [(session, AvatarBackgroundTaskWorkPhase.start)]);
      await finishWriting(second.job, second.fixture);
      expect(avatar.work, [
        (session, AvatarBackgroundTaskWorkPhase.start),
        (session, AvatarBackgroundTaskWorkPhase.end),
      ]);
      expect(model.calls, 0);
    },
  );

  test('retirement releases a shared multi-job session exactly once', () async {
    await start();
    await startSecond();
    final session = avatar.work.single.$1;
    await runtime.retireAndDrain();
    expect(avatar.work, [
      (session, AvatarBackgroundTaskWorkPhase.start),
      (session, AvatarBackgroundTaskWorkPhase.end),
    ]);
    expect(model.calls, 0);
  });

  for (final semantic in [false, true]) {
    test(
      'solo terminal native retry starts a new session exactly once, semantic=$semantic',
      () async {
        final failed = await prepareSoloRetry();
        final previousSession = avatar.work.first.$1;
        if (semantic) {
          await runtime.retireAndDrain();
          runtime = AgentRuntime(
            agentId: 'self',
            profile: AgentProfile(
              nickname: 'Test',
              avatar: '',
              bio: '',
              personalityTraits: [],
              catchphrase: '',
            ),
            llmClient: model,
            semanticCreationEnabled: true,
            prepareTtsForNewTurn: (_) async {},
          );
          await runtime.init();
          model.semanticReply = jsonEncode({
            'reply': '我继续写。',
            'actions': [
              {'type': 'creation.intent', 'mode': 'retry', 'taskId': failed.id},
            ],
          });
          final result = await runtime.chat('请继续刚才的作品', const []);
          expect(result.isSuccess, isTrue);
          final next = harness.latest(failed.taskId);
          expect(result.stdout, contains(harness.jobs.statusText(next)));
          expect(
            result.stdout,
            isNot(contains(harness.jobs.statusText(failed))),
          );
        } else {
          // Same native controls API used by the task card and Home action.
          final controls = harness.jobs.controlsFor(failed)!;
          expect(await controls.retry(failed.id, expectedAttempt: 1), isTrue);
        }
        await flushBodyMicrotasks();
        final retry = harness.latest(failed.taskId);
        expect(retry.attempt, 2);
        expect(retry.status, AgentTaskJobStatus.running);
        expect(avatar.work, hasLength(3));
        final nextSession = avatar.work.last.$1;
        expect(nextSession, isNot(previousSession));
        expect(avatar.work.last.$2, AvatarBackgroundTaskWorkPhase.start);
        await harness.tasks.synchronize(retry.taskId);
        await flushBodyMicrotasks();
        expect(avatar.work, hasLength(3));
        harness.head = 6;
        await harness.tasks.synchronize(retry.taskId);
        await flushBodyMicrotasks();
        expect(avatar.work.last, (
          nextSession,
          AvatarBackgroundTaskWorkPhase.end,
        ));
        expect(avatar.work, hasLength(4));
        expect(model.calls, semantic ? 1 : 0);
      },
    );
  }

  test(
    'retry joins its live shared session and old attempt replay cannot end it',
    () async {
      final first = await start();
      final second = await startSecond();
      final session = avatar.work.single.$1;
      apply(first, delivery.events(harness.f)[1]);
      final event = delivery.events(harness.f)[2];
      final failedSnapshot = projectBuildV2Object(event['snapshot'])
        ..remove('candidate');
      final failedEvent = {
        ...event,
        'type': 'run.failed',
        'snapshot': {
          ...failedSnapshot,
          'status': 'failed',
          'errorCode': 'worker_failed',
        },
      };
      apply(first, failedEvent);
      await flushBodyMicrotasks();
      final failed = harness.jobs.byId(first.id)!;
      expect(failed.status, AgentTaskJobStatus.failed);
      final pending = ProjectBuildV2TaskPendingCommand(
        operation: ProjectBuildV2TaskOperation.retry,
        requestId: 'shared-work-retry',
        expectedRunId: failed.projectBuildV2!.snapshot!.runId,
        expectedStatusVersion: failed.projectBuildV2!.snapshot!.statusVersion,
        acceptedTaskSequence: 4,
      );
      harness.jobs.updateProjectBuildV2Binding(
        failed.id,
        failed.projectBuildV2!.copyWith(pendingCommand: pending),
        expectedScopeKey: harness.appletScope,
      );
      final runId = failedSnapshot['runId'] as String;
      final retryRunId = '${runId.substring(0, runId.length - 2)}26';
      apply(first, {
        ...event,
        'type': 'run.retried',
        'runId': retryRunId,
        'sequence': 1,
        'taskSequence': 4,
        'at': '2026-09-28T08:00:03Z',
        'snapshot': {
          ...failedSnapshot,
          'runId': retryRunId,
          'attempt': 2,
          'status': 'queued',
          'statusVersion': 1,
          'snapshotSequence': 1,
          'snapshotTaskSequence': 4,
          'updatedAt': '2026-09-28T08:00:03Z',
          'errorCode': '',
        },
      });
      await flushBodyMicrotasks();
      final retry = harness.jobs.jobs.last;
      expect(retry.id, isNot(first.id));
      expect(retry.taskId, first.taskId);
      expect(retry.attempt, 2);
      expect(retry.status, AgentTaskJobStatus.running);
      // Journal replay from attempt 1 cannot remove attempt 2's membership.
      apply(first, failedEvent);
      await finishWriting(second.job, second.fixture);
      expect(avatar.work, [(session, AvatarBackgroundTaskWorkPhase.start)]);
      for (final index in [1, 2]) {
        final next = delivery.events(harness.f)[index];
        final snapshot = projectBuildV2Object(next['snapshot']);
        apply(retry, {
          ...next,
          'runId': retryRunId,
          'taskSequence': index + 4,
          'at': '2026-09-28T08:00:0${index + 3}Z',
          'snapshot': {
            ...snapshot,
            'runId': retryRunId,
            'attempt': 2,
            'snapshotTaskSequence': index + 4,
            'updatedAt': '2026-09-28T08:00:0${index + 3}Z',
          },
        });
      }
      await flushBodyMicrotasks();
      expect(
        harness.jobs.byId(retry.id)!.status,
        AgentTaskJobStatus.awaitingInput,
      );
      expect(avatar.work, [
        (session, AvatarBackgroundTaskWorkPhase.start),
        (session, AvatarBackgroundTaskWorkPhase.end),
      ]);
      expect(model.calls, 0);
    },
  );

  for (final terminal in [
    ('run.failed', 'failed', 'worker_failed', AgentTaskJobStatus.failed),
    ('run.cancel_requested', 'cancelling', '', AgentTaskJobStatus.cancelling),
    ('run.cancelled', 'cancelled', '', AgentTaskJobStatus.cancelled),
  ]) {
    test('V2 ${terminal.$2} promptly ends its owned body work', () async {
      final job = await start();
      expect(avatar.work, hasLength(1));
      final cancelled = terminal.$4 == AgentTaskJobStatus.cancelled;
      if (!cancelled) apply(job, delivery.events(harness.f)[1]);
      final event = delivery.events(harness.f)[cancelled ? 1 : 2];
      final snapshot = projectBuildV2Object(event['snapshot'])
        ..remove('candidate');
      apply(job, {
        ...event,
        'type': terminal.$1,
        'snapshot': {
          ...snapshot,
          'status': terminal.$2,
          'errorCode': terminal.$3,
        },
      });
      await flushBodyMicrotasks();
      expect(harness.jobs.byId(job.id)!.status, terminal.$4);
      expect(avatar.work.map((entry) => entry.$2), [
        AvatarBackgroundTaskWorkPhase.start,
        AvatarBackgroundTaskWorkPhase.end,
      ]);
    });
  }

  test(
    'retirement ends owned V2 work and later progress cannot replay it',
    () async {
      final job = await start();
      expect(avatar.work, hasLength(1));
      await runtime.retireAndDrain();
      expect(avatar.work.map((entry) => entry.$2), [
        AvatarBackgroundTaskWorkPhase.start,
        AvatarBackgroundTaskWorkPhase.end,
      ]);
      apply(job, delivery.events(harness.f)[1]);
      await flushBodyMicrotasks();
      expect(avatar.work, hasLength(2));
    },
  );
}
