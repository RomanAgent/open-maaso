# Offline edition: native packaging

The default application entry is the standalone local edition. Its iOS, Android
and macOS application identity is `org.openmaaso.app`; it can coexist with the
commercial Maaso app without reusing that app's installed data container.
The display name is **Open Maaso**. Android's implementation namespace stays
`com.futurpals.maaso`; explicit activity names and application-ID-scoped launcher
aliases keep the existing native bridge classes resolvable.

## Native configuration

- iOS links a generated UnityFramework containing the reviewed free VRM,
  original idle animation and primitive white scene. Build the Unity export
  below before compiling Flutter. The Firebase project file is not required.
  The existing native Unity bridge and AvatarRuntime contract are reused.
- Android does not apply the Google Services plugin or auto-initialize Firebase.
  Google cloud backup is disabled. The standard TTS service query permits the
  app to enumerate installed speech engines. Internet permission supports the
  explicitly enabled model client; local login and storage have no backend.
  The local Unity export is required by default. A missing export stops the
  build with instructions instead of silently omitting the 3D character.
- iOS disables Firebase delegate interception, messaging auto-init and analytics
  collection. No APNs entitlement or remote-notification background mode is
  requested by this edition. Platform registrations are not required for local
  login or storage. Application Support, containing the local database and
  saved works, is marked as excluded from system cloud backups at startup.
- macOS packaging omits the Unity sidecar for every configuration by default.
  It removes only an obsolete generated helper in the output app, preserving
  the Unity source/export directory and other packaged helpers.
- The web bootstrap points CanvasKit at the packaged `canvaskit/` directory,
  rather than a renderer CDN. The web font fallback base also stays local; the
  required Roboto fallback is packaged under `web/fonts/`, and the declared
  `MaasoOfflineSans` family supplies Noto Sans SC for Chinese UI. Font source
  revisions, hashes and licenses accompany the files. Native system-font
  selection is retained. A web build must be served locally or downloaded
  beforehand; browser caches and plugin support require their own validation.

These native defaults support the local Dart startup path. They do not prove
that every transitive plugin makes zero requests; live network instrumentation
and platform cold-launch checks are separate validation steps.

Unity Analytics is removed from the package manifest, player analytics
submission is disabled, and Unity Connect analytics, ads, diagnostics and crash
reporting are disabled. No cloud project ID or developer team is embedded.

## Build the bundled free avatar

Use Unity 6000.5.2f1 with iOS Build Support. From this repository root:

The installed Xcode also needs its Metal compiler component. Verify
`xcrun metal --version`; if Xcode reports that the component is missing,
install it with `xcodebuild -downloadComponent MetalToolchain` before shader
rendering/export. This is a developer-tool setup step.

```sh
"$UNITY_EDITOR" -batchmode -nographics -quit \
  -projectPath "$PWD/unity/masso_avatar" \
  -executeMethod Maaso.Avatar.Editor.MaasoDefaultAvatarSceneBuilder.RebuildAndExportIOS
ruby tool/unity/link_ios_unity_library.rb
```

`UNITY_EDITOR` is the executable path to your installed Unity Editor. Package
resolution may need the internet during development; the produced player loads
its avatar and scene locally. The source VRM is reviewed and hash-pinned. The
builder creates the controller, idle clip, floor and shared procedural entrance
without commercial room or animation assets. The entrance uses the original
login receiver, shared-door binding and camera transition. Player-pack validation requires the reviewed source and rejects
Joy and retired assets. Generated exports remain in the normal ignored
`unity/masso_avatar/Builds/iOS` directory.

## Signing and installation

Use your own development team/profile for `org.openmaaso.app` when installing
on a physical iPhone. For compilation without provisioning, use:

```sh
flutter build ios --release --no-codesign
```

An unsigned build is not an installable self-testing package. A physical-device
package for Home Screen launch must be a signed Release build, and its installed
version and debugger-free cold launch must be checked on the target device.
The Android release signing environment remains required:
`ANDROID_UPLOAD_KEYSTORE_PATH`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD`,
`ANDROID_UPLOAD_KEY_ALIAS`, and `ANDROID_UPLOAD_KEY_PASSWORD`.
No release build silently falls back to a debug key. Keep keys and passwords
outside Git.

For Android, install Unity's Android Build Support and export the committed
reviewed scene with:

```sh
"$UNITY_EDITOR" -batchmode -nographics -quit \
  -projectPath "$PWD/unity/masso_avatar" -buildTarget Android \
  -executeMethod Maaso.Avatar.Editor.MaasoUnityLibraryExporter.ExportAndroid
flutter build apk --release
```

To regenerate the scene first, run the same Unity command with
`-executeMethod Maaso.Avatar.Editor.MaasoDefaultAvatarSceneBuilder.RebuildScene`.
The signing environment must already be configured before the second command.
Only for development without the required 3D character, set
`ORG_GRADLE_PROJECT_openMaasoEmbedUnity=false`. A local development signing
key is suitable for testing and is distinct from a store-upload key.
macOS requires `OPEN_MAASO_EMBED_UNITY=1` with its own exported sidecar.
The offline UI reuses UnityAvatarRuntime and its default bundled-model URI.
The free model's license and source provenance accompany `OpenMaaso.vrm`.

## Verification in this change

`test/offline_native_configuration_test.dart` checks the isolated application
identity, default cloud/push configuration, reviewed local export linkage,
local web renderer and font bootstrap, and actual sidecar-script behavior for Debug, Profile and
Release. Ruby/Xcodeproj and `plutil` validate the edited Xcode project structure
and property-list syntax. These checks do not replace native compilation,
signing, device installation or a physical-device offline launch.

The free-avatar verification command `OpenMaasoAvatarVerification.BeginPlayPreview`
exercises the existing load/framing/visibility command path in Unity Play Mode
and renders a full-body PNG when `OPEN_MAASO_AVATAR_PREVIEW` is set. This is real
model-rendering evidence, not an iPhone cold-launch receipt. Focused Unity asset
guard tests and the actual iOS player-pack audit are separate from the Flutter
configuration tests.
