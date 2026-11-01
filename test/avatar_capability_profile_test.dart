import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

void main() {
  test('legacy descriptors remain loadable with an unknown profile', () {
    expect(
      AvatarCapabilityProfile.fromJson(null),
      same(AvatarCapabilityProfile.unknown),
    );
    const option = AvatarOption(
      id: 'legacy',
      name: 'Legacy',
      backend: AvatarBackendKind.unity,
      modelUrl: 'unity://legacy',
    );
    expect(option.capabilityProfile.state, AvatarCapabilityState.unknown);
    expect(option.capabilityProfile.hasBlockers, isFalse);
  });

  test('legacy wire profiles cannot conceal capabilities or blockers', () {
    expect(
      () => AvatarCapabilityProfile.fromJson({
        'schemaVersion': 1,
        'source': 'legacy',
        'state': 'unknown',
        'rig': {'humanoid': false},
        'behavior': <String, Object>{},
        'render': <String, Object>{},
        'issues': const [
          {'code': 'missing_humanoid', 'severity': 'blocker'},
        ],
      }),
      throwsStateError,
    );
  });

  test('round-trips a supported bounded profile', () {
    final profile = AvatarCapabilityProfile.fromJson(_profile());

    expect(profile.state, AvatarCapabilityState.supported);
    expect(profile.source, AvatarCapabilitySource.catalog);
    expect(profile.hasBlockers, isFalse);
    expect(profile.vertexCount, 72000);
    expect(
      AvatarCapabilityProfile.fromJson(profile.toJson()).toJson(),
      profile.toJson(),
    );
  });

  test('explains degraded and incompatible profiles with finite codes', () {
    final degraded = AvatarCapabilityProfile.fromJson(
      _profile(
        state: 'degraded',
        rightEye: false,
        issues: const [
          {'code': 'missing_right_eye', 'severity': 'warning'},
        ],
      ),
    );
    expect(degraded.state, AvatarCapabilityState.degraded);
    expect(
      degraded.primaryIssue?.code,
      AvatarCapabilityIssueCode.missingRightEye,
    );

    final incompatible = AvatarCapabilityProfile.fromJson(
      _profile(
        state: 'incompatible',
        humanoid: false,
        issues: const [
          {'code': 'missing_humanoid', 'severity': 'blocker'},
        ],
      ),
    );
    expect(incompatible.hasBlockers, isTrue);
    expect(
      incompatible.primaryIssue?.severity,
      AvatarCapabilityIssueSeverity.blocker,
    );
  });

  test('rejects unknown, duplicated, inconsistent, and oversized data', () {
    expect(
      () => AvatarCapabilityProfile.fromJson(
        _profile(
          state: 'degraded',
          issues: const [
            {'code': 'raw_unity_exception', 'severity': 'warning'},
          ],
        ),
      ),
      throwsStateError,
    );
    expect(
      () => AvatarCapabilityProfile.fromJson(
        _profile(
          state: 'degraded',
          rightEye: false,
          issues: const [
            {'code': 'missing_right_eye', 'severity': 'warning'},
            {'code': 'missing_right_eye', 'severity': 'warning'},
          ],
        ),
      ),
      throwsStateError,
    );
    expect(
      () => AvatarCapabilityProfile.fromJson(
        _profile(state: 'supported', humanoid: false),
      ),
      throwsStateError,
    );
    expect(
      () => AvatarCapabilityProfile.fromJson({
        ..._profile(),
        'padding': 'x' * AvatarCapabilityProfile.maximumEncodedBytes,
      }),
      throwsStateError,
    );
  });
}

Map<String, Object> _profile({
  String state = 'supported',
  bool humanoid = true,
  bool rightEye = true,
  List<Map<String, String>> issues = const [],
}) => {
  'schemaVersion': 1,
  'source': 'catalog',
  'state': state,
  'rig': {
    'humanoid': humanoid,
    'head': true,
    'leftEye': true,
    'rightEye': rightEye,
  },
  'behavior': {
    'lookAt': true,
    'lipSync': true,
    'blink': true,
    'expressions': true,
  },
  'render': {
    'renderable': true,
    'rendererCount': 3,
    'skinnedMeshCount': 2,
    'vertexCount': 72000,
    'triangleCount': 108000,
    'materialCount': 8,
    'textureCount': 10,
    'maxTextureSize': 2048,
    'estimatedTextureBytes': 32 * 1024 * 1024,
  },
  'issues': issues,
};
