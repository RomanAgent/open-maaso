#ifndef RUNNER_UNITY_PLAYER_HOST_H_
#define RUNNER_UNITY_PLAYER_HOST_H_

#include <flutter/encodable_value.h>

#include <windows.h>

#include <cstdint>
#include <deque>
#include <functional>
#include <string>
#include <vector>

// Owns the single Windows Unity player used by the desktop companion POC.
// The executable path is fixed relative to the signed Maaso installation; no
// caller-provided executable or command line is accepted.
class UnityPlayerHost {
 public:
  static constexpr UINT_PTR kAttachTimerId = 0x4d415553;

  explicit UnityPlayerHost(HWND parent_window);
  ~UnityPlayerHost();

  UnityPlayerHost(const UnityPlayerHost&) = delete;
  UnityPlayerHost& operator=(const UnityPlayerHost&) = delete;

  bool IsAvailable() const;
  bool IsRunning() const;
  bool IsAvatarReady() const;
  void SetParentWindow(HWND parent_window);
  void SetDesktopPetPresentation(bool enabled);
  void SetDesktopPetPresentationConfig(const std::string& quality,
                                       int target_fps);
  void SetAvatarStatusCallback(std::function<void(bool)> callback);
  bool Start(const RECT& bounds, std::wstring* error_message);
  bool SendAvatarCommand(const std::string& method,
                         const flutter::EncodableValue* arguments,
                         std::wstring* error_message);
  void DiscardPendingAvatarCommands();
  bool HandleAvatarCopyData(const COPYDATASTRUCT* copy_data,
                            std::string* callback_type,
                            std::string* callback_payload);
  bool CopyLatestDesktopPetFrame(uint32_t* width,
                                 uint32_t* height,
                                 uint32_t* stride,
                                 uint32_t* flags,
                                 std::vector<unsigned char>* pixels);
  void SetBounds(const RECT& bounds);
  void SetPointerGaze(double horizontal, double vertical);
  void Suspend();
  void Resume();
  void Tick();
  void Stop();

 private:
  std::wstring ResolvePlayerPath() const;
  bool EnsureHostWindow(std::wstring* error_message);
  void ApplyHostPresentationStyle();
  bool CreateKillOnCloseJob(std::wstring* error_message);
  void AttachPlayerWindow();
  void FlushPendingAvatarCommands();
  bool SendAvatarCommandNow(const std::string& method,
                            const std::string& arguments_json);
  bool EnsureDesktopPetFrameMapping();
  void CloseDesktopPetFrameMapping();
  void ResizePlayerIfReady();
  void CloseProcessHandles();

  struct PendingAvatarCommand {
    std::string method;
    std::string arguments_json;
  };

  HWND parent_window_ = nullptr;
  HWND command_host_window_ = nullptr;
  HWND host_window_ = nullptr;
  HWND player_window_ = nullptr;
  PROCESS_INFORMATION process_info_{};
  HANDLE process_job_ = nullptr;
  RECT bounds_{0, 0, 320, 560};
  std::string avatar_session_token_;
  HANDLE desktop_pet_frame_mapping_ = nullptr;
  const unsigned char* desktop_pet_frame_view_ = nullptr;
  uint32_t last_desktop_pet_frame_sequence_ = 0;
  bool has_desktop_pet_frame_sequence_ = false;
  std::deque<PendingAvatarCommand> pending_avatar_commands_;
  std::function<void(bool)> avatar_status_callback_;
  bool desktop_pet_presentation_ = false;
  std::string desktop_pet_quality_ = "crisp";
  int desktop_pet_target_fps_ = 30;
  bool suspended_ = false;
  bool avatar_ready_ = false;
};

#endif  // RUNNER_UNITY_PLAYER_HOST_H_
