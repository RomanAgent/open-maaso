#!/usr/bin/env python3
"""Check the rendered layer tree when native drag tracking begins, not a frame later.

Compile the production gesture methods and complete content/bubble views.
Only pointer input, alpha-hit detection, and the Window Server drag call are
replaced. AppKit window resizing and Core Animation presentation are real.
Accept a source snapshot as a red control for the one-frame resize regression.
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
    args = parser.parse_args()
    source = args.source.read_text()
    panel = source[source.index('private final class MacOSDesktopPetPanel'):]
    markers = [
        'private struct PointerGesture',
        'private static func visibleAvatarHeight(',
        'func beginDragging(with event: NSEvent)',
        'func continueDragging()',
        'private func finishSystemDragIfReleased()',
        'func cancelPointerGesture()',
        'private static func appKitFrame(',
    ]
    if 'private func currentWindowServerFrame()' in panel:
        markers.append('private func currentWindowServerFrame()')
    methods = '\n'.join(declaration(panel, marker) for marker in markers)
    methods = methods.replace('NSEvent.mouseLocation', 'pointer').replace(
        'NSEvent.pressedMouseButtons', 'buttons')
    views = '\n'.join(declaration(source, marker) for marker in [
        'private final class MacOSDesktopPetContentView',
        'private final class MacOSDesktopPetBubbleView',
        'private enum MacOSDesktopAvatarTapRegion',
    ])
    swift = r'''
import AppKit
import QuartzCore
class MacOSAvatarAlphaHitTest {
  func contains(_ point: NSPoint, in rect: NSRect) -> Bool { rect.contains(point) }
  func replaceImage(_ image: CGImage?) {}
}
extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
var checks = 0
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
  checks += 1
  if !condition { failures.append(message) }
}
class MacOSDesktopPetPanel: NSPanel {
  static let basePanelSize = NSSize(width: 300, height: 420)
  static let baseAvatarHeight: CGFloat = 280
  var petContentView: MacOSDesktopPetContentView {
    contentView as! MacOSDesktopPetContentView
  }
  var pointer = NSPoint.zero
  var buttons = 1
  var pointerGesture: PointerGesture?
  var isDraggingPet = false
  var dragCompletionTimer: Timer?
  var dragPanelSizeBeforeTracking: NSSize?
  var visibilityGeneration = 1
  var dragThreshold: CGFloat = 6
  var starts = 0
  var expectedAvatar = NSRect.zero
  override func constrainFrameRect(_ rect: NSRect, to screen: NSScreen?) -> NSRect { rect }
  override func performDrag(with event: NSEvent) {
    starts += 1
    verifyPresentation("before Window Server starts")
  }
  func finishSpatialDrop() {}
  func updateMousePassthrough() {}
  func endDragging(with event: NSEvent) { cancelPointerGesture() }
  func presentContextMenu(event: NSEvent, from view: NSView) {}
  func verifyPresentation(_ phase: String) {
    let root = petContentView.layer!
    let avatar = root.sublayers!.first!
    check(root.presentation()?.bounds.size == frame.size,
      "\(phase): rendered height must already match window height \(frame.height)")
    check(avatar.presentation()?.frame == expectedAvatar,
      "\(phase): rendered avatar must keep its original size and bottom anchor")
    check(avatar.presentation()?.contents != nil,
      "\(phase): avatar image must remain present")
  }
__METHODS__
}
__VIEWS__
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let pixels = CGContext(data: nil, width: 160, height: 280,
  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
pixels.setFillColor(NSColor.systemBlue.cgColor)
pixels.fill(CGRect(x: 0, y: 0, width: 160, height: 280))
let image = pixels.makeImage()!
for scale: CGFloat in [1.2, 1.8, 2.4, 3.0] {
  let size = NSSize(width: 300 * scale, height: 420 * scale)
  let panel = MacOSDesktopPetPanel(contentRect: NSRect(x: 250, y: 80,
    width: size.width, height: size.height),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  panel.isOpaque = false
  panel.backgroundColor = .clear
  panel.hasShadow = false
  panel.animationBehavior = .none
  panel.isMovable = false
  let view = MacOSDesktopPetContentView(frame: NSRect(origin: .zero, size: size),
    visualScale: scale)
  panel.contentView = view
  view.setAvatarImage(image)
  view.showBubble(text: "A reply arriving during dragging stays above the avatar.")
  panel.orderFrontRegardless()
  view.layoutSubtreeIfNeeded()
  CATransaction.flush()
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
  panel.expectedAvatar = NSRect(x: 70 * scale, y: 0,
    width: 160 * scale, height: 280 * scale)
  for cycle in 0..<2 {
    let before = panel.frame
    let point = NSPoint(x: size.width / 2, y: 140 * scale)
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil,
      eventNumber: cycle + 1, clickCount: 1, pressure: 1)!
    panel.pointer = panel.convertPoint(toScreen: point)
    panel.buttons = 1
    panel.beginDragging(with: event)
    panel.verifyPresentation("mouse down")
    check(panel.frame == before, "mouse down must not resize or reposition")
    panel.pointer.y += 3
    panel.continueDragging()
    check(panel.frame == before, "movement below threshold must not resize")
    panel.pointer.y += 30
    panel.continueDragging()
    check(panel.frame.origin == before.origin, "compacting must not move the window")
    // A real native drag renders the compact backing before mouse-up arrives.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    view.showBubble(text: "A new reply while the window is compact.")
    let drop = NSPoint(x: before.minX + 20, y: before.minY + 30)
    panel.setFrameOrigin(drop)
    // This fixture moves from AppKit; submit that move to emulate a position
    // already applied by Window Server during real native tracking.
    CATransaction.flush()
    panel.buttons = 0
    if cycle == 0 {
      panel.finishSystemDragIfReleased()
    } else {
      panel.cancelPointerGesture()
    }
    panel.verifyPresentation("immediately after release/cancel")
    check(panel.frame == NSRect(origin: drop, size: size),
      "restoring headroom must retain the final two-dimensional position")
    check(view.subviews.first!.frame.minY >= panel.expectedAvatar.maxY,
      "incoming bubble must stay above the avatar through resizing")
  }
  check(panel.starts == 2, "each gesture hands off exactly once")
  panel.orderOut(nil)
}
print(String(data: try! JSONSerialization.data(withJSONObject:
  ["checks": checks, "failures": failures], options: [.prettyPrinted, .sortedKeys]),
  encoding: .utf8)!)
exit(failures.isEmpty ? 0 : 1)
'''.replace('__METHODS__', methods).replace('__VIEWS__', views)
    with tempfile.TemporaryDirectory(prefix='maaso-drag-presentation-') as temp:
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
