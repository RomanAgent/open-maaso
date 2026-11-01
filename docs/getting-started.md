# Getting started

Start with source inspection and focused tests. Running the full application additionally requires a compatible backend and platform-specific integration. The repository does not provide hosted accounts, backend credentials, licensed avatar/room content, large LLM/ASR/TTS model weights, or prebuilt Unity players. The small Silero VAD model is bundled with upstream notices.

## 1. Prepare the toolchain

The source environment records Flutter **3.47.2** with Dart **3.13.2**. `pubspec.yaml` declares Dart `^3.11.5`. This is a source-environment record, not a guarantee that every native target has been built from the public export.

Install Flutter and the native tools for your chosen target. Android uses Java 17 and an Android SDK/NDK; iOS requires macOS, Xcode, CocoaPods, and your own signing setup. Unity integration uses the editor version recorded in `unity/masso_avatar/ProjectSettings/ProjectVersion.txt` when that project is present.

```bash
flutter doctor -v
git clone https://github.com/RomanAgent/open-maaso.git
cd open-maaso
flutter pub get
```

Keep the local WebView packages under `third_party/`: the application references these patched implementations through path overrides.

## 2. Verify a focused boundary

```bash
flutter test test/agent_action_protocol_test.dart \
  test/turn_policy_test.dart \
  test/turn_policy_wiring_test.dart
```

Additional areas have their own tests:

```bash
flutter test test/unity_avatar_runtime_test.dart
flutter test test/maaso_tts_pause_resume_test.dart \
  test/mic_playback_gate_test.dart \
  test/voice_asr_vad_segment_test.dart
flutter test test/surface_runtime_contract_test.dart \
  test/surface_stage_modes_test.dart \
  test/surface_persistence_test.dart
```

These commands describe available tests. Check the [release verification record](verification.md) for the commands actually run and their results. Tests do not establish that a physical-device app can launch independently.

## 3. Supply your service configuration

The main experience requires a backend implementing the client's authentication and retained APIs. A generic OpenAI-compatible inference endpoint alone is insufficient. This release does not include the backend implementation or an unauthenticated standalone mode.

Set your own backend origins at build time:

```bash
flutter run -d <device-id> \
  --dart-define=MAASO_TEST_BASE_URL=https://api-dev.example.com \
  --dart-define=MAASO_PRODUCTION_BASE_URL=https://api.example.com
```

The app's environment selection determines which origin is used. Example domains are placeholders, not available services. Use HTTPS origins. RTC configuration, when used, accepts a root HTTPS origin without credentials, query parameters, or fragments:

```bash
--dart-define=MAASO_AGENT_BASE_URL=https://rtc-api.example.com
```

Other integrations, including push notifications, store purchases, asset hosting, and RTC, require your own platform registrations or backend setup. Configure only the services you intend to support. Use your own application identifiers for distributed builds.

`--dart-define` is public client configuration. It does not hide values from an app binary. Provider secrets, signing credentials, service-account keys, and server tokens belong outside Git and outside compiled client configuration.

Direct-provider LLM settings are account-scoped client settings, stored through the existing secure-storage path. They do not bypass backend login or replace other service APIs.

## 4. Resolve rendering and content prerequisites

Original licensed character and room assets are intentionally absent. Do not fetch them from old production URLs or assume the repository license grants their redistribution. Supply content you have permission to use and adapt the scene/catalog references to that content.

| Target | Rendering prerequisite |
| --- | --- |
| iOS | The Xcode project references a generated Unity iOS project. Recreate the export and link it before building Runner. A plain clone is not build-complete. |
| Android | The native build adds Unity only when a local Android export exists. Without one, source/build availability does not establish a functioning avatar. |
| macOS | Release and Profile require `unity/masso_avatar/Builds/macOS/MaasoAvatar.app`. Debug may omit it only when `MAASO_REQUIRE_UNITY_SIDECAR` is not `1`; the portal then reports `sidecarUnavailable`. A supplied sidecar must match the protocol fingerprint and packaging rules. |
| Windows / Linux | Verify each target's native bridge and dependencies separately. The existence of desktop model paths does not certify the renderer on every desktop target. |
| Web | Browser paths are present, but native plugins and feature parity require separate validation. |

The retained Unity exporter and scene builder still reference the excluded default `Joy.vrm` and `Companion.unity` scene. They require adaptation to your replacement content before export; running an existing export script does not recreate those assets.

Treat a redistributable sample scene and a clean-clone native build as their own acceptance milestones. The public source release does not include a ready-made replacement for the original licensed scene.

## 5. Choose model and speech paths

Cloud inference and cloud TTS are the defaults. Optional local LLM, ASR, and neural TTS are available only through desktop-specific policy and settings. Desktop ASR requires user-imported models. Large LLM/ASR/TTS model files are excluded from this source release and carry their own licenses, storage requirements, and platform constraints. The bundled Silero VAD model detects speech activity only; it does not provide recognition, synthesis, or language generation.

Do not infer mobile local-model support from the presence of a native inference dependency. Android, iOS, and Web are not enabled for local model loading by the current application policy.

## Before distributing your build

Read [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and retain the licenses of included dependencies and assets. In particular, the pinned BLE package has separate commercial licensing requirements, and the FFmpeg dependency has LGPL terms. Unity, RTC, and other native SDKs have their own conditions.

Use your own bundle identifiers, push configuration, account backend, store listings, and signing credentials. Do not publish local configuration, device data, generated exports, or logs containing tokens. See [SECURITY.md](../SECURITY.md) for the repository's reporting and secret-handling guidance.

## Troubleshooting

| Symptom | First check |
| --- | --- |
| Login fails | Is the configured backend real, reachable over HTTPS, and compatible with the client authentication API? |
| BYOK is set but Home is unavailable | BYOK configures model inference; it does not create an authenticated application session. |
| iOS cannot find Unity products | The separately generated Unity export is required by the Xcode project. |
| Avatar is missing | Check scene/model availability, native export, and bridge readiness independently. |
| macOS Release/Profile fails while embedding Unity | Export the required sidecar with compatible replacement content; Debug's optional-sidecar behavior does not apply to Release/Profile. |
| A generated app fails offline | Its source may depend on remote libraries, fonts, or network services. Inspect the actual browser failure. |
| A local model option is unavailable | Check the desktop-only platform policy and whether required models were supplied. |

For an issue report, include platform, toolchain, reproduction steps, and redacted diagnostics. Never attach a credential-bearing configuration or a full private device log.
