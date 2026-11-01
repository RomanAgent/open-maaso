import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:uuid/uuid.dart';

import '../data/project_build_gateway.dart';
import '../data/project_build_repository.dart';
import '../domain/project_build_contract.dart';
import '../domain/project_build_task_binding.dart';

/// Account-owned transport/replay coordinator. It does not build a project or
/// grant a model capability. New admission and recovered POSTs default closed.
final class ProjectBuildTasks extends AppService
    implements AgentServerTaskControls {
  ProjectBuildTasks({
    required this.jobs,
    required ProjectBuildRepository repository,
    required HttpProjectBuildGateway gateway,
    required this.scopeKey,
    required this.appletScopeKey,
    required bool Function() isCurrent,
    required Future<void> Function() authorize,
    Future<bool> Function()? canRecoverDispatch,
    bool Function()? isForeground,
    Listenable? contextChanges,
    List<AppReactiveValue<dynamic>> reactiveContext = const [],
    this.enableCreation = false,
    String Function()? requestId,
    Duration pollInterval = const Duration(seconds: 2),
    this.maximumPagesPerSync = 4,
  }) : _repository = repository,
       _gateway = gateway,
       _isCurrent = isCurrent,
       _authorize = authorize,
       _canRecoverDispatch = canRecoverDispatch ?? _denyDispatch,
       _isForeground = isForeground ?? (() => true),
       _contextChanges = contextChanges,
       _reactiveContext = reactiveContext,
       _requestId = requestId ?? const Uuid().v4,
       _pollInterval = pollInterval {
    if (repository.scopeKey != scopeKey ||
        scopeKey.isEmpty ||
        appletScopeKey.isEmpty ||
        maximumPagesPerSync < 1 ||
        maximumPagesPerSync > 20) {
      throw ArgumentError('project_build_tracker_configuration');
    }
  }

  static Future<bool> _denyDispatch() async => false;
  final AgentTaskJobStore jobs;
  final ProjectBuildRepository _repository;
  final HttpProjectBuildGateway _gateway;
  final String scopeKey;
  final String appletScopeKey;
  final bool enableCreation;
  final int maximumPagesPerSync;
  final bool Function() _isCurrent;
  final bool Function() _isForeground;
  final Future<void> Function() _authorize;
  final Future<bool> Function() _canRecoverDispatch;
  final Listenable? _contextChanges;
  final List<AppReactiveValue<dynamic>> _reactiveContext;
  final List<Worker> _workers = [];
  final String Function() _requestId;
  final Duration _pollInterval;
  final Map<String, Future<void>> _syncs = {};
  final Set<Future<Object?>> _operations = {};
  final Set<String> _controlling = {};
  final Set<String> _authorizationBlocked = {};
  final Map<String, int> _replayHorizons = {};
  final Map<String, Set<String>> _pendingRecovery = {};
  bool _probeKnownTasks = false;
  final Completer<void> _retirement = Completer<void>();
  Timer? _timer;
  Future<void>? _restoring;
  Future<void>? _draining;
  Future<void> _admission = Future.value();
  bool _sealed = false;
  bool _storageFault = false;
  int _epoch = 0;
  int _failures = 0;
  bool get _valid =>
      !_sealed &&
      !_storageFault &&
      _isCurrent() &&
      _repository.scopeKey == scopeKey;
  bool get canSubmit => enableCreation && _valid && _isForeground();

  @override
  void onInit() {
    super.onInit();
    jobs.registerControls(AgentTaskExecutionKind.projectBuild, this);
    _contextChanges?.addListener(_contextChanged);
    for (final value in _reactiveContext) {
      _workers.add(value.listen((_) => _contextChanged()));
    }
    _contextChanged();
  }

  void _contextChanged() {
    _timer?.cancel();
    _timer = null;
    if (!_valid) {
      _epoch++;
      return;
    }
    _authorizationBlocked.clear();
    if (!_isForeground()) {
      _epoch++;
      return;
    }
    _schedule(Duration.zero, discover: true);
  }

  void _guard(int epoch) {
    if (!_valid || epoch != _epoch) {
      throw StateError('project_build_scope_changed');
    }
  }

  Iterable<AgentTaskJob> get _roots => jobs.jobs.where(
    (job) =>
        job.isProjectBuild &&
        job.appletScopeKey == appletScopeKey &&
        job.projectBuild!.scopeKey == scopeKey &&
        jobs.isCurrentAttempt(job),
  );

  AgentTaskJob? _forRequest(String requestId) {
    for (final job in _roots) {
      if (job.projectBuild!.createRequestId == requestId) return job;
    }
    return null;
  }

  AgentTaskJob _latest(String root) {
    for (final job in _roots) {
      if (job.taskId == root) return job;
    }
    throw StateError('project_build_job_unavailable');
  }

  bool _eligible(AgentTaskJob job) {
    final binding = job.projectBuild!;
    final pending = binding.pendingCommand;
    final canReplay =
        pending != null &&
        !binding.syncIssue.startsWith('rejected:') &&
        !_authorizationBlocked.contains(pending.requestId);
    return (_pendingRecovery[job.taskId]?.any(
              (id) => !_authorizationBlocked.contains(id),
            ) ??
            false) ||
        binding.appliedTaskSequence < (_replayHorizons[job.taskId] ?? 0) ||
        canReplay ||
        (binding.taskId != null && binding.snapshot?.isTerminal != true);
  }

  void _schedule(Duration delay, {bool discover = false}) {
    if (!_valid || !_isForeground() || (!discover && !_roots.any(_eligible))) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(
        restore(
          probeTerminal: discover,
        ).catchError((Object _, StackTrace _) {}),
      );
    });
  }

  Future<T> _track<T>(Future<T> work) {
    late Future<T> operation;
    operation = work.whenComplete(() => _operations.remove(operation));
    _operations.add(operation);
    return operation;
  }

  Future<T> _untilRetired<T>(Future<T> work) => Future.any([
    work,
    _retirement.future.then<T>(
      (_) => throw StateError('project_build_scope_changed'),
    ),
  ]);

  Future<T> _durable<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (_) {
      _storageFault = true;
      _timer?.cancel();
      rethrow;
    }
  }

  Future<void> _save(
    AgentTaskJob job,
    ProjectBuildTaskBinding binding,
    int epoch,
  ) async {
    _guard(epoch);
    jobs.updateProjectBuildBinding(
      job.id,
      binding,
      expectedScopeKey: appletScopeKey,
    );
    await _durable(jobs.flush);
    _guard(epoch);
  }

  Future<AgentTaskJob> enqueue({
    String agentId = 'self',
    required ProjectBuildKind projectKind,
    required String requirements,
    String locale = 'en',
  }) {
    final predecessor = _admission;
    final work = _track(() async {
      await predecessor;
      final epoch = _epoch;
      _guard(epoch);
      if (!canSubmit) throw StateError('project_build_admission_disabled');
      await _untilRetired(_authorize());
      _guard(epoch);
      final permitted = await _untilRetired(_canRecoverDispatch());
      _guard(epoch);
      if (!canSubmit || !permitted) {
        throw StateError('project_build_needs_authorization');
      }
      final input = ProjectBuildCreateRequest(
        requestId: _requestId(),
        agentId: agentId,
        projectKind: projectKind,
        requirements: requirements,
        locale: locale,
      );
      await _durable(
        () => _repository.prepareCreate(input, expectedScopeKey: scopeKey),
      );
      _guard(epoch);
      final job = jobs.startProjectBuild(
        agentId: input.agentId,
        userText: input.requirements,
        appletScopeKey: appletScopeKey,
        projectKind: input.projectKind,
        binding: ProjectBuildTaskBinding(
          scopeKey: scopeKey,
          createRequestId: input.requestId,
          pendingCommand: ProjectBuildTaskPendingCommand(
            operation: ProjectBuildTaskOperation.create,
            requestId: input.requestId,
          ),
        ),
      );
      await _durable(jobs.flush);
      _guard(epoch);
      unawaited(
        synchronize(job.taskId).catchError((Object _, StackTrace _) {}),
      );
      return job;
    }());
    _admission = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  /// Restores durable intent/card gaps, then replays known server work. This
  /// method may read accepted journals even while new admission is disabled.
  Future<void> restore({bool probeTerminal = true}) {
    _probeKnownTasks = _probeKnownTasks || probeTerminal;
    if (!_valid || !_isForeground()) return Future.value();
    final existing = _restoring;
    if (existing != null) return existing;
    late Future<void> operation;
    operation = _track(_restore(_epoch)).whenComplete(() {
      _restoring = null;
      final factor = 1 << _failures.clamp(0, 4);
      _schedule(
        _probeKnownTasks
            ? Duration.zero
            : Duration(
                milliseconds: (_pollInterval.inMilliseconds * factor).clamp(
                  100,
                  30000,
                ),
              ),
        discover: _probeKnownTasks,
      );
    });
    _restoring = operation;
    return operation;
  }

  Future<void> _restore(int epoch) async {
    _guard(epoch);
    final projections = await _durable(
      () => _repository.list(expectedScopeKey: scopeKey),
    );
    _guard(epoch);
    for (final projection in projections) {
      var job = _forRequest(projection.input.requestId);
      job ??= jobs.restoreProjectBuild(
        agentId: projection.input.agentId,
        userText: projection.input.requirements,
        appletScopeKey: appletScopeKey,
        projectKind: projection.input.projectKind,
        createdAt:
            projection.snapshot?.createdAt ??
            projection.remoteHead?.createdAt ??
            DateTime.now(),
        binding: ProjectBuildTaskBinding(
          scopeKey: scopeKey,
          createRequestId: projection.input.requestId,
          taskId: projection.taskId,
        ),
      );
      await _durable(jobs.flush);
      await _replay(job.taskId, projection, epoch);
    }
    final requests = await _durable(
      () => _repository.pendingRequests(
        expectedScopeKey: scopeKey,
        includeRejected: true,
      ),
    );
    _guard(epoch);
    final unresolvedIds = requests
        .where((r) => r.rejectionCode.isEmpty)
        .map((r) => r.requestId)
        .toSet();
    for (final ids in _pendingRecovery.values) {
      ids.removeWhere((id) => !unresolvedIds.contains(id));
    }
    for (final request in requests) {
      AgentTaskJob? job;
      final input = request.create;
      if (input != null) {
        job =
            _forRequest(input.requestId) ??
            jobs.restoreProjectBuild(
              agentId: input.agentId,
              userText: input.requirements,
              appletScopeKey: appletScopeKey,
              projectKind: input.projectKind,
              createdAt: DateTime.now(),
              binding: ProjectBuildTaskBinding(
                scopeKey: scopeKey,
                createRequestId: input.requestId,
                pendingCommand: _pending(request),
                syncIssue: request.rejectionCode.isEmpty
                    ? ''
                    : 'rejected:${request.rejectionCode}',
              ),
            );
      } else {
        for (final candidate in _roots) {
          if (candidate.projectBuild!.taskId == request.taskId) {
            job = candidate;
            break;
          }
        }
      }
      if (job == null) continue;
      final binding = job.projectBuild!;
      final currentPending = binding.pendingCommand;
      if (request.rejectionCode.isEmpty) {
        (_pendingRecovery[job.taskId] ??= {}).add(request.requestId);
      }
      if (request.rejectionCode.isNotEmpty &&
          currentPending != null &&
          currentPending.requestId != request.requestId) {
        continue;
      }
      if (request.rejectionCode.isNotEmpty &&
          currentPending == null &&
          input == null) {
        continue;
      }
      job = await _restorePending(job.taskId, request, epoch);
      await _save(
        job,
        job.projectBuild!.copyWith(
          clearPending:
              request.rejectionCode.isNotEmpty && request.create == null,
          syncIssue: request.rejectionCode.isEmpty
              ? binding.syncIssue
              : 'rejected:${request.rejectionCode}',
        ),
        epoch,
      );
    }
    await _durable(jobs.flush);
    _guard(epoch);
    final probeTerminal = _probeKnownTasks;
    _probeKnownTasks = false;
    await Future.wait(
      _roots
          .where(
            (job) =>
                _eligible(job) ||
                (probeTerminal && job.projectBuild!.taskId != null),
          )
          .map((job) => synchronize(job.taskId))
          .toList(),
    );
  }

  Future<AgentTaskJob> _restorePending(
    String root,
    ProjectBuildPendingRequest request,
    int epoch,
  ) async {
    _guard(epoch);
    final job = jobs.restoreProjectBuildPendingCommand(
      _latest(root).id,
      request,
      expectedScopeKey: appletScopeKey,
      expectedRepositoryScopeKey: scopeKey,
    );
    await _durable(jobs.flush);
    _guard(epoch);
    return job;
  }

  ProjectBuildTaskPendingCommand _pending(
    ProjectBuildPendingRequest request, {
    int? accepted,
  }) => ProjectBuildTaskPendingCommand(
    operation: request.create != null
        ? ProjectBuildTaskOperation.create
        : request.command!.operation == ProjectBuildOperation.cancel
        ? ProjectBuildTaskOperation.cancel
        : ProjectBuildTaskOperation.retry,
    requestId: request.requestId,
    expectedRunId: request.command?.expectedRunId,
    expectedStatusVersion: request.command?.expectedStatusVersion,
    acceptedTaskSequence: accepted,
  );

  Future<void> synchronize(String root) {
    if (!_valid || !_isForeground()) return Future.value();
    final existing = _syncs[root];
    if (existing != null) return existing;
    late Future<void> work;
    work = _track(_sync(root, _epoch)).whenComplete(() {
      _syncs.remove(root);
      final factor = 1 << _failures.clamp(0, 4);
      _schedule(
        Duration(
          milliseconds: (_pollInterval.inMilliseconds * factor).clamp(
            100,
            30000,
          ),
        ),
      );
    });
    _syncs[root] = work;
    return work;
  }

  Future<void> _sync(String root, int epoch) async {
    try {
      _guard(epoch);
      var job = _latest(root);
      final requests = await _durable(
        () => _repository.pendingRequests(expectedScopeKey: scopeKey),
      );
      _guard(epoch);
      for (final request in requests.where(
        (request) => request.create != null
            ? request.requestId == job.projectBuild!.createRequestId
            : request.taskId == job.projectBuild!.taskId,
      )) {
        job = await _restorePending(root, request, epoch);
        if (request.create != null ||
            request.command!.operation == ProjectBuildOperation.retry) {
          final permitted = await _untilRetired(_canRecoverDispatch());
          _guard(epoch);
          if (!permitted) {
            _authorizationBlocked.add(request.requestId);
            await _save(
              _latest(root),
              _latest(
                root,
              ).projectBuild!.copyWith(syncIssue: 'needs_authorization'),
              epoch,
            );
            continue;
          }
        }
        ProjectBuildReceipt receipt;
        try {
          receipt = request.create != null
              ? await _gateway.create(
                  request: request.create!,
                  expectedContextKey: scopeKey,
                )
              : await _gateway.command(
                  taskId: request.taskId!,
                  command: request.command!,
                  expectedContextKey: scopeKey,
                );
        } on ProjectBuildRequestException catch (error) {
          if (error.ambiguous || error.statusCode == 429) rethrow;
          _guard(epoch);
          await _durable(
            () => _repository.rejectRequest(
              request.requestId,
              error.code,
              expectedScopeKey: scopeKey,
            ),
          );
          _pendingRecovery[root]?.remove(request.requestId);
          job = _latest(root);
          await _save(
            job,
            job.projectBuild!.copyWith(
              pendingCommand: _pending(request),
              clearPending: request.create == null,
              syncIssue: 'rejected:${error.code}',
            ),
            epoch,
          );
          continue;
        }
        _guard(epoch);
        final projection = await _durable(
          () => _repository.recordReceipt(receipt, expectedScopeKey: scopeKey),
        );
        _guard(epoch);
        _pendingRecovery[root]?.remove(request.requestId);
        job = _latest(root);
        final binding = job.projectBuild!;
        final attachPending =
            binding.pendingCommand != null ||
            (binding.appliedTaskSequence < receipt.acceptedTaskSequence &&
                (request.create != null
                    ? binding.taskId == null
                    : binding.snapshot?.runId ==
                              request.command!.expectedRunId &&
                          binding.snapshot?.statusVersion ==
                              request.command!.expectedStatusVersion));
        await _save(
          job,
          binding.copyWith(
            taskId: receipt.taskId,
            pendingCommand: attachPending
                ? _pending(request, accepted: receipt.acceptedTaskSequence)
                : null,
            syncIssue: '',
          ),
          epoch,
        );
        job = _latest(root);
        final acceptedPending = job.projectBuild!.pendingCommand;
        if (acceptedPending?.acceptedTaskSequence != null &&
            acceptedPending!.acceptedTaskSequence! <=
                job.projectBuild!.appliedTaskSequence) {
          await _save(
            job,
            job.projectBuild!.copyWith(clearPending: true),
            epoch,
          );
        }
        await _replay(root, projection, epoch);
      }
      job = _latest(root);
      final task = job.projectBuild!.taskId;
      if (task == null) return;
      final head = await _gateway.snapshot(
        taskId: task,
        expectedContextKey: scopeKey,
      );
      _guard(epoch);
      var projection = await _durable(
        () => _repository.noteRemoteHead(head, expectedScopeKey: scopeKey),
      );
      await _replay(root, projection, epoch);
      for (var pages = 0; pages < maximumPagesPerSync; pages++) {
        _guard(epoch);
        final page = await _gateway.events(
          taskId: task,
          afterTaskSequence: projection.appliedTaskSequence,
          expectedContextKey: scopeKey,
        );
        _guard(epoch);
        projection = await _durable(
          () => _repository.applyPage(task, page, expectedScopeKey: scopeKey),
        );
        await _replay(root, projection, epoch);
        if (!page.hasMore) {
          if (projection.appliedTaskSequence < head.snapshotTaskSequence) {
            throw StateError('project_build_replay_incomplete');
          }
          break;
        }
      }
      job = _latest(root);
      if (_pendingRecovery[root]?.any(_authorizationBlocked.contains) ??
          false) {
        await _save(
          job,
          job.projectBuild!.copyWith(syncIssue: 'needs_authorization'),
          epoch,
        );
        job = _latest(root);
      }
      if (!job.projectBuild!.syncIssue.startsWith('rejected:') &&
          job.projectBuild!.syncIssue != 'needs_authorization') {
        await _save(job, job.projectBuild!.copyWith(syncIssue: ''), epoch);
      }
      _failures = 0;
    } catch (error) {
      if (!_valid || epoch != _epoch) return;
      _failures++;
      final job = _latest(root);
      await _save(
        job,
        job.projectBuild!.copyWith(
          syncIssue: error is ProjectBuildRequestException
              ? error.code
              : 'project_build_sync_unavailable',
        ),
        epoch,
      );
    }
  }

  Future<void> _replay(
    String root,
    ProjectBuildProjection projection,
    int epoch,
  ) async {
    final horizon = [
      projection.appliedTaskSequence,
      projection.receipt.acceptedTaskSequence,
      projection.remoteHead?.snapshotTaskSequence ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    if (horizon > (_replayHorizons[root] ?? 0)) _replayHorizons[root] = horizon;
    var job = _latest(root);
    if (job.projectBuild!.taskId == null) {
      await _save(
        job,
        job.projectBuild!.copyWith(taskId: projection.taskId),
        epoch,
      );
    }
    for (var pages = 0; pages < maximumPagesPerSync; pages++) {
      _guard(epoch);
      job = _latest(root);
      final cursor = job.projectBuild!.appliedTaskSequence;
      if (cursor >= projection.appliedTaskSequence) return;
      final page = await _repository.readEvents(
        projection.taskId,
        afterTaskSequence: cursor,
        expectedScopeKey: scopeKey,
      );
      _guard(epoch);
      for (final event in page.events) {
        jobs.applyProjectBuildEvent(
          root,
          event,
          expectedScopeKey: appletScopeKey,
          agentId: job.agentId,
        );
      }
      await _durable(jobs.flush);
      _guard(epoch);
      if (!page.hasMore) return;
    }
  }

  @override
  bool canControl(AgentTaskJob job, {required bool retry}) {
    if (!_valid ||
        !_isForeground() ||
        !job.isProjectBuild ||
        job.appletScopeKey != appletScopeKey ||
        job.projectBuild!.scopeKey != scopeKey ||
        !jobs.isCurrentAttempt(job) ||
        (_pendingRecovery[job.taskId]?.isNotEmpty ?? false) ||
        _controlling.contains(job.taskId)) {
      return false;
    }
    final binding = job.projectBuild!;
    if (binding.pendingCommand != null || binding.snapshot == null) {
      return false;
    }
    return retry
        ? canSubmit && binding.snapshot!.isTerminal
        : {
            ProjectBuildStatus.queued,
            ProjectBuildStatus.running,
          }.contains(binding.snapshot!.status);
  }

  @override
  Future<bool> cancel(String jobId, {required int expectedAttempt}) =>
      _control(jobId, expectedAttempt, retry: false);
  @override
  Future<bool> retry(String jobId, {required int expectedAttempt}) =>
      _control(jobId, expectedAttempt, retry: true);

  Future<bool> _control(String id, int attempt, {required bool retry}) =>
      _track(() async {
        final initial = jobs.byId(id);
        if (initial == null ||
            initial.attempt != attempt ||
            !canControl(initial, retry: retry)) {
          return false;
        }
        final root = initial.taskId;
        _controlling.add(root);
        final epoch = _epoch;
        try {
          await _syncs[root];
          _guard(epoch);
          if (retry) {
            await _untilRetired(_authorize());
            _guard(epoch);
          }
          final job = _latest(root);
          if (job.id != id ||
              job.attempt != attempt ||
              job.projectBuild!.pendingCommand != null ||
              (retry && !canSubmit)) {
            return false;
          }
          final snapshot = job.projectBuild!.snapshot!;
          if (retry
              ? !snapshot.isTerminal
              : !{
                  ProjectBuildStatus.queued,
                  ProjectBuildStatus.running,
                }.contains(snapshot.status)) {
            return false;
          }
          if (retry) {
            final permitted = await _untilRetired(_canRecoverDispatch());
            _guard(epoch);
            if (!permitted ||
                !canSubmit ||
                _latest(root).id != id ||
                _latest(root).projectBuild!.snapshot?.statusVersion !=
                    snapshot.statusVersion) {
              return false;
            }
          }
          final command = ProjectBuildCommand(
            operation: retry
                ? ProjectBuildOperation.retry
                : ProjectBuildOperation.cancel,
            requestId: _requestId(),
            expectedRunId: snapshot.runId,
            expectedStatusVersion: snapshot.statusVersion,
          );
          try {
            await _repository.prepareCommand(
              snapshot.taskId,
              command,
              expectedScopeKey: scopeKey,
            );
          } on StateError catch (error) {
            if (error.message == 'project_build_command_conflict') {
              await synchronize(root);
              return false;
            }
            _storageFault = true;
            _timer?.cancel();
            rethrow;
          } catch (_) {
            _storageFault = true;
            _timer?.cancel();
            rethrow;
          }
          _guard(epoch);
          // A concurrent sync may have advanced the card after prepare.
          // Reconcile the durable intent through the one per-root dispatcher;
          // never write the pre-prepare snapshot back over an accepted receipt.
          await _syncs[root];
          _guard(epoch);
          await synchronize(root);
          _guard(epoch);
          return true;
        } finally {
          _controlling.remove(root);
        }
      }());

  Future<void> deactivateAndDrain() => _draining ??= _drain();
  Future<void> _drain() async {
    _seal();
    final gateway = _gateway.deactivateAndDrain();
    await Future.wait(
      _operations.toList().map(
        (work) => work.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    await gateway;
    await jobs.flush();
  }

  void _seal() {
    if (_sealed) return;
    _sealed = true;
    if (!_retirement.isCompleted) _retirement.complete();
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _contextChanges?.removeListener(_contextChanged);
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    jobs.unregisterControls(AgentTaskExecutionKind.projectBuild, this);
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
