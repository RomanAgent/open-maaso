#include "unity_player_host.h"

#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iomanip>
#include <locale>
#include <regex>
#include <set>
#include <sstream>
#include <utility>
#include <vector>

namespace {

constexpr wchar_t kUnityRelativePath[] = L"unity\\MaasoAvatar.exe";
constexpr wchar_t kUnityHostWindowClass[] = L"MaasoUnityPlayerChildHost";
constexpr ULONG_PTR kAvatarCommandCopyData = 0x4d415643;
constexpr ULONG_PTR kAvatarCallbackCopyData = 0x4d415652;
constexpr uint32_t kAvatarProtocolVersion = 1;
constexpr size_t kMaximumAvatarMethodBytes = 64;
constexpr size_t kMaximumAvatarJsonBytes = 32 * 1024;
constexpr size_t kMaximumPendingAvatarCommands = 64;
constexpr UINT kUnityAttachTimerMilliseconds = 100;
constexpr UINT kDesktopPetFrameTimerMilliseconds = 16;
constexpr uint32_t kDesktopPetFrameMagic = 0x4653414D;  // Little-endian "MASF".
constexpr uint32_t kDesktopPetFrameVersion = 1;
constexpr size_t kDesktopPetFrameHeaderBytes = 64;
constexpr size_t kDesktopPetFrameMaximumDimension = 2048;
constexpr size_t kDesktopPetFrameMaximumPixels =
    kDesktopPetFrameMaximumDimension * kDesktopPetFrameMaximumDimension;
constexpr size_t kDesktopPetFrameMappingBytes =
    kDesktopPetFrameHeaderBytes + kDesktopPetFrameMaximumPixels * 4;
constexpr size_t kDesktopPetFrameMagicOffset = 0;
constexpr size_t kDesktopPetFrameVersionOffset = 4;
constexpr size_t kDesktopPetFrameSequenceBeginOffset = 8;
constexpr size_t kDesktopPetFrameSequenceEndOffset = 12;
constexpr size_t kDesktopPetFrameWidthOffset = 16;
constexpr size_t kDesktopPetFrameHeightOffset = 20;
constexpr size_t kDesktopPetFrameStrideOffset = 24;
constexpr size_t kDesktopPetFramePayloadOffset = 28;
constexpr size_t kDesktopPetFrameFlagsOffset = 32;
constexpr size_t kDesktopPetFramePixelsOffset = 64;
constexpr uint32_t kDesktopPetFrameTopDown = 1u << 0;

struct AvatarCopyDataHeader {
  uint32_t version;
  uint32_t token_length;
  uint32_t method_length;
  uint32_t payload_length;
};

const std::set<std::string> kAvatarMethods = {
    "prepareView", "loadAvatar", "setExpression", "setMouthOpen", "setGaze",
    "clearGaze", "startLipSync", "startVisemeTimeline", "stopLipSync", "playPrimitive",
    "syncSpeechPlaybackClock", "setConversationPhase",
    "playAnimationClip", "reactToScreenTap", "setHandIkTarget", "setBodyPose",
    "transitionPresence", "transitionLoginDoorway", "setPhoneInteraction", "setLocalAvatarVisible",
    "playMotion", "playMotionSequence", "setFraming", "setViewportSafeArea",
    "setWorldTimeOfDay", "setWorldCamera", "avatarArbiterCommand", "avatarArbiterReset",
    "enterAgentSpace", "leaveAgentSpace", "requestAgentSpaceMoveAtScreenPoint",
    "pause", "resume"};

bool IsAgentSpaceMethod(const std::string& method) {
  return method == "enterAgentSpace" || method == "leaveAgentSpace" ||
         method == "requestAgentSpaceMoveAtScreenPoint";
}

bool AgentSpaceIdentifier(const std::string& value, bool allow_empty = false) {
  if (value.size() > 128 || (!allow_empty && value.empty())) return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '.' || c == '_' || c == ':' || c == '-';
  });
}

const flutter::EncodableValue* AgentSpaceArgument(
    const flutter::EncodableMap& values, const char* key) {
  const auto found = values.find(flutter::EncodableValue(std::string(key)));
  return found == values.end() ? nullptr : &found->second;
}

bool IsValidAgentSpaceArguments(const std::string& method,
                               const flutter::EncodableValue* arguments) {
  if (!IsAgentSpaceMethod(method) || arguments == nullptr) return false;
  const auto* values = std::get_if<flutter::EncodableMap>(arguments);
  const bool moving = method == "requestAgentSpaceMoveAtScreenPoint";
  if (values == nullptr) return false;
  const std::set<std::string> allowed = moving
      ? std::set<std::string>{"requestId", "sessionId", "x", "y"}
      : std::set<std::string>{"requestId", "sessionId", "animated", "viewportTop", "viewportBottom"};
  for (const auto& item : *values) {
    const auto* key = std::get_if<std::string>(&item.first);
    if (key == nullptr || allowed.count(*key) != 1) return false;
  }
  for (const char* key : {"requestId", "sessionId"}) {
    const auto* value = AgentSpaceArgument(*values, key);
    const auto* text = value == nullptr ? nullptr : std::get_if<std::string>(value);
    if (text == nullptr || !AgentSpaceIdentifier(*text)) return false;
  }
  const auto boundedNumber = [&](const char* key, double maximum) {
    const auto* value = AgentSpaceArgument(*values, key);
    if (value == nullptr) return false;
    double point;
    if (const auto* v = std::get_if<double>(value)) point = *v;
    else if (const auto* v = std::get_if<int32_t>(value)) point = *v;
    else if (const auto* v = std::get_if<int64_t>(value)) point = static_cast<double>(*v);
    else return false;
    return std::isfinite(point) && point >= 0 && point <= maximum;
  };
  if (moving) {
    return values->size() == 4 && boundedNumber("x", 1) && boundedNumber("y", 1);
  }
  const auto* animated = AgentSpaceArgument(*values, "animated");
  if (animated != nullptr && std::get_if<bool>(animated) == nullptr) return false;
  const bool has_top = AgentSpaceArgument(*values, "viewportTop") != nullptr;
  const bool has_bottom = AgentSpaceArgument(*values, "viewportBottom") != nullptr;
  if (has_top != has_bottom) return false;
  return !has_top || (boundedNumber("viewportTop", 0.45) && boundedNumber("viewportBottom", 0.45));
}

void SkipAgentSpaceWhitespace(const std::string& json, size_t* offset) {
  while (*offset < json.size() &&
         (json[*offset] == ' ' || json[*offset] == '\t' ||
          json[*offset] == '\r' || json[*offset] == '\n')) ++*offset;
}

bool ReadAgentSpaceToken(const std::string& json, size_t* offset, std::string* value) {
  SkipAgentSpaceWhitespace(json, offset);
  if (*offset >= json.size() || json[(*offset)++] != '"') return false;
  const auto begin = *offset;
  while (*offset < json.size() && json[*offset] != '"') ++*offset;
  if (*offset >= json.size()) return false;
  *value = json.substr(begin, *offset - begin);
  ++*offset;
  return AgentSpaceIdentifier(*value, true);
}

bool IsValidAgentSpaceReceipt(const std::string& json) {
  size_t offset = 0;
  SkipAgentSpaceWhitespace(json, &offset);
  if (offset >= json.size() || json[offset++] != '{') return false;
  std::set<std::string> keys;
  std::string method;
  while (true) {
    std::string key;
    if (!ReadAgentSpaceToken(json, &offset, &key) || !keys.insert(key).second) return false;
    SkipAgentSpaceWhitespace(json, &offset);
    if (offset >= json.size() || json[offset++] != ':') return false;
    SkipAgentSpaceWhitespace(json, &offset);
    if (key == "ok") {
      if (json.compare(offset, 4, "true") == 0) offset += 4;
      else if (json.compare(offset, 5, "false") == 0) offset += 5;
      else return false;
    } else {
      std::string value;
      if (!ReadAgentSpaceToken(json, &offset, &value)) return false;
      if (key == "method") method = value;
      else if (key == "requestId" || key == "sessionId") {
        if (!AgentSpaceIdentifier(value)) return false;
      } else if (key != "code") return false;
    }
    SkipAgentSpaceWhitespace(json, &offset);
    if (offset >= json.size()) return false;
    if (json[offset] == '}') { ++offset; break; }
    if (json[offset++] != ',') return false;
  }
  SkipAgentSpaceWhitespace(json, &offset);
  return offset == json.size() && IsAgentSpaceMethod(method) &&
         keys == std::set<std::string>{"method", "requestId", "sessionId", "ok", "code"};
}

bool IsValidAvatarReceipt(const std::string& json) {
  static const std::regex method_field(
      R"room("method"\s*:\s*"([A-Za-z0-9._:-]{1,128})")room");
  std::smatch match;
  if (!std::regex_search(json, match, method_field)) return false;
  const auto method = match[1].str();
  if (IsAgentSpaceMethod(method)) return IsValidAgentSpaceReceipt(json);
  return method == "furnitureState" || kAvatarMethods.count(method) == 1;
}

bool AppendJsonString(const std::string& value, std::string* output) {
  static constexpr char kHex[] = "0123456789abcdef";
  output->push_back('"');
  for (const unsigned char character : value) {
    switch (character) {
      case '"':
        output->append("\\\"");
        break;
      case '\\':
        output->append("\\\\");
        break;
      case '\b':
        output->append("\\b");
        break;
      case '\f':
        output->append("\\f");
        break;
      case '\n':
        output->append("\\n");
        break;
      case '\r':
        output->append("\\r");
        break;
      case '\t':
        output->append("\\t");
        break;
      default:
        if (character < 0x20) {
          output->append("\\u00");
          output->push_back(kHex[(character >> 4) & 0x0f]);
          output->push_back(kHex[character & 0x0f]);
        } else {
          output->push_back(static_cast<char>(character));
        }
    }
    if (output->size() > kMaximumAvatarJsonBytes) return false;
  }
  output->push_back('"');
  return output->size() <= kMaximumAvatarJsonBytes;
}

bool EncodeJsonValue(const flutter::EncodableValue& value,
                     std::string* output,
                     int depth) {
  if (depth > 6 || output->size() > kMaximumAvatarJsonBytes) return false;
  if (std::holds_alternative<std::monostate>(value)) {
    output->append("null");
  } else if (const auto* boolean = std::get_if<bool>(&value)) {
    output->append(*boolean ? "true" : "false");
  } else if (const auto* number = std::get_if<int32_t>(&value)) {
    output->append(std::to_string(*number));
  } else if (const auto* number = std::get_if<int64_t>(&value)) {
    output->append(std::to_string(*number));
  } else if (const auto* number = std::get_if<double>(&value)) {
    if (!std::isfinite(*number)) return false;
    std::ostringstream stream;
    stream.imbue(std::locale::classic());
    stream << std::setprecision(17) << *number;
    output->append(stream.str());
  } else if (const auto* text = std::get_if<std::string>(&value)) {
    if (!AppendJsonString(*text, output)) return false;
  } else if (const auto* list =
                 std::get_if<flutter::EncodableList>(&value)) {
    output->push_back('[');
    for (size_t index = 0; index < list->size(); ++index) {
      if (index > 0) output->push_back(',');
      if (!EncodeJsonValue((*list)[index], output, depth + 1)) return false;
    }
    output->push_back(']');
  } else if (const auto* map =
                 std::get_if<flutter::EncodableMap>(&value)) {
    output->push_back('{');
    size_t index = 0;
    for (const auto& entry : *map) {
      const auto* key = std::get_if<std::string>(&entry.first);
      if (key == nullptr || index++ >= 512 ||
          !AppendJsonString(*key, output)) {
        return false;
      }
      output->push_back(':');
      if (!EncodeJsonValue(entry.second, output, depth + 1)) return false;
      if (index < map->size()) output->push_back(',');
    }
    output->push_back('}');
  } else {
    return false;
  }
  return output->size() <= kMaximumAvatarJsonBytes;
}

std::string GenerateAvatarSessionToken() {
  std::array<unsigned char, 32> random_bytes{};
  if (::BCryptGenRandom(nullptr, random_bytes.data(),
                        static_cast<ULONG>(random_bytes.size()),
                        BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    return std::string();
  }
  static constexpr char kHex[] = "0123456789abcdef";
  std::string token;
  token.reserve(random_bytes.size() * 2);
  for (const unsigned char value : random_bytes) {
    token.push_back(kHex[(value >> 4) & 0x0f]);
    token.push_back(kHex[value & 0x0f]);
  }
  return token;
}

bool IsValidUtf8(const std::string& value) {
  return value.empty() ||
         ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                               static_cast<int>(value.size()), nullptr, 0) > 0;
}

bool IsValidSessionToken(const std::string& token) {
  if (token.size() != 64) {
    return false;
  }
  return std::all_of(token.begin(), token.end(), [](char value) {
    return (value >= '0' && value <= '9') ||
           (value >= 'a' && value <= 'f') ||
           (value >= 'A' && value <= 'F');
  });
}

uint32_t ReadSharedFrameUint32(const unsigned char* view, size_t offset) {
  return *reinterpret_cast<volatile const uint32_t*>(view + offset);
}

bool RegisterUnityHostWindowClass() {
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = ::DefWindowProcW;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  window_class.hbrBackground =
      static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH));
  window_class.lpszClassName = kUnityHostWindowClass;
  if (::RegisterClassExW(&window_class) != 0) {
    return true;
  }
  return ::GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

struct PlayerWindowSearch {
  DWORD process_id = 0;
  HWND window = nullptr;
};

BOOL CALLBACK FindPlayerWindow(HWND window, LPARAM parameter) {
  auto* search = reinterpret_cast<PlayerWindowSearch*>(parameter);
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == search->process_id && ::GetWindow(window, GW_OWNER) == nullptr) {
    search->window = window;
    return FALSE;
  }
  return TRUE;
}

}  // namespace

UnityPlayerHost::UnityPlayerHost(HWND parent_window)
    : parent_window_(parent_window),
      command_host_window_(parent_window),
      avatar_session_token_(GenerateAvatarSessionToken()) {}

UnityPlayerHost::~UnityPlayerHost() {
  Stop();
  if (host_window_ != nullptr) {
    ::DestroyWindow(host_window_);
    host_window_ = nullptr;
  }
}

bool UnityPlayerHost::IsAvailable() const {
  std::error_code error;
  return std::filesystem::is_regular_file(ResolvePlayerPath(), error) && !error;
}

bool UnityPlayerHost::IsRunning() const {
  if (process_info_.hProcess == nullptr) {
    return false;
  }
  return ::WaitForSingleObject(process_info_.hProcess, 0) == WAIT_TIMEOUT;
}

bool UnityPlayerHost::IsAvatarReady() const {
  return avatar_ready_;
}

void UnityPlayerHost::SetAvatarStatusCallback(
    std::function<void(bool)> callback) {
  avatar_status_callback_ = std::move(callback);
  if (avatar_status_callback_ && avatar_ready_) {
    avatar_status_callback_(true);
  }
}

void UnityPlayerHost::SetParentWindow(HWND parent_window) {
  if (parent_window == nullptr || parent_window_ == parent_window) {
    return;
  }
  if (parent_window_ != nullptr) {
    ::KillTimer(parent_window_, kAttachTimerId);
  }
  parent_window_ = parent_window;
  if (host_window_ != nullptr && ::IsWindow(host_window_)) {
    ::SetParent(host_window_, parent_window_);
    LONG_PTR style = ::GetWindowLongPtrW(host_window_, GWL_STYLE);
    style &= ~WS_POPUP;
    style |= WS_CHILD;
    ::SetWindowLongPtrW(host_window_, GWL_STYLE, style);
    ApplyHostPresentationStyle();
    SetBounds(bounds_);
  }
  if (IsRunning()) {
    ::SetTimer(parent_window_, kAttachTimerId,
               desktop_pet_presentation_ ? kDesktopPetFrameTimerMilliseconds
                                         : kUnityAttachTimerMilliseconds,
               nullptr);
  }
}

void UnityPlayerHost::SetDesktopPetPresentation(bool enabled) {
  if (desktop_pet_presentation_ == enabled) {
    return;
  }
  if (IsRunning()) {
    Stop();
  }
  desktop_pet_presentation_ = enabled;
  ApplyHostPresentationStyle();
}

void UnityPlayerHost::SetDesktopPetPresentationConfig(
    const std::string& quality,
    int target_fps) {
  if ((quality != "eco" && quality != "balanced" && quality != "crisp") ||
      (target_fps != 24 && target_fps != 30 && target_fps != 60)) {
    return;
  }
  if (desktop_pet_quality_ == quality &&
      desktop_pet_target_fps_ == target_fps) {
    return;
  }
  desktop_pet_quality_ = quality;
  desktop_pet_target_fps_ = target_fps;
  if (!desktop_pet_presentation_ || !IsRunning()) {
    return;
  }
  const std::string configuration =
      std::string("{\"quality\":\"") + desktop_pet_quality_ +
      "\",\"targetFps\":" + std::to_string(desktop_pet_target_fps_) + "}";
  if (player_window_ != nullptr &&
      SendAvatarCommandNow("desktopPet.configurePresentation",
                           configuration)) {
    return;
  }
  // The dedicated internal IPC is preferred. If the Unity child is between
  // window creation and hook installation, restart it so the same bounded
  // values are picked up from the command line before the first captured frame.
  Stop();
}

bool UnityPlayerHost::Start(const RECT& bounds, std::wstring* error_message) {
  if (IsRunning()) {
    SetBounds(bounds);
    Resume();
    return true;
  }
  Stop();
  if (!IsAvailable()) {
    if (error_message != nullptr) {
      *error_message = L"The bundled Unity Windows player is unavailable.";
    }
    return false;
  }
  const std::string next_session_token = GenerateAvatarSessionToken();
  if (next_session_token.empty() || command_host_window_ == nullptr) {
    if (error_message != nullptr) {
      *error_message = L"The Unity Avatar IPC session could not be secured.";
    }
    return false;
  }
  avatar_session_token_ = next_session_token;
  if (!EnsureHostWindow(error_message) || !CreateKillOnCloseJob(error_message)) {
    Stop();
    return false;
  }

  SetBounds(bounds);
  const std::wstring player_path = ResolvePlayerPath();
  std::wstringstream command;
  command << L'\"' << player_path << L"\" -parentHWND "
          << reinterpret_cast<uintptr_t>(host_window_)
          << L" delayed -screen-fullscreen 0 -force-d3d11 -nolog"
          << L" -maasoAvatarSession "
          << std::wstring(avatar_session_token_.begin(),
                          avatar_session_token_.end())
          << L" -maasoAvatarHostHWND "
          << reinterpret_cast<uintptr_t>(command_host_window_);
  if (desktop_pet_presentation_) {
    command << L" -maasoDesktopPet -maasoDesktopPetQuality "
            << std::wstring(desktop_pet_quality_.begin(),
                            desktop_pet_quality_.end())
            << L" -maasoDesktopPetFps " << desktop_pet_target_fps_;
  }
  std::wstring command_line = command.str();
  std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
  mutable_command.push_back(L'\0');

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USEPOSITION | STARTF_USESIZE;
  startup.dwX = static_cast<DWORD>(bounds_.left);
  startup.dwY = static_cast<DWORD>(bounds_.top);
  startup.dwXSize = static_cast<DWORD>(bounds_.right - bounds_.left);
  startup.dwYSize = static_cast<DWORD>(bounds_.bottom - bounds_.top);
  const std::filesystem::path working_directory =
      std::filesystem::path(player_path).parent_path();
  if (!::CreateProcessW(player_path.c_str(), mutable_command.data(), nullptr,
                        nullptr, FALSE,
                        CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP |
                            CREATE_SUSPENDED,
                        nullptr, working_directory.c_str(), &startup,
                        &process_info_)) {
    if (error_message != nullptr) {
      *error_message = L"The Unity Windows player process could not start.";
    }
    Stop();
    return false;
  }
  if (!::AssignProcessToJobObject(process_job_, process_info_.hProcess)) {
    if (error_message != nullptr) {
      *error_message = L"The Unity Windows player could not join its lifecycle job.";
    }
    ::TerminateProcess(process_info_.hProcess, ERROR_ACCESS_DENIED);
    Stop();
    return false;
  }
  if (::ResumeThread(process_info_.hThread) == static_cast<DWORD>(-1)) {
    if (error_message != nullptr) {
      *error_message = L"The Unity Windows player process could not resume.";
    }
    Stop();
    return false;
  }

  suspended_ = false;
  if (parent_window_ != nullptr) {
    ::SetTimer(parent_window_, kAttachTimerId,
               desktop_pet_presentation_ ? kDesktopPetFrameTimerMilliseconds
                                         : kUnityAttachTimerMilliseconds,
               nullptr);
  }
  return true;
}

bool UnityPlayerHost::SendAvatarCommand(
    const std::string& method,
    const flutter::EncodableValue* arguments,
    std::wstring* error_message) {
  if (kAvatarMethods.find(method) == kAvatarMethods.end() ||
      method.size() > kMaximumAvatarMethodBytes) {
    if (error_message != nullptr) {
      *error_message = L"The Unity Avatar command is not allowed.";
    }
    return false;
  }
  if (IsAgentSpaceMethod(method) &&
      (!avatar_ready_ || !IsValidAgentSpaceArguments(method, arguments))) {
    if (error_message != nullptr) {
      *error_message = L"Personal-room command is invalid or renderer is not ready.";
    }
    return false;
  }
  std::string arguments_json;
  if (arguments == nullptr) {
    arguments_json = "{}";
  } else if (!EncodeJsonValue(*arguments, &arguments_json, 0) ||
             arguments_json.size() > kMaximumAvatarJsonBytes) {
    if (error_message != nullptr) {
      *error_message = L"The Unity Avatar command arguments are invalid.";
    }
    return false;
  }

  if (player_window_ != nullptr && IsRunning() &&
      SendAvatarCommandNow(method, arguments_json)) {
    return true;
  }
  if (IsAgentSpaceMethod(method)) {
    if (error_message != nullptr) {
      *error_message = L"Personal-room command could not reach the current renderer.";
    }
    return false;
  }
  if (pending_avatar_commands_.size() >= kMaximumPendingAvatarCommands) {
    pending_avatar_commands_.pop_front();
  }
  pending_avatar_commands_.push_back(
      PendingAvatarCommand{method, std::move(arguments_json)});
  return true;
}

void UnityPlayerHost::DiscardPendingAvatarCommands() {
  pending_avatar_commands_.clear();
}

bool UnityPlayerHost::HandleAvatarCopyData(
    const COPYDATASTRUCT* copy_data,
    std::string* callback_type,
    std::string* callback_payload) {
  if (copy_data == nullptr || copy_data->dwData != kAvatarCallbackCopyData ||
      copy_data->lpData == nullptr ||
      copy_data->cbData < static_cast<DWORD>(sizeof(AvatarCopyDataHeader)) ||
      copy_data->cbData > sizeof(AvatarCopyDataHeader) + 128 + 64 +
                              kMaximumAvatarJsonBytes) {
    return false;
  }
  AvatarCopyDataHeader header{};
  std::memcpy(&header, copy_data->lpData, sizeof(header));
  const size_t expected_size = sizeof(header) + header.token_length +
                               header.method_length + header.payload_length;
  if (header.version != kAvatarProtocolVersion ||
      header.token_length != avatar_session_token_.size() ||
      header.method_length == 0 || header.method_length > 64 ||
      header.payload_length > kMaximumAvatarJsonBytes ||
      expected_size != copy_data->cbData) {
    return true;
  }
  const auto* bytes = static_cast<const char*>(copy_data->lpData) +
                      sizeof(AvatarCopyDataHeader);
  const std::string token(bytes, header.token_length);
  const std::string type(bytes + header.token_length, header.method_length);
  const std::string payload(bytes + header.token_length + header.method_length,
                            header.payload_length);
  // Multiple UnityPlayerHost instances share the Flutter runner HWND. Only
  // claim callbacks for this host's session so the window message router can
  // offer the packet to the other host.
  if (token != avatar_session_token_) {
    return false;
  }
  if (!IsValidUtf8(type) || !IsValidUtf8(payload)) {
    return true;
  }
  if (type == "ready") {
    if (!avatar_ready_) {
      avatar_ready_ = true;
      if (avatar_status_callback_) avatar_status_callback_(true);
    }
    return true;
  }
  if (type != "commandResult" && type != "log" &&
      type != "error") {
    return true;
  }
  if (type == "commandResult" && !IsValidAvatarReceipt(payload)) return true;
  if (callback_type != nullptr) *callback_type = type;
  if (callback_payload != nullptr) *callback_payload = payload;
  return true;
}

bool UnityPlayerHost::CopyLatestDesktopPetFrame(
    uint32_t* width,
    uint32_t* height,
    uint32_t* stride,
    uint32_t* flags,
    std::vector<unsigned char>* pixels) {
  if (!desktop_pet_presentation_ || width == nullptr || height == nullptr ||
      stride == nullptr || flags == nullptr || pixels == nullptr ||
      !EnsureDesktopPetFrameMapping()) {
    return false;
  }

  const uint32_t sequence_begin = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameSequenceBeginOffset);
  if ((sequence_begin & 1u) != 0 ||
      (has_desktop_pet_frame_sequence_ &&
       sequence_begin == last_desktop_pet_frame_sequence_)) {
    return false;
  }
  MemoryBarrier();

  const uint32_t magic = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameMagicOffset);
  const uint32_t version = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameVersionOffset);
  const uint32_t frame_width = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameWidthOffset);
  const uint32_t frame_height = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameHeightOffset);
  const uint32_t frame_stride = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameStrideOffset);
  const uint32_t payload_bytes = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFramePayloadOffset);
  const uint32_t frame_flags = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameFlagsOffset);
  const uint64_t minimum_stride = static_cast<uint64_t>(frame_width) * 4;
  const uint64_t expected_payload =
      static_cast<uint64_t>(frame_stride) * frame_height;
  if (magic != kDesktopPetFrameMagic ||
      version != kDesktopPetFrameVersion || frame_width == 0 ||
      frame_height == 0 ||
      frame_width > kDesktopPetFrameMaximumDimension ||
      frame_height > kDesktopPetFrameMaximumDimension ||
      frame_stride < minimum_stride ||
      frame_stride > kDesktopPetFrameMaximumDimension * 4 ||
      expected_payload != payload_bytes ||
      payload_bytes > kDesktopPetFrameMappingBytes -
                          kDesktopPetFramePixelsOffset ||
      (frame_flags & ~kDesktopPetFrameTopDown) != 0) {
    return false;
  }

  try {
    pixels->resize(payload_bytes);
  } catch (...) {
    pixels->clear();
    return false;
  }
  std::memcpy(pixels->data(),
              desktop_pet_frame_view_ + kDesktopPetFramePixelsOffset,
              payload_bytes);
  MemoryBarrier();
  const uint32_t sequence_end = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameSequenceEndOffset);
  const uint32_t sequence_begin_again = ReadSharedFrameUint32(
      desktop_pet_frame_view_, kDesktopPetFrameSequenceBeginOffset);
  if ((sequence_end & 1u) != 0 || sequence_begin != sequence_end ||
      sequence_begin != sequence_begin_again) {
    return false;
  }

  last_desktop_pet_frame_sequence_ = sequence_begin;
  has_desktop_pet_frame_sequence_ = true;
  *width = frame_width;
  *height = frame_height;
  *stride = frame_stride;
  *flags = frame_flags;
  return true;
}

void UnityPlayerHost::SetBounds(const RECT& bounds) {
  bounds_ = bounds;
  const int width = bounds_.right - bounds_.left;
  const int height = bounds_.bottom - bounds_.top;
  if (host_window_ != nullptr && width > 0 && height > 0) {
    const bool can_show = player_window_ != nullptr && !suspended_ &&
                          !desktop_pet_presentation_;
    ::SetWindowPos(host_window_, HWND_TOP, bounds_.left, bounds_.top, width,
                   height,
                   SWP_NOACTIVATE |
                       (can_show ? SWP_SHOWWINDOW : SWP_NOREDRAW));
  }
  ResizePlayerIfReady();
}

void UnityPlayerHost::SetPointerGaze(double horizontal, double vertical) {
  if (player_window_ == nullptr || !::IsWindow(player_window_)) {
    return;
  }
  RECT client{};
  if (!::GetClientRect(player_window_, &client)) {
    return;
  }
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) {
    return;
  }
  const double bounded_x = std::clamp(horizontal, -1.0, 1.0);
  const double bounded_y = std::clamp(vertical, -1.0, 1.0);
  const int pointer_x = std::clamp(
      static_cast<int>(std::lround((bounded_x + 1.0) * 0.5 * (width - 1))),
      0, width - 1);
  const int pointer_y = std::clamp(
      static_cast<int>(std::lround((1.0 - bounded_y) * 0.5 * (height - 1))),
      0, height - 1);
  ::PostMessageW(player_window_, WM_MOUSEMOVE, 0,
                 MAKELPARAM(pointer_x, pointer_y));
}

void UnityPlayerHost::Suspend() {
  suspended_ = true;
  if (player_window_ != nullptr) {
    ::PostMessageW(player_window_, WM_ACTIVATEAPP, FALSE, 0);
    ::ShowWindow(player_window_, SW_HIDE);
  }
  if (host_window_ != nullptr) {
    ::ShowWindow(host_window_, SW_HIDE);
  }
}

void UnityPlayerHost::Resume() {
  suspended_ = false;
  if (desktop_pet_presentation_) {
    ResizePlayerIfReady();
    return;
  }
  if (host_window_ != nullptr) {
    ::ShowWindow(host_window_, SW_SHOWNOACTIVATE);
  }
  if (player_window_ != nullptr) {
    ::ShowWindow(player_window_, SW_SHOWNOACTIVATE);
    ::PostMessageW(player_window_, WM_ACTIVATEAPP, TRUE, 0);
    ResizePlayerIfReady();
  }
}

void UnityPlayerHost::Tick() {
  if (!IsRunning()) {
    Stop();
    return;
  }
  if (player_window_ == nullptr || !::IsWindow(player_window_)) {
    AttachPlayerWindow();
  }
  FlushPendingAvatarCommands();
  ResizePlayerIfReady();
}

void UnityPlayerHost::Stop() {
  if (parent_window_ != nullptr) {
    ::KillTimer(parent_window_, kAttachTimerId);
  }
  CloseDesktopPetFrameMapping();
  if (player_window_ != nullptr && ::IsWindow(player_window_)) {
    ::PostMessageW(player_window_, WM_CLOSE, 0, 0);
  }
  DWORD graceful_result = WAIT_OBJECT_0;
  if (process_info_.hProcess != nullptr) {
    graceful_result = ::WaitForSingleObject(process_info_.hProcess, 500);
  }
  // Closing the kill-on-close job guarantees a crashed or unresponsive child
  // cannot outlive Maaso.
  if (process_job_ != nullptr) {
    ::CloseHandle(process_job_);
    process_job_ = nullptr;
  }
  if (process_info_.hProcess != nullptr &&
      graceful_result == WAIT_TIMEOUT) {
    ::WaitForSingleObject(process_info_.hProcess, 250);
  }
  CloseProcessHandles();
  player_window_ = nullptr;
  suspended_ = false;
  if (avatar_ready_) {
    avatar_ready_ = false;
    if (avatar_status_callback_) avatar_status_callback_(false);
  }
  if (host_window_ != nullptr) {
    ::ShowWindow(host_window_, SW_HIDE);
  }
}

std::wstring UnityPlayerHost::ResolvePlayerPath() const {
  std::vector<wchar_t> executable_path(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, executable_path.data(), static_cast<DWORD>(executable_path.size()));
  if (length == 0 ||
      length >= static_cast<DWORD>(executable_path.size())) {
    return std::wstring();
  }
  return (std::filesystem::path(executable_path.data()).parent_path() /
          kUnityRelativePath)
      .wstring();
}

bool UnityPlayerHost::EnsureHostWindow(std::wstring* error_message) {
  if (host_window_ != nullptr && ::IsWindow(host_window_)) {
    return true;
  }
  if (!RegisterUnityHostWindowClass()) {
    if (error_message != nullptr) {
      *error_message = L"The Unity host window class could not be registered.";
    }
    return false;
  }
  host_window_ = ::CreateWindowExW(
      WS_EX_NOACTIVATE, kUnityHostWindowClass, L"",
      WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
      0, 0, 1, 1, parent_window_, nullptr, ::GetModuleHandleW(nullptr), nullptr);
  if (host_window_ == nullptr && error_message != nullptr) {
    *error_message = L"The Unity child host window could not be created.";
  }
  ApplyHostPresentationStyle();
  return host_window_ != nullptr;
}

void UnityPlayerHost::ApplyHostPresentationStyle() {
  if (host_window_ == nullptr || !::IsWindow(host_window_)) {
    return;
  }
  LONG_PTR extended_style = ::GetWindowLongPtrW(host_window_, GWL_EXSTYLE);
  if (desktop_pet_presentation_) {
    extended_style &= ~WS_EX_LAYERED;
    extended_style |= WS_EX_NOACTIVATE;
  } else {
    extended_style &= ~WS_EX_LAYERED;
  }
  ::SetWindowLongPtrW(host_window_, GWL_EXSTYLE, extended_style);
  ::SetWindowPos(host_window_, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOACTIVATE);
}

bool UnityPlayerHost::CreateKillOnCloseJob(std::wstring* error_message) {
  process_job_ = ::CreateJobObjectW(nullptr, nullptr);
  if (process_job_ == nullptr) {
    if (error_message != nullptr) {
      *error_message = L"The Unity lifecycle job could not be created.";
    }
    return false;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!::SetInformationJobObject(process_job_, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits))) {
    if (error_message != nullptr) {
      *error_message = L"The Unity lifecycle job could not be secured.";
    }
    return false;
  }
  return true;
}

void UnityPlayerHost::AttachPlayerWindow() {
  PlayerWindowSearch search{process_info_.dwProcessId, nullptr};
  ::EnumWindows(FindPlayerWindow, reinterpret_cast<LPARAM>(&search));
  if (search.window == nullptr && host_window_ != nullptr) {
    ::EnumChildWindows(host_window_, FindPlayerWindow,
                       reinterpret_cast<LPARAM>(&search));
  }
  if (search.window == nullptr) {
    return;
  }
  player_window_ = search.window;
  ::SetParent(player_window_, host_window_);
  LONG_PTR style = ::GetWindowLongPtrW(player_window_, GWL_STYLE);
  style &= ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
             WS_MAXIMIZEBOX | WS_SYSMENU);
  style |= WS_CHILD;
  ::SetWindowLongPtrW(player_window_, GWL_STYLE, style);
  LONG_PTR extended_style =
      ::GetWindowLongPtrW(player_window_, GWL_EXSTYLE);
  if (desktop_pet_presentation_) {
    extended_style &= ~WS_EX_LAYERED;
    extended_style |= WS_EX_NOACTIVATE;
  } else {
    extended_style &= ~WS_EX_LAYERED;
  }
  ::SetWindowLongPtrW(player_window_, GWL_EXSTYLE, extended_style);
  ::SetWindowPos(player_window_, HWND_TOP, 0, 0, 1, 1,
                 SWP_FRAMECHANGED | SWP_NOACTIVATE);
  if (!suspended_) {
    if (desktop_pet_presentation_) {
      ResizePlayerIfReady();
    } else {
      ::ShowWindow(host_window_, SW_SHOWNOACTIVATE);
      ::ShowWindow(player_window_, SW_SHOWNOACTIVATE);
    }
  }
  FlushPendingAvatarCommands();
}

void UnityPlayerHost::FlushPendingAvatarCommands() {
  while (player_window_ != nullptr && IsRunning() &&
         !pending_avatar_commands_.empty()) {
    const PendingAvatarCommand& command = pending_avatar_commands_.front();
    if (!SendAvatarCommandNow(command.method, command.arguments_json)) return;
    pending_avatar_commands_.pop_front();
  }
}

bool UnityPlayerHost::SendAvatarCommandNow(
    const std::string& method,
    const std::string& arguments_json) {
  if (player_window_ == nullptr || !::IsWindow(player_window_)) return false;
  const AvatarCopyDataHeader header{
      kAvatarProtocolVersion,
      static_cast<uint32_t>(avatar_session_token_.size()),
      static_cast<uint32_t>(method.size()),
      static_cast<uint32_t>(arguments_json.size()),
  };
  std::vector<unsigned char> packet(
      sizeof(header) + avatar_session_token_.size() + method.size() +
      arguments_json.size());
  size_t offset = 0;
  std::memcpy(packet.data() + offset, &header, sizeof(header));
  offset += sizeof(header);
  std::memcpy(packet.data() + offset, avatar_session_token_.data(),
              avatar_session_token_.size());
  offset += avatar_session_token_.size();
  std::memcpy(packet.data() + offset, method.data(), method.size());
  offset += method.size();
  std::memcpy(packet.data() + offset, arguments_json.data(),
              arguments_json.size());

  COPYDATASTRUCT copy_data{};
  copy_data.dwData = kAvatarCommandCopyData;
  copy_data.cbData = static_cast<DWORD>(packet.size());
  copy_data.lpData = packet.data();
  DWORD_PTR receiver_result = 0;
  const LRESULT send_result = ::SendMessageTimeoutW(
      player_window_, WM_COPYDATA,
      reinterpret_cast<WPARAM>(command_host_window_),
      reinterpret_cast<LPARAM>(&copy_data), SMTO_ABORTIFHUNG | SMTO_BLOCK, 50,
      &receiver_result);
  return send_result != 0 &&
         receiver_result == static_cast<DWORD_PTR>(TRUE);
}

bool UnityPlayerHost::EnsureDesktopPetFrameMapping() {
  if (desktop_pet_frame_view_ != nullptr &&
      desktop_pet_frame_mapping_ != nullptr) {
    return true;
  }
  if (!desktop_pet_presentation_ ||
      !IsValidSessionToken(avatar_session_token_)) {
    return false;
  }
  const std::wstring mapping_name =
      L"Local\\MaasoAvatarFrame_" +
      std::wstring(avatar_session_token_.begin(), avatar_session_token_.end());
  HANDLE mapping =
      ::OpenFileMappingW(FILE_MAP_READ, FALSE, mapping_name.c_str());
  if (mapping == nullptr) {
    return false;
  }
  const auto* view = static_cast<const unsigned char*>(::MapViewOfFile(
      mapping, FILE_MAP_READ, 0, 0, kDesktopPetFrameMappingBytes));
  if (view == nullptr) {
    ::CloseHandle(mapping);
    return false;
  }
  desktop_pet_frame_mapping_ = mapping;
  desktop_pet_frame_view_ = view;
  last_desktop_pet_frame_sequence_ = 0;
  has_desktop_pet_frame_sequence_ = false;
  return true;
}

void UnityPlayerHost::CloseDesktopPetFrameMapping() {
  if (desktop_pet_frame_view_ != nullptr) {
    ::UnmapViewOfFile(desktop_pet_frame_view_);
    desktop_pet_frame_view_ = nullptr;
  }
  if (desktop_pet_frame_mapping_ != nullptr) {
    ::CloseHandle(desktop_pet_frame_mapping_);
    desktop_pet_frame_mapping_ = nullptr;
  }
  last_desktop_pet_frame_sequence_ = 0;
  has_desktop_pet_frame_sequence_ = false;
}

void UnityPlayerHost::ResizePlayerIfReady() {
  if (player_window_ == nullptr || !::IsWindow(player_window_)) {
    return;
  }
  const LONG_PTR unity_state = ::GetWindowLongPtrW(player_window_, GWLP_USERDATA);
  if ((unity_state & 1) == 0) {
    return;
  }
  const int width = bounds_.right - bounds_.left;
  const int height = bounds_.bottom - bounds_.top;
  if (width > 0 && height > 0) {
    ::SetWindowPos(player_window_, HWND_TOP, 0, 0, width, height,
                   SWP_NOACTIVATE |
                       (suspended_ || desktop_pet_presentation_
                            ? SWP_NOREDRAW
                            : SWP_SHOWWINDOW));
    if (desktop_pet_presentation_) {
      ::ShowWindow(player_window_, SW_HIDE);
      if (host_window_ != nullptr) {
        ::ShowWindow(host_window_, SW_HIDE);
      }
    }
  }
}

void UnityPlayerHost::CloseProcessHandles() {
  if (process_info_.hThread != nullptr) {
    ::CloseHandle(process_info_.hThread);
  }
  if (process_info_.hProcess != nullptr) {
    ::CloseHandle(process_info_.hProcess);
  }
  process_info_ = {};
}
