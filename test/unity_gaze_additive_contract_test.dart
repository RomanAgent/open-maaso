import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
    'UnityAvatarCommandReceiver.cs',
  ).readAsStringSync();

  String section(String start, String end) {
    final startIndex = source.indexOf(start);
    final endIndex = source.indexOf(end, startIndex + start.length);
    expect(startIndex, greaterThanOrEqualTo(0), reason: 'Missing $start');
    expect(endIndex, greaterThan(startIndex), reason: 'Missing $end');
    return source.substring(startIndex, endIndex);
  }

  group('Unity additive gaze source contract', () {
    test('accepts and strictly clamps roll and upper-body inputs', () {
      final gazeCommand = section(
        'private sealed class GazeCommand',
        'private struct AppliedGazeBoneState',
      );

      expect(gazeCommand, contains('public float headRoll;'));
      expect(gazeCommand, contains('public float upperBodyX;'));
      for (final field in <String>[
        'eyeX',
        'eyeY',
        'headX',
        'headY',
        'headRoll',
        'upperBodyX',
      ]) {
        expect(gazeCommand, contains('$field = ClampUnit($field)'));
      }
    });

    test('applies arbitrated gaze and the Home eye center from LateUpdate', () {
      final lateUpdate = section(
        'private void LateUpdate()',
        'public void OnFlutterCommand(string payload)',
      );
      final applyGaze = section(
        'private void ApplyGaze(GazeCommand gaze)',
        'private void ClearGaze(bool immediate = false)',
      );

      expect(lateUpdate, contains('ApplyGazePose();'));
      expect(
        lateUpdate.indexOf('ApplyGazePose();'),
        greaterThan(lateUpdate.indexOf('UpdateIdlePose();')),
      );
      expect(
        applyGaze,
        contains('gazeTarget = (gaze ?? GazeCommand.Center).Clamped();'),
      );
      expect(lateUpdate, contains('UpdateGazeTransition(now);'));
      expect(lateUpdate, contains('ApplyHomeEyeContact();'));
      expect(applyGaze, isNot(contains('ApplyGazePose();')));
      expect(lateUpdate, isNot(contains('currentGaze =')));
      expect(lateUpdate, isNot(contains('gazeActive = true')));
      expect(source, isNot(contains('UnityEngine.InputSystem')));
      expect(source, isNot(contains('Mouse.current')));
      expect(source, isNot(contains('UpdateWindowsDesktopPointerGaze')));
      expect(source, isNot(contains('IsWindowsDesktopPetProcess')));
    });

    test('uses owned additive deltas without bind-pose overwrite', () {
      final applyBone = section(
        'private void ApplyGazeToBone(',
        'private Quaternion ReleaseOwnedGazeDelta(',
      );
      final releaseDelta = section(
        'private Quaternion ReleaseOwnedGazeDelta(',
        'private void RestoreOwnedGazePose()',
      );

      expect(applyBone, contains('ReleaseOwnedGazeDelta(bone)'));
      expect(applyBone, contains('animationRotation * delta'));
      expect(
        applyBone,
        contains('ScreenHorizontalToAvatarYaw * ClampUnit(horizontal)'),
      );
      expect(applyBone, contains('lastDelta = delta'));
      expect(applyBone, contains('lastResult = result'));
      expect(applyBone, isNot(contains('BaseRotation(')));
      expect(
        releaseDelta,
        contains('Quaternion.Angle(current, state.lastResult)'),
      );
      expect(
        releaseDelta,
        contains('current * Quaternion.Inverse(state.lastDelta)'),
      );
    });

    test('clear restores only owned deltas and action lowers body weight', () {
      final clearGaze = section(
        'private void ClearGaze(bool immediate = false)',
        'private void ApplyGazePose()',
      );
      final restorePose = section(
        'private void RestoreOwnedGazePose()',
        'private bool IsBodyActionHeld()',
      );
      final applyPose = section(
        'private void ApplyGazePose()',
        'private bool HasHomeEyeContactPresentation()',
      );
      final idleWeight = double.parse(
        RegExp(
          r'UpperBodyGazeIdleWeight = ([0-9.]+)f',
        ).firstMatch(source)!.group(1)!,
      );
      final actionWeight = double.parse(
        RegExp(
          r'UpperBodyGazeActionWeight = ([0-9.]+)f',
        ).firstMatch(source)!.group(1)!,
      );

      expect(clearGaze, contains('RestoreOwnedGazePose();'));
      expect(
        restorePose,
        contains('ReleaseOwnedGazeDelta(trackedBones[index])'),
      );
      expect(actionWeight, lessThan(idleWeight));
      expect(applyPose, contains('IsBodyActionHeld()'));
      expect(applyPose, contains('currentGaze.upperBodyX'));
      expect(applyPose, contains('currentGaze.headRoll'));
      expect(source, contains('private Transform FindUpperBodyBone()'));
      expect(source, contains('private void ApplyEyeBlendShapeGaze('));
      expect(source, contains('"eye_look_left.L"'));
      expect(source, contains('"eye_look_right.R"'));
      expect(source, contains('ClearEyeBlendShapeGaze();'));
      expect(source, contains('if (bone == null)'));
    });

    test(
      'Home eye contact uses one VRM owner and respects presentation gates',
      () {
        final gate = section(
          'private bool HasHomeEyeContactPresentation()',
          'private float ResolveHomeEyeContactVertical(',
        );
        final center = section(
          'private float ResolveHomeEyeContactVertical(',
          'private float VrmLookAtYawInput(',
        );
        final applyPose = section(
          'private void ApplyGazePose()',
          'private bool HasHomeEyeContactPresentation()',
        );
        for (final field in <String>[
          'avatarLeasedToWorld',
          'worldLocomotionActive',
          'phoneInteraction?.OwnsHands',
          'presenceTransition?.OwnsPresentation',
          'liveComposition?.IsBackgroundActive',
          '!localVisibility.Visible',
          '!framing.isActiveAndEnabled',
          'framing.TargetRoot != avatarRoot',
          'camera.orthographic',
          'camera.backgroundColor.a',
          'camera.cullingMask',
        ]) {
          expect(gate, contains(field), reason: field);
        }
        expect(
          applyPose,
          contains('ResolveHomeEyeContactVertical(currentGaze.eyeY)'),
        );
        expect(
          center,
          contains(
            'clamped + HomeEyeContactVerticalBias * (1f - Mathf.Abs(clamped))',
          ),
        );
        expect(center, contains('SetYawPitchManually('));
        expect(center, isNot(contains('localRotation')));
        expect(center, isNot(contains('currentGaze =')));
        expect(center, isNot(contains('headX')));
        expect(center, isNot(contains('headY')));
      },
    );
  });
}
