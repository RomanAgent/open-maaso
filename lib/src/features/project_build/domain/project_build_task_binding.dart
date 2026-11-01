import 'project_build_contract.dart';

enum ProjectBuildTaskOperation { create, cancel, retry }

final class ProjectBuildTaskPendingCommand {
  ProjectBuildTaskPendingCommand({
    required this.operation,
    required this.requestId,
    this.expectedRunId,
    this.expectedStatusVersion,
    this.acceptedTaskSequence,
  }) {
    _requestId(requestId);
    if (operation == ProjectBuildTaskOperation.create) {
      if (expectedRunId != null || expectedStatusVersion != null) {
        throw const FormatException('invalid_project_build_pending');
      }
    } else {
      projectBuildId(expectedRunId, 'run');
      _sequence(expectedStatusVersion);
    }
    if (acceptedTaskSequence != null) _sequence(acceptedTaskSequence);
  }

  final ProjectBuildTaskOperation operation;
  final String requestId;
  final String? expectedRunId;
  final int? expectedStatusVersion;
  final int? acceptedTaskSequence;

  ProjectBuildTaskPendingCommand copyWith({int? acceptedTaskSequence}) =>
      ProjectBuildTaskPendingCommand(
        operation: operation,
        requestId: requestId,
        expectedRunId: expectedRunId,
        expectedStatusVersion: expectedStatusVersion,
        acceptedTaskSequence: acceptedTaskSequence ?? this.acceptedTaskSequence,
      );

  bool sameCommand(ProjectBuildTaskPendingCommand other) =>
      operation == other.operation &&
      requestId == other.requestId &&
      expectedRunId == other.expectedRunId &&
      expectedStatusVersion == other.expectedStatusVersion;

  Map<String, Object?> toJson() => {
    'operation': operation.name,
    'requestId': requestId,
    'expectedRunId': expectedRunId,
    'expectedStatusVersion': expectedStatusVersion,
    'acceptedTaskSequence': acceptedTaskSequence,
  };

  factory ProjectBuildTaskPendingCommand.fromJson(Object? value) {
    final raw = _fields(value, const {
      'operation',
      'requestId',
      'expectedRunId',
      'expectedStatusVersion',
      'acceptedTaskSequence',
    });
    if (raw['operation'] is! String ||
        raw['requestId'] is! String ||
        (raw['expectedRunId'] != null && raw['expectedRunId'] is! String) ||
        (raw['expectedStatusVersion'] != null &&
            raw['expectedStatusVersion'] is! int) ||
        (raw['acceptedTaskSequence'] != null &&
            raw['acceptedTaskSequence'] is! int)) {
      throw const FormatException('invalid_project_build_pending');
    }
    return ProjectBuildTaskPendingCommand(
      operation: ProjectBuildTaskOperation.values.byName(
        raw['operation']! as String,
      ),
      requestId: raw['requestId']! as String,
      expectedRunId: raw['expectedRunId'] as String?,
      expectedStatusVersion: raw['expectedStatusVersion'] as int?,
      acceptedTaskSequence: raw['acceptedTaskSequence'] as int?,
    );
  }
}

/// A rebuildable task-list projection of an account repository journal.
/// Scope is the repository's environment/account key; Applet ownership scope
/// remains on the containing AgentTaskJob. Neither a receipt nor a remote head
/// can replace [snapshot] or advance [appliedTaskSequence].
final class ProjectBuildTaskBinding {
  ProjectBuildTaskBinding({
    required this.scopeKey,
    required this.createRequestId,
    this.taskId,
    this.snapshot,
    this.pendingCommand,
    this.syncIssue = '',
  }) {
    _requestId(createRequestId);
    if (scopeKey.isEmpty ||
        scopeKey.length > 512 ||
        scopeKey.runes.any((rune) => rune < 32 || rune == 127) ||
        !RegExp(r'^[A-Za-z0-9_.:-]{0,128}$').hasMatch(syncIssue)) {
      throw const FormatException('invalid_project_build_binding');
    }
    if (taskId != null) projectBuildId(taskId, 'task');
    if (snapshot != null && snapshot!.taskId != taskId) {
      throw const FormatException('project_build_binding_identity');
    }
    if (pendingCommand?.operation == ProjectBuildTaskOperation.create &&
        pendingCommand!.requestId != createRequestId) {
      throw const FormatException('project_build_binding_request_identity');
    }
    if (pendingCommand != null &&
        pendingCommand!.operation != ProjectBuildTaskOperation.create &&
        taskId == null) {
      throw const FormatException('project_build_pending_task_missing');
    }
  }

  final String scopeKey;
  final String createRequestId;
  final String? taskId;
  final ProjectBuildSnapshot? snapshot;
  final ProjectBuildTaskPendingCommand? pendingCommand;
  final String syncIssue;
  int get appliedTaskSequence => snapshot?.snapshotTaskSequence ?? 0;

  /// Defensive contiguous projection; caller must first commit the event to the
  /// authoritative account repository journal. Transport metadata cannot call
  /// this with a head snapshot in place of the missing events.
  ProjectBuildTaskBinding applyEvent(ProjectBuildEvent event) {
    final next = event.snapshot;
    final previous = snapshot;
    if (taskId == null ||
        event.taskId != taskId ||
        event.taskSequence != appliedTaskSequence + 1) {
      throw StateError('project_build_task_event_gap');
    }
    if (previous == null) {
      if (event.type != 'task.created' ||
          event.sequence != 1 ||
          next.attempt != 1 ||
          next.statusVersion != 1 ||
          next.status != ProjectBuildStatus.queued) {
        throw StateError('project_build_task_initial_event');
      }
    } else {
      if (previous.projectId != next.projectId ||
          previous.agentId != next.agentId ||
          previous.projectKind != next.projectKind ||
          previous.createdAt != next.createdAt ||
          next.updatedAt.isBefore(previous.updatedAt)) {
        throw StateError('project_build_task_event_identity');
      }
      if (previous.runId != next.runId) {
        if (!previous.isTerminal ||
            next.attempt != previous.attempt + 1 ||
            event.type != 'run.retried' ||
            event.sequence != 1 ||
            next.statusVersion != 1 ||
            next.status != ProjectBuildStatus.queued) {
          throw StateError('project_build_task_attempt_conflict');
        }
      } else {
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
          _ => <ProjectBuildStatus>{},
        };
        if (next.attempt != previous.attempt ||
            event.sequence != previous.snapshotSequence + 1 ||
            next.statusVersion <= previous.statusVersion ||
            !allowed.contains(next.status)) {
          throw StateError('project_build_task_state_conflict');
        }
      }
    }
    final pending = pendingCommand;
    if (pending?.acceptedTaskSequence == event.taskSequence) {
      final matches = switch (pending!.operation) {
        ProjectBuildTaskOperation.create => event.type == 'task.created',
        ProjectBuildTaskOperation.retry =>
          event.type == 'run.retried' && event.runId != pending.expectedRunId,
        ProjectBuildTaskOperation.cancel =>
          (event.type == 'run.cancel_requested' ||
                  event.type == 'run.cancelled') &&
              event.runId == pending.expectedRunId,
      };
      if (!matches) {
        throw StateError('project_build_task_receipt_event_conflict');
      }
    }
    final clear =
        pending != null &&
        ((pending.acceptedTaskSequence != null &&
                event.taskSequence >= pending.acceptedTaskSequence!) ||
            (pending.operation == ProjectBuildTaskOperation.create &&
                event.type == 'task.created') ||
            (pending.operation == ProjectBuildTaskOperation.retry &&
                event.type == 'run.retried' &&
                event.runId != pending.expectedRunId) ||
            (pending.operation == ProjectBuildTaskOperation.cancel &&
                event.type == 'run.cancelled' &&
                event.runId == pending.expectedRunId));
    return copyWith(snapshot: next, clearPending: clear, syncIssue: '');
  }

  ProjectBuildTaskBinding copyWith({
    String? taskId,
    ProjectBuildSnapshot? snapshot,
    ProjectBuildTaskPendingCommand? pendingCommand,
    String? syncIssue,
    bool clearPending = false,
  }) => ProjectBuildTaskBinding(
    scopeKey: scopeKey,
    createRequestId: createRequestId,
    taskId: taskId ?? this.taskId,
    snapshot: snapshot ?? this.snapshot,
    pendingCommand: clearPending ? null : pendingCommand ?? this.pendingCommand,
    syncIssue: syncIssue ?? this.syncIssue,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'scopeKey': scopeKey,
    'createRequestId': createRequestId,
    'taskId': taskId,
    'snapshot': snapshot?.toJson(),
    'appliedTaskSequence': appliedTaskSequence,
    'pendingCommand': pendingCommand?.toJson(),
    'syncIssue': syncIssue,
  };

  factory ProjectBuildTaskBinding.fromJson(Object? value) {
    final raw = _fields(value, const {
      'schemaVersion',
      'scopeKey',
      'createRequestId',
      'taskId',
      'snapshot',
      'appliedTaskSequence',
      'pendingCommand',
      'syncIssue',
    });
    if (raw['schemaVersion'] is! int ||
        raw['schemaVersion'] != 1 ||
        raw['scopeKey'] is! String ||
        raw['createRequestId'] is! String ||
        (raw['taskId'] != null && raw['taskId'] is! String) ||
        raw['syncIssue'] is! String ||
        raw['appliedTaskSequence'] is! int) {
      throw const FormatException('invalid_project_build_binding');
    }
    final binding = ProjectBuildTaskBinding(
      scopeKey: raw['scopeKey']! as String,
      createRequestId: raw['createRequestId']! as String,
      taskId: raw['taskId'] as String?,
      snapshot: raw['snapshot'] == null
          ? null
          : ProjectBuildSnapshot.fromJson(projectBuildObject(raw['snapshot'])),
      pendingCommand: raw['pendingCommand'] == null
          ? null
          : ProjectBuildTaskPendingCommand.fromJson(raw['pendingCommand']),
      syncIssue: raw['syncIssue']! as String,
    );
    if (raw['appliedTaskSequence'] != binding.appliedTaskSequence) {
      throw const FormatException('project_build_binding_cursor_conflict');
    }
    return binding;
  }
}

Map<String, Object?> _fields(Object? value, Set<String> fields) {
  final raw = projectBuildObject(value);
  if (raw.length != fields.length ||
      raw.keys.any((key) => !fields.contains(key))) {
    throw const FormatException('invalid_project_build_binding_fields');
  }
  return raw;
}

void _requestId(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(value)) {
    throw const FormatException('invalid_project_build_request_id');
  }
}

void _sequence(int? value) {
  if (value == null || value < 1 || value > projectBuildMaximumSequence) {
    throw const FormatException('invalid_project_build_binding_sequence');
  }
}
