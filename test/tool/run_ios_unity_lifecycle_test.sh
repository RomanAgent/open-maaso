#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/maaso-ios-lifecycle-test.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
xcrun swiftc \
  -module-cache-path "$task_temp/module-cache" \
  "$task_root/ios/Runner/UnityAvatarLifecycle.swift" \
  "$task_root/test/tool/ios_unity_lifecycle_test.swift" \
  -o "$task_temp/ios-unity-lifecycle-test"
"$task_temp/ios-unity-lifecycle-test"
