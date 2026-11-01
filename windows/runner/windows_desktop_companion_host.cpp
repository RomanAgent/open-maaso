#include "windows_desktop_companion_host.h"

#include <flutter/standard_method_codec.h>

#include <dwmapi.h>
#include <windowsx.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <limits>
#include <set>
#include <utility>

#include "unity_player_host.h"

namespace {

constexpr char kDesktopCompanionChannel[] = "maaso/desktop_companion";
constexpr wchar_t kPetWindowClass[] = L"MaasoWindowsDesktopPet";
constexpr wchar_t kOverlayWindowClass[] = L"MaasoWindowsDesktopPetOverlay";
constexpr wchar_t kBubbleWindowClass[] = L"MaasoWindowsDesktopPetBubble";
constexpr COLORREF kTransparencyKey = RGB(0, 0, 0);
constexpr size_t kMaximumMenuItems = 24;
constexpr size_t kMaximumMenuIdBytes = 128;
constexpr size_t kMaximumMenuLabelBytes = 80;
constexpr size_t kMaximumBubbleCharacters = 420;
constexpr uint32_t kDesktopPetFrameTopDown = 1u << 0;
constexpr DWORD kNativeSpatialVersion = 1;
constexpr wchar_t kSpatialRegistryPath[] =
    L"Software\\Maaso\\DesktopCompanion";
constexpr wchar_t kSpatialVersionValue[] = L"SpatialVersion";
constexpr wchar_t kSpatialMonitorDeviceValue[] = L"MonitorDevice";
constexpr wchar_t kSpatialNormalizedXValue[] = L"NormalizedX";
constexpr wchar_t kSpatialNormalizedYValue[] = L"NormalizedY";
constexpr wchar_t kSpatialAttachmentKindValue[] = L"AttachmentKind";
constexpr wchar_t kSpatialAttachmentMonitorDeviceValue[] =
    L"AttachmentMonitorDevice";
constexpr wchar_t kSpatialAttachmentWindowHandleValue[] =
    L"AttachmentWindowHandle";
constexpr wchar_t kSpatialAttachmentWindowProcessIdValue[] =
    L"AttachmentWindowProcessId";
constexpr int kMinimumSnapTargetLogicalWidth = 160;
constexpr int kMinimumSnapTargetLogicalHeight = 80;

enum class SpatialAttachmentKind : DWORD {
  kNone = 0,
  kWorkLeft = 1,
  kWorkTop = 2,
  kWorkRight = 3,
  kWorkBottom = 4,
  kWindowTop = 5,
};

struct MonitorSnapshot {
  HMONITOR handle = nullptr;
  MONITORINFOEXW info{};
};

struct PersistedSpatialStateV1 {
  std::wstring monitor_device;
  double normalized_x = 0.0;
  double normalized_y = 0.0;
  SpatialAttachmentKind attachment_kind = SpatialAttachmentKind::kNone;
  std::wstring attachment_monitor_device;
  HWND attachment_window = nullptr;
  DWORD attachment_window_process_id = 0;
};

struct SnapCandidate {
  SpatialAttachmentKind kind = SpatialAttachmentKind::kNone;
  std::wstring monitor_device;
  HWND window = nullptr;
  DWORD window_process_id = 0;
  POINT origin{};
  double distance = std::numeric_limits<double>::infinity();
};

bool ReadMonitorSnapshot(HMONITOR monitor, MonitorSnapshot* output) {
  if (monitor == nullptr || output == nullptr) {
    return false;
  }
  MonitorSnapshot snapshot;
  snapshot.handle = monitor;
  snapshot.info.cbSize = sizeof(snapshot.info);
  if (!::GetMonitorInfoW(
          monitor, reinterpret_cast<MONITORINFO*>(&snapshot.info))) {
    return false;
  }
  *output = snapshot;
  return true;
}

struct MonitorSearchContext {
  const std::wstring* device = nullptr;
  MonitorSnapshot* output = nullptr;
  bool primary_only = false;
};

BOOL CALLBACK FindMonitorCallback(HMONITOR monitor,
                                  HDC,
                                  LPRECT,
                                  LPARAM data) {
  auto* context = reinterpret_cast<MonitorSearchContext*>(data);
  if (context == nullptr || context->output == nullptr) {
    return FALSE;
  }
  MonitorSnapshot snapshot;
  if (!ReadMonitorSnapshot(monitor, &snapshot)) {
    return TRUE;
  }
  const bool matches = context->primary_only
                           ? (snapshot.info.dwFlags & MONITORINFOF_PRIMARY) != 0
                           : context->device != nullptr &&
                                 *context->device == snapshot.info.szDevice;
  if (!matches) {
    return TRUE;
  }
  *context->output = snapshot;
  return FALSE;
}

bool FindMonitorByDevice(const std::wstring& device,
                         MonitorSnapshot* output) {
  if (device.empty() || output == nullptr) {
    return false;
  }
  MonitorSearchContext context{&device, output, false};
  ::EnumDisplayMonitors(nullptr, nullptr, FindMonitorCallback,
                        reinterpret_cast<LPARAM>(&context));
  return output->handle != nullptr;
}

bool FindPrimaryMonitor(MonitorSnapshot* output) {
  if (output == nullptr) {
    return false;
  }
  MonitorSearchContext context{nullptr, output, true};
  ::EnumDisplayMonitors(nullptr, nullptr, FindMonitorCallback,
                        reinterpret_cast<LPARAM>(&context));
  return output->handle != nullptr;
}

bool MonitorForRect(const RECT& bounds, MonitorSnapshot* output) {
  return ReadMonitorSnapshot(
      ::MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST), output);
}

bool MonitorForPoint(POINT point, MonitorSnapshot* output) {
  return ReadMonitorSnapshot(
      ::MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST), output);
}

double NormalizedAxis(int origin,
                      int work_start,
                      int work_end,
                      int extent,
                      int leading_inset = 0,
                      int trailing_inset = 0) {
  const int minimum = work_start - std::max(0, leading_inset);
  const int maximum = std::max(
      minimum, work_end - extent + std::max(0, trailing_inset));
  const double travel = static_cast<double>(maximum - minimum);
  if (travel <= 0.0) {
    return 0.0;
  }
  return std::clamp((static_cast<double>(origin) - minimum) / travel, 0.0,
                    1.0);
}

POINT OriginFromNormalized(const RECT& work,
                           int width,
                           int height,
                           double normalized_x,
                           double normalized_y,
                           int left_inset = 0,
                           int right_inset = 0) {
  const int minimum_left = work.left - std::max(0, left_inset);
  const int maximum_left = std::max(
      minimum_left, work.right - width + std::max(0, right_inset));
  const int horizontal_travel = maximum_left - minimum_left;
  const int vertical_travel =
      std::max(0, work.bottom - work.top - height);
  return POINT{
      minimum_left + static_cast<int>(std::lround(
                         std::clamp(normalized_x, 0.0, 1.0) *
                         horizontal_travel)),
      work.top + static_cast<int>(std::lround(
                     std::clamp(normalized_y, 0.0, 1.0) * vertical_travel)),
  };
}

POINT ClampOriginToWorkArea(POINT proposed,
                            const RECT& work,
                            int width,
                            int height,
                            int left_inset = 0,
                            int right_inset = 0) {
  const int minimum_left = work.left - std::max(0, left_inset);
  const int maximum_left = std::max(
      minimum_left, work.right - width + std::max(0, right_inset));
  return POINT{
      std::clamp(proposed.x, minimum_left, maximum_left),
      std::clamp(proposed.y, work.top,
                 std::max(work.top, work.bottom - height)),
  };
}

int DpiScaledLogicalPixels(double logical_pixels, UINT dpi) {
  const double dpi_scale = static_cast<double>(dpi == 0 ? 96 : dpi) / 96.0;
  return std::max(1,
                  static_cast<int>(std::lround(logical_pixels * dpi_scale)));
}

bool ReadRegistryDword(HKEY key, const wchar_t* name, DWORD* output) {
  DWORD type = 0;
  DWORD size = sizeof(DWORD);
  DWORD value = 0;
  if (::RegQueryValueExW(key, name, nullptr, &type,
                         reinterpret_cast<BYTE*>(&value),
                         &size) != ERROR_SUCCESS ||
      type != REG_DWORD || size != sizeof(DWORD) || output == nullptr) {
    return false;
  }
  *output = value;
  return true;
}

bool ReadRegistryQword(HKEY key, const wchar_t* name, ULONGLONG* output) {
  DWORD type = 0;
  DWORD size = sizeof(ULONGLONG);
  ULONGLONG value = 0;
  if (::RegQueryValueExW(key, name, nullptr, &type,
                         reinterpret_cast<BYTE*>(&value),
                         &size) != ERROR_SUCCESS ||
      type != REG_QWORD || size != sizeof(ULONGLONG) || output == nullptr) {
    return false;
  }
  *output = value;
  return true;
}

bool ReadRegistryDouble(HKEY key, const wchar_t* name, double* output) {
  DWORD type = 0;
  DWORD size = sizeof(double);
  double value = 0.0;
  if (::RegQueryValueExW(key, name, nullptr, &type,
                         reinterpret_cast<BYTE*>(&value),
                         &size) != ERROR_SUCCESS ||
      type != REG_BINARY || size != sizeof(double) || output == nullptr ||
      !std::isfinite(value)) {
    return false;
  }
  *output = value;
  return true;
}

bool ReadRegistryDevice(HKEY key,
                        const wchar_t* name,
                        std::wstring* output) {
  DWORD type = 0;
  DWORD size = 0;
  if (output == nullptr ||
      ::RegQueryValueExW(key, name, nullptr, &type, nullptr, &size) !=
          ERROR_SUCCESS ||
      type != REG_SZ || size < sizeof(wchar_t) ||
      size > CCHDEVICENAME * sizeof(wchar_t) ||
      size % sizeof(wchar_t) != 0) {
    return false;
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t));
  if (::RegQueryValueExW(key, name, nullptr, &type,
                         reinterpret_cast<BYTE*>(buffer.data()),
                         &size) != ERROR_SUCCESS ||
      buffer.empty() || buffer.back() != L'\0') {
    return false;
  }
  const auto terminator =
      std::find(buffer.begin(), buffer.end(), static_cast<wchar_t>(L'\0'));
  if (terminator == buffer.begin() || terminator != buffer.end() - 1) {
    return false;
  }
  output->assign(buffer.begin(), terminator);
  return true;
}

bool WriteRegistryDword(HKEY key, const wchar_t* name, DWORD value) {
  return ::RegSetValueExW(key, name, 0, REG_DWORD,
                          reinterpret_cast<const BYTE*>(&value),
                          sizeof(value)) == ERROR_SUCCESS;
}

bool WriteRegistryQword(HKEY key, const wchar_t* name, ULONGLONG value) {
  return ::RegSetValueExW(key, name, 0, REG_QWORD,
                          reinterpret_cast<const BYTE*>(&value),
                          sizeof(value)) == ERROR_SUCCESS;
}

bool WriteRegistryDouble(HKEY key, const wchar_t* name, double value) {
  return std::isfinite(value) && value >= 0.0 && value <= 1.0 &&
         ::RegSetValueExW(key, name, 0, REG_BINARY,
                          reinterpret_cast<const BYTE*>(&value),
                          sizeof(value)) == ERROR_SUCCESS;
}

bool WriteRegistryDevice(HKEY key,
                         const wchar_t* name,
                         const std::wstring& value) {
  if (value.empty() || value.size() >= CCHDEVICENAME) {
    return false;
  }
  const DWORD size =
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  return ::RegSetValueExW(key, name, 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(value.c_str()),
                          size) == ERROR_SUCCESS;
}

bool DeleteRegistryValue(HKEY key, const wchar_t* name) {
  const LONG status = ::RegDeleteValueW(key, name);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

bool LoadPersistedSpatialStateV1(PersistedSpatialStateV1* output) {
  if (output == nullptr) {
    return false;
  }
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kSpatialRegistryPath, 0,
                      KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  PersistedSpatialStateV1 state;
  DWORD version = 0;
  DWORD attachment_kind = 0;
  bool valid = ReadRegistryDword(key, kSpatialVersionValue, &version) &&
               version == kNativeSpatialVersion &&
               ReadRegistryDevice(key, kSpatialMonitorDeviceValue,
                                  &state.monitor_device) &&
               ReadRegistryDouble(key, kSpatialNormalizedXValue,
                                  &state.normalized_x) &&
               ReadRegistryDouble(key, kSpatialNormalizedYValue,
                                  &state.normalized_y) &&
               state.normalized_x >= 0.0 && state.normalized_x <= 1.0 &&
               state.normalized_y >= 0.0 && state.normalized_y <= 1.0 &&
               ReadRegistryDword(key, kSpatialAttachmentKindValue,
                                 &attachment_kind) &&
               attachment_kind <=
                   static_cast<DWORD>(SpatialAttachmentKind::kWindowTop);
  if (valid) {
    state.attachment_kind =
        static_cast<SpatialAttachmentKind>(attachment_kind);
    switch (state.attachment_kind) {
      case SpatialAttachmentKind::kWorkLeft:
      case SpatialAttachmentKind::kWorkTop:
      case SpatialAttachmentKind::kWorkRight:
      case SpatialAttachmentKind::kWorkBottom:
        valid = ReadRegistryDevice(key, kSpatialAttachmentMonitorDeviceValue,
                                   &state.attachment_monitor_device);
        break;
      case SpatialAttachmentKind::kWindowTop: {
        ULONGLONG raw_window = 0;
        valid = ReadRegistryQword(key, kSpatialAttachmentWindowHandleValue,
                                  &raw_window) &&
                raw_window > 0 &&
                raw_window <= std::numeric_limits<UINT_PTR>::max() &&
                ReadRegistryDword(key,
                                  kSpatialAttachmentWindowProcessIdValue,
                                  &state.attachment_window_process_id) &&
                state.attachment_window_process_id != 0;
        if (valid) {
          state.attachment_window = reinterpret_cast<HWND>(
              static_cast<UINT_PTR>(raw_window));
        }
        break;
      }
      case SpatialAttachmentKind::kNone:
        break;
    }
  }
  ::RegCloseKey(key);
  if (!valid) {
    return false;
  }
  *output = std::move(state);
  return true;
}

bool SavePersistedSpatialStateV1(const PersistedSpatialStateV1& state) {
  if (state.monitor_device.empty() || !std::isfinite(state.normalized_x) ||
      !std::isfinite(state.normalized_y) || state.normalized_x < 0.0 ||
      state.normalized_x > 1.0 || state.normalized_y < 0.0 ||
      state.normalized_y > 1.0) {
    return false;
  }
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kSpatialRegistryPath, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  bool valid = WriteRegistryDword(key, kSpatialVersionValue, 0) &&
               WriteRegistryDevice(key, kSpatialMonitorDeviceValue,
                                   state.monitor_device) &&
               WriteRegistryDouble(key, kSpatialNormalizedXValue,
                                   state.normalized_x) &&
               WriteRegistryDouble(key, kSpatialNormalizedYValue,
                                   state.normalized_y) &&
               WriteRegistryDword(
                   key, kSpatialAttachmentKindValue,
                   static_cast<DWORD>(state.attachment_kind));
  switch (state.attachment_kind) {
    case SpatialAttachmentKind::kWorkLeft:
    case SpatialAttachmentKind::kWorkTop:
    case SpatialAttachmentKind::kWorkRight:
    case SpatialAttachmentKind::kWorkBottom:
      valid = valid &&
              WriteRegistryDevice(key, kSpatialAttachmentMonitorDeviceValue,
                                  state.attachment_monitor_device) &&
              DeleteRegistryValue(key, kSpatialAttachmentWindowHandleValue) &&
              DeleteRegistryValue(key,
                                  kSpatialAttachmentWindowProcessIdValue);
      break;
    case SpatialAttachmentKind::kWindowTop: {
      const ULONGLONG raw_window = static_cast<ULONGLONG>(
          reinterpret_cast<UINT_PTR>(state.attachment_window));
      valid = valid && raw_window > 0 &&
              state.attachment_window_process_id != 0 &&
              WriteRegistryQword(key, kSpatialAttachmentWindowHandleValue,
                                 raw_window) &&
              WriteRegistryDword(key,
                                 kSpatialAttachmentWindowProcessIdValue,
                                 state.attachment_window_process_id) &&
              DeleteRegistryValue(key,
                                  kSpatialAttachmentMonitorDeviceValue);
      break;
    }
    case SpatialAttachmentKind::kNone:
      valid = valid &&
              DeleteRegistryValue(key, kSpatialAttachmentMonitorDeviceValue) &&
              DeleteRegistryValue(key, kSpatialAttachmentWindowHandleValue) &&
              DeleteRegistryValue(key,
                                  kSpatialAttachmentWindowProcessIdValue);
      break;
  }
  if (valid) {
    valid = WriteRegistryDword(key, kSpatialVersionValue,
                              kNativeSpatialVersion);
  }
  ::RegCloseKey(key);
  return valid;
}

bool IsMaasoAuxiliaryProcess(DWORD process_id) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                 process_id);
  if (process == nullptr) {
    return false;
  }
  std::vector<wchar_t> path(32768, L'\0');
  DWORD length = static_cast<DWORD>(path.size());
  const bool queried =
      ::QueryFullProcessImageNameW(process, 0, path.data(), &length) != FALSE;
  ::CloseHandle(process);
  if (!queried || length == 0 || length >= path.size()) {
    return false;
  }
  const std::wstring image_path(path.data(), length);
  const size_t separator = image_path.find_last_of(L"\\/");
  const std::wstring executable_name =
      separator == std::wstring::npos ? image_path
                                      : image_path.substr(separator + 1);
  return ::_wcsicmp(executable_name.c_str(), L"MaasoAvatar.exe") == 0 ||
         ::_wcsicmp(executable_name.c_str(), L"UnityCrashHandler64.exe") ==
             0 ||
         ::_wcsicmp(executable_name.c_str(), L"UnityCrashHandler32.exe") == 0;
}

bool IsEligibleSnapWindow(HWND window,
                          DWORD own_process_id,
                          int minimum_width,
                          int minimum_height,
                          RECT* bounds,
                          DWORD* process_id) {
  if (window == nullptr || !::IsWindow(window) || !::IsWindowVisible(window) ||
      ::IsIconic(window) || ::GetAncestor(window, GA_ROOT) != window ||
      ::GetWindow(window, GW_OWNER) != nullptr ||
      (::GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) {
    return false;
  }
  DWORD candidate_process_id = 0;
  ::GetWindowThreadProcessId(window, &candidate_process_id);
  if (candidate_process_id == 0 || candidate_process_id == own_process_id ||
      IsMaasoAuxiliaryProcess(candidate_process_id)) {
    return false;
  }
  BOOL cloaked = FALSE;
  if (SUCCEEDED(::DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked,
                                        sizeof(cloaked))) &&
      cloaked) {
    return false;
  }
  RECT candidate_bounds{};
  const HRESULT frame_bounds_result = ::DwmGetWindowAttribute(
      window, DWMWA_EXTENDED_FRAME_BOUNDS, &candidate_bounds,
      sizeof(candidate_bounds));
  if (FAILED(frame_bounds_result) &&
      !::GetWindowRect(window, &candidate_bounds)) {
    return false;
  }
  if (candidate_bounds.right - candidate_bounds.left < minimum_width ||
      candidate_bounds.bottom - candidate_bounds.top < minimum_height) {
    return false;
  }
  if (bounds != nullptr) {
    *bounds = candidate_bounds;
  }
  if (process_id != nullptr) {
    *process_id = candidate_process_id;
  }
  return true;
}

double OriginDistance(POINT first, POINT second) {
  return std::hypot(static_cast<double>(first.x) - second.x,
                    static_cast<double>(first.y) - second.y);
}

struct SnapWindowEnumerationContext {
  HMONITOR monitor = nullptr;
  RECT work{};
  POINT current_origin{};
  int pet_width = 0;
  int pet_height = 0;
  int minimum_width = 0;
  int minimum_height = 0;
  DWORD own_process_id = 0;
  std::vector<SnapCandidate>* candidates = nullptr;
};

BOOL CALLBACK CollectSnapWindowCallback(HWND window, LPARAM data) {
  auto* context = reinterpret_cast<SnapWindowEnumerationContext*>(data);
  if (context == nullptr || context->candidates == nullptr) {
    return FALSE;
  }
  RECT bounds{};
  DWORD process_id = 0;
  if (!IsEligibleSnapWindow(window, context->own_process_id,
                            context->minimum_width, context->minimum_height,
                            &bounds, &process_id) ||
      ::MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST) !=
          context->monitor) {
    return TRUE;
  }
  const int top = bounds.top - context->pet_height;
  const int minimum_left = std::max(bounds.left, context->work.left);
  const int maximum_left =
      std::min(bounds.right - context->pet_width,
               context->work.right - context->pet_width);
  if (minimum_left > maximum_left || top < context->work.top ||
      top > context->work.bottom - context->pet_height) {
    return TRUE;
  }
  const POINT origin{
      std::clamp(context->current_origin.x, minimum_left, maximum_left), top};
  context->candidates->push_back(SnapCandidate{
      SpatialAttachmentKind::kWindowTop,
      std::wstring(),
      window,
      process_id,
      origin,
      OriginDistance(context->current_origin, origin),
  });
  return TRUE;
}

bool SameAttachment(const SnapCandidate& candidate,
                    DWORD attachment_kind,
                    const std::wstring& attachment_monitor_device,
                    HWND attachment_window,
                    DWORD attachment_window_process_id) {
  if (static_cast<DWORD>(candidate.kind) != attachment_kind) {
    return false;
  }
  if (candidate.kind == SpatialAttachmentKind::kWindowTop) {
    return candidate.window == attachment_window &&
           candidate.window_process_id == attachment_window_process_id;
  }
  return candidate.kind != SpatialAttachmentKind::kNone &&
         candidate.monitor_device == attachment_monitor_device;
}

bool HasReservedWorkEdge(SpatialAttachmentKind kind,
                         const MONITORINFOEXW& monitor) {
  switch (kind) {
    case SpatialAttachmentKind::kWorkLeft:
      return monitor.rcWork.left > monitor.rcMonitor.left;
    case SpatialAttachmentKind::kWorkTop:
      return monitor.rcWork.top > monitor.rcMonitor.top;
    case SpatialAttachmentKind::kWorkRight:
      return monitor.rcWork.right < monitor.rcMonitor.right;
    case SpatialAttachmentKind::kWorkBottom:
      return monitor.rcWork.bottom < monitor.rcMonitor.bottom;
    case SpatialAttachmentKind::kNone:
    case SpatialAttachmentKind::kWindowTop:
      return false;
  }
  return false;
}

const flutter::EncodableValue* FindValue(const flutter::EncodableMap& map,
                                         const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

const std::string* ReadString(const flutter::EncodableMap& map,
                              const char* key) {
  const auto* value = FindValue(map, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

bool ReadBool(const flutter::EncodableMap& map,
              const char* key,
              bool fallback) {
  const auto* value = FindValue(map, key);
  const auto* result = value == nullptr ? nullptr : std::get_if<bool>(value);
  return result == nullptr ? fallback : *result;
}

bool ReadRequiredBool(const flutter::EncodableMap& map,
                      const char* key,
                      bool* output) {
  const auto* value = FindValue(map, key);
  const auto* boolean =
      value == nullptr ? nullptr : std::get_if<bool>(value);
  if (boolean == nullptr || output == nullptr) {
    return false;
  }
  *output = *boolean;
  return true;
}

bool ReadInt(const flutter::EncodableMap& map, const char* key, int* output) {
  const auto* value = FindValue(map, key);
  if (value == nullptr || output == nullptr) {
    return false;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    *output = *number;
    return true;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    if (*number < std::numeric_limits<int>::min() ||
        *number > std::numeric_limits<int>::max()) {
      return false;
    }
    *output = static_cast<int>(*number);
    return true;
  }
  return false;
}

bool ReadFiniteDouble(const flutter::EncodableMap& map,
                      const char* key,
                      double* output) {
  const auto* value = FindValue(map, key);
  if (value == nullptr || output == nullptr) {
    return false;
  }
  double number = 0.0;
  if (const auto* value_double = std::get_if<double>(value)) {
    number = *value_double;
  } else if (const auto* value_int32 = std::get_if<int32_t>(value)) {
    number = static_cast<double>(*value_int32);
  } else if (const auto* value_int64 = std::get_if<int64_t>(value)) {
    number = static_cast<double>(*value_int64);
  } else {
    return false;
  }
  if (!std::isfinite(number)) {
    return false;
  }
  *output = number;
  return true;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
      nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(),
                            length) != length) {
    return std::wstring();
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
      nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(length), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(),
                            length, nullptr, nullptr) != length) {
    return std::string();
  }
  return result;
}

std::wstring Trimmed(std::wstring value) {
  const auto first = std::find_if_not(value.begin(), value.end(), [](wchar_t c) {
    return std::iswspace(c) != 0;
  });
  const auto last = std::find_if_not(value.rbegin(), value.rend(), [](wchar_t c) {
                      return std::iswspace(c) != 0;
                    }).base();
  if (first >= last) {
    return std::wstring();
  }
  return std::wstring(first, last);
}

bool RegisterWindowClass(const wchar_t* name, WNDPROC procedure) {
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = procedure;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  window_class.hbrBackground =
      static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH));
  window_class.lpszClassName = name;
  if (::RegisterClassExW(&window_class) != 0) {
    return true;
  }
  return ::GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

double ClampUnit(double value) {
  return std::clamp(value, -1.0, 1.0);
}

bool IsSupportedVisualScale(double value) {
  constexpr std::array<double, 4> kSupportedScales{1.2, 1.8, 2.4, 3.0};
  return std::any_of(
      kSupportedScales.begin(), kSupportedScales.end(),
      [value](double candidate) { return std::abs(value - candidate) < 0.0001; });
}

int64_t BoundedTimestampMilliseconds() {
  const ULONGLONG now = ::GetTickCount64();
  const auto maximum =
      static_cast<ULONGLONG>(std::numeric_limits<int64_t>::max());
  return now > maximum ? std::numeric_limits<int64_t>::max()
                       : static_cast<int64_t>(now);
}

}  // namespace

WindowsDesktopCompanionHost::WindowsDesktopCompanionHost(
    flutter::BinaryMessenger* messenger,
    UnityPlayerHost* pet_unity_player_host,
    PetStartedCallback pet_started_callback)
    : messenger_(messenger),
      pet_unity_player_host_(pet_unity_player_host),
      pet_started_callback_(std::move(pet_started_callback)) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger_, kDesktopCompanionChannel,
          &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
  LoadInitialBounds();
}

WindowsDesktopCompanionHost::~WindowsDesktopCompanionHost() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  pet_started_callback_ = {};
  Dispose();
}

bool WindowsDesktopCompanionHost::IsVisible() const {
  return visible_;
}

void WindowsDesktopCompanionHost::Dispose() {
  Hide();
  ReleasePetSurface();
  pet_frame_pixels_.clear();
  if (bubble_window_ != nullptr) {
    ::DestroyWindow(bubble_window_);
    bubble_window_ = nullptr;
  }
  if (overlay_window_ != nullptr) {
    ::DestroyWindow(overlay_window_);
    overlay_window_ = nullptr;
  }
  if (pet_window_ != nullptr) {
    ::DestroyWindow(pet_window_);
    pet_window_ = nullptr;
  }
  bubble_text_.clear();
}

LRESULT CALLBACK WindowsDesktopCompanionHost::PetWindowProc(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  auto* host = reinterpret_cast<WindowsDesktopCompanionHost*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    host = static_cast<WindowsDesktopCompanionHost*>(create->lpCreateParams);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(host));
  }
  return host == nullptr
             ? ::DefWindowProcW(window, message, wparam, lparam)
             : host->HandlePetMessage(window, message, wparam, lparam);
}

LRESULT CALLBACK WindowsDesktopCompanionHost::OverlayWindowProc(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  auto* host = reinterpret_cast<WindowsDesktopCompanionHost*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    host = static_cast<WindowsDesktopCompanionHost*>(create->lpCreateParams);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(host));
  }
  return host == nullptr
             ? ::DefWindowProcW(window, message, wparam, lparam)
             : host->HandleOverlayMessage(window, message, wparam, lparam);
}

LRESULT CALLBACK WindowsDesktopCompanionHost::BubbleWindowProc(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  auto* host = reinterpret_cast<WindowsDesktopCompanionHost*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    host = static_cast<WindowsDesktopCompanionHost*>(create->lpCreateParams);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(host));
  }
  return host == nullptr
             ? ::DefWindowProcW(window, message, wparam, lparam)
             : host->HandleBubbleMessage(window, message, wparam, lparam);
}

LRESULT WindowsDesktopCompanionHost::HandlePetMessage(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  switch (message) {
    case WM_NCHITTEST:
      // The interaction overlay exclusively owns the avatar's draggable and
      // context-menu region. Keep the Unity host itself transparent to input
      // so pixels outside that region reach the desktop window underneath.
      return HTTRANSPARENT;
    case WM_TIMER:
      if (wparam == UnityPlayerHost::kAttachTimerId &&
          pet_unity_player_host_ != nullptr) {
        pet_unity_player_host_->Tick();
        PresentLatestDesktopPetFrame();
        if (visible_ && !pet_unity_player_host_->IsRunning()) {
          FailPendingShow(
              "windows_desktop_companion_unavailable",
              "The Unity desktop avatar process exited before its first frame.");
          Hide();
          InvokeCommand("hostUnavailable");
        } else if (visible_ && avatar_startup_deadline_ != 0) {
          if (pet_unity_player_host_->IsAvatarReady() &&
              pending_show_result_ == nullptr) {
            avatar_startup_deadline_ = 0;
          } else if (::GetTickCount64() >= avatar_startup_deadline_) {
            FailPendingShow(
                "windows_desktop_companion_first_frame_timeout",
                "The Unity desktop avatar did not present its first frame in time.");
            Hide();
            InvokeCommand("hostUnavailable");
          }
        }
        return 0;
      }
      break;
    case WM_ERASEBKGND:
      return 1;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_DPICHANGED:
      // The overlay owns the paired resize so the Unity and interaction HWNDs
      // stay pixel-aligned while crossing monitors.
      return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

LRESULT WindowsDesktopCompanionHost::HandleOverlayMessage(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  switch (message) {
    case WM_NCHITTEST: {
      // A drag that began on the silhouette keeps its capture outside it.
      if (pointer_down_active_) return HTCLIENT;
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ::ScreenToClient(window, &point);
      return IsAvatarPoint(point) ? HTCLIENT : HTTRANSPARENT;
    }
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_SETCURSOR:
      if (LOWORD(lparam) == HTCLIENT) {
        ::SetCursor(::LoadCursorW(nullptr, IDC_HAND));
        return TRUE;
      }
      break;
    case WM_LBUTTONDOWN: {
      POINT cursor{};
      const POINT client_point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (IsAvatarPoint(client_point) && ::GetCursorPos(&cursor)) {
        BeginDrag(cursor, client_point);
      }
      return 0;
    }
    case WM_MOUSEMOVE:
      if (pointer_down_active_) {
        POINT cursor{};
        if (::GetCursorPos(&cursor)) {
          ContinueDrag(cursor);
        }
      }
      return 0;
    case WM_LBUTTONUP: {
      POINT cursor{};
      if (::GetCursorPos(&cursor)) {
        EndDrag(cursor);
      } else {
        CancelDrag();
      }
      return 0;
    }
    case WM_CAPTURECHANGED:
      CancelDrag();
      return 0;
    case WM_RBUTTONUP: {
      POINT cursor{};
      const POINT client_point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (IsAvatarPoint(client_point) && ::GetCursorPos(&cursor)) {
        PresentContextMenu(cursor);
      }
      return 0;
    }
    case WM_TIMER:
      if (wparam == kGazeTimerId) {
        UpdateGaze();
        return 0;
      }
      break;
    case WM_DISPLAYCHANGE: {
      RestoreSpatialPosition();
      SaveBounds();
      return 0;
    }
    case WM_DPICHANGED: {
      const auto* suggested = reinterpret_cast<const RECT*>(lparam);
      const POINT origin = suggested == nullptr
                               ? POINT{window_bounds_.left, window_bounds_.top}
                               : POINT{suggested->left, suggested->top};
      ResizeForDpi(HIWORD(wparam), origin);
      return 0;
    }
    case WM_PAINT:
      DrawInteractionOverlay(window);
      return 0;
    case WM_ERASEBKGND:
      return 1;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

LRESULT WindowsDesktopCompanionHost::HandleBubbleMessage(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  switch (message) {
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_PAINT:
      DrawOverlay(window);
      return 0;
    case WM_ERASEBKGND:
      return 1;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

void WindowsDesktopCompanionHost::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "configurePresentation") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error(
          "invalid_desktop_companion_presentation",
          "Desktop companion presentation configuration is required.");
      return;
    }
    ConfigurePresentation(*arguments, std::move(result));
    return;
  }
  if (call.method_name() == "configureMenu") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_desktop_companion_menu",
                    "Desktop companion menu configuration is required.");
      return;
    }
    ConfigureMenu(*arguments, std::move(result));
    return;
  }
  if (call.method_name() == "show") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    int interaction_generation = 0;
    if (arguments == nullptr || arguments->size() != 1 ||
        !ReadInt(*arguments, "interactionGeneration",
                 &interaction_generation) ||
        interaction_generation < 1 ||
        interaction_generation > std::numeric_limits<int32_t>::max()) {
      result->Error(
          "invalid_desktop_companion_show",
          "Desktop companion show requires one valid interaction generation.");
      return;
    }
    if (pending_show_result_ != nullptr) {
      result->Error(
          "windows_desktop_companion_show_in_progress",
          "A desktop companion presentation is already starting.");
      return;
    }
    std::wstring error;
    if (!Show(&error, static_cast<int32_t>(interaction_generation))) {
      result->Error("windows_desktop_companion_unavailable",
                    WideToUtf8(error));
      return;
    }
    pending_show_result_ = std::move(result);
    return;
  }
  if (call.method_name() == "hide") {
    Hide();
    result->Success();
    return;
  }
  if (call.method_name() == "showBubble") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    const std::string* text =
        arguments == nullptr ? nullptr : ReadString(*arguments, "text");
    std::wstring bounded = text == nullptr ? std::wstring() : Utf8ToWide(*text);
    if (bounded.size() > kMaximumBubbleCharacters) {
      bounded.resize(kMaximumBubbleCharacters);
    }
    bubble_text_ = Trimmed(std::move(bounded));
    if (bubble_window_ != nullptr) {
      ::InvalidateRect(bubble_window_, nullptr, FALSE);
    }
    result->Success();
    return;
  }
  if (call.method_name() == "clearBubble") {
    bubble_text_.clear();
    if (bubble_window_ != nullptr) {
      ::InvalidateRect(bubble_window_, nullptr, FALSE);
    }
    result->Success();
    return;
  }
  if (call.method_name() == "dispose") {
    Dispose();
    result->Success();
    return;
  }
  result->NotImplemented();
}

void WindowsDesktopCompanionHost::ConfigurePresentation(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  int version = 0;
  int target_fps = 0;
  double visual_scale = 0.0;
  double snap_acquire_distance = 0.0;
  double snap_release_distance = 0.0;
  bool always_on_top = false;
  bool snap_enabled = false;
  const std::string* quality = ReadString(arguments, "quality");
  const bool valid =
      arguments.size() == 8 && ReadInt(arguments, "version", &version) &&
      version == 1 && quality != nullptr &&
      (*quality == "eco" || *quality == "balanced" ||
       *quality == "crisp") &&
      ReadInt(arguments, "targetFps", &target_fps) &&
      (target_fps == 24 || target_fps == 30 || target_fps == 60) &&
      ReadFiniteDouble(arguments, "visualScale", &visual_scale) &&
      IsSupportedVisualScale(visual_scale) &&
      ReadRequiredBool(arguments, "alwaysOnTop", &always_on_top) &&
      ReadRequiredBool(arguments, "snapEnabled", &snap_enabled) &&
      ReadFiniteDouble(arguments, "snapAcquireDistance",
                       &snap_acquire_distance) &&
      snap_acquire_distance >= 4.0 && snap_acquire_distance <= 160.0 &&
      ReadFiniteDouble(arguments, "snapReleaseDistance",
                       &snap_release_distance) &&
      snap_release_distance >= snap_acquire_distance &&
      snap_release_distance <= 240.0;
  if (!valid) {
    result->Error(
        "invalid_desktop_companion_presentation",
        "Desktop companion presentation v1 contains invalid values.");
    return;
  }

  const bool capture_changed = presentation_quality_ != *quality ||
                               presentation_target_fps_ != target_fps;
  const bool geometry_changed =
      std::abs(presentation_visual_scale_ - visual_scale) > 0.0001;
  const bool attachment_cleared =
      !snap_enabled &&
      spatial_attachment_kind_ !=
          static_cast<DWORD>(SpatialAttachmentKind::kNone);
  const bool was_visible = visible_;
  presentation_quality_ = *quality;
  presentation_target_fps_ = target_fps;
  presentation_visual_scale_ = visual_scale;
  presentation_always_on_top_ = always_on_top;
  presentation_snap_enabled_ = snap_enabled;
  presentation_snap_acquire_distance_ = snap_acquire_distance;
  presentation_snap_release_distance_ = snap_release_distance;
  if (!presentation_snap_enabled_) {
    ClearSpatialAttachment();
  }

  if (geometry_changed) {
    ApplyPresentationGeometry();
  } else {
    MoveWindows(window_bounds_.left, window_bounds_.top);
  }
  if (pet_unity_player_host_ != nullptr) {
    pet_unity_player_host_->SetDesktopPetPresentationConfig(
        presentation_quality_, presentation_target_fps_);
  }
  if (was_visible && capture_changed) {
    std::wstring error;
    if (!Show(&error, interaction_generation_)) {
      Hide();
      result->Error("windows_desktop_companion_unavailable",
                    WideToUtf8(error));
      return;
    }
  }
  if (geometry_changed || attachment_cleared) {
    SaveBounds();
  }
  result->Success();
}

void WindowsDesktopCompanionHost::ApplyPresentationGeometry() {
  ClearAvatarHitRegion();
  const int width = Scale(300);
  const int height = Scale(420);
  window_bounds_ = RECT{window_bounds_.left, window_bounds_.top,
                        window_bounds_.left + width,
                        window_bounds_.top + height};
  RestoreSpatialPosition();
  if (pet_window_ == nullptr) {
    return;
  }
  if (EnsurePetSurface(width, height)) {
    std::memset(pet_surface_pixels_, 0,
                static_cast<size_t>(width) * height * 4);
    UpdatePetLayeredWindow();
  }
}

bool WindowsDesktopCompanionHost::EnsureWindows(
    std::wstring* error_message) {
  if (pet_window_ != nullptr && overlay_window_ != nullptr &&
      bubble_window_ != nullptr) {
    return true;
  }
  if (!RegisterWindowClass(kPetWindowClass, PetWindowProc) ||
      !RegisterWindowClass(kOverlayWindowClass, OverlayWindowProc) ||
      !RegisterWindowClass(kBubbleWindowClass, BubbleWindowProc)) {
    if (error_message != nullptr) {
      *error_message = L"The desktop-pet window classes could not be registered.";
    }
    return false;
  }

  const int width = window_bounds_.right - window_bounds_.left;
  const int height = window_bounds_.bottom - window_bounds_.top;
  const DWORD extended_style =
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED |
      (presentation_always_on_top_ ? WS_EX_TOPMOST : 0);
  pet_window_ = ::CreateWindowExW(
      extended_style | WS_EX_TRANSPARENT, kPetWindowClass, L"Maaso Desktop Pet",
      WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, window_bounds_.left,
      window_bounds_.top, width, height, nullptr, nullptr,
      ::GetModuleHandleW(nullptr), this);
  if (pet_window_ == nullptr) {
    if (error_message != nullptr) {
      *error_message = L"The Windows desktop-pet surface could not be created.";
    }
    return false;
  }
  overlay_window_ = ::CreateWindowExW(
      extended_style, kOverlayWindowClass, L"Maaso Desktop Pet Controls",
      WS_POPUP, window_bounds_.left, window_bounds_.top, width, height, nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (overlay_window_ == nullptr) {
    ::DestroyWindow(pet_window_);
    pet_window_ = nullptr;
    if (error_message != nullptr) {
      *error_message = L"The desktop-pet interaction overlay could not be created.";
    }
    return false;
  }
  bubble_window_ = ::CreateWindowExW(
      extended_style | WS_EX_TRANSPARENT, kBubbleWindowClass,
      L"Maaso Desktop Pet Bubble",
      WS_POPUP, window_bounds_.left, window_bounds_.top, width, height, nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (bubble_window_ == nullptr) {
    ::DestroyWindow(overlay_window_);
    overlay_window_ = nullptr;
    ::DestroyWindow(pet_window_);
    pet_window_ = nullptr;
    if (error_message != nullptr) {
      *error_message = L"The desktop-pet speech bubble could not be created.";
    }
    return false;
  }
  // Nonzero alpha enables interaction only inside the per-frame window region.
  // The two display windows are independently transparent to mouse input.
  ::SetLayeredWindowAttributes(overlay_window_, 0, 1, LWA_ALPHA);
  ::SetLayeredWindowAttributes(bubble_window_, kTransparencyKey, 255,
                               LWA_COLORKEY);
  ResizeForDpi(::GetDpiForWindow(overlay_window_),
               POINT{window_bounds_.left, window_bounds_.top});
  return true;
}

bool WindowsDesktopCompanionHost::Show(std::wstring* error_message,
                                       int32_t interaction_generation) {
  if (interaction_generation < 1) {
    if (error_message != nullptr) {
      *error_message = L"The desktop-pet interaction generation is invalid.";
    }
    return false;
  }
  if (!EnsureWindows(error_message)) {
    return false;
  }
  ClearAvatarHitRegion();
  // EnsureWindows() is a no-op after the HWNDs exist, so every summon must
  // revalidate its attachment before Unity starts or any native layer appears.
  RestoreSpatialPosition();
  if (pet_unity_player_host_ == nullptr) {
    if (error_message != nullptr) {
      *error_message = L"The Unity desktop avatar host is unavailable.";
    }
    return false;
  }
  const int surface_width = window_bounds_.right - window_bounds_.left;
  const int surface_height = window_bounds_.bottom - window_bounds_.top;
  if (!EnsurePetSurface(surface_width, surface_height)) {
    if (error_message != nullptr) {
      *error_message =
          L"The Windows desktop-pet alpha surface could not be created.";
    }
    return false;
  }
  std::memset(pet_surface_pixels_, 0,
              static_cast<size_t>(surface_width) * surface_height * 4);
  if (!UpdatePetLayeredWindow()) {
    if (error_message != nullptr) {
      *error_message =
          L"The Windows desktop-pet alpha surface could not be presented.";
    }
    return false;
  }
  pet_unity_player_host_->SetDesktopPetPresentation(true);
  pet_unity_player_host_->SetDesktopPetPresentationConfig(
      presentation_quality_, presentation_target_fps_);
  pet_unity_player_host_->SetParentWindow(pet_window_);
  if (!pet_unity_player_host_->Start(AvatarBounds(), error_message)) {
    return false;
  }
  if (pet_started_callback_) {
    bool state_replayed = false;
    try {
      state_replayed = pet_started_callback_(error_message);
    } catch (...) {
      if (error_message != nullptr) {
        *error_message =
            L"The desktop avatar state could not be restored safely.";
      }
    }
    if (!state_replayed) {
      if (error_message != nullptr && error_message->empty()) {
        *error_message = L"The desktop avatar state could not be restored.";
      }
      Hide();
      return false;
    }
  }
  avatar_startup_deadline_ =
      ::GetTickCount64() + kAvatarStartupTimeoutMilliseconds;

  MoveWindows(window_bounds_.left, window_bounds_.top);
  const HWND z_order =
      presentation_always_on_top_ ? HWND_TOPMOST : HWND_NOTOPMOST;
  ::SetWindowPos(pet_window_, z_order, window_bounds_.left,
                 window_bounds_.top, window_bounds_.right - window_bounds_.left,
                 window_bounds_.bottom - window_bounds_.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  ::SetWindowPos(overlay_window_, z_order, window_bounds_.left,
                 window_bounds_.top, window_bounds_.right - window_bounds_.left,
                 window_bounds_.bottom - window_bounds_.top,
                 SWP_NOACTIVATE);
  ::SetWindowPos(bubble_window_, z_order, window_bounds_.left,
                 window_bounds_.top, window_bounds_.right - window_bounds_.left,
                 window_bounds_.bottom - window_bounds_.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  ::SetTimer(overlay_window_, kGazeTimerId, 42, nullptr);
  interaction_generation_ = interaction_generation;
  visible_ = true;
  UpdateGaze();
  return true;
}

void WindowsDesktopCompanionHost::Hide() {
  FailPendingShow(
      "windows_desktop_companion_show_cancelled",
      "The desktop companion was hidden before its first frame.");
  avatar_startup_deadline_ = 0;
  CancelDrag();
  ClearAvatarHitRegion();
  if (bubble_window_ != nullptr) {
    ::ShowWindow(bubble_window_, SW_HIDE);
  }
  if (overlay_window_ != nullptr) {
    ::KillTimer(overlay_window_, kGazeTimerId);
    ::ShowWindow(overlay_window_, SW_HIDE);
  }
  if (pet_window_ != nullptr) {
    ::ShowWindow(pet_window_, SW_HIDE);
  }
  if (pet_unity_player_host_ != nullptr) {
    pet_unity_player_host_->Stop();
    pet_unity_player_host_->DiscardPendingAvatarCommands();
  }
  visible_ = false;
  bubble_text_.clear();
  ClearGaze();
}

void WindowsDesktopCompanionHost::ConfigureMenu(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* value = FindValue(arguments, "items");
  const auto* items =
      value == nullptr ? nullptr : std::get_if<flutter::EncodableList>(value);
  if (items == nullptr || items->size() > kMaximumMenuItems) {
    result->Error("invalid_desktop_companion_menu",
                  "Desktop companion menu entries are invalid.");
    return;
  }

  std::vector<MenuEntry> next_entries;
  std::set<std::string> seen_ids;
  next_entries.reserve(items->size());
  for (const auto& raw_item : *items) {
    const auto* item = std::get_if<flutter::EncodableMap>(&raw_item);
    const std::string* id = item == nullptr ? nullptr : ReadString(*item, "id");
    const std::string* label =
        item == nullptr ? nullptr : ReadString(*item, "label");
    if (id == nullptr || label == nullptr || id->empty() || label->empty() ||
        id->size() > kMaximumMenuIdBytes ||
        label->size() > kMaximumMenuLabelBytes || !seen_ids.insert(*id).second) {
      result->Error("invalid_desktop_companion_menu",
                    "Desktop companion menu entries are invalid.");
      return;
    }
    const std::wstring wide_label = Trimmed(Utf8ToWide(*label));
    if (wide_label.empty()) {
      result->Error("invalid_desktop_companion_menu",
                    "Desktop companion menu labels must be valid UTF-8.");
      return;
    }
    next_entries.push_back(
        MenuEntry{*id, wide_label, ReadBool(*item, "enabled", true)});
  }

  auto label_or = [&arguments](const char* key,
                               const wchar_t* fallback) -> std::wstring {
    const std::string* raw = ReadString(arguments, key);
    if (raw == nullptr || raw->empty() ||
        raw->size() > kMaximumMenuLabelBytes) {
      return fallback;
    }
    const std::wstring value = Trimmed(Utf8ToWide(*raw));
    return value.empty() ? std::wstring(fallback) : value;
  };
  menu_entries_ = std::move(next_entries);
  open_app_label_ = label_or("openAppLabel", L"Open Maaso");
  hide_pet_label_ = label_or("hidePetLabel", L"Hide Desktop Pet");
  quit_label_ = label_or("quitLabel", L"Quit Maaso");
  result->Success();
}

void WindowsDesktopCompanionHost::PresentContextMenu(POINT screen_point) {
  if (overlay_window_ == nullptr) {
    return;
  }
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  for (size_t index = 0; index < menu_entries_.size(); ++index) {
    const MenuEntry& entry = menu_entries_[index];
    const UINT flags = MF_STRING | (entry.enabled ? MF_ENABLED : MF_GRAYED);
    ::AppendMenuW(menu, flags, kFirstMenuCommand + static_cast<UINT>(index),
                  entry.label.c_str());
  }
  if (!menu_entries_.empty()) {
    ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  }
  ::AppendMenuW(menu, MF_STRING, kOpenAppCommand, open_app_label_.c_str());
  ::AppendMenuW(menu, MF_STRING, kHidePetCommand, hide_pet_label_.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kQuitCommand, quit_label_.c_str());

  // TrackPopupMenuEx owns mouse capture. Clicking outside the character or
  // moving focus to another application therefore dismisses the menu without
  // leaving a Flutter overlay behind.
  ::SetForegroundWindow(overlay_window_);
  const UINT selected = static_cast<UINT>(::TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, screen_point.x,
      screen_point.y, overlay_window_, nullptr));
  ::DestroyMenu(menu);
  ::PostMessageW(overlay_window_, WM_NULL, 0, 0);

  const UINT menu_entry_count = static_cast<UINT>(menu_entries_.size());
  if (selected >= kFirstMenuCommand &&
      selected < kFirstMenuCommand + menu_entry_count) {
    InvokeMenuSelection(menu_entries_[selected - kFirstMenuCommand].id);
  } else if (selected == kOpenAppCommand) {
    InvokeCommand("openApp");
  } else if (selected == kHidePetCommand) {
    InvokeCommand("hidePet");
  } else if (selected == kQuitCommand) {
    InvokeCommand("quit");
  }
}

void WindowsDesktopCompanionHost::InvokeMenuSelection(const std::string& id) {
  if (!channel_) {
    return;
  }
  channel_->InvokeMethod(
      "menuSelected",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("id"), flutter::EncodableValue(id)},
      }));
}

void WindowsDesktopCompanionHost::InvokeCommand(const char* id) {
  if (!channel_) {
    return;
  }
  channel_->InvokeMethod(
      "command",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("id"),
           flutter::EncodableValue(std::string(id))},
      }));
}

void WindowsDesktopCompanionHost::InvokeAvatarInteraction(
    POINT client_point,
    int32_t generation) {
  if (!channel_ || !visible_ || generation <= 0 ||
      generation != interaction_generation_ || !IsAvatarPoint(client_point)) {
    return;
  }
  const RECT avatar = AvatarBounds();
  const double width = static_cast<double>(avatar.right - avatar.left);
  const double height = static_cast<double>(avatar.bottom - avatar.top);
  if (width <= 0.0 || height <= 0.0) {
    return;
  }
  const double normalized_x = std::clamp(
      (static_cast<double>(client_point.x) - avatar.left) / width, 0.0, 1.0);
  // Windows client coordinates already run from top to bottom, matching the
  // cross-platform interaction contract without a vertical-axis inversion.
  const double normalized_y = std::clamp(
      (static_cast<double>(client_point.y) - avatar.top) / height, 0.0, 1.0);
  const std::string region = AvatarRegionForPoint(client_point);
  channel_->InvokeMethod(
      "avatarInteraction",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("version"), flutter::EncodableValue(1)},
          {flutter::EncodableValue("type"),
           flutter::EncodableValue(std::string("tap"))},
          {flutter::EncodableValue("normalizedX"),
           flutter::EncodableValue(normalized_x)},
          {flutter::EncodableValue("normalizedY"),
           flutter::EncodableValue(normalized_y)},
          {flutter::EncodableValue("region"),
           flutter::EncodableValue(region)},
          {flutter::EncodableValue("generation"),
           flutter::EncodableValue(generation)},
          {flutter::EncodableValue("timestampMs"),
           flutter::EncodableValue(BoundedTimestampMilliseconds())},
      }));
}

std::string WindowsDesktopCompanionHost::AvatarRegionForPoint(
    POINT client_point) const {
  const RECT avatar = AvatarBounds();
  const bool inside_actual_avatar =
      client_point.x >= avatar.left && client_point.x <= avatar.right &&
      client_point.y >= avatar.top && client_point.y <= avatar.bottom;
  if (!inside_actual_avatar) {
    // The interaction hit target has a small accessibility inset. Preserve a
    // bounded semantic value instead of classifying inset-only pixels as a
    // body part.
    return "avatar";
  }
  const double width = static_cast<double>(avatar.right - avatar.left);
  const double height = static_cast<double>(avatar.bottom - avatar.top);
  if (width <= 0.0 || height <= 0.0) {
    return "avatar";
  }
  const double normalized_x =
      (static_cast<double>(client_point.x) - avatar.left) / width;
  const double normalized_y =
      (static_cast<double>(client_point.y) - avatar.top) / height;
  if (normalized_y <= 0.28) {
    return "head";
  }
  if (normalized_y >= 0.82) {
    return "feet";
  }
  if (normalized_x <= 0.32) {
    return "leftSide";
  }
  if (normalized_x >= 0.68) {
    return "rightSide";
  }
  return "torso";
}

void WindowsDesktopCompanionHost::UpdateGaze() {
  if (!visible_ || overlay_window_ == nullptr) {
    return;
  }
  POINT cursor{};
  RECT frame{};
  if (!::GetCursorPos(&cursor) || !::GetWindowRect(overlay_window_, &frame)) {
    return;
  }
  const double head_x = frame.left + (frame.right - frame.left) / 2.0;
  const double head_y = frame.top + Scale(202);
  const double tracked_x = ClampUnit((cursor.x - head_x) / Scale(220));
  const double tracked_y = ClampUnit((head_y - cursor.y) / Scale(170));
  const RECT avatar = AvatarBounds();
  const double avatar_left = frame.left + avatar.left;
  const double avatar_top = frame.top + avatar.top;
  const double avatar_right = frame.left + avatar.right;
  const double avatar_bottom = frame.top + avatar.bottom;
  const double outside_x =
      cursor.x < avatar_left
          ? avatar_left - cursor.x
          : cursor.x > avatar_right ? cursor.x - avatar_right : 0.0;
  const double outside_y =
      cursor.y < avatar_top
          ? avatar_top - cursor.y
          : cursor.y > avatar_bottom ? cursor.y - avatar_bottom : 0.0;
  const double outside_distance = std::hypot(outside_x, outside_y);
  const double full_attention_distance = Scale(72);
  const double release_distance = Scale(180);
  const double attention_weight = std::clamp(
      (release_distance - outside_distance) /
          (release_distance - full_attention_distance),
      0.0, 1.0);
  const double next_x = tracked_x * attention_weight;
  const double next_y = tracked_y * attention_weight;
  const bool next_is_centered = next_x == 0.0 && next_y == 0.0;
  const bool last_is_centered = last_gaze_x_ == 0.0 && last_gaze_y_ == 0.0;
  if (has_last_gaze_ && next_is_centered == last_is_centered &&
      std::abs(next_x - last_gaze_x_) < 0.012 &&
      std::abs(next_y - last_gaze_y_) < 0.012) {
    return;
  }
  has_last_gaze_ = true;
  last_gaze_x_ = next_x;
  last_gaze_y_ = next_y;
  if (pet_unity_player_host_ != nullptr) {
    pet_unity_player_host_->SetPointerGaze(next_x, next_y);
  }
  if (channel_) {
    channel_->InvokeMethod(
        "gazeChanged",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("active"), flutter::EncodableValue(true)},
            {flutter::EncodableValue("x"), flutter::EncodableValue(next_x)},
            {flutter::EncodableValue("y"), flutter::EncodableValue(next_y)},
        }));
  }
}

void WindowsDesktopCompanionHost::ClearGaze() {
  if (pet_unity_player_host_ != nullptr) {
    pet_unity_player_host_->SetPointerGaze(0.0, 0.0);
  }
  if (has_last_gaze_ && channel_) {
    channel_->InvokeMethod(
        "gazeChanged",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("active"), flutter::EncodableValue(false)},
        }));
  }
  has_last_gaze_ = false;
}

bool WindowsDesktopCompanionHost::EnsurePetSurface(int width, int height) {
  if (width <= 0 || height <= 0) {
    return false;
  }
  if (pet_surface_dc_ != nullptr && pet_surface_bitmap_ != nullptr &&
      pet_surface_pixels_ != nullptr && pet_surface_width_ == width &&
      pet_surface_height_ == height) {
    return true;
  }

  const uint64_t surface_bytes =
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4;
  if (surface_bytes > MAXDWORD) {
    return false;
  }

  ReleasePetSurface();
  HDC surface_dc = ::CreateCompatibleDC(nullptr);
  if (surface_dc == nullptr) {
    return false;
  }

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;
  bitmap_info.bmiHeader.biSizeImage = static_cast<DWORD>(surface_bytes);
  void* surface_pixels = nullptr;
  HBITMAP surface_bitmap = ::CreateDIBSection(
      surface_dc, &bitmap_info, DIB_RGB_COLORS, &surface_pixels, nullptr, 0);
  if (surface_bitmap == nullptr || surface_pixels == nullptr) {
    if (surface_bitmap != nullptr) {
      ::DeleteObject(surface_bitmap);
    }
    ::DeleteDC(surface_dc);
    return false;
  }

  HGDIOBJ previous_bitmap = ::SelectObject(surface_dc, surface_bitmap);
  if (previous_bitmap == nullptr || previous_bitmap == HGDI_ERROR) {
    ::DeleteObject(surface_bitmap);
    ::DeleteDC(surface_dc);
    return false;
  }

  pet_surface_dc_ = surface_dc;
  pet_surface_bitmap_ = surface_bitmap;
  pet_surface_previous_bitmap_ = previous_bitmap;
  pet_surface_pixels_ = static_cast<unsigned char*>(surface_pixels);
  pet_surface_width_ = width;
  pet_surface_height_ = height;
  std::memset(pet_surface_pixels_, 0, static_cast<size_t>(surface_bytes));
  return true;
}

void WindowsDesktopCompanionHost::ReleasePetSurface() {
  ClearAvatarHitRegion();
  if (pet_surface_dc_ != nullptr &&
      pet_surface_previous_bitmap_ != nullptr) {
    ::SelectObject(pet_surface_dc_, pet_surface_previous_bitmap_);
  }
  if (pet_surface_bitmap_ != nullptr) {
    ::DeleteObject(pet_surface_bitmap_);
  }
  if (pet_surface_dc_ != nullptr) {
    ::DeleteDC(pet_surface_dc_);
  }
  pet_surface_dc_ = nullptr;
  pet_surface_bitmap_ = nullptr;
  pet_surface_previous_bitmap_ = nullptr;
  pet_surface_pixels_ = nullptr;
  pet_surface_width_ = 0;
  pet_surface_height_ = 0;
}

bool WindowsDesktopCompanionHost::UpdatePetLayeredWindow() {
  if (pet_window_ == nullptr || pet_surface_dc_ == nullptr ||
      pet_surface_width_ <= 0 || pet_surface_height_ <= 0) {
    return false;
  }

  const POINT destination{window_bounds_.left, window_bounds_.top};
  const POINT source{0, 0};
  const SIZE size{pet_surface_width_, pet_surface_height_};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UPDATELAYEREDWINDOWINFO update{};
  update.cbSize = sizeof(update);
  update.pptDst = &destination;
  update.psize = &size;
  update.hdcSrc = pet_surface_dc_;
  update.pptSrc = &source;
  update.pblend = &blend;
  update.dwFlags = ULW_ALPHA;
  return ::UpdateLayeredWindowIndirect(pet_window_, &update) != FALSE;
}

void WindowsDesktopCompanionHost::PresentLatestDesktopPetFrame() {
  if (!visible_ ||
      pet_unity_player_host_ == nullptr || pet_window_ == nullptr) {
    return;
  }

  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
  uint32_t frame_stride = 0;
  uint32_t frame_flags = 0;
  if (!pet_unity_player_host_->CopyLatestDesktopPetFrame(
          &frame_width, &frame_height, &frame_stride, &frame_flags,
          &pet_frame_pixels_)) {
    return;
  }

  if (!EnsurePetSurface(window_bounds_.right - window_bounds_.left,
                        window_bounds_.bottom - window_bounds_.top)) {
    ClearAvatarHitRegion();
    return;
  }

  const RECT avatar_bounds = AvatarBounds();
  const int avatar_width = avatar_bounds.right - avatar_bounds.left;
  const int avatar_height = avatar_bounds.bottom - avatar_bounds.top;
  if (avatar_width <= 0 || avatar_height <= 0 ||
      frame_width != static_cast<uint32_t>(avatar_width) ||
      frame_height != static_cast<uint32_t>(avatar_height) ||
      avatar_bounds.left < 0 || avatar_bounds.top < 0 ||
      avatar_bounds.right > pet_surface_width_ ||
      avatar_bounds.bottom > pet_surface_height_) {
    ClearAvatarHitRegion();
    return;
  }
  const uint64_t required_bytes =
      static_cast<uint64_t>(frame_stride) * frame_height;
  if (required_bytes > pet_frame_pixels_.size()) {
    ClearAvatarHitRegion();
    return;
  }

  const size_t surface_bytes = static_cast<size_t>(pet_surface_width_) *
                               pet_surface_height_ * 4;
  const size_t row_bytes = static_cast<size_t>(frame_width) * 4;
  std::memset(pet_surface_pixels_, 0, surface_bytes);
  for (uint32_t row = 0; row < frame_height; ++row) {
    const uint32_t source_row =
        (frame_flags & kDesktopPetFrameTopDown) != 0
            ? row
            : frame_height - row - 1;
    const auto* source_pixels =
        pet_frame_pixels_.data() +
        static_cast<size_t>(source_row) * frame_stride;
    auto* destination_pixels =
        pet_surface_pixels_ +
        (static_cast<size_t>(avatar_bounds.top + static_cast<int>(row)) *
             pet_surface_width_ +
         avatar_bounds.left) *
            4;
    std::memcpy(destination_pixels, source_pixels, row_bytes);
  }
  if (UpdatePetLayeredWindow()) {
    UpdateAvatarHitRegion();
    avatar_startup_deadline_ = 0;
    CompletePendingShow();
  } else {
    ClearAvatarHitRegion();
  }
}

void WindowsDesktopCompanionHost::ClearAvatarHitRegion() {
  avatar_hit_mask_.Clear();
  if (overlay_window_ == nullptr) return;
  HRGN empty = ::CreateRectRgn(0, 0, 0, 0);
  if (empty != nullptr && ::SetWindowRgn(overlay_window_, empty, FALSE) == 0) {
    ::DeleteObject(empty);
  }
  // Hiding also fails open if GDI cannot allocate/apply an empty region.
  // Captured gestures finish via the existing up/cancel path.
  if (!pointer_down_active_) ::ShowWindow(overlay_window_, SW_HIDE);
}

void WindowsDesktopCompanionHost::UpdateAvatarHitRegion() {
  if (overlay_window_ == nullptr) return;
  DesktopAvatarAlphaMask next;
  const size_t stride = static_cast<size_t>(pet_surface_width_) * 4;
  const size_t bytes = stride * static_cast<size_t>(pet_surface_height_);
  if (!next.Build(pet_surface_pixels_, bytes, pet_surface_width_,
                  pet_surface_height_, stride)) {
    ClearAvatarHitRegion();
    return;
  }
  if (next.Empty()) {
    if (!avatar_hit_mask_.Empty()) ClearAvatarHitRegion();
    return;
  }
  if (next.SameShape(avatar_hit_mask_)) return;

  HRGN region = nullptr;
  try {
    const auto& rectangles = next.rectangles();
    const size_t data_bytes =
        sizeof(RGNDATAHEADER) + rectangles.size() * sizeof(RECT);
    std::vector<unsigned char> storage(data_bytes);
    auto* data = reinterpret_cast<RGNDATA*>(storage.data());
    data->rdh.dwSize = sizeof(RGNDATAHEADER);
    data->rdh.iType = RDH_RECTANGLES;
    data->rdh.nCount = static_cast<DWORD>(rectangles.size());
    data->rdh.nRgnSize = static_cast<DWORD>(rectangles.size() * sizeof(RECT));
    RECT bounds{pet_surface_width_, pet_surface_height_, 0, 0};
    auto* native_rectangles = reinterpret_cast<RECT*>(data->Buffer);
    for (size_t index = 0; index < rectangles.size(); ++index) {
      const auto& rect = rectangles[index];
      native_rectangles[index] = RECT{rect.left, rect.top, rect.right, rect.bottom};
      bounds.left = std::min(bounds.left, static_cast<LONG>(rect.left));
      bounds.top = std::min(bounds.top, static_cast<LONG>(rect.top));
      bounds.right = std::max(bounds.right, static_cast<LONG>(rect.right));
      bounds.bottom = std::max(bounds.bottom, static_cast<LONG>(rect.bottom));
    }
    data->rdh.rcBound = bounds;
    region = ::ExtCreateRegion(nullptr, static_cast<DWORD>(data_bytes), data);
  } catch (...) {
    ClearAvatarHitRegion();
    return;
  }
  if (region == nullptr || ::SetWindowRgn(overlay_window_, region, TRUE) == 0) {
    if (region != nullptr) ::DeleteObject(region);
    ClearAvatarHitRegion();
    return;
  }
  // SetWindowRgn owns a successful HRGN; do not delete or reuse it.
  avatar_hit_mask_ = std::move(next);
  if (visible_ && !::IsWindowVisible(overlay_window_)) {
    ::ShowWindow(overlay_window_, SW_SHOWNOACTIVATE);
  }
}

void WindowsDesktopCompanionHost::CompletePendingShow() {
  if (pending_show_result_ == nullptr) {
    return;
  }
  auto result = std::move(pending_show_result_);
  result->Success();
}

void WindowsDesktopCompanionHost::FailPendingShow(
    const char* code,
    const std::string& message) {
  if (pending_show_result_ == nullptr) {
    return;
  }
  auto result = std::move(pending_show_result_);
  result->Error(code, message);
}

void WindowsDesktopCompanionHost::DrawInteractionOverlay(HWND window) {
  PAINTSTRUCT paint{};
  HDC context = ::BeginPaint(window, &paint);
  RECT client{};
  ::GetClientRect(window, &client);
  ::FillRect(context, &client,
             static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH)));
  ::EndPaint(window, &paint);
}

void WindowsDesktopCompanionHost::DrawOverlay(HWND window) {
  PAINTSTRUCT paint{};
  HDC context = ::BeginPaint(window, &paint);
  RECT client{};
  ::GetClientRect(window, &client);
  ::FillRect(context, &client,
             static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH)));
  if (!bubble_text_.empty()) {
    const RECT body{Scale(14), Scale(8), client.right - Scale(14), Scale(118)};
    HBRUSH fill = ::CreateSolidBrush(RGB(250, 250, 250));
    HPEN border = ::CreatePen(PS_SOLID, 1, RGB(194, 194, 194));
    HGDIOBJ old_brush = ::SelectObject(context, fill);
    HGDIOBJ old_pen = ::SelectObject(context, border);
    ::RoundRect(context, body.left, body.top, body.right, body.bottom,
                Scale(30), Scale(30));
    POINT tail[3] = {
        {client.right / 2 - Scale(9), body.bottom - 1},
        {client.right / 2, Scale(130)},
        {client.right / 2 + Scale(9), body.bottom - 1},
    };
    ::Polygon(context, tail, 3);

    ::SetBkMode(context, TRANSPARENT);
    ::SetTextColor(context, RGB(26, 26, 26));
    HFONT font = ::CreateFontW(
        -Scale(13), 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    HGDIOBJ old_font = ::SelectObject(context, font);
    RECT text_bounds{body.left + Scale(14), body.top + Scale(10),
                     body.right - Scale(14), body.bottom - Scale(10)};
    ::DrawTextW(context, bubble_text_.c_str(),
                static_cast<int>(bubble_text_.size()), &text_bounds,
                DT_CENTER | DT_VCENTER | DT_WORDBREAK | DT_END_ELLIPSIS |
                    DT_NOPREFIX);
    ::SelectObject(context, old_font);
    ::DeleteObject(font);
    ::SelectObject(context, old_pen);
    ::SelectObject(context, old_brush);
    ::DeleteObject(border);
    ::DeleteObject(fill);
  }
  ::EndPaint(window, &paint);
}

void WindowsDesktopCompanionHost::BeginDrag(POINT screen_point,
                                             POINT client_point) {
  if (overlay_window_ == nullptr || !visible_) {
    return;
  }
  CancelDrag();
  pointer_down_active_ = true;
  dragging_ = false;
  drag_cursor_start_ = screen_point;
  drag_window_start_ = POINT{window_bounds_.left, window_bounds_.top};
  pointer_down_client_ = client_point;
  pointer_down_timestamp_ms_ = ::GetTickCount64();
  pointer_down_generation_ = interaction_generation_;
  ::SetCapture(overlay_window_);
  if (::GetCapture() != overlay_window_) {
    pointer_down_active_ = false;
    pointer_down_timestamp_ms_ = 0;
    pointer_down_generation_ = 0;
  }
}

void WindowsDesktopCompanionHost::ContinueDrag(POINT screen_point) {
  if (!pointer_down_active_) {
    return;
  }
  if (!dragging_) {
    if (!MovedBeyondDragThreshold(screen_point)) {
      return;
    }
    dragging_ = true;
  }
  POINT proposed{
      drag_window_start_.x + screen_point.x - drag_cursor_start_.x,
      drag_window_start_.y + screen_point.y - drag_cursor_start_.y,
  };
  proposed = ClampOrigin(proposed);
  MoveWindows(proposed.x, proposed.y);
}

void WindowsDesktopCompanionHost::EndDrag(POINT screen_point) {
  if (!pointer_down_active_) {
    return;
  }
  const bool was_dragging = dragging_;
  const ULONGLONG elapsed =
      ::GetTickCount64() - pointer_down_timestamp_ms_;
  POINT client_point = screen_point;
  if (overlay_window_ == nullptr ||
      !::ScreenToClient(overlay_window_, &client_point)) {
    client_point = pointer_down_client_;
  }
  const int32_t generation = pointer_down_generation_;
  const bool should_invoke_tap =
      !was_dragging && !MovedBeyondDragThreshold(screen_point) &&
      elapsed <= kMaximumTapDurationMilliseconds && visible_ &&
      generation == interaction_generation_ && IsAvatarPoint(client_point);

  pointer_down_active_ = false;
  dragging_ = false;
  pointer_down_timestamp_ms_ = 0;
  pointer_down_generation_ = 0;
  if (::GetCapture() == overlay_window_) {
    ::ReleaseCapture();
  }
  if (avatar_hit_mask_.Empty() && overlay_window_ != nullptr) {
    ::ShowWindow(overlay_window_, SW_HIDE);
  }
  if (was_dragging) {
    ApplyDropSnap();
    SaveBounds();
  }
  if (should_invoke_tap) {
    InvokeAvatarInteraction(client_point, generation);
  }
}

void WindowsDesktopCompanionHost::CancelDrag() {
  if (!pointer_down_active_ && !dragging_) {
    return;
  }
  const bool was_dragging = dragging_;
  pointer_down_active_ = false;
  dragging_ = false;
  pointer_down_timestamp_ms_ = 0;
  pointer_down_generation_ = 0;
  if (::GetCapture() == overlay_window_) {
    ::ReleaseCapture();
  }
  if (avatar_hit_mask_.Empty() && overlay_window_ != nullptr) {
    ::ShowWindow(overlay_window_, SW_HIDE);
  }
  if (was_dragging) {
    ClearSpatialAttachment();
    SaveBounds();
  }
}

bool WindowsDesktopCompanionHost::MovedBeyondDragThreshold(
    POINT screen_point) const {
  const double delta_x =
      static_cast<double>(screen_point.x) - drag_cursor_start_.x;
  const double delta_y =
      static_cast<double>(screen_point.y) - drag_cursor_start_.y;
  return std::hypot(delta_x, delta_y) > Scale(kTapMoveLogicalPixels);
}

bool WindowsDesktopCompanionHost::ApplyDropSnap() {
  if (!presentation_snap_enabled_) {
    ClearSpatialAttachment();
    return false;
  }
  MonitorSnapshot monitor;
  if (!MonitorForRect(window_bounds_, &monitor)) {
    ClearSpatialAttachment();
    return false;
  }
  const int width = window_bounds_.right - window_bounds_.left;
  const int height = window_bounds_.bottom - window_bounds_.top;
  const RECT avatar = AvatarBounds();
  const int left_inset = avatar.left;
  const int right_inset = width - avatar.right;
  const POINT current{window_bounds_.left, window_bounds_.top};
  const RECT& work = monitor.info.rcWork;
  std::vector<SnapCandidate> candidates;
  candidates.reserve(12);
  auto add_work_candidate = [&](SpatialAttachmentKind kind, POINT origin) {
    origin = ClampOriginToWorkArea(origin, work, width, height, left_inset,
                                   right_inset);
    candidates.push_back(SnapCandidate{
        kind,
        monitor.info.szDevice,
        nullptr,
        0,
        origin,
        OriginDistance(current, origin),
    });
  };
  if (HasReservedWorkEdge(SpatialAttachmentKind::kWorkLeft, monitor.info)) {
    add_work_candidate(SpatialAttachmentKind::kWorkLeft,
                       POINT{work.left - left_inset, current.y});
  }
  if (HasReservedWorkEdge(SpatialAttachmentKind::kWorkTop, monitor.info)) {
    add_work_candidate(SpatialAttachmentKind::kWorkTop,
                       POINT{current.x, work.top});
  }
  if (HasReservedWorkEdge(SpatialAttachmentKind::kWorkRight, monitor.info)) {
    add_work_candidate(SpatialAttachmentKind::kWorkRight,
                       POINT{work.right - width + right_inset, current.y});
  }
  if (HasReservedWorkEdge(SpatialAttachmentKind::kWorkBottom, monitor.info)) {
    add_work_candidate(SpatialAttachmentKind::kWorkBottom,
                       POINT{current.x, work.bottom - height});
  }

  SnapWindowEnumerationContext enumeration{
      monitor.handle,
      work,
      current,
      width,
      height,
      std::max(width, DpiScaledLogicalPixels(
                          kMinimumSnapTargetLogicalWidth, dpi_)),
      DpiScaledLogicalPixels(kMinimumSnapTargetLogicalHeight, dpi_),
      ::GetCurrentProcessId(),
      &candidates,
  };
  ::EnumWindows(CollectSnapWindowCallback,
                reinterpret_cast<LPARAM>(&enumeration));

  const double release_distance = static_cast<double>(
      DpiScaledLogicalPixels(presentation_snap_release_distance_, dpi_));
  const double acquire_distance = static_cast<double>(
      DpiScaledLogicalPixels(presentation_snap_acquire_distance_, dpi_));
  const SnapCandidate* selected = nullptr;
  for (const auto& candidate : candidates) {
    if (SameAttachment(candidate, spatial_attachment_kind_,
                       spatial_attachment_monitor_device_,
                       spatial_attachment_window_,
                       spatial_attachment_window_process_id_) &&
        candidate.distance <= release_distance) {
      selected = &candidate;
      break;
    }
  }
  if (selected == nullptr) {
    const auto nearest =
        std::min_element(candidates.begin(), candidates.end(),
                         [](const SnapCandidate& first,
                            const SnapCandidate& second) {
                           return first.distance < second.distance;
                         });
    if (nearest != candidates.end() &&
        nearest->distance <= acquire_distance) {
      selected = &*nearest;
    }
  }
  if (selected == nullptr) {
    ClearSpatialAttachment();
    return false;
  }
  spatial_attachment_kind_ = static_cast<DWORD>(selected->kind);
  spatial_attachment_monitor_device_ = selected->monitor_device;
  spatial_attachment_window_ = selected->window;
  spatial_attachment_window_process_id_ = selected->window_process_id;
  MoveWindows(selected->origin.x, selected->origin.y);
  return true;
}

bool WindowsDesktopCompanionHost::ResolveSpatialAttachment(
    POINT* origin) const {
  if (origin == nullptr ||
      spatial_attachment_kind_ ==
          static_cast<DWORD>(SpatialAttachmentKind::kNone)) {
    return false;
  }
  const int width = window_bounds_.right - window_bounds_.left;
  const int height = window_bounds_.bottom - window_bounds_.top;
  const RECT avatar = AvatarBounds();
  const int left_inset = avatar.left;
  const int right_inset = width - avatar.right;
  const auto kind =
      static_cast<SpatialAttachmentKind>(spatial_attachment_kind_);
  if (kind == SpatialAttachmentKind::kWorkLeft ||
      kind == SpatialAttachmentKind::kWorkTop ||
      kind == SpatialAttachmentKind::kWorkRight ||
      kind == SpatialAttachmentKind::kWorkBottom) {
    MonitorSnapshot monitor;
    if (!FindMonitorByDevice(spatial_attachment_monitor_device_, &monitor)) {
      return false;
    }
    if (!HasReservedWorkEdge(kind, monitor.info)) {
      return false;
    }
    POINT resolved = OriginFromNormalized(
        monitor.info.rcWork, width, height, spatial_normalized_x_,
        spatial_normalized_y_, left_inset, right_inset);
    switch (kind) {
      case SpatialAttachmentKind::kWorkLeft:
        resolved.x = monitor.info.rcWork.left - left_inset;
        break;
      case SpatialAttachmentKind::kWorkTop:
        resolved.y = monitor.info.rcWork.top;
        break;
      case SpatialAttachmentKind::kWorkRight:
        resolved.x = monitor.info.rcWork.right - width + right_inset;
        break;
      case SpatialAttachmentKind::kWorkBottom:
        resolved.y = monitor.info.rcWork.bottom - height;
        break;
      case SpatialAttachmentKind::kNone:
      case SpatialAttachmentKind::kWindowTop:
        return false;
    }
    *origin = ClampOriginToWorkArea(resolved, monitor.info.rcWork, width,
                                    height, left_inset, right_inset);
    return true;
  }
  if (kind != SpatialAttachmentKind::kWindowTop ||
      spatial_attachment_window_ == nullptr ||
      spatial_attachment_window_process_id_ == 0) {
    return false;
  }
  RECT target{};
  DWORD target_process_id = 0;
  if (!IsEligibleSnapWindow(
          spatial_attachment_window_, ::GetCurrentProcessId(),
          std::max(width, DpiScaledLogicalPixels(
                              kMinimumSnapTargetLogicalWidth, dpi_)),
          DpiScaledLogicalPixels(kMinimumSnapTargetLogicalHeight, dpi_),
          &target, &target_process_id) ||
      target_process_id != spatial_attachment_window_process_id_) {
    return false;
  }
  MonitorSnapshot monitor;
  if (!MonitorForRect(target, &monitor)) {
    return false;
  }
  const POINT normalized = OriginFromNormalized(
      monitor.info.rcWork, width, height, spatial_normalized_x_,
      spatial_normalized_y_, left_inset, right_inset);
  const int minimum_left = std::max(target.left, monitor.info.rcWork.left);
  const int maximum_left =
      std::min(target.right - width, monitor.info.rcWork.right - width);
  const int top = target.top - height;
  if (minimum_left > maximum_left || top < monitor.info.rcWork.top ||
      top > monitor.info.rcWork.bottom - height) {
    return false;
  }
  *origin = POINT{std::clamp(normalized.x, minimum_left, maximum_left), top};
  return true;
}

void WindowsDesktopCompanionHost::ClearSpatialAttachment() {
  spatial_attachment_kind_ =
      static_cast<DWORD>(SpatialAttachmentKind::kNone);
  spatial_attachment_monitor_device_.clear();
  spatial_attachment_window_ = nullptr;
  spatial_attachment_window_process_id_ = 0;
}

void WindowsDesktopCompanionHost::RestoreSpatialPosition() {
  const int width = window_bounds_.right - window_bounds_.left;
  const int height = window_bounds_.bottom - window_bounds_.top;
  const RECT avatar = AvatarBounds();
  const int left_inset = avatar.left;
  const int right_inset = width - avatar.right;
  MonitorSnapshot monitor;
  if (!FindMonitorByDevice(spatial_monitor_device_, &monitor) &&
      !FindPrimaryMonitor(&monitor)) {
    return;
  }
  POINT origin = OriginFromNormalized(
      monitor.info.rcWork, width, height, spatial_normalized_x_,
      spatial_normalized_y_, left_inset, right_inset);
  if (spatial_attachment_kind_ !=
      static_cast<DWORD>(SpatialAttachmentKind::kNone)) {
    POINT attached{};
    if (ResolveSpatialAttachment(&attached)) {
      origin = attached;
    } else {
      ClearSpatialAttachment();
    }
  }
  window_bounds_ = RECT{origin.x, origin.y, origin.x + width,
                        origin.y + height};
  const POINT clamped = ClampOrigin(origin);
  MoveWindows(clamped.x, clamped.y);
}

void WindowsDesktopCompanionHost::UpdateSpatialFallbackFromBounds() {
  MonitorSnapshot monitor;
  if (!MonitorForRect(window_bounds_, &monitor)) {
    return;
  }
  const int width = window_bounds_.right - window_bounds_.left;
  const int height = window_bounds_.bottom - window_bounds_.top;
  const RECT avatar = AvatarBounds();
  spatial_monitor_device_ = monitor.info.szDevice;
  spatial_normalized_x_ =
      NormalizedAxis(window_bounds_.left, monitor.info.rcWork.left,
                     monitor.info.rcWork.right, width, avatar.left,
                     width - avatar.right);
  spatial_normalized_y_ =
      NormalizedAxis(window_bounds_.top, monitor.info.rcWork.top,
                     monitor.info.rcWork.bottom, height);
}

void WindowsDesktopCompanionHost::MoveWindows(int left, int top) {
  const int width = window_bounds_.right - window_bounds_.left;
  const int height = window_bounds_.bottom - window_bounds_.top;
  const HWND z_order =
      presentation_always_on_top_ ? HWND_TOPMOST : HWND_NOTOPMOST;
  window_bounds_ = RECT{left, top, left + width, top + height};
  UpdateSpatialFallbackFromBounds();
  if (pet_window_ != nullptr) {
    ::SetWindowPos(pet_window_, z_order, left, top, width, height,
                   SWP_NOACTIVATE | (visible_ ? SWP_SHOWWINDOW : 0));
  }
  if (overlay_window_ != nullptr) {
    ::SetWindowPos(overlay_window_, z_order, left, top, width, height,
                   SWP_NOACTIVATE |
                       (visible_ && (pointer_down_active_ || !avatar_hit_mask_.Empty())
                            ? SWP_SHOWWINDOW : 0));
  }
  if (bubble_window_ != nullptr) {
    ::SetWindowPos(bubble_window_, z_order, left, top, width, height,
                   SWP_NOACTIVATE | (visible_ ? SWP_SHOWWINDOW : 0));
  }
  if (visible_ && pet_unity_player_host_ != nullptr && pet_window_ != nullptr) {
    pet_unity_player_host_->SetBounds(AvatarBounds());
  }
}

void WindowsDesktopCompanionHost::ResizeForDpi(UINT next_dpi, POINT origin) {
  ClearAvatarHitRegion();
  MonitorSnapshot target_monitor;
  const bool has_target_monitor = MonitorForPoint(origin, &target_monitor);
  const bool target_changed =
      has_target_monitor &&
      spatial_monitor_device_ != target_monitor.info.szDevice;
  dpi_ = next_dpi == 0 ? 96 : next_dpi;
  const int width = Scale(300);
  const int height = Scale(420);
  window_bounds_ =
      RECT{origin.x, origin.y, origin.x + width, origin.y + height};
  if (target_changed) {
    ClearSpatialAttachment();
    const RECT avatar = AvatarBounds();
    const POINT clamped = ClampOriginToWorkArea(
        origin, target_monitor.info.rcWork, width, height, avatar.left,
        width - avatar.right);
    MoveWindows(clamped.x, clamped.y);
  } else {
    RestoreSpatialPosition();
  }
  const int surface_width = window_bounds_.right - window_bounds_.left;
  const int surface_height = window_bounds_.bottom - window_bounds_.top;
  if (EnsurePetSurface(surface_width, surface_height)) {
    std::memset(pet_surface_pixels_, 0,
                static_cast<size_t>(surface_width) * surface_height * 4);
    UpdatePetLayeredWindow();
  }
  SaveBounds();
}

POINT WindowsDesktopCompanionHost::ClampOrigin(POINT proposed) const {
  const int width = window_bounds_.right - window_bounds_.left;
  const int height = window_bounds_.bottom - window_bounds_.top;
  const RECT proposed_rect{proposed.x, proposed.y, proposed.x + width,
                           proposed.y + height};
  const HMONITOR monitor =
      ::MonitorFromRect(&proposed_rect, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    return proposed;
  }
  const RECT avatar = AvatarBounds();
  const int minimum_left = info.rcWork.left - avatar.left;
  const int maximum_left = std::max(
      minimum_left, info.rcWork.right - width + width - avatar.right);
  return POINT{
      std::clamp(proposed.x, minimum_left, maximum_left),
      std::clamp(proposed.y, info.rcWork.top,
                 std::max(info.rcWork.top, info.rcWork.bottom - height)),
  };
}

RECT WindowsDesktopCompanionHost::AvatarBounds() const {
  return RECT{Scale(70), Scale(140), Scale(230), Scale(420)};
}

bool WindowsDesktopCompanionHost::IsAvatarPoint(POINT client_point) const {
  return avatar_hit_mask_.Contains(client_point.x, client_point.y);
}

int WindowsDesktopCompanionHost::Scale(int logical_pixels) const {
  const double dpi_scale = static_cast<double>(dpi_) / 96.0;
  return std::max(
      1,
      static_cast<int>(std::lround(logical_pixels * dpi_scale *
                                   presentation_visual_scale_)));
}

void WindowsDesktopCompanionHost::LoadInitialBounds() {
  dpi_ = ::GetDpiForSystem();
  if (dpi_ == 0) {
    dpi_ = 96;
  }
  const int width = Scale(300);
  const int height = Scale(420);
  window_bounds_ = RECT{0, 0, width, height};
  PersistedSpatialStateV1 persisted;
  if (LoadPersistedSpatialStateV1(&persisted)) {
    spatial_monitor_device_ = persisted.monitor_device;
    spatial_normalized_x_ = persisted.normalized_x;
    spatial_normalized_y_ = persisted.normalized_y;
    spatial_attachment_kind_ =
        static_cast<DWORD>(persisted.attachment_kind);
    spatial_attachment_monitor_device_ =
        persisted.attachment_monitor_device;
    spatial_attachment_window_ = persisted.attachment_window;
    spatial_attachment_window_process_id_ =
        persisted.attachment_window_process_id;
    RestoreSpatialPosition();
    return;
  }
  POINT cursor{};
  if (!::GetCursorPos(&cursor)) {
    cursor = POINT{0, 0};
  }
  MonitorSnapshot monitor;
  const RECT fallback_work{0, 0, 1440, 900};
  const RECT* work = &fallback_work;
  if (ReadMonitorSnapshot(
          ::MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY), &monitor)) {
    work = &monitor.info.rcWork;
  }
  const POINT initial{
      work->right - width + (width - AvatarBounds().right) -
          DpiScaledLogicalPixels(28.0, dpi_),
      work->bottom - height - DpiScaledLogicalPixels(24.0, dpi_),
  };
  const RECT avatar = AvatarBounds();
  const POINT clamped = ClampOriginToWorkArea(
      initial, *work, width, height, avatar.left, width - avatar.right);
  ClearSpatialAttachment();
  MoveWindows(clamped.x, clamped.y);
}

void WindowsDesktopCompanionHost::SaveBounds() const {
  MonitorSnapshot monitor;
  if (!MonitorForRect(window_bounds_, &monitor)) {
    return;
  }
  const int width = window_bounds_.right - window_bounds_.left;
  const int height = window_bounds_.bottom - window_bounds_.top;
  const RECT avatar = AvatarBounds();
  PersistedSpatialStateV1 state;
  state.monitor_device = monitor.info.szDevice;
  state.normalized_x =
      NormalizedAxis(window_bounds_.left, monitor.info.rcWork.left,
                     monitor.info.rcWork.right, width, avatar.left,
                     width - avatar.right);
  state.normalized_y =
      NormalizedAxis(window_bounds_.top, monitor.info.rcWork.top,
                     monitor.info.rcWork.bottom, height);
  if (spatial_attachment_kind_ <=
      static_cast<DWORD>(SpatialAttachmentKind::kWindowTop)) {
    state.attachment_kind =
        static_cast<SpatialAttachmentKind>(spatial_attachment_kind_);
    state.attachment_monitor_device = spatial_attachment_monitor_device_;
    state.attachment_window = spatial_attachment_window_;
    state.attachment_window_process_id =
        spatial_attachment_window_process_id_;
  }
  SavePersistedSpatialStateV1(state);
}
