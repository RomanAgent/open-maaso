import 'dart:convert';

import 'package:cryptography/cryptography.dart' as signatures;

import 'project_bundle_v2.dart';
import 'project_json_canonicalizer.dart';

/// Closed native execution authority. JSON, bundle metadata and authored page
/// callbacks cannot construct trusted execution authority or extend this type.
sealed class ProjectBundleExecutionPermit {
  const ProjectBundleExecutionPermit._();
  String get candidateDigest;
  bool get isCurrent;
}

/// A live host capability created only by trusted-key signature verification.
/// It attests platform checks for this exact candidate, not account ownership,
/// gameplay authority, publication clearance or overall model quality.
final class VerifiedProjectBundlePermit extends ProjectBundleExecutionPermit {
  VerifiedProjectBundlePermit._({
    required this.candidateDigest,
    required this.reportDigest,
    required this.keyId,
    required this.productionIsolation,
    required bool Function() isCurrent,
  }) : _isCurrent = isCurrent,
       super._();
  @override
  final String candidateDigest;
  final String reportDigest;
  final String keyId;
  final bool productionIsolation;
  final bool Function() _isCurrent;
  @override
  bool get isCurrent {
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }
}

/// Keys are injected by the trusted account/bootstrap policy, never read from
/// a bundle, agent.md, a model reply, or the report being verified.
final class ProjectBundleVerificationService {
  ProjectBundleVerificationService({
    required Map<String, List<int>> trustedKeys,
    required bool Function() isCurrent,
    this.allowDevelopmentIsolation = false,
  }) : _trustedKeys = Map.unmodifiable({
         for (final entry in trustedKeys.entries)
           entry.key: List<int>.unmodifiable(entry.value),
       }),
       _isCurrent = isCurrent {
    for (final entry in _trustedKeys.entries) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(entry.key) ||
          entry.value.length != 32 ||
          entry.value.any((value) => value < 0 || value > 255)) {
        throw ArgumentError('invalid_project_verifier_key');
      }
    }
  }
  final Map<String, List<int>> _trustedKeys;
  final bool Function() _isCurrent;
  final bool allowDevelopmentIsolation;
  bool _sealed = false;
  static const _json = ProjectJsonCanonicalizer(maxBytes: 256 * 1024);

  bool get isCurrent => !_sealed && _isCurrent();
  void deactivate() => _sealed = true;

  Future<VerifiedProjectBundlePermit> verifyReport(
    ValidatedProjectBundleV2 bundle,
    Object? report, {
    String? expectedReportDigest,
  }) async {
    void guard() {
      if (!isCurrent) throw StateError('project_verifier_scope_changed');
    }

    guard();
    final raw = _json.parse(_json.canonicalize(report));
    final signed = _object(raw, {'payload', 'keyId', 'signature'});
    final keyId = signed['keyId'];
    final key = _trustedKeys[keyId];
    if (keyId is! String || key == null || signed['signature'] is! String) {
      throw const FormatException('untrusted_project_report');
    }
    final encodedSignature = signed['signature']! as String;
    final signature = base64Decode(encodedSignature);
    if (signature.length != 64 || base64Encode(signature) != encodedSignature) {
      throw const FormatException('invalid_project_report_signature');
    }
    final payload = _object(signed['payload'], {
      'schemaVersion',
      'profile',
      'candidateDigest',
      'projectId',
      'revisionId',
      'contentDigest',
      'artifactDigest',
      'runnerImageDigest',
      'runtime',
      'productionIsolation',
      'toolchainVersion',
      'createdAt',
      'checks',
      'screenshots',
      'environment',
      'elapsedMs',
      'scope',
      'requirementsQualityEvaluated',
    });
    final valid = await signatures.Ed25519().verify(
      _json.canonicalBytes(payload),
      signature: signatures.Signature(
        signature,
        publicKey: signatures.SimplePublicKey(
          key,
          type: signatures.KeyPairType.ed25519,
        ),
      ),
    );
    guard();
    if (!valid) throw const FormatException('invalid_project_report_signature');
    final manifest = bundle.manifest;
    if (payload['schemaVersion'] != 2 ||
        payload['profile'] != 'maaso.project.verification.v2' ||
        payload['candidateDigest'] != bundle.candidateDigest ||
        payload['projectId'] != manifest.projectId ||
        payload['revisionId'] != manifest.revisionId ||
        payload['contentDigest'] != manifest.contentDigest ||
        payload['artifactDigest'] != manifest.artifactDigest ||
        payload['toolchainVersion'] != projectBundleV2ToolchainVersion ||
        payload['scope'] != 'platform_and_project_self_tests' ||
        payload['requirementsQualityEvaluated'] is! bool ||
        payload['productionIsolation'] is! bool ||
        payload['runnerImageDigest'] is! String ||
        !RegExp(
          r'^sha256:[a-f0-9]{64}$',
        ).hasMatch(payload['runnerImageDigest']! as String) ||
        payload['createdAt'] is! String ||
        DateTime.tryParse(payload['createdAt']! as String) == null ||
        payload['elapsedMs'] is! int ||
        (payload['elapsedMs']! as int) < 0 ||
        (payload['elapsedMs']! as int) > 120000) {
      throw const FormatException('project_report_identity');
    }
    final production = payload['productionIsolation']! as bool;
    if (production
        ? payload['runtime'] != 'runsc'
        : !allowDevelopmentIsolation) {
      throw const FormatException('project_report_isolation_not_approved');
    }
    final environment = _object(payload['environment'], {
      'toolchainVersion',
      'node',
      'esbuild',
      'playwright',
    });
    if (environment['toolchainVersion'] != projectBundleV2ToolchainVersion ||
        environment['esbuild'] != '0.25.12' ||
        environment['playwright'] != '1.63.0' ||
        environment['node'] is! String) {
      throw const FormatException('project_report_environment');
    }
    final required = {
      'platform.compile',
      'platform.first_frame',
      'platform.offline',
      'platform.no_runtime_errors',
      for (final route in bundle.routes) 'platform.route.${route.routeId}',
      for (final file in manifest.files)
        if (file.role == ProjectBundleV2FileRole.asset)
          'platform.asset.${file.path}',
      if (manifest.projectKind == 'game') ...{
        'platform.game_rules',
        'platform.game_controls',
        if (bundle.protocol.rulesId == 'cooperative-dodge.v1') ...{
          'platform.realtime_controls',
          'platform.realtime_expiry',
          'platform.realtime_frames',
        },
      } else
        for (final action in bundle.protocol.actions)
          'platform.action.${action['id']}',
    };
    final checks = payload['checks'];
    if (checks is! List || checks.length > 300) {
      throw const FormatException('project_report_checks');
    }
    final seen = <String>{};
    for (final raw in checks) {
      final check = _object(raw, {'id', 'passed'});
      final id = check['id'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 300 ||
          !seen.add(id) ||
          check['passed'] != true) {
        throw const FormatException('project_report_check_failed');
      }
    }
    if (!required.every(seen.contains) ||
        !seen.any((id) => id.startsWith('project.self_test.'))) {
      throw const FormatException('project_report_missing_gate');
    }
    final screenshots = payload['screenshots'];
    if (screenshots is! List || screenshots.length != bundle.routes.length) {
      throw const FormatException('project_report_screenshots');
    }
    final routeIds = bundle.routes.map((route) => route.routeId).toSet();
    for (final raw in screenshots) {
      final shot = _object(raw, {
        'routeId',
        'sha256',
        'byteLength',
        'width',
        'height',
      });
      if (!routeIds.remove(shot['routeId']) ||
          shot['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(shot['sha256']! as String) ||
          ![
            shot['byteLength'],
            shot['width'],
            shot['height'],
          ].every((value) => value is int && value > 0) ||
          (shot['byteLength']! as int) > 2 * 1024 * 1024) {
        throw const FormatException('project_report_screenshot');
      }
    }
    final digest = projectBundleV2BytesDigest(_json.canonicalBytes(signed));
    if (expectedReportDigest != null && expectedReportDigest != digest) {
      throw const FormatException('project_report_digest_mismatch');
    }
    return VerifiedProjectBundlePermit._(
      candidateDigest: bundle.candidateDigest,
      reportDigest: digest,
      keyId: keyId,
      productionIsolation: production,
      isCurrent: () => isCurrent,
    );
  }
}

Map<String, Object?> _object(Object? value, Set<String> fields) {
  if (value is! Map ||
      value.length != fields.length ||
      value.keys.any((key) => key is! String || !fields.contains(key))) {
    throw const FormatException('invalid_project_report_fields');
  }
  return Map<String, Object?>.from(value);
}
