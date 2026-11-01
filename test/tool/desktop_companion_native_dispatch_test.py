"""Execute native dispatch and receipt code with inert window/Flutter adapters."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from native_source_helpers import swift_function

ROOT = Path(__file__).resolve().parents[2]


class DesktopCompanionNativeDispatchTests(unittest.TestCase):
    def compile_and_run(self, program, suffix):
        with tempfile.TemporaryDirectory(prefix="maaso-native-display-") as temp:
            folder = Path(temp)
            source = folder / ("dispatch" + suffix)
            source.write_text(program)
            executable = folder / "dispatch"
            if suffix == ".swift":
                command = ["xcrun", "swiftc", "-module-cache-path", str(folder / "cache")]
            else:
                command = ["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror"]
            build = subprocess.run(command + [str(source), "-o", str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(executable)], capture_output=True,
                                 text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift SDK")
    def test_mac_dispatch_generation_world_capture_and_retired_calls(self):
        source = (ROOT / "macos/Runner/MacOSUnityAvatarPortal.swift").read_text()
        bridge = source[source.index("final class MacOSDesktopCompanionBridge"):]
        methods = "\n".join(swift_function(bridge, marker) for marker in [
            "private func handle(", "fileprivate func accept(frame:",
            "func clearAvatarFrame()", "fileprivate func setWorldCaptureActive(",
        ]).replace("private func handle(", "func handle(", 1)
        program = r'''
import Foundation
import CoreFoundation
import Dispatch
typealias FlutterResult = (Any?) -> Void
final class FlutterError {
  let code: String
  init(code: String, message: String?, details: Any?) { self.code = code }
}
final class NotImplemented {}
let FlutterMethodNotImplemented = NotImplemented()
struct FlutterMethodCall { let method: String; let arguments: Any? }
struct MacOSUnitySurfaceFrame { let valid: Bool }
struct MacOSDesktopCompanionPresentationConfiguration {
  static func parse(_ value: Any?) -> Self? { value == nil ? nil : Self() }
}
final class Renderer {
  func makeImage(frame: MacOSUnitySurfaceFrame) -> Int? { frame.valid ? 1 : nil }
}
final class Panel {
  var visible = false
  var generation = 0
  var showCalls = 0
  var hideCalls = 0
  var images = 0
  var clearedImages = 0
  var disposeCalls = 0
  var menuConfiguration = 0
  func showPanel(interactionGeneration: Int) {
    visible = true; generation = interactionGeneration; showCalls += 1
  }
  func hidePanel() { visible = false; hideCalls += 1 }
  func setAvatarImage(_ image: Int) { images += 1 }
  func clearAvatarImage() { clearedImages += 1 }
  func clearBubble() {}
  func showBubble(text: String) {}
  func applyPresentation(_ value: MacOSDesktopCompanionPresentationConfiguration) {}
  func dispose() { disposeCalls += 1; visible = false }
}
final class Bridge {
  static let maximumBubbleLength = 420
  var worldCaptureActive = false
  let surfaceRenderer = Renderer()
  var panel: Panel? = Panel()
  var menuConfiguration = 0
  var presentationConfiguration = MacOSDesktopCompanionPresentationConfiguration()
  func ensurePanel() -> Panel { panel! }
  static func parseMenuConfiguration(_ value: Any?) -> Int? { 0 }
METHODS
}
func invoke(_ bridge: Bridge, _ method: String, _ args: Any?) -> Any? {
  var calls = 0
  var output: Any?
  bridge.handle(FlutterMethodCall(method: method, arguments: args)) {
    calls += 1; output = $0
  }
  precondition(calls == 1)
  return output
}
let bridge = Bridge()
let panel = bridge.panel!
let valid: [String: Any] = ["interactionGeneration": 23]
precondition(invoke(bridge, "show", valid) == nil)
precondition(panel.visible && panel.generation == 23 && panel.showCalls == 1)
for method in ["handoff.prepareHidden", "handoff.prepareDeparture", "handoff.awaitFrame",
               "handoff.enter", "handoff.exit", "handoff.cancel"] {
  precondition(invoke(bridge, method, ["handoffId": "retired", "generation": 1]) is NotImplemented)
  precondition(panel.visible && panel.showCalls == 1 && panel.hideCalls == 0)
  precondition(panel.generation == 23 && panel.images == 0)
}
for invalid in [NSNull(), [:], ["interactionGeneration": true], ["interactionGeneration": 0],
                ["interactionGeneration": 1.5], ["interactionGeneration": "23"],
                ["interactionGeneration": Int64(Int32.max) + 1],
                ["interactionGeneration": 23, "extra": 1]] as [Any] {
  precondition((invoke(bridge, "show", invalid) as? FlutterError)?.code == "invalid_desktop_companion_generation")
  precondition(panel.showCalls == 1 && panel.visible && panel.generation == 23)
}
bridge.accept(frame: MacOSUnitySurfaceFrame(valid: true))
precondition(panel.images == 1 && panel.visible)
bridge.accept(frame: MacOSUnitySurfaceFrame(valid: false))
precondition(panel.clearedImages == 1)
bridge.setWorldCaptureActive(true)
precondition(!panel.visible && panel.clearedImages == 2)
bridge.accept(frame: MacOSUnitySurfaceFrame(valid: true))
precondition(panel.images == 1)
precondition((invoke(bridge, "show", valid) as? FlutterError)?.code == "desktop_companion_world_capture_active")
precondition(invoke(bridge, "handoff.enter", valid) is NotImplemented)
precondition(!panel.visible && panel.showCalls == 1)
bridge.setWorldCaptureActive(false)
precondition(invoke(bridge, "show", ["interactionGeneration": 24]) == nil)
precondition(panel.visible && panel.generation == 24)
precondition(invoke(bridge, "hide", nil) == nil && !panel.visible)
precondition(invoke(bridge, "show", ["interactionGeneration": 25]) == nil)
precondition(invoke(bridge, "dispose", nil) == nil && bridge.panel == nil)
precondition(panel.disposeCalls == 1 && !panel.visible)
'''
        self.compile_and_run(program.replace("METHODS", methods), ".swift")

    def test_windows_dispatch_generation_first_frame_and_retired_calls(self):
        source = (ROOT / "windows/runner/windows_desktop_companion_host.cpp").read_text()
        methods = "\n".join(swift_function(source, marker) for marker in [
            "void WindowsDesktopCompanionHost::HandleMethodCall(",
            "void WindowsDesktopCompanionHost::CompletePendingShow()",
            "void WindowsDesktopCompanionHost::FailPendingShow(",
            "void WindowsDesktopCompanionHost::Hide()",
        ])
        parsers = "\n".join(swift_function(source, marker) for marker in [
            "const flutter::EncodableValue* FindValue(",
            "const std::string* ReadString(", "bool ReadInt(",
        ])
        program = r'''
#include <cassert>
#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <variant>
namespace flutter {
class EncodableValue;
using EncodableMap = std::map<EncodableValue, EncodableValue>;
class EncodableValue : public std::variant<std::monostate, bool, int32_t, int64_t, double, std::string, EncodableMap> {
 public:
  using variant::variant;
  EncodableValue(const char* value) : variant(std::string(value)) {}
  bool operator<(const EncodableValue& other) const {
    return std::get<std::string>(*this) < std::get<std::string>(other);
  }
};
template<class T> struct MethodCall {
  std::string name; T value;
  const std::string& method_name() const { return name; }
  const T* arguments() const { return &value; }
};
struct State { int callbacks = 0; std::string outcome; };
template<class T> struct MethodResult {
  State& state;
  explicit MethodResult(State& state) : state(state) {}
  void Success() { ++state.callbacks; state.outcome = "success"; }
  void Error(const std::string& code, const std::string&) { ++state.callbacks; state.outcome = code; }
  void NotImplemented() { ++state.callbacks; state.outcome = "notImplemented"; }
};
}
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;
using Map = flutter::EncodableMap;
using HWND = void*;
constexpr int FALSE = 0, SW_HIDE = 0;
int native_hides = 0;
void InvalidateRect(HWND, void*, int) {}
void ShowWindow(HWND, int) { ++native_hides; }
void KillTimer(HWND, int) {}
PARSERS
std::string WideToUtf8(const std::wstring&) { return {}; }
std::wstring Utf8ToWide(const std::string& value) { return {value.begin(), value.end()}; }
std::wstring Trimmed(std::wstring value) { return value; }
struct Player { int stops = 0, discards = 0; void Stop() { ++stops; } void DiscardPendingAvatarCommands() { ++discards; } };
class WindowsDesktopCompanionHost {
 public:
  static constexpr size_t kMaximumBubbleCharacters = 420;
  static constexpr int kGazeTimerId = 1;
  HWND bubble_window_ = reinterpret_cast<void*>(1), overlay_window_ = reinterpret_cast<void*>(2), pet_window_ = reinterpret_cast<void*>(3);
  Player* pet_unity_player_host_;
  std::unique_ptr<Result> pending_show_result_;
  uint64_t avatar_startup_deadline_ = 0;
  bool visible_ = false;
  int generation = 0, shows = 0, drag_cancels = 0, alpha_clears = 0, gaze_clears = 0;
  std::wstring bubble_text_;
  explicit WindowsDesktopCompanionHost(Player& player) : pet_unity_player_host_(&player) {}
  void HandleMethodCall(const flutter::MethodCall<Value>&, std::unique_ptr<Result>);
  void CompletePendingShow();
  void FailPendingShow(const char*, const std::string&);
  void Hide();
  bool Show(std::wstring*, int32_t next) { generation = next; visible_ = true; ++shows; avatar_startup_deadline_ = 100; return true; }
  void Dispose() { Hide(); }
  void CancelDrag() { ++drag_cancels; }
  void ClearAvatarHitRegion() { ++alpha_clears; }
  void ClearGaze() { ++gaze_clears; }
  void ConfigurePresentation(const Map&, std::unique_ptr<Result> result) { result->Success(); }
  void ConfigureMenu(const Map&, std::unique_ptr<Result> result) { result->Success(); }
};
METHODS
void invoke(WindowsDesktopCompanionHost& host, flutter::State& state, const char* method, Value args = {}) {
  host.HandleMethodCall(flutter::MethodCall<Value>{method, args}, std::make_unique<Result>(state));
}
int main() {
  Player player; WindowsDesktopCompanionHost host(player);
  flutter::State first;
  invoke(host, first, "show", Map{{"interactionGeneration", int32_t{23}}});
  assert(first.callbacks == 0 && host.visible_ && host.generation == 23 && host.shows == 1);
  for (const char* method : {"handoff.prepareHidden", "handoff.prepareDeparture", "handoff.awaitFrame", "handoff.enter", "handoff.exit", "handoff.cancel"}) {
    flutter::State state; invoke(host, state, method, Map{{"handoffId", "retired"}, {"generation", int32_t{1}}});
    assert(state.callbacks == 1 && state.outcome == "notImplemented");
    assert(host.visible_ && host.shows == 1 && host.generation == 23 && player.stops == 0);
  }
  flutter::State pending; invoke(host, pending, "show", Map{{"interactionGeneration", int32_t{24}}});
  assert(pending.outcome == "windows_desktop_companion_show_in_progress" && host.shows == 1);
  host.CompletePendingShow(); assert(first.callbacks == 1 && first.outcome == "success");
  for (const Value& invalid : {Value{}, Value(Map{}), Value(Map{{"interactionGeneration", true}}),
       Value(Map{{"interactionGeneration", int32_t{0}}}), Value(Map{{"interactionGeneration", 1.5}}),
       Value(Map{{"interactionGeneration", "23"}}), Value(Map{{"interactionGeneration", int64_t{2147483648}}}),
       Value(Map{{"interactionGeneration", int32_t{23}}, {"extra", int32_t{1}}})}) {
    flutter::State state; invoke(host, state, "show", invalid);
    assert(state.outcome == "invalid_desktop_companion_show" && state.callbacks == 1);
    assert(host.shows == 1 && host.visible_ && host.generation == 23);
  }
  flutter::State second; invoke(host, second, "show", Map{{"interactionGeneration", int32_t{25}}});
  flutter::State hidden; invoke(host, hidden, "hide");
  assert(hidden.outcome == "success" && hidden.callbacks == 1 && !host.visible_);
  assert(second.callbacks == 1 && second.outcome == "windows_desktop_companion_show_cancelled");
  assert(host.avatar_startup_deadline_ == 0 && native_hides == 3);
  assert(player.stops == 1 && player.discards == 1 && host.drag_cancels == 1 && host.alpha_clears == 1 && host.gaze_clears == 1);
  flutter::State third; invoke(host, third, "show", Map{{"interactionGeneration", int32_t{26}}});
  assert(host.generation == 26 && host.visible_);
  host.CompletePendingShow(); assert(third.outcome == "success");
}
'''
        self.compile_and_run(program.replace("METHODS", methods).replace("PARSERS", parsers), ".cpp")

    def test_windows_results_keep_main_authority_and_pet_phone_receipts(self):
        source = (ROOT / "windows/runner/flutter_window.cpp").read_text()
        selector = swift_function(source, "bool IsPhoneInteractionResult(")
        dispatch = swift_function(source, "  if (message == WM_COPYDATA) {")
        program = r'''
#include <cassert>
#include <memory>
#include <regex>
#include <string>
#include <vector>
namespace flutter { struct EncodableValue { std::string value; explicit EncodableValue(std::string value) : value(value) {} }; }
constexpr int WM_COPYDATA = 1, TRUE = 1;
struct COPYDATASTRUCT { bool pet; std::string type, payload; };
struct Player {
  bool pet, running = true;
  bool HandleAvatarCopyData(const COPYDATASTRUCT* data, std::string* type, std::string* payload) {
    if (data->pet != pet) return false;
    // The production transport admits only its declared callback types.
    if (data->type != "commandResult" && data->type != "ready" && data->type != "log" && data->type != "error") return false;
    *type = data->type; *payload = data->payload; return true;
  }
  bool IsRunning() { return running; }
};
struct Pet { bool visible = true; bool IsVisible() { return visible; } };
struct Channel {
  std::vector<std::string> delivered;
  void InvokeMethod(const std::string& type, std::unique_ptr<flutter::EncodableValue> payload) {
    delivered.push_back(type + ":" + payload->value);
  }
};
SELECTOR
struct Window {
  std::unique_ptr<Player> unity_player_host_ = std::make_unique<Player>(Player{false, true});
  std::unique_ptr<Player> pet_unity_player_host_ = std::make_unique<Player>(Player{true, true});
  std::unique_ptr<Pet> desktop_companion_host_ = std::make_unique<Pet>();
  std::unique_ptr<Channel> unity_avatar_channel_ = std::make_unique<Channel>();
  int dispatch(int message, const COPYDATASTRUCT& data) {
    auto lparam = reinterpret_cast<uintptr_t>(&data);
DISPATCH
    return 0;
  }
};
int main() {
  Window window;
  const std::string load = R"json({"method":"loadAvatar","ok":true})json";
  window.dispatch(1, COPYDATASTRUCT{false, "commandResult", load});
  window.dispatch(1, COPYDATASTRUCT{true, "commandResult", load});
  assert(window.unity_avatar_channel_->delivered.size() == 1);
  const std::string phone = R"json({"method":"setPhoneInteraction","ok":true})json";
  window.dispatch(1, COPYDATASTRUCT{false, "commandResult", phone});
  assert(window.unity_avatar_channel_->delivered.size() == 1);
  window.dispatch(1, COPYDATASTRUCT{true, "commandResult", phone});
  assert(window.unity_avatar_channel_->delivered.size() == 2);
  window.dispatch(1, COPYDATASTRUCT{false, "worldEvent", "world-state"});
  window.dispatch(1, COPYDATASTRUCT{true, "worldEvent", "pet-world"});
  assert(window.unity_avatar_channel_->delivered.size() == 2);
  window.unity_player_host_->running = false;
  window.dispatch(1, COPYDATASTRUCT{true, "commandResult", load});
  assert(window.unity_avatar_channel_->delivered.size() == 3);
  window.desktop_companion_host_->visible = false;
  window.unity_player_host_->running = true;
  window.dispatch(1, COPYDATASTRUCT{false, "commandResult", phone});
  window.dispatch(1, COPYDATASTRUCT{true, "commandResult", phone});
  assert(window.unity_avatar_channel_->delivered.size() == 4);
  assert(!IsPhoneInteractionResult(R"json({"method":"other","code":"setPhoneInteraction"})json"));
  assert(!IsPhoneInteractionResult(R"json({"method":"setPhoneInteractionOther"})json"));
}
'''
        self.compile_and_run(program.replace("SELECTOR", selector).replace("DISPATCH", dispatch), ".cpp")


if __name__ == "__main__":
    unittest.main()
