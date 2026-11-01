import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_command_dispatch_sink.dart';

void main() {
  final swiftBridge = File(
    'macos/Runner/MacOSUnityAvatarPortal.swift',
  ).readAsStringSync();
  final unityBridge = File(
    'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
    'DesktopUnitySidecarBridge.cs',
  ).readAsStringSync();
  final unityReceiver = File(
    'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
    'UnityAvatarCommandReceiver.cs',
  ).readAsStringSync();
  final agentSpaceController = File(
    'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
    'AgentSpaceController.cs',
  ).readAsStringSync();
  final surfacePlugin = File(
    'unity/masso_avatar/Assets/Plugins/macOS/'
    'MaasoDesktopAvatarPortalBridge.mm',
  ).readAsStringSync();
  final surfacePluginMeta = File(
    'unity/masso_avatar/Assets/Plugins/macOS/'
    'MaasoDesktopAvatarPortalBridge.mm.meta',
  ).readAsStringSync();
  final embedScript = File('macos/embed_unity_sidecar.sh').readAsStringSync();
  final macosProject = File(
    'macos/Runner.xcodeproj/project.pbxproj',
  ).readAsStringSync();
  final sidecarEntitlements = File(
    'macos/Runner/UnitySidecar.entitlements',
  ).readAsStringSync();
  final adHocSidecarEntitlements = File(
    'macos/Runner/UnitySidecarAdHoc.entitlements',
  ).readAsStringSync();
  final exporter = File(
    'unity/masso_avatar/Assets/MaasoAvatar/Editor/'
    'MaasoUnityLibraryExporter.cs',
  ).readAsStringSync();

  test('macOS launches only the fixed bundled Unity helper', () {
    expect(
      swiftBridge,
      contains('Contents/Helpers/MaasoAvatar.app/Contents/MacOS/MaasoAvatar'),
    );
    expect(swiftBridge, contains('child.executableURL = executable'));
    expect(swiftBridge, contains('MAASO_AVATAR_SESSION_TOKEN'));
    expect(swiftBridge, contains('MAASO_AVATAR_SOCKET_PATH'));
    expect(swiftBridge, contains('MAASO_AVATAR_PARENT_PID'));
    expect(swiftBridge, isNot(contains('/bin/sh')));
    expect(swiftBridge, isNot(contains('ProcessInfo.processInfo.arguments')));
  });

  test('Xcode tracks the embedded helper when signing the outer app', () {
    final phase = RegExp(
      r'/\* Embed Unity Avatar Sidecar \*/ = \{([\s\S]*?)\n\s*\};',
    ).firstMatch(macosProject);
    expect(phase, isNotNull);
    expect(
      RegExp(
        r'outputPaths = \(([\s\S]*?)\);',
      ).firstMatch(phase!.group(1)!)?.group(1),
      contains(
        r'$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/MaasoAvatar.app',
      ),
    );
  });

  test('sidecar IPC is local, per-launch authenticated, and bounded', () {
    expect(swiftBridge, contains('AF_UNIX'));
    expect(swiftBridge, contains('SecRandomCopyBytes'));
    expect(swiftBridge, contains('.posixPermissions: 0o700'));
    expect(swiftBridge, contains('chmod(socketPath, 0o600)'));
    expect(swiftBridge, contains('64 * 1024'));
    expect(unityBridge, contains('AddressFamily.Unix'));
    expect(unityBridge, contains('UnixDomainSocketEndPoint'));
    expect(unityBridge, contains('MaximumFrameBytes = 64 * 1024'));
    expect(unityBridge, contains('sessionToken'));
    expect(unityBridge, contains('DuplicatePropertyNameHandling.Error'));
    expect(unityBridge, contains('RequireExactProperties'));
    expect(unityBridge, isNot(contains('TcpClient')));
    expect(unityBridge, isNot(contains('HttpClient')));
  });

  test('one sidecar carries Avatar and local space command receipts', () {
    expect(swiftBridge, contains('maaso/unity_avatar'));
    expect(swiftBridge, contains('sendAvatarCommand'));
    expect(swiftBridge, contains('avatarResult'));
    expect(swiftBridge, isNot(contains('worldEvent')));
    expect(unityBridge, contains('"avatarCommand"'));
    expect(unityBridge, contains('AvatarMethods.Contains(method)'));
    expect(unityBridge, contains('ReportAvatarCommandResult'));
    for (final method in const [
      'enterAgentSpace',
      'leaveAgentSpace',
      'requestAgentSpaceMoveAtScreenPoint',
    ]) {
      expect(swiftBridge, contains('"$method"'), reason: method);
      expect(unityBridge, contains('"$method"'), reason: method);
      expect(unityReceiver, contains('case "$method":'), reason: method);
    }
    expect(
      unityReceiver,
      contains('DesktopUnitySidecarBridge.ReportAvatarReady()'),
    );
    expect(
      unityReceiver,
      contains('DesktopUnitySidecarBridge.ReportAvatarCommandResult(payload)'),
    );
    expect(
      unityReceiver,
      contains(
        'EnsureAgentSpace().ExecuteAsync(method, AgentSpaceController.ParseCommand(json),',
      ),
    );
    expect(
      unityReceiver,
      contains('result => NotifyCommandResult(JsonUtility.ToJson(result))'),
    );
    expect(
      unityReceiver,
      isNot(
        contains(
          'EnsureAgentSpace().Execute(method, FromJson<AgentSpaceCommand>(json))',
        ),
      ),
      reason: 'Dispatching a camera route cannot report immediate completion.',
    );
    expect(
      agentSpaceController,
      contains(
        'owner.BindPersonalRoom(receiver, room.HomeAgentAnchor, avatar.position, avatar.rotation)',
      ),
    );
    expect(agentSpaceController, contains('entryReceipts.Add(pending)'));
    expect(agentSpaceController, contains('exitReceipts.Add(pending)'));
    expect(agentSpaceController, contains('StartCoroutine(ReportAfterFrame('));
    expect(
      agentSpaceController,
      contains('yield return new WaitForEndOfFrame()'),
    );
    expect(
      agentSpaceController,
      contains('command.viewportTop = ReadViewport(document, "viewportTop")'),
      reason:
          'Legacy omission must remain distinct from an explicit zero viewport.',
    );
    expect(agentSpaceController, contains('sessionId != requestedSession'));
    expect(
      agentSpaceController,
      contains('retiredSessions.Contains(requestedSession)'),
    );
    expect(agentSpaceController, contains('RestoreHomeImmediately()'));
    expect(
      agentSpaceController,
      isNot(contains('InstantiateBundledAvatarForWorld')),
    );
  });

  test('Dart arbiter methods pass identical Swift and sidecar allowlists', () {
    Set<String> quotedMethods(String source, String start, String end) {
      final begin = source.indexOf(start);
      expect(begin, greaterThanOrEqualTo(0));
      final finish = source.indexOf(end, begin + start.length);
      expect(finish, greaterThan(begin));
      return RegExp(r'"([A-Za-z][A-Za-z.]+)"')
          .allMatches(source.substring(begin + start.length, finish))
          .map((match) => match.group(1)!)
          .toSet();
    }

    final swiftMethods = quotedMethods(
      swiftBridge,
      'avatarMethods: Set<String> = [',
      ']',
    );
    final sidecarMethods = quotedMethods(
      unityBridge,
      'HashSet<string> AvatarMethods = new(',
      'StringComparer.Ordinal',
    );
    expect(sidecarMethods, unorderedEquals(swiftMethods));
    expect(
      sidecarMethods,
      contains(UnityAvatarCommandDispatchSink.commandMethod),
    );
    expect(
      sidecarMethods,
      contains(UnityAvatarCommandDispatchSink.resetMethod),
    );
  });

  test('portal release preserves the shared Unity sidecar session', () {
    final releaseStart = swiftBridge.indexOf('private func releaseLease');
    final releaseEnd = swiftBridge.indexOf(
      'private static func dimensions',
      releaseStart,
    );
    expect(releaseStart, greaterThanOrEqualTo(0));
    expect(releaseEnd, greaterThan(releaseStart));
    final releaseBody = swiftBridge.substring(releaseStart, releaseEnd);
    expect(releaseBody, isNot(contains('session?.stop()')));
    expect(releaseBody, isNot(contains('session = nil')));
  });

  test('desktopHigh dimensions agree across Swift and Unity sidecar', () {
    expect(swiftBridge, contains('case "desktopHigh": return (1024, 1792)'));
    expect(
      swiftBridge,
      contains(
        '["desktopHigh", "compactHigh", "compactBalanced", "compactLow"]',
      ),
    );
    expect(unityBridge, contains('string.Equals(value, "desktopHigh"'));
    expect(swiftBridge, contains('height > 0, height <= 2160'));
  });

  test('native desktop pet renderer preserves sRGB color semantics', () {
    final rendererStart = swiftBridge.indexOf(
      'private final class MacOSDesktopPetSurfaceRenderer',
    );
    final rendererEnd = swiftBridge.indexOf(
      'private extension Comparable',
      rendererStart,
    );
    expect(rendererStart, greaterThanOrEqualTo(0));
    expect(rendererEnd, greaterThan(rendererStart));

    final rendererBody = swiftBridge.substring(rendererStart, rendererEnd);
    expect(rendererBody, contains('CGColorSpace(name: CGColorSpace.sRGB)!'));
    expect(
      rendererBody,
      contains('options: [.colorSpace: Self.sRGBColorSpace]'),
    );
    expect(rendererBody, contains('format: .BGRA8'));
    expect(rendererBody, contains('colorSpace: Self.sRGBColorSpace'));
  });

  test('IOSurface frames use color-normalized triple-buffered transport', () {
    expect(swiftBridge, contains('IOSurfaceLookup'));
    expect(swiftBridge, contains('CVPixelBufferCreateWithIOSurface'));
    expect(swiftBridge, contains('kCVImageBufferCGColorSpaceKey'));
    expect(swiftBridge, contains('kCVImageBufferColorPrimaries_ITU_R_709_2'));
    expect(swiftBridge, contains('kCVImageBufferTransferFunction_sRGB'));
    expect(swiftBridge, contains('.shouldPropagate'));
    expect(swiftBridge, contains('textureFrameAvailable'));
    expect(surfacePlugin, contains('kSurfaceSlotCount = 3'));
    expect(surfacePlugin, contains('IUnityGraphicsMetalV2'));
    expect(surfacePlugin, contains('MTLPixelFormatBGRA8Unorm_sRGB'));
    expect(surfacePlugin, contains('newRenderPipelineStateWithDescriptor'));
    expect(surfacePlugin, contains('renderCommandEncoderWithDescriptor'));
    expect(surfacePlugin, contains('source.read(uint2(input.position.xy))'));
    expect(surfacePlugin, isNot(contains('blitCommandEncoder')));
    expect(surfacePlugin, contains('addCompletedHandler'));
    expect(surfacePlugin, contains('NSApplicationActivationPolicyAccessory'));
    expect(surfacePlugin, contains('[window orderOut:nil]'));
    expect(unityBridge, contains('Application.runInBackground = true'));
    expect(unityBridge, contains('MaasoDesktopAvatarPortalHidePlayerWindow'));
    expect(unityBridge, contains('getppid() != expectedParentProcessId'));
    expect(
      RegExp(
        r'UNITY_INTERFACE_EXPORT[\s\S]*?MaasoDesktopAvatarPortal',
      ).allMatches(surfacePlugin).length,
      greaterThanOrEqualTo(3),
    );
    expect(surfacePlugin, isNot(contains('glReadPixels')));
  });

  test('packaging validates and signs the fixed helper bundle', () {
    expect(embedScript, contains('Builds/macOS/MaasoAvatar.app'));
    expect(embedScript, contains('Contents/Resources/Data'));
    expect(
      embedScript,
      contains(r'${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers'),
    );
    expect(embedScript, contains('/usr/bin/codesign'));
    expect(embedScript, contains('-extract LSUIElement raw -expect bool'));
    expect(embedScript, contains('com.futurpals.maaso.avatar-sidecar'));
    expect(embedScript, contains('--entitlements'));
    expect(sidecarEntitlements, contains('com.apple.security.inherit'));
    expect(sidecarEntitlements, contains('com.apple.security.cs.allow-jit'));
    expect(
      sidecarEntitlements,
      isNot(contains('com.apple.security.cs.disable-library-validation')),
    );
    expect(
      adHocSidecarEntitlements,
      contains('com.apple.security.cs.disable-library-validation'),
    );
    expect(embedScript, contains('[ "\${signing_identity}" = "-" ]'));
    expect(embedScript, isNot(contains('\$1')));
  });

  test('packaging rejects a sidecar built from stale protocol sources', () {
    const protocolSources = <String>[
      'lib/src/features/agent/application/avatar/'
          'desktop_unity_sidecar_protocol.dart',
      'macos/Runner/MacOSUnityAvatarPortal.swift',
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
          'CompanionPortalCaptureController.cs',
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
          'DesktopUnitySidecarBridge.cs',
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
          'UnityAvatarCommandReceiver.cs',
      'unity/masso_avatar/Assets/Plugins/macOS/'
          'MaasoDesktopAvatarPortalBridge.mm',
      'unity/masso_avatar/Assets/MaasoAvatar/Editor/'
          'MaasoUnityLibraryExporter.cs',
      'unity/masso_avatar/Assets/Plugins/macOS/'
          'MaasoDesktopAvatarPortalBridge.mm.meta',
    ];
    for (final source in protocolSources) {
      expect(exporter, contains(source));
      expect(embedScript, contains(source));
    }
    expect(exporter, contains('SHA256.Create()'));
    expect(exporter, contains('WriteMacOSSidecarProtocolFingerprint'));
    expect(exporter, contains('maaso-sidecar-protocol.sha256'));
    expect(embedScript, contains("/usr/bin/printf '%s\\0'"));
    expect(embedScript, contains('/usr/bin/shasum -a 256'));
    expect(embedScript, contains('expected_fingerprint'));
    expect(embedScript, contains('exported_fingerprint'));
    expect(embedScript, contains('sidecar is stale'));
  });

  test('Unity export compiles a universal native bundle for Mono', () {
    expect(exporter, contains('ScriptingImplementation.Mono2x'));
    expect(exporter, contains('PlayerSettings.productName = "MaasoAvatar"'));
    expect(
      exporter,
      contains('BuildMacOSNativePortalPlugin(MacOSPortalGeneratedBundlePath)'),
    );
    expect(exporter, contains('"-arch", "arm64"'));
    expect(exporter, contains('"-arch", "x86_64"'));
    expect(exporter, contains('"-framework", "AppKit"'));
    expect(exporter, contains('MaasoDesktopAvatarPortalBridge.bundle'));
    expect(exporter, contains('"/usr/bin/xcrun"'));
  });

  test('native portal source remains compiler input, not a player plugin', () {
    expect(surfacePluginMeta, contains('PluginImporter:'));
    expect(
      RegExp(
        r'- first:\s*\n\s*Any:\s*\n\s*second:\s*\n\s*enabled: 0',
      ).hasMatch(surfacePluginMeta),
      isTrue,
    );
    expect(
      RegExp(
        r'- first:\s*\n\s*Standalone: OSXUniversal\s*\n'
        r'\s*second:\s*\n\s*enabled: 0',
      ).hasMatch(surfacePluginMeta),
      isTrue,
    );
    expect(
      RegExp(
        r'(?:Android: Android|iPhone: iOS|WebGL: WebGL)\s*\n'
        r'\s*second:\s*\n\s*enabled: 1',
      ).hasMatch(surfacePluginMeta),
      isFalse,
    );
  });

  test(
    'the macOS native bundle is imported for startup before BuildPlayer',
    () {
      final prepareCall = exporter.indexOf(
        'PrepareMacOSNativePortalPluginForBuild();',
      );
      final buildPlayer = exporter.indexOf('BuildPipeline.BuildPlayer(');
      expect(prepareCall, greaterThanOrEqualTo(0));
      expect(prepareCall, lessThan(buildPlayer));
      expect(
        exporter,
        isNot(contains('BuildMacOSNativePortalPlugin(outputPath)')),
      );
      expect(exporter, contains('Assets/Plugins/macOS/GeneratedNative/'));
      expect(exporter, contains('ImportAssetOptions.ForceSynchronousImport'));
      expect(
        exporter,
        contains('importer.SetCompatibleWithAnyPlatform(false)'),
      );
      expect(exporter, contains('importer.SetCompatibleWithEditor(false)'));
      expect(
        exporter,
        contains(
          'importer.SetCompatibleWithPlatform(BuildTarget.StandaloneOSX, true)',
        ),
      );
      expect(exporter, contains('importer.isPreloaded = true'));
      expect(exporter, contains('importer.SaveAndReimport()'));
      expect(
        File('unity/masso_avatar/.gitignore').readAsStringSync(),
        contains('/Assets/Plugins/macOS/GeneratedNative/'),
      );
    },
  );
}
