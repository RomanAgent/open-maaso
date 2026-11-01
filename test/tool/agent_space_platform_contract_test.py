#!/usr/bin/env python3
"""Check platform room contracts and execute the production Windows receipt gate."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
METHODS = ("enterAgentSpace", "leaveAgentSpace", "requestAgentSpaceMoveAtScreenPoint")
RETIRED = (
    "worldMapCache", "prepareWorldMap", "cancelWorldMap", "switchWorld",
    "worldPrivateRoute", "worldPrivateFurniture", "joinWorld", "applyWorldSnapshot",
    "applyWorldHudSnapshot", "showWorldReaction", "showWorldChat", "showWorldEffect",
    "playWorldHighlight", "stopWorldHighlight", "beginWorldExit", "leaveWorld",
    "requestWorldMoveAtScreenPoint", "focusWorldResident", "worldEvent",
)


def block(source, marker):
    start = source.index(marker)
    offset = source.index("{", start)
    depth = 0
    while offset < len(source):
        raw = re.match(r'R"([A-Za-z0-9_]*)\(', source[offset:])
        if raw:
            ending = ")" + raw[1] + '"'
            offset = source.index(ending, offset + len(raw[0])) + len(ending)
            continue
        if source.startswith("//", offset):
            offset = source.index("\n", offset)
            continue
        if source.startswith("/*", offset):
            offset = source.index("*/", offset) + 2
            continue
        character = source[offset]
        if character in ('"', "'"):
            quote = character
            offset += 1
            while offset < len(source):
                if source[offset] == "\\":
                    offset += 2
                elif source[offset] == quote:
                    offset += 1
                    break
                else:
                    offset += 1
            continue
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start:offset + 1]
        offset += 1
    raise ValueError(f"Unterminated block: {marker}")


class AgentSpacePlatformContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.android = (ROOT / "android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt").read_text()
        cls.web = (ROOT / "web/maaso_unity_avatar.js").read_text()
        cls.windows = (ROOT / "windows/runner/unity_player_host.cpp").read_text()

    def test_all_platforms_remove_world_dispatch_and_admit_local_room(self):
        for source in (self.android, self.web, self.windows):
            for method in METHODS:
                self.assertIn(method, source)
            for method in RETIRED:
                self.assertNotIn(method, source)
            for retained in ("setWorldTimeOfDay", "setWorldCamera", "setPhoneInteraction",
                             "setLocalAvatarVisible", "avatarArbiterCommand"):
                self.assertIn(retained, source)

    def test_retired_feed_commands_cannot_reenter_native_avatar_hosts(self):
        paths = (
            "ios/Runner/AppDelegate.swift",
            "macos/Runner/MacOSUnityAvatarPortal.swift",
            "unity/masso_avatar/Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs",
            "unity/masso_avatar/Assets/MaasoAvatar/Scripts/DesktopUnitySidecarBridge.cs",
            "unity/masso_avatar/Assets/MaasoAvatar/Scripts/WindowsUnityAvatarMessageBridge.cs",
        )
        sources = (self.android, self.web, self.windows) + tuple(
            (ROOT / path).read_text() for path in paths
        )
        for source in sources:
            for method in ("live.applyScene", "live.clearScene", "live.captureCover"):
                self.assertNotIn(method, source)
        for source in sources[:3]:
            for method in METHODS:
                self.assertIn(method, source)

    def test_android_room_dispatch_and_receipt_use_closed_typed_fields(self):
        payload = block(self.android, "private object UnityAvatarAgentSpacePayload")
        declared = set(re.findall(r'"([A-Za-z]+)"', re.search(r"receiptKeys = setOf\((.*?)\)", payload)[1]))
        native = (ROOT / "unity/masso_avatar/Assets/MaasoAvatar/Scripts/AgentSpaceController.cs").read_text()
        result = block(native, "public sealed class AgentSpaceResult")
        native_fields = set(re.findall(r"public (?:string|bool) (\w+);", result))
        self.assertEqual(declared, native_fields)
        self.assertEqual(declared, {"method", "requestId", "sessionId", "ok", "code"})
        self.assertIn('!values.keys.containsAll(keys)', payload)
        self.assertIn('!allowed.containsAll(values.keys)', payload)
        self.assertIn('values["animated"] !is Boolean', payload)
        self.assertIn('values.containsKey("viewportTop") != values.containsKey("viewportBottom")', payload)
        self.assertIn('value > 0.45', payload)
        self.assertIn('raw.opt("ok") !is Boolean', payload)
        self.assertIn('raw.opt("code") as? String', payload)
        self.assertIn('value < 0 || value > 1', payload)
        dispatch = block(self.android, "private fun completeAgentSpaceCommand(")
        self.assertIn('isValidArguments(call.method, call.arguments)', dispatch)
        self.assertIn('sendTicketed(call.method, payload)', dispatch)

    def test_native_share_file_provider_keeps_the_new_generic_cache_reachable(self):
        paths = (ROOT / "android/app/src/main/res/xml/maaso_share_paths.xml").read_text()
        self.assertIn('File(cacheDir, "shared_media")', self.android)
        self.assertIn('path="shared_media/"', paths)
        self.assertNotIn("world_highlights", self.android + paths)

    def test_production_apple_transition_validators_execute_the_same_closed_contract(self):
        base = '["requestId": "request", "sessionId": "room"]'
        cases = [
            ('[:]', False), (base, True),
            ('base.merging(["animated": true]) { _, new in new }', True),
            ('base.merging(["animated": false, "viewportTop": 0.0, "viewportBottom": 0.45]) { _, new in new }', True),
            ('base.merging(["viewportTop": 0.1, "viewportBottom": 0.3]) { _, new in new }', True),
        ]
        for suffix in [
            '["animated": 1]', '["animated": "true"]', '["animated": NSNull()]',
            '["viewportTop": 0.1]', '["viewportBottom": 0.1]',
            '["viewportTop": true, "viewportBottom": 0.0]',
            '["viewportTop": 0.0, "viewportBottom": 0.46]',
            '["viewportTop": -0.01, "viewportBottom": 0.0]',
            '["viewportTop": Double.nan, "viewportBottom": 0.0]',
            '["viewportTop": 0.0, "viewportBottom": Double.infinity]',
            '["viewportTop": "0.1", "viewportBottom": 0.1]',
            '["x": 0.5, "y": 0.5]', '["extra": true]',
        ]:
            cases.append((f'base.merging({suffix}) {{ _, new in new }}', False))
        statements = '\n'.join(
            f'check(UnityAgentSpacePayload.isValidArguments(method: method, raw: {value}) == {str(expected).lower()}, "argument-{i}")'
            for i, (value, expected) in enumerate(cases)
        )
        movement = '''
let movement = base.merging(["x": 0.5, "y": 0.5]) { _, new in new }
check(UnityAgentSpacePayload.isValidArguments(method: "requestAgentSpaceMoveAtScreenPoint", raw: movement), "move")
for extra: [String: Any] in [["animated": true], ["viewportTop": 0.0, "viewportBottom": 0.0], ["extra": false]] {
  check(!UnityAgentSpacePayload.isValidArguments(method: "requestAgentSpaceMoveAtScreenPoint", raw: movement.merging(extra) { _, new in new }), "no-motion-fields-on-move")
}
'''
        receipt = '''
let receipt: [String: Any] = ["method": "enterAgentSpace", "requestId": "request", "sessionId": "room", "ok": false, "code": "space_transition_cancelled"]
check(UnityAgentSpacePayload.publicResult(receipt) != nil, "cancelled-exact-receipt")
check(UnityAgentSpacePayload.publicResult(receipt.merging(["code": "arbitrary_failure"]) { _, new in new }) == nil, "closed-failure-codes")
check(UnityAgentSpacePayload.publicResult(receipt.merging(["animated": true]) { _, new in new }) == nil, "closed-receipt-fields")
'''
        for path in ['ios/Runner/AppDelegate.swift', 'macos/Runner/MacOSUnityAvatarPortal.swift']:
            gate = block((ROOT / path).read_text(), 'private enum UnityAgentSpacePayload')
            program = '\n'.join([
                'import Foundation', 'import CoreFoundation', gate,
                'var checks = 0; var failures = 0',
                'func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures += 1; print(label) } }',
                f'let base: [String: Any] = {base}',
                'for method in ["enterAgentSpace", "leaveAgentSpace"] {', statements, '}',
                movement, receipt,
                'print("Apple transition validators: \\(checks) checks, \\(failures) failures")',
                'exit(failures == 0 ? 0 : 1)',
            ])
            with tempfile.TemporaryDirectory(prefix='maaso-space-apple-contract-') as folder:
                source = Path(folder) / 'gate.swift'; binary = Path(folder) / 'gate'
                source.write_text(program)
                subprocess.run(['swiftc', '-module-cache-path', str(Path(folder) / 'modules'), str(source), '-o', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)

    def test_production_windows_transition_arguments_execute_without_accepting_motion_on_moves(self):
        helpers = '\n'.join(block(self.windows, name) for name in (
            'bool IsAgentSpaceMethod(', 'bool AgentSpaceIdentifier(',
            'const flutter::EncodableValue* AgentSpaceArgument(', 'bool IsValidAgentSpaceArguments(',
        ))
        program = r'''
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <variant>
namespace flutter {
struct EncodableValue;
using EncodableMap = std::map<EncodableValue, EncodableValue>;
struct EncodableValue : std::variant<std::monostate, bool, int32_t, int64_t, double, std::string, EncodableMap> {
  using variant::variant;
};
}
__HELPERS__
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
int checks = 0, failures = 0;
void check(bool condition, const char* label) { ++checks; if (!condition) { ++failures; std::cerr << label << "\n"; } }
bool valid(const std::string& method, const Map& fields) { const Value raw(fields); return IsValidAgentSpaceArguments(method, &raw); }
int main() {
  const Map base{{Value(std::string("requestId")), Value(std::string("request"))},
                 {Value(std::string("sessionId")), Value(std::string("room"))}};
  for (const auto& method : {"enterAgentSpace", "leaveAgentSpace"}) {
    check(valid(method, base), "legacy");
    Map fields = base; fields[Value(std::string("animated"))] = true;
    check(valid(method, fields), "animated");
    fields[Value(std::string("viewportTop"))] = 0.0;
    check(!valid(method, fields), "partial-pair");
    fields[Value(std::string("viewportBottom"))] = 0.45;
    check(valid(method, fields), "bounded-pair");
    fields[Value(std::string("animated"))] = int32_t(1);
    check(!valid(method, fields), "numeric-boolean");
    fields[Value(std::string("animated"))] = false;
    for (const Value& bad : {Value(true), Value(-.01), Value(.46), Value(std::numeric_limits<double>::quiet_NaN()), Value(std::numeric_limits<double>::infinity()), Value(std::string("0.1")), Value()}) {
      fields[Value(std::string("viewportTop"))] = bad;
      check(!valid(method, fields), "invalid-viewport");
    }
    fields[Value(std::string("viewportTop"))] = int32_t(0);
    check(valid(method, fields), "zero-integer-safearea");
    fields[Value(std::string("other"))] = true;
    check(!valid(method, fields), "unknown-key");
    Map missing = base; missing.erase(Value(std::string("sessionId")));
    check(!valid(method, missing), "missing-session");
  }
  Map move = base; move[Value(std::string("x"))] = 0.25; move[Value(std::string("y"))] = 0.75;
  check(valid("requestAgentSpaceMoveAtScreenPoint", move), "move");
  move[Value(std::string("animated"))] = true;
  check(!valid("requestAgentSpaceMoveAtScreenPoint", move), "move-must-not-animate");
  move.erase(Value(std::string("animated")));
  move[Value(std::string("viewportTop"))] = 0.0; move[Value(std::string("viewportBottom"))] = 0.0;
  check(!valid("requestAgentSpaceMoveAtScreenPoint", move), "move-must-not-reframe");
  check(!valid("joinWorld", base), "retired-world");
  std::cout << "Windows native transition arguments: " << checks << " checks, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
'''.replace('__HELPERS__', helpers)
        with tempfile.TemporaryDirectory(prefix='maaso-space-windows-contract-') as folder:
            source = Path(folder) / 'gate.cpp'; binary = Path(folder) / 'gate'
            source.write_text(program)
            subprocess.run(['c++', '-std=c++17', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_production_android_transition_arguments_execute_with_installed_unity_kotlin(self):
        compilers = sorted(Path('/Applications/Unity/Hub/Editor').glob(
            '*/PlaybackEngines/AndroidPlayer/Tools/gradle/lib/kotlin-compiler-embeddable-*.jar'))
        if not compilers:
            self.skipTest('No installed Kotlin compiler; Android source contract remains checked')
        compiler = compilers[-1]
        libraries = compiler.parent
        java = libraries.parents[2] / 'OpenJDK/bin/java'
        if not java.is_file():
            self.skipTest('Installed Unity Kotlin compiler has no matching JDK')
        stdlib = next(libraries.glob('kotlin-stdlib-*.jar'))
        gate = block(self.android, 'private object UnityAvatarAgentSpacePayload')
        program = r'''
class JSONObject(private val values: Map<String, Any?>) {
    fun opt(key: String): Any? = values[key]
    fun keys(): Iterator<String> = values.keys.iterator()
    fun get(key: String): Any = values[key]!!
}
__GATE__
fun main() {
    var checks = 0
    var failures = 0
    fun check(condition: Boolean, label: String) { checks++; if (!condition) { failures++; println(label) } }
    val base = mapOf<String, Any?>("requestId" to "request", "sessionId" to "room")
    for (method in listOf("enterAgentSpace", "leaveAgentSpace")) {
        check(UnityAvatarAgentSpacePayload.isValidArguments(method, base), "legacy")
        check(UnityAvatarAgentSpacePayload.isValidArguments(method, base + mapOf("animated" to true)), "animated")
        check(UnityAvatarAgentSpacePayload.isValidArguments(method, base + mapOf("animated" to false, "viewportTop" to 0, "viewportBottom" to .45)), "paired-target")
        for (bad in listOf<Any?>(1, "true", null)) {
            check(!UnityAvatarAgentSpacePayload.isValidArguments(method, base + mapOf("animated" to bad)), "bad-animation-flag")
        }
        check(!UnityAvatarAgentSpacePayload.isValidArguments(method, base + mapOf("viewportTop" to .1)), "partial-target")
        for (bad in listOf<Any?>(true, -.01, .46, Double.NaN, Double.POSITIVE_INFINITY, "0.1", null)) {
            check(!UnityAvatarAgentSpacePayload.isValidArguments(method, base + mapOf("viewportTop" to bad, "viewportBottom" to .1)), "bad-target")
        }
        check(!UnityAvatarAgentSpacePayload.isValidArguments(method, base + mapOf("other" to true)), "unknown-key")
    }
    val move = base + mapOf("x" to .25, "y" to .75)
    check(UnityAvatarAgentSpacePayload.isValidArguments("requestAgentSpaceMoveAtScreenPoint", move), "move")
    check(!UnityAvatarAgentSpacePayload.isValidArguments("requestAgentSpaceMoveAtScreenPoint", move + mapOf("animated" to true)), "move-no-animation")
    check(!UnityAvatarAgentSpacePayload.isValidArguments("requestAgentSpaceMoveAtScreenPoint", move + mapOf("viewportTop" to 0, "viewportBottom" to 0)), "move-no-viewport")
    check(!UnityAvatarAgentSpacePayload.isValidArguments("joinWorld", base), "retired-command")
    val receipt = JSONObject(base + mapOf("method" to "enterAgentSpace", "ok" to false, "code" to "space_transition_cancelled"))
    check(UnityAvatarAgentSpacePayload.publicResult(receipt) != null, "cancelled-receipt")
    println("Android native transition arguments: $checks checks, $failures failures")
    if (failures != 0) error("Android transition validator failures")
}
'''.replace('__GATE__', gate)
        with tempfile.TemporaryDirectory(prefix='maaso-space-kotlin-contract-') as folder:
            source = Path(folder) / 'Gate.kt'; classes = Path(folder) / 'classes'
            source.write_text(program)
            subprocess.run([str(java), '-cp', str(libraries / '*'),
                            'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
                            '-classpath', str(stdlib), '-d', str(classes), str(source)], check=True)
            subprocess.run([str(java), '-cp', f'{classes}:{stdlib}', 'GateKt'], check=True)

    def test_production_windows_receipts_reject_malformed_and_retired_results(self):
        methods_start = self.windows.index("const std::set<std::string> kAvatarMethods")
        methods = self.windows[methods_start:self.windows.index("};", methods_start) + 2]
        helpers = "\n".join(block(self.windows, name) for name in (
            "bool IsAgentSpaceMethod(", "bool AgentSpaceIdentifier(",
            "void SkipAgentSpaceWhitespace(", "bool ReadAgentSpaceToken(",
            "bool IsValidAgentSpaceReceipt(", "bool IsValidAvatarReceipt(",
        ))
        valid = dict(method="enterAgentSpace", requestId="request-1", sessionId="space_1", ok=True, code="")
        fixtures = [(valid, True), ({**valid, "method": "leaveAgentSpace", "ok": False,
                                    "code": "session_mismatch"}, True)]
        for key, value in (("ok", "true"), ("code", 0), ("requestId", ""),
                           ("sessionId", "has whitespace"), ("sessionId", "x" * 129),
                           ("extra", True), ("requestId", {"value": "nested"})):
            fixtures.append(({**valid, key: value}, False))
        fixtures.append(({key: value for key, value in valid.items() if key != "code"}, False))
        packets = [(json.dumps(value), expected) for value, expected in fixtures]
        packets.extend([
            ('{"method":"enterAgentSpace","method":"enterAgentSpace","requestId":"r","sessionId":"s","ok":true,"code":""}', False),
            (json.dumps(valid) + " trailing", False),
            ('{"method":"worldPrivateRoute","requestId":"r","ok":true}', False),
            ('{"method":"furnitureState","phase":"standing"}', True),
            ('{"method":"loadAvatar","requestId":"load","ok":true}', True),
        ])
        statements = "\n".join(
            f'check(IsValidAvatarReceipt({json.dumps(packet)}) == {str(expected).lower()}, "fixture-{index}");'
            for index, (packet, expected) in enumerate(packets)
        )
        program = "\n".join([
            "#include <algorithm>", "#include <string>", "#include <set>", "#include <regex>",
            "#include <iostream>", methods, helpers,
            'int failures = 0; void check(bool valid, const char* label) { if (!valid) { ++failures; std::cerr << label << "\\n"; } }',
            "int main() {", statements,
            f'std::cout << "Windows native receipt fixtures: {len(packets)} checks, " << failures << " failures\\n";',
            "return failures == 0 ? 0 : 1; }",
        ])
        with tempfile.TemporaryDirectory(prefix="maaso-space-receipts-") as folder:
            root = Path(folder)
            source = root / "receipt_test.cpp"
            binary = root / "receipt_test"
            source.write_text(program)
            subprocess.run(["c++", "-std=c++17", str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
