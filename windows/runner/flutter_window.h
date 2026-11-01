#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

class UnityPlayerHost;
class WindowsDesktopCompanionHost;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool IsAnyAvatarReady() const;
  void NotifyAggregatedAvatarStatus();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  // The normal app surface and the persistent desktop pet must never reparent
  // or stop each other's Unity process.
  std::unique_ptr<UnityPlayerHost> unity_player_host_;
  std::unique_ptr<UnityPlayerHost> pet_unity_player_host_;
  std::unique_ptr<WindowsDesktopCompanionHost> desktop_companion_host_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      unity_player_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      unity_avatar_channel_;
  bool aggregated_avatar_ready_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
