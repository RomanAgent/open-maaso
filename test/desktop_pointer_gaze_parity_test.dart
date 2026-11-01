import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS and Windows pointer gaze share signed screen directions', () {
    final macOS = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final windows = File(
      'windows/runner/windows_desktop_companion_host.cpp',
    ).readAsStringSync();

    // Horizontal screen coordinates grow to the right on both platforms.
    // Therefore a cursor left of the avatar produces a negative value, while
    // one to the right produces a positive value.
    expect(macOS, contains('(mouse.x - headAnchor.x) / 220.0 / gazeScale'));
    expect(windows, contains('(cursor.x - head_x) / Scale(220)'));

    // AppKit screen Y grows upward while Win32 screen Y grows downward. These
    // formulas normalize both to positive=up and negative=down.
    expect(macOS, contains('(mouse.y - headAnchor.y) / 170.0 / gazeScale'));
    expect(windows, contains('(head_y - cursor.y) / Scale(170)'));

    expect(macOS, contains('.clamped(to: -1.0 ... 1.0)'));
    expect(windows, contains('ClampUnit((cursor.x - head_x) / Scale(220))'));
    expect(windows, contains('ClampUnit((head_y - cursor.y) / Scale(170))'));
  });

  test('pointer gaze fades to center within the reduced distance band', () {
    final macOS = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final windows = File(
      'windows/runner/windows_desktop_companion_host.cpp',
    ).readAsStringSync();

    final macOSGaze = macOS.substring(
      macOS.indexOf('private func updateGaze()'),
      macOS.indexOf('private func updateMousePassthrough()'),
    );
    final windowsGaze = windows.substring(
      windows.indexOf('void WindowsDesktopCompanionHost::UpdateGaze()'),
      windows.indexOf('void WindowsDesktopCompanionHost::ClearGaze()'),
    );

    // Sampling stays global, and distance is measured from the visible avatar
    // bounds so the character's feet still count as nearby.
    expect(macOSGaze, contains('NSEvent.mouseLocation'));
    expect(windowsGaze, contains('::GetCursorPos(&cursor)'));
    expect(macOS, contains('RunLoop.main.add(timer, forMode: .common)'));
    expect(
      windows,
      contains('if (wparam == kGazeTimerId) {\n        UpdateGaze();'),
    );
    expect(
      macOSGaze,
      contains('petContentView.avatarInteractionRect.offsetBy('),
    );
    expect(windowsGaze, contains('const RECT avatar = AvatarBounds();'));
    expect(
      macOSGaze,
      contains('let outsideDistance = hypot(outsideX, outsideY)'),
    );
    expect(
      windowsGaze,
      contains('const double outside_distance = std::hypot('),
    );

    // Both thresholds are 25% closer than the original 96/240 band. Keep the
    // same smooth falloff and scale with the selected avatar size/DPI.
    expect(macOSGaze, contains('let fullAttentionDistance = 72.0 * gazeScale'));
    expect(macOSGaze, contains('let releaseDistance = 180.0 * gazeScale'));
    expect(
      windowsGaze,
      contains('const double full_attention_distance = Scale(72)'),
    );
    expect(windowsGaze, contains('const double release_distance = Scale(180)'));
    expect(macOSGaze, contains('(releaseDistance - outsideDistance)'));
    expect(macOSGaze, contains('/ (releaseDistance - fullAttentionDistance)'));
    expect(macOSGaze, contains(').clamped(to: 0 ... 1)'));
    expect(
      windowsGaze,
      contains('const double attention_weight = std::clamp('),
    );
    expect(windowsGaze, contains('(release_distance - outside_distance) /'));
    expect(
      windowsGaze,
      contains('(release_distance - full_attention_distance)'),
    );
    expect(macOSGaze, contains('x: trackedX * attentionWeight'));
    expect(macOSGaze, contains('y: trackedY * attentionWeight'));
    expect(
      windowsGaze,
      contains('const double next_x = tracked_x * attention_weight'),
    );
    expect(
      windowsGaze,
      contains('const double next_y = tracked_y * attention_weight'),
    );

    // Entering exact center bypasses the ordinary delta suppression once, so
    // the final tiny residual cannot leave the Avatar looking slightly aside.
    expect(macOSGaze, contains('(next.x == 0 && next.y == 0)'));
    expect(windowsGaze, contains('next_is_centered == last_is_centered'));
    expect(macOSGaze, contains('onGazeChanged(next)'));
    expect(windowsGaze, contains('flutter::EncodableValue("active")'));
    expect(windowsGaze, contains('flutter::EncodableValue(true)'));
  });

  test('desktop pointer payload drives eyes, head, and upper body', () {
    final macOS = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final windows = File(
      'windows/runner/windows_desktop_companion_host.cpp',
    ).readAsStringSync();
    final windowsUnityHost = File(
      'windows/runner/unity_player_host.cpp',
    ).readAsStringSync();
    final windowsFlutterHost = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();
    final shell = File(
      'lib/src/desktop/presentation/desktop_companion_shell.dart',
    ).readAsStringSync();
    final director = File(
      'lib/src/core/services/gaze_director.dart',
    ).readAsStringSync();
    final unityReceiver = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'UnityAvatarCommandReceiver.cs',
    ).readAsStringSync();

    for (final nativeHost in <String>[macOS, windows]) {
      expect(nativeHost, contains('"gazeChanged"'));
      expect(nativeHost, contains('"x"'));
      expect(nativeHost, contains('"y"'));
    }
    expect(windows, contains('SetPointerGaze(next_x, next_y)'));
    expect(windowsUnityHost, contains('WM_MOUSEMOVE'));

    expect(director, contains('eye: Offset('));
    expect(director, contains('head: Offset('));
    expect(director, contains('headRoll: 0'));
    expect(director, contains('eyeX: eyeX'));
    expect(director, contains('eyeY: eyeY'));
    expect(director, contains('headX: headX'));
    expect(director, contains('headY: headY'));
    expect(
      director,
      contains("final headY = (params['ParamAngleY'] ?? 0) / 30.0;"),
    );
    expect(
      director,
      contains("'ParamBodyAngleX': (g.upperBodyX ?? g.head.dx) * 10"),
    );
    expect(director, contains('_behavior ?? _desktopPointer ?? _face'));
    expect(shell, contains('setDesktopPointerGaze(gaze)'));
    expect(windowsFlutterHost, contains('"setMouthOpen",     "setGaze"'));

    // Unity consumes only the gaze selected by Dart's director. A local
    // per-frame mouse fallback would bypass the behavior lease and overwrite
    // intentional eye/head/body poses.
    expect(unityReceiver, contains('case "setGaze":'));
    expect(unityReceiver, contains('ApplyGaze(FromJson<GazeCommand>(json))'));
    expect(unityReceiver, isNot(contains('UnityEngine.InputSystem')));
    expect(unityReceiver, isNot(contains('Mouse.current')));
    expect(unityReceiver, isNot(contains('UpdateWindowsDesktopPointerGaze')));
  });

  test('Unity maps screen-right gaze and supports eyes without bones', () {
    final unityReceiver = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'UnityAvatarCommandReceiver.cs',
    ).readAsStringSync();

    // The front-facing Avatar maps positive screen X to negative Avatar-space
    // yaw. Applying the delta in Avatar space is essential because VRM humanoid
    // head bones are allowed to use a non-standard local basis.
    expect(
      unityReceiver,
      contains('private const float ScreenHorizontalToAvatarYaw = -1f;'),
    );
    expect(unityReceiver, contains('ApplyAvatarSpaceGazeToBone('));
    expect(
      unityReceiver,
      contains('ScreenHorizontalToAvatarYaw * ClampUnit(horizontal)'),
    );
    expect(unityReceiver, contains('VrmLookAtYawInput(currentGaze.eyeX)'));
    expect(
      unityReceiver,
      contains(
        'VrmLookAtPitchInput(ResolveHomeEyeContactVertical(currentGaze.eyeY))',
      ),
    );

    // ModularAnime exposes directional eye blend shapes but no eye bones.
    // Positive screen X means the front-facing character looks to its left.
    expect(
      unityReceiver,
      contains(
        'SetBlendShapeGroup(\n'
        '                EyeLookLeftBlendShapes,\n'
        '                Mathf.Max(0f, screenHorizontal) * 100f);',
      ),
    );
    expect(
      unityReceiver,
      contains(
        'SetBlendShapeGroup(\n'
        '                EyeLookRightBlendShapes,\n'
        '                Mathf.Max(0f, -screenHorizontal) * 100f);',
      ),
    );
    for (final blendShape in <String>[
      'eye_look_left.L',
      'eye_look_left.R',
      'eye_look_right.L',
      'eye_look_right.R',
      'eye_look_up.L',
      'eye_look_up.R',
      'eye_look_down.L',
      'eye_look_down.R',
    ]) {
      expect(unityReceiver, contains('"$blendShape"'));
    }
    expect(
      unityReceiver,
      contains('ApplyEyeBlendShapeGaze(currentGaze.eyeX, currentGaze.eyeY);'),
    );
    expect(unityReceiver, contains('ClearEyeBlendShapeGaze();'));
  });
}
