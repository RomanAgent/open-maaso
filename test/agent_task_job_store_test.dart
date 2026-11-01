import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:maaso/src/features/project_build/domain/project_build_task_binding.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';

void main() {
  setUp(() => AppLocalization.updateLocale(const Locale('zh', 'CN')));

  group('public execution progress', () {
    late AgentTaskJobStore store;
    late AgentTaskJob job;

    setUp(() {
      store = AgentTaskJobStore();
      job = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '创建五子棋',
        appletScopeKey: 'device-legacy',
      );
    });
    tearDown(() => store.onClose());

    AgentTaskJob record({
      String? id,
      int expectedAttempt = 1,
      AgentTaskStage stage = AgentTaskStage.validating,
      String description = '检查游戏操作契约',
      String details = '已检查声明的操作与事件。',
      List<AgentTaskEvidence> evidence = const [],
    }) => store.recordProgress(
      id ?? job.id,
      expectedAttempt: expectedAttempt,
      stage: stage,
      description: description,
      details: details,
      evidence: evidence,
    );

    test('records typed facts, deduplicates and freezes the snapshot', () {
      final evidence = [
        const AgentTaskEvidence(
          kind: AgentTaskEvidenceKind.validation,
          outcome: AgentTaskEvidenceOutcome.passed,
          label: '操作契约',
          count: 4,
          reference: 'surface-1',
        ),
      ];
      final events = <AgentTaskJobEvent>[];
      final subscription = store.events.listen(events.add);
      addTearDown(subscription.cancel);
      final updated = record(evidence: evidence);
      final repeated = record(evidence: evidence);

      expect(repeated, same(updated));
      expect(events, hasLength(1));
      expect(events.single.type, AgentTaskJobEventType.progress);
      evidence.clear();
      expect(updated.progress.last.evidence.single.count, 4);
      expect(updated.progress.last.hasDetails, isTrue);
      expect(() => updated.progress.clear(), throwsUnsupportedError);
      expect(
        () => updated.progress.last.evidence.clear(),
        throwsUnsupportedError,
      );

      final next = record(description: '检查首屏控件');
      expect(next.progress.map((item) => item.sequence), [1, 2, 3]);
      expect(next.progress[1].description, '检查游戏操作契约');
      expect(next.progress.last.description, '检查首屏控件');
      expect(job.progress, hasLength(1));
    });

    test(
      'requires the current running attempt and cannot invent completion',
      () {
        expect(record(expectedAttempt: 2), same(store.byId(job.id)));
        expect(
          () => record(stage: AgentTaskStage.completed),
          throwsArgumentError,
        );
        expect(store.byId(job.id)!.progress, hasLength(1));
        store.awaitInput(job.id, '请选择模式');
        final waiting = store.byId(job.id)!;
        expect(record(), same(waiting));
        store.resume(job.id);
        store.requestCancel(job.id);
        final cancelling = store.byId(job.id)!;
        expect(record(), same(cancelling));
        store.fail(job.id, 'validation_failed');
        final failed = store.byId(job.id)!;
        final retry = store.retry(job.id);
        expect(record(), same(failed));
        expect(record(id: retry.id), same(store.byId(retry.id)));
        final current = record(id: retry.id, expectedAttempt: 2);
        expect(current.progress, hasLength(2));
        store.complete(retry.id);
        final completed = store.byId(retry.id)!;
        expect(record(id: retry.id, expectedAttempt: 2), same(completed));
        expect(store.byId(job.id), same(failed));
      },
    );

    test('rejects unbounded public payloads without changing state', () {
      final before = store.byId(job.id);
      final invalid = <void Function()>[
        () => record(description: ' '),
        () => record(description: 'a' * 161),
        () => record(description: 'line\nbreak'),
        () => record(description: 'control\u202eoverride'),
        () => record(details: 'a' * 2001),
        () => record(details: 'control\u0000data'),
        () => record(
          evidence: List.filled(
            9,
            const AgentTaskEvidence(
              kind: AgentTaskEvidenceKind.validation,
              outcome: AgentTaskEvidenceOutcome.passed,
              label: '检查',
            ),
          ),
        ),
        () => record(
          evidence: [
            AgentTaskEvidence(
              kind: AgentTaskEvidenceKind.validation,
              outcome: AgentTaskEvidenceOutcome.passed,
              label: 'a' * 121,
            ),
          ],
        ),
        () => record(
          evidence: const [
            AgentTaskEvidence(
              kind: AgentTaskEvidenceKind.execution,
              outcome: AgentTaskEvidenceOutcome.completed,
              label: '已返回结果',
              count: -1,
            ),
          ],
        ),
        () => record(
          evidence: const [
            AgentTaskEvidence(
              kind: AgentTaskEvidenceKind.artifact,
              outcome: AgentTaskEvidenceOutcome.completed,
              label: '已保存',
              reference: 'https://example.com/private',
            ),
          ],
        ),
      ];
      for (final action in invalid) {
        expect(action, throwsArgumentError);
        expect(store.byId(job.id), same(before));
      }
    });

    test('legacy JSON round trips while malformed additions fail closed', () {
      final original = job.toJson();
      final legacy = AgentTaskJob.tryParse(original)!;
      expect(legacy.progress.single.description, isEmpty);
      expect(legacy.progress.single.details, isEmpty);
      expect(legacy.progress.single.evidence, isEmpty);
      expect(legacy.toJson(), original);
      final oldEvent = Map<String, Object?>.from(
        (original['progress'] as List).single as Map,
      );
      const validEvidence = {
        'kind': 'validation',
        'outcome': 'passed',
        'label': '操作契约',
      };
      final malformed = <Map<String, Object?>>[
        {'description': null},
        {'details': 7},
        {'evidence': null},
        {'description': 'a' * 161},
        {'details': 'a' * 2001},
        {'evidence': List.filled(9, validEvidence)},
        {
          'evidence': [
            {...validEvidence, 'kind': 'modelReasoning'},
          ],
        },
        {
          'evidence': [
            {...validEvidence, 'outcome': 'probablyPassed'},
          ],
        },
        {
          'evidence': [
            {...validEvidence, 'rawResponse': 'private'},
          ],
        },
        {
          'evidence': [
            {...validEvidence, 'count': 1.5},
          ],
        },
        {
          'evidence': [
            {...validEvidence, 'count': 1000001},
          ],
        },
        {
          'evidence': [
            {...validEvidence, 'reference': '../private'},
          ],
        },
        {'rawToolOutput': 'private'},
      ];
      for (final addition in malformed) {
        expect(
          AgentTaskJob.tryParse({
            ...original,
            'progress': [
              {...oldEvent, ...addition},
            ],
          }),
          isNull,
          reason: addition.keys.join(','),
        );
      }
      expect(
        AgentTaskJob.tryParse({
          ...original,
          'progress': [
            oldEvent,
            {...oldEvent, 'sequence': 3},
          ],
        }),
        isNull,
      );
    });
  });

  test('tracks generated task jobs independently from chat turns', () {
    final store = AgentTaskJobStore();

    final job = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: '创建五子棋',
    );

    expect(job.id, isNotEmpty);
    expect(job.status, AgentTaskJobStatus.running);
    expect(store.latestForAgent('self')?.id, job.id);

    final completed = store.complete(job.id, summary: 'surface opened');

    expect(completed.status, AgentTaskJobStatus.completed);
    expect(completed.summary, 'surface opened');
    expect(store.byId(job.id)?.status, AgentTaskJobStatus.completed);
  });

  test('emits lifecycle events and summarizes the latest job status', () async {
    final store = AgentTaskJobStore();
    final events = <AgentTaskJobEvent>[];
    final sub = store.events.listen(events.add);
    addTearDown(sub.cancel);

    final job = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.surfaceGeneration,
      userText: '做一个透明时钟组件',
    );

    expect(store.latestStatusText('self'), contains('生成中'));

    final completed = store.complete(job.id, summary: 'surface opened');
    await pumpEventQueue();

    expect(completed.status, AgentTaskJobStatus.completed);
    expect(store.latestStatusText('self'), contains('已经生成好了'));
    expect(events.map((event) => event.type), [
      AgentTaskJobEventType.started,
      AgentTaskJobEventType.completed,
    ]);
    expect(events.last.job.id, job.id);
  });

  test('retries failed generated jobs with attempt metadata', () async {
    final store = AgentTaskJobStore();
    final events = <AgentTaskJobEvent>[];
    final sub = store.events.listen(events.add);
    addTearDown(sub.cancel);

    final job = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: '生成雷霆战机',
    );
    final failed = store.fail(job.id, 'validator rejected empty surface');

    expect(failed.status, AgentTaskJobStatus.failed);
    expect(store.latestStatusText('self'), contains('生成失败'));

    final retry = store.retry(job.id);
    await pumpEventQueue();

    expect(retry.status, AgentTaskJobStatus.running);
    expect(retry.parentJobId, job.id);
    expect(retry.attempt, 2);
    expect(retry.taskKind, job.taskKind);
    expect(retry.userText, job.userText);
    expect(store.latestForAgent('self')?.id, retry.id);
    expect(events.map((event) => event.type), [
      AgentTaskJobEventType.started,
      AgentTaskJobEventType.failed,
      AgentTaskJobEventType.retried,
    ]);
  });

  test('cancels a running generated job and emits status text', () async {
    final store = AgentTaskJobStore();
    final events = <AgentTaskJobEvent>[];
    final sub = store.events.listen(events.add);
    addTearDown(sub.cancel);

    final job = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: '生成五子棋',
    );

    final cancelled = store.cancel(job.id);
    await pumpEventQueue();

    expect(cancelled.status, AgentTaskJobStatus.cancelled);
    expect(store.latestStatusText('self'), contains('已取消'));
    expect(events.map((event) => event.type), [
      AgentTaskJobEventType.started,
      AgentTaskJobEventType.cancelled,
    ]);
  });

  test('running cancellation settles only after cleanup completes', () async {
    final store = AgentTaskJobStore();
    final events = <AgentTaskJobEvent>[];
    final sub = store.events.listen(events.add);
    addTearDown(sub.cancel);
    final job = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: '生成五子棋',
    );

    final cancelling = store.requestCancel(job.id);

    expect(cancelling.status, AgentTaskJobStatus.cancelling);
    expect(store.statusText(cancelling), contains('正在安全取消'));
    expect(store.complete(job.id).status, AgentTaskJobStatus.cancelling);
    expect(store.retry(job.id).id, job.id);

    final cancelled = store.cancel(job.id);
    await pumpEventQueue();

    expect(cancelled.status, AgentTaskJobStatus.cancelled);
    expect(events.map((event) => event.type), [
      AgentTaskJobEventType.started,
      AgentTaskJobEventType.cancelling,
      AgentTaskJobEventType.cancelled,
    ]);
  });

  test('a committed presentation receipt wins a racing cancellation', () {
    final store = AgentTaskJobStore();
    final job = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: '生成五子棋',
    );

    store.requestCancel(job.id);
    final completed = store.completeCommittedPresentation(
      job.id,
      summary: 'surface committed',
    );

    expect(completed.status, AgentTaskJobStatus.completed);
    expect(completed.summary, 'surface committed');
  });

  test(
    'awaits input and resumes the same scoped job before completion',
    () async {
      final store = AgentTaskJobStore();
      final events = <AgentTaskJobEvent>[];
      final sub = store.events.listen(events.add);
      addTearDown(sub.cancel);

      final job = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '生成五子棋',
        appletScopeKey: 'test|owner-a',
      );

      final awaiting = store.awaitInput(job.id, '请选择双人对战或人机对战');

      expect(awaiting.id, job.id);
      expect(awaiting.attempt, job.attempt);
      expect(awaiting.status, AgentTaskJobStatus.awaitingInput);
      expect(awaiting.pendingPrompt, '请选择双人对战或人机对战');
      expect(awaiting.appletScopeKey, 'test|owner-a');
      expect(
        store.latestStatusText('self', appletScopeKey: 'test|owner-a'),
        contains('请选择双人对战或人机对战'),
      );

      final resumed = store.resume(job.id);
      expect(resumed.id, job.id);
      expect(resumed.attempt, job.attempt);
      expect(resumed.status, AgentTaskJobStatus.running);
      expect(resumed.pendingPrompt, isEmpty);

      final completed = store.complete(job.id, summary: 'surface opened');
      await pumpEventQueue();

      expect(completed.status, AgentTaskJobStatus.completed);
      expect(events.map((event) => event.type), [
        AgentTaskJobEventType.started,
        AgentTaskJobEventType.awaitingInput,
        AgentTaskJobEventType.resumed,
        AgentTaskJobEventType.completed,
      ]);
      expect(events.map((event) => event.job.id).toSet(), {job.id});
    },
  );

  test(
    'stale lifecycle transitions cannot overwrite awaiting or cancelled jobs',
    () async {
      final store = AgentTaskJobStore();
      final events = <AgentTaskJobEvent>[];
      final sub = store.events.listen(events.add);
      addTearDown(sub.cancel);

      final job = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '生成天气卡片',
        appletScopeKey: 'test|owner-a',
      );
      store.awaitInput(job.id, '请选择城市');

      expect(store.complete(job.id).status, AgentTaskJobStatus.awaitingInput);
      expect(
        store.fail(job.id, 'late worker failure').status,
        AgentTaskJobStatus.awaitingInput,
      );
      expect(store.retry(job.id).id, job.id);
      expect(store.jobs, hasLength(1));

      final cancelled = store.cancel(job.id);
      expect(cancelled.status, AgentTaskJobStatus.cancelled);
      expect(cancelled.pendingPrompt, isEmpty);
      expect(store.resume(job.id).status, AgentTaskJobStatus.cancelled);
      expect(store.complete(job.id).status, AgentTaskJobStatus.cancelled);
      expect(
        store.fail(job.id, 'stale failure').status,
        AgentTaskJobStatus.cancelled,
      );
      expect(
        store.awaitInput(job.id, 'stale prompt').status,
        AgentTaskJobStatus.cancelled,
      );
      await pumpEventQueue();

      expect(events.map((event) => event.type), [
        AgentTaskJobEventType.started,
        AgentTaskJobEventType.awaitingInput,
        AgentTaskJobEventType.cancelled,
      ]);
    },
  );

  test('local retry eligibility never grants server-backed operations', () {
    final now = DateTime(2026);
    AgentTaskJob job(
      AgentTaskKind kind,
      AgentTaskJobStatus status, {
      CreatorImageTaskBinding? image,
      ProjectBuildTaskBinding? project,
      ProjectBuildV2TaskBinding? projectV2,
    }) => AgentTaskJob(
      id: 'retry-policy',
      agentId: 'self',
      taskKind: kind,
      userText: 'make a game',
      status: status,
      createdAt: now,
      serverImage: image,
      projectBuild: project,
      projectBuildV2: projectV2,
    );
    const allowed = <AgentTaskKind, Set<AgentTaskJobStatus>>{
      AgentTaskKind.none: {AgentTaskJobStatus.failed},
      AgentTaskKind.skillTask: {AgentTaskJobStatus.failed},
      AgentTaskKind.gameGeneration: {
        AgentTaskJobStatus.failed,
        AgentTaskJobStatus.cancelled,
      },
      AgentTaskKind.surfaceGeneration: {
        AgentTaskJobStatus.failed,
        AgentTaskJobStatus.cancelled,
      },
    };
    for (final kind in AgentTaskKind.values) {
      for (final status in AgentTaskJobStatus.values) {
        expect(
          job(kind, status).canRetryLocally,
          allowed[kind]!.contains(status),
          reason: '$kind/$status',
        );
        final serverJobs = [
          job(
            kind,
            status,
            image: const CreatorImageTaskBinding(
              creatorScopeKey: 'scope',
              draftId: 'draft',
              draftFingerprint: 'fingerprint',
              createRequestId: 'retry-policy-request',
              input: CreatorTaskImageInput(
                prompt: 'a tree',
                aspectRatio: '1:1',
                style: 'natural',
              ),
            ),
          ),
          job(
            kind,
            status,
            project: ProjectBuildTaskBinding(
              scopeKey: 'scope',
              createRequestId: 'retry-policy-request',
            ),
          ),
          job(
            kind,
            status,
            projectV2: ProjectBuildV2TaskBinding(
              scopeKey: 'scope',
              createRequestId: 'retry-policy-request',
            ),
          ),
        ];
        for (final server in serverJobs) {
          expect(server.isServerBacked, isTrue);
          expect(server.canRetryLocally, isFalse);
        }
      }
    }
  });

  test(
    'retry forks only failed jobs or explicitly cancelled local generation',
    () async {
      final store = AgentTaskJobStore();
      final events = <AgentTaskJobEvent>[];
      final sub = store.events.listen(events.add);
      addTearDown(sub.cancel);

      final running = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '生成五子棋',
      );
      expect(store.retry(running.id).id, running.id);
      expect(store.jobs, hasLength(1));

      store.complete(running.id, summary: 'surface opened');
      expect(store.retry(running.id).id, running.id);
      expect(store.jobs, hasLength(1));

      final cancelled = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '生成天气卡片',
      );
      store.cancel(cancelled.id);
      final resumed = store.retry(cancelled.id);
      expect(resumed.id, isNot(cancelled.id));
      expect(resumed.taskId, cancelled.taskId);
      expect(resumed.attempt, 2);
      expect(store.byId(cancelled.id)!.status, AgentTaskJobStatus.cancelled);
      expect(
        store.retry(cancelled.id).id,
        cancelled.id,
        reason: 'older attempt remains fenced',
      );
      expect(store.jobs, hasLength(3));

      final awaiting = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '生成象棋',
      );
      store.awaitInput(awaiting.id, '请选择双人或人机');
      expect(store.retry(awaiting.id).id, awaiting.id);
      expect(store.jobs, hasLength(4));

      final failed = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '生成俄罗斯方块',
      );
      store.fail(failed.id, 'validation failed');
      final retry = store.retry(failed.id);
      await pumpEventQueue();

      expect(retry.id, isNot(failed.id));
      expect(retry.parentJobId, failed.id);
      expect(retry.status, AgentTaskJobStatus.running);
      expect(store.jobs, hasLength(6));
      expect(
        events.where((event) => event.type == AgentTaskJobEventType.retried),
        hasLength(2),
      );
    },
  );

  test('filters latest jobs by applet scope and preserves scope on retry', () {
    final store = AgentTaskJobStore();

    final scopeA = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: '生成五子棋',
      appletScopeKey: 'test|owner-a',
    );
    final scopeB = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.surfaceGeneration,
      userText: '生成时钟',
      appletScopeKey: 'test|owner-b',
    );

    expect(store.latestForAgent('self')?.id, scopeB.id);
    expect(
      store.latestForAgent('self', appletScopeKey: 'test|owner-a')?.id,
      scopeA.id,
    );
    expect(
      store.latestForAgent('self', appletScopeKey: 'test|owner-b')?.id,
      scopeB.id,
    );
    expect(
      store.latestForAgent('self', appletScopeKey: 'test|owner-c'),
      isNull,
    );

    store.fail(scopeA.id, 'failed');
    final retry = store.retry(scopeA.id);
    expect(retry.appletScopeKey, 'test|owner-a');
    expect(retry.parentJobId, scopeA.id);
    expect(retry.attempt, 2);
  });

  test('filters the latest scoped job by lifecycle status', () {
    final store = AgentTaskJobStore();
    final scope = 'test|owner-a';
    final earlier = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: '生成五子棋',
      appletScopeKey: scope,
    );
    final later = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.surfaceGeneration,
      userText: '生成天气卡片',
      appletScopeKey: scope,
    );
    store.complete(later.id, summary: 'surface opened');
    store.awaitInput(earlier.id, '请选择双人或人机');

    expect(store.latestForAgent('self', appletScopeKey: scope)?.id, later.id);
    expect(
      store
          .latestForAgent(
            'self',
            appletScopeKey: scope,
            statuses: const {AgentTaskJobStatus.awaitingInput},
          )
          ?.id,
      earlier.id,
    );
    expect(
      store.latestForAgent(
        'self',
        appletScopeKey: scope,
        statuses: const {AgentTaskJobStatus.failed},
      ),
      isNull,
    );
  });

  test('status-filtered lookup follows the latest lifecycle event', () async {
    final store = AgentTaskJobStore();
    const scope = 'test|owner-a';
    final earlier = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.gameGeneration,
      userText: '生成五子棋',
      appletScopeKey: scope,
    );
    final later = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.surfaceGeneration,
      userText: '生成天气卡片',
      appletScopeKey: scope,
    );

    store.awaitInput(later.id, '请选择城市');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    store.awaitInput(earlier.id, '请选择双人或人机');

    expect(
      store
          .latestForAgent(
            'self',
            appletScopeKey: scope,
            statuses: const {AgentTaskJobStatus.awaitingInput},
          )
          ?.id,
      earlier.id,
    );

    store.cancel(earlier.id);
    expect(
      store
          .latestForAgent(
            'self',
            appletScopeKey: scope,
            statuses: const {AgentTaskJobStatus.awaitingInput},
          )
          ?.id,
      later.id,
    );
  });
}
