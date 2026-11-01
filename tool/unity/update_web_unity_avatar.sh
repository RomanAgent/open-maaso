#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tool/unity/update_web_unity_avatar.sh

Validates the exported Unity WebGL avatar manifest and its referenced build
files, then atomically copies the player into web/unity/avatar/player.

Expected Unity export:
  unity/masso_avatar/Builds/WebGL/MaasoAvatar/
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_ROOT="$REPO_ROOT/unity/masso_avatar/Builds/WebGL/MaasoAvatar"
MANIFEST_NAME="maaso-avatar-manifest.json"
SOURCE_MANIFEST="$SOURCE_ROOT/$MANIFEST_NAME"
DESTINATION_PARENT="$REPO_ROOT/web/unity/avatar"
DESTINATION_ROOT="$DESTINATION_PARENT/player"

command -v node >/dev/null 2>&1 || fail "Node.js is required"
[[ -d "$SOURCE_ROOT" ]] || fail "Unity WebGL export not found: $SOURCE_ROOT"
[[ -f "$SOURCE_MANIFEST" ]] || fail "Unity manifest not found: $SOURCE_MANIFEST"
[[ -d "$SOURCE_ROOT/Build" ]] || fail "Unity Build directory is missing"
[[ ! -L "$DESTINATION_ROOT" ]] || fail "destination must not be a symbolic link"
[[ ! -e "$DESTINATION_ROOT" || -d "$DESTINATION_ROOT" ]] ||
  fail "destination exists and is not a directory"

if ! STREAMING_ASSETS_RELATIVE="$(
  node - "$SOURCE_ROOT" "$SOURCE_MANIFEST" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const sourceRoot = fs.realpathSync(process.argv[2]);
const manifestPath = fs.realpathSync(process.argv[3]);

function fail(message) {
  process.stderr.write(`invalid Unity WebGL export: ${message}\n`);
  process.exit(1);
}

function isSafeRelative(value) {
  return typeof value === 'string' &&
    value.length > 0 &&
    !path.posix.isAbsolute(value) &&
    !value.includes('\\') &&
    !value.includes('?') &&
    !value.includes('#') &&
    path.posix.normalize(value) === value &&
    value.split('/').every((segment) =>
      segment.length > 0 && segment !== '.' && segment !== '..');
}

function resolveInsideSource(relative, kind) {
  if (!isSafeRelative(relative)) fail(`${kind} path is unsafe`);
  const candidate = path.resolve(sourceRoot, ...relative.split('/'));
  if (!fs.existsSync(candidate)) fail(`${kind} is missing: ${relative}`);
  const real = fs.realpathSync(candidate);
  const fromRoot = path.relative(sourceRoot, real);
  if (fromRoot === '..' || fromRoot.startsWith(`..${path.sep}`) || path.isAbsolute(fromRoot)) {
    fail(`${kind} escapes the export root`);
  }
  return real;
}

const manifestRelative = path.relative(sourceRoot, manifestPath);
if (manifestRelative === '..' || manifestRelative.startsWith(`..${path.sep}`)) {
  fail('manifest escapes the export root');
}

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
} catch (error) {
  fail(`manifest is not valid JSON: ${error.message}`);
}
if (!manifest || Array.isArray(manifest) || typeof manifest !== 'object') {
  fail('manifest root must be an object');
}
if (manifest.schemaVersion !== 1) fail('schemaVersion must be 1');
for (const field of ['buildName', 'unityVersion', 'productVersion']) {
  if (typeof manifest[field] !== 'string' || manifest[field].trim() === '') {
    fail(`${field} is missing`);
  }
}
if (!manifest.files || Array.isArray(manifest.files) || typeof manifest.files !== 'object') {
  fail('files map is missing');
}

const buildFiles = {
  loader: '.loader.js',
  data: '.data',
  framework: '.framework.js',
  wasm: '.wasm',
};
for (const [field, suffix] of Object.entries(buildFiles)) {
  const relative = manifest.files[field];
  if (!isSafeRelative(relative) || !relative.startsWith('Build/') || !relative.endsWith(suffix)) {
    fail(`files.${field} must name a ${suffix} file under Build/`);
  }
  const resolved = resolveInsideSource(relative, `files.${field}`);
  const stat = fs.statSync(resolved);
  if (!stat.isFile() || stat.size <= 0) fail(`files.${field} must be a non-empty file`);
}

const streamingAssets = manifest.files.streamingAssets;
if (streamingAssets === null || streamingAssets === undefined) {
  process.stdout.write('');
} else {
  const resolved = resolveInsideSource(streamingAssets, 'files.streamingAssets');
  if (!fs.statSync(resolved).isDirectory()) {
    fail('files.streamingAssets must be a directory');
  }
  process.stdout.write(streamingAssets);
}
NODE
)"; then
  fail "Unity WebGL export validation failed"
fi

mkdir -p "$DESTINATION_PARENT"
STAGE_ROOT="$(mktemp -d "$DESTINATION_PARENT/.player-stage.XXXXXX")"
BACKUP_ROOT=""

cleanup() {
  if [[ -n "$BACKUP_ROOT" && -d "$BACKUP_ROOT" && ! -e "$DESTINATION_ROOT" ]]; then
    mv "$BACKUP_ROOT" "$DESTINATION_ROOT" || true
  fi
  if [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]]; then
    rm -rf -- "$STAGE_ROOT"
  fi
}
trap cleanup EXIT

cp "$SOURCE_MANIFEST" "$STAGE_ROOT/$MANIFEST_NAME"
cp -R "$SOURCE_ROOT/Build" "$STAGE_ROOT/Build"
if [[ -n "$STREAMING_ASSETS_RELATIVE" ]]; then
  mkdir -p "$STAGE_ROOT/$(dirname "$STREAMING_ASSETS_RELATIVE")"
  cp -R \
    "$SOURCE_ROOT/$STREAMING_ASSETS_RELATIVE" \
    "$STAGE_ROOT/$STREAMING_ASSETS_RELATIVE"
fi

if [[ -d "$DESTINATION_ROOT" ]]; then
  BACKUP_ROOT="$(mktemp -d "$DESTINATION_PARENT/.player-backup.XXXXXX")"
  rmdir "$BACKUP_ROOT"
  mv "$DESTINATION_ROOT" "$BACKUP_ROOT"
fi

if ! mv "$STAGE_ROOT" "$DESTINATION_ROOT"; then
  fail "could not install the validated Unity WebGL player"
fi
STAGE_ROOT=""

if [[ -n "$BACKUP_ROOT" ]]; then
  rm -rf -- "$BACKUP_ROOT"
  BACKUP_ROOT=""
fi
trap - EXIT

echo "Unity WebGL avatar player updated: $DESTINATION_ROOT"
