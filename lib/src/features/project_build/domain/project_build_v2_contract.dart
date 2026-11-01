import 'dart:convert';
export 'project_build_contract.dart' show ProjectBuildKind;
import 'project_build_contract.dart' show ProjectBuildKind;
import 'project_bundle_v2.dart';
import 'project_json_canonicalizer.dart';
import 'project_build_v2_node.dart';
import 'project_build_v2_reference.dart';

const projectBuildV2MaximumSequence = 9007199254740991;
const projectBuildV2MaximumPageSize = 200;

// Delivery V2 stays separate from the strict control-plane V1 contract.
enum ProjectBuildV2Status {
  queued,
  running,
  cancelling,
  cancelled,
  failed,
  previewReady,
  completed,
}

extension ProjectBuildV2StatusWire on ProjectBuildV2Status {
  String get wireName =>
      this == ProjectBuildV2Status.previewReady ? 'preview_ready' : name;
  bool get retryable =>
      this == ProjectBuildV2Status.failed ||
      this == ProjectBuildV2Status.cancelled;
}

enum ProjectBuildV2Operation { cancel, retry, accept }

String canonicalProjectBuildV2Locale(String locale) {
  if (locale.length > 35 ||
      !RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$').hasMatch(locale)) {
    return 'en';
  }
  return locale.split('-').first.toLowerCase() == 'zh' ? 'zh' : 'en';
}

final class ProjectBuildV2CreateRequest {
  ProjectBuildV2CreateRequest({
    required this.requestId,
    required this.agentId,
    required this.projectKind,
    required this.requirements,
    String locale = 'en',
    this.projectId,
    this.baseRevision,
    this.baseHeadVersion,
    List<ProjectBuildReferenceInput> referenceInputs = const [],
  }) : locale = canonicalProjectBuildV2Locale(locale),
       referenceInputs = List.unmodifiable(referenceInputs) {
    _requestId(requestId);
    if (referenceInputs.length > 4 ||
        referenceInputs.map((r) => r.referenceId).toSet().length !=
            referenceInputs.length) {
      throw const FormatException('project_build_reference_inputs');
    }
    if ((projectId == null) != (baseRevision == null) ||
        (projectId == null) != (baseHeadVersion == null)) {
      throw const FormatException('project_build_edit_identity');
    }
    if (projectId != null) {
      projectBuildV2Id(projectId, 'project');
      projectBuildV2Id(baseRevision, 'revision');
      _integer(baseHeadVersion);
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(agentId) ||
        requirements.trim().isEmpty ||
        requirements.runes.length > 12000 ||
        utf8.encode(requirements).length > 48 * 1024) {
      throw const FormatException('invalid_project_build_input');
    }
  }

  final String requestId;
  final String agentId;
  final ProjectBuildKind projectKind;
  final String requirements;
  final String locale;
  final String? projectId;
  final String? baseRevision;
  final int? baseHeadVersion;
  final List<ProjectBuildReferenceInput> referenceInputs;

  factory ProjectBuildV2CreateRequest.fromJson(Map<String, Object?> data) {
    _keys(
      data,
      {'requestId', 'agentId', 'projectKind', 'requirements', 'locale'},
      optional: {
        'projectId',
        'baseRevision',
        'baseHeadVersion',
        'referenceInputs',
      },
    );
    if (data.containsKey('referenceInputs') &&
        data['referenceInputs'] is! List) {
      throw const FormatException('project_build_reference_inputs');
    }
    return ProjectBuildV2CreateRequest(
      requestId: _string(data['requestId']),
      agentId: _string(data['agentId']),
      projectKind: ProjectBuildKind.values.byName(_string(data['projectKind'])),
      requirements: _string(data['requirements']),
      locale: _string(data['locale']),
      projectId: data.containsKey('projectId')
          ? _string(data['projectId'])
          : null,
      baseRevision: data.containsKey('baseRevision')
          ? _string(data['baseRevision'])
          : null,
      baseHeadVersion: data.containsKey('baseHeadVersion')
          ? _integer(data['baseHeadVersion'])
          : null,
      referenceInputs: (data['referenceInputs'] as List? ?? const [])
          .map(ProjectBuildReferenceInput.fromJson)
          .toList(),
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'agentId': agentId,
    'projectKind': projectKind.name,
    'requirements': requirements,
    'locale': locale,
    if (projectId != null) 'projectId': projectId,
    if (baseRevision != null) 'baseRevision': baseRevision,
    if (baseHeadVersion != null) 'baseHeadVersion': baseHeadVersion,
    if (referenceInputs.isNotEmpty)
      'referenceInputs': referenceInputs.map((r) => r.toJson()).toList(),
  };
}

final class ProjectBuildV2Command {
  ProjectBuildV2Command({
    required this.operation,
    required this.requestId,
    required this.expectedRunId,
    required this.expectedStatusVersion,
    this.candidateDigest,
    this.baseRevision,
    this.expectedHeadVersion,
  }) {
    _requestId(requestId);
    projectBuildV2Id(expectedRunId, 'run');
    _integer(expectedStatusVersion);
    if (operation == ProjectBuildV2Operation.accept) {
      _digest(candidateDigest);
      _integer(
        expectedHeadVersion,
        minimum: 0,
        maximum: projectBuildV2MaximumSequence - 1,
      );
      if ((baseRevision == null) != (expectedHeadVersion == 0)) {
        throw const FormatException('project_build_head_identity');
      }
      if (baseRevision != null) projectBuildV2Id(baseRevision, 'revision');
    } else if (candidateDigest != null ||
        baseRevision != null ||
        expectedHeadVersion != null) {
      throw const FormatException('project_build_command_fields');
    }
  }

  final ProjectBuildV2Operation operation;
  final String requestId;
  final String expectedRunId;
  final int expectedStatusVersion;
  final String? candidateDigest;
  final String? baseRevision;
  final int? expectedHeadVersion;

  factory ProjectBuildV2Command.fromJson(
    Map<String, Object?> data, {
    required ProjectBuildV2Operation operation,
  }) {
    _keys(data, {
      'requestId',
      'expectedRunId',
      'expectedStatusVersion',
      if (operation == ProjectBuildV2Operation.accept) ...[
        'candidateDigest',
        'baseRevision',
        'expectedHeadVersion',
      ],
    });
    return ProjectBuildV2Command(
      operation: operation,
      requestId: _string(data['requestId']),
      expectedRunId: _string(data['expectedRunId']),
      expectedStatusVersion: _integer(data['expectedStatusVersion']),
      candidateDigest: data['candidateDigest'] as String?,
      baseRevision: data['baseRevision'] as String?,
      expectedHeadVersion: operation == ProjectBuildV2Operation.accept
          ? _integer(data['expectedHeadVersion'], minimum: 0)
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'expectedRunId': expectedRunId,
    'expectedStatusVersion': expectedStatusVersion,
    if (operation == ProjectBuildV2Operation.accept)
      'candidateDigest': candidateDigest,
    if (operation == ProjectBuildV2Operation.accept)
      'baseRevision': baseRevision,
    if (operation == ProjectBuildV2Operation.accept)
      'expectedHeadVersion': expectedHeadVersion,
  };
}

final class ProjectBuildV2Receipt {
  ProjectBuildV2Receipt._({
    required this.requestId,
    required this.taskId,
    required this.runId,
    required this.attempt,
    required this.acceptedTaskSequence,
    this.savedRevision,
  });

  final String requestId;
  final String taskId;
  final String runId;
  final int attempt;
  final int acceptedTaskSequence;
  final ProjectBuildV2SavedRevision? savedRevision;

  factory ProjectBuildV2Receipt.fromJson(Map<String, Object?> data) {
    _keys(
      data,
      {'requestId', 'taskId', 'runId', 'attempt', 'acceptedTaskSequence'},
      optional: {
        'savedHeadVersion',
        'savedProjectId',
        'savedRevisionId',
        'candidateDigest',
        'reportDigest',
      },
    );
    final request = _string(data['requestId']);
    _requestId(request);
    return ProjectBuildV2Receipt._(
      requestId: request,
      taskId: projectBuildV2Id(data['taskId'], 'task'),
      runId: projectBuildV2Id(data['runId'], 'run'),
      attempt: _integer(data['attempt'], maximum: 1000),
      acceptedTaskSequence: _integer(data['acceptedTaskSequence']),
      savedRevision:
          data.keys.any(
            (key) => const {
              'savedHeadVersion',
              'savedProjectId',
              'savedRevisionId',
              'candidateDigest',
              'reportDigest',
            }.contains(key),
          )
          ? ProjectBuildV2SavedRevision.fromJson({
              'headVersion': data['savedHeadVersion'],
              'projectId': data['savedProjectId'],
              'revisionId': data['savedRevisionId'],
              'candidateDigest': data['candidateDigest'],
              'reportDigest': data['reportDigest'],
            })
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'taskId': taskId,
    'runId': runId,
    'attempt': attempt,
    'acceptedTaskSequence': acceptedTaskSequence,
    if (savedRevision != null) ...{
      'savedHeadVersion': savedRevision!.headVersion,
      'savedProjectId': savedRevision!.projectId,
      'savedRevisionId': savedRevision!.revisionId,
      'candidateDigest': savedRevision!.candidateDigest,
      'reportDigest': savedRevision!.reportDigest,
    },
  };
}

final class ProjectBuildV2Checkpoint {
  ProjectBuildV2Checkpoint._(this.digest, this.byteLength);
  final String digest;
  final int byteLength;

  factory ProjectBuildV2Checkpoint.fromJson(Map<String, Object?> data) {
    _keys(data, {'digest', 'byteLength'});
    final digest = _string(data['digest']);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('invalid_project_build_checkpoint');
    }
    return ProjectBuildV2Checkpoint._(
      digest,
      _integer(data['byteLength'], maximum: 262144),
    );
  }

  Map<String, Object?> toJson() => {'digest': digest, 'byteLength': byteLength};
}

final class ProjectBuildV2Snapshot {
  ProjectBuildV2Snapshot._({
    required this.taskId,
    required this.runId,
    required this.attempt,
    required this.agentId,
    required this.projectKind,
    required this.projectId,
    required this.status,
    required this.statusVersion,
    required this.requirementRevision,
    required this.snapshotSequence,
    required this.snapshotTaskSequence,
    required this.createdAt,
    required this.updatedAt,
    required this.errorCode,
    required this.checkpoint,
    required this.candidate,
    required this.savedRevision,
  });

  final String taskId;
  final String runId;
  final int attempt;
  final String agentId;
  final ProjectBuildKind projectKind;
  final String projectId;
  final ProjectBuildV2Status status;
  final int statusVersion;
  final int requirementRevision;
  final int snapshotSequence;
  final int snapshotTaskSequence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String errorCode;
  final ProjectBuildV2Checkpoint? checkpoint;
  final ProjectBuildV2CandidateReference? candidate;
  final ProjectBuildV2SavedRevision? savedRevision;
  bool get isTerminal =>
      status == ProjectBuildV2Status.cancelled ||
      status == ProjectBuildV2Status.failed ||
      status == ProjectBuildV2Status.completed;

  factory ProjectBuildV2Snapshot.fromJson(Map<String, Object?> data) {
    _keys(
      data,
      {
        'schemaVersion',
        'kind',
        'taskId',
        'runId',
        'attempt',
        'agentId',
        'projectKind',
        'projectId',
        'status',
        'statusVersion',
        'requirementRevision',
        'snapshotSequence',
        'snapshotTaskSequence',
        'createdAt',
        'updatedAt',
        'errorCode',
      },
      optional: {'checkpoint', 'candidate', 'savedRevision'},
    );
    final agent = _string(data['agentId']);
    final error = _string(data['errorCode']);
    final status = ProjectBuildV2Status.values.singleWhere(
      (value) => value.wireName == _string(data['status']),
    );
    final created = _time(data['createdAt']);
    final updated = _time(data['updatedAt']);
    if (data['schemaVersion'] is! int ||
        data['schemaVersion'] != 2 ||
        data['kind'] != 'project_build' ||
        data['requirementRevision'] is! int ||
        data['requirementRevision'] != 1 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(agent) ||
        (status == ProjectBuildV2Status.failed
            ? !const {
                'worker_failed',
                'validation_failed',
                'provider_unavailable',
                'budget_exhausted',
                'execution_timeout',
                'vision_unsupported',
              }.contains(error)
            : error.isNotEmpty) ||
        updated.isBefore(created)) {
      throw const FormatException('invalid_project_build_snapshot');
    }
    final sequence = _integer(data['snapshotSequence']);
    final taskSequence = _integer(data['snapshotTaskSequence']);
    if (sequence > taskSequence) {
      throw const FormatException('invalid_project_build_sequences');
    }
    final candidate = data.containsKey('candidate')
        ? ProjectBuildV2CandidateReference.fromJson(
            projectBuildV2Object(data['candidate']),
          )
        : null;
    final saved = data.containsKey('savedRevision')
        ? ProjectBuildV2SavedRevision.fromJson(
            projectBuildV2Object(data['savedRevision']),
          )
        : null;
    if ((const {
              ProjectBuildV2Status.previewReady,
              ProjectBuildV2Status.completed,
            }.contains(status) &&
            candidate == null) ||
        (status == ProjectBuildV2Status.completed) != (saved != null) ||
        (saved != null &&
            (saved.projectId != data['projectId'] ||
                saved.revisionId != candidate!.revisionId ||
                saved.candidateDigest != candidate.candidateDigest ||
                saved.reportDigest != candidate.reportDigest ||
                saved.headVersion != (candidate.baseHeadVersion ?? 0) + 1))) {
      throw const FormatException('project_build_delivery_identity');
    }
    return ProjectBuildV2Snapshot._(
      taskId: projectBuildV2Id(data['taskId'], 'task'),
      runId: projectBuildV2Id(data['runId'], 'run'),
      attempt: _integer(data['attempt'], maximum: 1000),
      agentId: agent,
      projectKind: ProjectBuildKind.values.byName(_string(data['projectKind'])),
      projectId: projectBuildV2Id(data['projectId'], 'project'),
      status: status,
      statusVersion: _integer(data['statusVersion']),
      requirementRevision: 1,
      snapshotSequence: sequence,
      snapshotTaskSequence: taskSequence,
      createdAt: created,
      updatedAt: updated,
      errorCode: error,
      candidate: candidate,
      savedRevision: saved,
      checkpoint: data.containsKey('checkpoint')
          ? ProjectBuildV2Checkpoint.fromJson(
              projectBuildV2Object(data['checkpoint']),
            )
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 2,
    'kind': 'project_build',
    'taskId': taskId,
    'runId': runId,
    'attempt': attempt,
    'agentId': agentId,
    'projectKind': projectKind.name,
    'projectId': projectId,
    'status': status.wireName,
    'statusVersion': statusVersion,
    'requirementRevision': requirementRevision,
    'snapshotSequence': snapshotSequence,
    'snapshotTaskSequence': snapshotTaskSequence,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'errorCode': errorCode,
    if (checkpoint != null) 'checkpoint': checkpoint!.toJson(),
    if (candidate != null) 'candidate': candidate!.toJson(),
    if (savedRevision != null) 'savedRevision': savedRevision!.toJson(),
  };

  bool sameState(ProjectBuildV2Snapshot other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

sealed class ProjectBuildV2Event {
  const ProjectBuildV2Event._({
    required this.taskSequence,
    required this.sequence,
    required this.taskId,
    required this.runId,
    required this.type,
    required this.at,
  });
  final int taskSequence, sequence;
  final String taskId, runId, type;
  final DateTime at;
  int get attempt;
  int get statusVersion;
  static const stateTypes = {
    'task.created',
    'run.claimed',
    'run.reclaimed',
    'run.checkpointed',
    'run.failed',
    'run.cancel_requested',
    'run.cancelled',
    'run.retried',
    'run.cancel_cleanup_claimed',
    'run.preview_ready',
    'run.completed',
  };

  factory ProjectBuildV2Event.fromJson(Map<String, Object?> data) =>
      data['type'] == 'run.node_changed'
      ? ProjectBuildV2NodeDelta.fromJson(data)
      : ProjectBuildV2StateEvent.fromJson(data);
  ProjectBuildV2Snapshot resolveSnapshot(ProjectBuildV2Snapshot? previous);
  Map<String, Object?> toJson();
  bool sameEvent(ProjectBuildV2Event other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

final class ProjectBuildV2StateEvent extends ProjectBuildV2Event {
  ProjectBuildV2StateEvent._({
    required super.taskSequence,
    required super.sequence,
    required super.taskId,
    required super.runId,
    required super.type,
    required super.at,
    required this.snapshot,
  }) : super._();
  final ProjectBuildV2Snapshot snapshot;
  @override
  int get attempt => snapshot.attempt;
  @override
  int get statusVersion => snapshot.statusVersion;
  @override
  ProjectBuildV2Snapshot resolveSnapshot(ProjectBuildV2Snapshot? previous) =>
      snapshot;
  factory ProjectBuildV2StateEvent.fromJson(Map<String, Object?> data) {
    _keys(data, {
      'taskSequence',
      'sequence',
      'taskId',
      'runId',
      'type',
      'at',
      'snapshot',
    });
    final snapshot = ProjectBuildV2Snapshot.fromJson(
      projectBuildV2Object(data['snapshot']),
    );
    final taskSequence = _integer(data['taskSequence']);
    final sequence = _integer(data['sequence']);
    final task = projectBuildV2Id(data['taskId'], 'task');
    final run = projectBuildV2Id(data['runId'], 'run');
    final type = _string(data['type']);
    final at = _time(data['at']);
    final expectedStatus = switch (type) {
      'task.created' || 'run.retried' => ProjectBuildV2Status.queued,
      'run.claimed' ||
      'run.reclaimed' ||
      'run.checkpointed' => ProjectBuildV2Status.running,
      'run.failed' => ProjectBuildV2Status.failed,
      'run.preview_ready' => ProjectBuildV2Status.previewReady,
      'run.completed' => ProjectBuildV2Status.completed,
      'run.cancel_requested' ||
      'run.cancel_cleanup_claimed' => ProjectBuildV2Status.cancelling,
      'run.cancelled' => ProjectBuildV2Status.cancelled,
      _ => null,
    };
    if (!ProjectBuildV2Event.stateTypes.contains(type) ||
        expectedStatus != snapshot.status ||
        task != snapshot.taskId ||
        run != snapshot.runId ||
        taskSequence != snapshot.snapshotTaskSequence ||
        sequence != snapshot.snapshotSequence ||
        at != snapshot.updatedAt) {
      throw const FormatException('invalid_project_build_event');
    }
    return ProjectBuildV2StateEvent._(
      taskSequence: taskSequence,
      sequence: sequence,
      taskId: task,
      runId: run,
      type: type,
      at: at,
      snapshot: snapshot,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'taskSequence': taskSequence,
    'sequence': sequence,
    'taskId': taskId,
    'runId': runId,
    'type': type,
    'at': at.toUtc().toIso8601String(),
    'snapshot': snapshot.toJson(),
  };
}

/// Compact node deltas carry no snapshot and cannot independently change task
/// identity/status. Header projection requires the contiguous prior run state.
final class ProjectBuildV2NodeDelta extends ProjectBuildV2Event {
  ProjectBuildV2NodeDelta._({
    required super.taskSequence,
    required super.sequence,
    required super.taskId,
    required super.runId,
    required super.at,
    required this.attempt,
    required this.statusVersion,
    required this.node,
  }) : super._(type: 'run.node_changed');
  @override
  final int attempt;
  @override
  final int statusVersion;
  final ProjectBuildV2Node node;
  factory ProjectBuildV2NodeDelta.fromJson(Map<String, Object?> data) {
    _keys(data, {
      'taskSequence',
      'sequence',
      'taskId',
      'runId',
      'type',
      'at',
      'attempt',
      'statusVersion',
      'node',
    });
    final sequence = _integer(data['sequence']),
        taskSequence = _integer(data['taskSequence']);
    if (data['type'] != 'run.node_changed' || sequence > taskSequence) {
      throw const FormatException('project_build_node_delta_invalid');
    }
    return ProjectBuildV2NodeDelta._(
      taskSequence: taskSequence,
      sequence: sequence,
      taskId: projectBuildV2Id(data['taskId'], 'task'),
      runId: projectBuildV2Id(data['runId'], 'run'),
      at: _time(data['at']),
      attempt: _integer(data['attempt'], maximum: 1000),
      statusVersion: _integer(data['statusVersion']),
      node: ProjectBuildV2Node.fromJson(data['node']),
    );
  }
  @override
  ProjectBuildV2Snapshot resolveSnapshot(ProjectBuildV2Snapshot? previous) {
    if (previous == null ||
        previous.status != ProjectBuildV2Status.running ||
        previous.taskId != taskId ||
        previous.runId != runId ||
        previous.attempt != attempt ||
        sequence != previous.snapshotSequence + 1 ||
        taskSequence != previous.snapshotTaskSequence + 1 ||
        statusVersion != previous.statusVersion + 1 ||
        at.isBefore(previous.updatedAt)) {
      throw StateError('project_build_node_header_conflict');
    }
    return ProjectBuildV2Snapshot.fromJson({
      ...previous.toJson(),
      'snapshotSequence': sequence,
      'snapshotTaskSequence': taskSequence,
      'statusVersion': statusVersion,
      'updatedAt': at.toUtc().toIso8601String(),
    });
  }

  @override
  Map<String, Object?> toJson() => {
    'taskSequence': taskSequence,
    'sequence': sequence,
    'taskId': taskId,
    'runId': runId,
    'type': type,
    'at': at.toUtc().toIso8601String(),
    'attempt': attempt,
    'statusVersion': statusVersion,
    'node': node.toJson(),
  };
}

final class ProjectBuildV2EventPage {
  ProjectBuildV2EventPage._(this.events, this.nextTaskSequence, this.hasMore);
  final List<ProjectBuildV2Event> events;
  final int nextTaskSequence;
  final bool hasMore;

  factory ProjectBuildV2EventPage.fromJson(
    Map<String, Object?> data, {
    required String taskId,
    required int afterTaskSequence,
  }) {
    projectBuildV2Id(taskId, 'task');
    _integer(afterTaskSequence, minimum: 0);
    _keys(data, {'events', 'nextTaskSequence', 'hasMore'});
    final raw = data['events'];
    if (raw is! List ||
        raw.length > projectBuildV2MaximumPageSize ||
        data['hasMore'] is! bool) {
      throw const FormatException('invalid_project_build_events');
    }
    var cursor = afterTaskSequence;
    final events = <ProjectBuildV2Event>[];
    for (final item in raw) {
      final event = ProjectBuildV2Event.fromJson(projectBuildV2Object(item));
      if (event.taskId != taskId || event.taskSequence != cursor + 1) {
        throw const FormatException('project_build_event_gap');
      }
      events.add(event);
      cursor = event.taskSequence;
    }
    final next = _integer(data['nextTaskSequence'], minimum: 0);
    if (cursor != next || (data['hasMore'] == true && events.isEmpty)) {
      throw const FormatException('invalid_project_build_event_cursor');
    }
    return ProjectBuildV2EventPage._(
      List.unmodifiable(events),
      next,
      data['hasMore']! as bool,
    );
  }

  Map<String, Object?> toJson() => {
    'events': events.map((event) => event.toJson()).toList(),
    'nextTaskSequence': nextTaskSequence,
    'hasMore': hasMore,
  };
}

Map<String, Object?> projectBuildV2Object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('invalid_project_build_object');
  }
  return Map<String, Object?>.from(value);
}

String projectBuildV2Id(Object? value, String kind) {
  final id = _string(value);
  if (!RegExp(
    '^pb_${kind}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$',
  ).hasMatch(id)) {
    throw const FormatException('invalid_project_build_id');
  }
  return id;
}

void _requestId(String id) {
  if (!RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(id)) {
    throw const FormatException('invalid_project_build_request_id');
  }
}

String _string(Object? value) {
  if (value is! String) {
    throw const FormatException('invalid_project_build_string');
  }
  return value;
}

int _integer(
  Object? value, {
  int minimum = 1,
  int maximum = projectBuildV2MaximumSequence,
}) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('invalid_project_build_integer');
  }
  return value;
}

DateTime _time(Object? value) {
  final raw = _string(value);
  if (!raw.endsWith('Z')) {
    throw const FormatException('invalid_project_build_time');
  }
  return DateTime.parse(raw).toUtc();
}

void _keys(
  Map<String, Object?> data,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (!required.every(data.containsKey) ||
      data.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    throw const FormatException('invalid_project_build_fields');
  }
}

String _digest(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('project_build_digest');
  }
  return value;
}

final class ProjectBuildV2CandidateReference {
  ProjectBuildV2CandidateReference._(
    this.candidateId,
    this.candidateDigest,
    this.reportDigest,
    this.revisionId,
    this.baseRevision,
    this.baseHeadVersion,
  );
  final String candidateId, candidateDigest, reportDigest, revisionId;
  final String? baseRevision;
  final int? baseHeadVersion;
  factory ProjectBuildV2CandidateReference.fromJson(Map<String, Object?> data) {
    _keys(data, {
      'candidateId',
      'candidateDigest',
      'reportDigest',
      'revisionId',
      'baseRevision',
      'baseHeadVersion',
    });
    if ((data['baseRevision'] == null) != (data['baseHeadVersion'] == null)) {
      throw const FormatException('project_build_head_identity');
    }
    return ProjectBuildV2CandidateReference._(
      projectBuildV2Id(data['candidateId'], 'candidate'),
      _digest(data['candidateDigest']),
      _digest(data['reportDigest']),
      projectBuildV2Id(data['revisionId'], 'revision'),
      data['baseRevision'] == null
          ? null
          : projectBuildV2Id(data['baseRevision'], 'revision'),
      data['baseHeadVersion'] == null
          ? null
          : _integer(data['baseHeadVersion']),
    );
  }
  Map<String, Object?> toJson() => {
    'candidateId': candidateId,
    'candidateDigest': candidateDigest,
    'reportDigest': reportDigest,
    'revisionId': revisionId,
    'baseRevision': baseRevision,
    'baseHeadVersion': baseHeadVersion,
  };
}

final class ProjectBuildV2SavedRevision {
  ProjectBuildV2SavedRevision._(
    this.projectId,
    this.revisionId,
    this.candidateDigest,
    this.reportDigest,
    this.headVersion,
  );
  final String projectId, revisionId, candidateDigest, reportDigest;
  final int headVersion;
  factory ProjectBuildV2SavedRevision.fromJson(Map<String, Object?> data) {
    _keys(data, {
      'projectId',
      'revisionId',
      'candidateDigest',
      'reportDigest',
      'headVersion',
    });
    return ProjectBuildV2SavedRevision._(
      projectBuildV2Id(data['projectId'], 'project'),
      projectBuildV2Id(data['revisionId'], 'revision'),
      _digest(data['candidateDigest']),
      _digest(data['reportDigest']),
      _integer(data['headVersion']),
    );
  }
  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'revisionId': revisionId,
    'candidateDigest': candidateDigest,
    'reportDigest': reportDigest,
    'headVersion': headVersion,
  };
}

/// Parsed from strict HTTP JSON bytes, then bound again to the replayed task.
/// A signed report still requires the account's verification service.
final class ProjectBuildV2Candidate {
  ProjectBuildV2Candidate._(
    this.taskId,
    this.runId,
    this.projectId,
    this.reference,
    this.bundle,
    this.report,
  );
  final String taskId, runId, projectId;
  final ProjectBuildV2CandidateReference reference;
  final ValidatedProjectBundleV2 bundle;
  final Map<String, Object?> report;
  factory ProjectBuildV2Candidate.fromJson(Map<String, Object?> data) {
    _keys(data, {
      'schemaVersion',
      'taskId',
      'runId',
      'projectId',
      'candidateId',
      'candidateDigest',
      'reportDigest',
      'revisionId',
      'baseRevision',
      'baseHeadVersion',
      'bundle',
      'report',
    });
    if (data['schemaVersion'] != 2) {
      throw const FormatException('project_build_candidate_schema');
    }
    final reference = ProjectBuildV2CandidateReference.fromJson({
      for (final key in [
        'candidateId',
        'candidateDigest',
        'reportDigest',
        'revisionId',
        'baseRevision',
        'baseHeadVersion',
      ])
        key: data[key],
    });
    final bundle = const ProjectBundleV2Codec().decode(data['bundle']);
    final projectId = projectBuildV2Id(data['projectId'], 'project');
    if (bundle.manifest.projectId != projectId ||
        bundle.manifest.revisionId != reference.revisionId ||
        bundle.candidateDigest != reference.candidateDigest ||
        bundle.manifest.baseRevision != reference.baseRevision) {
      throw const FormatException('project_build_candidate_identity');
    }
    final report = projectBuildV2Object(data['report']);
    // Round trip makes all nested collections owned; callers receive a deep
    // read-only snapshot so validation cannot later be changed by mutation.
    final frozen =
        _freeze(
              const ProjectJsonCanonicalizer(maxBytes: 262144).parse(
                const ProjectJsonCanonicalizer(
                  maxBytes: 262144,
                ).canonicalize(report),
              ),
            )
            as Map<String, Object?>;
    return ProjectBuildV2Candidate._(
      projectBuildV2Id(data['taskId'], 'task'),
      projectBuildV2Id(data['runId'], 'run'),
      projectId,
      reference,
      bundle,
      frozen,
    );
  }
  bool matches(ProjectBuildV2Snapshot snapshot) =>
      taskId == snapshot.taskId &&
      runId == snapshot.runId &&
      projectId == snapshot.projectId &&
      bundle.manifest.projectKind == snapshot.projectKind.name &&
      bundle.manifest.requirementRevision == snapshot.requirementRevision &&
      jsonEncode(reference.toJson()) ==
          jsonEncode(snapshot.candidate?.toJson());
}

Object? _freeze(Object? value) => value is Map
    ? Map<String, Object?>.unmodifiable(
        value.map((key, item) => MapEntry(key as String, _freeze(item))),
      )
    : value is List
    ? List<Object?>.unmodifiable(value.map(_freeze))
    : value;
