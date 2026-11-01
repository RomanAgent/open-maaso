import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Unity portal captures the existing Avatar without CPU readback', () {
    final portal = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'CompanionPortalCaptureController.cs',
    ).readAsStringSync();

    expect(portal, contains('receiver.ActiveAvatarRoot'));
    expect(portal, contains('receiver.IsAvatarLeasedToWorld'));
    expect(portal, contains('RenderTextureFormat.ARGB32'));
    expect(portal, contains('new Color(0f, 0f, 0f, 0f)'));
    expect(portal, contains('GetNativeTexturePtr()'));
    expect(portal, contains('IssuePluginEventAndData'));
    expect(portal, contains('ReportState("unityAcquired"'));
    expect(portal, contains('ReportState("unityFrameRendered"'));
    expect(portal, contains('requestedGeneration == generation'));
    expect(portal, isNot(contains('Instantiate(')));
    expect(portal, isNot(contains('ReadPixels')));
    expect(portal, isNot(contains('EncodeToPNG')));
    expect(portal, isNot(contains('Convert.ToBase64String')));
  });

  test('macOS desktopHigh submits a stable high-resolution texture', () {
    final portal = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'CompanionPortalCaptureController.cs',
    ).readAsStringSync();

    expect(portal, contains('DesktopHighProfile = "desktopHigh"'));
    expect(portal, contains('width = 1024'));
    expect(portal, contains('height = 1792'));
    expect(
      portal,
      contains('requested == 24 || requested == 30 || requested == 60'),
    );
    expect(
      portal,
      contains('minimumFrameIntervalSeconds = 1f / framesPerSecond'),
    );
    expect(portal, contains('portalCamera.allowMSAA = false'));
    expect(portal, contains('antiAliasing = 1'));
    expect(portal, isNot(contains('ResolveAntiAliasedSurface(')));
    expect(portal, isNot(contains('bridgeTargetTexture')));
    expect(portal, isNot(contains('QualitySettings.antiAliasing')));
    expect(portal, isNot(contains('AsyncGPUReadback')));
  });

  test('macOS portal scopes soft lighting to every desktop capture lease', () {
    final portal = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'CompanionPortalCaptureController.cs',
    ).readAsStringSync();
    final acquire = portal.substring(
      portal.indexOf('public void Acquire('),
      portal.indexOf('public void Suspend('),
    );
    final release = portal.substring(
      portal.indexOf('public void Release('),
      portal.indexOf('private void LateUpdate()'),
    );

    expect(acquire, contains('#if UNITY_STANDALONE_OSX && !UNITY_EDITOR'));
    expect(acquire, contains('EnableCompanionLighting();'));
    expect(
      acquire.indexOf('EnableCompanionLighting();'),
      greaterThan(acquire.indexOf('Camera.onPostRender +=')),
    );
    expect(release, contains('DisableCompanionLighting();'));
    expect(release, contains('ExitCompanionLighting();'));
  });

  test('macOS sidecar carries an exact bounded FPS request to Unity', () {
    final swift = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final sidecar = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'DesktopUnitySidecarBridge.cs',
    ).readAsStringSync();

    expect(swift, contains('payload["targetFps"] = targetFps'));
    expect(swift, contains('guard [24, 30, 60].contains(targetFps)'));
    expect(sidecar, contains('"profile", "targetFps"'));
    expect(sidecar, contains('Rejected sidecar portal target FPS.'));
    expect(sidecar, contains('["targetFps"] = portal.TargetFps'));
    expect(swift, contains('includeWorld: Bool = false'));
    expect(swift, contains('payload["includeWorld"] = true'));
    expect(swift, contains('payload["viewportWidth"] = viewportWidth'));
    expect(swift, contains('payload["viewportHeight"] = viewportHeight'));
    expect(swift, contains('(64...3840).contains(viewportWidth)'));
    expect(swift, contains('(64...2160).contains(viewportHeight)'));
    expect(swift, contains('width > 0, width <= 3840'));
    expect(swift, contains('CFGetTypeID(number) == CFBooleanGetTypeID()'));
    expect(
      swift,
      contains('desktopCompanionBridge.setWorldCaptureActive(includeWorld)'),
    );
    expect(swift, contains('guard !worldCaptureActive else { return }'));
    expect(swift, contains('desktop_companion_world_capture_active'));
  });

  test(
    'iOS portal uses FlutterTexture and a color-normalizing Metal render pass',
    () {
      final bridge = File(
        'ios/Runner/LiveRtcAudioBridge.mm',
      ).readAsStringSync();
      final portalStart = bridge.indexOf(
        '@interface MaasoAvatarPortalTextureBridge',
      );
      final portalBridge = bridge.substring(portalStart);
      final unityBridge = File(
        'unity/masso_avatar/Assets/Plugins/iOS/MaasoLiveRtcBridge.mm',
      ).readAsStringSync();
      final appDelegate = File(
        'ios/Runner/AppDelegate.swift',
      ).readAsStringSync();
      final header = File(
        'ios/Runner/Runner-Bridging-Header.h',
      ).readAsStringSync();

      expect(portalBridge, contains('<FlutterTexture>'));
      expect(
        portalBridge,
        contains('methodChannelWithName:@"maaso/avatar_portal"'),
      );
      expect(portalBridge, contains('registerTexture:self'));
      expect(portalBridge, contains('if (self.textureId < 0)'));
      expect(portalBridge, contains('if (textureId >= 0)'));
      expect(
        portalBridge,
        contains('kCVPixelBufferPoolMinimumBufferCountKey : @3'),
      );
      expect(portalBridge, contains('kCVPixelBufferIOSurfacePropertiesKey'));
      expect(portalBridge, contains('kCVImageBufferCGColorSpaceKey'));
      expect(
        portalBridge,
        contains('kCVImageBufferColorPrimaries_ITU_R_709_2'),
      );
      expect(portalBridge, contains('kCVImageBufferTransferFunction_sRGB'));
      expect(portalBridge, contains('kCVAttachmentMode_ShouldPropagate'));
      expect(
        portalBridge,
        contains('CVMetalTextureCacheCreateTextureFromImage'),
      );
      expect(portalBridge, contains('MTLPixelFormatBGRA8Unorm_sRGB'));
      expect(portalBridge, contains('newRenderPipelineStateWithDescriptor'));
      expect(portalBridge, contains('renderCommandEncoderWithDescriptor'));
      expect(portalBridge, contains('source.read(uint2(input.position.xy))'));
      expect(portalBridge, isNot(contains('blitCommandEncoder')));
      expect(portalBridge, contains('MaasoAvatarPortalReportEventToFlutter'));
      expect(
        portalBridge,
        contains('textureFrameAvailable:strongSelf.textureId'),
      );
      expect(
        portalBridge,
        contains('[strongSelf generationMatches:generation]'),
      );
      expect(unityBridge, contains('GetUnityInterfaces()'));
      expect(unityBridge, isNot(contains('__attribute__((constructor))')));
      expect(unityBridge, isNot(contains('UnityRegisterRenderingPluginV5(')));
      expect(unityBridge, isNot(contains('UnityRegisterPlugin(')));
      expect(unityBridge, contains('metalInterfaceMissing'));
      expect(unityBridge, contains('metalCommandBufferMissing'));
      expect(header, contains('maaso_avatar_portal_register'));
      expect(appDelegate, contains('maaso_avatar_portal_register('));
      expect(bridge, isNot(contains('UIImagePNGRepresentation')));
      expect(bridge, isNot(contains('base64EncodedString')));
    },
  );

  test('Android portal uses SurfaceProducer and render-thread EGL blit', () {
    final bridge = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/'
      'AvatarPortalTextureBridge.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();
    final native = File(
      'android/app/src/main/cpp/live_rtc_audio_bridge.cpp',
    ).readAsStringSync();

    expect(bridge, contains('"maaso/avatar_portal"'));
    expect(bridge, contains('createSurfaceProducer('));
    expect(bridge, contains('TextureRegistry.SurfaceLifecycle.manual'));
    expect(bridge, contains('producer.scheduleFrame()'));
    expect(bridge, contains('frameGeneration != generation'));
    expect(bridge, contains('Class.forName("com.unity3d.player.UnityPlayer")'));
    expect(activity, contains('AvatarPortalTextureBridge(flutterEngine)'));
    expect(native, contains('eglGetCurrentContext()'));
    expect(native, contains('eglCreateWindowSurface'));
    expect(native, contains('glBlitFramebuffer'));
    expect(native, contains('MaasoAvatarPortalScheduleTexture'));
    expect(native, contains('frameAvailableNative'));
    expect(bridge, isNot(contains('UnityPlayer(')));
    expect(bridge, isNot(contains('Bitmap')));
    expect(bridge, isNot(contains('ByteArray')));
  });
}
