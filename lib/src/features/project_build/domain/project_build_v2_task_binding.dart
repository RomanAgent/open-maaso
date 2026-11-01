import 'dart:convert';
import 'project_build_v2_contract.dart';
import 'project_build_v2_node.dart';
import 'project_build_edit_identity.dart';

enum ProjectBuildV2TaskOperation { create, cancel, retry, accept }

final class ProjectBuildV2TaskPendingCommand {
  ProjectBuildV2TaskPendingCommand({
    required this.operation,
    required this.requestId,
    this.expectedRunId,
    this.expectedStatusVersion,
    this.acceptedTaskSequence,
    this.candidateDigest,
    this.baseRevision,
    this.expectedHeadVersion,
  }) {
    _requestId(requestId);
    if (operation == ProjectBuildV2TaskOperation.create) {
      if (expectedRunId != null || expectedStatusVersion != null) {
        throw const FormatException('invalid_project_build_pending');
      }
    } else {
      projectBuildV2Id(expectedRunId, 'run');
      _sequence(expectedStatusVersion);
    }
    if (operation == ProjectBuildV2TaskOperation.accept) {
      ProjectBuildV2Command(
        operation: ProjectBuildV2Operation.accept,
        requestId: requestId,
        expectedRunId: expectedRunId!,
        expectedStatusVersion: expectedStatusVersion!,
        candidateDigest: candidateDigest,
        baseRevision: baseRevision,
        expectedHeadVersion: expectedHeadVersion,
      );
    } else if (candidateDigest != null ||
        baseRevision != null ||
        expectedHeadVersion != null) {
      throw const FormatException('invalid_project_build_pending');
    }
    if (acceptedTaskSequence != null) _sequence(acceptedTaskSequence);
  }

  final ProjectBuildV2TaskOperation operation;
  final String requestId;
  final String? expectedRunId;
  final int? expectedStatusVersion;
  final int? acceptedTaskSequence;
  final String? candidateDigest;
  final String? baseRevision;
  final int? expectedHeadVersion;

  ProjectBuildV2TaskPendingCommand copyWith({int? acceptedTaskSequence}) =>
      ProjectBuildV2TaskPendingCommand(
        operation: operation,
        requestId: requestId,
        expectedRunId: expectedRunId,
        expectedStatusVersion: expectedStatusVersion,
        acceptedTaskSequence: acceptedTaskSequence ?? this.acceptedTaskSequence,
        candidateDigest: candidateDigest,
        baseRevision: baseRevision,
        expectedHeadVersion: expectedHeadVersion,
      );

  bool sameCommand(ProjectBuildV2TaskPendingCommand other) =>
      operation == other.operation &&
      requestId == other.requestId &&
      expectedRunId == other.expectedRunId &&
      expectedStatusVersion == other.expectedStatusVersion &&
      candidateDigest == other.candidateDigest &&
      baseRevision == other.baseRevision &&
      expectedHeadVersion == other.expectedHeadVersion;

  Map<String, Object?> toJson() => {
    'operation': operation.name,
    'requestId': requestId,
    'expectedRunId': expectedRunId,
    'expectedStatusVersion': expectedStatusVersion,
    'acceptedTaskSequence': acceptedTaskSequence,
    'candidateDigest': candidateDigest,
    'baseRevision': baseRevision,
    'expectedHeadVersion': expectedHeadVersion,
  };

  factory ProjectBuildV2TaskPendingCommand.fromJson(Object? value) {
    final raw = _fields(value, const {
      'operation',
      'requestId',
      'expectedRunId',
      'expectedStatusVersion',
      'acceptedTaskSequence',
      'candidateDigest',
      'baseRevision',
      'expectedHeadVersion',
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
    return ProjectBuildV2TaskPendingCommand(
      operation: ProjectBuildV2TaskOperation.values.byName(
        raw['operation']! as String,
      ),
      requestId: raw['requestId']! as String,
      expectedRunId: raw['expectedRunId'] as String?,
      expectedStatusVersion: raw['expectedStatusVersion'] as int?,
      acceptedTaskSequence: raw['acceptedTaskSequence'] as int?,
      candidateDigest: raw['candidateDigest'] as String?,
      baseRevision: raw['baseRevision'] as String?,
      expectedHeadVersion: raw['expectedHeadVersion'] as int?,
    );
  }
}

/// A rebuildable task-list projection of an account repository journal.
/// Scope is the repository's environment/account key; Applet ownership scope
/// remains on the containing AgentTaskJob. Neither a receipt nor a remote head
/// can replace [snapshot] or advance [appliedTaskSequence].
final class ProjectBuildV2TaskBinding {
  ProjectBuildV2TaskBinding({
    required this.scopeKey,
    required this.createRequestId,
    this.taskId,
    this.snapshot,
    this.pendingCommand,
    this.syncIssue = '',
    List<ProjectBuildV2Node> nodes = const [],
    this.lastNodeId,
    this.referenceSelectionDigest,
    this.editIdentity,
    String? legacyContractJson,
  }) : _legacyContractJson = legacyContractJson,
       nodes = List.unmodifiable(nodes) {
    parseProjectBuildV2Nodes(nodes.map((node) => node.toJson()).toList());
    if ((snapshot == null && nodes.isNotEmpty) ||
        (lastNodeId != null &&
            !nodes.any((node) => node.nodeId == lastNodeId))) {
      throw const FormatException('project_build_node_binding');
    }
    _requestId(createRequestId);
    if (referenceSelectionDigest != null &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(referenceSelectionDigest!)) {
      throw const FormatException('project_reference_selection_digest');
    }
    if (scopeKey.isEmpty ||
        scopeKey.length > 512 ||
        scopeKey.runes.any((rune) => rune < 32 || rune == 127) ||
        !RegExp(r'^[A-Za-z0-9_.:-]{0,128}$').hasMatch(syncIssue)) {
      throw const FormatException('invalid_project_build_binding');
    }
    if (taskId != null) projectBuildV2Id(taskId, 'task');
    if (snapshot != null && snapshot!.taskId != taskId) {
      throw const FormatException('project_build_binding_identity');
    }
    if (editIdentity != null &&
        snapshot != null &&
        (snapshot!.projectId != editIdentity!.projectId ||
            (snapshot!.candidate != null &&
                (snapshot!.candidate!.baseRevision !=
                        editIdentity!.baseRevision ||
                    snapshot!.candidate!.baseHeadVersion !=
                        editIdentity!.baseHeadVersion)))) {
      throw const FormatException('project_build_edit_snapshot_conflict');
    }
    if (pendingCommand?.operation == ProjectBuildV2TaskOperation.create &&
        pendingCommand!.requestId != createRequestId) {
      throw const FormatException('project_build_binding_request_identity');
    }
    if (pendingCommand != null &&
        pendingCommand!.operation != ProjectBuildV2TaskOperation.create &&
        taskId == null) {
      throw const FormatException('project_build_pending_task_missing');
    }
  }

  final String scopeKey;
  final String createRequestId;
  final String? taskId;
  final ProjectBuildV2Snapshot? snapshot;
  final ProjectBuildV2TaskPendingCommand? pendingCommand;
  final String syncIssue;
  final List<ProjectBuildV2Node> nodes;
  final String? lastNodeId;
  final String? referenceSelectionDigest;
  final ProjectBuildEditIdentity? editIdentity;
  final String? _legacyContractJson;
  bool get isLegacyReadOnly =>
      _legacyContractJson != null || syncIssue == 'legacy_contract';
  int get appliedTaskSequence => snapshot?.snapshotTaskSequence ?? 0;

  /// Defensive contiguous projection; caller must first commit the event to the
  /// authoritative account repository journal. Transport metadata cannot call
  /// this with a head snapshot in place of the missing events.
  ProjectBuildV2TaskBinding applyEvent(ProjectBuildV2Event event) {
    if (isLegacyReadOnly) throw StateError('project_build_legacy_contract');
    final previous = snapshot;
    final next = event.resolveSnapshot(previous);
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
          next.status != ProjectBuildV2Status.queued) {
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
        if (!previous.status.retryable ||
            next.attempt != previous.attempt + 1 ||
            event.type != 'run.retried' ||
            event.sequence != 1 ||
            next.statusVersion != 1 ||
            next.status != ProjectBuildV2Status.queued) {
          throw StateError('project_build_task_attempt_conflict');
        }
      } else {
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
          _ => <ProjectBuildV2Status>{},
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
        ProjectBuildV2TaskOperation.create => event.type == 'task.created',
        ProjectBuildV2TaskOperation.retry =>
          event.type == 'run.retried' && event.runId != pending.expectedRunId,
        ProjectBuildV2TaskOperation.accept =>
          event.type == 'run.completed' &&
              event.runId == pending.expectedRunId &&
              next.savedRevision?.candidateDigest == pending.candidateDigest &&
              next.savedRevision?.headVersion ==
                  (pending.expectedHeadVersion ?? -1) + 1,
        ProjectBuildV2TaskOperation.cancel =>
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
            (pending.operation == ProjectBuildV2TaskOperation.create &&
                event.type == 'task.created') ||
            (pending.operation == ProjectBuildV2TaskOperation.retry &&
                event.type == 'run.retried' &&
                event.runId != pending.expectedRunId) ||
            (pending.operation == ProjectBuildV2TaskOperation.accept &&
                event.type == 'run.completed' &&
                event.runId == pending.expectedRunId &&
                next.savedRevision?.candidateDigest ==
                    pending.candidateDigest) ||
            (pending.operation == ProjectBuildV2TaskOperation.cancel &&
                event.type == 'run.cancelled' &&
                event.runId == pending.expectedRunId));
    final reset = previous?.runId != next.runId;
    final nextNodes = event is ProjectBuildV2NodeDelta
        ? applyProjectBuildV2Node(nodes, event.node)
        : reset
        ? <ProjectBuildV2Node>[]
        : nodes;
    final nextNodeId = event is ProjectBuildV2NodeDelta
        ? event.node.nodeId
        : reset
        ? null
        : lastNodeId;
    return copyWith(
      snapshot: next,
      nodes: nextNodes,
      lastNodeId: nextNodeId,
      clearLastNode: nextNodeId == null,
      clearPending: clear,
      syncIssue: '',
    );
  }

  ProjectBuildV2TaskBinding copyWith({
    String? taskId,
    ProjectBuildV2Snapshot? snapshot,
    ProjectBuildV2TaskPendingCommand? pendingCommand,
    String? syncIssue,
    bool clearPending = false,
    List<ProjectBuildV2Node>? nodes,
    String? lastNodeId,
    bool clearLastNode = false,
    ProjectBuildEditIdentity? editIdentity,
  }) => isLegacyReadOnly
      ? this
      : ProjectBuildV2TaskBinding(
          scopeKey: scopeKey,
          createRequestId: createRequestId,
          referenceSelectionDigest: referenceSelectionDigest,
          editIdentity: editIdentity ?? this.editIdentity,
          taskId: taskId ?? this.taskId,
          snapshot: snapshot ?? this.snapshot,
          pendingCommand: clearPending
              ? null
              : pendingCommand ?? this.pendingCommand,
          syncIssue: syncIssue ?? this.syncIssue,
          nodes: nodes ?? this.nodes,
          lastNodeId: clearLastNode ? null : lastNodeId ?? this.lastNodeId,
        );

  Map<String, Object?> toJson() => _legacyContractJson != null
      ? {
          ...projectBuildV2Object(jsonDecode(_legacyContractJson)),
          'syncIssue': 'legacy_contract',
        }
      : {
          'schemaVersion': 2,
          'scopeKey': scopeKey,
          'createRequestId': createRequestId,
          if (referenceSelectionDigest != null)
            'referenceSelectionDigest': referenceSelectionDigest,
          if (editIdentity != null) 'editIdentity': editIdentity!.toJson(),
          'taskId': taskId,
          'snapshot': snapshot?.toJson(),
          'appliedTaskSequence': appliedTaskSequence,
          'pendingCommand': pendingCommand?.toJson(),
          'syncIssue': syncIssue,
          'nodes': nodes.map((node) => node.toJson()).toList(),
          'lastNodeId': lastNodeId,
        };

  factory ProjectBuildV2TaskBinding.fromJson(Object? value) {
    final source = projectBuildV2Object(value);
    if (source.containsKey('nodes') != source.containsKey('lastNodeId')) {
      throw const FormatException('project_build_node_binding_fields');
    }
    final raw = _fields(
      {
        ...source,
        if (!source.containsKey('nodes')) 'nodes': [],
        if (!source.containsKey('lastNodeId')) 'lastNodeId': null,
        if (!source.containsKey('referenceSelectionDigest'))
          'referenceSelectionDigest': null,
        if (!source.containsKey('editIdentity')) 'editIdentity': null,
      },
      const {
        'nodes',
        'lastNodeId',
        'schemaVersion',
        'scopeKey',
        'createRequestId',
        'taskId',
        'snapshot',
        'appliedTaskSequence',
        'pendingCommand',
        'syncIssue',
        'referenceSelectionDigest',
        'editIdentity',
      },
    );
    if (raw['schemaVersion'] is! int ||
        raw['schemaVersion'] != 2 ||
        raw['scopeKey'] is! String ||
        raw['createRequestId'] is! String ||
        (raw['taskId'] != null && raw['taskId'] is! String) ||
        (raw['referenceSelectionDigest'] != null &&
            raw['referenceSelectionDigest'] is! String) ||
        raw['syncIssue'] is! String ||
        raw['appliedTaskSequence'] is! int) {
      throw const FormatException('invalid_project_build_binding');
    }
    final storedSnapshot = raw['snapshot'],
        storedPending = raw['pendingCommand'];
    final legacySnapshot =
        storedSnapshot is Map &&
        ((storedSnapshot['candidate'] is Map &&
                !(storedSnapshot['candidate'] as Map).containsKey(
                  'baseHeadVersion',
                )) ||
            (storedSnapshot['savedRevision'] is Map &&
                !(storedSnapshot['savedRevision'] as Map).containsKey(
                  'headVersion',
                )));
    final legacyPending =
        storedPending is Map &&
        storedPending['operation'] == 'accept' &&
        !storedPending.containsKey('expectedHeadVersion');
    if (legacySnapshot ||
        legacyPending ||
        raw['syncIssue'] == 'legacy_contract') {
      // Preserve the exact old representation. It is display-only and never
      // converted into a new command or a fabricated projected head.
      return ProjectBuildV2TaskBinding(
        scopeKey: raw['scopeKey']! as String,
        createRequestId: raw['createRequestId']! as String,
        taskId: raw['taskId'] as String?,
        syncIssue: 'legacy_contract',
        legacyContractJson: jsonEncode(source),
      );
    }
    final binding = ProjectBuildV2TaskBinding(
      scopeKey: raw['scopeKey']! as String,
      createRequestId: raw['createRequestId']! as String,
      referenceSelectionDigest: raw['referenceSelectionDigest'] as String?,
      editIdentity: raw['editIdentity'] == null
          ? null
          : ProjectBuildEditIdentity.fromJson(raw['editIdentity']),
      taskId: raw['taskId'] as String?,
      snapshot: raw['snapshot'] == null
          ? null
          : ProjectBuildV2Snapshot.fromJson(
              projectBuildV2Object(raw['snapshot']),
            ),
      pendingCommand: raw['pendingCommand'] == null
          ? null
          : ProjectBuildV2TaskPendingCommand.fromJson({
              ...projectBuildV2Object(raw['pendingCommand']),
              if (!projectBuildV2Object(
                raw['pendingCommand'],
              ).containsKey('expectedHeadVersion'))
                'expectedHeadVersion': null,
            }),
      syncIssue: raw['syncIssue']! as String,
      nodes: parseProjectBuildV2Nodes(raw['nodes']),
      lastNodeId: raw['lastNodeId'] as String?,
    );
    if (raw['appliedTaskSequence'] != binding.appliedTaskSequence) {
      throw const FormatException('project_build_binding_cursor_conflict');
    }
    return binding;
  }
}

Map<String, Object?> _fields(Object? value, Set<String> fields) {
  final raw = projectBuildV2Object(value);
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
  if (value == null || value < 1 || value > projectBuildV2MaximumSequence) {
    throw const FormatException('invalid_project_build_binding_sequence');
  }
}
