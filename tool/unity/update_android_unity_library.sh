#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tool/unity/update_android_unity_library.sh [options] [-- extra flutter args]

Exports the active Unity avatar project for Android, then runs Flutter so
Unity changes can be checked on device.

Options:
  --run                 Export, then run `flutter run --debug` (default).
  --build-only          Export, then run `flutter build apk --debug`.
  -d, --device-id ID    Pass a Flutter device id to `flutter run`.
  --no-pub             Pass --no-pub to the Flutter command.
  --unity-bin PATH      Unity executable. Defaults to UNITY_BIN or Unity 6000.5.2f1.
  -h, --help           Show this help.

Environment:
  UNITY_BIN             Unity executable override.
  FLUTTER_BIN           Flutter executable override.
  UNITY_EXPORT_LOG      Export log path override.
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

resolve_executable() {
  local executable="$1"
  local label="$2"

  if [[ "$executable" == */* ]]; then
    [[ -x "$executable" ]] || fail "$label is not executable: $executable"
    printf '%s\n' "$executable"
    return
  fi

  command -v "$executable" >/dev/null 2>&1 ||
    fail "$label not found on PATH: $executable"
  printf '%s\n' "$executable"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UNITY_PROJECT="$REPO_ROOT/unity/masso_avatar"
UNITY_ANDROID_EXPORT="$UNITY_PROJECT/Builds/Android"
UNITY_ANDROID_LIBRARY="$UNITY_ANDROID_EXPORT/unityLibrary"
UNITY_ANDROID_BUILD_GRADLE="$UNITY_ANDROID_LIBRARY/build.gradle"

DEFAULT_UNITY_BIN="/Applications/Unity/Hub/Editor/6000.5.2f1/Unity.app/Contents/MacOS/Unity"
UNITY_BIN="${UNITY_BIN:-}"
FLUTTER_BIN="${FLUTTER_BIN:-}"
MODE="run"
NO_PUB=0
DEVICE_ID=""
EXTRA_FLUTTER_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      MODE="run"
      ;;
    --build-only)
      MODE="build"
      ;;
    -d|--device-id)
      shift
      [[ $# -gt 0 ]] || fail "--device-id requires a value"
      DEVICE_ID="$1"
      ;;
    --no-pub)
      NO_PUB=1
      ;;
    --unity-bin)
      shift
      [[ $# -gt 0 ]] || fail "--unity-bin requires a value"
      UNITY_BIN="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_FLUTTER_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [[ -z "$UNITY_BIN" ]]; then
  if [[ -x "$DEFAULT_UNITY_BIN" ]]; then
    UNITY_BIN="$DEFAULT_UNITY_BIN"
  else
    UNITY_BIN="Unity"
  fi
fi

if [[ -z "$FLUTTER_BIN" ]]; then
  if [[ -x "/path/to/local-checkout" ]]; then
    FLUTTER_BIN="/path/to/local-checkout"
  else
    FLUTTER_BIN="flutter"
  fi
fi

UNITY_BIN="$(resolve_executable "$UNITY_BIN" "Unity")"
FLUTTER_BIN="$(resolve_executable "$FLUTTER_BIN" "Flutter")"

[[ -d "$UNITY_PROJECT" ]] || fail "Unity project not found: $UNITY_PROJECT"

mkdir -p "$UNITY_PROJECT/Logs"
UNITY_LOG="${UNITY_EXPORT_LOG:-$UNITY_PROJECT/Logs/export-android-$(date +%Y%m%d-%H%M%S).log}"

echo "==> Exporting Unity Android Library"
echo "    Unity project: $UNITY_PROJECT"
echo "    Unity log: $UNITY_LOG"
"$UNITY_BIN" \
  -batchmode \
  -nographics \
  -quit \
  -projectPath "$UNITY_PROJECT" \
  -executeMethod Maaso.Avatar.Editor.MaasoUnityLibraryExporter.ExportAndroid \
  -logFile "$UNITY_LOG"

[[ -f "$UNITY_ANDROID_BUILD_GRADLE" ]] ||
  fail "Unity Android export missing: $UNITY_ANDROID_BUILD_GRADLE"

if [[ "$MODE" == "build" ]]; then
  echo "==> Verifying Flutter Android APK build"
  FLUTTER_CMD=("$FLUTTER_BIN" build apk --debug)
  if [[ "$NO_PUB" -eq 1 ]]; then
    FLUTTER_CMD+=(--no-pub)
  fi
  if [[ "${#EXTRA_FLUTTER_ARGS[@]}" -gt 0 ]]; then
    FLUTTER_CMD+=("${EXTRA_FLUTTER_ARGS[@]}")
  fi
  (cd "$REPO_ROOT" && "${FLUTTER_CMD[@]}")
else
  FLUTTER_CMD=("$FLUTTER_BIN" run --debug)
  if [[ -n "$DEVICE_ID" ]]; then
    FLUTTER_CMD+=(-d "$DEVICE_ID")
  fi
  if [[ "$NO_PUB" -eq 1 ]]; then
    FLUTTER_CMD+=(--no-pub)
  fi
  if [[ "${#EXTRA_FLUTTER_ARGS[@]}" -gt 0 ]]; then
    FLUTTER_CMD+=("${EXTRA_FLUTTER_ARGS[@]}")
  fi

  echo "==> Running Flutter app"
  (cd "$REPO_ROOT" && "${FLUTTER_CMD[@]}")
fi
