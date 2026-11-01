#!/usr/bin/env python3
"""Run production exit guards on real, transparent/offscreen AppKit windows.

Flutter channel value objects and its asynchronous terminate response are test
stand-ins. No Flutter engine, Unity process, user window, or account is touched.
"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "macos/Runner/AppDelegate.swift"
MAIN = ROOT / "macos/Runner/MainFlutterWindow.swift"
PET = ROOT / "macos/Runner/MacOSUnityAvatarPortal.swift"


def declaration(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    return source[start:cursor]


PREAMBLE = r'''
import Cocoa

final class FlutterMethodCall {
  let method: String
  let arguments: Any?
  init(_ method: String, _ arguments: Any? = nil) {
    self.method = method
    self.arguments = arguments
  }
}
typealias FlutterResult = (Any?) -> Void
let FlutterMethodNotImplemented = NSObject()
final class FlutterError {
  let code: String
  init(code: String, message: String?, details: Any?) { self.code = code }
}
class FlutterAppDelegate: NSObject {
  static var reply = NSApplication.TerminateReply.terminateCancel
  static var calls = 0
  static var windowsWereHidden = false
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Self.calls += 1
    Self.windowsWereHidden = sender.windows.allSatisfy { !$0.isVisible }
    return Self.reply
  }
}
final class FixtureCompanionBridge { var isPetVisible = false }
'''

CHECKS = r'''
var checkCount = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  checkCount += 1
  if !condition() { failures += 1; fputs("FAIL: \(label)\n", stderr) }
}
func configure(_ window: NSWindow) {
  window.isReleasedWhenClosed = false
  window.alphaValue = 0
  window.animationBehavior = .none
  window.ignoresMouseEvents = true
  window.setFrame(NSRect(x: -30000, y: -30000, width: 80, height: 80), display: false)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let closeWindow = FixtureMainWindow(contentRect: .zero, styleMask: .borderless,
                                     backing: .buffered, defer: false)
configure(closeWindow)
closeWindow.setIsVisible(true)
check(closeWindow.isVisible, "ordinary main window can show before quit")
closeWindow.close()
check(!MaasoApplicationExitPresentation.isExiting,
      "normal red-button close never begins application exit")

let main = FixtureMainWindow(contentRect: .zero, styleMask: .borderless,
                             backing: .buffered, defer: false)
let pet = FixturePetPanel(contentRect: .zero, styleMask: .borderless,
                          backing: .buffered, defer: false)
let auxiliary = NSPanel(contentRect: .zero, styleMask: .borderless,
                        backing: .buffered, defer: false)
for window in [main, pet, auxiliary] { configure(window) }
main.setIsVisible(true)
pet.orderFrontRegardless()
auxiliary.orderFrontRegardless()
check(main.isVisible && pet.isVisible && auxiliary.isVisible,
      "main, pet and auxiliary have real ordered AppKit windows")
var resultCount = 0
var lastResult: Any?
let result: FlutterResult = { resultCount += 1; lastResult = $0 }
MaasoApplicationExitPresentation.handle(FlutterMethodCall("resetExit"), result: result)
check(lastResult as AnyObject? === FlutterMethodNotImplemented,
      "no reset method is exposed")
check(!MaasoApplicationExitPresentation.isExiting, "unknown method cannot begin exit")
MaasoApplicationExitPresentation.handle(FlutterMethodCall("beginExit", ["reset": true]), result: result)
check((lastResult as? FlutterError)?.code == "invalid_application_exit_arguments",
      "beginExit rejects arguments")
check(!MaasoApplicationExitPresentation.isExiting, "invalid request cannot hide the app")

// Model the exact window_manager show scheduling: a queued focus can arrive
// after the coordinator has started account teardown.
var queuedCallbackRan = false
DispatchQueue.main.async {
  main.setIsVisible(true)
  main.makeKeyAndOrderFront(nil)
  pet.orderFrontRegardless()
  queuedCallbackRan = true
}
if CommandLine.arguments.contains("--cmd-q") {
  let delegate = FixtureAppDelegate()
  check(delegate.applicationShouldTerminate(application) == .terminateCancel,
        "first Flutter asynchronous exit response remains cancel")
  check(FlutterAppDelegate.windowsWereHidden,
        "native quit hides every window before asking Flutter to drain")
  check(MaasoApplicationExitPresentation.isExiting,
        "Flutter protocol cancel does not clear the exit latch")
  FlutterAppDelegate.reply = .terminateNow
  check(delegate.applicationShouldTerminate(application) == .terminateNow,
        "second native quit preserves Flutter completion reply")
  check(FlutterAppDelegate.calls == 2, "both native requests reach original termination handler")
} else {
  MaasoApplicationExitPresentation.handle(FlutterMethodCall("beginExit"), result: result)
  check(lastResult == nil, "tray beginExit succeeds with void response")
}
check(MaasoApplicationExitPresentation.isExiting, "explicit quit latches presentation")
check([main, pet, auxiliary].allSatisfy { !$0.isVisible },
      "all existing app windows are hidden synchronously")
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
check(queuedCallbackRan, "late window_manager and pet callback actually ran")
check(!main.isVisible && !pet.isVisible, "late show callbacks cannot reveal draining UI")
main.order(.above, relativeTo: 0)
pet.order(.below, relativeTo: 0)
check(!main.isVisible && !pet.isVisible, "direct window ordering cannot bypass quit latch")
main.order(.out, relativeTo: 0)
pet.order(.out, relativeTo: 0)
check(!main.isVisible && !pet.isVisible, "explicit hide is still accepted during cleanup")
let latePet = FixturePetPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: false)
configure(latePet)
latePet.orderFrontRegardless()
check(!latePet.isVisible, "new pet panel created during cleanup stays hidden")
MaasoApplicationExitPresentation.handle(FlutterMethodCall("beginExit", NSNull()), result: result)
check(lastResult == nil && MaasoApplicationExitPresentation.isExiting,
      "beginExit is idempotent and null-compatible")
MaasoApplicationExitPresentation.handle(FlutterMethodCall("resetExit"), result: result)
check(MaasoApplicationExitPresentation.isExiting, "later reset request cannot unlock presentation")
print("\(checkCount) checks, \(failures) failures (real NSWindow/NSPanel; production Swift guards)")
exit(failures == 0 ? 0 : 1)
'''


@unittest.skipUnless(sys.platform == "darwin", "requires macOS AppKit and Swift")
class ApplicationExitPresentationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="maaso-native-exit-test-")
        cls.executable = Path(cls.temp.name) / "exit-guard"
        app = APP.read_text()
        main = MAIN.read_text()
        pet = PET.read_text()
        main_methods = [
            "override func setIsVisible(",
            "override func makeKeyAndOrderFront(",
            "override func order(",
            "private func applyUnifiedTitlebarAppearance(",
            "override func close(",
        ]
        swift = PREAMBLE + declaration(app, "enum MaasoApplicationExitPresentation")
        swift += "\nclass FixtureMainWindow: NSWindow {\n"
        swift += "var desktopCompanionBridge: FixtureCompanionBridge?\n"
        swift += "\n".join(declaration(main, method) for method in main_methods) + "\n}\n"
        swift += "class FixturePetPanel: NSPanel {\n"
        swift += declaration(pet, "override func orderFrontRegardless(") + "\n"
        swift += declaration(pet, "override func order(") + "\n}\n"
        swift += "class FixtureAppDelegate: FlutterAppDelegate {\n"
        swift += declaration(app, "override func applicationShouldTerminate(") + "\n}\n"
        swift += CHECKS
        source = Path(cls.temp.name) / "main.swift"
        source.write_text(swift)
        subprocess.run([
            "xcrun", "swiftc", "-module-cache-path", str(Path(cls.temp.name) / "cache"),
            str(source), "-o", str(cls.executable),
        ], check=True, timeout=90)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_guard(self, *arguments):
        result = subprocess.run(
            [str(self.executable), *arguments], text=True, capture_output=True, timeout=20
        )
        print(result.stdout.strip())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tray_quit_hides_and_fences_real_windows(self):
        self.run_guard()

    def test_cmd_q_hides_before_flutter_async_exit_and_stays_latched(self):
        self.run_guard("--cmd-q")


if __name__ == "__main__":
    unittest.main(verbosity=2)
