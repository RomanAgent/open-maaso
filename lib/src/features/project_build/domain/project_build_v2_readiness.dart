import 'project_build_v2_contract.dart';

/// Authenticated short-lived capability metadata. Network identifiers select
/// only locally trusted verification keys; this response carries no key bytes.
final class ProjectBuildV2Readiness {
  ProjectBuildV2Readiness._(
    this.enabled,
    this.workerReady,
    this.verifierKeyIds,
    this.runtime,
    this.productionIsolation,
  );
  final bool enabled, workerReady, productionIsolation;
  final String runtime;
  final List<String> verifierKeyIds;
  static const verificationProfile = 'maaso.project.verification.v2';
  String get profile => verificationProfile;
  factory ProjectBuildV2Readiness.fromJson(Object? value) {
    final data = projectBuildV2Object(value);
    const keys = {
      'schemaVersion',
      'enabled',
      'workerReady',
      'verifierKeyIds',
      'profile',
      'runtime',
      'productionIsolation',
    };
    final raw = data['verifierKeyIds'];
    if (data.length != keys.length ||
        !data.keys.every(keys.contains) ||
        data['schemaVersion'] != 2 ||
        data['enabled'] is! bool ||
        data['workerReady'] is! bool ||
        data['productionIsolation'] is! bool ||
        data['profile'] != verificationProfile ||
        !const {'runsc', 'runc'}.contains(data['runtime']) ||
        raw is! List ||
        raw.length > 16 ||
        raw.any(
          (id) => id is! String || !RegExp(r'^[\x21-\x7E]{1,80}$').hasMatch(id),
        ) ||
        raw.toSet().length != raw.length ||
        (data['productionIsolation'] == true && data['runtime'] != 'runsc') ||
        (data['enabled'] == false &&
            (data['workerReady'] == true || raw.isNotEmpty))) {
      throw const FormatException('project_build_readiness_invalid');
    }
    return ProjectBuildV2Readiness._(
      data['enabled']! as bool,
      data['workerReady']! as bool,
      List.unmodifiable(raw.cast<String>()),
      data['runtime']! as String,
      data['productionIsolation']! as bool,
    );
  }
  bool permitsCreation(
    Set<String> trustedKeyIds, {
    bool allowDevelopmentIsolation = false,
  }) =>
      enabled &&
      workerReady &&
      verifierKeyIds.any(trustedKeyIds.contains) &&
      (productionIsolation || allowDevelopmentIsolation);
  Map<String, Object?> toJson() => {
    'schemaVersion': 2,
    'enabled': enabled,
    'workerReady': workerReady,
    'verifierKeyIds': verifierKeyIds,
    'profile': profile,
    'runtime': runtime,
    'productionIsolation': productionIsolation,
  };
}
