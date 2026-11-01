"""Exercise the actual city bridge without making live location/network requests."""

from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

from native_source_helpers import swift_function

ROOT = Path(os.environ.get("MAASO_REPO_ROOT", Path(__file__).resolve().parents[2]))
IOS = ROOT / "ios/Runner/AppDelegate.swift"
MAC = ROOT / "macos/Runner/MainFlutterWindow.swift"
ANDROID = ROOT / "android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt"

SWIFT_PLATFORM = r'''
import Foundation
import CoreFoundation
typealias FlutterResult = (Any?) -> Void
let FlutterMethodNotImplemented = NSObject()
final class FlutterMethodCall {
  let method: String; let arguments: Any?
  init(_ method: String, _ arguments: Any? = nil) { self.method = method; self.arguments = arguments }
}
final class FlutterMethodChannel {
  var handler: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?
  func setMethodCallHandler(_ callback: @escaping (FlutterMethodCall, @escaping FlutterResult) -> Void) { handler = callback }
  func invoke(_ method: String, _ arguments: Any? = nil, result: @escaping FlutterResult) { handler?(FlutterMethodCall(method, arguments), result) }
}
final class UIApplication {
  enum State { case active, background }
  static let shared = UIApplication(); var applicationState = State.active
  static let didEnterBackgroundNotification = Notification.Name("fixture.background")
}
final class FakeApplication { var isActive = true }
let NSApp = FakeApplication()
enum NSApplication { static let didResignActiveNotification = Notification.Name("fixture.background") }
'''

SWIFT_GEOCODER = r'''
final class CLLocation {
  init(latitude: Double, longitude: Double) {}
}
final class CLPlacemark {
  var locality: String?; var administrativeArea: String?; var country: String?
  var isoCountryCode: String?
  init(_ city: String?, _ region: String? = "Region", _ country: String? = "Country", _ countryCode: String? = "CN") {
    locality = city; administrativeArea = region; self.country = country
    isoCountryCode = countryCode
  }
}
final class CLGeocoder {
  static var callbacks: [(([CLPlacemark]?, Error?) -> Void)] = []
  static var cancellations = 0
  func reverseGeocodeLocation(_ location: CLLocation, completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void) {
    Self.callbacks.append(completionHandler)
  }
  func cancelGeocode() { Self.cancellations += 1 }
}
'''

SWIFT_CASES = r'''
extension MaasoCityGeocoderBridge { func fixtureExpire() { timeout?.perform() } }
func drain() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025)) }
func check(_ value: Bool, _ message: String) { precondition(value, message) }
var output: [[String: Any]] = []
let channel = FlutterMethodChannel()
private let bridge = MaasoCityGeocoderBridge(channel: channel)
let valid: [String: Any] = ["latitude": 30.0, "longitude": 120.0]
func send(_ arguments: [String: Any] = valid) {
  channel.invoke("reverseGeocode", arguments) { raw in
    if let result = raw as? [String: Any] { output.append(result) }
  }
}
func code() -> String? { output.last?["code"] as? String }
for malformed in [
  ["latitude": true, "longitude": 120.0] as [String: Any],
  ["latitude": "30", "longitude": 120.0],
  ["latitude": 91.0, "longitude": 120.0],
  ["latitude": 30.0, "longitude": Double.infinity],
  ["latitude": 30.0],
  ["latitude": 30.0, "longitude": 120.0, "street": "private"]
] {
  send(malformed)
  check(code() == "invalid_coordinates", "Malformed coordinates escaped validation")
}
check(CLGeocoder.callbacks.isEmpty, "Invalid input reached geocoder")
send(); send()
check(code() == "busy" && CLGeocoder.callbacks.count == 1, "Overlapping reverse request was admitted")
CLGeocoder.callbacks[0]([CLPlacemark("City")], nil); drain()
check(output.last?["status"] as? String == "available", "Valid city was rejected")
check(Set(output.last!.keys) == ["status", "city", "region", "country", "countryCode"], "Street or coordinates escaped bridge")
check(output.last?["countryCode"] as? String == "CN", "Canonical ISO country was not exposed")
let completedCount = output.count
CLGeocoder.callbacks[0]([CLPlacemark("Wrong")], nil); drain()
check(output.count == completedCount, "Duplicate callback was emitted")
send(); CLGeocoder.callbacks[1]([CLPlacemark(nil)], nil); drain()
check(code() == "city_unavailable", "Region incorrectly substituted for missing city")
send(); CLGeocoder.callbacks[2]([CLPlacemark("City\nAddress")], nil); drain()
check(code() == "city_unavailable", "Control-bearing city escaped")
send(); CLGeocoder.callbacks[3](nil, NSError(domain: "private-provider-detail", code: 9)); drain()
check(code() == "geocoder_failed" && output.last!.count == 2, "Raw provider failure escaped")
send(); channel.invoke("cancelReverseGeocode") { _ in }
check(code() == "cancelled", "Cancellation did not resolve pending request")
let cancelledCount = output.count
send(); CLGeocoder.callbacks[4]([CLPlacemark("Old City")], nil); drain()
check(output.count == cancelledCount, "Stale callback resolved a replacement request")
CLGeocoder.callbacks[5]([CLPlacemark("New City")], nil); drain()
check(output.last?["city"] as? String == "New City", "Replacement request did not resolve")
send(); bridge.fixtureExpire()
check(code() == "timeout", "Deadline did not bound the request")
let expiredCount = output.count
CLGeocoder.callbacks[6]([CLPlacemark("Late City")], nil); drain()
check(output.count == expiredCount, "Timeout callback was emitted twice")
for country in [nil, "", "cn", "CN ", "CN\n", "CHN", "CＮ", "ß", "中国", "HK", "US"] as [String?] {
  send()
  CLGeocoder.callbacks.last?([CLPlacemark("City", "Region", "Country", country)], nil); drain()
  let expected = country == "HK" || country == "US" ? country! : ""
  check(output.last?["countryCode"] as? String == expected, "Malformed country escaped bridge")
  check(output.last?["status"] as? String == "available", "Unknown country incorrectly rejected a valid city")
}
send(); NotificationCenter.default.post(name: Notification.Name("fixture.background"), object: nil)
check(code() == "cancelled", "Background request was not retired")
UIApplication.shared.applicationState = .background; NSApp.isActive = false
let dispatched = CLGeocoder.callbacks.count
send()
check(code() == "cancelled" && CLGeocoder.callbacks.count == dispatched, "Background request reached provider")
check(CLGeocoder.cancellations >= 3, "Cancellation was not forwarded to provider")
print("native city contract passed")
'''


class LocationNativeContractTest(unittest.TestCase):
    def bridge(self, path):
        return swift_function(path.read_text(), "private final class MaasoCityGeocoderBridge")

    def compile(self, text, *, typecheck=False):
        with tempfile.TemporaryDirectory(prefix="maaso-location-native-") as temp:
            folder = Path(temp)
            source = folder / "main.swift"
            source.write_text(text)
            command = ["xcrun", "swiftc", "-module-cache-path", str(folder / "cache")]
            if typecheck:
                command += ["-typecheck", str(source)]
            else:
                command += [str(source), "-o", str(folder / "fixture")]
            build = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            if not typecheck:
                run = subprocess.run([str(folder / "fixture")], capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stderr)

    def test_ios_actual_bridge_contract(self):
        self.compile(SWIFT_PLATFORM + SWIFT_GEOCODER + self.bridge(IOS) + SWIFT_CASES)

    def test_macos_actual_bridge_contract(self):
        self.compile(SWIFT_PLATFORM + SWIFT_GEOCODER + self.bridge(MAC) + SWIFT_CASES)

    def test_apple_real_corelocation_api_compiles(self):
        for path in [IOS, MAC]:
            with self.subTest(platform=path.parent.parent.name):
                self.compile("import CoreLocation\n" + SWIFT_PLATFORM + self.bridge(path), typecheck=True)

    def test_permissions_are_foreground_and_city_purpose_is_localized(self):
        info = plistlib.loads((ROOT / "ios/Runner/Info.plist").read_bytes())
        self.assertIn("NSLocationWhenInUseUsageDescription", info)
        self.assertFalse(any("LocationAlways" in key for key in info))
        self.assertNotIn("location", info.get("UIBackgroundModes", []))
        project = (ROOT / "ios/Runner.xcodeproj/project.pbxproj").read_text()
        self.assertIn("InfoPlist.strings in Resources", project)
        for language in ["en", "zh-Hans"]:
            strings = ROOT / f"ios/Runner/{language}.lproj/InfoPlist.strings"
            self.assertIn("NSLocationWhenInUseUsageDescription", strings.read_text())
            self.assertIn(f"{language}.lproj/InfoPlist.strings", project)
        self.assertIn("BYPASS_PERMISSION_LOCATION_ALWAYS=1", (ROOT / "ios/Podfile").read_text())
        android = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml")
        namespace = "{http://schemas.android.com/apk/res/android}"
        permissions = {item.get(namespace + "name"): item for item in android.findall("uses-permission")}
        for name in ["ACCESS_COARSE_LOCATION", "ACCESS_FINE_LOCATION"]:
            self.assertIsNone(permissions[f"android.permission.{name}"].get(namespace + "maxSdkVersion"))
        self.assertNotIn("android.permission.ACCESS_BACKGROUND_LOCATION", permissions)
        self.assertEqual(permissions["android.permission.BLUETOOTH_SCAN"].get(namespace + "usesPermissionFlags"), "neverForLocation")
        for path in ["macos/Runner/DebugProfile.entitlements", "macos/Runner/Release.entitlements"]:
            self.assertTrue(plistlib.loads((ROOT / path).read_bytes())["com.apple.security.personal-information.location"])

    def test_android_bounded_foreground_dispatch_and_no_address_projection(self):
        source = ANDROID.read_text()
        bridge = swift_function(source, "private class MaasoCityGeocoderBridge")
        self.assertIn("Build.VERSION_CODES.TIRAMISU", bridge)
        self.assertIn("Geocoder.GeocodeListener", bridge)
        self.assertIn("worker.submit", bridge)
        self.assertIn("ArrayBlockingQueue(1)", bridge)
        self.assertIn("postDelayed(timeout, 10_000L)", bridge)
        self.assertIn("pendingRequest != request", bridge)
        self.assertIn("setForeground(false)", swift_function(source, "override fun onStop()"))
        self.assertIn("locationBridge?.dispose()", swift_function(source, "override fun onDestroy()"))
        for private_field in ["getAddressLine", "thoroughfare", "postalCode", "featureName", "Log."]:
            self.assertNotIn(private_field, bridge)

    def test_android_actual_bridge_compiles_against_platform_sdk(self):
        wrappers = Path.home() / ".gradle/wrapper/dists"
        compilers = sorted(wrappers.glob("*/**/lib/kotlin-compiler-embeddable-*.jar"))
        sdks = sorted((Path.home() / "Library/Android/sdk/platforms").glob("android-3*/android.jar"))
        if not compilers or not sdks:
            self.skipTest("Cached Kotlin compiler or Android platform SDK is unavailable")
        compiler_lib = compilers[-1].parent
        compiler_classpath = str(compiler_lib / "*")
        classpath = os.pathsep.join([str(sdks[-1])] + [str(path) for path in compiler_lib.glob("*.jar")])
        bridge = swift_function(ANDROID.read_text(), "private class MaasoCityGeocoderBridge")
        declarations = """
import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.Locale
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Future
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
class MethodChannel {
    data class Call(val method: String, val arguments: Any?)
    interface Result { fun success(value: Any?); fun notImplemented() }
    fun setMethodCallHandler(callback: ((Call, Result) -> Unit)?) {}
}
"""
        with tempfile.TemporaryDirectory(prefix="maaso-location-android-sdk-") as temp:
            source = Path(temp) / "Location.kt"
            source.write_text(declarations + bridge)
            build = subprocess.run([
                "java", "-cp", compiler_classpath,
                "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                "-no-stdlib", "-no-reflect", "-classpath", classpath,
                "-d", str(Path(temp) / "classes"), str(source),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)


if __name__ == "__main__":
    unittest.main()
