#!/bin/sh

set -u

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
asset_catalog=${MAASO_ASSET_CATALOG:-"$ios_root/Runner/Assets.xcassets"}
max_attempts=${MAASO_ASSET_CATALOG_PREFLIGHT_ATTEMPTS:-3}
retry_delay=${MAASO_ASSET_CATALOG_PREFLIGHT_RETRY_DELAY_SECONDS:-1}

if [ ! -d "$asset_catalog" ]; then
  echo "error: asset catalog not found: $asset_catalog" >&2
  exit 66
fi

if [ -n "${MAASO_ACTOOL:-}" ]; then
  actool=$MAASO_ACTOOL
else
  actool=$(xcrun --find actool) || exit $?
fi

work_directory=$(mktemp -d "${TMPDIR:-/tmp}/maaso-actool-preflight.XXXXXX") || exit $?
trap 'rm -rf -- "$work_directory"' EXIT HUP INT TERM

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  output_directory="$work_directory/compiled-$attempt"
  mkdir -p "$output_directory"

  if "$actool" "$asset_catalog" \
    --compile "$output_directory" \
    --platform iphoneos \
    --minimum-deployment-target "${IPHONEOS_DEPLOYMENT_TARGET:-13.0}" \
    --target-device iphone \
    --target-device ipad \
    --app-icon AppIcon \
    --output-partial-info-plist "$work_directory/partial-$attempt.plist" \
    >"$work_directory/stdout-$attempt.log" \
    2>"$work_directory/stderr-$attempt.log"; then
    echo "[maaso] AssetCatalogSimulatorAgent is ready (attempt $attempt)."
    /bin/sh "$script_directory/warm_pod_xcframeworks.sh"
    exit 0
  else
    status=$?
  fi

  cat "$work_directory/stderr-$attempt.log" >&2
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "error: asset catalog preflight failed after $attempt attempts." >&2
    exit "$status"
  fi

  echo "warning: asset catalog preflight attempt $attempt failed; retrying." >&2
  sleep "$retry_delay"
  attempt=$((attempt + 1))
done
