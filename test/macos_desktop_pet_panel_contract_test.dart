import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS pet is a separate native panel backed by the shared IOSurface',
    () {
      final portal = File(
        'macos/Runner/MacOSUnityAvatarPortal.swift',
      ).readAsStringSync();
      final mainWindow = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();

      expect(portal, contains('maaso/desktop_companion'));
      expect(portal, contains('final class MacOSDesktopPetPanel: NSPanel'));
      expect(portal, contains('styleMask: [.borderless, .nonactivatingPanel]'));
      expect(portal, contains('desktopCompanionBridge.accept(frame: frame)'));
      expect(portal, contains('IOSurfaceLookup(IOSurfaceID(frame.surfaceID))'));
      expect(
        mainWindow,
        contains('MacOSDesktopCompanionBridge(registrar: registrar)'),
      );
    },
  );

  test('native pet supports right-click, drag, focus dismissal, and gaze', () {
    final source = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();

    expect(
      source,
      contains('override func rightMouseDown(with event: NSEvent)'),
    );
    expect(source, contains('menu.popUp(positioning: nil'));
    expect(source, contains('override func mouseDragged(with event: NSEvent)'));
    expect(source, contains('private static let gazeInterval'));
    expect(source, contains('NSEvent.mouseLocation'));
    expect(source, contains('(mouse.x - headAnchor.x) / 220.0'));
    expect(source, isNot(contains('(headAnchor.x - mouse.x) / 220.0')));
    expect(
      source,
      contains(
        'ignoresMouseEvents = !petContentView.containsVisibleAvatar(at: point)',
      ),
    );
  });

  test('alpha passthrough updates on frames and local/global pointer movement', () {
    final source = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final panel = source.substring(
      source.indexOf('private final class MacOSDesktopPetPanel'),
      source.indexOf('private final class MacOSDesktopPetContentView'),
    );
    final tracking = panel.substring(
      panel.indexOf('private func startGazeTracking()'),
      panel.indexOf('private func updateGaze()'),
    );
    final passthrough = panel.substring(
      panel.indexOf('private func updateMousePassthrough()'),
      panel.indexOf('@objc private func screenParametersDidChange'),
    );
    for (final method in [
      'setAvatarImage(_ image: CGImage)',
      'clearAvatarImage()',
    ]) {
      final body = panel.substring(panel.indexOf('func $method'));
      expect(
        body.substring(0, body.indexOf('\n  }')),
        contains('updateMousePassthrough()'),
      );
    }
    expect(
      tracking,
      contains('NSEvent.addLocalMonitorForEvents(matching: .mouseMoved)'),
    );
    expect(
      tracking,
      contains('NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)'),
    );
    expect(tracking, contains('return event'));
    expect(
      tracking,
      contains(
        'if let monitor = localMouseMoveMonitor { NSEvent.removeMonitor(monitor) }',
      ),
    );
    expect(
      tracking,
      contains(
        'if let monitor = globalMouseMoveMonitor { NSEvent.removeMonitor(monitor) }',
      ),
    );
    expect(tracking, contains('RunLoop.main.add(timer, forMode: .common)'));
    expect(passthrough, contains('guard isVisible else'));
    expect(
      passthrough,
      contains('convertPoint(fromScreen: NSEvent.mouseLocation)'),
    );
    expect(
      passthrough,
      contains('petContentView.convert(windowPoint, from: nil)'),
    );
    expect(passthrough, isNot(contains('avatarInteractionRect')));
    expect(source, isNot(contains('CGEvent.tapCreate')));
    expect(source, isNot(contains('event.post(')));
  });

  test('frame failure clears alpha and helper is included in native target', () {
    final source = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final project = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final helper = File(
      'macos/Runner/MacOSAvatarAlphaHitTest.swift',
    ).readAsStringSync();
    expect(
      source,
      contains(
        'guard let image = surfaceRenderer.makeImage(frame: frame) else {\n      clearAvatarFrame()',
      ),
    );
    expect(source, contains('avatarAlphaHitTest.replaceImage(image)'));
    expect(source, contains('avatarAlphaHitTest.replaceImage(nil)'));
    expect(project, contains('MacOSAvatarAlphaHitTest.swift in Sources'));
    expect(helper, contains('image.dataProvider?.data'));
    expect(helper, isNot(contains('CGContext(')));
    expect(helper, isNot(contains('IOSurfaceGetBaseAddress')));
  });

  test('native pet uses crisp Retina capture and bounded hot scaling', () {
    final source = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();

    expect(
      source,
      contains(
        'private static let baseAvatarSize = NSSize(width: 160, height: 280)',
      ),
    );
    expect(source, contains('override func viewDidMoveToWindow()'));
    expect(source, contains('override func viewDidChangeBackingProperties()'));
    expect(
      source,
      contains('avatarLayer.contentsScale = window?.backingScaleFactor'),
    );
    expect(source, contains('avatarLayer.minificationFilter = .linear'));
    expect(
      source,
      isNot(contains('avatarLayer.minificationFilter = .trilinear')),
    );
    expect(source, contains('restoreSpatialPlacement(panelSize: nextSize)'));
    expect(source, contains('Self.panelSize(visualScale:'));
  });

  test('macOS accepts exactly the four presentation size tiers', () {
    final source = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final presentationSource = source.substring(
      source.indexOf(
        'private struct MacOSDesktopCompanionPresentationConfiguration',
      ),
      source.indexOf('private final class MacOSDesktopPetPanel'),
    );

    expect(source, contains('case "configurePresentation":'));
    expect(source, contains('Set(arguments.keys) == keys'));
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
      expect(source, contains('"$key"'));
    }
    expect(source, contains('[24, 30, 60].contains(targetFps)'));
    expect(
      presentationSource,
      contains(
        'private static let supportedVisualScales: Set<Double> = [\n'
        '    1.2, 1.8, 2.4, 3.0,\n'
        '  ]',
      ),
    );
    expect(
      presentationSource,
      contains('supportedVisualScales.contains(visualScaleNumber.doubleValue)'),
    );
    expect(presentationSource, contains('visualScale: 1.8'));
    expect(
      presentationSource,
      isNot(contains('visualScaleNumber.doubleValue >=')),
    );
    expect(
      presentationSource,
      isNot(contains('visualScaleNumber.doubleValue <=')),
    );
    expect(
      RegExp(
        r'CFGetTypeID\(.+Number\) != CFBooleanGetTypeID\(\)',
      ).allMatches(presentationSource).length,
      3,
    );
    expect(
      RegExp(
        r'CFGetTypeID\(.+Number\) == CFBooleanGetTypeID\(\)',
      ).allMatches(presentationSource).length,
      2,
    );
    expect(
      source,
      contains(
        'snapReleaseNumber.doubleValue >= snapAcquireNumber.doubleValue',
      ),
    );
    expect(
      source,
      contains('windowLevel(alwaysOnTop: configuration.alwaysOnTop)'),
    );
  });

  test('bubble and normal app window have independent lifecycles', () {
    final portal = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final mainWindow = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();

    expect(portal, contains('final class MacOSDesktopPetBubbleView: NSView'));
    expect(portal, contains('case "showBubble":'));
    expect(mainWindow, contains('desktopCompanionBridge?.isPetVisible'));
    expect(mainWindow, contains('orderOut(nil)'));
  });

  test(
    'desktop-only factories and login policy leave mobile and web unchanged',
    () {
      final factory = File(
        'lib/src/desktop/infrastructure/desktop_companion_host_gateway_factory.dart',
      ).readAsStringSync();
      final ioFactory = File(
        'lib/src/desktop/infrastructure/desktop_companion_host_gateway_factory_io.dart',
      ).readAsStringSync();
      final login = File(
        'lib/src/features/auth/presentation/login_page.dart',
      ).readAsStringSync();
      final shell = File('lib/src/app/app_agent_shell.dart').readAsStringSync();

      expect(factory, contains('if (dart.library.io)'));
      expect(ioFactory, contains('Platform.isMacOS'));
      expect(login, contains('LoginDoorwayArtwork()'));
      expect(
        shell,
        contains('!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS'),
      );
    },
  );
}
