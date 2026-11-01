import Cocoa
import FlutterMacOS

/// Explicit application exit hides presentation before account teardown starts.
/// This is a one-way latch: Flutter's first terminateCancel is its asynchronous
/// exit handshake, not permission to reveal the draining account surface again.
enum MaasoApplicationExitPresentation {
  private(set) static var isExiting = false

  static func beginExit() {
    dispatchPrecondition(condition: .onQueue(.main))
    isExiting = true
    for window in NSApp.windows {
      window.orderOut(nil)
    }
  }

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard call.method == "beginExit" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard call.arguments == nil || call.arguments is NSNull else {
      result(FlutterError(code: "invalid_application_exit_arguments",
        message: "beginExit does not accept arguments.", details: nil))
      return
    }
    beginExit()
    result(nil)
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  // Let macOS render the compiled AppIcon.icon, including its native material
  // and mask. Replacing it with an NSImage loses that layered icon metadata.

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MaasoApplicationExitPresentation.beginExit()
    return super.applicationShouldTerminate(sender)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // The normal Flutter window may be hidden while the independent desktop
    // pet and status item keep the application running. Explicit Quit still
    // terminates through window_manager.
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

}
