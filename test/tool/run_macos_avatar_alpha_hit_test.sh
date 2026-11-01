#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/maaso-alpha-hit-test.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
xcrun swiftc \
  "$task_root/macos/Runner/MacOSAvatarAlphaHitTest.swift" \
  "$task_root/test/tool/macos_avatar_alpha_hit_test.swift" \
  -o "$task_temp/macos-avatar-alpha-hit-test"
"$task_temp/macos-avatar-alpha-hit-test"
