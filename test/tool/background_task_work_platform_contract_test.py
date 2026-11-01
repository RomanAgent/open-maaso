#!/usr/bin/env python3
"""Execute the actual Swift/Kotlin host-work boundary without a player or device."""
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / "macos/Runner/MacOSUnityAvatarPortal.swift"
ANDROID = ROOT / "android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt"
SPEC = importlib.util.spec_from_file_location(
    "native_blocks", ROOT / "test/tool/agent_space_platform_contract_test.py"
)
BLOCKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BLOCKS)
block = BLOCKS.block

COMMAND_KEYS = {"requestId", "sessionId", "phase", "loadRequestId", "sequence",
                "issuedAtEpochMs", "deadlineEpochMs"}
FAILURES = {"invalid_command", "deadline_expired", "model_stale", "stale_sequence",
            "session_ended", "session_mismatch", "authority_owned", "not_ready",
            "presentation_busy", "user_pose_owned", "work_unavailable", "mutation_failed"}


class BackgroundTaskWorkPlatformContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mac = MAC.read_text()
        cls.android = ANDROID.read_text()
        cls.swift = block(cls.mac, "private enum UnityBackgroundTaskWorkPayload")
        cls.kotlin = block(cls.android, "private object UnityAvatarBackgroundTaskWorkPayload")

    def test_closed_protocol_fields_and_reasons_match_both_platforms(self):
        for source in [self.swift, self.kotlin]:
            fields = re.search(r"commandKeys[^=]*=\s*(?:setOf\()?\[?(.*?)\]?(?:\)|\])", source, re.S)
            self.assertIsNotNone(fields)
            self.assertEqual(set(re.findall(r'"([A-Za-z]+)"', fields[1])), COMMAND_KEYS)
            reasons = re.search(r"failureCodes[^=]*=\s*(?:setOf\()?\[?(.*?)\]?(?:\)|\])", source, re.S)
            self.assertEqual(set(re.findall(r'"([a-z_]+)"', reasons[1])), FAILURES)

    def test_native_dispatch_is_validated_and_never_queues_an_unready_work_start(self):
        mac_handler = block(self.mac, "private func handleAvatar(")
        self.assertIn("UnityBackgroundTaskWorkPayload.isValidArguments(arguments)", mac_handler)
        readiness = mac_handler.index("|| call.method == UnityBackgroundTaskWorkPayload.commandMethod)")
        self.assertLess(readiness, mac_handler.index("try ensureSession()"))
        send = block(self.mac, "func sendAvatarCommand(")
        enqueue = block(self.mac, "private func enqueue(")
        self.assertIn("allowPending: method != UnityBackgroundTaskWorkPayload.commandMethod", send)
        self.assertLess(enqueue.index("stateLock.lock()"), enqueue.index("allowPending ||"))
        self.assertLess(enqueue.index("allowPending ||"), enqueue.index("outgoingSequence += 1"))
        android_dispatch = block(self.android, "private fun completeBackgroundTaskWorkCommand(")
        self.assertIn("UnityAvatarBackgroundTaskWorkPayload.isValidArguments(call.arguments)", android_dispatch)
        self.assertIn("commandSink.sendTicketed(call.method, payload)", android_dispatch)
        self.assertNotIn("commandSink.send(", android_dispatch)
        self.assertIn('"setBackgroundTaskWork" -> completeBackgroundTaskWorkCommand', self.android)

    def test_old_furniture_and_loaded_work_version_are_preserved_without_self_grant(self):
        mac_result = block(self.mac, "private static func isValidAvatarResult(")
        self.assertIn("validFurnitureWorkSession(payload)", mac_result)
        self.assertIn("boundedWorkVersion(version)", mac_result)
        android_result = block(self.android, "fun emitCommandResult(")
        self.assertIn("validFurnitureWorkSession(raw)", android_result)
        self.assertIn('result["workSessionId"] = it', android_result)
        self.assertIn('boundedWorkVersion(raw.opt("backgroundTaskWorkVersion"))', android_result)
        self.assertIn('result["backgroundTaskWorkVersion"] = version', android_result)
        self.assertNotIn('result["backgroundTaskWorkVersion"] = 2', android_result)

    def test_real_swift_boundary_and_atomic_sidecar_send(self):
        send = block(self.mac, "func sendAvatarCommand(")
        enqueue = block(self.mac, "private func enqueue(")
        source = "import Foundation\nimport CoreFoundation\n" + self.swift + "\n" + r'''
final class Session {
  static let protocolVersion = 1
  static let maximumSequence = 2147483647
  static let maximumFrameBytes = 1024 * 1024
  let stateLock = NSLock()
  var stopped = false, authenticated = false
  var connectionFD: Int32 = -1
  var outgoingSequence = 1
  var token = "test"
  var pendingFrames: [Data] = [], sent: [Data] = []
  func sendLocked(_ frame: Data) -> Bool { sent.append(frame); return true }
__SEND__
__ENQUEUE__
}
var checks = 0
func check(_ condition: Bool, _ name: String) {
  checks += 1
  if !condition { fatalError(name) }
}
let id = String(repeating: "a", count: 64)
let args: [String: Any] = ["requestId": "request-1", "sessionId": id, "phase": "start",
  "loadRequestId": "load-1", "sequence": 1, "issuedAtEpochMs": 1000, "deadlineEpochMs": 11000]
check(UnityBackgroundTaskWorkPayload.isValidArguments(args), "valid start")
var end = args; end["phase"] = "end"
check(UnityBackgroundTaskWorkPayload.isValidArguments(end), "valid end")
for field in args.keys {
  var invalid = args; invalid.removeValue(forKey: field)
  check(!UnityBackgroundTaskWorkPayload.isValidArguments(invalid), "missing field")
}
for field in ["sequence", "issuedAtEpochMs", "deadlineEpochMs"] {
  for value: Any in [true, "1", 0, -1, 1.5, Double.nan, Double.infinity, 9007199254740992 as Int64] {
    var invalid = args; invalid[field] = value
    check(!UnityBackgroundTaskWorkPayload.isValidArguments(invalid), "bad integer")
  }
}
for field in ["requestId", "loadRequestId"] {
  for value in ["", " bad", "bad\n", String(repeating: "a", count: 129)] {
    var invalid = args; invalid[field] = value
    check(!UnityBackgroundTaskWorkPayload.isValidArguments(invalid), "bad id")
  }
}
for value in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63)] {
  var invalid = args; invalid["sessionId"] = value
  check(!UnityBackgroundTaskWorkPayload.isValidArguments(invalid), "bad session")
}
for value in [1000, 999, 11001] {
  var invalid = args; invalid["deadlineEpochMs"] = value
  check(!UnityBackgroundTaskWorkPayload.isValidArguments(invalid), "bad interval")
}
var extra = args; extra["gesture"] = "jump"
check(!UnityBackgroundTaskWorkPayload.isValidArguments(extra), "no gesture")
var receipt = args
receipt.removeValue(forKey: "issuedAtEpochMs"); receipt.removeValue(forKey: "deadlineEpochMs")
receipt["method"] = "setBackgroundTaskWork"; receipt["ok"] = true; receipt["code"] = ""
check(UnityBackgroundTaskWorkPayload.publicResult(receipt) != nil, "valid receipt")
for field in receipt.keys {
  var value = receipt; value.removeValue(forKey: field)
  check(UnityBackgroundTaskWorkPayload.publicResult(value) == nil, "missing receipt field")
}
for value: Any in [1, 0, "true", NSNull()] {
  var bad = receipt; bad["ok"] = value
  check(UnityBackgroundTaskWorkPayload.publicResult(bad) == nil, "strict boolean")
}
var badReceipt = receipt; badReceipt["privatePath"] = "secret"
check(UnityBackgroundTaskWorkPayload.publicResult(badReceipt) == nil, "closed result")
var refusal = receipt; refusal["ok"] = false; refusal["code"] = "unknown_failure"
check(UnityBackgroundTaskWorkPayload.publicResult(refusal) == nil, "closed code")
for code in ["invalid_command", "deadline_expired", "model_stale", "stale_sequence", "session_ended",
             "session_mismatch", "authority_owned", "not_ready", "presentation_busy", "user_pose_owned",
             "work_unavailable", "mutation_failed"] {
  refusal["code"] = code
  check(UnityBackgroundTaskWorkPayload.publicResult(refusal) != nil, "known refusal")
}
let state: [String: Any] = ["method": "backgroundTaskWorkState", "requestId": "state-1",
  "sessionId": id, "loadRequestId": "load-1", "phase": "working", "furnitureId": "desk",
  "sceneId": "coastal:room", "sequence": 2, "workSessionId": id]
check(UnityBackgroundTaskWorkPayload.publicResult(state) != nil, "valid state")
for field in state.keys {
  var value = state; value.removeValue(forKey: field)
  check(UnityBackgroundTaskWorkPayload.publicResult(value) == nil, "missing state field")
}
check(UnityBackgroundTaskWorkPayload.validFurnitureWorkSession([:]), "legacy missing work is compatible")
check(UnityBackgroundTaskWorkPayload.validFurnitureWorkSession(state), "legacy typed work is preserved")
check(!UnityBackgroundTaskWorkPayload.validFurnitureWorkSession(["workSessionId": true]), "legacy work is not boolean")
for phase in ["approaching", "aligning", "working"] {
  var value = state; value["phase"] = phase
  check(UnityBackgroundTaskWorkPayload.publicResult(value) != nil, "active work phase")
}
for phase in ["seated", "lying", "rising", "standing"] {
  var value = state; value["phase"] = phase
  check(UnityBackgroundTaskWorkPayload.publicResult(value) == nil, "inactive session not retained")
  value["workSessionId"] = ""
  check(UnityBackgroundTaskWorkPayload.publicResult(value) != nil, "user posture observed")
}
var stopped = state; stopped["phase"] = "standing"; stopped["furnitureId"] = ""; stopped["workSessionId"] = NSNull()
check(UnityBackgroundTaskWorkPayload.publicResult(stopped) != nil, "null retired work")
for (key, value): (String, Any) in [("workSessionId", String(repeating: "b", count: 64)),
  ("furnitureId", "sofa"), ("phase", "unknown"), ("privatePath", "secret"), ("sequence", true)] {
  var invalid = state; invalid[key] = value
  check(UnityBackgroundTaskWorkPayload.publicResult(invalid) == nil, "invalid state")
}
for version: Any in [0, 1, 2, 3, 2147483647] {
  check(UnityBackgroundTaskWorkPayload.boundedWorkVersion(version) != nil, "version preserved")
}
for version: Any in [true, "2", -1, 1.5, Double.nan, 2147483648 as Int64] {
  check(UnityBackgroundTaskWorkPayload.boundedWorkVersion(version) == nil, "version no coercion")
}
let session = Session()
check(!session.sendAvatarCommand(method: "setBackgroundTaskWork", json: "{}"), "unready work refused")
check(session.pendingFrames.isEmpty && session.outgoingSequence == 1, "no delayed replay or sequence loss")
check(session.sendAvatarCommand(method: "loadAvatar", json: "{}"), "legacy queue retained")
check(session.pendingFrames.count == 1, "one legacy frame")
session.authenticated = true; session.connectionFD = 1
check(session.sendAvatarCommand(method: "setBackgroundTaskWork", json: "{}"), "ready work sent")
check(session.sent.count == 1 && session.pendingFrames.count == 1, "work never enters backlog")
session.connectionFD = -1
check(!session.sendAvatarCommand(method: "setBackgroundTaskWork", json: "{}"), "lost connection refused")
check(session.pendingFrames.count == 1, "lost work never queued")
print("Swift native work protocol: \(checks) checks, 0 failures")
'''.replace("__SEND__", send).replace("__ENQUEUE__", enqueue)
        with tempfile.TemporaryDirectory(prefix="maaso-task-work-swift-") as folder:
            path = Path(folder)
            (path / "main.swift").write_text(source)
            subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(path / "module-cache"),
                            str(path / "main.swift"), "-o", str(path / "probe")], check=True)
            execution = subprocess.run([str(path / "probe")], check=True, capture_output=True, text=True)
            self.assertIn("0 failures", execution.stdout)
            print(execution.stdout.strip())

    def test_real_kotlin_boundary_with_installed_unity_compiler(self):
        compilers = sorted(Path("/Applications/Unity/Hub/Editor").glob(
            "*/PlaybackEngines/AndroidPlayer/Tools/gradle/lib/kotlin-compiler-embeddable-*.jar"))
        if not compilers:
            self.skipTest("No installed Kotlin compiler; no Android device was requested")
        libraries = compilers[-1].parent
        java = libraries.parents[2] / "OpenJDK/bin/java"
        stdlib = next(libraries.glob("kotlin-stdlib-*.jar"))
        gate = self.kotlin
        dispatch = block(self.android, "private fun completeBackgroundTaskWorkCommand(")
        dispatch = dispatch.replace("io.flutter.plugin.common.MethodCall", "MethodCall")
        program = r'''
class JSONObject(private val values: Map<String, Any?>) {
  companion object { val NULL = Any() }
  fun opt(key: String): Any? = values[key]
  fun keys(): Iterator<String> = values.keys.iterator()
}
__GATE__
class MethodCall(val method: String, val arguments: Any?)
object MethodChannel { interface Result { fun error(code: String, message: String, details: Any?); fun success(value: Any?) } }
object UnityAvatarCommandPayload { fun encode(method: String, arguments: Any?) = method }
class Sink { var ready = false; var queued = 0; var sent = 0
  fun sendTicketed(method: String, payload: String): Boolean { if (!ready) return false; sent++; return true }
  fun send(method: String, payload: String) { queued++ }
}
class Bridge(val commandSink: Sink) {
__DISPATCH__
  fun dispatch(arguments: Any?, result: MethodChannel.Result) =
    completeBackgroundTaskWorkCommand(MethodCall("setBackgroundTaskWork", arguments), result)
}
class Result : MethodChannel.Result {
  var code: String? = null; var successes = 0
  override fun error(code: String, message: String, details: Any?) { this.code = code }
  override fun success(value: Any?) { successes++ }
}
fun main() {
  var checks = 0
  fun check(value: Boolean, label: String) { checks++; if (!value) error(label) }
  val id = "a".repeat(64)
  val args = mapOf<String, Any?>("requestId" to "request-1", "sessionId" to id, "phase" to "start",
    "loadRequestId" to "load-1", "sequence" to 1L, "issuedAtEpochMs" to 1000L, "deadlineEpochMs" to 11000L)
  check(UnityAvatarBackgroundTaskWorkPayload.isValidArguments(args), "valid start")
  check(UnityAvatarBackgroundTaskWorkPayload.isValidArguments(args + ("phase" to "end")), "valid end")
  for (key in args.keys) check(!UnityAvatarBackgroundTaskWorkPayload.isValidArguments(args - key), "missing field")
  for (key in listOf("sequence", "issuedAtEpochMs", "deadlineEpochMs")) {
    for (value in listOf<Any?>(true, "1", 0, -1, 1.5, Double.NaN, Double.POSITIVE_INFINITY, 9007199254740992L))
      check(!UnityAvatarBackgroundTaskWorkPayload.isValidArguments(args + (key to value)), "bad integer")
  }
  for (key in listOf("requestId", "loadRequestId")) for (value in listOf("", " bad", "bad\n", "a".repeat(129)))
    check(!UnityAvatarBackgroundTaskWorkPayload.isValidArguments(args + (key to value)), "bad identifier")
  for (value in listOf(1000L, 999L, 11001L))
    check(!UnityAvatarBackgroundTaskWorkPayload.isValidArguments(args + ("deadlineEpochMs" to value)), "bad interval")
  check(!UnityAvatarBackgroundTaskWorkPayload.isValidArguments(args + ("gesture" to "jump")), "no arbitrary gesture")
  val receipt = args - "issuedAtEpochMs" - "deadlineEpochMs" + mapOf("method" to "setBackgroundTaskWork", "ok" to true, "code" to "")
  check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(receipt)) != null, "valid receipt")
  for (field in receipt.keys)
    check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(receipt - field)) == null, "missing receipt field")
  for (value in listOf<Any?>(1, 0, "true", null))
    check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(receipt + ("ok" to value))) == null, "strict receipt boolean")
  for (code in listOf("invalid_command", "deadline_expired", "model_stale", "stale_sequence", "session_ended",
    "session_mismatch", "authority_owned", "not_ready", "presentation_busy", "user_pose_owned", "work_unavailable", "mutation_failed"))
    check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(receipt + mapOf("ok" to false, "code" to code))) != null, "known failure")
  check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(receipt + mapOf("ok" to false, "code" to "raw_exception"))) == null, "closed failure")
  check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(receipt + ("coords" to listOf(1, 2)))) == null, "closed receipt")
  val state = mapOf<String, Any?>("method" to "backgroundTaskWorkState", "requestId" to "state-1", "sessionId" to id,
    "loadRequestId" to "load-1", "phase" to "working", "furnitureId" to "desk", "sceneId" to "coastal:room",
    "sequence" to 2L, "workSessionId" to id)
  check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(state)) != null, "valid state")
  for (field in state.keys)
    check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(state - field)) == null, "missing state field")
  check(UnityAvatarBackgroundTaskWorkPayload.validFurnitureWorkSession(JSONObject(emptyMap())), "legacy missing work")
  check(UnityAvatarBackgroundTaskWorkPayload.validFurnitureWorkSession(JSONObject(state)), "legacy valid work")
  check(!UnityAvatarBackgroundTaskWorkPayload.validFurnitureWorkSession(JSONObject(mapOf("workSessionId" to true))), "legacy boolean work")
  for (phase in listOf("approaching", "aligning", "working"))
    check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(state + ("phase" to phase))) != null, "active session")
  for (phase in listOf("seated", "lying", "rising", "standing")) {
    check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(state + ("phase" to phase))) == null, "nonworking session")
    check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(state + mapOf("phase" to phase, "workSessionId" to ""))) != null, "user posture")
  }
  check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(state + mapOf("phase" to "standing", "furnitureId" to "", "workSessionId" to JSONObject.NULL))) != null, "stopped session")
  for ((key, value) in listOf("workSessionId" to "b".repeat(64), "furnitureId" to "sofa", "phase" to "unknown", "sequence" to true, "privatePath" to "secret"))
    check(UnityAvatarBackgroundTaskWorkPayload.publicResult(JSONObject(state + (key to value))) == null, "bad state")
  for (version in listOf(0, 1, 2, 3, 2147483647)) check(UnityAvatarBackgroundTaskWorkPayload.boundedWorkVersion(version) != null, "supported version shape")
  for (version in listOf<Any?>(true, "2", -1, 1.5, Double.NaN, 2147483648L)) check(UnityAvatarBackgroundTaskWorkPayload.boundedWorkVersion(version) == null, "version no coercion")
  val sink = Sink(); val bridge = Bridge(sink); val unready = Result()
  bridge.dispatch(args, unready)
  check(unready.code == "not_ready" && sink.queued == 0 && sink.sent == 0, "unready never queued")
  val invalid = Result(); bridge.dispatch(args + ("gesture" to "jump"), invalid)
  check(invalid.code == "invalid_background_task_work_command" && sink.sent == 0, "validate before dispatch")
  sink.ready = true; val ready = Result(); bridge.dispatch(args, ready)
  check(ready.successes == 1 && sink.sent == 1 && sink.queued == 0, "one immediate send")
  println("Kotlin native work protocol: $checks checks, 0 failures")
}
'''.replace("__GATE__", gate).replace("__DISPATCH__", dispatch)
        with tempfile.TemporaryDirectory(prefix="maaso-task-work-kotlin-") as folder:
            path = Path(folder)
            (path / "Gate.kt").write_text(program)
            subprocess.run([str(java), "-cp", str(libraries / "*"), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                            "-no-stdlib", "-no-reflect", "-classpath", str(stdlib), "-d", str(path / "classes"),
                            str(path / "Gate.kt")], check=True)
            execution = subprocess.run([str(java), "-cp", f"{path / 'classes'}:{stdlib}", "GateKt"],
                                       check=True, capture_output=True, text=True)
            self.assertIn("0 failures", execution.stdout)
            print(execution.stdout.strip())


if __name__ == "__main__":
    unittest.main()
