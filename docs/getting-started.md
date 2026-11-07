# Getting started

The default app uses the original Maaso interface and local account/data
adapters. A Maaso backend, Firebase configuration or hosted TTS account is not
required for local login and persistence.

## Prepare tools and the character

Recorded versions: Flutter 3.47.2, Dart 3.13.2, Unity 6000.5.2f1.
Android requires Java 17 and SDK/NDK; iOS requires Xcode, CocoaPods and an
eligible provisioning profile. Package downloads are development-time steps.

```bash
git clone https://github.com/RomanAgent/open-maaso.git
cd open-maaso
flutter pub get
```

Build/export the included free VRM scene and link its native Unity player
before building the mobile app. Follow [native packaging](offline-platforms.md).
Keep the vendored `third_party/webview_flutter_*` dependencies for isolation.

## Run checks

```bash
flutter test test/local_test_auth_client_test.dart test/local_original_backend_test.dart \
  test/local_skill_marketplace_test.dart test/original_ui_local_catalog_test.dart \
  test/local_edition_model_integration_test.dart test/local_bundled_speech_model_test.dart
flutter test test/router_destinations_test.dart test/settings_white_frost_page_test.dart \
  test/agent_action_protocol_test.dart test/surface_runtime_contract_test.dart
```

Use a supported prepared device with `flutter run -d <device-id>` during
active development. For an independently launched iPhone self-testing package,
build and sign **Release**, verify the installed version and cold launch it
without an attached debugger. Do not use Debug as a Home Screen launch package.

## Sign in and configure a model

The original login fields are prefilled: **test / test123456**.
This is a local convenience identity. Profile and Agent defaults are editable
through the original pages. Existing Home, conversation, Store/workshop,
games/applets, memory, companion and settings controls remain in place.

In **Settings → Model**, select a provider, review its endpoint/model, enter
your key and explicitly enable model calls. Saving does not contact a provider.
The configured endpoint is the only inference service; Maaso proxy credentials
are not needed. Remote model calls need connectivity. No large LLM is bundled.
Ollama's loopback address refers to the device running the app.

Keys are held by account-scoped secure storage. Keep them out of source, logs,
works and build-time definitions. Installed local system voices provide TTS;
missing voices do not trigger a cloud TTS fallback or model download.

## Local works and data

Original game/applet catalogs read device-local widgets. A local listing is
not a public URL. Use self-contained authored HTML for offline play: remote
scripts, fonts, images and API dependencies are blocked by the local host.
The original saved-work player and companion controls are retained.

The original Skill Store stores local prompt packages and installation state.
Local structural checks are not a claim of semantic model evaluation. The
original BLE applet reuses the singleton transport and requires compatible
hardware and OS permission for real transfers.

Signing out retains local data. Use the original account deletion confirmation
flow to remove the local test account's scoped data. This app has a distinct
bundle identity and does not erase the commercial app's data.

Read [local architecture and limitations](offline-edition.md) for cloud-only
operations without a local implementation and the outstanding device gates.
