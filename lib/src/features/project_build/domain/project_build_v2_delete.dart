import 'project_build_v2_contract.dart';

/// Created only after the native owner UI confirms the exact visible revision.
/// Recovery must keep this nonce/body, including after an acknowledgement loss.
final class ProjectBuildV2DeleteRequest {
  ProjectBuildV2DeleteRequest({
    required this.requestId,
    required this.expectedRevision,
    required this.expectedHeadVersion,
  }) {
    _requestId(requestId);
    _headVersion(
      expectedHeadVersion,
      maximum: projectBuildV2MaximumSequence - 1,
    );
    projectBuildV2Id(expectedRevision, 'revision');
  }
  final String requestId, expectedRevision;
  final int expectedHeadVersion;
  factory ProjectBuildV2DeleteRequest.fromJson(Object? value) {
    final data = _fields(value, {
      'requestId',
      'expectedRevision',
      'expectedHeadVersion',
    });
    return ProjectBuildV2DeleteRequest(
      requestId: data['requestId']! as String,
      expectedRevision: projectBuildV2Id(data['expectedRevision'], 'revision'),
      expectedHeadVersion: _headVersion(data['expectedHeadVersion']),
    );
  }
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'expectedRevision': expectedRevision,
    'expectedHeadVersion': expectedHeadVersion,
  };
}

final class ProjectBuildV2DeleteReceipt {
  ProjectBuildV2DeleteReceipt._(
    this.requestId,
    this.projectId,
    this.deletedRevisionId,
    this.deletedAt,
    this.headVersion,
  );
  final String requestId, projectId, deletedRevisionId;
  final DateTime deletedAt;
  final int headVersion;
  factory ProjectBuildV2DeleteReceipt.fromJson(Object? value) {
    final data = _fields(value, {
          'requestId',
          'projectId',
          'deletedRevisionId',
          'deletedAt',
          'headVersion',
        }),
        request = data['requestId'],
        at = data['deletedAt'];
    if (request is! String || at is! String || !at.endsWith('Z')) {
      throw const FormatException('project_delete_receipt_invalid');
    }
    _requestId(request);
    return ProjectBuildV2DeleteReceipt._(
      request,
      projectBuildV2Id(data['projectId'], 'project'),
      projectBuildV2Id(data['deletedRevisionId'], 'revision'),
      DateTime.parse(at).toUtc(),
      _headVersion(data['headVersion']),
    );
  }
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'projectId': projectId,
    'deletedRevisionId': deletedRevisionId,
    'deletedAt': deletedAt.toIso8601String(),
    'headVersion': headVersion,
  };
}

Map<String, Object?> _fields(Object? value, Set<String> keys) {
  final data = projectBuildV2Object(value);
  if (data.length != keys.length || !data.keys.every(keys.contains)) {
    throw const FormatException('project_delete_fields');
  }
  return data;
}

void _requestId(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(value)) {
    throw const FormatException('project_delete_request_id');
  }
}

int _headVersion(Object? value, {int maximum = projectBuildV2MaximumSequence}) {
  if (value is! int || value < 1 || value > maximum) {
    throw const FormatException('project_head_version');
  }
  return value;
}
