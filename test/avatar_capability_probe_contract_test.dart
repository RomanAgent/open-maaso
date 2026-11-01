import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
    'AvatarCapabilityProbe.cs',
  ).readAsStringSync();
  final receiverSource = File(
    'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
    'UnityAvatarCommandReceiver.cs',
  ).readAsStringSync();

  group('Avatar capability probe source contract', () {
    test('uses the exact finite public issue-code vocabulary', () {
      final issueCodeSection = _between(
        source,
        'public static class AvatarCapabilityIssueCodes',
        'internal static class AvatarCapabilitySeverities',
      );
      final codes = RegExp(
        r'public const string \w+ = "([a-z0-9_]+)";',
      ).allMatches(issueCodeSection).map((match) => match.group(1)).toSet();

      expect(
        codes,
        equals(<String>{
          'missing_humanoid',
          'missing_renderable',
          'missing_head',
          'missing_left_eye',
          'missing_right_eye',
          'missing_look_at',
          'missing_lip_sync',
          'missing_blink',
          'missing_expressions',
          'high_vertex_count',
          'high_material_count',
          'high_texture_memory',
        }),
      );
      expect(codes.length, lessThanOrEqualTo(16));
      expect(source, contains('issues.Count >= MaximumIssues'));
      expect(
        source,
        contains('AvatarCapabilityIssueCodes.TryGetSeverity(code'),
      );
      expect(source, contains('MaximumSerializedBytes = 8 * 1024'));
      expect(source, contains('Encoding.UTF8.GetByteCount(json)'));
    });

    test('profile shape is strict, shallow, serializable, and bounded', () {
      for (final type in <String>[
        'AvatarCapabilityIssue',
        'AvatarCapabilityRig',
        'AvatarCapabilityBehavior',
        'AvatarCapabilityRenderMetrics',
        'AvatarCapabilityProfile',
      ]) {
        expect(
          source,
          contains('[Serializable]\n    public sealed class $type'),
        );
      }

      for (final field in <String>[
        'schemaVersion',
        'source',
        'state',
        'rig',
        'behavior',
        'render',
        'issues',
        'humanoid',
        'head',
        'leftEye',
        'rightEye',
        'lookAt',
        'lipSync',
        'blink',
        'expressions',
        'renderable',
        'rendererCount',
        'skinnedMeshCount',
        'vertexCount',
        'triangleCount',
        'materialCount',
        'textureCount',
        'maxTextureSize',
        'estimatedTextureBytes',
      ]) {
        expect(
          source,
          contains(RegExp(r'\[SerializeField\] private \w+(?:\[\])? ' + field)),
          reason: field,
        );
      }

      expect(source, contains('MaximumRendererCount = 4096'));
      expect(source, contains('MaximumSkinnedMeshCount = 2048'));
      expect(source, contains('MaximumVertexCount = 10 * 1000 * 1000'));
      expect(source, contains('MaximumTriangleCount = 20 * 1000 * 1000'));
      expect(source, contains('MaximumMaterialCount = 8192'));
      expect(source, contains('MaximumTextureCount = 8192'));
      expect(source, contains('MaximumTextureSize = 16384'));
      expect(
        source,
        contains('MaximumEstimatedTextureBytes = 2L * 1024 * 1024 * 1024'),
      );
    });

    test('exposes an explicit pre-activation integration seam', () {
      expect(source, contains('"probe_candidate_before_activation"'));
      expect(
        source,
        contains(
          'public static AvatarCapabilityProfile ProbeCandidate('
          'GameObject candidateRoot)',
        ),
      );
      expect(source, contains('public static AvatarCapabilityProfile Probe('));
      expect(source, contains('Vrm10Instance vrm = null'));
      expect(source, contains('public bool HasBlockers =>'));
      expect(source, contains('public static bool BlocksActivation('));
      final blockingPolicy = _between(
        source,
        'public static bool BlocksActivation(',
        'public static string ToJson(',
      );
      expect(
        blockingPolicy,
        contains('profile != null && profile.HasBlockingIssues'),
      );
      expect(source, isNot(contains('ActivateLoadedAvatarReplacement(')));
    });

    test(
      'probes candidates before atomic activation and returns the profile',
      () {
        final bundleLoad = _between(
          receiverSource,
          'private IEnumerator LoadReviewedAvatarBundle(',
          'private AvatarCapabilityProfile ActivateAvatarReplacement(',
        );
        expect(bundleLoad, contains('out bool capabilityBlocked'));
        expect(bundleLoad, contains('"capability_incompatible"'));
        expect(bundleLoad, contains('capabilityProfile);'));

        final bundleActivation = _between(
          receiverSource,
          'private AvatarCapabilityProfile ActivateAvatarReplacement(',
          'private IEnumerator LoadReviewedVrmAvatar(',
        );
        expect(
          bundleActivation.indexOf('AvatarCapabilityProbe.ProbeCandidate('),
          lessThan(
            bundleActivation.indexOf('ActivateLoadedAvatarReplacement('),
          ),
        );
        expect(
          bundleActivation.indexOf('AvatarCapabilityProbe.BlocksActivation('),
          lessThan(
            bundleActivation.indexOf('ActivateLoadedAvatarReplacement('),
          ),
        );

        final vrmLoad = _between(
          receiverSource,
          'private IEnumerator LoadReviewedVrmAvatar(',
          'private void ActivateLoadedAvatarReplacement(',
        );
        expect(
          vrmLoad.indexOf('AvatarCapabilityProbe.Probe(vrm.gameObject, vrm)'),
          lessThan(vrmLoad.indexOf('ActivateLoadedAvatarReplacement(')),
        );
        expect(vrmLoad, contains('"capability_incompatible"'));

        final activation = _between(
          receiverSource,
          'private void ActivateLoadedAvatarReplacement(',
          'private bool RestoreBundledAvatar(',
        );
        expect(
          activation.indexOf('BindAvatarRoot(replacement.transform);'),
          lessThan(activation.indexOf('reviewedAvatarInstance = replacement;')),
        );
        expect(
          activation,
          contains('reviewedAvatarInstance = previousReviewed;'),
        );
        expect(activation, contains('BindAvatarRoot(previousRoot);'));

        final resultShape = _between(
          receiverSource,
          'private sealed class AvatarLoadResult',
          '[Serializable]\n        private sealed class LiveCoverCommand',
        );
        expect(
          resultShape,
          contains('public AvatarCapabilityProfile capabilityProfile;'),
        );
      },
    );

    test('never serializes raw model identifiers or diagnostic prose', () {
      final issueShape = _between(
        source,
        'public sealed class AvatarCapabilityIssue',
        '[Serializable]\n    public sealed class AvatarCapabilityRig',
      );
      expect(issueShape, contains('[SerializeField] private string code;'));
      expect(issueShape, contains('[SerializeField] private string severity;'));

      for (final forbidden in <String>[
        'message;',
        'boneName',
        'transformName',
        'rendererName',
        'materialName',
        'textureName',
        'assetPath',
        'modelPath',
        'sourcePath',
        'Exception.Message',
        'StackTrace',
        'System.IO',
        'File.',
        'Directory.',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}

String _between(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: startMarker);
  expect(end, greaterThan(start), reason: endMarker);
  return source.substring(start, end);
}
