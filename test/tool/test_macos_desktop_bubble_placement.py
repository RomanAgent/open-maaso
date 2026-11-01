#!/usr/bin/env python3
"""Execute production pet/bubble geometry against deterministic screen bounds.

The actual Swift content-view bounds property, avatar rect, bubble placement and
panel clamping functions are compiled unchanged except for access control.
Only screen/window lookup and their coordinate conversion are fixtures; no app
window is opened, moved or activated. --source supports an unchanged red control.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

from native_source_helpers import swift_function

ROOT = Path(__file__).resolve().parents[2]


def run(source_path):
    source = source_path.read_text()
    panel = source[source.index("private final class MacOSDesktopPetPanel") :]
    content = source[source.index("private final class MacOSDesktopPetContentView") :]
    bubble = source[source.index("private final class MacOSDesktopPetBubbleView") :]
    geometry = "\n".join(
        swift_function(panel, marker).replace("private static", "static", 1)
        for marker in [
            "private static func clampedOrigin(\n    _ proposed: NSPoint,\n    panelSize: NSSize,",
            "private static func horizontalVisibleInset(",
            "private static func visibleAvatarHeight(",
        ]
    )
    constants = "\n".join(re.findall(
        r"  private static let base(?:PanelSize|AvatarWidth|AvatarHeight)[^\n]*", panel
    )).replace("private ", "")
    scales = re.search(
        r"supportedVisualScales: Set<Double> = (\[[^]]+\])", source
    ).group(1)
    properties = "\n".join(
        swift_function(content, marker).replace("private ", "", 1)
        for marker in ["private var avatarRect:", "private var bubbleLayoutBounds:"]
    )
    placement = swift_function(bubble, "func reposition(in containerBounds:")
    swift = r'''
import Foundation
import CoreGraphics
extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
enum Geometry {
__CONSTANTS__
__GEOMETRY__
}
struct ScreenFixture { let visibleFrame: NSRect }
enum NSScreen { static var main: ScreenFixture? { nil } }
final class WindowFixture {
  let frame: NSRect
  let screen: ScreenFixture?
  init(frame: NSRect, visible: NSRect) {
    self.frame = frame
    screen = ScreenFixture(visibleFrame: visible)
  }
  func convertFromScreen(_ rect: NSRect) -> NSRect {
    rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
  }
}
final class Content {
  static let baseAvatarSize = NSSize(width: 160, height: 280)
  static let baseBubbleHeadroom: CGFloat = 140
  let bounds: NSRect
  let visualScale: CGFloat
  let window: WindowFixture?
  init(bounds: NSRect, scale: CGFloat, window: WindowFixture?) {
    self.bounds = bounds; self.visualScale = scale; self.window = window
  }
  func convert(_ rect: NSRect, from: Any?) -> NSRect { rect }
__PROPERTIES__
}
final class Bubble {
  var frame: NSRect
  init(size: NSSize) { frame = NSRect(origin: .zero, size: size) }
__PLACEMENT__
}
var checks = 0
var failures: [String] = []
func check(_ condition: Bool, _ label: String) {
  checks += 1
  if !condition { failures.append(label) }
}
let screens = [NSRect(x: 0, y: 24, width: 1440, height: 876),
               NSRect(x: -1600, y: 100, width: 1600, height: 1000)]
for screen in screens {
  for scale: CGFloat in __SCALES__ {
    let size = NSSize(width: 300 * scale, height: 420 * scale)
    for x in [screen.minX - size.width, screen.midX - size.width / 2, screen.maxX] {
      for y in [screen.minY, screen.midY, screen.maxY] {
        let origin = Geometry.clampedOrigin(NSPoint(x: x, y: y), panelSize: size, visibleFrame: screen)
        let frame = NSRect(origin: origin, size: size)
        let window = WindowFixture(frame: frame, visible: screen)
        let view = Content(bounds: NSRect(origin: .zero, size: size), scale: scale, window: window)
        let actorBefore = view.avatarRect
        let layout = view.bubbleLayoutBounds
        for height: CGFloat in [46, 80, 116] {
          // The unchanged show(text:) already limits its measured width to
          // container.width - 8. Exercise that same valid size envelope.
          let width = min(272, max(72, layout.width - 8))
          let bubble = Bubble(size: NSSize(width: width, height: height))
          bubble.reposition(in: layout, above: view.avatarRect.maxY)
          let rendered = bubble.frame.offsetBy(dx: frame.minX, dy: frame.minY)
          check(screen.contains(rendered), "Offscreen caption: scale=\(scale), panel=\(frame), bubble=\(rendered)")
          check(view.avatarRect == actorBefore && window.frame == frame,
                "Bubble layout changed the avatar or panel")
          let preferred = view.avatarRect.maxY + 4
          if preferred + height <= layout.maxY - 4 {
            check(abs(bubble.frame.minY - preferred) < 0.0001, "Unclipped caption moved away from above the avatar")
          }
        }
      }
    }
  }
}
let detached = Content(bounds: NSRect(x: 0, y: 0, width: 300, height: 280), scale: 1, window: nil)
check(detached.bubbleLayoutBounds == NSRect(x: 0, y: 0, width: 300, height: 420),
      "Detached/drag headroom fallback changed")
print("Native bubble placement: \(checks) checks, \(failures.count) failures")
for failure in failures.prefix(8) { print(failure) }
exit(failures.isEmpty ? 0 : 1)
'''
    for key, value in {
        "__CONSTANTS__": constants, "__GEOMETRY__": geometry,
        "__PROPERTIES__": properties, "__PLACEMENT__": placement,
        "__SCALES__": scales,
    }.items():
        swift = swift.replace(key, value)
    with tempfile.TemporaryDirectory(prefix="maaso-bubble-placement-") as temporary:
        folder = Path(temporary)
        script = folder / "bubble.swift"
        executable = folder / "bubble"
        script.write_text(swift)
        build = subprocess.run([
            "xcrun", "swiftc", "-module-cache-path", str(folder / "cache"),
            str(script), "-o", str(executable),
        ], capture_output=True, text=True)
        if build.returncode:
            print(build.stdout + build.stderr)
            return build.returncode
        result = subprocess.run([str(executable)], capture_output=True, text=True)
        print(result.stdout + result.stderr)
        return result.returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT / "macos/Runner/MacOSUnityAvatarPortal.swift")
    raise SystemExit(run(parser.parse_args().source))
