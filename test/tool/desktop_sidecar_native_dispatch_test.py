#!/usr/bin/env python3
"""Execute production native send/dispatch/session callback fencing without IPC."""
import argparse
from pathlib import Path
import subprocess
import tempfile

from native_source_helpers import swift_function

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT / "macos/Runner/MacOSUnityAvatarPortal.swift")
    args = parser.parse_args()
    source = args.source.read_text()
    constants = source[source.index("  private static let avatarArbiterChannels:"):
                       source.index("  private static func isAvatarArbiterMethod(")]
    validators = "\n".join(swift_function(source, name) for name in [
        "private static func normalizedAvatarArguments(", "private static func normalizeJSON(",
        "private static func isAvatarArbiterMethod(", "private static func isValidAvatarArbiterArguments(",
        "private static func exactInteger(", "private static func identifier(_ raw: Any?, maximum: Int)",
        "private static func token(", "private static func lowerHex(",
    ])
    room_gate = swift_function(source, "private enum UnityAgentSpacePayload")
    methods = "\n".join(swift_function(source, name).replace("private func", "func", 1) for name in [
        "private func handleAvatar(", "private func ensureSession()", "private func handleSessionFailure(",
    ])
    sending = "\n".join(swift_function(source, name) for name in [
        "func sendAvatarCommand(", "private func enqueue(",
    ])
    program = r'''
import Foundation
import CoreFoundation
import Dispatch
__ROOM_GATE__
typealias FlutterResult = (Any?) -> Void
let FlutterMethodNotImplemented = "not-implemented"
struct FlutterMethodCall { let method: String; let arguments: Any? }
final class FlutterError {
    let code: String
    init(code: String, message: String?, details: Any?) { self.code = code }
}
struct MacOSUnitySurfaceFrame { let generation: Int }
final class Channel {
    var methods: [String] = []
    func invokeMethod(_ method: String, arguments: Any?) { methods.append(method) }
}
final class MacOSUnitySidecarSession {
    static let protocolVersion = 1
    static let maximumSequence = 0x7fff_ffff
    static let maximumFrameBytes = 64 * 1024
    let stateLock = NSLock()
    let token = String(repeating: "T", count: 43)
    var stopped = false
    var outgoingSequence = 0
    var authenticated = false
    var connectionFD: Int32 = -1
    var pendingFrames: [Data] = []
    var sendSucceeds = true
    var sentFrames: [Data] = []
    var stops = 0
    let onAvatarReady: () -> Void
    let onAvatarResult: ([String: Any]) -> Void
    let onSurface: (MacOSUnitySurfaceFrame) -> Void
    let onEvent: (String, Int) -> Void
    let onFailure: (String) -> Void
    init(onAvatarReady: @escaping () -> Void = {},
         onAvatarResult: @escaping ([String: Any]) -> Void = { _ in },
         onSurface: @escaping (MacOSUnitySurfaceFrame) -> Void = { _ in },
         onEvent: @escaping (String, Int) -> Void = { _, _ in },
         onFailure: @escaping (String) -> Void = { _ in }) throws {
        self.onAvatarReady = onAvatarReady; self.onAvatarResult = onAvatarResult
        self.onSurface = onSurface
        self.onEvent = onEvent; self.onFailure = onFailure
    }
    func start() throws {}
    func stop() { stops += 1; stopped = true }
    func sendLocked(_ frame: Data) -> Bool { sentFrames.append(frame); return sendSucceeds }
__SENDING__
}
final class Bridge {
    static let maximumAvatarJSONBytes = 32 * 1024
    static let maximumAvatarArbiterJSONBytes = 256 * 1024
    static let avatarMethods: Set<String> = ["setMouthOpen", "avatarArbiterCommand", "avatarArbiterReset"]
    var session: MacOSUnitySidecarSession?
    var sessionIdentity: UUID?
    var avatarReceiverReady = true
    var activeGeneration = 1
    var readyCount = 0
    var resultCount = 0
    var surfaceCount = 0
    var eventCount = 0
    var releaseCount = 0
    let avatarChannel = Channel()
    let portalChannel = Channel()
    func acceptAvatarReady() { readyCount += 1; avatarReceiverReady = true }
    func acceptAvatarResult(_ value: [String: Any]) { resultCount += 1 }
    func accept(frame: MacOSUnitySurfaceFrame) { surfaceCount += 1 }
    func accept(event: String, generation: Int) { eventCount += 1 }
    func releaseLease(reason: String, notifyFlutter: Bool) { releaseCount += 1 }
    static func boundedReason(_ value: String) -> String { value }
__CONSTANTS__
__VALIDATORS__
__METHODS__
}
var checks = 0
var failures: [String] = []
func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures.append(label) }
}
func outcome(_ bridge: Bridge, method: String = "setMouthOpen", arguments: [String: Any] = ["value": 0.5]) -> String? {
    var codes: [String?] = []
    bridge.handleAvatar(FlutterMethodCall(method: method, arguments: arguments)) {
        codes.append(($0 as? FlutterError)?.code)
    }
    check(codes.count == 1, "Every dispatch has exactly one immediate native result")
    return codes.first ?? nil
}
let queued = Bridge()
check(outcome(queued) == nil && queued.session!.pendingFrames.count == 1, "Valid command should queue before socket authentication")
let disconnected = Bridge()
let ended = try disconnected.ensureSession(); ended.stop()
check(outcome(disconnected) == "unity_avatar_sidecar_command_rejected", "Stopped session was acknowledged as success")
let writeFailed = Bridge()
let broken = try writeFailed.ensureSession(); broken.authenticated = true; broken.connectionFD = 1; broken.sendSucceeds = false
check(outcome(writeFailed) == "unity_avatar_sidecar_command_rejected", "Failed write was acknowledged as success")
let exhausted = Bridge()
let exhaustedSession = try exhausted.ensureSession(); exhaustedSession.outgoingSequence = Int.max
check(outcome(exhausted) == "unity_avatar_sidecar_command_rejected", "Exhausted sequence was acknowledged as success")
let boundary = try MacOSUnitySidecarSession()
let exact: Any = boundary.sendAvatarCommand(method: "avatarArbiterCommand", json: String(repeating: "x", count: 32768))
check((exact as? Bool) == true && boundary.pendingFrames.count == 1, "32KiB wire payload should remain accepted")
let tooLarge: Any = boundary.sendAvatarCommand(method: "avatarArbiterCommand", json: String(repeating: "x", count: 32769))
check((tooLarge as? Bool) == false && boundary.pendingFrames.count == 1, "Oversized payload needs an observable rejection")
let escaped: Any = boundary.sendAvatarCommand(method: "avatarArbiterCommand", json: String(repeating: "\"", count: 32768))
check((escaped as? Bool) == false && boundary.pendingFrames.count == 1, "Oversized encoded frame must fail without queueing")
let huge = Bridge()
let hugeArguments: [String: Any] = [
    "protocolVersion": 1, "requestId": "test_1", "ticket": 1, "rendererId": "test-renderer",
    "ownerToken": String(repeating: "A", count: 43), "commitToken": String(repeating: "C", count: 43),
    "accountGeneration": 1, "rendererGeneration": 1, "channel": "mouth",
    "fingerprint": "0123456789abcdef", "payloadJson": String(repeating: "x", count: 33000),
    "payloadSha256": String(repeating: "a", count: 64), "deadlineEpochMs": 2000000000000,
    "clearsChannel": false,
]
check(outcome(huge, method: "avatarArbiterCommand", arguments: hugeArguments) == "unity_avatar_sidecar_payload_too_large",
      "Oversized arbiter payload must return FlutterError instead of waiting for a receipt")
check(huge.session == nil, "Known oversized input should not start a sidecar")

let lifecycle = Bridge()
let old = try lifecycle.ensureSession()
old.onAvatarReady()
check(lifecycle.readyCount == 1, "Current ready callback was lost")
old.onFailure("sidecarDisconnected")
check(lifecycle.session == nil && old.stops == 1 && lifecycle.releaseCount == 1, "Current failure must release the old session")
let current = try lifecycle.ensureSession()
old.onAvatarReady(); old.onAvatarResult([:])
old.onSurface(MacOSUnitySurfaceFrame(generation: 1)); old.onEvent("unityCommandFailed", 1)
old.onFailure("sidecarExited")
check(lifecycle.session === current && current.stops == 0 && lifecycle.releaseCount == 1,
      "Late old failure stopped the replacement session")
check(lifecycle.readyCount == 1 && !lifecycle.avatarReceiverReady,
      "Late old ready marked the replacement receiver ready")
check(lifecycle.resultCount == 0 && lifecycle.surfaceCount == 0 && lifecycle.eventCount == 0,
      "Late callback from retired sidecar reached current state")
current.onAvatarReady(); current.onAvatarResult([:])
current.onSurface(MacOSUnitySurfaceFrame(generation: 1)); current.onEvent("active", 1)
check(lifecycle.readyCount == 2 && lifecycle.avatarReceiverReady && lifecycle.resultCount == 1 && lifecycle.surfaceCount == 1 && lifecycle.eventCount == 1,
      "Current replacement callbacks must remain active")
print("Native sidecar dispatch/session fences: \(checks) checks, \(failures.count) failures")
for value in failures { print(value) }
exit(failures.isEmpty ? 0 : 1)
'''
    for key, value in {"__ROOM_GATE__": room_gate, "__CONSTANTS__": constants, "__VALIDATORS__": validators,
                       "__METHODS__": methods, "__SENDING__": sending}.items():
        program = program.replace(key, value)
    with tempfile.TemporaryDirectory(prefix="maaso-sidecar-native-") as temporary:
        folder = Path(temporary)
        swift = folder / "main.swift"
        binary = folder / "native"
        swift.write_text(program)
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(folder / "cache"),
                        str(swift), "-o", str(binary)], check=True)
        raise SystemExit(subprocess.run([str(binary)]).returncode)


if __name__ == "__main__":
    main()
