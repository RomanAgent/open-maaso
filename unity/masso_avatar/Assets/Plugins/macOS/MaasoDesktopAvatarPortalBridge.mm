#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

#include "IUnityGraphics.h"
#include "IUnityGraphicsMetal.h"

#include <atomic>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <memory>
#include <mutex>
#include <unistd.h>

namespace {
constexpr int kSurfaceSlotCount = 3;

// This player exists only to render IOSurfaces for the host app. Installing
// before scene load avoids a regular Unity window appearing during startup;
// observers also cover a later window recreation or system reactivation.
std::atomic<uint64_t> window_guard_epoch{0};
std::mutex window_guard_mutex;
__strong NSArray<id> *window_guard_observers = nil;
bool suppressing_player_windows = false;  // Main thread only.
std::atomic<bool> window_order_guard_enabled{false};
using WindowOrderMethod = void (*)(id, SEL, NSWindowOrderingMode, NSInteger);
using WindowRegardlessMethod = void (*)(id, SEL);
using WindowAlphaMethod = void (*)(id, SEL, CGFloat);
WindowOrderMethod original_window_order = nullptr;
WindowRegardlessMethod original_window_regardless = nullptr;
WindowAlphaMethod original_window_alpha = nullptr;

bool IsHostedSidecar() {
  const char *token = std::getenv("MAASO_AVATAR_SESSION_TOKEN");
  const char *endpoint = std::getenv("MAASO_AVATAR_SOCKET_PATH");
  const char *parent = std::getenv("MAASO_AVATAR_PARENT_PID");
  if (token == nullptr || std::strlen(token) != 43 ||
      endpoint == nullptr || endpoint[0] != '/' || std::strlen(endpoint) > 103 ||
      parent == nullptr || parent[0] == '\0') {
    return false;
  }
  for (const char *value = token; *value != '\0'; ++value) {
    if (!((*value >= 'A' && *value <= 'Z') ||
          (*value >= 'a' && *value <= 'z') ||
          (*value >= '0' && *value <= '9') || *value == '_' || *value == '-')) {
      return false;
    }
  }
  for (const char *value = parent; *value != '\0'; ++value) {
    if (*value < '0' || *value > '9') return false;
  }
  char *end = nullptr;
  const long parent_id = std::strtol(parent, &end, 10);
  return end != parent && *end == '\0' && parent_id > 1 &&
      parent_id <= INT_MAX && getppid() == parent_id;
}

void PrepareHiddenPlayerWindow(NSWindow *window) {
  if (window.alphaValue != 0) window.alphaValue = 0;
  if (!window.ignoresMouseEvents) window.ignoresMouseEvents = YES;
  const NSWindowCollectionBehavior conflict =
      NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorStationary |
      NSWindowCollectionBehaviorParticipatesInCycle;
  const NSWindowCollectionBehavior behavior = (window.collectionBehavior & ~conflict) |
      NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
  if (window.collectionBehavior != behavior) window.collectionBehavior = behavior;
}

void GuardedWindowOrder(id window, SEL selector, NSWindowOrderingMode place, NSInteger other) {
  if (window_order_guard_enabled.load()) {
    PrepareHiddenPlayerWindow(window);
    if (place != NSWindowOut) {
      place = NSWindowOut;
      other = 0;
    }
  }
  original_window_order(window, selector, place, other);
}

void GuardedWindowRegardless(id window, SEL selector) {
  if (!window_order_guard_enabled.load()) {
    original_window_regardless(window, selector);
    return;
  }
  PrepareHiddenPlayerWindow(window);
  original_window_order(window, @selector(orderWindow:relativeTo:), NSWindowOut, 0);
}

void GuardedWindowAlpha(id window, SEL selector, CGFloat alpha) {
  original_window_alpha(window, selector, window_order_guard_enabled.load() ? 0 : alpha);
}

void InstallWindowOrderingGuard(uint64_t epoch) {
  std::lock_guard<std::mutex> lock(window_guard_mutex);
  if (epoch != window_guard_epoch.load() || window_order_guard_enabled.load()) return;
  // Runtime method installation creates no NSApplication or window. This can
  // precede PlayerApplication/Metal startup through Unity's native preload.
  Method order = class_getInstanceMethod([NSWindow class], @selector(orderWindow:relativeTo:));
  Method regardless = class_getInstanceMethod([NSWindow class], @selector(orderFrontRegardless));
  Method alpha = class_getInstanceMethod([NSWindow class], @selector(setAlphaValue:));
  if (order == nullptr || regardless == nullptr || alpha == nullptr) return;
  original_window_order = reinterpret_cast<WindowOrderMethod>(method_getImplementation(order));
  original_window_regardless = reinterpret_cast<WindowRegardlessMethod>(method_getImplementation(regardless));
  original_window_alpha = reinterpret_cast<WindowAlphaMethod>(method_getImplementation(alpha));
  window_order_guard_enabled.store(true);
  method_setImplementation(alpha, reinterpret_cast<IMP>(GuardedWindowAlpha));
  method_setImplementation(order, reinterpret_cast<IMP>(GuardedWindowOrder));
  method_setImplementation(regardless, reinterpret_cast<IMP>(GuardedWindowRegardless));
}

void RestoreWindowOrderingGuard() {
  // The caller holds window_guard_mutex. Do not remove another component's
  // later method replacement if it has changed this helper's implementation.
  window_order_guard_enabled.store(false);
  const auto restore = [](SEL selector, IMP replacement, IMP original) {
    Method method = class_getInstanceMethod([NSWindow class], selector);
    if (method != nullptr && original != nullptr && method_getImplementation(method) == replacement) {
      method_setImplementation(method, original);
    }
  };
  restore(@selector(orderWindow:relativeTo:), reinterpret_cast<IMP>(GuardedWindowOrder),
          reinterpret_cast<IMP>(original_window_order));
  restore(@selector(orderFrontRegardless), reinterpret_cast<IMP>(GuardedWindowRegardless),
          reinterpret_cast<IMP>(original_window_regardless));
  restore(@selector(setAlphaValue:), reinterpret_cast<IMP>(GuardedWindowAlpha),
          reinterpret_cast<IMP>(original_window_alpha));
}

void SuppressPlayerWindows(uint64_t epoch) {
  if (epoch != window_guard_epoch.load() || ![NSThread isMainThread] ||
      NSApp == nil || suppressing_player_windows) return;
  suppressing_player_windows = true;
  @try {
    // Accessory matches LSUIElement and still permits Unity to initialize its
    // AppKit/Metal graphics window. Visibility is suppressed separately.
    if (NSApp.activationPolicy != NSApplicationActivationPolicyAccessory) {
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
    for (NSWindow *window in NSApp.windows) {
      PrepareHiddenPlayerWindow(window);
      if (window.isVisible) [window orderOut:nil];
    }
  } @finally {
    suppressing_player_windows = false;
  }
}

void InstallWindowSuppression(uint64_t epoch) {
  if (epoch != window_guard_epoch.load() || ![NSThread isMainThread]) return;
  {
    std::lock_guard<std::mutex> lock(window_guard_mutex);
    if (epoch != window_guard_epoch.load()) return;
    if (window_guard_observers == nil) {
      NSMutableArray<id> *observers = [NSMutableArray array];
      NSArray<NSNotificationName> *names = @[
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
      for (NSNotificationName name in names) {
        id observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:name object:nil queue:nil
            usingBlock:^(NSNotification *notification) {
              if ([NSThread isMainThread]) {
                SuppressPlayerWindows(epoch);
              } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                  SuppressPlayerWindows(epoch);
                });
              }
            }];
        [observers addObject:observer];
      }
      window_guard_observers = observers;
    }
  }
  SuppressPlayerWindows(epoch);
}

void RequestWindowSuppression() {
  if (!IsHostedSidecar()) return;
  const uint64_t epoch = window_guard_epoch.load();
  InstallWindowOrderingGuard(epoch);
  if ([NSThread isMainThread]) {
    InstallWindowSuppression(epoch);
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      InstallWindowSuppression(epoch);
    });
  }
}

void RemoveWindowSuppression() {
  // Invalidate already queued callbacks before detaching observers. Observer
  // removal does not need AppKit work or a synchronous main-thread dispatch.
  window_guard_epoch.fetch_add(1);
  NSArray<id> *observers;
  {
    std::lock_guard<std::mutex> lock(window_guard_mutex);
    observers = window_guard_observers;
    window_guard_observers = nil;
    RestoreWindowOrderingGuard();
  }
  for (id observer in observers) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
  }
}

struct PortalFrameSubmission {
  void *texture;
  int width;
  int height;
  int generation;
};

struct PortalSurfaceSlot {
  IOSurfaceRef surface = nullptr;
  __strong id<MTLTexture> texture = nil;
  int width = 0;
  int height = 0;
  std::atomic<bool> in_flight{false};
};

struct PortalFrameMetadata {
  uint32_t surface_id = 0;
  int width = 0;
  int height = 0;
  int generation = 0;
  int64_t sequence = -1;
};

IUnityInterfaces *unity_interfaces = nullptr;
IUnityGraphicsMetalV2 *unity_metal = nullptr;
__strong id<MTLDevice> portal_copy_device = nil;
__strong id<MTLRenderPipelineState> portal_copy_pipeline = nil;
PortalSurfaceSlot surface_slots[kSurfaceSlotCount];
std::atomic<uint64_t> next_slot{0};
std::atomic<int64_t> next_sequence{0};
std::mutex metadata_mutex;
PortalFrameMetadata latest_frame;
int64_t last_polled_sequence = -1;

IUnityGraphicsMetalV2 *ResolveMetalInterface() {
  // Preloaded plugins may run before the graphics device registers its Metal
  // interface. Retry on the render event instead of caching startup nullptr.
  if (unity_metal == nullptr && unity_interfaces != nullptr) {
    unity_metal = unity_interfaces->Get<IUnityGraphicsMetalV2>();
  }
  return unity_metal;
}

bool EnsureColorCopyPipeline(id<MTLDevice> device) {
  if (device == nil) {
    return false;
  }
  if (portal_copy_device == device && portal_copy_pipeline != nil) {
    return true;
  }

  static const char *shader_source = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct MaasoPortalVertexOut {
  float4 position [[position]];
};

vertex MaasoPortalVertexOut maasoPortalCopyVertex(uint vertex_id [[vertex_id]]) {
  const float2 positions[3] = {
    float2(-1.0, -1.0),
    float2(3.0, -1.0),
    float2(-1.0, 3.0),
  };
  MaasoPortalVertexOut output;
  output.position = float4(positions[vertex_id], 0.0, 1.0);
  return output;
}

fragment float4 maasoPortalCopyFragment(
    MaasoPortalVertexOut input [[stage_in]],
    texture2d<float, access::read> source [[texture(0)]]) {
  return source.read(uint2(input.position.xy));
}
)METAL";
  NSError *library_error = nil;
  id<MTLLibrary> library = [device
      newLibraryWithSource:[NSString stringWithUTF8String:shader_source]
                    options:nil
                      error:&library_error];
  if (library == nil) {
    NSLog(@"[DesktopAvatarPortal] Metal color-copy shader unavailable: %@",
          library_error);
    portal_copy_device = nil;
    portal_copy_pipeline = nil;
    return false;
  }

  MTLRenderPipelineDescriptor *descriptor =
      [[MTLRenderPipelineDescriptor alloc] init];
  descriptor.label = @"Maaso Desktop Avatar Portal Color Copy";
  descriptor.vertexFunction =
      [library newFunctionWithName:@"maasoPortalCopyVertex"];
  descriptor.fragmentFunction =
      [library newFunctionWithName:@"maasoPortalCopyFragment"];
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
  NSError *pipeline_error = nil;
  id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithDescriptor:descriptor
                                             error:&pipeline_error];
  if (pipeline == nil) {
    NSLog(@"[DesktopAvatarPortal] Metal color-copy pipeline unavailable: %@",
          pipeline_error);
    portal_copy_device = nil;
    portal_copy_pipeline = nil;
    return false;
  }
  portal_copy_device = device;
  portal_copy_pipeline = pipeline;
  return true;
}

void DestroySlot(PortalSurfaceSlot *slot) {
  if (slot == nullptr || slot->in_flight.load()) {
    return;
  }
  slot->texture = nil;
  if (slot->surface != nullptr) {
    CFRelease(slot->surface);
    slot->surface = nullptr;
  }
  slot->width = 0;
  slot->height = 0;
}

bool EnsureSlot(PortalSurfaceSlot *slot,
                id<MTLDevice> device,
                int width,
                int height) {
  if (slot == nullptr || device == nil || width <= 0 || height <= 0) {
    return false;
  }
  if (slot->surface != nullptr && slot->texture != nil &&
      slot->width == width && slot->height == height) {
    return true;
  }
  if (slot->in_flight.load()) {
    return false;
  }
  DestroySlot(slot);

  const size_t bytes_per_row = IOSurfaceAlignProperty(
      kIOSurfaceBytesPerRow,
      static_cast<size_t>(width) * 4);
  NSDictionary *properties = @{
    (__bridge NSString *)kIOSurfaceWidth : @(width),
    (__bridge NSString *)kIOSurfaceHeight : @(height),
    (__bridge NSString *)kIOSurfaceBytesPerElement : @4,
    (__bridge NSString *)kIOSurfaceBytesPerRow : @(bytes_per_row),
    (__bridge NSString *)kIOSurfacePixelFormat : @(kCVPixelFormatType_32BGRA),
    (__bridge NSString *)kIOSurfaceIsGlobal : @YES,
  };
  slot->surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
  if (slot->surface == nullptr) {
    return false;
  }
  MTLTextureDescriptor *descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                                MTLPixelFormatBGRA8Unorm_sRGB
                                                    width:width
                                                   height:height
                                                mipmapped:NO];
  descriptor.storageMode = MTLStorageModeShared;
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  slot->texture = [device newTextureWithDescriptor:descriptor
                                         iosurface:slot->surface
                                             plane:0];
  if (slot->texture == nil) {
    DestroySlot(slot);
    return false;
  }
  slot->width = width;
  slot->height = height;
  return true;
}

void UNITY_INTERFACE_API RenderPortalFrame(int event_id, void *data) {
  (void)event_id;
  std::unique_ptr<PortalFrameSubmission> submission(
      static_cast<PortalFrameSubmission *>(data));
  IUnityGraphicsMetalV2 *metal = ResolveMetalInterface();
  if (submission == nullptr || metal == nullptr ||
      submission->texture == nullptr || submission->generation <= 0) {
    return;
  }
  metal->EndCurrentCommandEncoder();
  id<MTLCommandBuffer> command_buffer = metal->CurrentCommandBuffer();
  id<MTLTexture> source = (__bridge id<MTLTexture>)submission->texture;
  if (command_buffer == nil || source == nil ||
      source.width < static_cast<NSUInteger>(submission->width) ||
      source.height < static_cast<NSUInteger>(submission->height) ||
      !EnsureColorCopyPipeline(source.device)) {
    return;
  }

  PortalSurfaceSlot *slot = nullptr;
  for (int attempt = 0; attempt < kSurfaceSlotCount; attempt += 1) {
    const uint64_t index = next_slot.fetch_add(1) % kSurfaceSlotCount;
    PortalSurfaceSlot *candidate = &surface_slots[index];
    bool expected = false;
    if (candidate->in_flight.load()) {
      continue;
    }
    if (!EnsureSlot(candidate, source.device,
                    submission->width, submission->height)) {
      continue;
    }
    if (!candidate->in_flight.compare_exchange_strong(expected, true)) {
      continue;
    }
    slot = candidate;
    break;
  }
  if (slot == nullptr) {
    return;
  }

  MTLRenderPassDescriptor *render_pass =
      [MTLRenderPassDescriptor renderPassDescriptor];
  render_pass.colorAttachments[0].texture = slot->texture;
  render_pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> encoder =
      [command_buffer renderCommandEncoderWithDescriptor:render_pass];
  if (encoder == nil) {
    slot->in_flight.store(false);
    return;
  }
  encoder.label = @"Maaso Desktop Avatar Portal Color Copy";
  [encoder setRenderPipelineState:portal_copy_pipeline];
  [encoder setFragmentTexture:source atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:3];
  [encoder endEncoding];

  const uint32_t surface_id = IOSurfaceGetID(slot->surface);
  const int frame_width = submission->width;
  const int frame_height = submission->height;
  const int generation = submission->generation;
  [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
    if (completed.status == MTLCommandBufferStatusCompleted && surface_id > 0) {
      const int64_t sequence = next_sequence.fetch_add(1);
      std::lock_guard<std::mutex> lock(metadata_mutex);
      latest_frame = PortalFrameMetadata{
          surface_id,
          frame_width,
          frame_height,
          generation,
          sequence,
      };
    }
    slot->in_flight.store(false);
  }];
}

}  // namespace

extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityPluginLoad(IUnityInterfaces *interfaces) {
  RequestWindowSuppression();
  unity_interfaces = interfaces;
  unity_metal = nullptr;
}

extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API UnityPluginUnload() {
  RemoveWindowSuppression();
  unity_interfaces = nullptr;
  unity_metal = nullptr;
  portal_copy_pipeline = nil;
  portal_copy_device = nil;
  for (int index = 0; index < kSurfaceSlotCount; index += 1) {
    DestroySlot(&surface_slots[index]);
  }
  std::lock_guard<std::mutex> lock(metadata_mutex);
  latest_frame = PortalFrameMetadata{};
  last_polled_sequence = -1;
}

extern "C" {
void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
MaasoDesktopAvatarPortalHidePlayerWindow() {
  RequestWindowSuppression();
}

void *UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
MaasoDesktopAvatarPortalScheduleTexture(
    void *texture,
    int width,
    int height,
    int generation) {
  if (texture == nullptr || width <= 0 || height <= 0 || generation <= 0) {
    return nullptr;
  }
  return new PortalFrameSubmission{texture, width, height, generation};
}

UnityRenderingEventAndData UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
MaasoDesktopAvatarPortalGetRenderEventFunc() {
  return RenderPortalFrame;
}

bool UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
MaasoDesktopAvatarPortalPollSurface(
    uint32_t *surface_id,
    int *width,
    int *height,
    int *generation,
    int64_t *frame_sequence) {
  if (surface_id == nullptr || width == nullptr || height == nullptr ||
      generation == nullptr || frame_sequence == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> lock(metadata_mutex);
  if (latest_frame.surface_id == 0 ||
      latest_frame.sequence <= last_polled_sequence) {
    return false;
  }
  *surface_id = latest_frame.surface_id;
  *width = latest_frame.width;
  *height = latest_frame.height;
  *generation = latest_frame.generation;
  *frame_sequence = latest_frame.sequence;
  last_polled_sequence = latest_frame.sequence;
  return true;
}
}
