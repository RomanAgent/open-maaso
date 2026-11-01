#include "flutter_window.h"

#include <algorithm>
#include <array>
#include <map>
#include <optional>
#include <regex>
#include <set>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "unity_player_host.h"
#include "windows_desktop_companion_host.h"

namespace {

constexpr char kUnityHostChannel[] = "maaso/desktop_unity_host";
constexpr char kUnityAvatarChannel[] = "maaso/unity_avatar";

constexpr std::array<const char*, 6> kPetBaselineAvatarMethods = {
    "prepareView", "loadAvatar", "setExpression", "setFraming",
    "setViewportSafeArea", "setLocalAvatarVisible",
};

const std::set<std::string> kPetTransientAvatarMethods = {
    "setMouthOpen",     "setGaze",          "clearGaze",
    "startLipSync",     "stopLipSync",      "playPrimitive",
    "startVisemeTimeline",
    "syncSpeechPlaybackClock", "setConversationPhase",
    "playAnimationClip", "reactToScreenTap", "setHandIkTarget",
    "setBodyPose",      "playMotion",        "playMotionSequence",
};

using PetBaselineAvatarCommandCache =
    std::map<std::string, std::optional<flutter::EncodableValue>>;

bool IsPhoneInteractionResult(const std::string& payload) {
  static const std::regex method(R"phone("method"\s*:\s*"setPhoneInteraction")phone");
  return std::regex_search(payload, method);
}

bool IsPetBaselineAvatarMethod(const std::string& method) {
  return std::any_of(
      kPetBaselineAvatarMethods.begin(), kPetBaselineAvatarMethods.end(),
      [&method](const char* candidate) { return method == candidate; });
}

bool ShouldMirrorAvatarCommandToPet(const std::string& method,
                                    bool pet_visible) {
  return pet_visible &&
         (IsPetBaselineAvatarMethod(method) ||
          kPetTransientAvatarMethods.find(method) !=
              kPetTransientAvatarMethods.end());
}

int ReadInt(const flutter::EncodableMap& arguments,
            const char* key,
            int fallback) {
  auto value = arguments.find(flutter::EncodableValue(key));
  if (value == arguments.end()) {
    return fallback;
  }
  if (const auto* number = std::get_if<int32_t>(&value->second)) {
    return *number;
  }
  if (const auto* number = std::get_if<int64_t>(&value->second)) {
    return static_cast<int>(*number);
  }
  return fallback;
}

flutter::EncodableMap UnityHostStatus(const UnityPlayerHost& host) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("available"),
       flutter::EncodableValue(host.IsAvailable())},
      {flutter::EncodableValue("running"),
       flutter::EncodableValue(host.IsRunning())},
  };
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::IsAnyAvatarReady() const {
  return (unity_player_host_ != nullptr &&
          unity_player_host_->IsAvatarReady()) ||
         (pet_unity_player_host_ != nullptr &&
          pet_unity_player_host_->IsAvatarReady());
}

void FlutterWindow::NotifyAggregatedAvatarStatus() {
  const bool ready = IsAnyAvatarReady();
  if (ready == aggregated_avatar_ready_) {
    return;
  }
  aggregated_avatar_ready_ = ready;
  if (unity_avatar_channel_ == nullptr) {
    return;
  }
  if (ready) {
    unity_avatar_channel_->InvokeMethod("ready", nullptr);
    return;
  }
  unity_avatar_channel_->InvokeMethod(
      "unready",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("reason"),
           flutter::EncodableValue("windows_player_stopped")},
      }));
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  unity_player_host_ = std::make_unique<UnityPlayerHost>(GetHandle());
  pet_unity_player_host_ = std::make_unique<UnityPlayerHost>(GetHandle());
  const auto pet_baseline_cache =
      std::make_shared<PetBaselineAvatarCommandCache>();
  unity_avatar_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kUnityAvatarChannel,
          &flutter::StandardMethodCodec::GetInstance());
  unity_player_host_->SetAvatarStatusCallback(
      [this](bool) { NotifyAggregatedAvatarStatus(); });
  pet_unity_player_host_->SetAvatarStatusCallback(
      [this](bool) { NotifyAggregatedAvatarStatus(); });
  unity_avatar_channel_->SetMethodCallHandler(
      [this, pet_baseline_cache](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        if (call.method_name() == "setLocalAvatarVisible") {
          (*pet_baseline_cache)[call.method_name()] = call.arguments()
              ? std::optional<flutter::EncodableValue>(*call.arguments()) : std::nullopt;
          std::wstring error;
          // Ownership applies to every currently running player, including a
          // pet-only process. New players start hidden and receive this cached
          // baseline when they become ready.
          if (unity_player_host_->IsRunning()) {
            unity_player_host_->SendAvatarCommand(call.method_name(), call.arguments(), &error);
          }
          if (pet_unity_player_host_->IsRunning()) {
            pet_unity_player_host_->SendAvatarCommand(call.method_name(), call.arguments(), &error);
          }
          result->Success();
          return;
        }
        if (call.method_name() == "avatarArbiterCommand" ||
            call.method_name() == "avatarArbiterReset") {
          // Windows may host the app renderer and desktop-pet renderer at the
          // same time. Until the bridge can aggregate two post-mutation
          // receipts, never let the first renderer's ACK mask a missing second
          // mutation. Enforce mode therefore fails closed before either host.
          result->Error("avatar_arbiter_multi_renderer_unsupported",
                        "Ticketed Avatar control is unavailable while Windows "
                        "uses multiple Unity renderers.");
          return;
        }
        std::wstring error;
        const bool pet_visible = desktop_companion_host_ != nullptr &&
            desktop_companion_host_->IsVisible();
        if (call.method_name() == "transitionPresence" ||
            call.method_name() == "setPhoneInteraction") {
          // Route direct presence/phone interaction to the visible renderer.
          // The independent pet must acknowledge its own visual commands.
          auto* target = pet_visible ? pet_unity_player_host_.get() : unity_player_host_.get();
          if (!target || !target->SendAvatarCommand(call.method_name(), call.arguments(), &error)) {
            result->Error("invalid_unity_avatar_command", std::string(error.begin(), error.end()));
          } else {
            result->Success();
          }
          return;
        }
        const bool main_accepted = unity_player_host_->SendAvatarCommand(
            call.method_name(), call.arguments(), &error);
        if (!main_accepted) {
          result->Error("invalid_unity_avatar_command",
                        std::string(error.begin(), error.end()));
          return;
        }
        const bool baseline = IsPetBaselineAvatarMethod(call.method_name());
        if (baseline) {
          // Only five validated (<=32 KiB encoded) latest-value entries exist,
          // so hidden pet sessions cannot grow an unbounded replay queue.
          auto& cached = (*pet_baseline_cache)[call.method_name()];
          if (call.arguments() == nullptr) {
            cached.reset();
          } else {
            cached = *call.arguments();
          }
        }
        bool pet_accepted = true;
        if (ShouldMirrorAvatarCommandToPet(call.method_name(), pet_visible)) {
          pet_accepted = pet_unity_player_host_->SendAvatarCommand(
              call.method_name(), call.arguments(), &error);
        }
        if (!pet_accepted) {
          result->Error("invalid_unity_avatar_command",
                        std::string(error.begin(), error.end()));
          return;
        }
        result->Success();
        if (call.method_name() == "prepareView" && IsAnyAvatarReady()) {
          unity_avatar_channel_->InvokeMethod("ready", nullptr);
        }
      });
  desktop_companion_host_ =
      std::make_unique<WindowsDesktopCompanionHost>(
          flutter_controller_->engine()->messenger(),
          pet_unity_player_host_.get(),
          [this, pet_baseline_cache](std::wstring* error_message) {
            for (const char* method : kPetBaselineAvatarMethods) {
              const auto cached = pet_baseline_cache->find(method);
              if (cached == pet_baseline_cache->end()) {
                continue;
              }
              const flutter::EncodableValue* arguments =
                  cached->second.has_value() ? &cached->second.value()
                                             : nullptr;
              if (!pet_unity_player_host_->SendAvatarCommand(
                      method, arguments, error_message)) {
                return false;
              }
            }
            return true;
          });
  unity_player_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kUnityHostChannel,
          &flutter::StandardMethodCodec::GetInstance());
  unity_player_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "status") {
          result->Success(
              flutter::EncodableValue(UnityHostStatus(*unity_player_host_)));
          return;
        }
        if (call.method_name() == "start") {
          RECT client = GetClientArea();
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          RECT bounds = client;
          if (arguments != nullptr) {
            bounds.left = ReadInt(*arguments, "left", client.left);
            bounds.top = ReadInt(*arguments, "top", client.top);
            const int width = ReadInt(
                *arguments, "width", client.right - client.left);
            const int height = ReadInt(
                *arguments, "height", client.bottom - client.top);
            bounds.right = bounds.left + width;
            bounds.bottom = bounds.top + height;
          }
          if (bounds.left < client.left || bounds.top < client.top ||
              bounds.right > client.right || bounds.bottom > client.bottom ||
              bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
            result->Error("invalid_unity_host_bounds",
                          "Unity host bounds must stay inside the Maaso window.");
            return;
          }
          std::wstring error;
          unity_player_host_->SetDesktopPetPresentation(false);
          unity_player_host_->SetParentWindow(GetHandle());
          if (!unity_player_host_->Start(bounds, &error)) {
            result->Error("unity_windows_host_unavailable",
                          std::string(error.begin(), error.end()));
            return;
          }
          result->Success(
              flutter::EncodableValue(UnityHostStatus(*unity_player_host_)));
          return;
        }
        if (call.method_name() == "setBounds") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_unity_host_bounds",
                          "Unity host bounds are required.");
            return;
          }
          RECT client = GetClientArea();
          RECT bounds{};
          bounds.left = ReadInt(*arguments, "left", -1);
          bounds.top = ReadInt(*arguments, "top", -1);
          bounds.right = bounds.left + ReadInt(*arguments, "width", 0);
          bounds.bottom = bounds.top + ReadInt(*arguments, "height", 0);
          if (bounds.left < client.left || bounds.top < client.top ||
              bounds.right > client.right || bounds.bottom > client.bottom ||
              bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
            result->Error("invalid_unity_host_bounds",
                          "Unity host bounds must stay inside the Maaso window.");
            return;
          }
          unity_player_host_->SetBounds(bounds);
          result->Success();
          return;
        }
        if (call.method_name() == "suspend") {
          unity_player_host_->Suspend();
          result->Success();
          return;
        }
        if (call.method_name() == "resume") {
          unity_player_host_->Resume();
          result->Success();
          return;
        }
        if (call.method_name() == "stop") {
          unity_player_host_->Stop();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (unity_player_channel_) {
    unity_player_channel_->SetMethodCallHandler(nullptr);
  }
  if (unity_avatar_channel_) {
    unity_avatar_channel_->SetMethodCallHandler(nullptr);
  }
  if (unity_player_host_) {
    unity_player_host_->SetAvatarStatusCallback({});
  }
  if (pet_unity_player_host_) {
    pet_unity_player_host_->SetAvatarStatusCallback({});
  }
  desktop_companion_host_.reset();
  unity_player_channel_.reset();
  unity_avatar_channel_.reset();
  pet_unity_player_host_.reset();
  unity_player_host_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_COPYDATA) {
    const auto* copy_data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    std::string main_callback_type;
    std::string main_callback_payload;
    const bool main_handled =
        unity_player_host_ != nullptr &&
        unity_player_host_->HandleAvatarCopyData(
            copy_data, &main_callback_type, &main_callback_payload);
    const bool pet_presenting = desktop_companion_host_ != nullptr &&
        desktop_companion_host_->IsVisible();
    if (!main_callback_type.empty() && unity_avatar_channel_ &&
        !(pet_presenting && main_callback_type == "commandResult" &&
          IsPhoneInteractionResult(main_callback_payload))) {
      // Only the app-owned player is authoritative for renderer results and
      // world events. The pet player mirrors presentation state only.
      unity_avatar_channel_->InvokeMethod(
          main_callback_type,
          std::make_unique<flutter::EncodableValue>(main_callback_payload));
    }

    std::string pet_callback_type;
    std::string pet_callback_payload;
    const bool pet_handled =
        pet_unity_player_host_ != nullptr &&
        pet_unity_player_host_->HandleAvatarCopyData(
            copy_data, &pet_callback_type, &pet_callback_payload);
    const bool main_running =
        unity_player_host_ != nullptr && unity_player_host_->IsRunning();
    const bool pet_phone = pet_presenting && IsPhoneInteractionResult(pet_callback_payload);
    if ((!main_running || pet_phone) && pet_callback_type == "commandResult" &&
        unity_avatar_channel_) {
      // A pet-only session must still complete mirrored visual requests. Once
      // the app player runs, its receipt remains authoritative and the pet's
      // duplicate is intentionally ignored.
      unity_avatar_channel_->InvokeMethod(
          pet_callback_type,
          std::make_unique<flutter::EncodableValue>(pet_callback_payload));
    }
    if (main_handled || pet_handled) {
      return TRUE;
    }
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_TIMER:
      if (wparam == UnityPlayerHost::kAttachTimerId && unity_player_host_) {
        unity_player_host_->Tick();
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
