#!/usr/bin/env python3
"""Check Git-tracked public source; report locations, never matched values.

This supplements a secret scanner. It does not prove that a repository is
secret-free and does not scan old commits. Run Gitleaks separately for history.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


# This licensed VAD is the one deliberately bundled model. Changing its bytes
# requires reviewing its provenance and updating THIRD_PARTY_NOTICES.md.
LICENSED_MODELS = {
    "assets/sherpa_models/silero-vad-v5/silero_vad.onnx":
        "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
}
MODEL_SUFFIXES = {
    ".vrm", ".fbx", ".blend", ".blend1", ".glb", ".gltf", ".gguf",
    ".safetensors", ".ckpt", ".pth", ".pt", ".onnx", ".tflite",
}
SIGNING_SUFFIXES = {".p8", ".p12", ".pfx", ".jks", ".keystore", ".mobileprovision"}
PRIVATE_DIRECTORIES = {
    ".store-release-secrets", ".worktrees", ".gitnexus", ".dart_tool",
    "build", "Pods", "DerivedData", "node_modules",
}
CONTENT_RULES = {
    "private-key": re.compile(
        r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"
    ),
    "provider-token": re.compile(
        r"(?<![A-Za-z0-9_-])(?:"
        r"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}|"
        r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|"
        r"xox[baprs]-[A-Za-z0-9-]{15,}|AIza[0-9A-Za-z_-]{30,}|"
        r"AKIA[0-9A-Z]{16})(?![A-Za-z0-9_-])"
    ),
    "jwt": re.compile(
        r"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\."
        r"[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?![A-Za-z0-9_-])"
    ),
    "machine-path": re.compile(
        r"(?<![A-Za-z0-9_./-])(?:file://)?/(?:Users|home)/[A-Za-z0-9_. -]+/|"
        r"[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\"
    ),
}
# This is deliberately fake test data proving raw model output is discarded.
# Only its exact source line in this one file is exempt from this one rule.
PUBLIC_FIXTURES = {
    ("test/action_audit_log_test.dart", "provider-token"): {
        "const secret = '" + "sk-" + "super-secret-user-authored-display-text';",
    },
    ("test/server_request_failure_log_test.dart", "machine-path"): {
        "const modelPath = '" + "/Users/" + "owner/private/avatar.bundle';",
        "const localPath = '" + "/Users/" + "owner/private/avatar_selection.dart:42:7';",
        "const linuxPath = '" + "/home/" + "runner/maaso/avatar_selection.dart:18:3';",
        "const windowsPath = r'C:" + "\\Users\\owner\\maaso\\avatar_selection.dart:9:2';",
        "'" + "/Users/" + "John Doe/private,folder/avatar_selection.dart:42:7';",
    },
}


def forbidden_path(name: str) -> str | None:
    """Reject deployment inputs and model assets without rejecting examples."""
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        return "unsafe-path"
    if set(path.parts) & PRIVATE_DIRECTORIES:
        return "private-directory"
    if path.name in {"google-services.json", "GoogleService-Info.plist"}:
        return "firebase-project-config"
    if path.name in {"local.properties", "key.properties", ".store-release.env"}:
        return "local-config"
    if path.name.startswith(".env") or path.suffix == ".env":
        if not path.name.endswith((".example", ".template")):
            return "environment-secrets"
    if path.suffix.lower() in SIGNING_SUFFIXES:
        return "signing-material"
    if path.suffix.lower() in MODEL_SUFFIXES and name not in LICENSED_MODELS:
        return "unreviewed-model-asset"
    return None


def content_findings(name: str, data: bytes) -> list[tuple[str, int, str]]:
    """Return only path, line and category. No secret is returned or logged."""
    results = []
    if name in LICENSED_MODELS:
        if hashlib.sha256(data).hexdigest() != LICENSED_MODELS[name]:
            results.append((name, 0, "licensed-model-checksum"))
        return results
    if b"\0" in data[:8192]:
        return results
    try:
        source = data.decode("utf-8")
    except UnicodeDecodeError:
        return results
    for number, line in enumerate(source.splitlines(), 1):
        for category, pattern in CONTENT_RULES.items():
            if pattern.search(line):
                if line.strip() in PUBLIC_FIXTURES.get((name, category), set()):
                    continue
                results.append((name, number, category))
    return results


def check_repository(root: Path) -> tuple[int, list[tuple[str, int, str]]]:
    """Read only this checkout's tracked working files, including staged adds."""
    root = root.resolve()
    top = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True
    ).strip()
    if Path(top).resolve() != root:
        raise ValueError("Run this checker at the public repository root, not a parent checkout.")
    names = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-z"]
    ).decode("utf-8").split("\0")
    if not any(names):
        raise ValueError("No tracked source files; stage the intended public source before scanning.")
    results = []
    count = 0
    for name in filter(None, names):
        count += 1
        if category := forbidden_path(name):
            results.append((name, 0, category))
        path = root / name
        if path.is_symlink():
            results.append((name, 0, "tracked-symlink"))
            continue
        if not path.is_file():
            results.append((name, 0, "missing-tracked-file"))
            continue
        results.extend(content_findings(name, path.read_bytes()))
    return count, results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        count, findings = check_repository(args.root)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Public export check could not run: {type(error).__name__}", file=sys.stderr)
        return 2
    for name, line, category in findings:
        print(f"{name}:{line}: {category}")
    print(f"Checked {count} tracked files; {len(findings)} finding(s).")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
