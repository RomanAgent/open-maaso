import 'dart:convert';
import 'project_json_canonicalizer.dart';

const projectBuildV2MaximumNodesPerAttempt = 120;

enum ProjectBuildV2NodeStatus { queued, running, succeeded, failed, cancelled }

enum ProjectBuildV2NodeKind { planning, generation, tool, validation, delivery }

/// Public step data from real platform/tool boundaries. Neither this data nor
/// agent.md grants a capability or exposes private model reasoning.
final class ProjectBuildV2Node {
  ProjectBuildV2Node._(
    this.nodeId,
    this.parentId,
    this.dependencyIds,
    this.revision,
    this.status,
    this.kind,
    this.title,
    this.summary,
    this.details,
    this.evidence,
  );
  final String nodeId, title, summary, details;
  final String? parentId;
  final List<String> dependencyIds;
  final int revision;
  final ProjectBuildV2NodeStatus status;
  final ProjectBuildV2NodeKind kind;
  final List<ProjectBuildV2NodeEvidence> evidence;
  bool get isTerminal => const {
    ProjectBuildV2NodeStatus.succeeded,
    ProjectBuildV2NodeStatus.failed,
    ProjectBuildV2NodeStatus.cancelled,
  }.contains(status);
  factory ProjectBuildV2Node.fromJson(Object? value) {
    final data = _fields(value, {
          'nodeId',
          'parentId',
          'dependencyIds',
          'revision',
          'status',
          'kind',
          'title',
          'summary',
          'details',
          'evidence',
        }),
        dependencies = data['dependencyIds'],
        evidence = data['evidence'];
    final id = _nodeId(data['nodeId']);
    if (dependencies is! List ||
        dependencies.length > 32 ||
        evidence is! List ||
        evidence.length > 8) {
      throw const FormatException('project_build_node_limits');
    }
    final ids = dependencies.map(_nodeId).toList();
    if (ids.toSet().length != ids.length || ids.contains(id)) {
      throw const FormatException('project_build_node_dependencies');
    }
    final parent = data['parentId'] == null ? null : _nodeId(data['parentId']);
    if (parent == id) {
      throw const FormatException('project_build_node_parent');
    }
    final node = ProjectBuildV2Node._(
      id,
      parent,
      List.unmodifiable(ids),
      _integer(data['revision'], 1, 9007199254740991),
      ProjectBuildV2NodeStatus.values.byName(data['status']! as String),
      ProjectBuildV2NodeKind.values.byName(data['kind']! as String),
      _text(data['title'], 120, nonempty: true),
      _text(data['summary'], 400),
      _text(data['details'], 2048),
      List.unmodifiable(evidence.map(ProjectBuildV2NodeEvidence.fromJson)),
    );
    if (utf8.encode(node.details).length > 8192) {
      throw const FormatException('project_build_node_details_limit');
    }
    const ProjectJsonCanonicalizer(
      maxBytes: 16384,
    ).canonicalBytes(node.toJson());
    return node;
  }
  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'parentId': parentId,
    'dependencyIds': dependencyIds,
    'revision': revision,
    'status': status.name,
    'kind': kind.name,
    'title': title,
    'summary': summary,
    'details': details,
    'evidence': evidence.map((e) => e.toJson()).toList(),
  };
  bool sameNode(ProjectBuildV2Node other) =>
      const ProjectJsonCanonicalizer(maxBytes: 16384).canonicalize(toJson()) ==
      const ProjectJsonCanonicalizer(
        maxBytes: 16384,
      ).canonicalize(other.toJson());
}

final class ProjectBuildV2NodeEvidence {
  ProjectBuildV2NodeEvidence._(
    this.kind,
    this.outcome,
    this.label,
    this.count,
    this.reference,
  );
  final String kind, outcome, label;
  final int? count;
  final String? reference;
  factory ProjectBuildV2NodeEvidence.fromJson(Object? value) {
    final data = _fields(
      value,
      {'kind', 'outcome', 'label'},
      optional: {'count', 'reference'},
    );
    if (!const {'execution', 'validation', 'artifact'}.contains(data['kind']) ||
        !const {
          'started',
          'passed',
          'failed',
          'completed',
        }.contains(data['outcome'])) {
      throw const FormatException('project_build_node_evidence');
    }
    final count = data.containsKey('count')
        ? _integer(data['count'], 0, 1000000)
        : null;
    final ref = data.containsKey('reference')
        ? _text(data['reference'], 160, nonempty: true)
        : null;
    if (ref != null &&
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$').hasMatch(ref)) {
      throw const FormatException('project_build_node_reference');
    }
    return ProjectBuildV2NodeEvidence._(
      data['kind']! as String,
      data['outcome']! as String,
      _text(data['label'], 120, nonempty: true),
      count,
      ref,
    );
  }
  Map<String, Object?> toJson() => {
    'kind': kind,
    'outcome': outcome,
    'label': label,
    if (count != null) 'count': count,
    if (reference != null) 'reference': reference,
  };
}

/// Applies one new revision. Journal duplicate handling happens before this
/// function; a new sequence cannot replay an old revision as a new step.
List<ProjectBuildV2Node> applyProjectBuildV2Node(
  List<ProjectBuildV2Node> previous,
  ProjectBuildV2Node node,
) {
  final index = previous.indexWhere((n) => n.nodeId == node.nodeId);
  if (index < 0) {
    if (previous.length >= projectBuildV2MaximumNodesPerAttempt ||
        node.revision != 1 ||
        node.status != ProjectBuildV2NodeStatus.queued) {
      throw StateError('project_build_node_initial_revision');
    }
    final ids = {for (final n in previous) n.nodeId: n};
    if (node.dependencyIds.any((id) => !ids.containsKey(id))) {
      throw StateError('project_build_node_unknown_dependency');
    }
    var parent = node.parentId, depth = 1;
    while (parent != null) {
      final known = ids[parent];
      if (known == null || ++depth > 8) {
        throw StateError('project_build_node_parent_depth');
      }
      parent = known.parentId;
    }
    return List.unmodifiable([...previous, node]);
  }
  final old = previous[index];
  if (node.revision != old.revision + 1 ||
      old.isTerminal ||
      node.parentId != old.parentId ||
      node.kind != old.kind ||
      node.title != old.title ||
      jsonEncode(node.dependencyIds) != jsonEncode(old.dependencyIds)) {
    throw StateError('project_build_node_revision_conflict');
  }
  final allowed = old.status == ProjectBuildV2NodeStatus.queued
      ? const {
          ProjectBuildV2NodeStatus.queued,
          ProjectBuildV2NodeStatus.running,
          ProjectBuildV2NodeStatus.failed,
          ProjectBuildV2NodeStatus.cancelled,
        }
      : const {
          ProjectBuildV2NodeStatus.running,
          ProjectBuildV2NodeStatus.succeeded,
          ProjectBuildV2NodeStatus.failed,
          ProjectBuildV2NodeStatus.cancelled,
        };
  if (!allowed.contains(node.status)) {
    throw StateError('project_build_node_transition');
  }
  return List.unmodifiable([
    ...previous.take(index),
    node,
    ...previous.skip(index + 1),
  ]);
}

Map<String, Object?> _fields(
  Object? value,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (value is! Map ||
      value.keys.any((key) => key is! String) ||
      !required.every(value.containsKey) ||
      value.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    throw const FormatException('project_build_node_fields');
  }
  return Map<String, Object?>.from(value);
}

String _nodeId(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(value)) {
    throw const FormatException('project_build_node_id');
  }
  return value;
}

String _text(Object? value, int limit, {bool nonempty = false}) {
  if (value is! String ||
      value.runes.length > limit ||
      (nonempty && value.trim().isEmpty) ||
      RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(value)) {
    throw const FormatException('project_build_node_text');
  }
  return value;
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('project_build_node_integer');
  }
  return value;
}

List<ProjectBuildV2Node> parseProjectBuildV2Nodes(Object? value) {
  if (value is! List || value.length > projectBuildV2MaximumNodesPerAttempt) {
    throw const FormatException('project_build_node_projection');
  }
  final nodes = value.map(ProjectBuildV2Node.fromJson).toList(),
      known = <String, ProjectBuildV2Node>{};
  for (final node in nodes) {
    if (known.containsKey(node.nodeId) ||
        node.dependencyIds.any((id) => !known.containsKey(id))) {
      throw const FormatException('project_build_node_projection_topology');
    }
    var parent = node.parentId, depth = 1;
    while (parent != null) {
      final ancestor = known[parent];
      if (ancestor == null || ++depth > 8) {
        throw const FormatException('project_build_node_projection_parent');
      }
      parent = ancestor.parentId;
    }
    known[node.nodeId] = node;
  }
  return List.unmodifiable(nodes);
}
