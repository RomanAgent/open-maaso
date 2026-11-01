import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/project_build/application/project_build_tasks.dart';
import 'package:maaso/src/features/project_build/data/project_build_gateway.dart';
import 'package:maaso/src/features/project_build/data/project_build_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_build_fixtures.dart';

const _appletScope = 'https://example.invalid|owner';

final class _Server {
  final events = <Map<String, Object?>>[];
  final receipts = <String, Map<String, Object?>>{};
  final posts = <Map<String, Object?>>[];
  final paths = <String>[];
  final cursors = <int>[];
  Future<void> Function(Map<String, Object?>)? beforePost;
  bool loseCreateAck = false;
  bool rejectCreate = false;
  Completer<void>? pauseRead;
  int pageSize = 100;
  void advance(ProjectBuildStatus status, {bool retry = false}) {
    if (events.isEmpty) {
      events.add(projectBuildEvents().first);
      return;
    }
    final old = ProjectBuildEvent.fromJson(events.last);
    final taskSequence = old.taskSequence + 1;
    final at = DateTime.utc(
      2026,
      9,
      28,
      6,
      0,
      taskSequence - 1,
    ).toIso8601String();
    final run = retry ? projectBuildOtherRun : old.runId;
    final sequence = retry ? 1 : old.sequence + 1;
    final type = retry
        ? 'run.retried'
        : switch (status) {
            ProjectBuildStatus.running =>
              old.snapshot.status == ProjectBuildStatus.queued
                  ? 'run.claimed'
                  : 'run.checkpointed',
            ProjectBuildStatus.failed => 'run.failed',
            ProjectBuildStatus.cancelled => 'run.cancelled',
            ProjectBuildStatus.cancelling => 'run.cancel_requested',
            ProjectBuildStatus.queued => 'task.created',
          };
    events.add({
      'taskSequence': taskSequence,
      'sequence': sequence,
      'taskId': old.taskId,
      'runId': run,
      'type': type,
      'at': at,
      'snapshot': {
        ...old.snapshot.toJson(),
        'runId': run,
        'attempt': old.snapshot.attempt + (retry ? 1 : 0),
        'status': status.name,
        'statusVersion': retry ? 1 : old.snapshot.statusVersion + 1,
        'snapshotSequence': sequence,
        'snapshotTaskSequence': taskSequence,
        'updatedAt': at,
        'errorCode': status == ProjectBuildStatus.failed ? 'worker_failed' : '',
      },
    });
  }

  Future<http.Response> handle(http.Request request) async {
    paths.add(request.url.path);
    expect(request.headers['authorization'], 'Bearer synthetic');
    Object data;
    if (request.method == 'POST') {
      final body = projectBuildObject(jsonDecode(request.body));
      await beforePost?.call(body);
      posts.add(body);
      final nonce = body['requestId']! as String;
      if (receipts.containsKey(nonce)) return _ok(receipts[nonce]!);
      if (request.url.path == '/v1/project-builds') {
        if (rejectCreate) {
          return http.Response(jsonEncode({'code': 'CONSENT_REQUIRED'}), 403);
        }
        if (events.isNotEmpty) throw StateError('unexpected second create');
        advance(ProjectBuildStatus.queued);
      } else {
        final head = ProjectBuildEvent.fromJson(events.last).snapshot;
        if (body['expectedRunId'] != head.runId ||
            body['expectedStatusVersion'] != head.statusVersion) {
          return http.Response(
            jsonEncode({'code': 'PROJECT_BUILD_COMMAND_CONFLICT'}),
            409,
          );
        }
        if (request.url.path.endsWith('/retry')) {
          advance(ProjectBuildStatus.queued, retry: true);
        } else {
          advance(
            head.status == ProjectBuildStatus.queued
                ? ProjectBuildStatus.cancelled
                : ProjectBuildStatus.cancelling,
          );
        }
      }
      final head = ProjectBuildEvent.fromJson(events.last);
      data = {
        'requestId': nonce,
        'taskId': head.taskId,
        'runId': head.runId,
        'attempt': head.snapshot.attempt,
        'acceptedTaskSequence': head.taskSequence,
      };
      receipts[nonce] = projectBuildObject(data);
      if (loseCreateAck) {
        loseCreateAck = false;
        throw http.ClientException('ack lost');
      }
    } else {
      await pauseRead?.future;
      final after = int.tryParse(
        request.url.queryParameters['afterTaskSequence'] ?? '',
      );
      if (after != null) {
        cursors.add(after);
        final tail = events
            .where((e) => (e['taskSequence']! as int) > after)
            .toList();
        final page = tail.take(pageSize).toList();
        data = {
          'events': page,
          'nextTaskSequence': page.isEmpty ? after : page.last['taskSequence'],
          'hasMore': tail.length > page.length,
        };
      } else {
        data = events.last['snapshot']!;
      }
    }
    return _ok(data);
  }
}

http.Response _ok(Object data) => http.Response(
  jsonEncode({
    'code': 'OK',
    'message': 'ok',
    'traceId': 'tracker-test',
    'data': data,
  }),
  200,
);

final class _Harness {
  final server = _Server();
  final changes = ChangeNotifier();
  late DBService db;
  late AgentTaskJobStore jobs;
  late ProjectBuildRepository repository;
  late ProjectBuildTasks tasks;
  bool current = true;
  bool foreground = true;
  bool dispatch = true;
  int nonce = 0;
  int authorizeCalls = 0;
  Future<void> Function()? authorizing;
  Future<void> open({bool enable = false}) async {
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'build-tracker-${DateTime.now().microsecondsSinceEpoch}',
    );
    await mount(enable: enable);
  }

  Future<void> mount({bool enable = false}) async {
    jobs = await AgentTaskJobStore(
      persistence: SembastAgentTaskPersistence(db),
    ).init();
    repository = ProjectBuildRepository(
      database: db,
      scopeKey: projectBuildTestScope,
      isCurrent: () => current,
    );
    final gateway = HttpProjectBuildGateway(
      baseUri: () => Uri.parse('https://example.invalid/'),
      contextKey: () => current ? projectBuildTestScope : 'test|other',
      accessToken: () async => 'synthetic',
      isCurrent: () => current,
      client: MockClient(server.handle),
    );
    tasks = ProjectBuildTasks(
      jobs: jobs,
      repository: repository,
      gateway: gateway,
      scopeKey: projectBuildTestScope,
      appletScopeKey: _appletScope,
      isCurrent: () => current,
      isForeground: () => foreground,
      contextChanges: changes,
      enableCreation: enable,
      canRecoverDispatch: () async => dispatch,
      authorize: () async {
        authorizeCalls++;
        await authorizing?.call();
      },
      requestId: () => 'project_request_${nonce++}',
      pollInterval: const Duration(hours: 1),
      maximumPagesPerSync: 2,
    );
    final visible = foreground;
    foreground = false;
    tasks.onInit();
    foreground = visible;
  }

  Future<void> close() async {
    await tasks.deactivateAndDrain();
    await jobs.deactivateAndDrain();
    changes.dispose();
    await db.close();
  }

  Future<void> restart({bool enable = false}) async {
    await tasks.deactivateAndDrain();
    await jobs.deactivateAndDrain();
    await mount(enable: enable);
  }

  AgentTaskJob get latest => jobs.jobs.last;
  Future<AgentTaskJob> enqueue() => tasks.enqueue(
    projectKind: ProjectBuildKind.applet,
    requirements: projectBuildInput().requirements,
    locale: 'zh-CN',
  );
  Future<void> seed({bool failed = false}) async {
    await repository.prepareCreate(
      projectBuildInput(),
      expectedScopeKey: projectBuildTestScope,
    );
    await repository.recordReceipt(
      projectBuildReceipt(),
      expectedScopeKey: projectBuildTestScope,
    );
    server.events.addAll(
      failed ? projectBuildEvents() : [projectBuildEvents().first],
    );
    await repository.applyPage(
      projectBuildReceipt().taskId,
      projectBuildPage(server.events),
      expectedScopeKey: projectBuildTestScope,
    );
  }
}

Future<void> _waitFor(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Harness h;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    h = _Harness();
  });
  tearDown(() async {
    await h.close();
    await appServices.reset();
  });

  test(
    'new admission defaults closed and cannot create a nonce or POST',
    () async {
      await h.open();
      expect(h.tasks.canSubmit, isFalse);
      await expectLater(h.enqueue(), throwsStateError);
      expect(h.server.posts, isEmpty);
      expect(
        await h.repository.pendingRequests(
          expectedScopeKey: projectBuildTestScope,
        ),
        isEmpty,
      );
      expect(h.jobs.jobs, isEmpty);
    },
  );

  test(
    'durable nonce is replayed after lost ACK and restart with one card',
    () async {
      await h.open(enable: true);
      h.server.loseCreateAck = true;
      final job = await h.enqueue();
      await _waitFor(
        () =>
            h.server.posts.length == 1 &&
            h.latest.projectBuild!.syncIssue.isNotEmpty,
      );
      final pending = await h.repository.pendingRequests(
        expectedScopeKey: projectBuildTestScope,
      );
      expect(pending.single.requestId, h.server.posts.single['requestId']);
      await h.restart();
      await h.tasks.restore();
      await _waitFor(() => h.latest.projectBuild!.appliedTaskSequence == 1);
      expect(h.server.posts, hasLength(2));
      expect(h.server.posts[0], h.server.posts[1]);
      expect(h.server.events, hasLength(1));
      expect(h.latest.taskId, job.taskId);
      expect(await h.db.getMessages('self'), hasLength(1));
      expect(h.latest.status, isNot(AgentTaskJobStatus.completed));
    },
  );

  test(
    'recovery dispatch defaults safely blocked while accepted journal remains readable',
    () async {
      await h.open();
      h.dispatch = false;
      await h.repository.prepareCreate(
        projectBuildInput(),
        expectedScopeKey: projectBuildTestScope,
      );
      await h.tasks.restore();
      expect(h.server.posts, isEmpty);
      expect(h.latest.projectBuild!.syncIssue, 'needs_authorization');
      expect(h.tasks.canControl(h.latest, retry: true), isFalse);
      await h.repository.recordReceipt(
        projectBuildReceipt(),
        expectedScopeKey: projectBuildTestScope,
      );
      h.server.events.add(projectBuildEvents().first);
      await h.tasks.restore();
      expect(h.server.posts, isEmpty);
      expect(h.latest.projectBuild!.appliedTaskSequence, 1);
      expect(h.tasks.canControl(h.latest, retry: false), isTrue);
    },
  );

  test(
    'accepted repository history restores card without jumping cursor or submitting',
    () async {
      await h.open();
      h.dispatch = false;
      await h.seed(failed: true);
      await h.tasks.restore();
      expect(h.server.posts, isEmpty);
      expect(h.latest.projectBuild!.appliedTaskSequence, 3);
      expect(h.latest.status, AgentTaskJobStatus.failed);
      expect(h.latest.progress, hasLength(3));
      await h.restart();
      await h.tasks.restore();
      expect(h.latest.progress, hasLength(3));
      expect(await h.db.getMessages('self'), hasLength(1));
    },
  );

  test(
    'bounded pages catch up from durable cursor and overlapping sync shares one request',
    () async {
      await h.open();
      await h.seed();
      h.server.advance(ProjectBuildStatus.running);
      for (var i = 0; i < 4; i++) {
        h.server.advance(ProjectBuildStatus.running);
      }
      h.server.pageSize = 1;
      await h.tasks.restore();
      expect(h.latest.projectBuild!.appliedTaskSequence, lessThan(6));
      final gate = Completer<void>();
      h.server.pauseRead = gate;
      final first = h.tasks.synchronize(h.latest.taskId);
      final second = h.tasks.synchronize(h.latest.taskId);
      expect(identical(first, second), isTrue);
      gate.complete();
      await first;
      h.server.pauseRead = null;
      await h.tasks.synchronize(h.latest.taskId);
      expect(h.latest.projectBuild!.appliedTaskSequence, 6);
      expect(h.server.cursors, containsAllInOrder([1, 2, 3, 4, 5]));
      expect(h.latest.status, isNot(AgentTaskJobStatus.completed));
    },
  );

  test(
    'cancel works with creation disabled; retry rechecks authorization and attempt',
    () async {
      await h.open();
      await h.seed();
      await h.tasks.restore();
      final original = h.latest;
      expect(
        await h.tasks.cancel(original.id, expectedAttempt: original.attempt),
        isTrue,
      );
      expect(h.latest.status, AgentTaskJobStatus.cancelled);
      expect(h.tasks.canControl(h.latest, retry: true), isFalse);
      await h.restart(enable: true);
      await h.tasks.restore();
      expect(await h.tasks.retry(h.latest.id, expectedAttempt: 99), isFalse);
      expect(await h.tasks.retry(h.latest.id, expectedAttempt: 1), isTrue);
      expect(h.latest.attempt, 2);
      expect(h.latest.taskId, original.taskId);
      expect(h.authorizeCalls, 1);
      expect(await h.db.getMessages('self'), hasLength(1));
    },
  );

  test(
    'account changes during retry authorization do not POST or leak a new attempt',
    () async {
      await h.open(enable: true);
      await h.seed(failed: true);
      await h.tasks.restore();
      final gate = Completer<void>();
      h.authorizing = () => gate.future;
      final work = h.tasks.retry(h.latest.id, expectedAttempt: 1);
      final result = expectLater(work, throwsStateError);
      await _waitFor(() => h.authorizeCalls == 1);
      h.current = false;
      h.changes.notifyListeners();
      gate.complete();
      await result;
      expect(h.server.posts, isEmpty);
      expect(h.latest.attempt, 1);
    },
  );

  test(
    'explicit rejection persists and is not replayed after restart',
    () async {
      await h.open(enable: true);
      h.server.rejectCreate = true;
      await h.enqueue();
      await _waitFor(
        () => h.latest.projectBuild!.syncIssue.startsWith('rejected:'),
      );
      expect(h.server.posts, hasLength(1));
      await h.restart();
      await h.tasks.restore();
      expect(h.server.posts, hasLength(1));
      expect(h.latest.projectBuild!.syncIssue, 'rejected:CONSENT_REQUIRED');
      expect(h.latest.status, isNot(AgentTaskJobStatus.completed));
    },
  );

  test(
    'foreground loss stops new polls and retirement drains stalled authorization',
    () async {
      await h.open(enable: true);
      await h.seed();
      await h.tasks.restore();
      h.foreground = false;
      h.changes.notifyListeners();
      final count = h.server.paths.length;
      await h.tasks.restore();
      expect(h.server.paths, hasLength(count));
      h.foreground = true;
      h.changes.notifyListeners();
      final gate = Completer<void>();
      h.authorizing = () => gate.future;
      final enqueue = h.enqueue();
      final failure = expectLater(enqueue, throwsStateError);
      await _waitFor(() => h.authorizeCalls == 1);
      await h.tasks.deactivateAndDrain().timeout(const Duration(seconds: 1));
      await failure;
      expect(h.server.posts, isEmpty);
    },
  );
  for (final existingCard in [false, true]) {
    test(
      'accepted retry receipt survives crash before task pending save: card=$existingCard',
      () async {
        await h.open();
        await h.seed(failed: true);
        if (existingCard) await h.tasks.restore();
        final command = ProjectBuildCommand.fromJson(
          projectBuildObject(projectBuildWireFixture()['retryCommand']),
          operation: ProjectBuildOperation.retry,
        );
        await h.repository.prepareCommand(
          projectBuildReceipt().taskId,
          command,
          expectedScopeKey: projectBuildTestScope,
        );
        await h.repository.recordReceipt(
          ProjectBuildReceipt.fromJson({
            'requestId': command.requestId,
            'taskId': projectBuildReceipt().taskId,
            'runId': projectBuildOtherRun,
            'attempt': 2,
            'acceptedTaskSequence': 4,
          }),
          expectedScopeKey: projectBuildTestScope,
        );
        h.server.events.add(projectBuildRetryEvent());
        await h.restart();
        h.dispatch = false;
        await h.tasks.restore(probeTerminal: false);
        expect(h.latest.attempt, 2);
        expect(h.latest.projectBuild!.appliedTaskSequence, 4);
        expect(h.server.posts, isEmpty);
      },
    );
  }

  test(
    'local replay budget continues beyond terminal page using durable horizon',
    () async {
      await h.open();
      await h.seed();
      h.server.advance(ProjectBuildStatus.running);
      for (var i = 0; i < 197; i++) {
        h.server.advance(ProjectBuildStatus.running);
      }
      h.server.advance(ProjectBuildStatus.failed);
      h.server.advance(ProjectBuildStatus.queued, retry: true);
      expect(h.server.events, hasLength(201));
      await h.repository.applyPage(
        projectBuildReceipt().taskId,
        projectBuildPage(h.server.events.take(200).toList()),
        expectedScopeKey: projectBuildTestScope,
      );
      await h.repository.applyPage(
        projectBuildReceipt().taskId,
        projectBuildPage([h.server.events.last], after: 200),
        expectedScopeKey: projectBuildTestScope,
      );
      await h.tasks.restore(probeTerminal: false);
      expect(h.latest.projectBuild!.appliedTaskSequence, 201);
      expect(h.latest.attempt, 2);
      expect(h.server.posts, isEmpty);
    },
  );

  test(
    'explicit foreground restore probes a known terminal task retried elsewhere',
    () async {
      await h.open();
      await h.seed(failed: true);
      await h.tasks.restore();
      h.server.events.add(projectBuildRetryEvent());
      await h.tasks.restore();
      expect(h.latest.attempt, 2);
      expect(h.latest.projectBuild!.appliedTaskSequence, 4);
      expect(h.server.posts, isEmpty);
    },
  );
  test(
    'durable old-version command reconciles original nonce after projection advances',
    () async {
      await h.open();
      await h.seed();
      h.server.advance(ProjectBuildStatus.running);
      await h.tasks.restore();
      final command = ProjectBuildCommand(
        operation: ProjectBuildOperation.cancel,
        requestId: 'durable_cancel_0001',
        expectedRunId: h.latest.projectBuild!.snapshot!.runId,
        expectedStatusVersion: 2,
      );
      await h.repository.prepareCommand(
        projectBuildReceipt().taskId,
        command,
        expectedScopeKey: projectBuildTestScope,
      );
      h.server.advance(ProjectBuildStatus.running);
      await h.repository.applyPage(
        projectBuildReceipt().taskId,
        projectBuildPage([h.server.events.last], after: 2),
        expectedScopeKey: projectBuildTestScope,
      );
      await h.restart();
      await h.tasks.restore();
      expect(h.server.posts.single, command.toJson());
      expect(h.latest.projectBuild!.appliedTaskSequence, 3);
      expect(h.latest.projectBuild!.pendingCommand, isNull);
      expect(
        h.latest.projectBuild!.syncIssue,
        'rejected:PROJECT_BUILD_COMMAND_CONFLICT',
      );
      expect(
        await h.repository.pendingRequests(
          expectedScopeKey: projectBuildTestScope,
        ),
        isEmpty,
      );
    },
  );

  test(
    'denied old retry still reads newer journal without replaying POST',
    () async {
      await h.open();
      await h.seed(failed: true);
      await h.tasks.restore();
      final command = ProjectBuildCommand.fromJson(
        projectBuildObject(projectBuildWireFixture()['retryCommand']),
        operation: ProjectBuildOperation.retry,
      );
      await h.repository.prepareCommand(
        projectBuildReceipt().taskId,
        command,
        expectedScopeKey: projectBuildTestScope,
      );
      h.server.events.add(projectBuildRetryEvent());
      await h.repository.applyPage(
        projectBuildReceipt().taskId,
        projectBuildPage([projectBuildRetryEvent()], after: 3),
        expectedScopeKey: projectBuildTestScope,
      );
      await h.restart();
      h.dispatch = false;
      await h.tasks.restore();
      expect(h.server.posts, isEmpty);
      expect(h.latest.projectBuild!.appliedTaskSequence, 4);
      expect(h.latest.projectBuild!.syncIssue, 'needs_authorization');
    },
  );

  test(
    'foreground reprobe survives an old epoch in-flight terminal head',
    () async {
      await h.open();
      await h.seed(failed: true);
      await h.tasks.restore();
      final before = h.server.paths.length;
      final gate = Completer<void>();
      h.server.pauseRead = gate;
      final old = h.tasks.restore();
      await _waitFor(() => h.server.paths.length > before);
      h.foreground = false;
      h.changes.notifyListeners();
      h.foreground = true;
      h.changes.notifyListeners();
      await pumpEventQueue();
      h.server.events.add(projectBuildRetryEvent());
      gate.complete();
      await old;
      await _waitFor(() => h.latest.projectBuild!.appliedTaskSequence == 4);
      expect(h.server.paths.length, greaterThan(before + 1));
      expect(h.server.posts, isEmpty);
    },
  );

  test(
    'ordinary command CAS conflict refreshes state without poisoning tracker',
    () async {
      await h.open(enable: true);
      await h.seed();
      h.server.advance(ProjectBuildStatus.running);
      await h.tasks.restore();
      final before = h.latest;
      h.server.advance(ProjectBuildStatus.running);
      await h.repository.applyPage(
        projectBuildReceipt().taskId,
        projectBuildPage([h.server.events.last], after: 2),
        expectedScopeKey: projectBuildTestScope,
      );
      expect(await h.tasks.cancel(before.id, expectedAttempt: 1), isFalse);
      expect(h.tasks.canSubmit, isTrue);
      expect(h.latest.projectBuild!.appliedTaskSequence, 3);
      expect(await h.tasks.cancel(h.latest.id, expectedAttempt: 1), isTrue);
      expect(
        h.latest.projectBuild!.snapshot!.status,
        ProjectBuildStatus.cancelling,
      );
    },
  );
  test(
    'concurrent command/sync persists pending before POST without stale card overwrite',
    () async {
      await h.open();
      await h.seed();
      await h.tasks.restore();
      final job = h.latest;
      var checked = 0;
      h.server.beforePost = (body) async {
        final rows = await SembastAgentTaskPersistence(h.db).readJobs();
        final stored = rows
            .map(AgentTaskJob.tryParse)
            .whereType<AgentTaskJob>()
            .last;
        expect(
          stored.projectBuild!.pendingCommand!.requestId,
          body['requestId'],
        );
        expect(
          stored.projectBuild!.pendingCommand!.expectedRunId,
          body['expectedRunId'],
        );
        expect(
          stored.projectBuild!.pendingCommand!.expectedStatusVersion,
          body['expectedStatusVersion'],
        );
        checked++;
      };
      final cancel = h.tasks.cancel(job.id, expectedAttempt: job.attempt);
      final concurrent = h.tasks.synchronize(job.taskId);
      expect(await cancel, isTrue);
      await concurrent;
      expect(checked, 1);
      expect(h.server.posts, hasLength(1));
      expect(h.latest.status, AgentTaskJobStatus.cancelled);
      expect(h.latest.projectBuild!.pendingCommand, isNull);
    },
  );
}
