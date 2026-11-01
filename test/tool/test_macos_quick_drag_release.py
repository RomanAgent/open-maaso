#!/usr/bin/env python3
"""Reproduce Window Server movement arriving before AppKit's frame cache.

Move a real NSPanel, but expose the previous frame through its getter until the
first restoration write. Production cleanup must recover the actual Window
Server origin, not the stale getter. No mouse events are posted to the system.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

from test_macos_system_drag import declaration


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path,
                        default=Path('macos/Runner/MacOSUnityAvatarPortal.swift'))
    source = parser.parse_args().source.read_text()
    panel = source[source.index('private final class MacOSDesktopPetPanel'):]
    markers = [
        'private struct PointerGesture',
        'private static func visibleAvatarHeight(',
        'func beginDragging(with event: NSEvent)',
        'func continueDragging()',
        'private func finishSystemDragIfReleased()',
        'func endDragging(with event: NSEvent)',
        'func cancelPointerGesture()',
        'private static func appKitFrame(',
    ]
    if 'private func currentWindowServerFrame()' in panel:
        markers.append('private func currentWindowServerFrame()')
    members = '\n'.join(declaration(panel, marker) for marker in markers)
    members = members.replace('NSEvent.mouseLocation', 'pointer').replace(
        'NSEvent.pressedMouseButtons', 'buttons')
    types = '\n'.join(declaration(source, marker) for marker in [
        'private enum MacOSDesktopAvatarTapRegion',
        'private struct MacOSDesktopAvatarInteraction',
    ])
    swift = r'''
import AppKit
import QuartzCore
__TYPES__
class Content: NSView {
  func containsVisibleAvatar(at point: NSPoint) -> Bool { true }
  func semanticTap(at point: NSPoint) -> (normalizedX: CGFloat,
    normalizedY: CGFloat, region: MacOSDesktopAvatarTapRegion)? { (0.5, 0.5, .torso) }
}
var checks = 0
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
  checks += 1
  if !condition { failures.append(message) }
}
class Probe: NSPanel {
  static let basePanelSize = NSSize(width: 300, height: 420)
  static let baseAvatarHeight: CGFloat = 280
  static let maximumTapDuration: TimeInterval = 0.5
  static func monotonicTimestampMs() -> Int { 1 }
  var petContentView: Content { contentView as! Content }
  var pointer = NSPoint.zero
  var buttons = 1
  var pointerGesture: PointerGesture?
  var isDraggingPet = false
  var dragCompletionTimer: Timer?
  var dragPanelSizeBeforeTracking: NSSize?
  var visibilityGeneration = 1
  var dragThreshold: CGFloat = 6
  var starts = 0
  var taps = 0
  var drops: [NSPoint] = []
  var writes: [NSRect] = []
  var staleFrame: NSRect?
  override var frame: NSRect { staleFrame ?? super.frame }
  override func constrainFrameRect(_ rect: NSRect, to screen: NSScreen?) -> NSRect { rect }
  override func setFrame(_ rect: NSRect, display: Bool) {
    writes.append(rect)
    staleFrame = nil
    super.setFrame(rect, display: display)
  }
  override func performDrag(with event: NSEvent) { starts += 1 }
  func finishSpatialDrop() { drops.append(frame.origin) }
  func updateMousePassthrough() {}
  func onAvatarInteraction(_ event: MacOSDesktopAvatarInteraction) { taps += 1 }
  func moveSystemBeforeFrameNotification(to point: NSPoint) {
    let old = super.frame
    super.setFrameOrigin(point)
    CATransaction.flush()
    staleFrame = old
    writes.removeAll()
  }
__MEMBERS__
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let positions = [NSPoint(x: 500, y: 260), NSPoint(x: -550, y: 120),
  NSPoint(x: 260, y: -320), NSPoint(x: 160, y: 1200)]
for scale: CGFloat in [1.2, 2.4] {
  for target in positions {
    for completion in ["timer", "mouse-up", "next-down", "cancel"] {
      let size = NSSize(width: 300 * scale, height: 420 * scale)
      let panel = Probe(contentRect: NSRect(x: 250, y: 150,
        width: size.width, height: size.height),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.animationBehavior = .none
      panel.isMovable = false
      panel.contentView = Content(frame: NSRect(origin: .zero, size: size))
      panel.contentView!.wantsLayer = true
      panel.orderFrontRegardless()
      let localPoint = NSPoint(x: size.width / 2, y: 140 * scale)
      func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: localPoint, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
      }
      panel.pointer = panel.convertPoint(toScreen: localPoint)
      panel.beginDragging(with: event(.leftMouseDown))
      panel.pointer.y += 30
      panel.continueDragging()
      let oldTimer = panel.dragCompletionTimer!
      panel.moveSystemBeforeFrameNotification(to: target)
      check(panel.frame.origin != target, "fixture must expose a stale AppKit origin")
      panel.buttons = 0
      switch completion {
      case "timer": panel.finishSystemDragIfReleased()
      case "mouse-up": panel.endDragging(with: event(.leftMouseUp))
      case "next-down":
        panel.buttons = 1
        panel.beginDragging(with: event(.leftMouseDown))
      default:
        panel.cancelPointerGesture()
      }
      let label = "\(completion) scale=\(scale) target=\(target)"
      check(panel.writes.first?.origin == target,
        "\(label): first restoration must use the actual system origin")
      check(panel.frame == NSRect(origin: target, size: size),
        "\(label): restored full window must remain at the release position")
      let expectedDrops = completion == "timer" || completion == "mouse-up" ? [target] : []
      check(panel.drops == expectedDrops,
        "\(label): drop records the system position once; cancellation never persists")
      let writesBeforeOldTimer = panel.writes.count
      oldTimer.fire()
      panel.finishSystemDragIfReleased()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
      check(panel.writes.count == writesBeforeOldTimer,
        "\(label): stale timer cannot overwrite this or the next gesture")
      check(panel.frame.origin == target,
        "\(label): draining the next event loop must not jump back")
      check(panel.taps == 0, "\(label): quick drag is never a semantic tap")
      check(panel.starts == 1, "\(label): Window Server tracking is started once")
      panel.cancelPointerGesture()
      panel.orderOut(nil)
    }
  }
}
print(String(data: try! JSONSerialization.data(withJSONObject:
  ["checks": checks, "failures": failures], options: [.prettyPrinted, .sortedKeys]),
  encoding: .utf8)!)
exit(failures.isEmpty ? 0 : 1)
'''.replace('__TYPES__', types).replace('__MEMBERS__', members)
    with tempfile.TemporaryDirectory(prefix='maaso-quick-release-') as temp:
        path = Path(temp) / 'main.swift'
        binary = Path(temp) / 'native_test'
        path.write_text(swift)
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(temp) / 'cache'), str(path), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr)
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
