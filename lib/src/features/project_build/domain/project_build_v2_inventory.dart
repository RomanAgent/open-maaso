import 'dart:convert';
import 'project_build_v2_contract.dart';

/// Owner-filtered discovery is separate from task history. No task cards or
/// execution events are synthesized from these saved revision descriptors.
final class ProjectBuildV2OwnedProject {
  ProjectBuildV2OwnedProject._(
    this.projectId,
    this.agentId,
    this.projectKind,
    this.title,
    this.currentRevisionId,
    this.revisionCount,
    this.headVersion,
    this.createdAt,
    this.updatedAt,
  );
  final String projectId, agentId, title, currentRevisionId;
  final ProjectBuildKind projectKind;
  final int revisionCount, headVersion;
  final DateTime createdAt, updatedAt;
  factory ProjectBuildV2OwnedProject.fromJson(Object? value) {
    final data = _fields(value, {
      'projectId',
      'agentId',
      'projectKind',
      'title',
      'currentRevisionId',
      'revisionCount',
      'headVersion',
      'createdAt',
      'updatedAt',
    });
    final title = data['title'],
        agentId = data['agentId'],
        count = data['revisionCount'];
    final created = _time(data['createdAt']),
        updated = _time(data['updatedAt']);
    if (title is! String ||
        title.trim().isEmpty ||
        title.runes.length > 80 ||
        utf8.encode(title).length > 320 ||
        RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(title) ||
        agentId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(agentId) ||
        count is! int ||
        count < 1 ||
        count > 128 ||
        updated.isBefore(created)) {
      throw const FormatException('project_build_owned_project_invalid');
    }
    return ProjectBuildV2OwnedProject._(
      projectBuildV2Id(data['projectId'], 'project'),
      agentId,
      ProjectBuildKind.values.byName(data['projectKind']! as String),
      title,
      projectBuildV2Id(data['currentRevisionId'], 'revision'),
      count,
      _version(data['headVersion']),
      created,
      updated,
    );
  }
  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'agentId': agentId,
    'projectKind': projectKind.name,
    'title': title,
    'currentRevisionId': currentRevisionId,
    'revisionCount': revisionCount,
    'headVersion': headVersion,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}

final class ProjectBuildV2OwnedProjects {
  ProjectBuildV2OwnedProjects._(this.projects);
  final List<ProjectBuildV2OwnedProject> projects;
  factory ProjectBuildV2OwnedProjects.fromJson(Object? value) {
    final data = _fields(value, {'schemaVersion', 'projects'}),
        raw = data['projects'];
    if (data['schemaVersion'] != 2 || raw is! List || raw.length > 5) {
      throw const FormatException('project_build_owned_inventory_invalid');
    }
    final projects = raw.map(ProjectBuildV2OwnedProject.fromJson).toList();
    if (projects.map((p) => p.projectId).toSet().length != projects.length) {
      throw const FormatException('project_build_owned_inventory_duplicate');
    }
    return ProjectBuildV2OwnedProjects._(List.unmodifiable(projects));
  }
  Map<String, Object?> toJson() => {
    'schemaVersion': 2,
    'projects': projects.map((p) => p.toJson()).toList(),
  };
}

final class ProjectBuildV2RevisionDescriptor {
  ProjectBuildV2RevisionDescriptor._(
    this.revisionId,
    this.baseRevision,
    this.candidateDigest,
    this.reportDigest,
    this.createdAt,
  );
  final String revisionId, candidateDigest, reportDigest;
  final String? baseRevision;
  final DateTime createdAt;
  factory ProjectBuildV2RevisionDescriptor.fromJson(Object? value) {
    final data = _fields(value, {
      'revisionId',
      'baseRevision',
      'candidateDigest',
      'reportDigest',
      'createdAt',
    });
    return ProjectBuildV2RevisionDescriptor._(
      projectBuildV2Id(data['revisionId'], 'revision'),
      data['baseRevision'] == null
          ? null
          : projectBuildV2Id(data['baseRevision'], 'revision'),
      _digest(data['candidateDigest']),
      _digest(data['reportDigest']),
      _time(data['createdAt']),
    );
  }
  Map<String, Object?> toJson() => {
    'revisionId': revisionId,
    'baseRevision': baseRevision,
    'candidateDigest': candidateDigest,
    'reportDigest': reportDigest,
    'createdAt': createdAt.toIso8601String(),
  };
  bool matches(ProjectBuildV2Candidate candidate) =>
      revisionId == candidate.reference.revisionId &&
      baseRevision == candidate.reference.baseRevision &&
      candidateDigest == candidate.reference.candidateDigest &&
      reportDigest == candidate.reference.reportDigest;
}

final class ProjectBuildV2OwnedRevisions {
  ProjectBuildV2OwnedRevisions._(
    this.projectId,
    this.currentRevisionId,
    this.currentHeadVersion,
    this.revisions,
  );
  final String projectId, currentRevisionId;
  final int currentHeadVersion;
  final List<ProjectBuildV2RevisionDescriptor> revisions;
  ProjectBuildV2RevisionDescriptor get current =>
      revisions.singleWhere((r) => r.revisionId == currentRevisionId);
  factory ProjectBuildV2OwnedRevisions.fromJson(Object? value) {
    final data = _fields(value, {
          'schemaVersion',
          'projectId',
          'currentRevisionId',
          'currentHeadVersion',
          'revisions',
        }),
        raw = data['revisions'];
    if (data['schemaVersion'] != 2 ||
        raw is! List ||
        raw.isEmpty ||
        raw.length > 128) {
      throw const FormatException('project_build_revision_inventory_invalid');
    }
    final revisions = raw
        .map(ProjectBuildV2RevisionDescriptor.fromJson)
        .toList();
    final ids = {for (final r in revisions) r.revisionId: r};
    final head = projectBuildV2Id(data['currentRevisionId'], 'revision');
    if (ids.length != revisions.length ||
        !ids.containsKey(head) ||
        revisions.map((r) => r.candidateDigest).toSet().length !=
            revisions.length) {
      throw const FormatException('project_build_revision_duplicate');
    }
    // Every saved node belongs to one bounded, acyclic rooted history. The
    // current pointer may name any node after a rollback; time is not authority.
    if (revisions.where((r) => r.baseRevision == null).length != 1) {
      throw const FormatException('project_build_revision_roots_invalid');
    }
    for (final node in revisions) {
      final visited = <String>{};
      String? cursor = node.revisionId;
      while (cursor != null) {
        final revision = ids[cursor];
        if (revision == null || !visited.add(cursor)) {
          throw const FormatException('project_build_revision_dag_invalid');
        }
        cursor = revision.baseRevision;
      }
    }
    return ProjectBuildV2OwnedRevisions._(
      projectBuildV2Id(data['projectId'], 'project'),
      head,
      _version(data['currentHeadVersion']),
      List.unmodifiable(revisions),
    );
  }
  bool contains(String revision) =>
      revisions.any((r) => r.revisionId == revision);

  /// Ancestry describes source history only, never the current-head authority.
  bool isAncestor(String ancestor, String descendant) {
    String? cursor = descendant;
    while (cursor != null) {
      if (cursor == ancestor) return contains(ancestor);
      final candidates = revisions.where((r) => r.revisionId == cursor);
      if (candidates.isEmpty) return false;
      cursor = candidates.single.baseRevision;
    }
    return false;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 2,
    'projectId': projectId,
    'currentRevisionId': currentRevisionId,
    'currentHeadVersion': currentHeadVersion,
    'revisions': revisions.map((r) => r.toJson()).toList(),
  };
}

Map<String, Object?> _fields(Object? value, Set<String> keys) {
  final data = projectBuildV2Object(value);
  if (data.length != keys.length || !data.keys.every(keys.contains)) {
    throw const FormatException('project_build_inventory_fields');
  }
  return data;
}

String _digest(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('project_build_inventory_digest');
  }
  return value;
}

DateTime _time(Object? value) {
  if (value is! String || !value.endsWith('Z')) {
    throw const FormatException('project_build_inventory_time');
  }
  return DateTime.parse(value).toUtc();
}

int _version(Object? value) {
  if (value is! int || value < 1 || value > projectBuildV2MaximumSequence) {
    throw const FormatException('project_build_head_version');
  }
  return value;
}
