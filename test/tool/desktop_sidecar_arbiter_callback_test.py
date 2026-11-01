#!/usr/bin/env python3
"""Run the production macOS result gate on real Unity EditMode callbacks.

First run DesktopUnitySidecarArbiterTests in Unity. Its synthetic receiver
receipts are written under the OS temporary directory; no account data or
running application state is used by this test.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

from native_source_helpers import swift_function

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", type=Path, required=True)
    args = parser.parse_args()
    if not args.results.is_file():
        parser.error("Run DesktopUnitySidecarArbiterTests first; actual receiver callbacks are required.")
    mac = (ROOT / "macos/Runner/MacOSUnityAvatarPortal.swift").read_text()
    constants = mac[mac.index("  private static let avatarArbiterChannels:"):
                    mac.index("  private static func isAvatarArbiterMethod(")]
    functions = "\n".join(swift_function(mac, marker) for marker in [
        "private static func normalizeJSON(", "private static func isValidAvatarResult(",
        "private static func isAvatarArbiterMethod(", "private static func isValidAvatarArbiterResult(",
        "private static func exactInteger(", "private static func identifier(_ raw: Any?, maximum: Int)",
        "private static func token(", "private static func lowerHex(",
    ])
    callback = swift_function(mac, "private func acceptAvatarResult(").replace("private func", "func", 1)
    room_gate = swift_function(mac, "private enum UnityAgentSpacePayload")
    source = "import Foundation\nimport CoreFoundation\nimport Dispatch\n" + room_gate + "\n" + r'''
final class Channel {
    var values: [[String: Any]] = []
    func invokeMethod(_ method: String, arguments: Any?) {
        precondition(method == "commandResult", "Unexpected Flutter callback method")
        values.append(arguments as! [String: Any])
    }
}
struct Bridge {
    let avatarChannel = Channel()
    static let maximumAvatarArbiterJSONBytes = 256 * 1024
''' + constants + functions + "\n" + callback + "\n}\n" + r'''
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let receipts = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
precondition(receipts.count == 2, "Need command and reset receipts from the real receiver")
let bridge = Bridge()
for receipt in receipts {
    bridge.acceptAvatarResult(receipt)
    precondition(bridge.avatarChannel.values.count > 0, "Native gate dropped the receiver callback")
    let actual = bridge.avatarChannel.values.last!
    precondition(NSDictionary(dictionary: actual).isEqual(to: receipt), "Native bridge changed receipt fields")
    let count = bridge.avatarChannel.values.count
    var malformed = receipt
    malformed.removeValue(forKey: "commitToken")
    bridge.acceptAvatarResult(malformed)
    precondition(bridge.avatarChannel.values.count == count, "Missing commit fence was forwarded")
    malformed = receipt
    malformed["unexpected"] = true
    bridge.acceptAvatarResult(malformed)
    precondition(bridge.avatarChannel.values.count == count, "Unknown receipt field was forwarded")
    malformed = receipt
    malformed["payloadSha256"] = "not-a-digest"
    bridge.acceptAvatarResult(malformed)
    precondition(bridge.avatarChannel.values.count == count, "Malformed digest was forwarded")
}
precondition(bridge.avatarChannel.values.count == 2)
precondition(Set(bridge.avatarChannel.values.map { $0["method"] as! String }) ==
             Set(["avatarArbiterCommand", "avatarArbiterReset"]))
print("Native arbiter callbacks: 2 actual receiver receipts forwarded unchanged; 6 malformed receipts rejected")
'''
    with tempfile.TemporaryDirectory(prefix="maaso-arbiter-callback-") as temporary:
        folder = Path(temporary)
        swift = folder / "main.swift"
        binary = folder / "callback"
        swift.write_text(source)
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(folder / "cache"),
                        str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(args.results)], check=True)


if __name__ == "__main__":
    main()
