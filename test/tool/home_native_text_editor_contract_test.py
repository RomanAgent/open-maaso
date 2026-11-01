"""Compile actual native editor sources and execute their boundary predicates.

These checks do not run a keyboard, platform view, clipboard, or device. They
cannot establish actual IME delivery or replace the isolated device probe.
Compiler outputs and module caches live only in a disposable temporary folder.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

from native_source_helpers import swift_function


ROOT = Path(os.environ.get("MAASO_REPO_ROOT", Path(__file__).resolve().parents[2]))
IOS = ROOT / "ios/Runner/MaasoHomeTextEditor.swift"
ANDROID = ROOT / "android/app/src/main/kotlin/com/futurpals/maaso/HomeTextEditorPlugin.kt"


def local_properties():
    path = ROOT / "android/local.properties"
    if not path.exists():
        return {}
    return dict(
        line.split("=", 1)
        for line in path.read_text().splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    )


def flutter_root():
    configured = os.environ.get("FLUTTER_ROOT") or local_properties().get("flutter.sdk")
    if configured:
        return Path(configured)
    executable = shutil.which("flutter")
    return Path(executable).resolve().parents[1] if executable else None


SWIFT_CASES = r'''
func rawSnapshot(_ overrides: [String: Any] = [:]) -> [String: Any] {
  ["token": 7, "ids": ["A", "B"], "selectedId": NSNull(), "enabled": true]
    .merging(overrides) { _, replacement in replacement }
}
func attachmentSnapshot(_ selected: Bool = false, _ available: Bool = true) -> MaasoHomeTextEditorRules.AttachmentSnapshot {
  MaasoHomeTextEditorRules.attachmentSnapshot(rawSnapshot([
    "ids": available ? ["A", "B"] : [], "selectedId": selected && available ? "B" as Any : NSNull()
  ]))!
}
func command(
  _ enabled: Bool = true, _ available: Bool = true, _ selected: Bool = false,
  _ base: Int = 0, _ extent: Int = 0, _ start: Int = -1, _ end: Int = -1
) -> String? {
  MaasoHomeTextEditorRules.attachmentCommand(
    enabled: enabled, attachments: attachmentSnapshot(selected, available),
    selectionBase: base, selectionExtent: extent, composingStart: start, composingEnd: end
  )?.kind
}
precondition(command() == "boundaryDelete")
precondition(command(true, true, true) == "deleteSelectedAttachment")
precondition(command(true, true, true, 5, 5) == "deleteSelectedAttachment")
for selected in [false, true] {
  precondition(command(false, true, selected) == nil)
  precondition(command(true, false, selected) == nil)
  precondition(command(true, true, selected, -1, -1) == nil)
  precondition(command(true, true, selected, 0, 2) == nil)
  precondition(command(true, true, selected, 2, 0) == nil)
  // A zero-length live marked range is still IME-owned.
  precondition(command(true, true, selected, 0, 0, 0, 0) == nil)
  precondition(command(true, true, selected, 0, 0, 0, 2) == nil)
}
precondition(command(true, true, false, 2, 2) == nil)
func nextCommand(_ state: MaasoHomeTextEditorRules.AttachmentSnapshot?) -> MaasoHomeTextEditorRules.AttachmentCommand? {
  MaasoHomeTextEditorRules.attachmentCommand(
    enabled: true, attachments: state, selectionBase: 0, selectionExtent: 0,
    composingStart: -1, composingEnd: -1
  )
}
var chain = attachmentSnapshot()
let originalChain = chain
let first = nextCommand(chain)!
for (index, target) in ["B", "B", "A", "A"].enumerated() {
  let pending = nextCommand(chain)!
  precondition(pending.targetId == target && pending.before == chain)
  precondition(pending.kind == (index % 2 == 0 ? "boundaryDelete" : "deleteSelectedAttachment"))
  precondition(pending.arguments["snapshotToken"] as? Int == 7)
  precondition(pending.arguments["beforeIds"] as? [String] == chain.ids)
  if chain.selectedId == nil { precondition(pending.arguments["beforeSelectedId"] is NSNull) }
  else { precondition(pending.arguments["beforeSelectedId"] as? String == chain.selectedId) }
  chain = chain.applying(pending)!
}
precondition(chain.ids.isEmpty && chain.selectedId == nil && nextCommand(chain) == nil)
precondition(nextCommand(nil) == nil)
let selectedChain = originalChain.applying(first)!
precondition(selectedChain.applying(first) == nil)
precondition(selectedChain.clearingSelection() == originalChain)
let aba = MaasoHomeTextEditorRules.attachmentSnapshot(rawSnapshot(["token": 8]))!
precondition(aba.applying(first) == nil)
let replaced = MaasoHomeTextEditorRules.attachmentSnapshot(rawSnapshot(["ids": ["A", "C"]]))!
precondition(replaced.applying(first) == nil)
let disabled = MaasoHomeTextEditorRules.attachmentSnapshot(rawSnapshot(["enabled": false]))!
precondition(nextCommand(disabled) == nil)
precondition(MaasoHomeTextEditorRules.attachmentSnapshot(rawSnapshot(["token": Int.max]))?.token == Int.max)
for malformed in [
  rawSnapshot(["token": -1]), rawSnapshot(["token": true]), rawSnapshot(["token": 1.5]),
  rawSnapshot(["ids": ["A", "A"]]), rawSnapshot(["ids": ["A", "B", "C", "D", "E"]]),
  rawSnapshot(["ids": [""]]), rawSnapshot(["ids": [String(repeating: "x", count: 257)]]),
  rawSnapshot(["ids": [String(repeating: "😀", count: 129)]]),
  rawSnapshot(["ids": ["A", 2] as [Any]]), rawSnapshot(["ids": "A"]),
  rawSnapshot(["selectedId": "missing"]), rawSnapshot(["selectedId": 1]),
  rawSnapshot(["enabled": 1]), rawSnapshot(["enabled": "true"])
] {
  precondition(MaasoHomeTextEditorRules.attachmentSnapshot(malformed) == nil)
}
var missingSelection = rawSnapshot(); missingSelection.removeValue(forKey: "selectedId")
precondition(MaasoHomeTextEditorRules.attachmentSnapshot(missingSelection) == nil)
precondition(MaasoHomeTextEditorRules.attachmentSnapshot(nil) == nil)
precondition(MaasoHomeTextEditorRules.attachmentSnapshot([:]) == nil)
precondition(MaasoHomeTextEditorRules.argb(0x12ABCDEF) == 0x12ABCDEF)
precondition(MaasoHomeTextEditorRules.argb(0xFFFFFFFF) == 0xFFFFFFFF)
precondition(MaasoHomeTextEditorRules.argb(-1) == nil)
precondition(MaasoHomeTextEditorRules.argb(0x100000000) == nil)
precondition(MaasoHomeTextEditorRules.argb(true) == nil)
precondition(MaasoHomeTextEditorRules.argb("blue") == nil)
let text = "中😀e\u{0301}\u{200B}\u{FFFC}"
let original = text
precondition(MaasoHomeTextEditorRules.utf16Offset(-9, in: text) == 0)
precondition(MaasoHomeTextEditorRules.utf16Offset(2, in: text) == 1)
precondition(MaasoHomeTextEditorRules.utf16Offset(3, in: text) == 3)
precondition(MaasoHomeTextEditorRules.utf16Offset(Int.max, in: text) == (text as NSString).length)
precondition(text == original)
precondition(MaasoHomeTextEditorRules.integer(true) == nil)
precondition(MaasoHomeTextEditorRules.integer("1") == nil)
precondition(MaasoHomeTextEditorRules.integer(Double.nan) == nil)
precondition(MaasoHomeTextEditorRules.integer(1.5) == nil)
precondition(MaasoHomeTextEditorRules.integer(3) == 3)
precondition(MaasoHomeTextEditorRules.fontSize(nil) == 17)
precondition(MaasoHomeTextEditorRules.fontSize(6) == 10)
precondition(MaasoHomeTextEditorRules.fontSize(72) == 48)
precondition(MaasoHomeTextEditorRules.fontSize(20.5) == 20.5)
precondition(MaasoHomeTextEditorRules.fontSize(Double.infinity) == 17)
let exact = "  中😀e\u{0301}\n\u{200B}\u{2060}\u{FFFC}  "
let fullRange = NSRange(location: 0, length: (exact as NSString).length)
precondition(MaasoHomeTextEditorRules.exactSelectedText(in: exact, range: fullRange) == exact)
precondition(MaasoHomeTextEditorRules.exactSelectedText(in: exact, range: NSRange(location: 3, length: 2)) == "😀")
precondition(MaasoHomeTextEditorRules.exactSelectedText(in: "\u{FFFC}", range: NSRange(location: 0, length: 1)) == "\u{FFFC}")
precondition(MaasoHomeTextEditorRules.exactSelectedText(in: "e\u{0301}", range: NSRange(location: 1, length: 1)) == "\u{0301}")
for range in [
  NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 0),
  NSRange(location: 99, length: 1), NSRange(location: 1, length: Int.max),
  NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
  NSRange(location: 4, length: 1), NSRange(location: 3, length: 1)
] {
  precondition(MaasoHomeTextEditorRules.exactSelectedText(in: exact, range: range) == nil)
}
print("Home Swift attachment predicates passed")
'''


KOTLIN_CASES = r'''
fun main() {
    fun rawSnapshot(overrides: Map<String, Any?> = emptyMap()): Map<String, Any?> =
        mapOf("token" to 7L, "ids" to listOf("A", "B"), "selectedId" to null, "enabled" to true) + overrides
    fun attachmentSnapshot(selected: Boolean = false, available: Boolean = true): HomeTextEditorRules.AttachmentSnapshot =
        HomeTextEditorRules.attachmentSnapshot(rawSnapshot(mapOf(
            "ids" to if (available) listOf("A", "B") else emptyList<String>(),
            "selectedId" to if (selected && available) "B" else null
        )))!!
    fun command(enabled: Boolean = true, available: Boolean = true, selected: Boolean = false,
                base: Int = 0, extent: Int = 0, start: Int = -1, end: Int = -1): String? =
        HomeTextEditorRules.attachmentCommand(enabled, attachmentSnapshot(selected, available), base, extent, start, end)?.kind
    check(command() == "boundaryDelete")
    check(command(selected = true) == "deleteSelectedAttachment")
    check(command(selected = true, base = 5, extent = 5) == "deleteSelectedAttachment")
    for (selected in listOf(false, true)) {
        check(command(enabled = false, selected = selected) == null)
        check(command(available = false, selected = selected) == null)
        check(command(selected = selected, base = -1, extent = -1) == null)
        check(command(selected = selected, base = 0, extent = 2) == null)
        check(command(selected = selected, base = 2, extent = 0) == null)
        check(command(selected = selected, start = 0, end = 0) == null)
        check(command(selected = selected, start = 0, end = 2) == null)
    }
    check(command(base = 2, extent = 2) == null)
    fun nextCommand(state: HomeTextEditorRules.AttachmentSnapshot?): HomeTextEditorRules.AttachmentCommand? =
        HomeTextEditorRules.attachmentCommand(true, state, 0, 0, -1, -1)
    var chain = attachmentSnapshot()
    val originalChain = chain
    val first = nextCommand(chain)!!
    for ((index, target) in listOf("B", "B", "A", "A").withIndex()) {
        val pending = nextCommand(chain)!!
        check(pending.targetId == target && pending.before == chain)
        check(pending.kind == if (index % 2 == 0) "boundaryDelete" else "deleteSelectedAttachment")
        check(pending.arguments()["snapshotToken"] == 7L)
        check(pending.arguments()["beforeIds"] == chain.ids)
        check(pending.arguments()["beforeSelectedId"] == chain.selectedId)
        chain = chain.applying(pending)!!
    }
    check(chain.ids.isEmpty() && chain.selectedId == null && nextCommand(chain) == null)
    check(nextCommand(null) == null)
    val selectedChain = originalChain.applying(first)!!
    check(selectedChain.applying(first) == null)
    check(selectedChain.clearingSelection() == originalChain)
    val aba = HomeTextEditorRules.attachmentSnapshot(rawSnapshot(mapOf("token" to 8)))!!
    check(aba.applying(first) == null)
    val replaced = HomeTextEditorRules.attachmentSnapshot(rawSnapshot(mapOf("ids" to listOf("A", "C"))))!!
    check(replaced.applying(first) == null)
    val disabled = HomeTextEditorRules.attachmentSnapshot(rawSnapshot(mapOf("enabled" to false)))!!
    check(nextCommand(disabled) == null)
    check(HomeTextEditorRules.attachmentSnapshot(rawSnapshot(mapOf("token" to Long.MAX_VALUE)))?.token == Long.MAX_VALUE)
    for (malformed in listOf(
        rawSnapshot(mapOf("token" to -1)), rawSnapshot(mapOf("token" to true)), rawSnapshot(mapOf("token" to 1.5)),
        rawSnapshot(mapOf("ids" to listOf("A", "A"))), rawSnapshot(mapOf("ids" to listOf("A", "B", "C", "D", "E"))),
        rawSnapshot(mapOf("ids" to listOf(""))), rawSnapshot(mapOf("ids" to listOf("x".repeat(257)))),
        rawSnapshot(mapOf("ids" to listOf("😀".repeat(129)))), rawSnapshot(mapOf("ids" to listOf("A", 2))),
        rawSnapshot(mapOf("ids" to "A")), rawSnapshot(mapOf("selectedId" to "missing")),
        rawSnapshot(mapOf("selectedId" to 1)), rawSnapshot(mapOf("enabled" to 1)),
        rawSnapshot(mapOf("enabled" to "true")), rawSnapshot() - "selectedId"
    )) check(HomeTextEditorRules.attachmentSnapshot(malformed) == null)
    check(HomeTextEditorRules.attachmentSnapshot(null) == null)
    check(HomeTextEditorRules.attachmentSnapshot(emptyMap<String, Any>()) == null)
    check(HomeTextEditorRules.argb(0x12ABCDEFL) == 0x12ABCDEF)
    check(HomeTextEditorRules.argb(0xFFFFFFFFL) == -1)
    check(HomeTextEditorRules.argb(-1) == null)
    check(HomeTextEditorRules.argb(0x100000000L) == null)
    check(HomeTextEditorRules.argb(true) == null)
    check(HomeTextEditorRules.argb("blue") == null)
    val text = "中😀e\u0301\u200B\uFFFC"
    val original = text
    check(HomeTextEditorRules.utf16Offset(-9, text) == 0)
    check(HomeTextEditorRules.utf16Offset(2, text) == 1)
    check(HomeTextEditorRules.utf16Offset(3, text) == 3)
    check(HomeTextEditorRules.utf16Offset(Long.MAX_VALUE, text) == text.length)
    check(text == original)
    check(HomeTextEditorRules.integer(true) == null)
    check(HomeTextEditorRules.integer("1") == null)
    check(HomeTextEditorRules.integer(Double.NaN) == null)
    check(HomeTextEditorRules.integer(1.5) == null)
    check(HomeTextEditorRules.integer(3) == 3L)
    check(HomeTextEditorRules.fontSize(null) == 17f)
    check(HomeTextEditorRules.fontSize(6) == 10f)
    check(HomeTextEditorRules.fontSize(72) == 48f)
    check(HomeTextEditorRules.fontSize(20.5) == 20.5f)
    check(HomeTextEditorRules.fontSize(Double.POSITIVE_INFINITY) == 17f)
    println("Home Kotlin attachment predicates passed")
}
'''


class HomeNativeTextEditorContractTest(unittest.TestCase):
    def run_checked(self, command):
        completed = subprocess.run(command, capture_output=True, text=True, timeout=120)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        return completed.stdout.strip()

    def kotlin_environment(self):
        gradle = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle"))
        compilers = sorted((gradle / "wrapper/dists").glob("*/**/lib/kotlin-compiler-embeddable-*.jar"))
        if not compilers or not shutil.which("java"):
            self.skipTest("A cached Kotlin compiler and Java are required; no download attempted")
        libraries = compilers[-1].parent
        return str(libraries / "*"), [str(path) for path in libraries.glob("*.jar")]

    def test_ios_actual_source_typechecks_with_uikit_and_flutter(self):
        flutter = flutter_root()
        if not shutil.which("xcrun") or flutter is None:
            self.skipTest("Xcode and a local Flutter SDK are required")
        framework = flutter / "bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64"
        if not (framework / "Flutter.framework").exists():
            self.skipTest("Cached iOS Flutter framework is unavailable; no download attempted")
        sdk = self.run_checked(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"])
        with tempfile.TemporaryDirectory(prefix="maaso-home-editor-ios-") as temp:
            self.run_checked([
                "xcrun", "swiftc", "-typecheck", "-target", "arm64-apple-ios15.0",
                "-sdk", sdk, "-F", str(framework), "-module-cache-path", str(Path(temp) / "cache"), str(IOS),
            ])

    def test_ios_actual_boundary_predicates_execute(self):
        if not shutil.which("xcrun"):
            self.skipTest("A local Swift compiler is required")
        rules = swift_function(IOS.read_text(), "enum MaasoHomeTextEditorRules")
        with tempfile.TemporaryDirectory(prefix="maaso-home-editor-swift-rules-") as temp:
            folder = Path(temp)
            source = folder / "main.swift"
            source.write_text("import Foundation\nimport CoreFoundation\n" + rules + SWIFT_CASES)
            self.run_checked([
                "xcrun", "swiftc", "-module-cache-path", str(folder / "cache"),
                str(source), "-o", str(folder / "rules"),
            ])
            self.assertIn("predicates passed", self.run_checked([str(folder / "rules")]))

    def test_android_actual_source_compiles_with_platform_and_flutter(self):
        compiler, libraries = self.kotlin_environment()
        sdk = Path(os.environ.get("ANDROID_HOME") or local_properties().get("sdk.dir", Path.home() / "Library/Android/sdk"))
        platforms = sorted((sdk / "platforms").glob("android-3*/android.jar"))
        flutter = flutter_root()
        embedding = flutter / "bin/cache/artifacts/engine/android-arm64/flutter.jar" if flutter else None
        if not platforms or embedding is None or not embedding.exists():
            self.skipTest("Cached Android SDK and Flutter embedding are required; no download attempted")
        classpath = os.pathsep.join(libraries + [str(platforms[-1]), str(embedding)])
        with tempfile.TemporaryDirectory(prefix="maaso-home-editor-android-") as temp:
            self.run_checked([
                "java", "-cp", compiler, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-classpath", classpath,
                "-d", str(Path(temp) / "classes"), str(ANDROID),
            ])

    def test_android_actual_boundary_predicates_execute(self):
        compiler, libraries = self.kotlin_environment()
        rules = swift_function(ANDROID.read_text(), "internal object HomeTextEditorRules")
        with tempfile.TemporaryDirectory(prefix="maaso-home-editor-kotlin-rules-") as temp:
            folder = Path(temp)
            source = folder / "HomeRules.kt"
            source.write_text(rules + KOTLIN_CASES)
            classes = folder / "classes"
            self.run_checked([
                "java", "-cp", compiler, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-classpath", os.pathsep.join(libraries),
                "-d", str(classes), str(source),
            ])
            output = self.run_checked(["java", "-cp", os.pathsep.join([str(classes)] + libraries), "HomeRulesKt"])
            self.assertIn("predicates passed", output)


if __name__ == "__main__":
    unittest.main()
