import 'dart:convert';

import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';
import '../domain/project_build_v2_contract.dart';
import '../domain/project_build_v2_inventory.dart';
import '../domain/project_build_v2_node.dart';
import '../domain/project_build_v2_delete.dart';
import '../domain/project_build_v2_head.dart';
import '../domain/project_build_edit_identity.dart';
import 'project_build_reference_admission_store.dart';

/// Recovery reuses this exact persisted body and nonce when acknowledgement is
/// unknown; it never infers a new user request from a network timeout.
final class ProjectBuildV2PendingRequest {
  ProjectBuildV2PendingRequest._(
    this.scopeKey,
    this.create,
    this.command,
    this.taskId,
    this.rejectionCode,
  );
  final String scopeKey;
  final ProjectBuildV2CreateRequest? create;
  final ProjectBuildV2Command? command;
  final String? taskId;
  final String rejectionCode;
  String get requestId => create?.requestId ?? command!.requestId;

  factory ProjectBuildV2PendingRequest._parse(Map<String, Object?> row) {
    final scope = row['scopeKey'];
    if (scope is! String || scope.isEmpty || scope.length > 512) {
      throw const FormatException('project_build_invalid_request_scope');
    }
    final rejection = row['rejectionCode'] ?? '';
    if (rejection is! String ||
        (rejection.isNotEmpty &&
            !RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(rejection))) {
      throw const FormatException('project_build_invalid_rejection');
    }
    if (row['operation'] == 'create') {
      return ProjectBuildV2PendingRequest._(
        scope,
        ProjectBuildV2CreateRequest.fromJson(projectBuildV2Object(row['body'])),
        null,
        null,
        rejection,
      );
    }
    return ProjectBuildV2PendingRequest._(
      scope,
      null,
      ProjectBuildV2Command.fromJson(
        projectBuildV2Object(row['body']),
        operation: ProjectBuildV2Operation.values.byName(
          row['operation']! as String,
        ),
      ),
      projectBuildV2Id(row['taskId'], 'task'),
      rejection,
    );
  }
}

final class ProjectBuildV2Projection {
  ProjectBuildV2Projection._(
    this.scopeKey,
    this.input,
    this.receipt,
    this.snapshot,
    this.remoteHead,
    this.nodes,
  );
  final String scopeKey;
  final ProjectBuildV2CreateRequest input;
  final ProjectBuildV2Receipt receipt;
  final ProjectBuildV2Snapshot? snapshot;
  final ProjectBuildV2Snapshot? remoteHead;
  final List<ProjectBuildV2Node> nodes;
  String get taskId => receipt.taskId;
  int get appliedTaskSequence => snapshot?.snapshotTaskSequence ?? 0;

  factory ProjectBuildV2Projection._parse(
    Map<String, Object?> row,
    String scope,
  ) {
    if (row['scopeKey'] != scope) {
      throw StateError('project_build_scope_changed');
    }
    final projection = ProjectBuildV2Projection._(
      scope,
      ProjectBuildV2CreateRequest.fromJson(projectBuildV2Object(row['input'])),
      ProjectBuildV2Receipt.fromJson(projectBuildV2Object(row['receipt'])),
      row['snapshot'] == null
          ? null
          : ProjectBuildV2Snapshot.fromJson(
              projectBuildV2Object(row['snapshot']),
            ),
      row['remoteHead'] == null
          ? null
          : ProjectBuildV2Snapshot.fromJson(
              projectBuildV2Object(row['remoteHead']),
            ),
      parseProjectBuildV2Nodes(
        row.containsKey('nodes') ? row['nodes'] : const [],
      ),
    );
    if (row['taskId'] != projection.taskId ||
        row['cursor'] != projection.appliedTaskSequence ||
        (projection.nodes.isNotEmpty &&
            row['nodesRunId'] != projection.snapshot?.runId)) {
      throw const FormatException('invalid_project_build_projection');
    }
    for (final snapshot in [projection.snapshot, projection.remoteHead]) {
      if (snapshot != null &&
          (snapshot.taskId != projection.taskId ||
              snapshot.agentId != projection.input.agentId ||
              snapshot.projectKind != projection.input.projectKind ||
              (projection.input.projectId != null &&
                  projection.input.projectId != snapshot.projectId) ||
              (snapshot.candidate != null &&
                  (snapshot.candidate!.baseRevision !=
                          projection.input.baseRevision ||
                      snapshot.candidate!.baseHeadVersion !=
                          projection.input.baseHeadVersion)))) {
        throw const FormatException('project_build_projection_identity');
      }
    }
    return projection;
  }
}

/// Scope-bound proof reconstructed only from this repository's committed owned
/// inventory. It never invents the original task's missing execution journal.
final class ProjectBuildV2OwnedRevision {
  ProjectBuildV2OwnedRevision._(
    this.scopeKey,
    this.project,
    this.revision,
    this.currentRevisionId,
    this.currentHeadVersion,
    this._isScopeCurrent,
  );
  final bool Function() _isScopeCurrent;
  bool get isScopeCurrent => _isScopeCurrent();
  final String scopeKey;
  final ProjectBuildV2OwnedProject project;
  final ProjectBuildV2RevisionDescriptor revision;
  final String currentRevisionId;
  final int currentHeadVersion;
  bool get isCurrent => currentRevisionId == revisionId;
  String get projectId => project.projectId;
  String get revisionId => revision.revisionId;
  String? get baseRevision => revision.baseRevision;
  String get candidateDigest => revision.candidateDigest;
  String get reportDigest => revision.reportDigest;
}

/// Native, process-local selection issued from a committed owned-current proof.
/// isCurrent is an issuer/mount fence, not a claim that the server head has
/// stayed unchanged. Admission must read the head again before persisting work.
final class ProjectBuildEditTarget {
  ProjectBuildEditTarget._(
    this._issuer,
    this.scopeKey,
    this.appletScopeKey,
    this.title,
    this.agentId,
    this.projectKind,
    this.identity,
    this.candidateDigest,
    this.reportDigest,
    this._isCurrent,
  );
  final Object _issuer;
  final bool Function() _isCurrent;
  final String scopeKey, appletScopeKey, title, agentId;
  final ProjectBuildKind projectKind;
  final ProjectBuildEditIdentity identity;
  final String candidateDigest, reportDigest;
  bool get isCurrent => _isCurrent();
  String get projectId => identity.projectId;
  String get baseRevision => identity.baseRevision;
  int get baseHeadVersion => identity.baseHeadVersion;
}

/// Original durable create input, never reconstructed from a later remote head.
/// Used only to recover missing audit metadata on old local task rows.
final class ProjectBuildV2DurableCreate {
  ProjectBuildV2DurableCreate._(this.scopeKey, this.input, this._isCurrent);
  final String scopeKey;
  final ProjectBuildV2CreateRequest input;
  final bool Function() _isCurrent;
  bool get isScopeCurrent => _isCurrent();
}

/// A server delete receipt bound to its original durable nonce and account
/// mount. Only the repository may create this authority for local cleanup.
final class ProjectBuildV2DeletionProof {
  ProjectBuildV2DeletionProof._(
    this.scopeKey,
    this.receipt,
    Iterable<String> taskIds,
    Iterable<String> createRequestIds,
    this._isScopeCurrent,
  ) : taskIds = List.unmodifiable(taskIds),
      createRequestIds = List.unmodifiable(createRequestIds);
  final String scopeKey;
  final ProjectBuildV2DeleteReceipt receipt;
  final bool Function() _isScopeCurrent;
  bool get isScopeCurrent => _isScopeCurrent();
  final List<String> taskIds, createRequestIds;
  String get projectId => receipt.projectId;
  String get deletedRevisionId => receipt.deletedRevisionId;
  DateTime get deletedAt => receipt.deletedAt;
}

final class ProjectBuildV2PendingDeletion {
  ProjectBuildV2PendingDeletion._(
    this.scopeKey,
    this.projectId,
    this.request,
    this.proof,
    this.rejectionCode,
    this.localCleanupComplete,
  );
  final String scopeKey, projectId, rejectionCode;
  final ProjectBuildV2DeleteRequest request;
  final ProjectBuildV2DeletionProof? proof;
  final bool localCleanupComplete;
  factory ProjectBuildV2PendingDeletion._parse(
    Map<String, Object?> row,
    String scope,
    bool Function() isScopeCurrent,
  ) {
    if (row['scopeKey'] != scope) {
      throw StateError('project_build_scope_changed');
    }
    final project = projectBuildV2Id(row['projectId'], 'project'),
        request = ProjectBuildV2DeleteRequest.fromJson(row['body']);
    final receipt = row['receipt'] == null
        ? null
        : ProjectBuildV2DeleteReceipt.fromJson(row['receipt']);
    if (receipt != null &&
        (receipt.projectId != project ||
            receipt.requestId != request.requestId ||
            receipt.deletedRevisionId != request.expectedRevision ||
            receipt.headVersion != request.expectedHeadVersion + 1)) {
      throw const FormatException('project_delete_receipt_identity');
    }
    final tasks = (row['deletedTaskIds'] as List? ?? const [])
        .map((id) => projectBuildV2Id(id, 'task'))
        .toList();
    final requests = (row['deletedCreateRequestIds'] as List? ?? const [])
        .cast<String>();
    if (requests.any((id) => !RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(id))) {
      throw const FormatException('project_delete_requests');
    }
    final rejection = row['rejectionCode'] as String? ?? '';
    if (rejection.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(rejection)) {
      throw const FormatException('project_delete_rejection');
    }
    return ProjectBuildV2PendingDeletion._(
      scope,
      project,
      request,
      receipt == null
          ? null
          : ProjectBuildV2DeletionProof._(
              scope,
              receipt,
              tasks,
              requests,
              isScopeCurrent,
            ),
      rejection,
      row['localCleanupComplete'] == true,
    );
  }
}

final class ProjectBuildV2PendingRollback {
  ProjectBuildV2PendingRollback._(
    this.scopeKey,
    this.projectId,
    this.request,
    this.target,
    this.receipt,
    this.rejectionCode,
    this.settled,
  );
  final String scopeKey, projectId, rejectionCode;
  final ProjectBuildV2RollbackRequest request;
  final ProjectBuildV2RevisionDescriptor target;
  final ProjectBuildV2RollbackReceipt? receipt;
  final bool settled;
  factory ProjectBuildV2PendingRollback._parse(
    Map<String, Object?> row,
    String scope,
  ) {
    if (row['scopeKey'] != scope) {
      throw StateError('project_build_scope_changed');
    }
    final project = projectBuildV2Id(row['projectId'], 'project');
    final request = ProjectBuildV2RollbackRequest.fromJson(row['body']);
    final target = ProjectBuildV2RevisionDescriptor.fromJson(row['target']);
    final receipt = row['receipt'] == null
        ? null
        : ProjectBuildV2RollbackReceipt.fromJson(row['receipt']);
    final rejection = row['rejectionCode'] as String? ?? '';
    if (!RegExp(r'^[A-Za-z0-9_.:-]{0,64}$').hasMatch(rejection) ||
        target.revisionId != request.targetRevision ||
        (receipt != null &&
            (receipt.requestId != request.requestId ||
                receipt.projectId != project ||
                receipt.revisionId != target.revisionId ||
                receipt.headVersion != request.expectedHeadVersion + 1 ||
                receipt.candidateDigest != target.candidateDigest ||
                receipt.reportDigest != target.reportDigest))) {
      throw const FormatException('project_rollback_identity');
    }
    return ProjectBuildV2PendingRollback._(
      scope,
      project,
      request,
      target,
      receipt,
      rejection,
      row['settled'] == true,
    );
  }
}

/// Account-mounted durable projection. It has no worker, timer or implicit
/// submission; the tracker separately rebuilds task cards from its journal.
/// All scope authority comes from the caller's mount.
final class ProjectBuildV2Repository {
  ProjectBuildV2Repository({
    required DBService database,
    required this.scopeKey,
    required bool Function() isCurrent,
  }) : _database = database,
       _isCurrent = isCurrent,
       referenceAdmissions = ProjectBuildReferenceAdmissionStore(
         database: database.raw,
         scopeKey: scopeKey,
         isCurrent: isCurrent,
       ) {
    if (scopeKey.isEmpty || scopeKey.length > 512) {
      throw ArgumentError('invalid_project_build_scope');
    }
  }

  final DBService _database;
  final String scopeKey;
  final bool Function() _isCurrent;
  final Object _editIssuer = Object();
  final ProjectBuildReferenceAdmissionStore referenceAdmissions;
  static final _intents = stringMapStoreFactory.store(
    'project_build_v2_intents',
  );
  static final _tasks = stringMapStoreFactory.store(
    'project_build_v2_projections',
  );
  static final _events = stringMapStoreFactory.store(
    'project_build_v2_journal',
  );

  static final _ownedProjects = stringMapStoreFactory.store(
    'project_build_v2_owned_projects',
  );
  static final _ownedRevisions = stringMapStoreFactory.store(
    'project_build_v2_owned_revisions',
  );

  static final _projectDeletions = stringMapStoreFactory.store(
    'project_build_v2_project_deletions',
  );

  static final _projectRollbacks = stringMapStoreFactory.store(
    'project_build_v2_project_rollbacks',
  );
  static final _tombstones = stringMapStoreFactory.store(
    'project_build_v2_tombstones',
  );

  String _key(String id) => jsonEncode([scopeKey, id]);
  String _eventKey(String task, int sequence) =>
      jsonEncode([scopeKey, task, sequence]);

  void _guard(String expected) {
    if (expected != scopeKey || !_isCurrent()) {
      throw StateError('project_build_scope_changed');
    }
  }

  Future<ProjectBuildEditTarget> captureEditTarget({
    required String projectId,
    required String revisionId,
    required int headVersion,
    required String candidateDigest,
    required String appletScopeKey,
    required String expectedScopeKey,
    required bool Function() isAdmissionCurrent,
  }) async {
    _guard(expectedScopeKey);
    final proof = await ownedRevision(
      projectId,
      revisionId,
      expectedScopeKey: expectedScopeKey,
    );
    _guard(expectedScopeKey);
    if (!isAdmissionCurrent()) throw StateError('project_build_scope_changed');
    if (proof == null ||
        !proof.isCurrent ||
        !proof.isScopeCurrent ||
        proof.currentHeadVersion != headVersion ||
        proof.candidateDigest != candidateDigest) {
      throw StateError('project_build_head_changed');
    }
    return ProjectBuildEditTarget._(
      _editIssuer,
      scopeKey,
      appletScopeKey,
      proof.project.title,
      proof.project.agentId,
      proof.project.projectKind,
      ProjectBuildEditIdentity(
        projectId: projectId,
        baseRevision: revisionId,
        baseHeadVersion: headVersion,
      ),
      proof.candidateDigest,
      proof.reportDigest,
      () => _isCurrent() && isAdmissionCurrent(),
    );
  }

  void validateEditTarget(
    ProjectBuildEditTarget target, {
    required String expectedScopeKey,
    required String expectedAppletScopeKey,
  }) {
    _guard(expectedScopeKey);
    if (!identical(target._issuer, _editIssuer) ||
        !target.isCurrent ||
        target.scopeKey != scopeKey ||
        target.appletScopeKey != expectedAppletScopeKey) {
      throw StateError('project_build_scope_changed');
    }
  }

  Future<ProjectBuildV2DurableCreate?> durableCreate(
    String requestId, {
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    final row = await _intents.record(_key(requestId)).get(_database.raw);
    _guard(expectedScopeKey);
    ProjectBuildV2CreateRequest? input;
    if (row != null && row['operation'] == 'create') {
      final persisted = ProjectBuildV2PendingRequest._parse(row);
      if (persisted.scopeKey != scopeKey) {
        throw StateError('project_build_scope_changed');
      }
      input = persisted.create;
    } else {
      final plan = await referenceAdmissions.read(requestId);
      _guard(expectedScopeKey);
      input = plan?.frozenRequest ?? plan?.draft;
    }
    if (input == null) return null;
    if (input.requestId != requestId) {
      throw StateError('project_build_request_identity');
    }
    return ProjectBuildV2DurableCreate._(scopeKey, input, _isCurrent);
  }

  Future<void> prepareCreate(
    ProjectBuildV2CreateRequest request, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    if (request.projectId != null &&
        await _tombstones
            .record(_key('project:${request.projectId}'))
            .exists(tx)) {
      throw StateError('project_build_project_deleted');
    }
    await _putIntent(tx, request.requestId, {
      'scopeKey': scopeKey,
      'operation': 'create',
      'body': request.toJson(),
    });
  });

  Future<void> prepareCommand(
    String taskId,
    ProjectBuildV2Command command, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final projection = ProjectBuildV2Projection._parse(
      await _task(tx, taskId),
      scopeKey,
    );
    final snapshot = projection.snapshot;
    // Replaying an already persisted nonce does not need a still-current UI
    // revision; an actually new command must capture the projected revision.
    final record = _intents.record(_key(command.requestId));
    final row = {
      'scopeKey': scopeKey,
      'operation': command.operation.name,
      'taskId': taskId,
      'body': command.toJson(),
    };
    final existing = await record.get(tx);
    if (existing != null) {
      _sameIntent(existing, row);
      return;
    }
    if (snapshot == null ||
        snapshot.runId != command.expectedRunId ||
        snapshot.statusVersion != command.expectedStatusVersion ||
        (command.operation == ProjectBuildV2Operation.retry
            ? !snapshot.status.retryable
            : command.operation == ProjectBuildV2Operation.accept
            ? snapshot.status != ProjectBuildV2Status.previewReady ||
                  snapshot.candidate?.candidateDigest !=
                      command.candidateDigest ||
                  snapshot.candidate?.baseRevision != command.baseRevision ||
                  (snapshot.candidate?.baseHeadVersion ?? 0) !=
                      command.expectedHeadVersion
            : !{
                ProjectBuildV2Status.queued,
                ProjectBuildV2Status.running,
                ProjectBuildV2Status.previewReady,
              }.contains(snapshot.status))) {
      throw StateError('project_build_command_conflict');
    }
    await record.put(tx, {
      ...row,
      'expectedAttempt': snapshot.attempt,
      'baseTaskSequence': snapshot.snapshotTaskSequence,
      if (command.operation == ProjectBuildV2Operation.accept)
        'expectedSavedRevision': {
          'projectId': snapshot.projectId,
          'revisionId': snapshot.candidate!.revisionId,
          'candidateDigest': snapshot.candidate!.candidateDigest,
          'reportDigest': snapshot.candidate!.reportDigest,
          'headVersion': command.expectedHeadVersion! + 1,
        },
    });
  });

  Future<void> _putIntent(
    Transaction tx,
    String requestId,
    Map<String, Object?> intent,
  ) async {
    if (await _tombstones.record(_key('request:$requestId')).exists(tx)) {
      throw StateError('project_build_project_deleted');
    }
    final record = _intents.record(_key(requestId));
    final old = await record.get(tx);
    if (old != null) {
      _sameIntent(old, intent);
      return;
    }
    await record.put(tx, intent);
  }

  void _sameIntent(Map<String, Object?> old, Map<String, Object?> next) {
    for (final key in ['scopeKey', 'operation', 'taskId']) {
      if (old[key] != next[key]) {
        throw StateError('project_build_idempotency_conflict');
      }
    }
    if (jsonEncode(old['body']) != jsonEncode(next['body'])) {
      throw StateError('project_build_idempotency_conflict');
    }
  }

  /// The receipt identifies accepted work. It never advances the journal cursor.
  Future<ProjectBuildV2Projection> recordReceipt(
    ProjectBuildV2Receipt receipt, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    if (await _tombstones
            .record(_key('request:${receipt.requestId}'))
            .exists(tx) ||
        await _tombstones.record(_key('task:${receipt.taskId}')).exists(tx)) {
      throw StateError('project_build_project_deleted');
    }
    final intentRef = _intents.record(_key(receipt.requestId));
    final intent = await intentRef.get(tx);
    if (intent == null || intent['scopeKey'] != scopeKey) {
      throw StateError('project_build_request_unknown');
    }
    if (intent['receipt'] != null &&
        jsonEncode(intent['receipt']) != jsonEncode(receipt.toJson())) {
      throw StateError('project_build_receipt_conflict');
    }
    final taskRef = _tasks.record(_key(receipt.taskId));
    var row = await taskRef.get(tx);
    if (intent['operation'] == 'create') {
      final input = ProjectBuildV2CreateRequest.fromJson(
        projectBuildV2Object(intent['body']),
      );
      if (receipt.savedRevision != null ||
          receipt.attempt != 1 ||
          receipt.acceptedTaskSequence != 1 ||
          input.requestId != receipt.requestId) {
        throw StateError('project_build_receipt_conflict');
      }
      if (row != null &&
          jsonEncode(row['input']) != jsonEncode(input.toJson())) {
        throw StateError('project_build_task_identity');
      }
      row ??= {
        'scopeKey': scopeKey,
        'taskId': receipt.taskId,
        'input': input.toJson(),
        'receipt': receipt.toJson(),
        'cursor': 0,
      };
    } else {
      if (row == null || intent['taskId'] != receipt.taskId) {
        throw StateError('project_build_task_identity');
      }
      final command = ProjectBuildV2Command.fromJson(
        projectBuildV2Object(intent['body']),
        operation: ProjectBuildV2Operation.values.byName(
          intent['operation']! as String,
        ),
      );
      final retry = command.operation == ProjectBuildV2Operation.retry;
      if (command.operation == ProjectBuildV2Operation.accept &&
          jsonEncode(receipt.savedRevision?.toJson()) !=
              jsonEncode(intent['expectedSavedRevision'])) {
        throw StateError('project_build_receipt_conflict');
      }
      if ((command.operation == ProjectBuildV2Operation.accept) !=
              (receipt.savedRevision != null) ||
          (receipt.savedRevision != null &&
              (receipt.savedRevision!.candidateDigest !=
                      command.candidateDigest ||
                  receipt.savedRevision!.projectId !=
                      ProjectBuildV2Projection._parse(
                        row,
                        scopeKey,
                      ).snapshot?.projectId))) {
        throw StateError('project_build_receipt_conflict');
      }
      if (receipt.attempt !=
              (intent['expectedAttempt']! as int) + (retry ? 1 : 0) ||
          receipt.acceptedTaskSequence <=
              (intent['baseTaskSequence']! as int) ||
          (retry
              ? receipt.runId == command.expectedRunId
              : receipt.runId != command.expectedRunId)) {
        throw StateError('project_build_receipt_conflict');
      }
    }
    final old = ProjectBuildV2Projection._parse(row, scopeKey);
    final acceptedEvent = await _event(
      tx,
      receipt.taskId,
      receipt.acceptedTaskSequence,
    );
    if (acceptedEvent != null) {
      _assertReceiptEvent(
        receipt,
        intent['operation']! as String,
        acceptedEvent,
      );
    } else if (receipt.acceptedTaskSequence <= old.appliedTaskSequence) {
      throw StateError('project_build_receipt_event_missing');
    }
    if (receipt.acceptedTaskSequence >= old.receipt.acceptedTaskSequence) {
      row = {...row, 'receipt': receipt.toJson()};
    }
    await intentRef.put(tx, {...intent, 'receipt': receipt.toJson()});
    await taskRef.put(tx, row);
    return ProjectBuildV2Projection._parse(row, scopeKey);
  });

  Future<ProjectBuildV2Projection?> read(
    String taskId, {
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    projectBuildV2Id(taskId, 'task');
    final row = await _tasks.record(_key(taskId)).get(_database.raw);
    _guard(expectedScopeKey);
    return row == null ? null : ProjectBuildV2Projection._parse(row, scopeKey);
  }

  Future<List<ProjectBuildV2PendingRequest>> pendingRequests({
    required String expectedScopeKey,
    bool includeRejected = false,
  }) async {
    _guard(expectedScopeKey);
    final rows = await _intents.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    final unavailable = await _tasks.find(
      _database.raw,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('unavailable', true),
        ]),
      ),
    );
    _guard(expectedScopeKey);
    final retired = unavailable.map((r) => r.value['taskId']).toSet();
    return List.unmodifiable([
      for (final row in rows)
        if (!retired.contains(row.value['taskId']) &&
            row.value['operation'] != 'deleted' &&
            !_legacyIntent(row.value) &&
            row.value['receipt'] == null &&
            (includeRejected || row.value['rejectionCode'] == null))
          ProjectBuildV2PendingRequest._parse(row.value),
    ]);
  }

  Future<void> rejectRequest(
    String requestId,
    String code, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    if (!RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(code)) {
      throw ArgumentError('project_build_invalid_rejection');
    }
    final record = _intents.record(_key(requestId));
    final row = await record.get(tx);
    if (row == null || row['scopeKey'] != scopeKey || row['receipt'] != null) {
      throw StateError('project_build_request_not_pending');
    }
    await record.put(tx, {...row, 'rejectionCode': code});
  });

  /// Bounded replay from the committed journal, for independently persisted UI
  /// projections. Reading a remote head or receipt cannot fill a missing step.
  Future<ProjectBuildV2EventPage> readEvents(
    String taskId, {
    required int afterTaskSequence,
    int limit = 100,
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    if (afterTaskSequence < 0 ||
        limit < 1 ||
        limit > projectBuildV2MaximumPageSize) {
      throw ArgumentError('project_build_invalid_journal_cursor');
    }
    final projection = ProjectBuildV2Projection._parse(
      await _task(tx, taskId),
      scopeKey,
    );
    if (afterTaskSequence > projection.appliedTaskSequence) {
      throw StateError('project_build_cursor_ahead');
    }
    final events = <ProjectBuildV2Event>[];
    for (
      var sequence = afterTaskSequence + 1;
      sequence <= projection.appliedTaskSequence && events.length < limit;
      sequence++
    ) {
      final event = await _event(tx, taskId, sequence);
      if (event == null) throw StateError('project_build_event_gap');
      events.add(event);
    }
    final next = events.isEmpty ? afterTaskSequence : events.last.taskSequence;
    return ProjectBuildV2EventPage.fromJson(
      {
        'events': events.map((event) => event.toJson()).toList(),
        'nextTaskSequence': next,
        'hasMore': next < projection.appliedTaskSequence,
      },
      taskId: taskId,
      afterTaskSequence: afterTaskSequence,
    );
  });

  /// Known pre-counter records remain on disk but cannot be redispatched.
  /// This does not rewrite their nonce/body or turn a failed decode into consent.
  Future<Set<String>> legacyCreateRequestIds({
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    final tasks = await _tasks.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    final intents = await _intents.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    _guard(expectedScopeKey);
    final legacyTaskIds = intents
        .where((r) => _legacyIntent(r.value))
        .map((r) => r.value['taskId'])
        .toSet();
    return Set.unmodifiable({
      for (final row in tasks)
        if (_legacyProjection(row.value) ||
            legacyTaskIds.contains(row.value['taskId']))
          projectBuildV2Object(row.value['input'])['requestId']! as String,
      for (final row in intents)
        if (_legacyIntent(row.value) && row.value['operation'] == 'create')
          projectBuildV2Object(row.value['body'])['requestId']! as String,
    });
  }

  Future<List<ProjectBuildV2Projection>> list({
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    final quarantined = await legacyCreateRequestIds(
      expectedScopeKey: expectedScopeKey,
    );
    final rows = await _tasks.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    _guard(expectedScopeKey);
    return List.unmodifiable([
      for (final row in rows)
        if (row.value['unavailable'] != true &&
            !_legacyProjection(row.value) &&
            !quarantined.contains(
              projectBuildV2Object(row.value['input'])['requestId'],
            ))
          ProjectBuildV2Projection._parse(row.value, scopeKey),
    ]);
  }

  /// An authenticated, current-scope task GET returned not-found. Retain
  /// local audit data but never recreate work or use a new create nonce.
  Future<void> markTaskUnavailable(
    String taskId, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final row = await _task(tx, taskId);
    await _tasks.record(_key(taskId)).put(tx, {...row, 'unavailable': true});
  });

  /// A head is a synchronization target, not proof that intervening events have
  /// been consumed. The projected snapshot/cursor stay unchanged until replay.
  Future<ProjectBuildV2Projection> noteRemoteHead(
    ProjectBuildV2Snapshot head, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final row = await _task(tx, head.taskId);
    final current = ProjectBuildV2Projection._parse(row, scopeKey);
    _identity(current, head);
    if (head.snapshotTaskSequence <= current.appliedTaskSequence) {
      final recorded = await _journalSnapshot(
        tx,
        head.taskId,
        head.snapshotTaskSequence,
      );
      if (recorded == null || !recorded.sameState(head)) {
        throw StateError('project_build_snapshot_conflict');
      }
      return current;
    }
    final previous = current.remoteHead;
    if (previous != null &&
        previous.snapshotTaskSequence > head.snapshotTaskSequence) {
      return current;
    }
    if (previous != null &&
        previous.snapshotTaskSequence == head.snapshotTaskSequence &&
        !previous.sameState(head)) {
      throw StateError('project_build_snapshot_conflict');
    }
    final next = {...row, 'remoteHead': head.toJson()};
    await _tasks.record(_key(head.taskId)).put(tx, next);
    return ProjectBuildV2Projection._parse(next, scopeKey);
  });

  Future<ProjectBuildV2Projection> applyPage(
    String taskId,
    ProjectBuildV2EventPage page, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    var row = await _task(tx, taskId);
    var current = ProjectBuildV2Projection._parse(row, scopeKey);
    final acceptedRequests = await _intents.find(
      tx,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('receipt.taskId', taskId),
        ]),
      ),
    );
    for (final event in page.events) {
      if (event.taskId != taskId) {
        throw StateError('project_build_event_identity');
      }
      for (final request in acceptedRequests) {
        final receipt = ProjectBuildV2Receipt.fromJson(
          projectBuildV2Object(request.value['receipt']),
        );
        if (receipt.acceptedTaskSequence == event.taskSequence) {
          _assertReceiptEvent(
            receipt,
            request.value['operation']! as String,
            event,
          );
        }
      }
      if (event.taskSequence <= current.appliedTaskSequence) {
        final previous = await _event(tx, taskId, event.taskSequence);
        if (previous == null || !previous.sameEvent(event)) {
          throw StateError('project_build_event_conflict');
        }
        continue;
      }
      if (event.taskSequence != current.appliedTaskSequence + 1) {
        throw StateError('project_build_event_gap');
      }
      if (current.snapshot == null && event.runId != current.receipt.runId) {
        throw StateError('project_build_receipt_event_conflict');
      }
      final nextSnapshot = _transition(current.snapshot, event);
      _identity(current, nextSnapshot);
      final nextNodes = event is ProjectBuildV2NodeDelta
          ? applyProjectBuildV2Node(current.nodes, event.node)
          : current.snapshot?.runId != nextSnapshot.runId
          ? <ProjectBuildV2Node>[]
          : current.nodes;
      final head = current.remoteHead;
      if (head != null &&
          head.snapshotTaskSequence == event.taskSequence &&
          !head.sameState(nextSnapshot)) {
        throw StateError('project_build_snapshot_conflict');
      }
      await _events.record(_eventKey(taskId, event.taskSequence)).put(tx, {
        'scopeKey': scopeKey,
        'event': event.toJson(),
        'projectionSnapshot': nextSnapshot.toJson(),
      });
      row = {
        ...row,
        'snapshot': nextSnapshot.toJson(),
        'nodesRunId': nextSnapshot.runId,
        'nodes': nextNodes.map((node) => node.toJson()).toList(),
        'cursor': event.taskSequence,
      };
      current = ProjectBuildV2Projection._parse(row, scopeKey);
    }
    if (page.nextTaskSequence > current.appliedTaskSequence) {
      throw StateError('project_build_event_gap');
    }
    await _tasks.record(_key(taskId)).put(tx, row);
    return current;
  });

  void _identity(
    ProjectBuildV2Projection current,
    ProjectBuildV2Snapshot snapshot,
  ) {
    final known = current.snapshot ?? current.remoteHead;
    if (snapshot.taskId != current.taskId ||
        snapshot.agentId != current.input.agentId ||
        snapshot.projectKind != current.input.projectKind ||
        (current.input.projectId != null &&
            current.input.projectId != snapshot.projectId) ||
        (snapshot.candidate != null &&
            (snapshot.candidate!.baseRevision != current.input.baseRevision ||
                snapshot.candidate!.baseHeadVersion !=
                    current.input.baseHeadVersion)) ||
        (known != null &&
            (known.projectId != snapshot.projectId ||
                known.createdAt != snapshot.createdAt))) {
      throw StateError('project_build_snapshot_identity');
    }
  }

  void _assertReceiptEvent(
    ProjectBuildV2Receipt receipt,
    String operation,
    ProjectBuildV2Event event,
  ) {
    if (event is! ProjectBuildV2StateEvent) {
      throw StateError('project_build_receipt_event_conflict');
    }
    final validType = switch (operation) {
      'create' => event.type == 'task.created',
      'retry' => event.type == 'run.retried',
      'accept' =>
        event.type == 'run.completed' &&
            jsonEncode(receipt.savedRevision?.toJson()) ==
                jsonEncode(event.snapshot.savedRevision?.toJson()),
      'cancel' =>
        event.type == 'run.cancelled' || event.type == 'run.cancel_requested',
      _ => false,
    };
    if (!validType ||
        receipt.taskId != event.taskId ||
        receipt.acceptedTaskSequence != event.taskSequence ||
        receipt.runId != event.runId ||
        receipt.attempt != event.snapshot.attempt) {
      throw StateError('project_build_receipt_event_conflict');
    }
  }

  ProjectBuildV2Snapshot _transition(
    ProjectBuildV2Snapshot? previous,
    ProjectBuildV2Event event,
  ) {
    final next = event.resolveSnapshot(previous);
    if (previous == null) {
      if (event.taskSequence != 1 ||
          event.sequence != 1 ||
          next.attempt != 1 ||
          next.statusVersion != 1 ||
          next.status != ProjectBuildV2Status.queued ||
          event.type != 'task.created') {
        throw StateError('project_build_initial_event');
      }
      return next;
    }
    if (next.updatedAt.isBefore(previous.updatedAt)) {
      throw StateError('project_build_time_regressed');
    }
    if (next.runId != previous.runId) {
      if (!previous.status.retryable ||
          next.attempt != previous.attempt + 1 ||
          event.sequence != 1 ||
          next.statusVersion != 1 ||
          next.status != ProjectBuildV2Status.queued ||
          event.type != 'run.retried') {
        throw StateError('project_build_run_conflict');
      }
      return next;
    }
    if (previous.isTerminal ||
        next.attempt != previous.attempt ||
        event.sequence != previous.snapshotSequence + 1 ||
        next.statusVersion <= previous.statusVersion) {
      throw StateError('project_build_state_conflict');
    }
    if (previous.candidate != null &&
        jsonEncode(previous.candidate!.toJson()) !=
            jsonEncode(next.candidate?.toJson())) {
      throw StateError('project_build_candidate_changed');
    }
    final allowed = switch (previous.status) {
      ProjectBuildV2Status.queued => {
        ProjectBuildV2Status.running,
        ProjectBuildV2Status.cancelled,
      },
      ProjectBuildV2Status.running => {
        ProjectBuildV2Status.running,
        ProjectBuildV2Status.cancelling,
        ProjectBuildV2Status.failed,
        ProjectBuildV2Status.previewReady,
      },
      ProjectBuildV2Status.previewReady => {
        ProjectBuildV2Status.completed,
        ProjectBuildV2Status.cancelled,
      },
      ProjectBuildV2Status.cancelling => {
        ProjectBuildV2Status.cancelling,
        ProjectBuildV2Status.cancelled,
      },
      ProjectBuildV2Status.completed ||
      ProjectBuildV2Status.cancelled ||
      ProjectBuildV2Status.failed => <ProjectBuildV2Status>{},
    };
    if (!allowed.contains(next.status)) {
      throw StateError('project_build_state_conflict');
    }
    return next;
  }

  Future<ProjectBuildV2PendingDeletion> prepareProjectDeletion(
    String projectId,
    ProjectBuildV2DeleteRequest request, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    projectBuildV2Id(projectId, 'project');
    final record = _projectDeletions.record(_key(request.requestId));
    final existing = await record.get(tx);
    if (existing != null) {
      if (existing['projectId'] != projectId ||
          jsonEncode(existing['body']) != jsonEncode(request.toJson())) {
        throw StateError('project_build_idempotency_conflict');
      }
      return ProjectBuildV2PendingDeletion._parse(
        existing,
        scopeKey,
        _isCurrent,
      );
    }
    await _assertProjectHead(
      tx,
      projectId,
      request.expectedHeadVersion,
      expectedRevision: request.expectedRevision,
    );
    await _assertNoProjectMutation(tx, projectId);
    final row = <String, Object?>{
      'scopeKey': scopeKey,
      'projectId': projectId,
      'body': request.toJson(),
      'localCleanupComplete': false,
    };
    await record.put(tx, row);
    return ProjectBuildV2PendingDeletion._parse(row, scopeKey, _isCurrent);
  });

  Future<ProjectBuildV2DeletionProof> recordProjectDeletionReceipt(
    ProjectBuildV2DeleteReceipt receipt, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final record = _projectDeletions.record(_key(receipt.requestId));
    final row = await record.get(tx);
    if (row == null) throw StateError('project_delete_request_unknown');
    final pending = ProjectBuildV2PendingDeletion._parse(
      row,
      scopeKey,
      _isCurrent,
    );
    if (pending.projectId != receipt.projectId ||
        pending.request.expectedRevision != receipt.deletedRevisionId ||
        pending.request.expectedHeadVersion + 1 != receipt.headVersion) {
      throw StateError('project_delete_receipt_conflict');
    }
    if (pending.proof != null) {
      if (jsonEncode(pending.proof!.receipt.toJson()) !=
          jsonEncode(receipt.toJson())) {
        throw StateError('project_delete_receipt_conflict');
      }
      return pending.proof!;
    }
    final rows = await _tasks.find(
      tx,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    final taskIds = <String>{}, requestIds = <String>{};
    // Image uploads can have a durable edit draft before prepareCreate. Its
    // original ID must be included in the same deletion proof/card fence.
    requestIds.addAll(
      await referenceAdmissions.requestIdsForProject(tx, receipt.projectId),
    );
    for (final task in rows) {
      if (!_rowBelongsToProject(task.value, receipt.projectId)) continue;
      final id = projectBuildV2Id(task.value['taskId'], 'task');
      taskIds.add(id);
      requestIds.add(
        projectBuildV2Object(task.value['input'])['requestId']! as String,
      );
      await _tombstones.record(_key('task:$id')).put(tx, {
        'scopeKey': scopeKey,
        'projectId': receipt.projectId,
      });
      await _tasks.record(task.key).delete(tx);
      await _events.delete(
        tx,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('scopeKey', scopeKey),
            Filter.equals('taskId', id),
          ]),
        ),
      );
    }
    final intents = await _intents.find(
      tx,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    for (final intent in intents) {
      final body = intent.value['body'];
      if (!taskIds.contains(intent.value['taskId']) &&
          !(body is Map &&
              (body['projectId'] == receipt.projectId ||
                  requestIds.contains(body['requestId'])))) {
        continue;
      }
      final id = projectBuildV2Object(body)['requestId']! as String;
      if (intent.value['operation'] == 'create') requestIds.add(id);
      await _tombstones.record(_key('request:$id')).put(tx, {
        'scopeKey': scopeKey,
        'projectId': receipt.projectId,
      });
      // A deletion keeps identity only; requirements and provider content go.
      await _intents.record(intent.key).put(tx, {
        'scopeKey': scopeKey,
        'operation': 'deleted',
        'requestId': id,
        'projectId': receipt.projectId,
      });
    }
    for (final id in requestIds) {
      await _tombstones.record(_key('request:$id')).put(tx, {
        'scopeKey': scopeKey,
        'projectId': receipt.projectId,
      });
    }
    await _tombstones.record(_key('project:${receipt.projectId}')).put(tx, {
      'scopeKey': scopeKey,
      'receipt': receipt.toJson(),
    });
    await _ownedRevisions.record(_key(receipt.projectId)).delete(tx);
    final owned = await _ownedProjects.record(_key('inventory')).get(tx);
    if (owned != null) {
      final data = projectBuildV2Object(owned['inventory']);
      await _ownedProjects.record(_key('inventory')).put(tx, {
        'scopeKey': scopeKey,
        'inventory': {
          ...data,
          'projects': (data['projects']! as List)
              .where(
                (p) =>
                    projectBuildV2Object(p)['projectId'] != receipt.projectId,
              )
              .toList(),
        },
      });
    }
    final next = {
      ...row,
      'receipt': receipt.toJson(),
      'deletedTaskIds': taskIds.toList(),
      'deletedCreateRequestIds': requestIds.toList(),
    };
    await record.put(tx, next);
    return ProjectBuildV2PendingDeletion._parse(
      next,
      scopeKey,
      _isCurrent,
    ).proof!;
  });

  Future<void> finishProjectDeletion(
    ProjectBuildV2DeletionProof proof, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    if (proof.scopeKey != scopeKey || !proof.isScopeCurrent) {
      throw StateError('project_build_scope_changed');
    }
    final record = _projectDeletions.record(_key(proof.receipt.requestId));
    final row = await record.get(tx);
    if (row == null ||
        jsonEncode(row['receipt']) != jsonEncode(proof.receipt.toJson())) {
      throw StateError('project_delete_receipt_conflict');
    }
    await record.put(tx, {...row, 'localCleanupComplete': true});
  });

  Future<void> rejectProjectDeletion(
    String requestId,
    String code, {
    required String expectedScopeKey,
  }) => _rejectProjectMutation(
    _projectDeletions,
    requestId,
    code,
    expectedScopeKey,
  );

  Future<ProjectBuildV2PendingRollback> prepareProjectRollback(
    String projectId,
    ProjectBuildV2RollbackRequest request, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    projectBuildV2Id(projectId, 'project');
    final record = _projectRollbacks.record(_key(request.requestId));
    final old = await record.get(tx);
    if (old != null) {
      if (old['projectId'] != projectId ||
          jsonEncode(old['body']) != jsonEncode(request.toJson())) {
        throw StateError('project_build_idempotency_conflict');
      }
      return ProjectBuildV2PendingRollback._parse(old, scopeKey);
    }
    await _assertProjectHead(tx, projectId, request.expectedHeadVersion);
    await _assertNoProjectMutation(tx, projectId);
    final row = await _ownedRevisions.record(_key(projectId)).get(tx);
    if (row == null) throw StateError('project_build_owned_inventory_missing');
    final history = ProjectBuildV2OwnedRevisions.fromJson(row['inventory']);
    if (history.currentHeadVersion != request.expectedHeadVersion ||
        history.currentRevisionId == request.targetRevision ||
        !history.contains(request.targetRevision)) {
      throw StateError('project_build_head_conflict');
    }
    final target = history.revisions.singleWhere(
      (r) => r.revisionId == request.targetRevision,
    );
    final next = <String, Object?>{
      'scopeKey': scopeKey,
      'projectId': projectId,
      'body': request.toJson(),
      'target': target.toJson(),
      'settled': false,
    };
    await record.put(tx, next);
    return ProjectBuildV2PendingRollback._parse(next, scopeKey);
  });

  Future<List<ProjectBuildV2PendingRollback>> pendingProjectRollbacks({
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    final rows = await _projectRollbacks.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    _guard(expectedScopeKey);
    return List.unmodifiable(
      rows
          .map((r) => ProjectBuildV2PendingRollback._parse(r.value, scopeKey))
          .where((r) => !r.settled && r.rejectionCode.isEmpty),
    );
  }

  Future<ProjectBuildV2PendingRollback> recordProjectRollbackReceipt(
    ProjectBuildV2RollbackReceipt receipt, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final record = _projectRollbacks.record(_key(receipt.requestId));
    final row = await record.get(tx);
    if (row == null) throw StateError('project_rollback_request_unknown');
    final pending = ProjectBuildV2PendingRollback._parse(row, scopeKey);
    if (receipt.projectId != pending.projectId ||
        receipt.revisionId != pending.request.targetRevision ||
        receipt.headVersion != pending.request.expectedHeadVersion + 1 ||
        receipt.candidateDigest != pending.target.candidateDigest ||
        receipt.reportDigest != pending.target.reportDigest ||
        (pending.receipt != null &&
            jsonEncode(pending.receipt!.toJson()) !=
                jsonEncode(receipt.toJson()))) {
      throw StateError('project_rollback_receipt_conflict');
    }
    final next = {...row, 'receipt': receipt.toJson()};
    await record.put(tx, next);
    return ProjectBuildV2PendingRollback._parse(next, scopeKey);
  });
  Future<void> finishProjectRollback(
    String requestId, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final ref = _projectRollbacks.record(_key(requestId)),
        row = await ref.get(tx);
    if (row == null || row['receipt'] == null) {
      throw StateError('project_rollback_receipt_missing');
    }
    await ref.put(tx, {...row, 'settled': true});
  });
  Future<void> rejectProjectRollback(
    String requestId,
    String code, {
    required String expectedScopeKey,
  }) => _rejectProjectMutation(
    _projectRollbacks,
    requestId,
    code,
    expectedScopeKey,
  );

  Future<void> _rejectProjectMutation(
    StoreRef<String, Map<String, Object?>> store,
    String requestId,
    String code,
    String expected,
  ) => _transaction(expected, (tx) async {
    if (!RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(code)) {
      throw ArgumentError('project_build_rejection');
    }
    final ref = store.record(_key(requestId)), row = await ref.get(tx);
    if (row == null || row['receipt'] != null) {
      throw StateError('project_build_request_not_pending');
    }
    await ref.put(tx, {...row, 'rejectionCode': code});
  });
  Future<void> _assertProjectHead(
    DatabaseClient tx,
    String projectId,
    int version, {
    String? expectedRevision,
  }) async {
    if (await _tombstones.record(_key('project:$projectId')).exists(tx)) {
      throw StateError('project_build_project_deleted');
    }
    final row = await _ownedProjects.record(_key('inventory')).get(tx);
    if (row == null) throw StateError('project_build_owned_inventory_missing');
    final matches = ProjectBuildV2OwnedProjects.fromJson(
      row['inventory'],
    ).projects.where((p) => p.projectId == projectId);
    if (matches.isEmpty ||
        matches.single.headVersion != version ||
        (expectedRevision != null &&
            matches.single.currentRevisionId != expectedRevision)) {
      throw StateError('project_build_head_conflict');
    }
  }

  Future<void> _assertNoProjectMutation(
    DatabaseClient tx,
    String projectId,
  ) async {
    for (final store in [_projectDeletions, _projectRollbacks]) {
      final rows = await store.find(
        tx,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('scopeKey', scopeKey),
            Filter.equals('projectId', projectId),
          ]),
        ),
      );
      if (rows.any(
        (r) =>
            r.value['rejectionCode'] == null &&
            r.value['settled'] != true &&
            r.value['localCleanupComplete'] != true,
      )) {
        throw StateError('project_build_mutation_pending');
      }
    }
  }

  bool _rowBelongsToProject(Map<String, Object?> row, String projectId) => [
    row['input'],
    row['snapshot'],
    row['remoteHead'],
  ].any((v) => v is Map && v['projectId'] == projectId);
  Future<List<ProjectBuildV2PendingDeletion>> pendingProjectDeletions({
    required String expectedScopeKey,
    bool includeCompleted = false,
  }) async {
    _guard(expectedScopeKey);
    final rows = await _projectDeletions.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    _guard(expectedScopeKey);
    return List.unmodifiable(
      rows
          .map(
            (row) => ProjectBuildV2PendingDeletion._parse(
              row.value,
              scopeKey,
              _isCurrent,
            ),
          )
          .where(
            (item) =>
                includeCompleted ||
                (!item.localCleanupComplete && item.rejectionCode.isEmpty),
          ),
    );
  }

  Future<void> recordOwnedProjects(
    ProjectBuildV2OwnedProjects inventory, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final checked = ProjectBuildV2OwnedProjects.fromJson(inventory.toJson());
    for (final project in checked.projects) {
      if (await _tombstones
          .record(_key('project:${project.projectId}'))
          .exists(tx)) {
        throw StateError('project_build_owned_head_stale');
      }
    }
    final oldRow = await _ownedProjects.record(_key('inventory')).get(tx);
    if (oldRow != null && !_legacyInventory(oldRow['inventory'])) {
      final old = ProjectBuildV2OwnedProjects.fromJson(oldRow['inventory']);
      for (final next in checked.projects) {
        final prior = old.projects.where((p) => p.projectId == next.projectId);
        if (prior.isNotEmpty &&
            (next.headVersion < prior.single.headVersion ||
                (next.headVersion == prior.single.headVersion &&
                    next.currentRevisionId !=
                        prior.single.currentRevisionId))) {
          throw StateError('project_build_owned_head_stale');
        }
      }
    }
    await _ownedProjects.record(_key('inventory')).put(tx, {
      'scopeKey': scopeKey,
      'inventory': checked.toJson(),
    });
  });
  Future<ProjectBuildV2OwnedProjects?> readOwnedProjects({
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    final row = await _ownedProjects
        .record(_key('inventory'))
        .get(_database.raw);
    _guard(expectedScopeKey);
    if (row == null) return null;
    if (row['scopeKey'] != scopeKey) {
      throw StateError('project_build_scope_changed');
    }
    if (_legacyInventory(row['inventory'])) return null;
    return ProjectBuildV2OwnedProjects.fromJson(row['inventory']);
  }

  Future<List<ProjectBuildV2OwnedRevision>> recordOwnedRevisions(
    ProjectBuildV2OwnedRevisions inventory, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final checked = ProjectBuildV2OwnedRevisions.fromJson(inventory.toJson());
    final row = await _ownedProjects.record(_key('inventory')).get(tx);
    if (row == null || row['scopeKey'] != scopeKey) {
      throw StateError('project_build_owned_inventory_missing');
    }
    final project = ProjectBuildV2OwnedProjects.fromJson(
      row['inventory'],
    ).projects.singleWhere((p) => p.projectId == checked.projectId);
    if (checked.currentHeadVersion < project.headVersion ||
        (checked.currentHeadVersion == project.headVersion &&
            checked.currentRevisionId != project.currentRevisionId)) {
      throw StateError('project_build_owned_head_stale');
    }
    final oldHistory = await _ownedRevisions
        .record(_key(checked.projectId))
        .get(tx);
    if (oldHistory != null &&
        projectBuildV2Object(
          oldHistory['inventory'],
        ).containsKey('currentHeadVersion')) {
      final previous = ProjectBuildV2OwnedRevisions.fromJson(
        oldHistory['inventory'],
      );
      if (checked.currentHeadVersion < previous.currentHeadVersion ||
          (checked.currentHeadVersion == previous.currentHeadVersion &&
              checked.currentRevisionId != previous.currentRevisionId)) {
        throw StateError('project_build_owned_head_stale');
      }
      for (final prior in previous.revisions) {
        final same = checked.revisions.where(
          (r) => r.revisionId == prior.revisionId,
        );
        if (same.isEmpty ||
            jsonEncode(same.single.toJson()) != jsonEncode(prior.toJson())) {
          throw StateError('project_build_owned_history_changed');
        }
      }
    }
    await _ownedRevisions.record(_key(checked.projectId)).put(tx, {
      'scopeKey': scopeKey,
      'inventory': checked.toJson(),
    });
    return List.unmodifiable(
      checked.revisions.map(
        (r) => ProjectBuildV2OwnedRevision._(
          scopeKey,
          project,
          r,
          checked.currentRevisionId,
          checked.currentHeadVersion,
          _isCurrent,
        ),
      ),
    );
  });
  Future<ProjectBuildV2OwnedRevision?> ownedRevision(
    String projectId,
    String revisionId, {
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    projectBuildV2Id(projectId, 'project');
    projectBuildV2Id(revisionId, 'revision');
    final projects = await readOwnedProjects(
      expectedScopeKey: expectedScopeKey,
    );
    if (projects == null) return null;
    final matches = projects.projects.where((p) => p.projectId == projectId);
    if (matches.isEmpty) return null;
    final row = await _ownedRevisions
        .record(_key(projectId))
        .get(_database.raw);
    _guard(expectedScopeKey);
    if (row == null) return null;
    if (row['scopeKey'] != scopeKey) {
      throw StateError('project_build_scope_changed');
    }
    if (!projectBuildV2Object(
      row['inventory'],
    ).containsKey('currentHeadVersion')) {
      return null;
    }
    final revisions = ProjectBuildV2OwnedRevisions.fromJson(row['inventory']);
    if (revisions.currentHeadVersion < matches.single.headVersion ||
        (revisions.currentHeadVersion == matches.single.headVersion &&
            revisions.currentRevisionId != matches.single.currentRevisionId)) {
      return null;
    }
    final found = revisions.revisions.where((r) => r.revisionId == revisionId);
    return found.isEmpty
        ? null
        : ProjectBuildV2OwnedRevision._(
            scopeKey,
            matches.single,
            found.single,
            revisions.currentRevisionId,
            revisions.currentHeadVersion,
            _isCurrent,
          );
  }

  Future<bool> isDelivered(
    String taskId, {
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    final row = await _task(_database.raw, taskId);
    _guard(expectedScopeKey);
    final snapshot = ProjectBuildV2Projection._parse(row, scopeKey).snapshot;
    return snapshot?.status == ProjectBuildV2Status.completed &&
        row['deliveredCandidateDigest'] == snapshot?.candidate?.candidateDigest;
  }

  Future<void> markDelivered(
    String taskId,
    String candidateDigest, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final row = await _task(tx, taskId);
    final snapshot = ProjectBuildV2Projection._parse(row, scopeKey).snapshot;
    if (snapshot?.status != ProjectBuildV2Status.completed ||
        snapshot?.savedRevision?.candidateDigest != candidateDigest) {
      throw StateError('project_build_delivery_conflict');
    }
    await _tasks.record(_key(taskId)).put(tx, {
      ...row,
      'deliveredCandidateDigest': candidateDigest,
    });
  });

  Future<Map<String, Object?>> _task(DatabaseClient tx, String taskId) async {
    projectBuildV2Id(taskId, 'task');
    if (await _tombstones.record(_key('task:$taskId')).exists(tx)) {
      throw StateError('project_build_project_deleted');
    }
    final row = await _tasks.record(_key(taskId)).get(tx);
    if (row == null || row['scopeKey'] != scopeKey) {
      throw StateError('project_build_task_unknown');
    }
    return Map<String, Object?>.from(row);
  }

  Future<ProjectBuildV2Snapshot?> _journalSnapshot(
    DatabaseClient tx,
    String taskId,
    int sequence,
  ) async {
    final row = await _events.record(_eventKey(taskId, sequence)).get(tx);
    if (row == null) return null;
    if (row['scopeKey'] != scopeKey) {
      throw StateError('project_build_scope_changed');
    }
    final event = ProjectBuildV2Event.fromJson(
      projectBuildV2Object(row['event']),
    );
    if (row['projectionSnapshot'] == null) {
      if (event is ProjectBuildV2StateEvent) return event.snapshot;
      throw StateError('project_build_node_header_missing');
    }
    final snapshot = ProjectBuildV2Snapshot.fromJson(
      projectBuildV2Object(row['projectionSnapshot']),
    );
    if (snapshot.taskId != event.taskId ||
        snapshot.runId != event.runId ||
        snapshot.attempt != event.attempt ||
        snapshot.snapshotTaskSequence != event.taskSequence ||
        snapshot.snapshotSequence != event.sequence ||
        snapshot.statusVersion != event.statusVersion ||
        snapshot.updatedAt != event.at ||
        (event is ProjectBuildV2NodeDelta &&
            snapshot.status != ProjectBuildV2Status.running)) {
      throw StateError('project_build_journal_header_conflict');
    }
    return snapshot;
  }

  Future<ProjectBuildV2Event?> _event(
    DatabaseClient tx,
    String taskId,
    int sequence,
  ) async {
    final row = await _events.record(_eventKey(taskId, sequence)).get(tx);
    if (row == null) return null;
    if (row['scopeKey'] != scopeKey) {
      throw StateError('project_build_scope_changed');
    }
    return ProjectBuildV2Event.fromJson(projectBuildV2Object(row['event']));
  }

  Future<T> _transaction<T>(
    String expected,
    Future<T> Function(Transaction) operation,
  ) async {
    _guard(expected);
    final result = await _database.raw.transaction((tx) async {
      _guard(expected);
      final result = await operation(tx);
      _guard(expected);
      return result;
    });
    _guard(expected);
    return result;
  }
}

bool _legacyInventory(Object? value) {
  final data = projectBuildV2Object(value);
  if (data['schemaVersion'] != 2 || data['projects'] is! List) return false;
  return (data['projects'] as List).any(
    (p) => p is Map && !p.containsKey('headVersion'),
  );
}

bool _legacyIntent(Map<String, Object?> row) {
  final body = row['body'];
  if (body is! Map) return false;
  return (row['operation'] == 'accept' &&
          !body.containsKey('expectedHeadVersion')) ||
      (row['operation'] == 'create' &&
          body['projectId'] != null &&
          !body.containsKey('baseHeadVersion'));
}

bool _legacyProjection(Map<String, Object?> row) {
  final input = row['input'];
  if (input is Map &&
      input['projectId'] != null &&
      !input.containsKey('baseHeadVersion')) {
    return true;
  }
  return [row['snapshot'], row['remoteHead']].any(
    (v) =>
        v is Map &&
        ((v['candidate'] is Map &&
                !(v['candidate'] as Map).containsKey('baseHeadVersion')) ||
            (v['savedRevision'] is Map &&
                !(v['savedRevision'] as Map).containsKey('headVersion'))),
  );
}
