#!/usr/bin/env python3
"""Compile and run the production desktop-pet geometry without Flutter or Unity.

Only access control is removed from extracted Swift helpers. Display/window
enumeration is replaced with fixtures; their geometry and snap calculations are
the production code. NSScreen is read once to report the real local work area.
An alternate source path allows an unchanged pre-fix snapshot as a red control.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private ", "", 1)


def run(source_path):
    source = source_path.read_text()
    panel = source[source.index("private final class MacOSDesktopPetPanel") :]
    markers = [
        "private static func panelSize(",
        "private static func horizontalVisibleInset(",
        "private static func normalizedPosition(",
        "private static func origin(",
        "private static func clampedOrigin(\n    _ proposed: NSPoint,\n    panelSize: NSSize,",
        "private static func monitor(",
        "private static func intersectionArea(",
        "private static func mainMonitor(",
        "private static func snapCandidates(",
    ]
    for optional in ("visibleAvatarHeight", "visibleAvatarFrame"):
        marker = f"private static func {optional}("
        if marker in panel:
            markers.append(marker)
    constants = re.findall(
        r"  private static let base(?:PanelSize|AvatarWidth|AvatarHeight)[^\n]*",
        panel,
    )
    helpers = "\n".join(declaration(panel, marker) for marker in markers)
    harness = r'''
import AppKit

struct MacOSDesktopPetMonitor {
  let displayID: CGDirectDisplayID
  let id: String
  let frame: NSRect
  let visibleFrame: NSRect
}
enum MacOSDesktopPetSpatialEdge { case top, bottom, left, right }
enum MacOSDesktopPetSpatialAttachmentKind { case workAreaEdge, windowTop }
struct MacOSDesktopPetSpatialAttachment {
  let kind: MacOSDesktopPetSpatialAttachmentKind
  let targetID: String
  let edge: MacOSDesktopPetSpatialEdge
}
struct MacOSDesktopPetSnapCandidate {
  let attachment: MacOSDesktopPetSpatialAttachment
  let origin: NSPoint
  let distance: CGFloat
}
struct MacOSDesktopPetForeignWindow {
  let id: String
  let frame: NSRect
}
extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
enum DesktopGeometry {
  // OS enumeration alone is stubbed; all geometry below is extracted verbatim.
  static var windows: [MacOSDesktopPetForeignWindow] = []
  static func eligibleForeignWindows(on monitor: MacOSDesktopPetMonitor,
    panelSize: NSSize, windowInfo: [[String: Any]]? = nil
  ) -> [MacOSDesktopPetForeignWindow] { windows }
__CONSTANTS__
__HELPERS__
}

var checked = 0
var failures: [String] = []
func check(_ condition: Bool, _ description: String) {
  checked += 1
  if !condition { failures.append(description) }
}
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000001 }
let size = DesktopGeometry.panelSize(visualScale: 1.8)
let work = NSRect(x: 0, y: 24, width: 1440, height: 720)
let moved = DesktopGeometry.clampedOrigin(NSPoint(x: 320, y: 180),
  panelSize: size, visibleFrame: work)
check(close(moved.x, 320) && close(moved.y, 180),
  "default 1.8 scale must retain both x=320 and y=180 on a 720pt work area")

let workAreas = [work,
  NSRect(x: -1920, y: -120, width: 1920, height: 1056),
  NSRect(x: 160, y: 1100, width: 1280, height: 976),
  NSRect(x: -720, y: -1280, width: 720, height: 1240)]
for scale: CGFloat in [1.2, 1.8, 2.4, 3.0] {
  let panelSize = DesktopGeometry.panelSize(visualScale: scale)
  let avatarWidth = 160 * scale
  let avatarHeight = 280 * scale
  let inset = (panelSize.width - avatarWidth) / 2
  for area in workAreas {
    for x: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
      for y: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
        let position = DesktopGeometry.origin(normalizedX: x, normalizedY: y,
          panelSize: panelSize, visibleFrame: area)
        let expectedY = area.minY + max(0, area.height - avatarHeight) * (1 - y)
        check(close(position.y, expectedY), "visible-height Y mapping scale=\(scale) y=\(y) area=\(area)")
        check(position.x + inset >= area.minX - 0.000001 &&
          position.x + inset + avatarWidth <= area.maxX + 0.000001,
          "visible avatar stays within horizontal work area")
        check(position.y >= area.minY - 0.000001 && position.y.isFinite,
          "feet remain visible, including oversized avatars")
        if avatarHeight <= area.height {
          check(position.y + avatarHeight <= area.maxY + 0.000001,
            "visible head stays below top boundary")
        }
        let normalized = DesktopGeometry.normalizedPosition(origin: position,
          panelSize: panelSize, visibleFrame: area)
        check(close(normalized.x, x), "X round trip")
        check(close(normalized.y, avatarHeight < area.height ? y : 0), "Y round trip or zero travel")
      }
    }
    let clamped = DesktopGeometry.clampedOrigin(NSPoint(x: area.maxX + 1000, y: area.maxY + 1000),
      panelSize: panelSize, visibleFrame: area)
    check(close(clamped.x + inset + avatarWidth, area.maxX), "right edge clamps visible width")
    check(close(clamped.y, area.minY + max(0, area.height - avatarHeight)),
      "top edge clamps visible height, excluding bubble headroom")
  }
}

let lower = MacOSDesktopPetMonitor(displayID: CGMainDisplayID(), id: "lower",
  frame: NSRect(x: 0, y: 0, width: 1440, height: 800),
  visibleFrame: NSRect(x: 0, y: 24, width: 1440, height: 752))
let upper = MacOSDesktopPetMonitor(displayID: CGMainDisplayID() + 1, id: "upper",
  frame: NSRect(x: 0, y: 800, width: 1440, height: 500),
  visibleFrame: NSRect(x: 0, y: 800, width: 1440, height: 476))
let left = MacOSDesktopPetMonitor(displayID: CGMainDisplayID() + 2, id: "left",
  frame: NSRect(x: -1440, y: -160, width: 1440, height: 900),
  visibleFrame: NSRect(x: -1440, y: -136, width: 1440, height: 852))
let screens = [lower, upper, left]
__AVATAR_FRAME_CHECKS__
check(DesktopGeometry.monitor(for: NSRect(x: 200, y: 900, width: 600, height: 150),
  monitors: screens)?.id == "upper", "foreign-window selection retains its complete window geometry")
check(DesktopGeometry.monitor(for: NSRect(x: 5000, y: 5000, width: 100, height: 100),
  monitors: screens)?.id == "lower", "removed/offscreen monitor falls back to main")
check(DesktopGeometry.monitor(for: .zero, monitors: []) == nil, "empty monitor set remains safe")

let snapped = DesktopGeometry.snapCandidates(proposedOrigin: NSPoint(x: 220, y: 260),
  panelSize: size, monitor: lower)
let top = snapped.first { $0.attachment.edge == .top }
let bottom = snapped.first { $0.attachment.edge == .bottom }
check(top != nil && close(top!.origin.y + 504, lower.visibleFrame.maxY), "top snap uses visible head")
check(bottom != nil && close(bottom!.origin.y, lower.visibleFrame.minY), "bottom snap uses feet")
DesktopGeometry.windows = [MacOSDesktopPetForeignWindow(id: "window",
  frame: NSRect(x: 120, y: 40, width: 900, height: 210))]
let windowSnap = DesktopGeometry.snapCandidates(proposedOrigin: NSPoint(x: 220, y: 250),
  panelSize: size, monitor: lower).first { $0.attachment.kind == .windowTop }
check(windowSnap != nil && close(windowSnap!.origin.y, 250), "window-top feet at 250pt remain attachable")

var actualScreens: [[String: Any]] = []
for screen in NSScreen.screens {
  let visible = screen.visibleFrame
  let wantedY = visible.minY + max(0, visible.height - 504) / 2
  let moved = DesktopGeometry.clampedOrigin(NSPoint(x: visible.midX, y: wantedY),
    panelSize: size, visibleFrame: visible)
  if visible.height > 504 { check(close(moved.y, wantedY), "real NSScreen allows default-scale vertical movement") }
  actualScreens.append(["frame": NSStringFromRect(screen.frame),
    "visibleFrame": NSStringFromRect(visible), "defaultAvatarHeight": 504,
    "defaultPanelHeight": 756, "oldVerticalTravel": max(0, visible.height - 756),
    "newVerticalTravel": max(0, visible.height - 504), "testedY": moved.y])
}
let report: [String: Any] = ["checks": checked, "failed": failures.count,
  "failureExamples": Array(failures.prefix(12)), "actualScreens": actualScreens,
  "scope": "production Swift geometry; no NSPanel, user drag, Flutter or Unity runtime started"]
print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
  encoding: .utf8)!)
exit(failures.isEmpty ? 0 : 1)
'''
    avatar_checks = ""
    if "private static func visibleAvatarFrame(" in panel:
        avatar_checks = r'''
// A small avatar near the top has transparent headroom on the upper display.
let smallPanel = NSRect(x: 300, y: 776 - 336, width: 360, height: 504)
let visibleAvatar = DesktopGeometry.visibleAvatarFrame(for: smallPanel)
check(close(visibleAvatar.height, 336) && close(visibleAvatar.minY, smallPanel.minY),
  "visible frame excludes the transparent top reserve")
check(DesktopGeometry.monitor(for: visibleAvatar, monitors: screens)?.id == "lower",
  "transparent headroom cannot change the persisted/handoff monitor")
let negativePanel = NSRect(x: -1300, y: 40, width: 540, height: 756)
check(DesktopGeometry.monitor(for: DesktopGeometry.visibleAvatarFrame(for: negativePanel),
  monitors: screens)?.id == "left", "negative-origin monitor selection")
'''
    harness = harness.replace("__CONSTANTS__", "\n".join(constants).replace("private ", ""))
    harness = harness.replace("__HELPERS__", helpers).replace("__AVATAR_FRAME_CHECKS__", avatar_checks)
    with tempfile.TemporaryDirectory(prefix="maaso-desktop-geometry-") as directory:
        directory = Path(directory)
        swift = directory / "main.swift"
        binary = directory / "geometry-test"
        swift.write_text(harness)
        subprocess.run(
            ["xcrun", "swiftc", "-module-cache-path", str(directory / "module-cache"),
             str(swift), "-o", str(binary)], check=True,
        )
        result = subprocess.run([str(binary)], text=True, capture_output=True)
        if result.stderr:
            print(result.stderr)
        report = json.loads(result.stdout)
        report["source"] = str(source_path.resolve())
        print(json.dumps(report, indent=2))
        return result.returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2]
                        / "macos/Runner/MacOSUnityAvatarPortal.swift")
    raise SystemExit(run(parser.parse_args().source))
