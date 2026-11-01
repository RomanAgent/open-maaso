#!/usr/bin/env python3
"""Exercise production gesture dispatch without posting mouse events.

Only physical pointer reads and the Window Server call are replaced by spies.
The real Timer lifetime, threshold, cleanup and completion code are compiled.
"""
from pathlib import Path
import subprocess
import tempfile


def declaration(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '', 1)


def main():
    source = Path('macos/Runner/MacOSUnityAvatarPortal.swift').read_text()
    panel = source[source.index('private final class MacOSDesktopPetPanel'):]
    members = '\n'.join(declaration(panel, marker) for marker in [
        'private struct PointerGesture',
        'private static func visibleAvatarHeight(',
        'func beginDragging(with event: NSEvent)',
        'func continueDragging()',
        'private func finishSystemDragIfReleased()',
        'func cancelPointerGesture()',
    ])
    members = members.replace('NSEvent.mouseLocation', 'pointer').replace('NSEvent.pressedMouseButtons', 'buttons')
    swift = r'''
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
class Content: NSView {
  func containsVisibleAvatar(at point: NSPoint) -> Bool { true }
}
class Probe: NSPanel {
  static let basePanelSize = NSSize(width:300,height:420)
  static let baseAvatarHeight: CGFloat = 280
  let petContentView = Content()
  var pointer = NSPoint.zero
  var buttons = 1
  var pointerGesture: PointerGesture?
  var isDraggingPet = false
  var dragCompletionTimer: Timer?
  var dragPanelSizeBeforeTracking: NSSize?
  var visibilityGeneration = 1
  var dragThreshold: CGFloat = 6
  var starts = 0
  var drops = 0
  var lastEvent: NSEvent?
  var passthroughUpdates = 0
  var shown = true
  override var isVisible: Bool { shown }
  override func performDrag(with event: NSEvent) { starts += 1; lastEvent = event }
  func finishSpatialDrop() { drops += 1 }
  func updateMousePassthrough() { passthroughUpdates += 1 }
  func currentWindowServerFrame() -> NSRect? { nil }
__MEMBERS__
}
let panel = Probe(contentRect: NSRect(x:0,y:0,width:540,height:756), styleMask:.borderless,backing:.buffered,defer:false)
let event = NSEvent.mouseEvent(with:.leftMouseDown, location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1)!
var checks = 0
var failures: [String] = []
func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append(label) } }
func begin() {
 panel.pointer = .zero; panel.buttons = 1
 panel.beginDragging(with:event)
 if let g=panel.pointerGesture {
  panel.pointerGesture=Probe.PointerGesture(downUptime:g.downUptime,mouseStart:.zero,mouseDownEvent:g.mouseDownEvent)
 }
}
begin()
panel.pointer = NSPoint(x:3,y:2);panel.continueDragging()
check(panel.starts == 0 && !panel.isDraggingPet, "a short tap must not start a system drag")
panel.pointer = NSPoint(x:0,y:20);panel.continueDragging()
check(panel.starts == 1 && panel.lastEvent === event && panel.isMovable, "vertical drag passes the original mouse-down to Window Server")
check(panel.frame.height == 504 && panel.frame.width == 540 && Probe.visibleAvatarHeight(panelSize:panel.frame.size) == 504, "native tracking bounds exclude headroom without changing avatar scale")
let firstTimer = panel.dragCompletionTimer
for i in 1...50 { panel.pointer = NSPoint(x:i,y:i*2); panel.continueDragging() }
check(panel.starts == 1 && panel.dragCompletionTimer === firstTimer, "subsequent drag events never fight or restart system movement")
panel.finishSystemDragIfReleased()
check(panel.drops == 0 && panel.pointerGesture != nil, "holding the physical button must not end the drag")
panel.setFrameOrigin(NSPoint(x:32,y:180))
panel.buttons = 2;panel.finishSystemDragIfReleased()
check(panel.drops == 1 && panel.pointerGesture == nil && panel.dragCompletionTimer == nil && firstTimer?.isValid == false && !panel.isMovable, "lost mouse-up still finalizes exactly once and releases capture")
check(panel.frame.origin == NSPoint(x:32,y:180) && panel.frame.size == NSSize(width:540,height:756) && panel.dragPanelSizeBeforeTracking == nil, "restoring bubble headroom preserves the final two-dimensional drop position")
panel.finishSystemDragIfReleased()
check(panel.drops == 1, "duplicate completion must not snap or persist again")
begin();panel.pointer=NSPoint(x:20,y:0);panel.buttons=0;panel.continueDragging()
check(panel.starts == 1 && panel.pointerGesture == nil, "a queued event after physical release must not start a drag")
begin();panel.pointer = NSPoint(x:20,y:0);panel.continueDragging()
let cancelled = panel.dragCompletionTimer
panel.cancelPointerGesture();panel.buttons=0;panel.finishSystemDragIfReleased()
check(panel.drops == 1 && cancelled?.isValid == false && !panel.isDraggingPet, "hide/account retirement cancels without a later stale drop")
check(panel.frame.height == 756 && panel.dragPanelSizeBeforeTracking == nil, "cancellation restores full dimensions before hide")
begin();panel.pointer = NSPoint(x:0,y:20);panel.continueDragging();panel.shown=false;panel.buttons=0;panel.finishSystemDragIfReleased()
check(panel.drops == 1 && panel.pointerGesture == nil, "a hidden panel cannot inherit a late drag placement")
panel.shown=true
begin();panel.pointer=NSPoint(x:20,y:20);panel.continueDragging()
let liveTimer=panel.dragCompletionTimer
firstTimer?.fire()
check(panel.dragCompletionTimer === liveTimer && panel.pointerGesture != nil, "a stale completion timer cannot end a newer gesture")
panel.buttons=0;liveTimer?.fire()
check(panel.drops == 2 && panel.dragCompletionTimer == nil, "the live timer finalizes without an AppKit mouse-up")
begin();panel.pointer=NSPoint(x:20,y:20);panel.continueDragging()
let displacedTimer=panel.dragCompletionTimer!
let replacement=Timer(timeInterval:60,repeats:true) { _ in }
panel.dragCompletionTimer=replacement
panel.buttons=0;displacedTimer.fire()
check(!displacedTimer.isValid && panel.dragCompletionTimer === replacement && panel.pointerGesture != nil && panel.drops == 2, "a still-valid displaced timer must fail identity checking before touching a newer gesture")
panel.cancelPointerGesture()
panel.visibilityGeneration = 0;begin()
check(panel.pointerGesture == nil, "a mouse-down without a live generation must not recapture the window")
panel.visibilityGeneration=1;panel.shown=false;begin()
check(panel.pointerGesture == nil, "a late mouse-down after hiding must be ignored")
panel.shown=true;begin();panel.visibilityGeneration=0
let startsBeforeGenerationLoss=panel.starts
panel.pointer=NSPoint(x:20,y:0);panel.continueDragging()
check(panel.starts == startsBeforeGenerationLoss && panel.pointerGesture == nil, "generation loss before dispatch must not start native dragging")
let data=try! JSONSerialization.data(withJSONObject:["checks":checks,"failures":failures],options:[.prettyPrinted,.sortedKeys]);print(String(data:data,encoding:.utf8)!)
exit(failures.isEmpty ? 0 : 1)
'''.replace('__MEMBERS__', members)
    with tempfile.TemporaryDirectory(prefix='maaso-system-drag-') as temp:
        path=Path(temp)/'main.swift';path.write_text(swift); binary=Path(temp)/'native_test'
        subprocess.run(['xcrun','swiftc','-module-cache-path',str(Path(temp)/'cache'),str(path),'-o',str(binary)],check=True)
        result=subprocess.run([str(binary)],capture_output=True,text=True)
        print(result.stdout,end='')
        if result.stderr:print(result.stderr)
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
