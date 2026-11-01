import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/creator/data/creator_draft_repository.dart';
import 'package:maaso/src/features/creator/data/creator_task_gateway.dart';
import 'package:maaso/src/features/creator/data/image_generation_gateway.dart';
import 'package:maaso/src/features/creator/domain/creator_draft.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:uuid/uuid.dart';

final class CreatorImageTaskPreview {
  CreatorImageTaskPreview._(
    this._authority,
    this.jobId,
    this.attempt,
    this.serverAttemptId,
    this.asset,
    this._epoch,
    this._draftRevision,
  );
  final Object _authority;
  final String jobId;
  final int attempt;
  final String serverAttemptId;
  final CreatorAssetRef asset;
  final int _epoch;
  final String _draftRevision;
  bool _presented = false;
  bool _closed = false;
  void markPresented() {
    if (!_closed) _presented = true;
  }

  void close() {
    _closed = true;
  }
}

/// Account-owned tracker. The durable command is flushed before POST; losing
/// HTTP acknowledgement never changes its nonce or falls back to generation.
class CreatorImageTasks extends AppService implements AgentServerTaskControls {
  CreatorImageTasks({
    required this.jobs,
    required CreatorDraftRepository repository,
    required CreatorTaskGateway gateway,
    required CreatorTaskAssetDownloader assets,
    required this.creatorScopeKey,
    required this.appletScopeKey,
    required bool Function() isCurrent,
    required Future<void> Function() authorize,
    bool Function()? isForeground,
    Listenable? contextChanges,
    List<AppReactiveValue<dynamic>> reactiveContext = const [],
    String Function()? requestId,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _repository = repository,
       _gateway = gateway,
       _assets = assets,
       _isCurrent = isCurrent,
       _authorize = authorize,
       _isForeground = isForeground ?? (() => true),
       _contextChanges = contextChanges,
       _reactiveContext = reactiveContext,
       _requestId = requestId ?? const Uuid().v4,
       _pollInterval = pollInterval;
  final AgentTaskJobStore jobs;
  final CreatorDraftRepository _repository;
  final CreatorTaskGateway _gateway;
  final CreatorTaskAssetDownloader _assets;
  final String creatorScopeKey;
  final String appletScopeKey;
  final bool Function() _isCurrent;
  final bool Function() _isForeground;
  final Future<void> Function() _authorize;
  final Listenable? _contextChanges;
  final List<AppReactiveValue<dynamic>> _reactiveContext;
  final List<Worker> _contextWorkers = [];
  final String Function() _requestId;
  final Duration _pollInterval;
  final Object _previewAuthority = Object();
  final Map<String, Future<void>> _syncs = {};
  final Set<Future<Object?>> _operations = {};
  final _draftChanges = StreamController<CreatorDraft>.broadcast(sync: true);
  Timer? _timer;
  bool _sealed = false;
  bool _storageFault = false;
  int _epoch = 0;
  int _failures = 0;
  Future<void>? _draining;
  Stream<CreatorDraft> get draftChanges => _draftChanges.stream;
  bool get isAvailable => _valid && _gateway.isAvailable;
  bool get _valid =>
      !_sealed &&
      !_storageFault &&
      _isCurrent() &&
      _gateway.requestContextKey == creatorScopeKey &&
      _repository.currentScopeKey == creatorScopeKey;

  @override
  void onInit() {
    super.onInit();
    jobs.registerControls(AgentTaskExecutionKind.creatorImage, this);
    _contextChanges?.addListener(_contextChanged);
    for (final signal in _reactiveContext) {
      _contextWorkers.add(signal.listen((_) => _contextChanged()));
    }
    _contextChanged();
  }

  void _contextChanged() {
    if (_sealed) return;
    if (!_valid) {
      _epoch++;
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (!_isForeground()) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _schedule(Duration.zero);
  }

  void _guard(int epoch) {
    if (!_valid || epoch != _epoch) throw const CreatorScopeChangedException();
  }

  T _sameJob<T>(String id, int attempt, T Function(AgentTaskJob) body) {
    final job = jobs.byId(id);
    if (!_valid ||
        job == null ||
        !job.isCreatorImage ||
        job.appletScopeKey != appletScopeKey ||
        job.serverImage!.creatorScopeKey != creatorScopeKey ||
        job.attempt != attempt ||
        !jobs.isCurrentAttempt(job)) {
      throw const CreatorScopeChangedException();
    }
    return body(job);
  }

  AgentTaskJob _latest(String root) {
    final job = jobs.latestForTask(
      root,
      appletScopeKey: appletScopeKey,
      agentId: 'self',
    );
    if (job == null ||
        !job.isCreatorImage ||
        job.serverImage!.creatorScopeKey != creatorScopeKey) {
      throw const CreatorScopeChangedException();
    }
    return job;
  }

  Iterable<AgentTaskJob> get _roots => jobs.jobs.where(
    (job) =>
        job.isCreatorImage &&
        job.appletScopeKey == appletScopeKey &&
        job.serverImage!.creatorScopeKey == creatorScopeKey &&
        jobs.isCurrentAttempt(job),
  );
  bool _eligible(AgentTaskJob job) {
    final binding = job.serverImage!;
    return !binding.syncIssue.startsWith('rejected:') &&
        (binding.pendingCommand != null || binding.snapshot?.canCancel == true);
  }

  AgentTaskJob? taskForDraft(String draftId) {
    for (final job in _roots.toList().reversed) {
      if (job.serverImage!.draftId == draftId) return job;
    }
    return null;
  }

  bool draftIsBusy(String draftId) => taskForDraft(draftId)?.isActive ?? false;

  static String fingerprint(CreatorDraft draft) =>
      creatorDraftTaskFingerprint(draft);

  Future<AgentTaskJob> enqueue(
    CreatorDraft draft, {
    String aspectRatio = '4:5',
    String style = 'cinematic',
  }) => _track(() async {
    final epoch = _epoch;
    _guard(epoch);
    if (!isAvailable) throw StateError('backend_not_ready');
    final current = await _repository.get(draft.id);
    _guard(epoch);
    if (current == null ||
        current.scopeKey != creatorScopeKey ||
        current.isSelfieVideo) {
      throw StateError('creator_draft_unavailable');
    }
    final input = CreatorTaskImageInput.fromJson({
      'prompt': current.imagePrompt?.trim() ?? '',
      'aspectRatio': aspectRatio,
      'style': style.trim().toLowerCase(),
    });
    final source = fingerprint(current);
    final existing = taskForDraft(current.id);
    if (existing != null &&
        existing.serverImage!.draftFingerprint == source &&
        jsonEncode(existing.serverImage!.input.toJson()) ==
            jsonEncode(input.toJson()) &&
        !existing.serverImage!.applied) {
      return existing;
    }
    if (_roots.any((job) => job.isActive)) throw StateError('creator_busy');
    await _authorize();
    _guard(epoch);
    // Consent lookup is asynchronous: recheck admission after it returns.
    if (_roots.any((job) => job.isActive)) throw StateError('creator_busy');
    final request = _requestId();
    final binding = CreatorImageTaskBinding(
      creatorScopeKey: creatorScopeKey,
      draftId: current.id,
      draftFingerprint: source,
      createRequestId: request,
      input: input,
      pendingCommand: CreatorTaskCommand(
        operation: CreatorTaskOperation.create,
        requestId: request,
      ),
    );
    final job = jobs.startServerImage(
      agentId: 'self',
      userText: current.title,
      appletScopeKey: appletScopeKey,
      binding: binding,
    );
    await _flush();
    _guard(epoch);
    _queue(job.taskId);
    return job;
  }());

  Future<void> _flush() async {
    try {
      await jobs.flush();
    } catch (_) {
      _storageFault = true;
      _timer?.cancel();
      rethrow;
    }
  }

  Future<void> _save(
    AgentTaskJob job,
    CreatorImageTaskBinding binding,
    int epoch,
  ) async {
    _guard(epoch);
    jobs.updateServerBinding(job.id, binding, expectedScopeKey: appletScopeKey);
    await _flush();
    _guard(epoch);
  }

  Future<T> _track<T>(Future<T> work) {
    late Future<T> tracked;
    tracked = work.whenComplete(() => _operations.remove(tracked));
    _operations.add(tracked);
    return tracked;
  }

  void _queue(String root) {
    unawaited(synchronize(root).catchError((Object _, StackTrace _) {}));
  }

  void _schedule(Duration delay) {
    if (!_valid || !_isForeground() || !_roots.any(_eligible)) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      for (final job in _roots.where(_eligible).toList()) {
        _queue(job.taskId);
      }
    });
  }

  Future<void> synchronize(String root) {
    if (!_valid) return Future.value();
    final existing = _syncs[root];
    if (existing != null) return existing;
    late Future<void> operation;
    operation = _track(_sync(root, _epoch)).whenComplete(() {
      _syncs.remove(root);
      if (_valid) {
        final multiplier = 1 << _failures.clamp(0, 4);
        _schedule(
          Duration(
            milliseconds: (_pollInterval.inMilliseconds * multiplier).clamp(
              100,
              30000,
            ),
          ),
        );
      }
    });
    _syncs[root] = operation;
    return operation;
  }

  Future<void> _sync(String root, int epoch) async {
    try {
      _guard(epoch);
      var job = _latest(root);
      var binding = job.serverImage!;
      final command = binding.pendingCommand;
      if (command != null && !binding.syncIssue.startsWith('rejected:')) {
        final alreadyAcknowledged =
            binding.receipt?.requestId == command.requestId;
        if (!alreadyAcknowledged) {
          // This exact nonce was authorized before it was persisted. Recovery
          // may read an existing receipt after new admission or consent stops;
          // the backend still checks privacy for any genuinely new dispatch.
          CreatorTaskReceipt receipt;
          try {
            if (command.operation == CreatorTaskOperation.create) {
              receipt = await _gateway.create(
                requestId: command.requestId,
                agentId: job.agentId,
                input: binding.input,
                expectedContextKey: creatorScopeKey,
              );
            } else {
              final id = binding.serverTaskId;
              if (id == null) throw StateError('server_task_identity_unknown');
              receipt = await _gateway.command(
                taskId: id,
                command: command,
                expectedContextKey: creatorScopeKey,
              );
            }
          } on CreatorTaskRequestException catch (error) {
            if (error.ambiguous) rethrow;
            _guard(epoch);
            job = _latest(root);
            binding = job.serverImage!;
            await _save(
              job,
              binding.copyWith(
                clearPending: command.operation != CreatorTaskOperation.create,
                syncIssue: 'rejected:${error.code}',
              ),
              epoch,
            );
            if (binding.serverTaskId == null) return;
            return await _readState(root, epoch);
          }
          _guard(epoch);
          job = _latest(root);
          binding = job.serverImage!;
          if (receipt.requestId != command.requestId ||
              (binding.serverTaskId != null &&
                  binding.serverTaskId != receipt.taskId) ||
              (command.operation == CreatorTaskOperation.create &&
                  receipt.attempt != 1) ||
              (command.operation == CreatorTaskOperation.cancel &&
                  receipt.attemptId != command.expectedAttemptId) ||
              (command.operation == CreatorTaskOperation.retry &&
                  receipt.attempt != job.attempt + 1)) {
            throw StateError('invalid_task_receipt');
          }
          await _save(
            job,
            binding.copyWith(receipt: receipt, syncIssue: ''),
            epoch,
          );
        }
      }
      await _readState(root, epoch);
      _failures = 0;
    } on CreatorScopeChangedException {
      return;
    } catch (error) {
      if (!_valid || epoch != _epoch) return;
      _failures++;
      final job = _latest(root);
      final issue = error is CreatorTaskRequestException
          ? error.code
          : 'task_sync_unavailable';
      try {
        await _save(job, job.serverImage!.copyWith(syncIssue: issue), epoch);
      } catch (_) {}
    }
  }

  Future<void> _readState(String root, int epoch) async {
    var job = _latest(root);
    final id = job.serverImage!.serverTaskId;
    if (id == null) return;
    final head = await _gateway.snapshot(
      taskId: id,
      expectedContextKey: creatorScopeKey,
    );
    _guard(epoch);
    if (head.taskId != id || head.agentId != job.agentId) {
      throw StateError('server_task_identity_changed');
    }
    var more = true;
    var pages = 0;
    while (more) {
      if (++pages > 4) throw StateError('server_task_replay_limit');
      job = _latest(root);
      final after = job.serverImage!.serverSequence;
      final page = await _gateway.events(
        taskId: id,
        agentId: job.agentId,
        afterSequence: after,
        expectedContextKey: creatorScopeKey,
      );
      _guard(epoch);
      for (final snapshot in page.snapshots) {
        _guard(epoch);
        jobs.applyServerSnapshot(
          root,
          snapshot,
          expectedScopeKey: appletScopeKey,
          agentId: job.agentId,
        );
      }
      await _flush();
      _guard(epoch);
      more = page.hasMore;
    }
    job = _latest(root);
    final binding = job.serverImage!;
    final known = binding.snapshot;
    if (known == null ||
        known.sequence < head.sequence ||
        (known.sequence == head.sequence && !known.sameState(head))) {
      throw StateError('server_task_replay_incomplete');
    }
    final receipt = binding.receipt;
    final clear =
        binding.pendingCommand != null &&
        receipt?.requestId == binding.pendingCommand?.requestId &&
        known.sequence >= receipt!.sequence;
    await _save(
      job,
      binding.copyWith(syncIssue: '', clearPending: clear),
      epoch,
    );
  }

  @override
  bool canControl(AgentTaskJob job, {required bool retry}) {
    if (!_valid ||
        !job.isCreatorImage ||
        !jobs.isCurrentAttempt(job) ||
        job.appletScopeKey != appletScopeKey ||
        job.serverImage!.creatorScopeKey != creatorScopeKey) {
      return false;
    }
    final binding = job.serverImage!;
    if (retry &&
        binding.snapshot == null &&
        binding.syncIssue.startsWith('rejected:')) {
      return isAvailable;
    }
    if (binding.pendingCommand != null) return false;
    return retry
        ? isAvailable && binding.snapshot?.canRetry == true
        : binding.snapshot?.canCancel == true;
  }

  @override
  Future<bool> cancel(String jobId, {required int expectedAttempt}) =>
      _control(jobId, expectedAttempt, retry: false);
  @override
  Future<bool> retry(String jobId, {required int expectedAttempt}) =>
      _control(jobId, expectedAttempt, retry: true);
  Future<bool> _control(String id, int attempt, {required bool retry}) =>
      _track(() async {
        final epoch = _epoch;
        final original = _sameJob(id, attempt, (job) => job);
        if (!canControl(original, retry: retry)) return false;
        await _syncs[original.taskId];
        _guard(epoch);
        final job = _sameJob(id, attempt, (job) => job);
        if (!canControl(job, retry: retry)) return false;
        final binding = job.serverImage!;
        final command = binding.snapshot == null
            ? CreatorTaskCommand(
                operation: CreatorTaskOperation.create,
                requestId: binding.createRequestId,
              )
            : CreatorTaskCommand(
                operation: retry
                    ? CreatorTaskOperation.retry
                    : CreatorTaskOperation.cancel,
                requestId: _requestId(),
                expectedAttemptId: binding.snapshot!.attemptId,
              );
        if (retry) {
          await _authorize();
          _guard(epoch);
          if (!canControl(_sameJob(id, attempt, (job) => job), retry: true)) {
            return false;
          }
        }
        await _save(
          job,
          binding.copyWith(pendingCommand: command, syncIssue: ''),
          epoch,
        );
        await synchronize(job.taskId);
        _guard(epoch);
        return true;
      }());

  Future<CreatorImageTaskPreview> preview(
    String jobId, {
    required int expectedAttempt,
  }) => _track(() async {
    final epoch = _epoch;
    var job = _sameJob(jobId, expectedAttempt, (job) => job);
    final binding = job.serverImage!;
    final snapshot = binding.snapshot;
    final artifact = snapshot?.artifact;
    if (snapshot?.status != CreatorTaskStatus.completed || artifact == null) {
      throw StateError('task_result_unavailable');
    }
    final previewDraft = await _repository.get(binding.draftId);
    _guard(epoch);
    if (previewDraft == null ||
        fingerprint(previewDraft) != binding.draftFingerprint) {
      throw StateError('creator_draft_changed');
    }
    final draftRevision = creatorDraftApplicationRevision(previewDraft);
    bool current() =>
        _valid &&
        epoch == _epoch &&
        jobs.isCurrentAttempt(job) &&
        jobs.byId(job.id)?.serverImage?.snapshot?.attemptId ==
            snapshot!.attemptId;
    CreatorAssetRef? asset = binding.previewAsset;
    if (asset == null ||
        !await _assets.validateTaskAsset(
          asset,
          artifact,
          expectedContextKey: creatorScopeKey,
          canContinue: current,
        )) {
      final result = await _gateway.result(
        taskId: snapshot!.taskId,
        expectedContextKey: creatorScopeKey,
      );
      _guard(epoch);
      if (jsonEncode(result.artifact.toJson()) !=
          jsonEncode(artifact.toJson())) {
        throw StateError('task_artifact_changed');
      }
      asset = await _assets.downloadTaskAsset(
        artifact: artifact,
        assetUrl: result.assetUrl,
        expectedContextKey: creatorScopeKey,
        canContinue: current,
      );
      _guard(epoch);
      job = _sameJob(jobId, expectedAttempt, (job) => job);
      await _save(job, job.serverImage!.copyWith(previewAsset: asset), epoch);
    }
    _guard(epoch);
    return CreatorImageTaskPreview._(
      _previewAuthority,
      jobId,
      expectedAttempt,
      snapshot!.attemptId,
      asset,
      epoch,
      draftRevision,
    );
  }());
  bool isPreviewCurrent(CreatorImageTaskPreview preview) {
    if (!_valid ||
        preview._closed ||
        preview._epoch != _epoch ||
        !identical(preview._authority, _previewAuthority)) {
      return false;
    }
    final job = jobs.byId(preview.jobId);
    return job != null &&
        jobs.isCurrentAttempt(job) &&
        job.attempt == preview.attempt &&
        job.serverImage?.snapshot?.attemptId == preview.serverAttemptId &&
        job.serverImage?.snapshot?.artifact?.matchesAsset(preview.asset) ==
            true;
  }

  Future<CreatorDraft> applyPreview(CreatorImageTaskPreview preview) =>
      _track(() async {
        _guard(preview._epoch);
        if (!isPreviewCurrent(preview) ||
            !identical(preview._authority, _previewAuthority) ||
            preview._closed ||
            !preview._presented) {
          throw StateError('task_preview_required');
        }
        final job = _sameJob(preview.jobId, preview.attempt, (job) => job);
        final binding = job.serverImage!;
        if (binding.snapshot?.attemptId != preview.serverAttemptId ||
            binding.snapshot?.artifact?.matchesAsset(preview.asset) != true) {
          throw StateError('task_artifact_changed');
        }
        final current = await _repository.get(binding.draftId);
        _guard(preview._epoch);
        if (current == null ||
            current.scopeKey != creatorScopeKey ||
            fingerprint(current) != binding.draftFingerprint) {
          throw StateError('creator_draft_changed');
        }
        final valid = await _assets.validateTaskAsset(
          preview.asset,
          binding.snapshot!.artifact!,
          expectedContextKey: creatorScopeKey,
          canContinue: () => _valid && preview._epoch == _epoch,
        );
        _guard(preview._epoch);
        if (!valid) throw StateError('task_preview_invalid');
        final applied = await _repository.applyTaskImage(
          draftId: binding.draftId,
          expectedFingerprint: binding.draftFingerprint,
          expectedApplicationRevision: preview._draftRevision,
          asset: preview.asset,
          canContinue: () => isPreviewCurrent(preview),
        );
        _guard(preview._epoch);
        await _save(
          job,
          binding.copyWith(previewAsset: preview.asset, applied: true),
          preview._epoch,
        );
        _draftChanges.add(applied);
        return applied;
      }());

  Future<void> deactivateAndDrain() => _draining ??= _drain();
  Future<void> _drain() async {
    _sealed = true;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _contextChanges?.removeListener(_contextChanged);
    for (final worker in _contextWorkers) {
      worker.dispose();
    }
    _contextWorkers.clear();
    jobs.unregisterControls(AgentTaskExecutionKind.creatorImage, this);
    _assets.cancelPendingTaskDownloads();
    final gateway = _gateway.deactivateAndDrain();
    await Future.wait(
      _operations.toList().map(
        (work) => work.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    await gateway;
    await jobs.flush();
  }

  @override
  void onClose() {
    _sealed = true;
    _epoch++;
    _timer?.cancel();
    _contextChanges?.removeListener(_contextChanged);
    for (final worker in _contextWorkers) {
      worker.dispose();
    }
    _contextWorkers.clear();
    jobs.unregisterControls(AgentTaskExecutionKind.creatorImage, this);
    _assets.cancelPendingTaskDownloads();
    unawaited(_gateway.deactivateAndDrain());
    _draftChanges.close();
    super.onClose();
  }
}
