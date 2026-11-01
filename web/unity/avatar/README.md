# Unity WebGL avatar player

The browser avatar host loads a generated Unity player from `player/`. That
directory is deliberately ignored by Git because the `.data`, JavaScript, and
WebAssembly files are build artifacts.

## Update the player

Export the Unity project to:

```text
unity/masso_avatar/Builds/WebGL/MaasoAvatar/
```

Then run:

```bash
tool/unity/update_web_unity_avatar.sh
```

The script validates `maaso-avatar-manifest.json`, all four referenced files,
and their paths before atomically replacing `web/unity/avatar/player/`. It
copies `StreamingAssets` only when the manifest names that directory.

The manifest contract is:

```json
{
  "schemaVersion": 1,
  "buildName": "MaasoAvatar",
  "unityVersion": "6000.5.2f1",
  "productVersion": "1.0.0",
  "files": {
    "loader": "Build/MaasoAvatar.loader.js",
    "data": "Build/MaasoAvatar.data",
    "framework": "Build/MaasoAvatar.framework.js",
    "wasm": "Build/MaasoAvatar.wasm",
    "streamingAssets": null
  }
}
```

All paths are relative to the manifest. The host resolves the manifest from
`document.baseURI`, so deployments under a non-root Flutter `--base-href` keep
working.

## Hosting requirements

- Serve the player over HTTP(S), not `file://`.
- Serve `.wasm` as `application/wasm`.
- This export contract uses uncompressed Unity output. If compression is
  enabled later, configure matching `Content-Encoding` headers before changing
  the manifest contract.
- Avoid caching a new manifest with old `Build/` files. Deploy the copied
  `player/` directory atomically.
- Decide deliberately whether Flutter's service worker or Unity owns large
  `.data` caching; enabling both can consume browser quota twice.

Run the browser-host tests with:

```bash
node --test test/js/maaso_unity_avatar_host_test.mjs
flutter test test/web_shell_contract_test.dart
```
