#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>

#include "IUnityGraphics.h"
#include "IUnityGraphicsMetal.h"

#include <atomic>
#include <cstdint>
#include <memory>

using MaasoAvatarPortalSubmitMetalTextureFunction = void (*)(
    void *, void *, int, int, int);
using MaasoAvatarPortalReportEventFunction = void (*)(const char *, int);

extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityPluginLoad(IUnityInterfaces *interfaces);
extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityPluginUnload();

// Unity as a Library loads UnityFramework before its plug-in registry exists,
// so constructor-based registration crashes during dyld initialization. The
// render callback runs after the registry is initialized and can safely resolve
// the Metal interface lazily from UnityFramework's internal registry accessor.
IUnityInterfaces *GetUnityInterfaces();

namespace {
struct MaasoAvatarPortalFrameSubmission {
  void *texture;
  int width;
  int height;
  int generation;
};

IUnityGraphicsMetalV2 *unityMetal = nullptr;
std::atomic<int> lastReportedPortalRenderGeneration{0};

void ReportAvatarPortalEvent(const char *type, int generation) {
  static MaasoAvatarPortalReportEventFunction report =
      reinterpret_cast<MaasoAvatarPortalReportEventFunction>(
          dlsym(RTLD_DEFAULT, "MaasoAvatarPortalReportEventToFlutter"));
  if (report != nullptr && type != nullptr && generation > 0) {
    report(type, generation);
  }
}

void UNITY_INTERFACE_API MaasoAvatarPortalRenderEvent(int eventId, void *data) {
  (void)eventId;
  std::unique_ptr<MaasoAvatarPortalFrameSubmission> submission(
      static_cast<MaasoAvatarPortalFrameSubmission *>(data));
  if (submission == nullptr) {
    return;
  }
  if (unityMetal == nullptr) {
    IUnityInterfaces *interfaces = GetUnityInterfaces();
    unityMetal = interfaces == nullptr
        ? nullptr
        : interfaces->Get<IUnityGraphicsMetalV2>();
  }
  if (unityMetal == nullptr) {
    if (lastReportedPortalRenderGeneration.exchange(submission->generation) !=
        submission->generation) {
      ReportAvatarPortalEvent("metalInterfaceMissing", submission->generation);
    }
    return;
  }
  unityMetal->EndCurrentCommandEncoder();
  id<MTLCommandBuffer> commandBuffer = unityMetal->CurrentCommandBuffer();
  if (commandBuffer == nil) {
    if (lastReportedPortalRenderGeneration.exchange(submission->generation) !=
        submission->generation) {
      ReportAvatarPortalEvent("metalCommandBufferMissing", submission->generation);
    }
    return;
  }
  static MaasoAvatarPortalSubmitMetalTextureFunction submit =
      reinterpret_cast<MaasoAvatarPortalSubmitMetalTextureFunction>(
          dlsym(RTLD_DEFAULT, "MaasoAvatarPortalSubmitMetalTexture"));
  if (submit != nullptr) {
    if (lastReportedPortalRenderGeneration.exchange(submission->generation) !=
        submission->generation) {
      ReportAvatarPortalEvent("metalSubmitDispatch", submission->generation);
    }
    submit(
        submission->texture,
        (__bridge void *)commandBuffer,
        submission->width,
        submission->height,
        submission->generation);
  } else {
    if (lastReportedPortalRenderGeneration.exchange(submission->generation) !=
        submission->generation) {
      ReportAvatarPortalEvent("metalSubmitMissing", submission->generation);
    }
  }
}
}  // namespace

extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityPluginLoad(IUnityInterfaces *interfaces) {
  unityMetal = interfaces == nullptr
      ? nullptr
      : interfaces->Get<IUnityGraphicsMetalV2>();
}

extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityPluginUnload() {
  unityMetal = nullptr;
  lastReportedPortalRenderGeneration.store(0);
}

extern "C" {
void *MaasoAvatarPortalScheduleTexture(
    void *texture,
    int width,
    int height,
    int generation) {
  if (texture == nullptr || width <= 0 || height <= 0 || generation <= 0) {
    return nullptr;
  }
  return new MaasoAvatarPortalFrameSubmission{
      texture,
      width,
      height,
      generation,
  };
}

UnityRenderingEventAndData MaasoAvatarPortalGetRenderEventFunc() {
  return MaasoAvatarPortalRenderEvent;
}

void MaasoAvatarPortalReportEvent(const char *type, int generation) {
  ReportAvatarPortalEvent(type, generation);
}

}
