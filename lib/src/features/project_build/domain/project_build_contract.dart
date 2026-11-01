import 'dart:convert';

const projectBuildMaximumSequence = 9007199254740991;
const projectBuildMaximumPageSize = 200;

enum ProjectBuildKind { applet, game }

// A control-plane acceptance is not a generated project. This contract does
// not support a successful build/result until a real worker contract exists.
enum ProjectBuildStatus { queued, running, cancelling, cancelled, failed }

enum ProjectBuildOperation { cancel, retry }

String canonicalProjectBuildLocale(String locale) {
  if (locale.length > 35 ||
      !RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$').hasMatch(locale)) {
    return 'en';
  }
  return locale.split('-').first.toLowerCase() == 'zh' ? 'zh' : 'en';
}

final class ProjectBuildCreateRequest {
  ProjectBuildCreateRequest({
    required this.requestId,
    required this.agentId,
    required this.projectKind,
    required this.requirements,
    String locale = 'en',
  }) : locale = canonicalProjectBuildLocale(locale) {
    _requestId(requestId);
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

  factory ProjectBuildCreateRequest.fromJson(Map<String, Object?> data) {
    _keys(data, {
      'requestId',
      'agentId',
      'projectKind',
      'requirements',
      'locale',
    });
    return ProjectBuildCreateRequest(
      requestId: _string(data['requestId']),
      agentId: _string(data['agentId']),
      projectKind: ProjectBuildKind.values.byName(_string(data['projectKind'])),
      requirements: _string(data['requirements']),
      locale: _string(data['locale']),
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'agentId': agentId,
    'projectKind': projectKind.name,
    'requirements': requirements,
    'locale': locale,
  };
}

final class ProjectBuildCommand {
  ProjectBuildCommand({
    required this.operation,
    required this.requestId,
    required this.expectedRunId,
    required this.expectedStatusVersion,
  }) {
    _requestId(requestId);
    projectBuildId(expectedRunId, 'run');
    _integer(expectedStatusVersion);
  }

  final ProjectBuildOperation operation;
  final String requestId;
  final String expectedRunId;
  final int expectedStatusVersion;

  factory ProjectBuildCommand.fromJson(
    Map<String, Object?> data, {
    required ProjectBuildOperation operation,
  }) {
    _keys(data, {'requestId', 'expectedRunId', 'expectedStatusVersion'});
    return ProjectBuildCommand(
      operation: operation,
      requestId: _string(data['requestId']),
      expectedRunId: _string(data['expectedRunId']),
      expectedStatusVersion: _integer(data['expectedStatusVersion']),
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'expectedRunId': expectedRunId,
    'expectedStatusVersion': expectedStatusVersion,
  };
}

final class ProjectBuildReceipt {
  ProjectBuildReceipt._({
    required this.requestId,
    required this.taskId,
    required this.runId,
    required this.attempt,
    required this.acceptedTaskSequence,
  });

  final String requestId;
  final String taskId;
  final String runId;
  final int attempt;
  final int acceptedTaskSequence;

  factory ProjectBuildReceipt.fromJson(Map<String, Object?> data) {
    _keys(data, {
      'requestId',
      'taskId',
      'runId',
      'attempt',
      'acceptedTaskSequence',
    });
    final request = _string(data['requestId']);
    _requestId(request);
    return ProjectBuildReceipt._(
      requestId: request,
      taskId: projectBuildId(data['taskId'], 'task'),
      runId: projectBuildId(data['runId'], 'run'),
      attempt: _integer(data['attempt'], maximum: 1000),
      acceptedTaskSequence: _integer(data['acceptedTaskSequence']),
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'taskId': taskId,
    'runId': runId,
    'attempt': attempt,
    'acceptedTaskSequence': acceptedTaskSequence,
  };
}

final class ProjectBuildCheckpoint {
  ProjectBuildCheckpoint._(this.digest, this.byteLength);
  final String digest;
  final int byteLength;

  factory ProjectBuildCheckpoint.fromJson(Map<String, Object?> data) {
    _keys(data, {'digest', 'byteLength'});
    final digest = _string(data['digest']);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('invalid_project_build_checkpoint');
    }
    return ProjectBuildCheckpoint._(
      digest,
      _integer(data['byteLength'], maximum: 262144),
    );
  }

  Map<String, Object?> toJson() => {'digest': digest, 'byteLength': byteLength};
}

final class ProjectBuildSnapshot {
  ProjectBuildSnapshot._({
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
  });

  final String taskId;
  final String runId;
  final int attempt;
  final String agentId;
  final ProjectBuildKind projectKind;
  final String projectId;
  final ProjectBuildStatus status;
  final int statusVersion;
  final int requirementRevision;
  final int snapshotSequence;
  final int snapshotTaskSequence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String errorCode;
  final ProjectBuildCheckpoint? checkpoint;
  bool get isTerminal =>
      status == ProjectBuildStatus.cancelled ||
      status == ProjectBuildStatus.failed;

  factory ProjectBuildSnapshot.fromJson(Map<String, Object?> data) {
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
      optional: {'checkpoint'},
    );
    final agent = _string(data['agentId']);
    final error = _string(data['errorCode']);
    final status = ProjectBuildStatus.values.byName(_string(data['status']));
    final created = _time(data['createdAt']);
    final updated = _time(data['updatedAt']);
    if (data['schemaVersion'] is! int ||
        data['schemaVersion'] != 1 ||
        data['kind'] != 'project_build' ||
        data['requirementRevision'] is! int ||
        data['requirementRevision'] != 1 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(agent) ||
        (status == ProjectBuildStatus.failed
            ? !const {
                'worker_failed',
                'validation_failed',
                'provider_unavailable',
                'budget_exhausted',
                'execution_timeout',
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
    return ProjectBuildSnapshot._(
      taskId: projectBuildId(data['taskId'], 'task'),
      runId: projectBuildId(data['runId'], 'run'),
      attempt: _integer(data['attempt'], maximum: 1000),
      agentId: agent,
      projectKind: ProjectBuildKind.values.byName(_string(data['projectKind'])),
      projectId: projectBuildId(data['projectId'], 'project'),
      status: status,
      statusVersion: _integer(data['statusVersion']),
      requirementRevision: 1,
      snapshotSequence: sequence,
      snapshotTaskSequence: taskSequence,
      createdAt: created,
      updatedAt: updated,
      errorCode: error,
      checkpoint: data.containsKey('checkpoint')
          ? ProjectBuildCheckpoint.fromJson(
              projectBuildObject(data['checkpoint']),
            )
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'kind': 'project_build',
    'taskId': taskId,
    'runId': runId,
    'attempt': attempt,
    'agentId': agentId,
    'projectKind': projectKind.name,
    'projectId': projectId,
    'status': status.name,
    'statusVersion': statusVersion,
    'requirementRevision': requirementRevision,
    'snapshotSequence': snapshotSequence,
    'snapshotTaskSequence': snapshotTaskSequence,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'errorCode': errorCode,
    if (checkpoint != null) 'checkpoint': checkpoint!.toJson(),
  };

  bool sameState(ProjectBuildSnapshot other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

final class ProjectBuildEvent {
  ProjectBuildEvent._({
    required this.taskSequence,
    required this.sequence,
    required this.taskId,
    required this.runId,
    required this.type,
    required this.at,
    required this.snapshot,
  });

  static const types = {
    'task.created',
    'run.claimed',
    'run.reclaimed',
    'run.checkpointed',
    'run.failed',
    'run.cancel_requested',
    'run.cancelled',
    'run.retried',
    'run.cancel_cleanup_claimed',
  };
  final int taskSequence;
  final int sequence;
  final String taskId;
  final String runId;
  final String type;
  final DateTime at;
  final ProjectBuildSnapshot snapshot;

  factory ProjectBuildEvent.fromJson(Map<String, Object?> data) {
    _keys(data, {
      'taskSequence',
      'sequence',
      'taskId',
      'runId',
      'type',
      'at',
      'snapshot',
    });
    final snapshot = ProjectBuildSnapshot.fromJson(
      projectBuildObject(data['snapshot']),
    );
    final taskSequence = _integer(data['taskSequence']);
    final sequence = _integer(data['sequence']);
    final task = projectBuildId(data['taskId'], 'task');
    final run = projectBuildId(data['runId'], 'run');
    final type = _string(data['type']);
    final at = _time(data['at']);
    final expectedStatus = switch (type) {
      'task.created' || 'run.retried' => ProjectBuildStatus.queued,
      'run.claimed' ||
      'run.reclaimed' ||
      'run.checkpointed' => ProjectBuildStatus.running,
      'run.failed' => ProjectBuildStatus.failed,
      'run.cancel_requested' ||
      'run.cancel_cleanup_claimed' => ProjectBuildStatus.cancelling,
      'run.cancelled' => ProjectBuildStatus.cancelled,
      _ => null,
    };
    if (!types.contains(type) ||
        expectedStatus != snapshot.status ||
        task != snapshot.taskId ||
        run != snapshot.runId ||
        taskSequence != snapshot.snapshotTaskSequence ||
        sequence != snapshot.snapshotSequence ||
        at != snapshot.updatedAt) {
      throw const FormatException('invalid_project_build_event');
    }
    return ProjectBuildEvent._(
      taskSequence: taskSequence,
      sequence: sequence,
      taskId: task,
      runId: run,
      type: type,
      at: at,
      snapshot: snapshot,
    );
  }

  Map<String, Object?> toJson() => {
    'taskSequence': taskSequence,
    'sequence': sequence,
    'taskId': taskId,
    'runId': runId,
    'type': type,
    'at': at.toUtc().toIso8601String(),
    'snapshot': snapshot.toJson(),
  };

  bool sameEvent(ProjectBuildEvent other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

final class ProjectBuildEventPage {
  ProjectBuildEventPage._(this.events, this.nextTaskSequence, this.hasMore);
  final List<ProjectBuildEvent> events;
  final int nextTaskSequence;
  final bool hasMore;

  factory ProjectBuildEventPage.fromJson(
    Map<String, Object?> data, {
    required String taskId,
    required int afterTaskSequence,
  }) {
    projectBuildId(taskId, 'task');
    _integer(afterTaskSequence, minimum: 0);
    _keys(data, {'events', 'nextTaskSequence', 'hasMore'});
    final raw = data['events'];
    if (raw is! List ||
        raw.length > projectBuildMaximumPageSize ||
        data['hasMore'] is! bool) {
      throw const FormatException('invalid_project_build_events');
    }
    var cursor = afterTaskSequence;
    final events = <ProjectBuildEvent>[];
    for (final item in raw) {
      final event = ProjectBuildEvent.fromJson(projectBuildObject(item));
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
    return ProjectBuildEventPage._(
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

Map<String, Object?> projectBuildObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('invalid_project_build_object');
  }
  return Map<String, Object?>.from(value);
}

String projectBuildId(Object? value, String kind) {
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
  int maximum = projectBuildMaximumSequence,
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
