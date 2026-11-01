#include <jni.h>

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <cstdint>
#include <memory>
#include <mutex>

namespace {
using UnityRenderingEventAndData = void (*)(int, void*);

struct MaasoAvatarPortalFrameSubmission {
  void* texture;
  int width;
  int height;
  int generation;
};

JavaVM* javaVm = nullptr;
jclass portalBridgeClass = nullptr;
jmethodID portalFrameAvailableMethod = nullptr;

std::mutex portalMutex;
ANativeWindow* portalWindow = nullptr;
EGLDisplay portalDisplay = EGL_NO_DISPLAY;
EGLSurface portalSurface = EGL_NO_SURFACE;
int portalWidth = 0;
int portalHeight = 0;
int portalGeneration = 0;

JNIEnv* environment(bool* didAttach) {
  *didAttach = false;
  if (javaVm == nullptr) return nullptr;
  JNIEnv* env = nullptr;
  const jint status = javaVm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  if (status == JNI_OK) return env;
  if (status != JNI_EDETACHED || javaVm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
    return nullptr;
  }
  *didAttach = true;
  return env;
}

void destroyPortalSurfaceLocked() {
  if (portalSurface != EGL_NO_SURFACE && portalDisplay != EGL_NO_DISPLAY) {
    eglDestroySurface(portalDisplay, portalSurface);
  }
  portalSurface = EGL_NO_SURFACE;
  portalDisplay = EGL_NO_DISPLAY;
  if (portalWindow != nullptr) {
    ANativeWindow_release(portalWindow);
    portalWindow = nullptr;
  }
  portalWidth = 0;
  portalHeight = 0;
  portalGeneration = 0;
}

bool ensurePortalSurfaceLocked(EGLDisplay display, EGLSurface referenceSurface) {
  if (portalWindow == nullptr || display == EGL_NO_DISPLAY ||
      referenceSurface == EGL_NO_SURFACE) {
    return false;
  }
  if (portalSurface != EGL_NO_SURFACE && portalDisplay == display) {
    return true;
  }
  if (portalSurface != EGL_NO_SURFACE && portalDisplay != EGL_NO_DISPLAY) {
    eglDestroySurface(portalDisplay, portalSurface);
    portalSurface = EGL_NO_SURFACE;
  }
  EGLint configId = 0;
  if (eglQuerySurface(display, referenceSurface, EGL_CONFIG_ID, &configId) != EGL_TRUE) {
    return false;
  }
  const EGLint attributes[] = {EGL_CONFIG_ID, configId, EGL_NONE};
  EGLConfig config = nullptr;
  EGLint count = 0;
  if (eglChooseConfig(display, attributes, &config, 1, &count) != EGL_TRUE ||
      count != 1 || config == nullptr) {
    return false;
  }
  portalSurface = eglCreateWindowSurface(display, config, portalWindow, nullptr);
  if (portalSurface == EGL_NO_SURFACE) {
    return false;
  }
  portalDisplay = display;
  return true;
}

void notifyPortalFrameAvailable(int generation) {
  bool didAttach = false;
  JNIEnv* env = environment(&didAttach);
  if (env != nullptr && portalBridgeClass != nullptr &&
      portalFrameAvailableMethod != nullptr) {
    env->CallStaticVoidMethod(
        portalBridgeClass,
        portalFrameAvailableMethod,
        static_cast<jint>(generation));
    if (env->ExceptionCheck()) env->ExceptionClear();
  }
  if (didAttach) javaVm->DetachCurrentThread();
}

void MaasoAvatarPortalRenderEvent(int eventId, void* data) {
  (void)eventId;
  std::unique_ptr<MaasoAvatarPortalFrameSubmission> submission(
      static_cast<MaasoAvatarPortalFrameSubmission*>(data));
  if (submission == nullptr || submission->texture == nullptr) return;

  bool rendered = false;
  {
    std::lock_guard<std::mutex> lock(portalMutex);
    if (portalWindow == nullptr || submission->generation != portalGeneration ||
        submission->width != portalWidth || submission->height != portalHeight) {
      return;
    }
    EGLDisplay display = eglGetCurrentDisplay();
    EGLContext context = eglGetCurrentContext();
    EGLSurface originalDraw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface originalRead = eglGetCurrentSurface(EGL_READ);
    if (display == EGL_NO_DISPLAY || context == EGL_NO_CONTEXT ||
        originalDraw == EGL_NO_SURFACE ||
        !ensurePortalSurfaceLocked(display, originalDraw)) {
      return;
    }

    GLint originalReadFramebuffer = 0;
    GLint originalDrawFramebuffer = 0;
    GLint originalViewport[4] = {0, 0, 0, 0};
    GLboolean originalScissor = glIsEnabled(GL_SCISSOR_TEST);
    GLboolean originalBlend = glIsEnabled(GL_BLEND);
    GLboolean originalColorMask[4] = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &originalReadFramebuffer);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &originalDrawFramebuffer);
    glGetIntegerv(GL_VIEWPORT, originalViewport);
    glGetBooleanv(GL_COLOR_WRITEMASK, originalColorMask);

    if (eglMakeCurrent(display, portalSurface, portalSurface, context) != EGL_TRUE) {
      return;
    }
    GLuint sourceFramebuffer = 0;
    glGenFramebuffers(1, &sourceFramebuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, sourceFramebuffer);
    GLuint textureName = static_cast<GLuint>(
        reinterpret_cast<uintptr_t>(submission->texture));
    glFramebufferTexture2D(
        GL_READ_FRAMEBUFFER,
        GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D,
        textureName,
        0);
    bool framebufferReady =
        glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (framebufferReady) {
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
      glViewport(0, 0, portalWidth, portalHeight);
      glDisable(GL_SCISSOR_TEST);
      glDisable(GL_BLEND);
      glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
      glBlitFramebuffer(
          0,
          0,
          submission->width,
          submission->height,
          0,
          0,
          portalWidth,
          portalHeight,
          GL_COLOR_BUFFER_BIT,
          GL_NEAREST);
      rendered = glGetError() == GL_NO_ERROR &&
          eglSwapBuffers(display, portalSurface) == EGL_TRUE;
    }
    glDeleteFramebuffers(1, &sourceFramebuffer);

    if (eglMakeCurrent(display, originalDraw, originalRead, context) == EGL_TRUE) {
      glBindFramebuffer(GL_READ_FRAMEBUFFER, originalReadFramebuffer);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, originalDrawFramebuffer);
      glViewport(
          originalViewport[0],
          originalViewport[1],
          originalViewport[2],
          originalViewport[3]);
      if (originalScissor == GL_TRUE) {
        glEnable(GL_SCISSOR_TEST);
      } else {
        glDisable(GL_SCISSOR_TEST);
      }
      if (originalBlend == GL_TRUE) {
        glEnable(GL_BLEND);
      } else {
        glDisable(GL_BLEND);
      }
      glColorMask(
          originalColorMask[0],
          originalColorMask[1],
          originalColorMask[2],
          originalColorMask[3]);
    } else {
      rendered = false;
    }
  }
  if (rendered) notifyPortalFrameAvailable(submission->generation);
}
}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  javaVm = vm;
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT void JNICALL
Java_com_futurpals_maaso_AvatarPortalTextureBridge_nativeInitialize(
    JNIEnv* env,
    jobject receiver) {
  if (portalBridgeClass != nullptr) {
    env->DeleteGlobalRef(portalBridgeClass);
  }
  jclass localClass = env->GetObjectClass(receiver);
  portalBridgeClass = reinterpret_cast<jclass>(env->NewGlobalRef(localClass));
  env->DeleteLocalRef(localClass);
  portalFrameAvailableMethod = env->GetStaticMethodID(
      portalBridgeClass,
      "frameAvailableNative",
      "(I)V");
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_futurpals_maaso_AvatarPortalTextureBridge_nativeSetSurface(
    JNIEnv* env,
    jobject,
    jobject surface,
    jint width,
    jint height,
    jint generation) {
  if (surface == nullptr || width <= 0 || height <= 0 || generation <= 0) {
    return JNI_FALSE;
  }
  ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
  if (window == nullptr) return JNI_FALSE;
  ANativeWindow_setBuffersGeometry(window, width, height, WINDOW_FORMAT_RGBA_8888);
  std::lock_guard<std::mutex> lock(portalMutex);
  destroyPortalSurfaceLocked();
  portalWindow = window;
  portalWidth = width;
  portalHeight = height;
  portalGeneration = generation;
  return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_futurpals_maaso_AvatarPortalTextureBridge_nativeClearSurface(
    JNIEnv*,
    jobject,
    jint generation) {
  std::lock_guard<std::mutex> lock(portalMutex);
  if (generation <= 0 || portalGeneration == generation) {
    destroyPortalSurfaceLocked();
  }
}

extern "C" __attribute__((visibility("default"))) void*
MaasoAvatarPortalScheduleTexture(
    void* texture,
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

extern "C" __attribute__((visibility("default"))) UnityRenderingEventAndData
MaasoAvatarPortalGetRenderEventFunc() {
  return MaasoAvatarPortalRenderEvent;
}
