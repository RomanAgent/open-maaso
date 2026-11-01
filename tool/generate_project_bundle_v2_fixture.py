#!/usr/bin/env python3
"""Rebuild the production shared golden from checked-in source and pinned SDK.

No dependency installation, network, timestamps or random IDs are involved.
JSON in this fixture uses only safe integers and ASCII keys, so sorted compact
Python JSON matches RFC 8785; the separately retained RFC vectors cover the
general JCS implementation in Dart/Go.
"""
import base64
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tool/fixtures/project_bundle_v2_source"
OUTPUT = ROOT / "tool/fixtures/project_bundle_v2_golden.json"


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    original = json.loads(OUTPUT.read_text())
    project = json.loads((SOURCE / "project.json").read_text())
    sdk = (ROOT / "assets/project_runtime/maaso_project_sdk_v2.js").read_text()
    script = (SOURCE / "src/main.js").read_text()
    style = (SOURCE / "src/styles.css").read_text()
    escaped_sdk = sdk.replace("</script", "<\\/script")
    escaped_script = script.replace("</script", "<\\/script")
    runtime = (
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<style>{style}</style></head><body><main id="maaso-project-root"></main>'
        '<script>globalThis.__MAASO_CONFIG__=__MAASO_CONFIG_JSON__;\n'
        f'{escaped_sdk}</script><script>{escaped_script}</script></body></html>'
    ).encode()
    types = {".json": "application/json", ".md": "text/markdown", ".js": "text/javascript",
             ".css": "text/css", ".png": "image/png", ".jpg": "image/jpeg"}
    files = []
    for path in sorted(SOURCE.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("fixture source symlinks are not permitted")
        if not path.is_file():
            continue
        relative = path.relative_to(SOURCE).as_posix()
        data = path.read_bytes()
        role = "asset" if relative.startswith("assets/") else "source"
        files.append({"path": relative, "mimeType": types[path.suffix], "role": role,
                      "byteLength": len(data), "sha256": digest(data),
                      "bytesBase64": base64.b64encode(data).decode()})
    files.append({"path": "dist/index.html", "mimeType": "text/html", "role": "runtime",
                  "byteLength": len(runtime), "sha256": digest(runtime),
                  "bytesBase64": base64.b64encode(runtime).decode()})
    files.sort(key=lambda item: item["path"])
    metadata = [{key: value for key, value in item.items() if key != "bytesBase64"} for item in files]

    def index_digest(artifact):
        roles = {"asset", "runtime" if artifact else "source"}
        return digest(canonical({"schemaVersion": 2, "files": [item for item in metadata if item["role"] in roles]}).encode())

    manifest = {key: value for key, value in project.items() if key not in {"title", "summary"}}
    manifest.update(requirementRevision=1,
                    requirementDigest=digest(b"Build an offline checklist with home and details."),
                    baseRevision=None, hashAlgorithm="jcs-sha256-v1",
                    contentDigest=index_digest(False), artifactDigest=index_digest(True), files=metadata)
    candidate = digest(canonical(manifest).encode())
    output = {
        "fixtureVersion": 1,
        "bundle": {"manifest": manifest, "files": files},
        "expected": {"candidateDigest": candidate, "bundleDigest": candidate,
                     "contentDigest": manifest["contentDigest"], "artifactDigest": manifest["artifactDigest"],
                     "canonicalManifest": canonical(manifest)},
        "jcsNumberVectors": original["jcsNumberVectors"],
        "jcsSortingVector": original["jcsSortingVector"],
    }
    OUTPUT.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in output["expected"].items() if key != "canonicalManifest"}))


if __name__ == "__main__":
    main()
