#!/bin/sh

set -eu

if [ -z "${PODS_ROOT:-}" ] || [ -z "${PODS_XCFRAMEWORKS_BUILD_DIR:-}" ]; then
  echo "[maaso] CocoaPods XCFramework preflight skipped outside an Xcode build."
  exit 0
fi

for target in sherpa_onnx_ios VolcApiEngine VolcEngineRTC; do
  copy_script="$PODS_ROOT/Target Support Files/$target/$target-xcframeworks.sh"
  if [ ! -f "$copy_script" ]; then
    continue
  fi

  echo "[maaso] Warming $target XCFrameworks."
  /bin/sh "$copy_script"
done
