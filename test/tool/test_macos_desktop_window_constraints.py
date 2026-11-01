#!/usr/bin/env python3
"""Exercise the production NSPanel constraint override against actual AppKit.

The test window is fully transparent, nonactivating and ignores mouse events.
It is ordered in briefly because hidden NSWindows do not apply AppKit's clamp.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def extract_override(source):
    panel = source[source.index('private final class MacOSDesktopPetPanel'):]
    marker = 'override func constrainFrameRect('
    if marker not in panel:
        return ''
    start = panel.index(marker)
    end = panel.index('{', start) + 1
    depth = 1
    while depth:
        depth += (panel[end] == '{') - (panel[end] == '}')
        end += 1
    return panel[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=Path('macos/Runner/MacOSUnityAvatarPortal.swift'))
    args = parser.parse_args()
    override = extract_override(args.source.read_text())
    harness = r'''
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
guard let screen = NSScreen.main else { print("No graphical macOS session"); exit(77) }
class ProductionPanel: NSPanel { __OVERRIDE__ }
let area = screen.visibleFrame
let height = area.height + 40
let size = NSSize(width: 720, height: height)
let avatarHeight = height * 280 / 420
let low = area.minY
let high = area.maxY - avatarHeight
let panel = ProductionPanel(contentRect: NSRect(origin: NSPoint(x: area.midX - 360, y: low), size: size),
  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.alphaValue = 0
panel.ignoresMouseEvents = true
panel.isReleasedWhenClosed = false
panel.orderFrontRegardless()
var checks = 0
var failures: [String] = []
func check(_ expected: NSPoint, _ label: String) {
  checks += 1
  if abs(panel.frame.minX - expected.x) > 0.01 || abs(panel.frame.minY - expected.y) > 0.01 {
    failures.append("\(label): expected \(expected), actual \(panel.frame.origin)")
  }
}
for fraction: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
  let target = NSPoint(x: area.midX - 360 + fraction * 100, y: (low + fraction * (high - low)).rounded(.down))
  panel.setFrameOrigin(target)
  check(target, "visible dragging \(fraction)")
}
let restored = NSPoint(x: area.midX - 360, y: ((low + high) / 2).rounded(.down))
panel.setFrame(NSRect(origin: restored, size: size), display: false)
check(restored, "restore position")
for x in [screen.frame.minX - size.width - 1, screen.frame.maxX + 1] {
  let target = NSPoint(x: x, y: restored.y)
  panel.setFrameOrigin(target)
  check(target, "handoff keeps Y outside screen")
}
panel.orderOut(nil)
let result: [String: Any] = ["checks": checks, "failures": failures,
  "productionOverridePresent": __PRESENT__, "visibleHeight": area.height,
  "panelHeight": size.height, "avatarHeight": avatarHeight]
let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
exit(failures.isEmpty ? 0 : 1)
'''.replace('__OVERRIDE__', override).replace('__PRESENT__', str(bool(override)).lower())
    with tempfile.TemporaryDirectory(prefix='maaso-appkit-test-') as work:
        source = Path(work) / 'main.swift'
        binary = Path(work) / 'native_test'
        source.write_text(harness)
        subprocess.run(['xcrun', 'swiftc', str(source), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr)
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
