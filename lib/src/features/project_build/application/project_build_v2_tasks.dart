import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/models/chat_attachment.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:uuid/uuid.dart';

import '../data/project_build_v2_gateway.dart';
import '../data/project_build_v2_repository.dart';
import '../domain/project_build_v2_contract.dart';
import '../domain/project_build_v2_task_binding.dart';
import '../domain/project_build_edit_identity.dart';
import '../data/project_bundle_installation_store.dart';
import '../domain/project_bundle_verification.dart';
import '../domain/project_build_v2_inventory.dart';
import '../domain/project_build_v2_delete.dart';
import '../domain/project_build_v2_head.dart';
import '../domain/project_reference_selection.dart';
import '../domain/project_build_v2_reference.dart';
import '../data/project_build_reference_admission_store.dart';

/// Native, current-account retry admission after its new attempt is observed.
/// Recovered journal events alone do not emit this presentation signal.
final class ProjectBuildV2WorkAdmittedEvent extends ClawEvent {
  ProjectBuildV2WorkAdmittedEvent._(this.tasks, this.job, this._epoch)
    : super(agentId: job.agentId);

  final ProjectBuildV2Tasks tasks;
  final AgentTaskJob job;
  final int _epoch;

  bool get isCurrent =>
      tasks._valid && tasks._epoch == _epoch && tasks._isForeground();
}

/// Account-owned transport/replay coordinator. It does not build a project or
/// grant a model capability. New admission and recovered POSTs default closed.
final class ProjectBuildV2Tasks extends AppService
    implements AgentServerTaskControls {
  ProjectBuildV2Tasks({
    required this.jobs,
    required this.installation,
    required this.verification,
    required this.presentCandidate,
    required this.persistInstalled,
    this.reconcileOwnedProjects,
    this.cleanupDeletedProject,
    this.referenceMedia,
    this.authorizeCloudImage,

    required ProjectBuildV2Repository repository,
    required HttpProjectBuildV2Gateway gateway,
    required this.scopeKey,
    required this.appletScopeKey,
    required bool Function() isCurrent,
    required Future<void> Function() authorize,
    Future<bool> Function()? canRecoverDispatch,
    bool Function()? isForeground,
    bool Function()? isCreationReady,
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
       _isCreationReady = isCreationReady ?? (() => true),
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
  final ChatMediaService? Function()? referenceMedia;
  final Future<void> Function()? authorizeCloudImage;
  final ProjectBundleInstallationStore installation;
  final ProjectBundleVerificationService verification;

  /// True only once the exact candidate is visibly mounted. Preview mode is
  /// explicit even if those same bytes were installed by a previous attempt.
  final Future<bool> Function(
    InstalledProjectBundleV2,
    VerifiedProjectBundlePermit,
    bool preview,
  )
  presentCandidate;

  /// Idempotent account-owned offline widget pointer persistence.
  final Future<void> Function(InstalledProjectBundleV2, String agentId)
  persistInstalled;
  final Future<void> Function(Set<String> projectIds)? reconcileOwnedProjects;
  final Future<void> Function(
    ProjectBuildV2DeletionProof proof,
    Set<String> localTaskIds,
  )?
  cleanupDeletedProject;
  final Set<String> _deletedProjectIds = {};
  final RxString inventoryIssue = ''.obs;
  Future<void>? _savedRecovery;
  Future<void> _ownedMutation = Future<void>.value();
  Future<void> _inventoryRead = Future<void>.value();
  final Map<String, Future<void>> _projectDeliveries = {};
  final Map<String, String> _presented = {};
  final Set<String> _delivered = {};

  final ProjectBuildV2Repository _repository;
  final HttpProjectBuildV2Gateway _gateway;
  final String scopeKey;
  final String appletScopeKey;
  final bool enableCreation;
  final int maximumPagesPerSync;
  final bool Function() _isCurrent;
  final bool Function() _isForeground;
  final bool Function() _isCreationReady;
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
  final Map<String, ({int epoch, int attempt})> _workRetryAdmissions = {};
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
  bool get canSubmit =>
      enableCreation && _valid && _isForeground() && _isCreationReady();

  @override
  void onInit() {
    super.onInit();
    jobs.registerControls(AgentTaskExecutionKind.projectBuildV2, this);
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
      _workRetryAdmissions.clear();
      _epoch++;
      return;
    }
    _authorizationBlocked.clear();
    if (!_isForeground()) {
      _workRetryAdmissions.clear();
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
        job.isProjectBuildV2 &&
        job.appletScopeKey == appletScopeKey &&
        job.projectBuildV2!.scopeKey == scopeKey &&
        !job.projectBuildV2!.isLegacyReadOnly &&
        job.projectBuildV2!.syncIssue != 'rejected:task_unavailable' &&
        jobs.isCurrentAttempt(job),
  );

  AgentTaskJob? _forRequest(String requestId) {
    for (final job in _roots) {
      if (job.projectBuildV2!.createRequestId == requestId) return job;
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
    final binding = job.projectBuildV2!;
    if (binding.syncIssue == 'rejected:task_unavailable' ||
        _deletedProjectIds.contains(binding.snapshot?.projectId)) {
      return false;
    }
    final pending = binding.pendingCommand;
    final canReplay =
        pending != null &&
        !binding.syncIssue.startsWith('rejected:') &&
        !_authorizationBlocked.contains(pending.requestId);
    return (binding.snapshot?.status == ProjectBuildV2Status.completed &&
            !_delivered.contains(job.taskId)) ||
        (_pendingRecovery[job.taskId]?.any(
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
    } on StateError catch (error) {
      if (const {
        'project_build_owned_head_stale',
        'project_build_head_conflict',
        'project_build_project_deleted',
        'project_build_mutation_pending',
        'project_build_command_conflict',
        'project_build_scope_changed',
      }.contains(error.message)) {
        rethrow;
      }
      _storageFault = true;
      _timer?.cancel();
      rethrow;
    } catch (_) {
      _storageFault = true;
      _timer?.cancel();
      rethrow;
    }
  }

  Future<void> _save(
    AgentTaskJob job,
    ProjectBuildV2TaskBinding binding,
    int epoch,
  ) async {
    _guard(epoch);
    jobs.updateProjectBuildV2Binding(
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
    String? projectId,
    String? baseRevision,
    int? baseHeadVersion,
    bool Function()? canContinue,
    ProjectReferenceSelection? referenceSelection,
    ProjectReferenceInputSnapshot? referenceInput,
    ProjectBuildEditTarget? editTarget,
  }) {
    if (editTarget != null &&
        ((projectId != null && projectId != editTarget.projectId) ||
            (baseRevision != null && baseRevision != editTarget.baseRevision) ||
            (baseHeadVersion != null &&
                baseHeadVersion != editTarget.baseHeadVersion) ||
            projectKind != editTarget.projectKind)) {
      throw StateError('project_build_edit_conflict');
    }
    final selectedProjectId = editTarget?.projectId ?? projectId;
    final selectedRevision = editTarget?.baseRevision ?? baseRevision;
    final selectedHeadVersion = editTarget?.baseHeadVersion ?? baseHeadVersion;
    if (referenceSelection != null && referenceInput != null) {
      throw const FormatException('project_reference_ambiguous_selection');
    }
    final selected =
        referenceSelection ??
        (referenceInput == null
            ? null
            : ProjectReferenceSelection.fromSnapshot(referenceInput));
    if (selected != null && selected.scopeKey != appletScopeKey) {
      throw StateError('project_build_scope_changed');
    }
    void guardAdmission() {
      if (editTarget != null) {
        _repository.validateEditTarget(
          editTarget,
          expectedScopeKey: scopeKey,
          expectedAppletScopeKey: appletScopeKey,
        );
      }
      if (canContinue != null && !canContinue()) {
        throw StateError('project_build_turn_cancelled');
      }
    }

    final predecessor = _admission;
    final work = _track(() async {
      await predecessor;
      final epoch = _epoch;
      _guard(epoch);
      guardAdmission();
      if (!canSubmit) throw StateError('project_build_admission_disabled');
      await _untilRetired(_authorize());
      _guard(epoch);
      guardAdmission();
      final permitted = await _untilRetired(_canRecoverDispatch());
      _guard(epoch);
      guardAdmission();
      if (!canSubmit || !permitted) {
        throw StateError('project_build_needs_authorization');
      }
      if (editTarget != null) {
        final owned = await _withOwnedMutation(
          () => _ownedHistory(editTarget.projectId, epoch),
        );
        _guard(epoch);
        guardAdmission();
        if (owned.history.currentRevisionId != editTarget.baseRevision ||
            owned.history.currentHeadVersion != editTarget.baseHeadVersion ||
            owned.history.current.candidateDigest !=
                editTarget.candidateDigest ||
            owned.history.current.reportDigest != editTarget.reportDigest ||
            owned.project.projectKind != editTarget.projectKind) {
          throw StateError('project_build_head_changed');
        }
      }
      final input = ProjectBuildV2CreateRequest(
        requestId: _requestId(),
        agentId: agentId,
        projectKind: projectKind,
        requirements: requirements,
        locale: locale,
        projectId: selectedProjectId,
        baseRevision: selectedRevision,
        baseHeadVersion: selectedHeadVersion,
      );
      // From prepareCreate onward the durable intent must be reconciled even
      // if its initiating foreground turn is later cancelled.
      guardAdmission();
      if (selected == null) {
        await _durable(
          () => _repository.prepareCreate(input, expectedScopeKey: scopeKey),
        );
      } else {
        await _loadReferenceMedia(selected, epoch);
        _guard(epoch);
        guardAdmission();
        await _durable(
          () => _repository.referenceAdmissions.saveSelection(
            selected,
            expectedAppletScopeKey: appletScopeKey,
          ),
        );
        _guard(epoch);
        guardAdmission();
        // This durable admission is the reference task's commit point. Its
        // original requirements and each upload nonce survive a lost reply.
        await _durable(
          () => _repository.referenceAdmissions.prepare(
            input,
            selected,
            List.generate(selected.references.length, (_) => _requestId()),
          ),
        );
      }
      _guard(epoch);
      final job = jobs.startProjectBuildV2(
        agentId: input.agentId,
        userText: input.requirements,
        appletScopeKey: appletScopeKey,
        projectKind: input.projectKind,
        binding: ProjectBuildV2TaskBinding(
          scopeKey: scopeKey,
          createRequestId: input.requestId,
          editIdentity: ProjectBuildEditIdentity.fromCreate(input),
          referenceSelectionDigest: selected?.sourceIdentityDigest,
          pendingCommand: ProjectBuildV2TaskPendingCommand(
            operation: ProjectBuildV2TaskOperation.create,
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

  /// Native selection capture is local-only. It never requests a summary or
  /// claims an upload/model observation; bytes reuse the mounted media store.
  Future<ProjectReferenceSelection> captureReferences(
    List<PreparedChatMedia> media, {
    List<ProjectReferencePurpose>? purposes,
    int inputRevision = 1,
  }) {
    if (purposes != null && purposes.length != media.length) {
      throw const FormatException('project_reference_invalid_selection');
    }
    final frozen = media
        .map(
          (m) => PreparedChatMedia(
            m.attachment,
            Uint8List.fromList(m.bytes),
            m.mime,
          ),
        )
        .toList(growable: false);
    final selection = ProjectReferenceSelection(
      scopeKey: appletScopeKey,
      inputRevision: inputRevision,
      references: [
        for (var i = 0; i < frozen.length; i++)
          ProjectReferenceImage(
            sha256: frozen[i].attachment.id,
            byteLength: frozen[i].bytes.length,
            mime: frozen[i].mime,
            purpose: purposes?[i] ?? ProjectReferencePurpose.reference,
          ),
      ],
    );
    for (final item in frozen) {
      if (item.attachment.kind != 'image' ||
          item.attachment.byteLength != item.bytes.length ||
          sha256.convert(item.bytes).toString() != item.attachment.id) {
        throw const FormatException('project_reference_invalid_bytes');
      }
    }
    return _track(() async {
      final epoch = _epoch;
      _guard(epoch);
      final owner = referenceMedia?.call();
      if (owner == null || !owner.isCurrent) {
        throw StateError('project_reference_media_unavailable');
      }
      for (final item in frozen) {
        await _untilRetired(owner.persist(item));
        _guard(epoch);
        if (!owner.isCurrent) throw StateError('project_build_scope_changed');
      }
      await _durable(
        () => _repository.referenceAdmissions.saveSelection(
          selection,
          expectedAppletScopeKey: appletScopeKey,
        ),
      );
      _guard(epoch);
      return selection;
    }());
  }

  Future<List<PreparedChatMedia>> _loadReferenceMedia(
    ProjectReferenceSelection selection,
    int epoch,
  ) async {
    _guard(epoch);
    if (selection.scopeKey != appletScopeKey) {
      throw StateError('project_build_scope_changed');
    }
    final owner = referenceMedia?.call();
    if (owner == null || !owner.isCurrent) {
      throw StateError('project_reference_media_unavailable');
    }
    final result = <PreparedChatMedia>[];
    for (final reference in selection.references) {
      final loaded = await _untilRetired(
        owner.read(
          ChatAttachment(
            id: reference.sha256,
            kind: 'image',
            byteLength: reference.byteLength,
          ),
        ),
      );
      _guard(epoch);
      if (!owner.isCurrent) throw StateError('project_build_scope_changed');
      if (loaded == null ||
          loaded.mime != reference.mime ||
          loaded.bytes.length != reference.byteLength ||
          sha256.convert(loaded.bytes).toString() != reference.sha256) {
        throw StateError('project_reference_local_media_missing');
      }
      result.add(
        PreparedChatMedia(
          loaded.attachment,
          Uint8List.fromList(loaded.bytes),
          loaded.mime,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Future<bool> _prepareReferenceCreate(AgentTaskJob job, int epoch) async {
    final id = job.projectBuildV2!.createRequestId;
    final loaded = await _durable(
      () => _repository.referenceAdmissions.read(id),
    );
    _guard(epoch);
    if (loaded == null ||
        loaded.selection.scopeKey != appletScopeKey ||
        loaded.selection.sourceIdentityDigest !=
            job.projectBuildV2!.referenceSelectionDigest) {
      await _save(
        job,
        job.projectBuildV2!.copyWith(
          syncIssue: 'rejected:reference_input_missing',
        ),
        epoch,
      );
      return false;
    }
    ProjectBuildReferenceAdmission plan = loaded;
    if (plan.rejectionCode.isNotEmpty) {
      await _save(
        job,
        job.projectBuildV2!.copyWith(
          syncIssue: 'rejected:${plan.rejectionCode}',
        ),
        epoch,
      );
      return false;
    }
    if (plan.prepared) return true;
    final permitted = await _untilRetired(_canRecoverDispatch());
    _guard(epoch);
    if (!permitted ||
        !_isForeground() ||
        !_isCreationReady() ||
        authorizeCloudImage == null) {
      await _save(
        job,
        job.projectBuildV2!.copyWith(syncIssue: 'reference_upload_unavailable'),
        epoch,
      );
      return false;
    }
    await _untilRetired(_authorize());
    _guard(epoch);
    await _untilRetired(authorizeCloudImage!());
    _guard(epoch);
    List<PreparedChatMedia>? media;
    for (var index = 0; index < plan.receipts.length; index++) {
      if (plan.receipts[index] != null) continue;
      media ??= await _loadReferenceMedia(plan.selection, epoch);
      _guard(epoch);
      final reference = plan.selection.references[index];
      final upload = ProjectBuildReferenceUploadRequest(
        requestId: plan.uploadRequestIds[index],
        mediaType: reference.mime,
        contentBase64: base64Encode(media[index].bytes),
        purpose: reference.purpose,
      );
      try {
        // Every image POST receives a fresh current-scope privacy check.
        await _untilRetired(authorizeCloudImage!());
        _guard(epoch);
        final receipt = await _gateway.uploadReference(
          request: upload,
          authorize: () async {
            await _untilRetired(authorizeCloudImage!());
            _guard(epoch);
            await _durable(
              () => _repository.referenceAdmissions.assertDispatchable(id),
            );
            _guard(epoch);
          },
          expectedContextKey: scopeKey,
          canDispatch: () =>
              _valid &&
              epoch == _epoch &&
              _isForeground() &&
              _isCreationReady(),
        );
        _guard(epoch);
        plan = await _durable(
          () =>
              _repository.referenceAdmissions.recordReceipt(id, index, receipt),
        );
        _guard(epoch);
      } on ProjectBuildV2RequestException catch (error) {
        if (error.ambiguous || error.statusCode == 429) rethrow;
        await _durable(
          () => _repository.referenceAdmissions.reject(id, error.code),
        );
        _guard(epoch);
        final latest = _latest(job.taskId);
        await _save(
          latest,
          latest.projectBuildV2!.copyWith(syncIssue: 'rejected:${error.code}'),
          epoch,
        );
        return false;
      }
    }
    plan = await _durable(() => _repository.referenceAdmissions.freeze(id));
    _guard(epoch);
    // After this freeze, even expiry or an uncertain create cannot replace
    // reference IDs under the original create nonce.
    final request = plan.frozenRequest!;
    await _durable(
      () => _repository.prepareCreate(request, expectedScopeKey: scopeKey),
    );
    _guard(epoch);
    await _durable(() => _repository.referenceAdmissions.markPrepared(id));
    _guard(epoch);
    return true;
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
    try {
      await _withOwnedMutation(() => _resumeProjectMutations(epoch));
    } catch (_) {
      _guard(epoch);
      inventoryIssue.value = 'project_build_request_pending';
    }
    final referencePlans = await _durable(
      _repository.referenceAdmissions.pending,
    );
    _guard(epoch);
    for (final plan in referencePlans) {
      if (plan.selection.scopeKey != appletScopeKey) {
        throw StateError('project_build_scope_changed');
      }
      if (_forRequest(plan.requestId) == null) {
        jobs.restoreProjectBuildV2(
          agentId: plan.draft.agentId,
          userText: plan.draft.requirements,
          appletScopeKey: appletScopeKey,
          projectKind: plan.draft.projectKind,
          createdAt: DateTime.now(),
          binding: ProjectBuildV2TaskBinding(
            scopeKey: scopeKey,
            createRequestId: plan.requestId,
            editIdentity: ProjectBuildEditIdentity.fromCreate(plan.draft),
            referenceSelectionDigest: plan.selection.sourceIdentityDigest,
            pendingCommand: ProjectBuildV2TaskPendingCommand(
              operation: ProjectBuildV2TaskOperation.create,
              requestId: plan.requestId,
            ),
          ),
        );
      }
      await _recoverEditIdentity(
        _forRequest(plan.requestId)!,
        plan.draft,
        epoch,
      );
    }
    final legacy = await _durable(
      () => _repository.legacyCreateRequestIds(expectedScopeKey: scopeKey),
    );
    _guard(epoch);
    for (final job in jobs.jobs.toList()) {
      final binding = job.projectBuildV2;
      if (job.appletScopeKey == appletScopeKey &&
          binding?.scopeKey == scopeKey &&
          legacy.contains(binding!.createRequestId) &&
          !binding.isLegacyReadOnly) {
        await _save(job, binding.copyWith(syncIssue: 'legacy_contract'), epoch);
      }
    }
    final projections = await _durable(
      () => _repository.list(expectedScopeKey: scopeKey),
    );
    _guard(epoch);
    for (final projection in projections) {
      final referencePlan = await _durable(
        () => _repository.referenceAdmissions.read(projection.input.requestId),
      );
      _guard(epoch);
      var job = _forRequest(projection.input.requestId);
      job ??= jobs.restoreProjectBuildV2(
        agentId: projection.input.agentId,
        userText: projection.input.requirements,
        appletScopeKey: appletScopeKey,
        projectKind: projection.input.projectKind,
        createdAt:
            projection.snapshot?.createdAt ??
            projection.remoteHead?.createdAt ??
            DateTime.now(),
        binding: ProjectBuildV2TaskBinding(
          scopeKey: scopeKey,
          createRequestId: projection.input.requestId,
          editIdentity: ProjectBuildEditIdentity.fromCreate(projection.input),
          referenceSelectionDigest:
              referencePlan?.selection.sourceIdentityDigest,
          taskId: projection.taskId,
        ),
      );
      job = await _recoverEditIdentity(job, projection.input, epoch);
      await _durable(jobs.flush);
      await _replay(job.taskId, projection, epoch);
      if (await _repository.isDelivered(
        projection.taskId,
        expectedScopeKey: scopeKey,
      )) {
        _delivered.add(job.taskId);
      }
      _guard(epoch);
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
        final referencePlan = await _durable(
          () => _repository.referenceAdmissions.read(input.requestId),
        );
        _guard(epoch);
        job =
            _forRequest(input.requestId) ??
            jobs.restoreProjectBuildV2(
              agentId: input.agentId,
              userText: input.requirements,
              appletScopeKey: appletScopeKey,
              projectKind: input.projectKind,
              createdAt: DateTime.now(),
              binding: ProjectBuildV2TaskBinding(
                scopeKey: scopeKey,
                createRequestId: input.requestId,
                editIdentity: ProjectBuildEditIdentity.fromCreate(input),
                referenceSelectionDigest:
                    referencePlan?.selection.sourceIdentityDigest,
                pendingCommand: _pending(request),
                syncIssue: request.rejectionCode.isEmpty
                    ? ''
                    : 'rejected:${request.rejectionCode}',
              ),
            );
        job = await _recoverEditIdentity(job, input, epoch);
      } else {
        for (final candidate in _roots) {
          if (candidate.projectBuildV2!.taskId == request.taskId) {
            job = candidate;
            break;
          }
        }
      }
      if (job == null) continue;
      final binding = job.projectBuildV2!;
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
        job.projectBuildV2!.copyWith(
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
                (probeTerminal && job.projectBuildV2!.taskId != null),
          )
          .map((job) => synchronize(job.taskId))
          .toList(),
    );
  }

  Future<AgentTaskJob> _recoverEditIdentity(
    AgentTaskJob job,
    ProjectBuildV2CreateRequest input,
    int epoch,
  ) async {
    final identity = ProjectBuildEditIdentity.fromCreate(input);
    if (job.projectBuildV2!.editIdentity == identity) return job;
    final proof = await _durable(
      () => _repository.durableCreate(
        input.requestId,
        expectedScopeKey: scopeKey,
      ),
    );
    _guard(epoch);
    if (proof == null) throw StateError('project_build_create_missing');
    final updated = jobs.restoreProjectBuildV2EditIdentity(
      job.id,
      proof,
      expectedScopeKey: appletScopeKey,
      expectedRepositoryScopeKey: scopeKey,
    );
    await _durable(jobs.flush);
    _guard(epoch);
    return updated;
  }

  Future<AgentTaskJob> _restorePending(
    String root,
    ProjectBuildV2PendingRequest request,
    int epoch,
  ) async {
    _guard(epoch);
    final job = jobs.restoreProjectBuildV2PendingCommand(
      _latest(root).id,
      request,
      expectedScopeKey: appletScopeKey,
      expectedRepositoryScopeKey: scopeKey,
    );
    await _durable(jobs.flush);
    _guard(epoch);
    return job;
  }

  ProjectBuildV2TaskPendingCommand _pending(
    ProjectBuildV2PendingRequest request, {
    int? accepted,
  }) => ProjectBuildV2TaskPendingCommand(
    operation: request.create != null
        ? ProjectBuildV2TaskOperation.create
        : ProjectBuildV2TaskOperation.values.byName(
            request.command!.operation.name,
          ),
    candidateDigest: request.command?.candidateDigest,
    baseRevision: request.command?.baseRevision,
    expectedHeadVersion: request.command?.expectedHeadVersion,
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
      if (job.projectBuildV2!.referenceSelectionDigest != null &&
          job.projectBuildV2!.taskId == null) {
        if (!await _prepareReferenceCreate(job, epoch)) return;
        job = _latest(root);
      }
      final requests = await _durable(
        () => _repository.pendingRequests(expectedScopeKey: scopeKey),
      );
      _guard(epoch);
      for (final request in requests.where(
        (request) => request.create != null
            ? request.requestId == job.projectBuildV2!.createRequestId
            : request.taskId == job.projectBuildV2!.taskId,
      )) {
        job = await _restorePending(root, request, epoch);
        if (request.create != null ||
            request.command!.operation == ProjectBuildV2Operation.retry) {
          final permitted = await _untilRetired(_canRecoverDispatch());
          _guard(epoch);
          if (!permitted || !_isCreationReady()) {
            _authorizationBlocked.add(request.requestId);
            await _save(
              _latest(root),
              _latest(root).projectBuildV2!.copyWith(
                syncIssue: _isCreationReady()
                    ? 'needs_authorization'
                    : 'generation_unavailable',
              ),
              epoch,
            );
            continue;
          }
        }
        ProjectBuildV2Receipt receipt;
        var usesImages = request.create?.referenceInputs.isNotEmpty ?? false;
        if (request.command?.operation == ProjectBuildV2Operation.retry) {
          final original = await _durable(
            () => _repository.read(request.taskId!, expectedScopeKey: scopeKey),
          );
          _guard(epoch);
          usesImages =
              original?.input.referenceInputs.isNotEmpty ??
              job.projectBuildV2!.referenceSelectionDigest != null;
        }
        Future<void> authorizeImages() async {
          if (authorizeCloudImage == null) {
            throw StateError('reference_upload_unavailable');
          }
          await _untilRetired(authorizeCloudImage!());
          _guard(epoch);
        }

        try {
          receipt = request.create != null
              ? await _gateway.create(
                  request: request.create!,
                  authorize: usesImages ? authorizeImages : null,
                  expectedContextKey: scopeKey,
                  canDispatch: () =>
                      _valid &&
                      _epoch == epoch &&
                      _isForeground() &&
                      _isCreationReady(),
                )
              : await _gateway.command(
                  taskId: request.taskId!,
                  command: request.command!,
                  authorize: usesImages ? authorizeImages : null,
                  expectedContextKey: scopeKey,
                  canDispatch:
                      request.command!.operation ==
                          ProjectBuildV2Operation.retry
                      ? () =>
                            _valid &&
                            _epoch == epoch &&
                            _isForeground() &&
                            _isCreationReady()
                      : null,
                );
        } on ProjectBuildV2RequestException catch (error) {
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
            job.projectBuildV2!.copyWith(
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
        final binding = job.projectBuildV2!;
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
        final acceptedPending = job.projectBuildV2!.pendingCommand;
        if (acceptedPending?.acceptedTaskSequence != null &&
            acceptedPending!.acceptedTaskSequence! <=
                job.projectBuildV2!.appliedTaskSequence) {
          await _save(
            job,
            job.projectBuildV2!.copyWith(clearPending: true),
            epoch,
          );
        }
        await _replay(root, projection, epoch);
      }
      job = _latest(root);
      final task = job.projectBuildV2!.taskId;
      if (task == null) return;
      ProjectBuildV2Snapshot head;
      try {
        head = await _gateway.snapshot(
          taskId: task,
          expectedContextKey: scopeKey,
        );
      } on ProjectBuildV2RequestException catch (error) {
        if (error.statusCode != 404) rethrow;
        _guard(epoch);
        await _durable(
          () =>
              _repository.markTaskUnavailable(task, expectedScopeKey: scopeKey),
        );
        _guard(epoch);
        final retired = _latest(root);
        await _save(
          retired,
          retired.projectBuildV2!.copyWith(
            clearPending: true,
            syncIssue: 'rejected:task_unavailable',
          ),
          epoch,
        );
        _pendingRecovery.remove(root);
        _replayHorizons.remove(root);
        return;
      }
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
          job.projectBuildV2!.copyWith(syncIssue: 'needs_authorization'),
          epoch,
        );
        job = _latest(root);
      }
      if (!job.projectBuildV2!.syncIssue.startsWith('rejected:') &&
          job.projectBuildV2!.syncIssue != 'needs_authorization') {
        await _save(job, job.projectBuildV2!.copyWith(syncIssue: ''), epoch);
      }
      if (job.projectBuildV2!.snapshot?.status ==
              ProjectBuildV2Status.completed &&
          !_delivered.contains(root)) {
        await _deliver(job, epoch);
      }
      _failures = 0;
    } catch (error) {
      if (!_valid || epoch != _epoch) return;
      _failures++;
      final job = _latest(root);
      // Only native, known reference failures may become public task codes.
      // Other exception text can include private provider or image data.
      const referenceIssues = {
        'project_reference_local_media_missing': 'reference_input_missing',
        'project_reference_media_unavailable': 'reference_upload_unavailable',
        'reference_upload_unavailable': 'reference_upload_unavailable',
      };
      await _save(
        job,
        job.projectBuildV2!.copyWith(
          syncIssue: error is ProjectBuildV2RequestException
              ? error.code
              : (error is StateError ? referenceIssues[error.message] : null) ??
                    'project_build_sync_unavailable',
        ),
        epoch,
      );
    }
  }

  Future<void> _replay(
    String root,
    ProjectBuildV2Projection projection,
    int epoch,
  ) async {
    final horizon = [
      projection.appliedTaskSequence,
      projection.receipt.acceptedTaskSequence,
      projection.remoteHead?.snapshotTaskSequence ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    if (horizon > (_replayHorizons[root] ?? 0)) _replayHorizons[root] = horizon;
    var job = _latest(root);
    if (job.projectBuildV2!.taskId == null) {
      await _save(
        job,
        job.projectBuildV2!.copyWith(taskId: projection.taskId),
        epoch,
      );
    }
    for (var pages = 0; pages < maximumPagesPerSync; pages++) {
      _guard(epoch);
      job = _latest(root);
      final cursor = job.projectBuildV2!.appliedTaskSequence;
      if (cursor >= projection.appliedTaskSequence) return;
      final page = await _repository.readEvents(
        projection.taskId,
        afterTaskSequence: cursor,
        expectedScopeKey: scopeKey,
      );
      _guard(epoch);
      for (final event in page.events) {
        jobs.applyProjectBuildV2Event(
          root,
          event,
          expectedScopeKey: appletScopeKey,
          agentId: job.agentId,
        );
        _publishRetryWork(root, epoch);
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
        !job.isProjectBuildV2 ||
        job.appletScopeKey != appletScopeKey ||
        job.projectBuildV2!.scopeKey != scopeKey ||
        !jobs.isCurrentAttempt(job) ||
        (_pendingRecovery[job.taskId]?.isNotEmpty ?? false) ||
        _controlling.contains(job.taskId)) {
      return false;
    }
    final binding = job.projectBuildV2!;
    if (_deletedProjectIds.contains(binding.snapshot?.projectId) ||
        binding.syncIssue == 'rejected:task_unavailable' ||
        binding.isLegacyReadOnly ||
        binding.pendingCommand != null ||
        binding.snapshot == null) {
      return false;
    }
    return retry
        ? canSubmit && binding.snapshot!.status.retryable
        : {
            ProjectBuildV2Status.queued,
            ProjectBuildV2Status.running,
            ProjectBuildV2Status.previewReady,
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
              job.projectBuildV2!.pendingCommand != null ||
              (retry && !canSubmit)) {
            return false;
          }
          final snapshot = job.projectBuildV2!.snapshot!;
          if (retry
              ? !snapshot.status.retryable
              : !{
                  ProjectBuildV2Status.queued,
                  ProjectBuildV2Status.running,
                  ProjectBuildV2Status.previewReady,
                }.contains(snapshot.status)) {
            return false;
          }
          if (retry) {
            final permitted = await _untilRetired(_canRecoverDispatch());
            _guard(epoch);
            if (!permitted ||
                !canSubmit ||
                _latest(root).id != id ||
                _latest(root).projectBuildV2!.snapshot?.statusVersion !=
                    snapshot.statusVersion) {
              return false;
            }
          }
          final command = ProjectBuildV2Command(
            operation: retry
                ? ProjectBuildV2Operation.retry
                : ProjectBuildV2Operation.cancel,
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
          if (retry) {
            _workRetryAdmissions[root] = (epoch: epoch, attempt: attempt + 1);
          }
          // A concurrent sync may have advanced the card after prepare.
          // Reconcile the durable intent through the one per-root dispatcher;
          // never write the pre-prepare snapshot back over an accepted receipt.
          await _syncs[root];
          _guard(epoch);
          await synchronize(root);
          _guard(epoch);
          _publishRetryWork(root, epoch);
          return true;
        } finally {
          _controlling.remove(root);
        }
      }());

  void _publishRetryWork(String root, int epoch) {
    final admission = _workRetryAdmissions[root];
    if (admission == null ||
        admission.epoch != epoch ||
        !_valid ||
        _epoch != epoch ||
        !_isForeground()) {
      return;
    }
    final job = _latest(root);
    if (job.attempt < admission.attempt) {
      if (job.projectBuildV2!.syncIssue.startsWith('rejected:')) {
        _workRetryAdmissions.remove(root);
      }
      return;
    }
    _workRetryAdmissions.remove(root);
    if (job.attempt == admission.attempt &&
        job.status == AgentTaskJobStatus.running &&
        jobs.isCurrentAttempt(job)) {
      EventBus().fire(ProjectBuildV2WorkAdmittedEvent._(this, job, epoch));
    }
  }

  String _candidateKey(AgentTaskJob job) {
    final snapshot = job.projectBuildV2!.snapshot!;
    return '${snapshot.runId}:${snapshot.attempt}:${snapshot.candidate!.candidateDigest}:${snapshot.candidate!.reportDigest}';
  }

  bool canPreview(AgentTaskJob job) =>
      _valid &&
      _isForeground() &&
      job.isProjectBuildV2 &&
      job.appletScopeKey == appletScopeKey &&
      job.projectBuildV2!.scopeKey == scopeKey &&
      !job.projectBuildV2!.isLegacyReadOnly &&
      !_deletedProjectIds.contains(job.projectBuildV2!.snapshot?.projectId) &&
      jobs.isCurrentAttempt(job) &&
      job.projectBuildV2!.snapshot?.status ==
          ProjectBuildV2Status.previewReady &&
      job.projectBuildV2!.pendingCommand == null;
  bool canAccept(AgentTaskJob job) =>
      canPreview(job) &&
      !_controlling.contains(job.taskId) &&
      _presented[job.taskId] == _candidateKey(job);
  bool canOpen(AgentTaskJob job) =>
      _valid &&
      job.isProjectBuildV2 &&
      job.appletScopeKey == appletScopeKey &&
      job.projectBuildV2!.scopeKey == scopeKey &&
      !job.projectBuildV2!.isLegacyReadOnly &&
      job.projectBuildV2!.syncIssue != 'rejected:task_unavailable' &&
      !_deletedProjectIds.contains(job.projectBuildV2!.snapshot?.projectId) &&
      jobs.isCurrentAttempt(job) &&
      job.projectBuildV2!.snapshot?.status == ProjectBuildV2Status.completed &&
      _delivered.contains(job.taskId);

  Future<bool> preview(String jobId, {required int expectedAttempt}) =>
      _track(() async {
        var job = jobs.byId(jobId);
        if (job == null || job.attempt != expectedAttempt || !canPreview(job)) {
          return false;
        }
        final epoch = _epoch;
        final key = _candidateKey(job);
        final root = job.taskId;
        final candidate = await _gateway.candidate(
          taskId: job.projectBuildV2!.taskId!,
          expectedContextKey: scopeKey,
        );
        _guard(epoch);
        job = _latest(root);
        if (job.id != jobId ||
            !canPreview(job) ||
            key != _candidateKey(job) ||
            !candidate.matches(job.projectBuildV2!.snapshot!)) {
          return false;
        }
        final permit = await verification.verifyReport(
          candidate.bundle,
          candidate.report,
          expectedReportDigest: candidate.reference.reportDigest,
        );
        _guard(epoch);
        final staged = await installation.stageCandidate(
          candidate.bundle,
          expectedScopeKey: installation.scopeKey,
          verificationReport: candidate.report,
        );
        _guard(epoch);
        job = _latest(root);
        if (!canPreview(job) || key != _candidateKey(job)) return false;
        final visible = await _untilRetired(
          presentCandidate(staged, permit, true),
        );
        _guard(epoch);
        job = _latest(root);
        if (!visible ||
            !permit.isCurrent ||
            !canPreview(job) ||
            key != _candidateKey(job)) {
          return false;
        }
        _presented[root] = key;
        // Drive the existing reactive card; this changes no server history.
        jobs.jobs.refresh();
        return true;
      }());

  Future<bool> accept(String jobId, {required int expectedAttempt}) => _track(
    () async {
      final initial = jobs.byId(jobId);
      if (initial == null ||
          initial.attempt != expectedAttempt ||
          !canAccept(initial)) {
        return false;
      }
      final root = initial.taskId, key = _candidateKey(initial);
      final epoch = _epoch;
      _controlling.add(root);
      try {
        await _syncs[root];
        _guard(epoch);
        final job = _latest(root),
            snapshot = _latest(root).projectBuildV2!.snapshot!;
        if (job.id != jobId ||
            key != _candidateKey(job) ||
            _presented[root] != key ||
            snapshot.status != ProjectBuildV2Status.previewReady ||
            job.projectBuildV2!.pendingCommand != null) {
          return false;
        }
        final command = ProjectBuildV2Command(
          operation: ProjectBuildV2Operation.accept,
          requestId: _requestId(),
          expectedRunId: snapshot.runId,
          expectedStatusVersion: snapshot.statusVersion,
          candidateDigest: snapshot.candidate!.candidateDigest,
          baseRevision: snapshot.candidate!.baseRevision,
          expectedHeadVersion: snapshot.candidate!.baseHeadVersion ?? 0,
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
        await _syncs[root];
        await synchronize(root);
        _guard(epoch);
        // Accepted means the user's command is durable; only completed journal
        // plus verified local persistence makes canOpen true.
        return true;
      } finally {
        _controlling.remove(root);
      }
    }(),
  );

  Future<T> _withOwnedMutation<T>(Future<T> Function() body) {
    final work = _ownedMutation.then((_) => body());
    _ownedMutation = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  Future<ProjectBuildV2OwnedProjects> _fetchOwnedProjects(int epoch) {
    final work = _inventoryRead.then((_) async {
      _guard(epoch);
      final inventory = await _gateway.projects(expectedContextKey: scopeKey);
      _guard(epoch);
      await _durable(
        () => _repository.recordOwnedProjects(
          inventory,
          expectedScopeKey: scopeKey,
        ),
      );
      _guard(epoch);
      // Only this freshly committed complete owner list may restore membership
      // after a previous absence. Installing old proof cannot authorize itself.
      await reconcileOwnedProjects?.call(
        Set.unmodifiable(
          inventory.projects.map((project) => project.projectId),
        ),
      );
      _guard(epoch);
      return inventory;
    });
    _inventoryRead = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  Future<T> _withProjectDelivery<T>(
    String projectId,
    Future<T> Function() body,
  ) {
    final previous = _projectDeliveries[projectId] ?? Future<void>.value();
    final work = previous.then((_) => body());
    late Future<void> settled;
    settled = work
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_projectDeliveries[projectId], settled)) {
            _projectDeliveries.remove(projectId);
          }
        });
    _projectDeliveries[projectId] = settled;
    return work;
  }

  bool get canManageSavedProjects => _valid && _isForeground();

  Future<ProjectBuildV2OwnedRevisions> savedRevisionHistory(String projectId) =>
      _track(
        _withOwnedMutation(() async {
          final epoch = _epoch;
          _guard(epoch);
          if (!canManageSavedProjects) {
            throw StateError('project_build_not_foreground');
          }
          return (await _ownedHistory(projectId, epoch)).history;
        }),
      );

  /// Called only after native confirmation of this exact head and the deletion
  /// of the work, every saved version and its production history.
  Future<bool> deleteSavedProject(
    String projectId, {
    required String expectedRevision,
    required int expectedHeadVersion,
  }) => _track(
    _withOwnedMutation(() async {
      if (!canManageSavedProjects || cleanupDeletedProject == null) {
        return false;
      }
      final epoch = _epoch;
      try {
        final pending = await _durable(
          () => _repository.prepareProjectDeletion(
            projectId,
            ProjectBuildV2DeleteRequest(
              requestId: _requestId(),
              expectedRevision: expectedRevision,
              expectedHeadVersion: expectedHeadVersion,
            ),
            expectedScopeKey: scopeKey,
          ),
        );
        _guard(epoch);
        return await _recoverDeletion(pending, epoch);
      } catch (_) {
        if (_valid && epoch == _epoch) {
          inventoryIssue.value = 'project_build_request_pending';
        }
        return false;
      }
    }),
  );

  /// Opening a historical revision never calls this method. A native user
  /// confirmation authorizes moving the server's current revision pointer.
  Future<bool> rollbackSavedProject(
    String projectId, {
    required String targetRevision,
    required int expectedHeadVersion,
  }) => _track(
    _withOwnedMutation(() async {
      if (!canManageSavedProjects) return false;
      final epoch = _epoch;
      try {
        final pending = await _durable(
          () => _repository.prepareProjectRollback(
            projectId,
            ProjectBuildV2RollbackRequest(
              requestId: _requestId(),
              targetRevision: targetRevision,
              expectedHeadVersion: expectedHeadVersion,
            ),
            expectedScopeKey: scopeKey,
          ),
        );
        _guard(epoch);
        return await _recoverRollback(pending, epoch);
      } catch (_) {
        if (_valid && epoch == _epoch) {
          inventoryIssue.value = 'project_build_request_pending';
        }
        return false;
      }
    }),
  );

  Future<void> _resumeProjectMutations(int epoch) async {
    _guard(epoch);
    final deletions = await _durable(
      () => _repository.pendingProjectDeletions(expectedScopeKey: scopeKey),
    );
    _guard(epoch);
    for (final pending in deletions) {
      if (pending.proof != null) _deletedProjectIds.add(pending.projectId);
      if (cleanupDeletedProject == null) {
        throw StateError('project_delete_cleanup_unavailable');
      }
      await _recoverDeletion(pending, epoch);
    }
    final rollbacks = await _durable(
      () => _repository.pendingProjectRollbacks(expectedScopeKey: scopeKey),
    );
    _guard(epoch);
    for (final pending in rollbacks) {
      await _recoverRollback(pending, epoch);
    }
  }

  Future<bool> _recoverDeletion(
    ProjectBuildV2PendingDeletion pending,
    int epoch,
  ) async {
    _guard(epoch);
    var proof = pending.proof;
    if (proof == null) {
      try {
        final receipt = await _gateway.deleteProject(
          projectId: pending.projectId,
          request: pending.request,
          expectedContextKey: scopeKey,
          canDispatch: () => _valid && _epoch == epoch && _isForeground(),
        );
        _guard(epoch);
        proof = await _durable(
          () => _repository.recordProjectDeletionReceipt(
            receipt,
            expectedScopeKey: scopeKey,
          ),
        );
      } on ProjectBuildV2RequestException catch (error) {
        if (error.ambiguous || error.statusCode == 429) rethrow;
        _guard(epoch);
        await _durable(
          () => _repository.rejectProjectDeletion(
            pending.request.requestId,
            error.code,
            expectedScopeKey: scopeKey,
          ),
        );
        inventoryIssue.value = 'rejected:${error.code}';
        return false;
      }
    }
    _guard(epoch);
    final committed =
        proof ?? (throw StateError('project_delete_receipt_missing'));
    _deletedProjectIds.add(committed.projectId);
    await installation.purgeDeletedProject(
      committed,
      expectedScopeKey: installation.scopeKey,
      expectedProjectBuildScopeKey: scopeKey,
    );
    _guard(epoch);
    final removed = await _durable(
      () => jobs.purgeProjectBuildV2(
        committed,
        expectedScopeKey: appletScopeKey,
        expectedRepositoryScopeKey: scopeKey,
      ),
    );
    await _durable(() => _repository.referenceAdmissions.purge(committed));
    _guard(epoch);
    for (final root in removed) {
      _delivered.remove(root);
      _presented.remove(root);
      _pendingRecovery.remove(root);
      _replayHorizons.remove(root);
    }
    final cleanup = cleanupDeletedProject;
    if (cleanup == null) throw StateError('project_delete_cleanup_unavailable');
    await cleanup(committed, removed);
    _guard(epoch);
    await _durable(
      () => _repository.finishProjectDeletion(
        committed,
        expectedScopeKey: scopeKey,
      ),
    );
    _guard(epoch);
    inventoryIssue.value = '';
    return true;
  }

  Future<bool> _recoverRollback(
    ProjectBuildV2PendingRollback pending,
    int epoch,
  ) async {
    _guard(epoch);
    var accepted = pending;
    if (pending.receipt == null) {
      try {
        final receipt = await _gateway.rollbackProject(
          projectId: pending.projectId,
          request: pending.request,
          expectedContextKey: scopeKey,
          canDispatch: () => _valid && _epoch == epoch && _isForeground(),
        );
        _guard(epoch);
        accepted = await _durable(
          () => _repository.recordProjectRollbackReceipt(
            receipt,
            expectedScopeKey: scopeKey,
          ),
        );
      } on ProjectBuildV2RequestException catch (error) {
        if (error.ambiguous || error.statusCode == 429) rethrow;
        _guard(epoch);
        await _durable(
          () => _repository.rejectProjectRollback(
            pending.request.requestId,
            error.code,
            expectedScopeKey: scopeKey,
          ),
        );
        inventoryIssue.value = 'rejected:${error.code}';
        return false;
      }
    }
    _guard(epoch);
    final fresh = await _ownedHistory(pending.projectId, epoch);
    // Another device may already have advanced the head again. Install only
    // fresh server authority; the original rollback receipt stays unchanged.
    if (fresh.history.currentHeadVersion < accepted.receipt!.headVersion) {
      throw StateError('project_build_owned_head_stale');
    }
    await _withProjectDelivery(
      pending.projectId,
      () => _cacheOwnedRevision(
        fresh.project,
        fresh.history.current,
        epoch,
        updateCurrent: true,
      ),
    );
    _guard(epoch);
    await _durable(
      () => _repository.finishProjectRollback(
        pending.request.requestId,
        expectedScopeKey: scopeKey,
      ),
    );
    _guard(epoch);
    inventoryIssue.value = '';
    return true;
  }

  /// Invoke after the first app frame and on foreground recovery. Discovery is
  /// bounded (five projects, 128 revision descriptors each), serial per project,
  /// and creates offline pointers, never invented task/event history.
  Future<void> restoreSavedProjects() {
    if (!_valid || !_isForeground()) return Future<void>.value();
    final previous = _savedRecovery;
    if (previous != null) return previous;
    late Future<void> work;
    work = _track(
      _withOwnedMutation(() async {
        final epoch = _epoch;
        try {
          await _resumeProjectMutations(epoch);
          final inventory = await _fetchOwnedProjects(epoch);
          for (final project in inventory.projects) {
            await _withProjectDelivery(project.projectId, () async {
              _guard(epoch);
              final history = await _gateway.revisions(
                projectId: project.projectId,
                expectedContextKey: scopeKey,
              );
              _guard(epoch);
              await _durable(
                () => _repository.recordOwnedRevisions(
                  history,
                  expectedScopeKey: scopeKey,
                ),
              );
              _guard(epoch);
              await _cacheOwnedRevision(
                project,
                history.current,
                epoch,
                updateCurrent: true,
              );
            });
          }
          _guard(epoch);
          await _fetchOwnedProjects(epoch);
          _guard(epoch);
          inventoryIssue.value = '';
        } catch (_) {
          if (_valid && epoch == _epoch) {
            inventoryIssue.value = 'project_build_inventory_unavailable';
          }
        }
      }),
    ).whenComplete(() => _savedRecovery = null);
    _savedRecovery = work;
    return work;
  }

  Future<
    ({ProjectBuildV2OwnedProject project, ProjectBuildV2OwnedRevisions history})
  >
  _ownedHistory(String projectId, int epoch) async {
    final inventory = await _fetchOwnedProjects(epoch);
    final matches = inventory.projects.where((p) => p.projectId == projectId);
    if (matches.isEmpty) throw StateError('project_build_project_removed');
    final history = await _gateway.revisions(
      projectId: projectId,
      expectedContextKey: scopeKey,
    );
    _guard(epoch);
    await _durable(
      () =>
          _repository.recordOwnedRevisions(history, expectedScopeKey: scopeKey),
    );
    _guard(epoch);
    return (project: matches.single, history: history);
  }

  Future<ProjectBuildEditTarget> prepareEditTarget(
    String projectId, {
    required String expectedRevisionId,
    required int expectedHeadVersion,
    required String expectedCandidateDigest,
  }) => _track(
    _withOwnedMutation(() async {
      final epoch = _epoch;
      _guard(epoch);
      if (!canManageSavedProjects) {
        throw StateError('project_build_not_foreground');
      }
      final owned = await _ownedHistory(projectId, epoch);
      _guard(epoch);
      if (owned.history.currentRevisionId != expectedRevisionId ||
          owned.history.currentHeadVersion != expectedHeadVersion ||
          owned.history.current.candidateDigest != expectedCandidateDigest) {
        throw StateError('project_build_head_changed');
      }
      final target = await _repository.captureEditTarget(
        projectId: projectId,
        revisionId: expectedRevisionId,
        headVersion: expectedHeadVersion,
        candidateDigest: expectedCandidateDigest,
        appletScopeKey: appletScopeKey,
        expectedScopeKey: scopeKey,
        isAdmissionCurrent: () => _valid && epoch == _epoch,
      );
      _guard(epoch);
      return target;
    }),
  );

  Future<InstalledProjectBundleV2> _cacheOwnedRevision(
    ProjectBuildV2OwnedProject project,
    ProjectBuildV2RevisionDescriptor target,
    int epoch, {
    required bool updateCurrent,
  }) async {
    var cached = await installation.openCandidate(
      target.candidateDigest,
      expectedScopeKey: installation.scopeKey,
      reportDigest: target.reportDigest,
    );
    _guard(epoch);
    if (cached == null || cached.verificationReport == null) {
      final candidate = await _gateway.revision(
        projectId: project.projectId,
        revisionId: target.revisionId,
        expectedContextKey: scopeKey,
      );
      _guard(epoch);
      if (!target.matches(candidate) ||
          candidate.bundle.manifest.projectKind != project.projectKind.name) {
        throw StateError('project_build_owned_revision_mismatch');
      }
      await verification.verifyReport(
        candidate.bundle,
        candidate.report,
        expectedReportDigest: target.reportDigest,
      );
      _guard(epoch);
      cached = await installation.stageCandidate(
        candidate.bundle,
        expectedScopeKey: installation.scopeKey,
        verificationReport: candidate.report,
      );
      _guard(epoch);
    }
    if (cached.bundle.manifest.projectId != project.projectId ||
        cached.bundle.manifest.revisionId != target.revisionId ||
        cached.bundle.manifest.baseRevision != target.baseRevision ||
        cached.bundle.manifest.projectKind != project.projectKind.name) {
      throw StateError('project_build_owned_revision_mismatch');
    }
    final permit = await verification.verifyReport(
      cached.bundle,
      cached.verificationReport,
      expectedReportDigest: target.reportDigest,
    );
    _guard(epoch);
    // Re-read authority after a potentially large download. A revision list is
    // a bounded DAG; only its monotonic head version authorizes a head move.
    final fresh = await _gateway.revisions(
      projectId: project.projectId,
      expectedContextKey: scopeKey,
    );
    _guard(epoch);
    await _durable(
      () => _repository.recordOwnedRevisions(fresh, expectedScopeKey: scopeKey),
    );
    _guard(epoch);
    final proof = await _repository.ownedRevision(
      project.projectId,
      target.revisionId,
      expectedScopeKey: scopeKey,
    );
    _guard(epoch);
    if (proof == null ||
        proof.candidateDigest != target.candidateDigest ||
        proof.reportDigest != target.reportDigest) {
      throw StateError('project_build_owned_revision_changed');
    }
    var accepted = await installation.cacheAcceptedHistorical(
      cached.bundle,
      expectedScopeKey: installation.scopeKey,
      ownedRevision: proof,
      expectedProjectBuildScopeKey: scopeKey,
      permit: permit,
      verificationReport: cached.verificationReport!,
    );
    _guard(epoch);
    if (updateCurrent) {
      if (fresh.currentRevisionId != target.revisionId) {
        throw StateError('project_build_owned_head_changed');
      }
      final local = await installation.openCurrent(
        project.projectId,
        expectedScopeKey: installation.scopeKey,
      );
      _guard(epoch);
      if (local != null &&
          local.headVersion == null &&
          local.candidateDigest == cached.candidateDigest) {
        accepted = await installation.adoptCurrentHead(
          proof,
          expectedScopeKey: installation.scopeKey,
          expectedProjectBuildScopeKey: scopeKey,
          permit: permit,
          verificationReport: cached.verificationReport!,
        );
      } else {
        accepted = await installation.install(
          cached.bundle,
          expectedScopeKey: installation.scopeKey,
          expectedCurrentCandidateDigest: local?.candidateDigest,
          expectedHeadVersion: local?.headVersion,
          expectedProjectBuildScopeKey: scopeKey,
          ownedRevision: proof,
          permit: permit,
          verificationReport: cached.verificationReport!,
        );
      }
      _guard(epoch);
      await persistInstalled(accepted, project.agentId);
      _guard(epoch);
    }
    return accepted;
  }

  Future<void> _deliver(AgentTaskJob job, int epoch) async {
    final snapshot = job.projectBuildV2!.snapshot!,
        reference = job.projectBuildV2!.snapshot!.candidate!;
    if (snapshot.status != ProjectBuildV2Status.completed) {
      throw StateError('project_build_not_saved');
    }
    await _withOwnedMutation(
      () => _withProjectDelivery(snapshot.projectId, () async {
        final owned = await _ownedHistory(snapshot.projectId, epoch);
        final target = owned.history.revisions.singleWhere(
          (r) => r.revisionId == reference.revisionId,
        );
        if (target.candidateDigest != reference.candidateDigest ||
            target.reportDigest != reference.reportDigest ||
            target.baseRevision != reference.baseRevision ||
            owned.project.projectKind != snapshot.projectKind) {
          throw StateError('project_build_owned_revision_mismatch');
        }
        await _cacheOwnedRevision(
          owned.project,
          target,
          epoch,
          updateCurrent: owned.history.currentRevisionId == target.revisionId,
        );
        if (owned.history.currentRevisionId != target.revisionId) {
          await _cacheOwnedRevision(
            owned.project,
            owned.history.current,
            epoch,
            updateCurrent: true,
          );
        }
      }),
    );
    _guard(epoch);
    await _durable(
      () => _repository.markDelivered(
        snapshot.taskId,
        reference.candidateDigest,
        expectedScopeKey: scopeKey,
      ),
    );
    _guard(epoch);
    _delivered.add(job.taskId);
    jobs.jobs.refresh();
  }

  Future<ProjectBuildV2OwnedProjects?> savedProjects() =>
      _repository.readOwnedProjects(expectedScopeKey: scopeKey);

  /// History is owner-scoped. Cached accepted bytes reopen offline; a cache
  /// miss may fetch that saved revision without changing the current pointer.
  Future<bool> openSavedRevision(String projectId, String revisionId) =>
      _track(() async {
        final epoch = _epoch;
        _guard(epoch);
        var proof = await _repository.ownedRevision(
          projectId,
          revisionId,
          expectedScopeKey: scopeKey,
        );
        _guard(epoch);
        var cached = proof == null
            ? null
            : await installation.openCandidate(
                proof.candidateDigest,
                expectedScopeKey: installation.scopeKey,
                reportDigest: proof.reportDigest,
              );
        _guard(epoch);
        if (cached == null ||
            !cached.isAccepted ||
            cached.verificationReport == null) {
          cached = await _withProjectDelivery(projectId, () async {
            final owned = await _ownedHistory(projectId, epoch);
            final target = owned.history.revisions.singleWhere(
              (r) => r.revisionId == revisionId,
            );
            return _cacheOwnedRevision(
              owned.project,
              target,
              epoch,
              updateCurrent: false,
            );
          });
          proof = await _repository.ownedRevision(
            projectId,
            revisionId,
            expectedScopeKey: scopeKey,
          );
          _guard(epoch);
        }
        if (proof == null ||
            cached == null ||
            cached.bundle.manifest.revisionId != revisionId ||
            cached.bundle.manifest.projectId != projectId) {
          return false;
        }
        final permit = await verification.verifyReport(
          cached.bundle,
          cached.verificationReport,
          expectedReportDigest: proof.reportDigest,
        );
        _guard(epoch);
        final visible = await _untilRetired(
          presentCandidate(cached, permit, false),
        );
        _guard(epoch);
        return visible;
      }());

  Future<bool> open(String jobId, {required int expectedAttempt}) =>
      _track(() async {
        final job = jobs.byId(jobId);
        if (job == null || job.attempt != expectedAttempt || !canOpen(job)) {
          return false;
        }
        final epoch = _epoch,
            reference = job.projectBuildV2!.snapshot!.candidate!;
        final installed = await installation.openCandidate(
          reference.candidateDigest,
          expectedScopeKey: installation.scopeKey,
          reportDigest: reference.reportDigest,
        );
        _guard(epoch);
        if (installed == null ||
            !installed.isAccepted ||
            installed.verificationReport == null) {
          return false;
        }
        final permit = await verification.verifyReport(
          installed.bundle,
          installed.verificationReport,
          expectedReportDigest: reference.reportDigest,
        );
        _guard(epoch);
        final visible = await _untilRetired(
          presentCandidate(installed, permit, false),
        );
        _guard(epoch);
        return visible;
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
    _workRetryAdmissions.clear();
    if (!_retirement.isCompleted) _retirement.complete();
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _contextChanges?.removeListener(_contextChanged);
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    jobs.unregisterControls(AgentTaskExecutionKind.projectBuildV2, this);
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
