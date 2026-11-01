import 'dart:convert';

import 'package:maaso/src/core/services/avatar_config_service.dart';

import 'avatar_runtime.dart';

/// A bounded, renderer-neutral description of what an Avatar can actually do.
///
/// Catalog data is advisory. Unity probes the loaded candidate and returns the
/// authoritative profile before the candidate is allowed to replace the
/// current Avatar.
enum AvatarCapabilityState {
  supported('supported'),
  degraded('degraded'),
  unknown('unknown'),
  incompatible('incompatible');

  const AvatarCapabilityState(this.wireName);

  final String wireName;

  static AvatarCapabilityState parse(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return values.firstWhere(
      (item) => item.wireName == normalized,
      orElse: () =>
          throw StateError('Avatar capability profile has an invalid state'),
    );
  }
}

enum AvatarCapabilitySource {
  legacy('legacy'),
  catalog('catalog'),
  unity('unity');

  const AvatarCapabilitySource(this.wireName);

  final String wireName;

  static AvatarCapabilitySource parse(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return values.firstWhere(
      (item) => item.wireName == normalized,
      orElse: () =>
          throw StateError('Avatar capability profile has an invalid source'),
    );
  }
}

enum AvatarCapabilityIssueSeverity {
  warning('warning'),
  blocker('blocker');

  const AvatarCapabilityIssueSeverity(this.wireName);

  final String wireName;
}

/// Public issue codes are deliberately finite. Raw Unity node names, paths,
/// scanner output, and exception text must never become UI or prompt data.
enum AvatarCapabilityIssueCode {
  missingHumanoid('missing_humanoid', AvatarCapabilityIssueSeverity.blocker),
  missingRenderable(
    'missing_renderable',
    AvatarCapabilityIssueSeverity.blocker,
  ),
  missingHead('missing_head', AvatarCapabilityIssueSeverity.blocker),
  missingLeftEye('missing_left_eye', AvatarCapabilityIssueSeverity.warning),
  missingRightEye('missing_right_eye', AvatarCapabilityIssueSeverity.warning),
  missingLookAt('missing_look_at', AvatarCapabilityIssueSeverity.warning),
  missingLipSync('missing_lip_sync', AvatarCapabilityIssueSeverity.warning),
  missingBlink('missing_blink', AvatarCapabilityIssueSeverity.warning),
  missingExpressions(
    'missing_expressions',
    AvatarCapabilityIssueSeverity.warning,
  ),
  highVertexCount('high_vertex_count', AvatarCapabilityIssueSeverity.warning),
  highMaterialCount(
    'high_material_count',
    AvatarCapabilityIssueSeverity.warning,
  ),
  highTextureMemory(
    'high_texture_memory',
    AvatarCapabilityIssueSeverity.warning,
  );

  const AvatarCapabilityIssueCode(this.wireName, this.severity);

  final String wireName;
  final AvatarCapabilityIssueSeverity severity;

  static AvatarCapabilityIssueCode parse(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return values.firstWhere(
      (item) => item.wireName == normalized,
      orElse: () => throw StateError(
        'Avatar capability profile has an invalid issue code',
      ),
    );
  }
}

class AvatarCapabilityIssue {
  const AvatarCapabilityIssue(this.code);

  final AvatarCapabilityIssueCode code;

  AvatarCapabilityIssueSeverity get severity => code.severity;

  factory AvatarCapabilityIssue.fromJson(Object? value) {
    final json = _strictObject(value, 'issue');
    _assertOnlyKeys(json, const {'code', 'severity'}, 'issue');
    final code = AvatarCapabilityIssueCode.parse(json['code']);
    final severity = json['severity']?.toString().trim().toLowerCase();
    if (severity != code.severity.wireName) {
      throw StateError(
        'Avatar capability profile has an invalid issue severity',
      );
    }
    return AvatarCapabilityIssue(code);
  }

  Map<String, Object> toJson() => {
    'code': code.wireName,
    'severity': severity.wireName,
  };
}

class AvatarCapabilityProfile {
  const AvatarCapabilityProfile._({
    required this.schemaVersion,
    required this.source,
    required this.state,
    required this.humanoid,
    required this.renderable,
    required this.head,
    required this.leftEye,
    required this.rightEye,
    required this.lookAt,
    required this.lipSync,
    required this.blink,
    required this.expressions,
    required this.rendererCount,
    required this.skinnedMeshCount,
    required this.vertexCount,
    required this.triangleCount,
    required this.materialCount,
    required this.textureCount,
    required this.maxTextureSize,
    required this.estimatedTextureBytes,
    required this.issues,
  });

  static const currentSchemaVersion = 1;
  static const maximumEncodedBytes = 8 * 1024;
  static const maximumIssueCount = 16;

  static const unknown = AvatarCapabilityProfile._(
    schemaVersion: currentSchemaVersion,
    source: AvatarCapabilitySource.legacy,
    state: AvatarCapabilityState.unknown,
    humanoid: null,
    renderable: null,
    head: null,
    leftEye: null,
    rightEye: null,
    lookAt: null,
    lipSync: null,
    blink: null,
    expressions: null,
    rendererCount: null,
    skinnedMeshCount: null,
    vertexCount: null,
    triangleCount: null,
    materialCount: null,
    textureCount: null,
    maxTextureSize: null,
    estimatedTextureBytes: null,
    issues: <AvatarCapabilityIssue>[],
  );

  final int schemaVersion;
  final AvatarCapabilitySource source;
  final AvatarCapabilityState state;
  final bool? humanoid;
  final bool? renderable;
  final bool? head;
  final bool? leftEye;
  final bool? rightEye;
  final bool? lookAt;
  final bool? lipSync;
  final bool? blink;
  final bool? expressions;
  final int? rendererCount;
  final int? skinnedMeshCount;
  final int? vertexCount;
  final int? triangleCount;
  final int? materialCount;
  final int? textureCount;
  final int? maxTextureSize;
  final int? estimatedTextureBytes;
  final List<AvatarCapabilityIssue> issues;

  bool get isDeclared => source != AvatarCapabilitySource.legacy;

  bool get hasBlockers =>
      state == AvatarCapabilityState.incompatible ||
      issues.any(
        (issue) => issue.severity == AvatarCapabilityIssueSeverity.blocker,
      );

  AvatarCapabilityIssue? get primaryIssue {
    for (final issue in issues) {
      if (issue.severity == AvatarCapabilityIssueSeverity.blocker) return issue;
    }
    return issues.isEmpty ? null : issues.first;
  }

  factory AvatarCapabilityProfile.fromJson(Object? value) {
    if (value == null) return unknown;
    late final int encodedBytes;
    try {
      encodedBytes = utf8.encode(jsonEncode(value)).length;
    } on Object {
      throw StateError('Avatar capability profile is not valid JSON');
    }
    if (encodedBytes > maximumEncodedBytes) {
      throw StateError('Avatar capability profile is too large');
    }

    final json = _strictObject(value, 'profile');
    _assertOnlyKeys(json, const {
      'schemaVersion',
      'source',
      'state',
      'rig',
      'behavior',
      'render',
      'issues',
    }, 'profile');
    final schemaVersion = _requiredBoundedInt(
      json,
      'schemaVersion',
      minimum: currentSchemaVersion,
      maximum: currentSchemaVersion,
    );
    final source = AvatarCapabilitySource.parse(json['source']);
    final declaredState = AvatarCapabilityState.parse(json['state']);
    final rig = _strictObject(json['rig'], 'rig');
    _assertOnlyKeys(rig, const {
      'humanoid',
      'head',
      'leftEye',
      'rightEye',
    }, 'rig');
    final behavior = _strictObject(json['behavior'], 'behavior');
    _assertOnlyKeys(behavior, const {
      'lookAt',
      'lipSync',
      'blink',
      'expressions',
    }, 'behavior');
    final render = _strictObject(json['render'], 'render');
    _assertOnlyKeys(render, const {
      'renderable',
      'rendererCount',
      'skinnedMeshCount',
      'vertexCount',
      'triangleCount',
      'materialCount',
      'textureCount',
      'maxTextureSize',
      'estimatedTextureBytes',
    }, 'render');
    final rawIssues = json['issues'];
    if (rawIssues is! List || rawIssues.length > maximumIssueCount) {
      throw StateError('Avatar capability profile has invalid issues');
    }
    final issues = List<AvatarCapabilityIssue>.unmodifiable(
      rawIssues.map(AvatarCapabilityIssue.fromJson),
    );
    if (issues.map((issue) => issue.code).toSet().length != issues.length) {
      throw StateError('Avatar capability profile has duplicate issues');
    }

    final profile = AvatarCapabilityProfile._(
      schemaVersion: schemaVersion,
      source: source,
      state: declaredState,
      humanoid: _optionalBool(rig, 'humanoid'),
      renderable: _optionalBool(render, 'renderable'),
      head: _optionalBool(rig, 'head'),
      leftEye: _optionalBool(rig, 'leftEye'),
      rightEye: _optionalBool(rig, 'rightEye'),
      lookAt: _optionalBool(behavior, 'lookAt'),
      lipSync: _optionalBool(behavior, 'lipSync'),
      blink: _optionalBool(behavior, 'blink'),
      expressions: _optionalBool(behavior, 'expressions'),
      rendererCount: _optionalBoundedInt(
        render,
        'rendererCount',
        maximum: 4096,
      ),
      skinnedMeshCount: _optionalBoundedInt(
        render,
        'skinnedMeshCount',
        maximum: 2048,
      ),
      vertexCount: _optionalBoundedInt(
        render,
        'vertexCount',
        maximum: 10 * 1000 * 1000,
      ),
      triangleCount: _optionalBoundedInt(
        render,
        'triangleCount',
        maximum: 20 * 1000 * 1000,
      ),
      materialCount: _optionalBoundedInt(
        render,
        'materialCount',
        maximum: 8192,
      ),
      textureCount: _optionalBoundedInt(render, 'textureCount', maximum: 8192),
      maxTextureSize: _optionalBoundedInt(
        render,
        'maxTextureSize',
        maximum: 16384,
      ),
      estimatedTextureBytes: _optionalBoundedInt(
        render,
        'estimatedTextureBytes',
        maximum: 2 * 1024 * 1024 * 1024,
      ),
      issues: issues,
    );
    profile._validateConsistency();
    return profile;
  }

  void _validateConsistency() {
    if (source == AvatarCapabilitySource.legacy &&
        (<bool?>[
              humanoid,
              renderable,
              head,
              leftEye,
              rightEye,
              lookAt,
              lipSync,
              blink,
              expressions,
            ].any((value) => value != null) ||
            <int?>[
              rendererCount,
              skinnedMeshCount,
              vertexCount,
              triangleCount,
              materialCount,
              textureCount,
              maxTextureSize,
              estimatedTextureBytes,
            ].any((value) => value != null) ||
            issues.isNotEmpty)) {
      throw StateError(
        'Legacy Avatar capability profiles must use the canonical unknown shape',
      );
    }
    final derived = _deriveState(this);
    if (state != derived) {
      throw StateError('Avatar capability profile has an inconsistent state');
    }
    for (final issue in issues) {
      final missingValue = switch (issue.code) {
        AvatarCapabilityIssueCode.missingHumanoid => humanoid,
        AvatarCapabilityIssueCode.missingRenderable => renderable,
        AvatarCapabilityIssueCode.missingHead => head,
        AvatarCapabilityIssueCode.missingLeftEye => leftEye,
        AvatarCapabilityIssueCode.missingRightEye => rightEye,
        AvatarCapabilityIssueCode.missingLookAt => lookAt,
        AvatarCapabilityIssueCode.missingLipSync => lipSync,
        AvatarCapabilityIssueCode.missingBlink => blink,
        AvatarCapabilityIssueCode.missingExpressions => expressions,
        AvatarCapabilityIssueCode.highVertexCount ||
        AvatarCapabilityIssueCode.highMaterialCount ||
        AvatarCapabilityIssueCode.highTextureMemory => null,
      };
      if (missingValue == true) {
        throw StateError('Avatar capability profile has an inconsistent issue');
      }
    }
  }

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'source': source.wireName,
    'state': state.wireName,
    'rig': <String, Object>{
      'humanoid': ?humanoid,
      'head': ?head,
      'leftEye': ?leftEye,
      'rightEye': ?rightEye,
    },
    'behavior': <String, Object>{
      'lookAt': ?lookAt,
      'lipSync': ?lipSync,
      'blink': ?blink,
      'expressions': ?expressions,
    },
    'render': <String, Object>{
      'renderable': ?renderable,
      'rendererCount': ?rendererCount,
      'skinnedMeshCount': ?skinnedMeshCount,
      'vertexCount': ?vertexCount,
      'triangleCount': ?triangleCount,
      'materialCount': ?materialCount,
      'textureCount': ?textureCount,
      'maxTextureSize': ?maxTextureSize,
      'estimatedTextureBytes': ?estimatedTextureBytes,
    },
    'issues': issues.map((issue) => issue.toJson()).toList(growable: false),
  };
}

abstract interface class AvatarCapabilityRuntime {
  AvatarCapabilityProfile get activeCapabilityProfile;

  Stream<AvatarCapabilityProfile> get capabilityProfileChanges;
}

extension AvatarRuntimeCapabilityAccess on AvatarRuntime {
  AvatarCapabilityProfile get capabilityProfile =>
      this is AvatarCapabilityRuntime
      ? (this as AvatarCapabilityRuntime).activeCapabilityProfile
      : AvatarCapabilityProfile.unknown;

  Stream<AvatarCapabilityProfile> get capabilityProfiles =>
      this is AvatarCapabilityRuntime
      ? (this as AvatarCapabilityRuntime).capabilityProfileChanges
      : Stream<AvatarCapabilityProfile>.value(AvatarCapabilityProfile.unknown);
}

extension AvatarOptionCapabilityAccess on AvatarOption {
  AvatarCapabilityProfile get capabilityProfile =>
      AvatarCapabilityProfile.fromJson(config['capabilityProfile']);
}

AvatarCapabilityState _deriveState(AvatarCapabilityProfile profile) {
  if (profile.source == AvatarCapabilitySource.legacy) {
    return AvatarCapabilityState.unknown;
  }
  if (profile.issues.any(
        (issue) => issue.severity == AvatarCapabilityIssueSeverity.blocker,
      ) ||
      profile.humanoid == false ||
      profile.renderable == false ||
      profile.head == false) {
    return AvatarCapabilityState.incompatible;
  }
  if (profile.issues.isNotEmpty ||
      profile.leftEye == false ||
      profile.rightEye == false ||
      profile.lookAt == false ||
      profile.lipSync == false ||
      profile.blink == false ||
      profile.expressions == false) {
    return AvatarCapabilityState.degraded;
  }
  if (<bool?>[
    profile.humanoid,
    profile.renderable,
    profile.head,
    profile.leftEye,
    profile.rightEye,
    profile.lookAt,
    profile.lipSync,
    profile.blink,
    profile.expressions,
  ].any((value) => value == null)) {
    return AvatarCapabilityState.unknown;
  }
  return AvatarCapabilityState.supported;
}

Map<String, dynamic> _strictObject(Object? value, String name) {
  if (value is! Map) {
    throw StateError('Avatar capability profile has an invalid $name');
  }
  return Map<String, dynamic>.from(value);
}

void _assertOnlyKeys(
  Map<String, dynamic> value,
  Set<String> allowed,
  String name,
) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw StateError('Avatar capability profile has an invalid $name field');
  }
}

bool? _optionalBool(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) return null;
  final value = json[key];
  if (value is! bool) {
    throw StateError('Avatar capability profile has an invalid $key');
  }
  return value;
}

int _requiredBoundedInt(
  Map<String, dynamic> json,
  String key, {
  required int minimum,
  required int maximum,
}) {
  final value = json[key];
  if (value is! int || value < minimum || value > maximum) {
    throw StateError('Avatar capability profile has an invalid $key');
  }
  return value;
}

int? _optionalBoundedInt(
  Map<String, dynamic> json,
  String key, {
  int minimum = 0,
  required int maximum,
}) {
  if (!json.containsKey(key)) return null;
  final value = json[key];
  if (value is! int || value < minimum || value > maximum) {
    throw StateError('Avatar capability profile has an invalid $key');
  }
  return value;
}
