#!/usr/bin/env python3
"""Exercise the production ObjC++ guard with real Cocoa notifications.

Window/application stand-ins avoid opening UI or starting Unity. The helper
functions are extracted unchanged; the complete plugin is separately compiled
with clang's syntax-only check. This does not claim a Stage Manager visual test.
"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "unity/masso_avatar/Assets/Plugins/macOS/MaasoDesktopAvatarPortalBridge.mm"

PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <atomic>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unistd.h>

@interface GuardFixtureWindow : NSObject
@property(nonatomic) CGFloat alphaValue;
@property(nonatomic) BOOL ignoresMouseEvents;
@property(nonatomic) NSWindowCollectionBehavior collectionBehavior;
@property(nonatomic) BOOL isVisible;
@property(nonatomic) NSRect frame;
@property(nonatomic) NSInteger alphaWrites;
@property(nonatomic) NSInteger mouseWrites;
@property(nonatomic) NSInteger behaviorWrites;
@property(nonatomic) NSInteger orderOutCalls;
@property(nonatomic) BOOL notifyDuringOrderOut;
@property(nonatomic) NSInteger visibleOrderRequests;
@property(nonatomic) NSInteger regardlessCalls;
@property(nonatomic) NSWindowOrderingMode lastOrderingMode;
@property(nonatomic) NSInteger lastRelativeWindow;
- (void)orderOut:(id)sender;
- (void)orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)other;
- (void)orderFrontRegardless;
@end
@implementation GuardFixtureWindow
@synthesize alphaValue = _alphaValue;
@synthesize ignoresMouseEvents = _ignoresMouseEvents;
@synthesize collectionBehavior = _collectionBehavior;
- (void)setAlphaValue:(CGFloat)value {
  _alphaValue = value;
  self.alphaWrites += 1;
}
- (void)setIgnoresMouseEvents:(BOOL)value {
  _ignoresMouseEvents = value;
  self.mouseWrites += 1;
}
- (void)setCollectionBehavior:(NSWindowCollectionBehavior)value {
  _collectionBehavior = value;
  self.behaviorWrites += 1;
}
- (void)orderOut:(id)sender {
  self.orderOutCalls += 1;
  // Emulate the nested window notification before visibility has settled.
  if (self.notifyDuringOrderOut) {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSWindowDidUpdateNotification object:self];
  }
  self.isVisible = NO;
}
- (void)orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)other {
  self.lastOrderingMode = place;
  self.lastRelativeWindow = other;
  self.isVisible = place != NSWindowOut;
  if (self.isVisible) self.visibleOrderRequests += 1;
}
- (void)orderFrontRegardless {
  self.regardlessCalls += 1;
  [self orderWindow:NSWindowAbove relativeTo:0];
}
@end

@interface GuardFixtureApplication : NSObject
@property(nonatomic) NSApplicationActivationPolicy activationPolicy;
@property(nonatomic, copy) NSArray<GuardFixtureWindow *> *windows;
@property(nonatomic) NSInteger activationWrites;
@end
@implementation GuardFixtureApplication
@synthesize activationPolicy = _activationPolicy;
- (void)setActivationPolicy:(NSApplicationActivationPolicy)value {
  _activationPolicy = value;
  self.activationWrites += 1;
}
@end

static GuardFixtureApplication *fixtureApp;
#undef NSApp
#define NSApp fixtureApp
#define NSWindow GuardFixtureWindow
'''

CHECKS = r'''
static int checks = 0;
static int failures = 0;
static void Check(bool condition, const char *name) {
  checks += 1;
  if (!condition) { failures += 1; fprintf(stderr, "FAIL: %s\n", name); }
}
static GuardFixtureWindow *NewWindow() {
  GuardFixtureWindow *window = [GuardFixtureWindow new];
  window.alphaValue = 1;
  window.isVisible = YES;
  window.frame = NSMakeRect(23, 45, 1024, 768);
  window.collectionBehavior = NSWindowCollectionBehaviorManaged |
      NSWindowCollectionBehaviorStationary |
      NSWindowCollectionBehaviorParticipatesInCycle |
      NSWindowCollectionBehaviorFullScreenAuxiliary;
  return window;
}
static void ValidEnvironment() {
  setenv("MAASO_AVATAR_SESSION_TOKEN", std::string(43, 'A').c_str(), 1);
  setenv("MAASO_AVATAR_SOCKET_PATH", "/tmp/maaso-window-guard-fixture.sock", 1);
  setenv("MAASO_AVATAR_PARENT_PID", std::to_string(getppid()).c_str(), 1);
}
static void CheckHidden(GuardFixtureWindow *window, const char *name) {
  Check(!window.isVisible, name);
  Check(window.alphaValue == 0, "helper alpha is zero");
  Check(window.ignoresMouseEvents, "helper does not intercept input");
  Check((window.collectionBehavior & NSWindowCollectionBehaviorTransient) != 0,
        "helper is transient");
  Check((window.collectionBehavior & NSWindowCollectionBehaviorIgnoresCycle) != 0,
        "helper is excluded from window cycle");
  Check((window.collectionBehavior & (NSWindowCollectionBehaviorManaged |
        NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorParticipatesInCycle)) == 0,
        "conflicting collection behaviors removed");
  Check((window.collectionBehavior & NSWindowCollectionBehaviorFullScreenAuxiliary) != 0,
        "unrelated collection behavior preserved");
  Check(NSEqualRects(window.frame, NSMakeRect(23, 45, 1024, 768)),
        "render window frame unchanged");
}

int main() {
  @autoreleasepool {
    fixtureApp = [GuardFixtureApplication new];
    fixtureApp.activationPolicy = NSApplicationActivationPolicyRegular;
    GuardFixtureWindow *initial = NewWindow();
    fixtureApp.windows = @[initial];

    unsetenv("MAASO_AVATAR_SESSION_TOKEN");
    unsetenv("MAASO_AVATAR_SOCKET_PATH");
    unsetenv("MAASO_AVATAR_PARENT_PID");
    RequestWindowSuppression();
    Check(initial.isVisible && initial.alphaValue == 1, "ordinary app untouched");
    Check(fixtureApp.activationPolicy == NSApplicationActivationPolicyRegular,
          "ordinary app policy unchanged");
    Check(window_guard_observers == nil, "ordinary app has no observers");
    [initial orderWindow:NSWindowAbove relativeTo:17];
    Check(initial.isVisible && initial.lastRelativeWindow == 17,
          "ordinary app above ordering unchanged");
    [initial orderWindow:NSWindowBelow relativeTo:19];
    Check(initial.isVisible && initial.lastRelativeWindow == 19,
          "ordinary app below ordering unchanged");
    [initial orderFrontRegardless];
    Check(initial.regardlessCalls == 1, "ordinary app regardless call unchanged");
    initial.alphaValue = 0.7;
    Check(initial.alphaValue == 0.7, "ordinary app alpha unchanged");
    initial.alphaValue = 1;
    const IMP originalOrder = class_getMethodImplementation(
        [GuardFixtureWindow class], @selector(orderWindow:relativeTo:));
    const IMP originalAlpha = class_getMethodImplementation(
        [GuardFixtureWindow class], @selector(setAlphaValue:));

    ValidEnvironment();
    setenv("MAASO_AVATAR_SESSION_TOKEN", "invalid", 1);
    Check(!IsHostedSidecar(), "short token rejected");
    ValidEnvironment();
    setenv("MAASO_AVATAR_SESSION_TOKEN", std::string(43, '!').c_str(), 1);
    Check(!IsHostedSidecar(), "invalid token alphabet rejected");
    ValidEnvironment();
    setenv("MAASO_AVATAR_SOCKET_PATH", "relative.sock", 1);
    Check(!IsHostedSidecar(), "relative endpoint rejected");
    ValidEnvironment();
    setenv("MAASO_AVATAR_SOCKET_PATH", ("/" + std::string(104, 'a')).c_str(), 1);
    Check(!IsHostedSidecar(), "oversize endpoint rejected");
    ValidEnvironment();
    setenv("MAASO_AVATAR_PARENT_PID", "1", 1);
    Check(!IsHostedSidecar(), "unhosted process rejected");
    ValidEnvironment();
    setenv("MAASO_AVATAR_PARENT_PID", "999999999999999999999999", 1);
    Check(!IsHostedSidecar(), "overflow parent rejected");
    ValidEnvironment();
    setenv("MAASO_AVATAR_PARENT_PID", "+2", 1);
    Check(!IsHostedSidecar(), "noncanonical parent rejected");
    RequestWindowSuppression();
    Check(window_guard_observers == nil && initial.isVisible,
          "invalid environment cannot install guard");

    ValidEnvironment();
    Check(IsHostedSidecar(), "hosted fixture accepted");
    initial.notifyDuringOrderOut = YES;
    RequestWindowSuppression();
    CheckHidden(initial, "initial window hidden synchronously");
    Check(fixtureApp.activationPolicy == NSApplicationActivationPolicyAccessory,
          "accessory still allows graphics window creation");
    Check(window_guard_observers.count == 9, "lifecycle guard installed once");
    Check(initial.orderOutCalls == 1, "nested notification does not reenter");
    GuardFixtureWindow *preDisplay = NewWindow();
    // This object is deliberately absent from NSApp.windows and sends no
    // notification: the production hook must act before the original order.
    [preDisplay orderWindow:NSWindowAbove relativeTo:42];
    CheckHidden(preDisplay, "first above request cannot expose a new helper window");
    Check(preDisplay.visibleOrderRequests == 0,
          "above is suppressed before window server ordering");
    [preDisplay orderWindow:NSWindowBelow relativeTo:43];
    Check(preDisplay.lastOrderingMode == NSWindowOut &&
          preDisplay.lastRelativeWindow == 0 && preDisplay.visibleOrderRequests == 0,
          "below is translated to out before presentation");
    [preDisplay orderWindow:NSWindowOut relativeTo:44];
    Check(preDisplay.lastOrderingMode == NSWindowOut &&
          preDisplay.lastRelativeWindow == 44, "out keeps original ordering semantics");
    [preDisplay orderFrontRegardless];
    Check(!preDisplay.isVisible && preDisplay.regardlessCalls == 0 &&
          preDisplay.visibleOrderRequests == 0, "regardless cannot bypass pre-display guard");
    preDisplay.alphaValue = 1;
    Check(preDisplay.alphaValue == 0, "Unity alpha restore is clamped before write");
    NSArray *observers = window_guard_observers;
    const NSInteger alphaWrites = initial.alphaWrites;
    const NSInteger mouseWrites = initial.mouseWrites;
    const NSInteger behaviorWrites = initial.behaviorWrites;
    const NSInteger activationWrites = fixtureApp.activationWrites;
    for (int frame = 0; frame < 300; ++frame) {
      RequestWindowSuppression();
      [[NSNotificationCenter defaultCenter]
          postNotificationName:NSWindowDidUpdateNotification object:initial];
    }
    Check(observers == window_guard_observers, "repeated compatibility calls do not reinstall");
    Check(initial.orderOutCalls == 1, "already hidden windows are not reordered");
    Check(initial.alphaWrites == alphaWrites && initial.mouseWrites == mouseWrites &&
          initial.behaviorWrites == behaviorWrites &&
          fixtureApp.activationWrites == activationWrites,
          "settled window notifications do not perpetuate property writes");

    GuardFixtureWindow *late = NewWindow();
    fixtureApp.windows = @[initial, late];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSWindowDidBecomeMainNotification object:late];
    CheckHidden(late, "window created after initial capture is hidden");
    Check(late.orderOutCalls == 1, "late window hidden once");

    NSArray<NSNotificationName> *events = @[
      NSApplicationWillFinishLaunchingNotification,
      NSApplicationDidFinishLaunchingNotification,
      NSApplicationDidBecomeActiveNotification,
      NSApplicationDidUnhideNotification,
      NSWindowDidBecomeKeyNotification,
      NSWindowDidBecomeMainNotification,
      NSWindowDidExposeNotification,
      NSWindowDidUpdateNotification,
      NSWindowDidChangeOcclusionStateNotification,
    ];
    for (NSNotificationName event in events) {
      late.alphaValue = 1;
      late.isVisible = YES;
      fixtureApp.activationPolicy = NSApplicationActivationPolicyRegular;
      [[NSNotificationCenter defaultCenter] postNotificationName:event object:late];
      CheckHidden(late, "reopened window hidden by real notification callback");
      Check(fixtureApp.activationPolicy == NSApplicationActivationPolicyAccessory,
            "reactivation does not expose regular app policy");
    }

    const uint64_t oldEpoch = window_guard_epoch.load();
    RemoveWindowSuppression();
    Check(window_guard_observers == nil, "unload detaches observers");
    Check(class_getMethodImplementation([GuardFixtureWindow class],
          @selector(orderWindow:relativeTo:)) == originalOrder &&
          class_getMethodImplementation([GuardFixtureWindow class],
          @selector(setAlphaValue:)) == originalAlpha,
          "unload restores original Objective-C methods");
    [preDisplay orderWindow:NSWindowAbove relativeTo:45];
    preDisplay.alphaValue = 0.8;
    Check(preDisplay.isVisible && preDisplay.lastRelativeWindow == 45 &&
          preDisplay.alphaValue == 0.8, "unloaded helper does not retain method interception");
    late.alphaValue = 1;
    late.isVisible = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSWindowDidExposeNotification object:late];
    SuppressPlayerWindows(oldEpoch);
    InstallWindowSuppression(oldEpoch);
    Check(late.isVisible && late.alphaValue == 1,
          "unloaded and stale callbacks do not modify a window");
    Check(window_guard_observers == nil, "stale install cannot recreate guard");

    dispatch_semaphore_t queued = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      RequestWindowSuppression();
      dispatch_semaphore_signal(queued);
    });
    dispatch_semaphore_wait(queued, DISPATCH_TIME_FOREVER);
    RemoveWindowSuppression();
    RemoveWindowSuppression();
    Check(class_getMethodImplementation([GuardFixtureWindow class],
          @selector(orderWindow:relativeTo:)) == originalOrder,
          "unload is idempotent");
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    Check(window_guard_observers == nil && late.isVisible,
          "queued background install is invalidated by unload");

    RequestWindowSuppression();
    CheckHidden(late, "later plugin lifetime can install a fresh guard");
    RemoveWindowSuppression();
    fixtureApp = nil;
    fprintf(stdout, "%d checks, %d failures (production ObjC++ helpers; Cocoa notifications; no UI)\n",
            checks, failures);
    return failures == 0 ? 0 : 1;
  }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Cocoa/clang")
class SidecarWindowSuppressionTest(unittest.TestCase):
    def test_production_lifecycle_guard(self):
        source = SOURCE.read_text()
        begin = source.index("std::atomic<uint64_t> window_guard_epoch")
        end = source.index("struct PortalFrameSubmission", begin)
        helpers = source[begin:end]
        with tempfile.TemporaryDirectory(prefix="maaso-sidecar-window-test-") as temp:
            test_source = Path(temp) / "guard.mm"
            executable = Path(temp) / "guard"
            test_source.write_text(PREAMBLE + helpers + CHECKS)
            subprocess.run([
                "xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-fblocks",
                "-framework", "Foundation", "-framework", "AppKit",
                str(test_source), "-o", str(executable),
            ], check=True, timeout=60)
            result = subprocess.run(
                [str(executable)], text=True, capture_output=True, timeout=20
            )
            print(result.stdout.strip())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_preloaded_metal_interface_becomes_available_on_later_render_event(self):
        source = SOURCE.read_text()
        begin = source.index("IUnityGraphicsMetalV2 *ResolveMetalInterface()")
        end = source.index("\nbool EnsureColorCopyPipeline", begin)
        resolver = source[begin:end]
        fixture = r'''
#include <cstdio>
struct IUnityGraphicsMetalV2 {};
struct IUnityInterfaces {
  IUnityGraphicsMetalV2 *available = nullptr;
  int queries = 0;
  template <typename T> T *Get() {
    ++queries;
    return reinterpret_cast<T *>(available);
  }
};
IUnityInterfaces *unity_interfaces = nullptr;
IUnityGraphicsMetalV2 *unity_metal = nullptr;
'''
        checks = r'''
int main() {
  if (ResolveMetalInterface() != nullptr) return 1;
  IUnityInterfaces interfaces;
  unity_interfaces = &interfaces;
  if (ResolveMetalInterface() != nullptr || interfaces.queries != 1) return 2;
  if (ResolveMetalInterface() != nullptr || interfaces.queries != 2) return 3;
  IUnityGraphicsMetalV2 graphics;
  interfaces.available = &graphics;
  if (ResolveMetalInterface() != &graphics || interfaces.queries != 3) return 4;
  if (ResolveMetalInterface() != &graphics || interfaces.queries != 3) return 5;
  // These are the production unload assignments. A later plugin lifetime
  // must never reuse an interface from the preceding renderer.
  unity_interfaces = nullptr;
  unity_metal = nullptr;
  if (ResolveMetalInterface() != nullptr || interfaces.queries != 3) return 6;
  std::puts("6 checks, 0 failures (production Metal interface resolver)");
}
'''
        with tempfile.TemporaryDirectory(prefix="maaso-sidecar-metal-test-") as temp:
            test_source = Path(temp) / "resolver.cpp"
            executable = Path(temp) / "resolver"
            test_source.write_text(fixture + resolver + checks)
            subprocess.run([
                "xcrun", "clang++", "-std=c++17", str(test_source), "-o", str(executable)
            ], check=True, timeout=30)
            result = subprocess.run(
                [str(executable)], text=True, capture_output=True, timeout=10
            )
            print(result.stdout.strip())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The actual render event must reach the resolver; visibility and
        # window frame are deliberately absent from IOSurface capture gating.
        begin = source.index("void UNITY_INTERFACE_API RenderPortalFrame(")
        end = source.index("\n}  // namespace", begin)
        render = source[begin:end]
        self.assertIn("ResolveMetalInterface()", render)
        for ui_dependency in ("NSApp", "isVisible", "alphaValue", "orderWindow"):
            self.assertNotIn(ui_dependency, render)


if __name__ == "__main__":
    unittest.main(verbosity=2)
