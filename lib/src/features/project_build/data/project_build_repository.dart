import 'dart:convert';

import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';
import '../domain/project_build_contract.dart';

/// Recovery reuses this exact persisted body and nonce when acknowledgement is
/// unknown; it never infers a new user request from a network timeout.
final class ProjectBuildPendingRequest {
  ProjectBuildPendingRequest._(
    this.scopeKey,
    this.create,
    this.command,
    this.taskId,
    this.rejectionCode,
  );
  final String scopeKey;
  final ProjectBuildCreateRequest? create;
  final ProjectBuildCommand? command;
  final String? taskId;
  final String rejectionCode;
  String get requestId => create?.requestId ?? command!.requestId;

  factory ProjectBuildPendingRequest._parse(Map<String, Object?> row) {
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
      return ProjectBuildPendingRequest._(
        scope,
        ProjectBuildCreateRequest.fromJson(projectBuildObject(row['body'])),
        null,
        null,
        rejection,
      );
    }
    return ProjectBuildPendingRequest._(
      scope,
      null,
      ProjectBuildCommand.fromJson(
        projectBuildObject(row['body']),
        operation: ProjectBuildOperation.values.byName(
          row['operation']! as String,
        ),
      ),
      projectBuildId(row['taskId'], 'task'),
      rejection,
    );
  }
}

final class ProjectBuildProjection {
  ProjectBuildProjection._(
    this.scopeKey,
    this.input,
    this.receipt,
    this.snapshot,
    this.remoteHead,
  );
  final String scopeKey;
  final ProjectBuildCreateRequest input;
  final ProjectBuildReceipt receipt;
  final ProjectBuildSnapshot? snapshot;
  final ProjectBuildSnapshot? remoteHead;
  String get taskId => receipt.taskId;
  int get appliedTaskSequence => snapshot?.snapshotTaskSequence ?? 0;

  factory ProjectBuildProjection._parse(
    Map<String, Object?> row,
    String scope,
  ) {
    if (row['scopeKey'] != scope) {
      throw StateError('project_build_scope_changed');
    }
    final projection = ProjectBuildProjection._(
      scope,
      ProjectBuildCreateRequest.fromJson(projectBuildObject(row['input'])),
      ProjectBuildReceipt.fromJson(projectBuildObject(row['receipt'])),
      row['snapshot'] == null
          ? null
          : ProjectBuildSnapshot.fromJson(projectBuildObject(row['snapshot'])),
      row['remoteHead'] == null
          ? null
          : ProjectBuildSnapshot.fromJson(
              projectBuildObject(row['remoteHead']),
            ),
    );
    if (row['taskId'] != projection.taskId ||
        row['cursor'] != projection.appliedTaskSequence) {
      throw const FormatException('invalid_project_build_projection');
    }
    for (final snapshot in [projection.snapshot, projection.remoteHead]) {
      if (snapshot != null &&
          (snapshot.taskId != projection.taskId ||
              snapshot.agentId != projection.input.agentId ||
              snapshot.projectKind != projection.input.projectKind)) {
        throw const FormatException('project_build_projection_identity');
      }
    }
    return projection;
  }
}

/// Account-mounted durable projection. It has no worker, timer or implicit
/// submission; the tracker separately rebuilds task cards from its journal.
/// All scope authority comes from the caller's mount.
final class ProjectBuildRepository {
  ProjectBuildRepository({
    required DBService database,
    required this.scopeKey,
    required bool Function() isCurrent,
  }) : _database = database,
       _isCurrent = isCurrent {
    if (scopeKey.isEmpty || scopeKey.length > 512) {
      throw ArgumentError('invalid_project_build_scope');
    }
  }

  final DBService _database;
  final String scopeKey;
  final bool Function() _isCurrent;
  static final _intents = stringMapStoreFactory.store('project_build_intents');
  static final _tasks = stringMapStoreFactory.store(
    'project_build_projections',
  );
  static final _events = stringMapStoreFactory.store('project_build_journal');

  String _key(String id) => jsonEncode([scopeKey, id]);
  String _eventKey(String task, int sequence) =>
      jsonEncode([scopeKey, task, sequence]);

  void _guard(String expected) {
    if (expected != scopeKey || !_isCurrent()) {
      throw StateError('project_build_scope_changed');
    }
  }

  Future<void> prepareCreate(
    ProjectBuildCreateRequest request, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    await _putIntent(tx, request.requestId, {
      'scopeKey': scopeKey,
      'operation': 'create',
      'body': request.toJson(),
    });
  });

  Future<void> prepareCommand(
    String taskId,
    ProjectBuildCommand command, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final projection = ProjectBuildProjection._parse(
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
        (command.operation == ProjectBuildOperation.retry
            ? !snapshot.isTerminal
            : !{
                ProjectBuildStatus.queued,
                ProjectBuildStatus.running,
              }.contains(snapshot.status))) {
      throw StateError('project_build_command_conflict');
    }
    await record.put(tx, {
      ...row,
      'expectedAttempt': snapshot.attempt,
      'baseTaskSequence': snapshot.snapshotTaskSequence,
    });
  });

  Future<void> _putIntent(
    Transaction tx,
    String requestId,
    Map<String, Object?> intent,
  ) async {
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
  Future<ProjectBuildProjection> recordReceipt(
    ProjectBuildReceipt receipt, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
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
      final input = ProjectBuildCreateRequest.fromJson(
        projectBuildObject(intent['body']),
      );
      if (receipt.attempt != 1 ||
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
      final command = ProjectBuildCommand.fromJson(
        projectBuildObject(intent['body']),
        operation: ProjectBuildOperation.values.byName(
          intent['operation']! as String,
        ),
      );
      final retry = command.operation == ProjectBuildOperation.retry;
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
    final old = ProjectBuildProjection._parse(row, scopeKey);
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
    return ProjectBuildProjection._parse(row, scopeKey);
  });

  Future<ProjectBuildProjection?> read(
    String taskId, {
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    projectBuildId(taskId, 'task');
    final row = await _tasks.record(_key(taskId)).get(_database.raw);
    _guard(expectedScopeKey);
    return row == null ? null : ProjectBuildProjection._parse(row, scopeKey);
  }

  Future<List<ProjectBuildPendingRequest>> pendingRequests({
    required String expectedScopeKey,
    bool includeRejected = false,
  }) async {
    _guard(expectedScopeKey);
    final rows = await _intents.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    _guard(expectedScopeKey);
    return List.unmodifiable([
      for (final row in rows)
        if (row.value['receipt'] == null &&
            (includeRejected || row.value['rejectionCode'] == null))
          ProjectBuildPendingRequest._parse(row.value),
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
  Future<ProjectBuildEventPage> readEvents(
    String taskId, {
    required int afterTaskSequence,
    int limit = 100,
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    if (afterTaskSequence < 0 ||
        limit < 1 ||
        limit > projectBuildMaximumPageSize) {
      throw ArgumentError('project_build_invalid_journal_cursor');
    }
    final projection = ProjectBuildProjection._parse(
      await _task(tx, taskId),
      scopeKey,
    );
    if (afterTaskSequence > projection.appliedTaskSequence) {
      throw StateError('project_build_cursor_ahead');
    }
    final events = <ProjectBuildEvent>[];
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
    return ProjectBuildEventPage.fromJson(
      {
        'events': events.map((event) => event.toJson()).toList(),
        'nextTaskSequence': next,
        'hasMore': next < projection.appliedTaskSequence,
      },
      taskId: taskId,
      afterTaskSequence: afterTaskSequence,
    );
  });

  Future<List<ProjectBuildProjection>> list({
    required String expectedScopeKey,
  }) async {
    _guard(expectedScopeKey);
    final rows = await _tasks.find(
      _database.raw,
      finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
    );
    _guard(expectedScopeKey);
    return List.unmodifiable([
      for (final row in rows)
        ProjectBuildProjection._parse(row.value, scopeKey),
    ]);
  }

  /// A head is a synchronization target, not proof that intervening events have
  /// been consumed. The projected snapshot/cursor stay unchanged until replay.
  Future<ProjectBuildProjection> noteRemoteHead(
    ProjectBuildSnapshot head, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    final row = await _task(tx, head.taskId);
    final current = ProjectBuildProjection._parse(row, scopeKey);
    _identity(current, head);
    if (head.snapshotTaskSequence <= current.appliedTaskSequence) {
      final event = await _event(tx, head.taskId, head.snapshotTaskSequence);
      if (event == null || !event.snapshot.sameState(head)) {
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
    return ProjectBuildProjection._parse(next, scopeKey);
  });

  Future<ProjectBuildProjection> applyPage(
    String taskId,
    ProjectBuildEventPage page, {
    required String expectedScopeKey,
  }) => _transaction(expectedScopeKey, (tx) async {
    var row = await _task(tx, taskId);
    var current = ProjectBuildProjection._parse(row, scopeKey);
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
      _identity(current, event.snapshot);
      for (final request in acceptedRequests) {
        final receipt = ProjectBuildReceipt.fromJson(
          projectBuildObject(request.value['receipt']),
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
      _transition(current.snapshot, event);
      final head = current.remoteHead;
      if (head != null &&
          head.snapshotTaskSequence == event.taskSequence &&
          !head.sameState(event.snapshot)) {
        throw StateError('project_build_snapshot_conflict');
      }
      await _events.record(_eventKey(taskId, event.taskSequence)).put(tx, {
        'scopeKey': scopeKey,
        'event': event.toJson(),
      });
      row = {
        ...row,
        'snapshot': event.snapshot.toJson(),
        'cursor': event.taskSequence,
      };
      current = ProjectBuildProjection._parse(row, scopeKey);
    }
    if (page.nextTaskSequence > current.appliedTaskSequence) {
      throw StateError('project_build_event_gap');
    }
    await _tasks.record(_key(taskId)).put(tx, row);
    return current;
  });

  void _identity(
    ProjectBuildProjection current,
    ProjectBuildSnapshot snapshot,
  ) {
    final known = current.snapshot ?? current.remoteHead;
    if (snapshot.taskId != current.taskId ||
        snapshot.agentId != current.input.agentId ||
        snapshot.projectKind != current.input.projectKind ||
        (known != null &&
            (known.projectId != snapshot.projectId ||
                known.createdAt != snapshot.createdAt))) {
      throw StateError('project_build_snapshot_identity');
    }
  }

  void _assertReceiptEvent(
    ProjectBuildReceipt receipt,
    String operation,
    ProjectBuildEvent event,
  ) {
    final validType = switch (operation) {
      'create' => event.type == 'task.created',
      'retry' => event.type == 'run.retried',
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

  void _transition(ProjectBuildSnapshot? previous, ProjectBuildEvent event) {
    final next = event.snapshot;
    if (previous == null) {
      if (event.taskSequence != 1 ||
          event.sequence != 1 ||
          next.attempt != 1 ||
          next.statusVersion != 1 ||
          next.status != ProjectBuildStatus.queued ||
          event.type != 'task.created') {
        throw StateError('project_build_initial_event');
      }
      return;
    }
    if (next.updatedAt.isBefore(previous.updatedAt)) {
      throw StateError('project_build_time_regressed');
    }
    if (next.runId != previous.runId) {
      if (!previous.isTerminal ||
          next.attempt != previous.attempt + 1 ||
          event.sequence != 1 ||
          next.statusVersion != 1 ||
          next.status != ProjectBuildStatus.queued ||
          event.type != 'run.retried') {
        throw StateError('project_build_run_conflict');
      }
      return;
    }
    if (previous.isTerminal ||
        next.attempt != previous.attempt ||
        event.sequence != previous.snapshotSequence + 1 ||
        next.statusVersion <= previous.statusVersion) {
      throw StateError('project_build_state_conflict');
    }
    final allowed = switch (previous.status) {
      ProjectBuildStatus.queued => {
        ProjectBuildStatus.running,
        ProjectBuildStatus.cancelled,
      },
      ProjectBuildStatus.running => {
        ProjectBuildStatus.running,
        ProjectBuildStatus.cancelling,
        ProjectBuildStatus.failed,
      },
      ProjectBuildStatus.cancelling => {
        ProjectBuildStatus.cancelling,
        ProjectBuildStatus.cancelled,
      },
      ProjectBuildStatus.cancelled ||
      ProjectBuildStatus.failed => <ProjectBuildStatus>{},
    };
    if (!allowed.contains(next.status)) {
      throw StateError('project_build_state_conflict');
    }
  }

  Future<Map<String, Object?>> _task(DatabaseClient tx, String taskId) async {
    projectBuildId(taskId, 'task');
    final row = await _tasks.record(_key(taskId)).get(tx);
    if (row == null || row['scopeKey'] != scopeKey) {
      throw StateError('project_build_task_unknown');
    }
    return Map<String, Object?>.from(row);
  }

  Future<ProjectBuildEvent?> _event(
    DatabaseClient tx,
    String taskId,
    int sequence,
  ) async {
    final row = await _events.record(_eventKey(taskId, sequence)).get(tx);
    if (row == null) return null;
    if (row['scopeKey'] != scopeKey) {
      throw StateError('project_build_scope_changed');
    }
    return ProjectBuildEvent.fromJson(projectBuildObject(row['event']));
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
