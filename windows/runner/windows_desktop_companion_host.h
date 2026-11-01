#ifndef RUNNER_WINDOWS_DESKTOP_COMPANION_HOST_H_
#define RUNNER_WINDOWS_DESKTOP_COMPANION_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "desktop_avatar_alpha_mask.h"

class UnityPlayerHost;

// Owns the engine-independent Windows desktop-pet surface. The Flutter engine
// remains attached to the normal application window; this host only presents
// its dedicated Unity player plus native menu, drag, gaze, and bubble chrome.
class WindowsDesktopCompanionHost {
 public:
  using PetStartedCallback = std::function<bool(std::wstring*)>;

  WindowsDesktopCompanionHost(flutter::BinaryMessenger* messenger,
                              UnityPlayerHost* pet_unity_player_host,
                              PetStartedCallback pet_started_callback);
  ~WindowsDesktopCompanionHost();

  WindowsDesktopCompanionHost(const WindowsDesktopCompanionHost&) = delete;
  WindowsDesktopCompanionHost& operator=(
      const WindowsDesktopCompanionHost&) = delete;

  bool IsVisible() const;
  void Dispose();

 private:
  struct MenuEntry {
    std::string id;
    std::wstring label;
    bool enabled = true;
  };

  static constexpr UINT_PTR kGazeTimerId = 0x4d415547;
  static constexpr ULONGLONG kAvatarStartupTimeoutMilliseconds = 15000;
  static constexpr ULONGLONG kMaximumTapDurationMilliseconds = 500;
  static constexpr int kTapMoveLogicalPixels = 6;
  static constexpr UINT kFirstMenuCommand = 1000;
  static constexpr UINT kOpenAppCommand = 2001;
  static constexpr UINT kHidePetCommand = 2002;
  static constexpr UINT kQuitCommand = 2003;

  static LRESULT CALLBACK PetWindowProc(HWND window,
                                        UINT message,
                                        WPARAM wparam,
                                        LPARAM lparam) noexcept;
  static LRESULT CALLBACK OverlayWindowProc(HWND window,
                                            UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) noexcept;
  static LRESULT CALLBACK BubbleWindowProc(HWND window,
                                           UINT message,
                                           WPARAM wparam,
                                           LPARAM lparam) noexcept;

  LRESULT HandlePetMessage(HWND window,
                           UINT message,
                           WPARAM wparam,
                           LPARAM lparam) noexcept;
  LRESULT HandleOverlayMessage(HWND window,
                               UINT message,
                               WPARAM wparam,
                               LPARAM lparam) noexcept;
  LRESULT HandleBubbleMessage(HWND window,
                              UINT message,
                              WPARAM wparam,
                              LPARAM lparam) noexcept;
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool EnsureWindows(std::wstring* error_message);
  bool Show(std::wstring* error_message, int32_t interaction_generation);
  void Hide();
  void ConfigureMenu(const flutter::EncodableMap& arguments,
                     std::unique_ptr<flutter::MethodResult<
                         flutter::EncodableValue>> result);
  void ConfigurePresentation(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ApplyPresentationGeometry();
  void PresentContextMenu(POINT screen_point);
  void InvokeMenuSelection(const std::string& id);
  void InvokeCommand(const char* id);
  void InvokeAvatarInteraction(POINT client_point, int32_t generation);
  std::string AvatarRegionForPoint(POINT client_point) const;
  void UpdateGaze();
  void ClearGaze();
  bool EnsurePetSurface(int width, int height);
  void ReleasePetSurface();
  bool UpdatePetLayeredWindow();
  void PresentLatestDesktopPetFrame();
  void UpdateAvatarHitRegion();
  void ClearAvatarHitRegion();
  void CompletePendingShow();
  void FailPendingShow(const char* code, const std::string& message);
  void DrawInteractionOverlay(HWND window);
  void DrawOverlay(HWND window);

  void BeginDrag(POINT screen_point, POINT client_point);
  void ContinueDrag(POINT screen_point);
  void EndDrag(POINT screen_point);
  void CancelDrag();
  bool MovedBeyondDragThreshold(POINT screen_point) const;
  bool ApplyDropSnap();
  bool ResolveSpatialAttachment(POINT* origin) const;
  void ClearSpatialAttachment();
  void RestoreSpatialPosition();
  void UpdateSpatialFallbackFromBounds();
  void MoveWindows(int left, int top);
  void ResizeForDpi(UINT next_dpi, POINT origin);
  POINT ClampOrigin(POINT proposed) const;
  RECT AvatarBounds() const;
  bool IsAvatarPoint(POINT client_point) const;
  int Scale(int logical_pixels) const;
  void LoadInitialBounds();
  void SaveBounds() const;

  flutter::BinaryMessenger* messenger_ = nullptr;
  UnityPlayerHost* pet_unity_player_host_ = nullptr;
  PetStartedCallback pet_started_callback_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND pet_window_ = nullptr;
  HWND overlay_window_ = nullptr;
  HWND bubble_window_ = nullptr;
  HDC pet_surface_dc_ = nullptr;
  HBITMAP pet_surface_bitmap_ = nullptr;
  HGDIOBJ pet_surface_previous_bitmap_ = nullptr;
  unsigned char* pet_surface_pixels_ = nullptr;
  int pet_surface_width_ = 0;
  int pet_surface_height_ = 0;
  std::vector<unsigned char> pet_frame_pixels_;
  DesktopAvatarAlphaMask avatar_hit_mask_;
  RECT window_bounds_{0, 0, 300, 420};
  UINT dpi_ = 96;
  bool visible_ = false;
  ULONGLONG avatar_startup_deadline_ = 0;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
      pending_show_result_;
  bool dragging_ = false;
  bool pointer_down_active_ = false;
  POINT drag_cursor_start_{};
  POINT drag_window_start_{};
  POINT pointer_down_client_{};
  ULONGLONG pointer_down_timestamp_ms_ = 0;
  int32_t pointer_down_generation_ = 0;
  int32_t interaction_generation_ = 0;
  bool has_last_gaze_ = false;
  double last_gaze_x_ = 0.0;
  double last_gaze_y_ = 0.0;
  std::vector<MenuEntry> menu_entries_;
  std::wstring open_app_label_ = L"Open Maaso";
  std::wstring hide_pet_label_ = L"Hide Desktop Pet";
  std::wstring quit_label_ = L"Quit Maaso";
  std::wstring bubble_text_;
  std::string presentation_quality_ = "crisp";
  int presentation_target_fps_ = 30;
  double presentation_visual_scale_ = 1.8;
  bool presentation_always_on_top_ = true;
  bool presentation_snap_enabled_ = false;
  double presentation_snap_acquire_distance_ = 24.0;
  double presentation_snap_release_distance_ = 40.0;
  std::wstring spatial_monitor_device_;
  double spatial_normalized_x_ = 1.0;
  double spatial_normalized_y_ = 1.0;
  DWORD spatial_attachment_kind_ = 0;
  std::wstring spatial_attachment_monitor_device_;
  HWND spatial_attachment_window_ = nullptr;
  DWORD spatial_attachment_window_process_id_ = 0;
};

#endif  // RUNNER_WINDOWS_DESKTOP_COMPANION_HOST_H_
