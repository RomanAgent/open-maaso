import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'macos/Runner/MacOSUnityAvatarPortal.swift',
  ).readAsStringSync();

  test('macOS persists only strict normalized spatial state v1', () {
    final attachmentSource = _between(
      source,
      'private struct MacOSDesktopPetSpatialAttachment',
      'private struct MacOSDesktopPetSpatialStateV1',
    );
    final stateSource = _between(
      source,
      'private struct MacOSDesktopPetSpatialStateV1',
      'private struct MacOSDesktopPetMonitor',
    );

    expect(source, contains('maaso.desktopCompanion.spatialStateV1'));
    expect(
      attachmentSource,
      contains('Set<String> = ["kind", "targetId", "edge"]'),
    );
    expect(attachmentSource, contains('Set(value.keys) == keys'));
    expect(attachmentSource, contains('kind != .windowTop || edge == .top'));
    expect(
      stateSource,
      contains('"version", "monitorId", "normalizedX", "normalizedY"'),
    );
    expect(stateSource, contains('baseKeys.union(["attachment"])'));
    expect(stateSource, contains('keys == baseKeys || keys == allKeys'));
    expect(stateSource, contains('!CFNumberIsFloatType(versionNumber)'));
    expect(stateSource, contains('normalizedXNumber.doubleValue.isFinite'));
    expect(stateSource, contains('normalizedYNumber.doubleValue.isFinite'));
    expect(stateSource, contains('normalizedXNumber.doubleValue >= 0'));
    expect(stateSource, contains('normalizedXNumber.doubleValue <= 1'));
    expect(stateSource, contains('normalizedYNumber.doubleValue >= 0'));
    expect(stateSource, contains('normalizedYNumber.doubleValue <= 1'));
    expect(stateSource, contains('if let attachment'));
    expect(
      source,
      contains('nextState.dictionary,\n      forKey: Self.spatialStateKey'),
    );
    expect(source, contains('NSRectFromString(storedValue)'));
    expect(source, contains('removeObject(forKey: Self.legacyStoredFrameKey)'));
    expect(source, isNot(contains('NSStringFromRect(frame)')));
    expect(source, isNot(contains('setValue(NSStringFromRect')));
    expect(source, isNot(contains('private static let storedFrameKey')));
  });

  test('monitor restore uses UUID identity and normalized main fallback', () {
    final restoreSource = _between(
      source,
      'private func restoreSpatialPlacement(panelSize: NSSize)',
      'private func persistSpatialState(',
    );

    expect(source, contains('CGDisplayCreateUUIDFromDisplayID(displayID)'));
    expect(source, contains('CFUUIDCreateString(nil, uuid)'));
    expect(source, contains('CGDisplayVendorNumber(displayID)'));
    expect(source, contains('CGDisplayModelNumber(displayID)'));
    expect(source, contains('CGDisplaySerialNumber(displayID)'));
    expect(source, contains('let displayID: CGDirectDisplayID'));
    expect(source, contains('displayID: displayID'));
    expect(source, contains('let primaryDisplayID = CGMainDisplayID()'));
    expect(
      source,
      contains(r'monitors.first(where: { $0.displayID == primaryDisplayID })'),
    );
    expect(source, isNot(contains(r'$0.screen === main')));
    expect(
      restoreSource,
      contains(r'monitors.first(where: { $0.id == state.monitorID })'),
    );
    expect(restoreSource, contains('?? Self.mainMonitor(in: monitors)'));
    expect(restoreSource, contains('normalizedX: state.normalizedX'));
    expect(restoreSource, contains('normalizedY: state.normalizedY'));
    expect(restoreSource, contains('resolvedAttachment'));
    expect(
      restoreSource,
      contains('persistSpatialState(attachment: resolvedAttachment)'),
    );
  });

  test('window-top restore follows its target across monitors once', () {
    final restoreSource = _between(
      source,
      'private func restoreSpatialPlacement(panelSize: NSSize)',
      'private func persistSpatialState(',
    );

    expect(restoreSource, contains('case .workAreaEdge:'));
    expect(restoreSource, contains('monitor: monitor'));
    expect(restoreSource, contains('case .windowTop:'));
    expect(
      restoreSource,
      contains('let windowInfo = Self.foreignWindowInfo()'),
    );
    expect(
      restoreSource,
      contains('for candidateMonitor in monitors where targetWindow == nil'),
    );
    expect(
      restoreSource,
      contains(r').first(where: { $0.id == attachment.targetID })'),
    );
    expect(restoreSource, contains('for: targetWindow.frame'));
    expect(restoreSource, contains('placementMonitor = targetMonitor'));
    expect(
      restoreSource,
      contains('visibleFrame: placementMonitor.visibleFrame'),
    );
    expect(
      RegExp(r'Self\.foreignWindowInfo\(\)').allMatches(restoreSource),
      hasLength(1),
    );
  });

  test('position normalization round-trips the visible avatar footprint', () {
    final normalizeSource = _between(
      source,
      'private static func normalizedPosition(',
      'private static func snapCandidates(',
    );

    expect(
      RegExp(
        r'let horizontalInset = horizontalVisibleInset\(panelSize: panelSize\)',
      ).allMatches(normalizeSource),
      hasLength(2),
    );
    expect(
      normalizeSource,
      contains('let minimumX = visibleFrame.minX - horizontalInset'),
    );
    expect(
      normalizeSource,
      contains('visibleFrame.maxX - panelSize.width + horizontalInset'),
    );
    expect(normalizeSource, contains('(clamped.x - minimumX) / travelX'));
    expect(normalizeSource, contains('x: minimumX + normalizedX * travelX'));
    expect(
      RegExp(
        r'let avatarHeight = visibleAvatarHeight\(panelSize: panelSize\)',
      ).allMatches(normalizeSource),
      hasLength(2),
    );
    expect(normalizeSource, contains('visibleFrame.height - avatarHeight'));
    expect(
      normalizeSource,
      contains('(visibleFrame.maxY - avatarHeight - clamped.y) / travelY'),
    );
    expect(
      normalizeSource,
      contains('visibleFrame.maxY - avatarHeight - normalizedY * travelY'),
    );
    expect(normalizeSource, isNot(contains('backingScaleFactor')));
    expect(source, contains('primaryTop - frame.maxY'));
  });

  test(
    'vertical bounds use the avatar and preserve two-axis drag and local show',
    () {
      final drag = _between(
        source,
        'func continueDragging()',
        'func endDragging(',
      );
      final clamp = _between(
        source,
        'private static func clampedOrigin(\n    _ proposed: NSPoint,\n    panelSize: NSSize,\n    visibleFrame: NSRect',
        'private static func panelSize(',
      );
      final snap = _between(
        source,
        'private static func snapCandidates(',
        'private static func eligibleForeignWindows(',
      );
      expect(
        source,
        contains('private static let baseAvatarHeight: CGFloat = 280'),
      );
      expect(
        source,
        contains('baseAvatarSize = NSSize(width: 160, height: 280)'),
      );
      expect(clamp, contains('visibleFrame.maxY - avatarHeight'));
      expect(clamp, isNot(contains('visibleFrame.maxY - panelSize.height')));
      expect(
        snap,
        contains('visible.maxY - visibleAvatarHeight(panelSize: panelSize)'),
      );
      expect(drag, contains('performDrag(with: gesture.mouseDownEvent)'));
      expect(drag, contains('!isDraggingPet'));
      expect(drag, contains('NSEvent.pressedMouseButtons & 1 == 0'));
      expect(drag, contains('self.dragCompletionTimer === timer'));
      expect(drag, contains('RunLoop.main.add(timer, forMode: .common)'));
      expect(drag, isNot(contains('setFrameOrigin(')));
      expect(drag, contains('dragPanelSizeBeforeTracking = frame.size'));
      expect(
        drag.indexOf('height: Self.visibleAvatarHeight'),
        lessThan(drag.indexOf('performDrag(with:')),
      );
      final show = _between(source, 'func showPanel(', 'func hidePanel()');
      expect(
        show.indexOf('visibilityGeneration = interactionGeneration'),
        lessThan(show.indexOf('orderFrontRegardless()')),
      );
      expect(
        show.indexOf('restoreSpatialPlacement(panelSize: frame.size)'),
        lessThan(show.indexOf('orderFrontRegardless()')),
      );
      expect(
        source,
        contains('bubbleView.show(text: text, in: bubbleLayoutBounds'),
      );
      final layout = _between(
        source,
        'override func layout()',
        'override func viewDidMoveToWindow()',
      );
      expect(
        layout,
        contains(
          'bubbleView.reflow(in: bubbleLayoutBounds, above: avatarRect.maxY)',
        ),
      );
      for (final section in [
        _between(
          source,
          'private func finishSpatialDrop()',
          'private func selectedSnapCandidate(',
        ),
        _between(
          source,
          'private func persistSpatialState(',
          'private static func loadSpatialState()',
        ),
      ]) {
        expect(section, contains('for: Self.visibleAvatarFrame(for: frame)'));
      }
    },
  );

  test('horizontal clamp lets the visible avatar touch both screen edges', () {
    final clampSource = _between(
      source,
      'private static func clampedOrigin(\n    _ proposed: NSPoint,\n    panelSize: NSSize,\n    visibleFrame: NSRect',
      'private static func panelSize(visualScale: CGFloat)',
    );
    final initialFrameSource = _between(
      source,
      'private static func restoredOrInitialFrame(',
      'private static func normalizedPosition(',
    );
    final snapSource = _between(
      source,
      'private static func snapCandidates(',
      'private static func eligibleForeignWindows(',
    );
    final insetSource = _between(
      source,
      'private static func horizontalVisibleInset(panelSize: NSSize)',
      'private var dragThreshold: CGFloat',
    );

    expect(
      source,
      contains(
        'private static let basePanelSize = NSSize(width: 300, height: 420)',
      ),
    );
    expect(
      source,
      contains('private static let baseAvatarWidth: CGFloat = 160'),
    );
    expect(
      clampSource,
      contains(
        'let horizontalInset = horizontalVisibleInset(panelSize: panelSize)',
      ),
    );
    expect(
      clampSource,
      contains('let minimumX = visibleFrame.minX - horizontalInset'),
    );
    expect(
      clampSource,
      contains('visibleFrame.maxX - panelSize.width + horizontalInset'),
    );
    expect(clampSource, contains('to: minimumX ... maximumX'));
    expect(
      insetSource,
      contains('return max(0, (panelSize.width - avatarWidth) / 2)'),
    );
    expect(
      initialFrameSource,
      contains('+ horizontalVisibleInset(panelSize: panelSize) - 28'),
    );
    expect(
      snapSource,
      contains('NSPoint(x: visible.minX - horizontalInset, y: proposed.y)'),
    );
    expect(
      snapSource,
      contains('x: visible.maxX - panelSize.width + horizontalInset'),
    );

    const visibleLeft = 0.0;
    const visibleRight = 1440.0;
    for (final scale in <double>[1.2, 1.8, 2.4, 3.0]) {
      final panelWidth = 300 * scale;
      final avatarWidth = 160 * scale;
      final inset = (panelWidth - avatarWidth) / 2;
      final leftOrigin = visibleLeft - inset;
      final rightOrigin = visibleRight - panelWidth + inset;
      expect(leftOrigin + inset, visibleLeft);
      expect(rightOrigin + panelWidth - inset, visibleRight);
    }
  });

  test('drop snap applies release hysteresis before nearest acquire', () {
    final selectionSource = _between(
      source,
      'private func selectedSnapCandidate(',
      'private func restoreSpatialPlacement(panelSize: NSSize)',
    );
    final endDragSource = _between(
      source,
      'func endDragging(with event: NSEvent)',
      'func cancelPointerGesture()',
    );

    expect(selectionSource, contains('spatialState?.attachment'));
    expect(selectionSource, contains('snapReleaseDistance'));
    expect(selectionSource, contains('candidates.min'));
    expect(selectionSource, contains('snapAcquireDistance'));
    expect(
      selectionSource.indexOf('snapReleaseDistance'),
      lessThan(selectionSource.indexOf('snapAcquireDistance')),
    );
    expect(source, contains('if presentationConfiguration.snapEnabled'));
    expect(source, contains('finishSpatialDrop()'));
    expect(
      endDragSource.indexOf('if didDrag'),
      lessThan(endDragSource.indexOf('finishSpatialDrop()')),
    );
    expect(
      source,
      contains(
        'let retainedAttachment = configuration.snapEnabled\n'
        '      ? spatialState?.attachment\n'
        '      : nil',
      ),
    );
  });

  test(
    'snap candidates use work area and filtered foreign layer-zero windows',
    () {
      final candidateSource = _between(
        source,
        'private static func snapCandidates(',
        'private static func appKitFrame(fromQuartzFrame frame: CGRect)',
      );

      expect(candidateSource, contains('monitor.visibleFrame'));
      expect(
        candidateSource,
        contains('visible.maxY < monitor.frame.maxY - 0.5'),
      );
      expect(
        candidateSource,
        contains('visible.minY > monitor.frame.minY + 0.5'),
      );
      expect(
        candidateSource,
        contains('visible.minX > monitor.frame.minX + 0.5'),
      );
      expect(
        candidateSource,
        contains('visible.maxX < monitor.frame.maxX - 0.5'),
      );
      for (final edge in <String>['.top', '.bottom', '.left', '.right']) {
        expect(candidateSource, contains(edge));
      }
      expect(candidateSource, contains('y: window.frame.maxY'));
      expect(
        candidateSource,
        contains('proposed.x.clamped(to: window.frame.minX ... maximumX)'),
      );
      expect(
        candidateSource,
        contains('[.optionOnScreenOnly, .excludeDesktopElements]'),
      );
      expect(
        candidateSource,
        contains('ownerPIDNumber.int32Value != currentProcessID'),
      );
      expect(candidateSource, contains('layerNumber.intValue == 0'));
      expect(
        candidateSource,
        contains('alphaNumber.doubleValue > minimumForeignWindowAlpha'),
      );
      expect(candidateSource, contains('minimumForeignWindowWidth'));
      expect(candidateSource, contains('minimumForeignWindowHeight'));
      expect(candidateSource, contains('excludedForeignWindowOwners'));
      expect(candidateSource, contains('excludedForeignWindowOwnerPrefixes'));
      expect(source, contains('"maaso", "masso_avatar"'));
      expect(candidateSource, contains('ownerName.lowercased().hasPrefix'));
      expect(
        candidateSource,
        contains('appKitFrame.intersects(monitor.visibleFrame)'),
      );
    },
  );

  test('topology restore is event-driven without AX or window polling', () {
    expect(
      source,
      contains('NSApplication.didChangeScreenParametersNotification'),
    );
    expect(source, contains('#selector(screenParametersDidChange(_:))'));
    expect(
      source,
      contains(
        'NotificationCenter.default.removeObserver(\n'
        '      self,\n'
        '      name: NSApplication.didChangeScreenParametersNotification',
      ),
    );
    expect(
      RegExp('CGWindowListCopyWindowInfo').allMatches(source),
      hasLength(2),
    );
    final ownWindowSource = _between(
      source,
      'private func currentWindowServerFrame()',
      'func presentContextMenu(',
    );
    final cleanupSource = _between(
      source,
      'func cancelPointerGesture()',
      'private func currentWindowServerFrame()',
    );
    expect(ownWindowSource, contains('CGWindowID(exactly: windowNumber)'));
    expect(ownWindowSource, contains('.optionIncludingWindow, windowID'));
    expect(ownWindowSource, isNot(contains('kCGNullWindowID')));
    expect(ownWindowSource, isNot(contains('Timer(')));
    expect(
      cleanupSource,
      contains(
        'dragPanelSizeBeforeTracking == nil\n'
        '      ? nil : currentWindowServerFrame()?.origin',
      ),
    );
    expect(
      cleanupSource.indexOf('currentWindowServerFrame()'),
      lessThan(cleanupSource.indexOf('isMovable = false')),
    );
    expect(
      RegExp(r'currentWindowServerFrame\(\)').allMatches(source),
      hasLength(
        2,
      ), // declaration and one completion call; no continuous polling
    );
    expect(source, isNot(contains('AXUIElement')));
    expect(source, isNot(contains('AXIsProcessTrusted')));
    expect(source, isNot(contains('kAXWindowsAttribute')));
  });
}

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, greaterThanOrEqualTo(0), reason: 'missing $start');
  expect(endIndex, greaterThan(startIndex), reason: 'missing $end');
  return source.substring(startIndex, endIndex);
}
