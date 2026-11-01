import 'project_build_v2_contract.dart';

/// Native owner confirmation captures a version, not a timestamp or a digest.
/// The exact nonce/body is retained until the server's outcome is known.
final class ProjectBuildV2RollbackRequest {
  ProjectBuildV2RollbackRequest({
    required this.requestId,
    required this.expectedHeadVersion,
    required this.targetRevision,
  }) {
    _nonce(requestId);
    _version(expectedHeadVersion, maximum: projectBuildV2MaximumSequence - 1);
    projectBuildV2Id(targetRevision, 'revision');
  }
  final String requestId, targetRevision;
  final int expectedHeadVersion;
  factory ProjectBuildV2RollbackRequest.fromJson(Object? value) {
    final d = _fields(value, {
      'requestId',
      'expectedHeadVersion',
      'targetRevision',
    });
    return ProjectBuildV2RollbackRequest(
      requestId: d['requestId']! as String,
      expectedHeadVersion: _version(d['expectedHeadVersion']),
      targetRevision: projectBuildV2Id(d['targetRevision'], 'revision'),
    );
  }
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'expectedHeadVersion': expectedHeadVersion,
    'targetRevision': targetRevision,
  };
}

final class ProjectBuildV2RollbackReceipt {
  ProjectBuildV2RollbackReceipt._(
    this.requestId,
    this.projectId,
    this.revisionId,
    this.headVersion,
    this.candidateDigest,
    this.reportDigest,
  );
  final String requestId, projectId, revisionId, candidateDigest, reportDigest;
  final int headVersion;
  factory ProjectBuildV2RollbackReceipt.fromJson(Object? value) {
    final d = _fields(value, {
      'requestId',
      'projectId',
      'revisionId',
      'headVersion',
      'candidateDigest',
      'reportDigest',
    });
    final nonce = d['requestId']! as String;
    _nonce(nonce);
    return ProjectBuildV2RollbackReceipt._(
      nonce,
      projectBuildV2Id(d['projectId'], 'project'),
      projectBuildV2Id(d['revisionId'], 'revision'),
      _version(d['headVersion']),
      _digest(d['candidateDigest']),
      _digest(d['reportDigest']),
    );
  }
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'projectId': projectId,
    'revisionId': revisionId,
    'headVersion': headVersion,
    'candidateDigest': candidateDigest,
    'reportDigest': reportDigest,
  };
}

Map<String, Object?> _fields(Object? value, Set<String> keys) {
  final d = projectBuildV2Object(value);
  if (d.length != keys.length || !d.keys.every(keys.contains)) {
    throw const FormatException('project_rollback_fields');
  }
  return d;
}

void _nonce(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(value)) {
    throw const FormatException('project_rollback_request');
  }
}

int _version(Object? value, {int maximum = projectBuildV2MaximumSequence}) {
  if (value is! int || value < 1 || value > maximum) {
    throw const FormatException('project_head_version');
  }
  return value;
}

String _digest(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('project_rollback_digest');
  }
  return value;
}
