import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'project_build_v2_contract.dart';
import 'project_json_canonicalizer.dart';

/// Persisted audit identity, not an edit grant. Only a native EditTarget can
/// carry live issuer authority; this value merely records the original CAS.
final class ProjectBuildEditIdentity {
  ProjectBuildEditIdentity({
    required this.projectId,
    required this.baseRevision,
    required this.baseHeadVersion,
  }) {
    projectBuildV2Id(projectId, 'project');
    projectBuildV2Id(baseRevision, 'revision');
    if (baseHeadVersion < 1 || baseHeadVersion > 9007199254740991) {
      throw const FormatException('project_build_edit_identity');
    }
  }
  final String projectId, baseRevision;
  final int baseHeadVersion;
  String get digest => sha256
      .convert(
        utf8.encode(const ProjectJsonCanonicalizer().canonicalize(toJson())),
      )
      .toString();
  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'baseRevision': baseRevision,
    'baseHeadVersion': baseHeadVersion,
  };
  factory ProjectBuildEditIdentity.fromJson(Object? value) {
    final raw = projectBuildV2Object(value);
    if (raw.length != 3 ||
        !raw.keys.toSet().containsAll({
          'projectId',
          'baseRevision',
          'baseHeadVersion',
        }) ||
        raw['baseHeadVersion'] is! int) {
      throw const FormatException('project_build_edit_identity');
    }
    return ProjectBuildEditIdentity(
      projectId: projectBuildV2Id(raw['projectId'], 'project'),
      baseRevision: projectBuildV2Id(raw['baseRevision'], 'revision'),
      baseHeadVersion: raw['baseHeadVersion']! as int,
    );
  }
  static ProjectBuildEditIdentity? fromCreate(
    ProjectBuildV2CreateRequest input,
  ) => input.projectId == null
      ? null
      : ProjectBuildEditIdentity(
          projectId: input.projectId!,
          baseRevision: input.baseRevision!,
          baseHeadVersion: input.baseHeadVersion!,
        );
  @override
  bool operator ==(Object other) =>
      other is ProjectBuildEditIdentity &&
      projectId == other.projectId &&
      baseRevision == other.baseRevision &&
      baseHeadVersion == other.baseHeadVersion;
  @override
  int get hashCode => Object.hash(projectId, baseRevision, baseHeadVersion);
}
