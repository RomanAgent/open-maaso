import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = File(
    'windows/runner/windows_desktop_companion_host.cpp',
  ).readAsStringSync();
  final hostHeader = File(
    'windows/runner/windows_desktop_companion_host.h',
  ).readAsStringSync();
  final unityHost = File(
    'windows/runner/unity_player_host.cpp',
  ).readAsStringSync();
  final presentation = File(
    'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
    'WindowsDesktopPetPresentationController.cs',
  ).readAsStringSync();

  String section(String source, String start, String end) {
    final startIndex = source.indexOf(start);
    final endIndex = source.indexOf(end, startIndex + start.length);
    expect(startIndex, greaterThanOrEqualTo(0), reason: 'Missing $start');
    expect(endIndex, greaterThan(startIndex), reason: 'Missing $end');
    return source.substring(startIndex, endIndex);
  }

  test('Windows accepts exactly the four presentation size tiers', () {
    final configure = section(
      host,
      'void WindowsDesktopCompanionHost::ConfigurePresentation(',
      'void WindowsDesktopCompanionHost::ApplyPresentationGeometry()',
    );

    expect(host, contains('call.method_name() == "configurePresentation"'));
    expect(configure, contains('arguments.size() == 8'));
    for (final key in <String>[
      'version',
      'quality',
      'targetFps',
      'visualScale',
      'alwaysOnTop',
      'snapEnabled',
      'snapAcquireDistance',
      'snapReleaseDistance',
    ]) {
      expect(configure, contains('"$key"'));
    }
    expect(configure, contains('target_fps == 24'));
    expect(configure, contains('target_fps == 30'));
    expect(configure, contains('target_fps == 60'));
    expect(configure, contains('IsSupportedVisualScale(visual_scale)'));
    expect(configure, isNot(contains('visual_scale >= 0.6')));
    expect(configure, isNot(contains('visual_scale <= 2.0')));
    final supportedScales = section(
      host,
      'bool IsSupportedVisualScale(double value)',
      'int64_t BoundedTimestampMilliseconds()',
    );
    expect(
      supportedScales,
      contains(
        'constexpr std::array<double, 4> kSupportedScales{1.2, 1.8, 2.4, 3.0}',
      ),
    );
    expect(hostHeader, contains('presentation_visual_scale_ = 1.8'));
    expect(
      configure,
      contains('snap_release_distance >= snap_acquire_distance'),
    );
  });

  test('configuration precedes show and updates all native pet layers', () {
    final show = section(
      host,
      'bool WindowsDesktopCompanionHost::Show(',
      'void WindowsDesktopCompanionHost::Hide()',
    );
    final move = section(
      host,
      'void WindowsDesktopCompanionHost::MoveWindows(',
      'void WindowsDesktopCompanionHost::ResizeForDpi(',
    );
    final applyGeometry = section(
      host,
      'void WindowsDesktopCompanionHost::ApplyPresentationGeometry()',
      'bool WindowsDesktopCompanionHost::EnsureWindows(',
    );

    expect(
      show.indexOf('SetDesktopPetPresentationConfig('),
      lessThan(show.indexOf('pet_unity_player_host_->Start(')),
    );
    expect(host, contains('presentation_always_on_top_ ? HWND_TOPMOST'));
    expect(host, contains(': HWND_NOTOPMOST'));
    expect(
      RegExp(
        r'SetWindowPos\((pet|overlay|bubble)_window_, z_order',
      ).allMatches(move).length,
      3,
    );
    expect(host, contains('logical_pixels * dpi_scale *'));
    expect(host, contains('presentation_visual_scale_'));
    expect(applyGeometry, contains('const int width = Scale(300)'));
    expect(applyGeometry, contains('const int height = Scale(420)'));
    expect(applyGeometry, contains('RestoreSpatialPosition()'));
    expect(host, contains('OriginFromNormalized('));
  });

  test('Unity child starts with strict quality and FPS arguments', () {
    final setConfig = section(
      unityHost,
      'void UnityPlayerHost::SetDesktopPetPresentationConfig(',
      'bool UnityPlayerHost::Start(',
    );
    final start = section(
      unityHost,
      'bool UnityPlayerHost::Start(',
      'bool UnityPlayerHost::SendAvatarCommand(',
    );

    expect(setConfig, contains('quality != "eco"'));
    expect(setConfig, contains('quality != "balanced"'));
    expect(setConfig, contains('quality != "crisp"'));
    expect(setConfig, contains('target_fps != 24'));
    expect(setConfig, contains('target_fps != 30'));
    expect(setConfig, contains('target_fps != 60'));
    expect(
      setConfig,
      contains('SendAvatarCommandNow("desktopPet.configurePresentation"'),
    );
    expect(setConfig, contains('Stop();'));
    expect(start, contains('-maasoDesktopPetQuality'));
    expect(start, contains('-maasoDesktopPetFps'));
  });

  test('Unity capture exposes crisp balanced eco and 24 30 60 FPS', () {
    expect(presentation, contains('CrispCaptureSsaaScales'));
    expect(presentation, contains('{ 4f, 3f, 2f, 1f }'));
    expect(presentation, contains('CrispCaptureMsaaSamples = { 4, 2, 1 }'));
    expect(presentation, contains('BalancedCaptureSsaaScales = { 2f, 1f }'));
    expect(presentation, contains('BalancedCaptureMsaaSamples = { 2, 1 }'));
    expect(presentation, contains('EcoCaptureSsaaScales = { 1f }'));
    expect(presentation, contains('EcoCaptureMsaaSamples = { 1 }'));
    expect(presentation, contains('candidateFps == 24'));
    expect(presentation, contains('candidateFps == 30'));
    expect(presentation, contains('candidateFps == 60'));
    expect(presentation, contains('double nextInterval = 1.0 / targetFps'));
    expect(
      presentation,
      contains('foreach (float requestedScale in captureSsaaScales)'),
    );
    expect(
      presentation,
      contains('foreach (int requestedSamples in captureMsaaSamples)'),
    );
    expect(
      presentation,
      contains('captureEpoch = unchecked(captureEpoch + 1)'),
    );
    expect(presentation, contains('ReleaseCaptureTextures();'));
    final bridge = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'WindowsUnityAvatarMessageBridge.cs',
    ).readAsStringSync();
    expect(bridge, contains('DesktopPetPresentationMethod'));
    expect(bridge, contains('configuration.Count != 2'));
    expect(bridge, contains('controller?.ApplyPresentationConfig('));
  });

  test('Windows desktop-pet process enters and restores soft lighting', () {
    final awake = section(
      presentation,
      'private void Awake()',
      'private void Start()',
    );
    final start = section(
      presentation,
      'private void Start()',
      'private void EnableCompanionLighting()',
    );
    final destroy = section(
      presentation,
      'private void OnDestroy()',
      'private void ApplyAvatarLayer(',
    );

    expect(awake, isNot(contains('EnterCompanionLighting();')));
    expect(start, contains('EnableCompanionLighting();'));
    expect(presentation, contains('EnterCompanionLighting();'));
    expect(destroy, contains('DisableCompanionLighting();'));
    expect(presentation, contains('ExitCompanionLighting();'));
  });
}
