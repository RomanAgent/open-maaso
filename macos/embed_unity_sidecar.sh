#!/bin/sh

set -eu

source_app="${SRCROOT}/../unity/masso_avatar/Builds/macOS/MaasoAvatar.app"
helpers_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
destination_app="${helpers_dir}/MaasoAvatar.app"
source_executable="${source_app}/Contents/MacOS/MaasoAvatar"
source_data="${source_app}/Contents/Resources/Data"
protocol_fingerprint="${source_data}/maaso-sidecar-protocol.sha256"
protocol_source_paths='lib/src/features/agent/application/avatar/desktop_unity_sidecar_protocol.dart
macos/Runner/MacOSUnityAvatarPortal.swift
unity/masso_avatar/Assets/MaasoAvatar/Scripts/CompanionPortalCaptureController.cs
unity/masso_avatar/Assets/MaasoAvatar/Scripts/DesktopUnitySidecarBridge.cs
unity/masso_avatar/Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs
unity/masso_avatar/Assets/Plugins/macOS/MaasoDesktopAvatarPortalBridge.mm
unity/masso_avatar/Assets/MaasoAvatar/Editor/MaasoUnityLibraryExporter.cs
unity/masso_avatar/Assets/Plugins/macOS/MaasoDesktopAvatarPortalBridge.mm.meta'

if [ ! -x "${source_executable}" ] || [ ! -d "${source_data}" ]; then
  if [ "${CONFIGURATION}" = "Debug" ] && \
     [ "${MAASO_REQUIRE_UNITY_SIDECAR:-0}" != "1" ]; then
    echo "warning: macOS Unity Avatar sidecar is not exported; Avatar portal will report sidecarUnavailable."
    exit 0
  fi
  echo "error: export the Unity macOS sidecar before packaging: ${source_app}" >&2
  exit 1
fi

# Reject older exports that register a second ordinary application in Dock.
# This is a build-time check: never mutate a signed installed helper at launch.
source_info_plist="${source_app}/Contents/Info.plist"
helper_ui_element="$(/usr/bin/plutil -extract LSUIElement raw -expect bool "${source_info_plist}" 2>/dev/null || true)"
helper_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -expect string "${source_info_plist}" 2>/dev/null || true)"
if [ "${helper_ui_element}" != "true" ] || \
   [ "${helper_bundle_id}" != "com.futurpals.maaso.avatar-sidecar" ]; then
  echo "error: Unity macOS sidecar is not configured as the Maaso background UI agent; export it again: ${source_app}" >&2
  exit 1
fi

for relative_path in ${protocol_source_paths}; do
  source_path="${SRCROOT}/../${relative_path}"
  if [ ! -f "${source_path}" ]; then
    echo "error: macOS Unity sidecar protocol source is missing: ${source_path}" >&2
    exit 1
  fi
done

if [ ! -f "${protocol_fingerprint}" ]; then
  echo "error: Unity macOS sidecar has no protocol fingerprint; export it again: ${source_app}" >&2
  exit 1
fi

expected_fingerprint="$(
  {
    for relative_path in ${protocol_source_paths}; do
      /usr/bin/printf '%s\0' "${relative_path}"
      /bin/cat "${SRCROOT}/../${relative_path}"
      /usr/bin/printf '\0'
    done
  } | /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1
)"
exported_fingerprint="$(/usr/bin/tr -d '[:space:]' < "${protocol_fingerprint}")"
if [ "${expected_fingerprint}" != "${exported_fingerprint}" ]; then
  echo "error: Unity macOS sidecar is stale for the current desktop protocol; export it again: ${source_app}" >&2
  exit 1
fi

/bin/mkdir -p "${helpers_dir}"
/bin/rm -rf "${destination_app}"
/usr/bin/ditto --rsrc --extattr "${source_app}" "${destination_app}"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
  signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  sidecar_entitlements="${SRCROOT}/Runner/UnitySidecar.entitlements"
  if [ "${signing_identity}" = "-" ]; then
    sidecar_entitlements="${SRCROOT}/Runner/UnitySidecarAdHoc.entitlements"
  fi
  /usr/bin/codesign \
    --force \
    --deep \
    --sign "${signing_identity}" \
    --entitlements "${sidecar_entitlements}" \
    --options runtime \
    --timestamp=none \
    "${destination_app}"
fi
