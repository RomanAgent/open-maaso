# Open-source scope

open-maaso is a source release of the Maaso Flutter client and its integration layers. It provides a codebase for studying and extending a companion agent: conversation orchestration, structured actions, voice, memory, generated browser works, application navigation, avatar bridges and device adapters.

It is not a release of the production backend, commercial avatar artwork, deployed accounts, or prebuilt application packages.

## Included and excluded

| Area | Included | Required separately |
| --- | --- | --- |
| Flutter client | Dart source, app navigation, state ownership, persistence, Agent runtime and focused tests | Flutter and resolved packages |
| Model providers | OpenAI-compatible client integrations and configuration logic | Your provider account, API key and permitted endpoint |
| Account and hosted features | Client protocols, lifecycle and service adapters | A compatible backend for authentication and account-scoped features |
| Generated works | Surface protocols, validation, browser runtime integration and SDK source | Any external resources requested by an authored work |
| Voice | Capture, VAD, speech orchestration and provider integrations | Platform permissions, supported runtime libraries and any needed large LLM/ASR/TTS model weights or service configuration |
| Avatar | Dart interfaces, native platform bridges and Unity integration source | Licensed avatar/art/animation assets, scene setup and rebuilt Unity exports |
| BLE | Shared transport and device-specific adapter source | Compatible hardware and dependency licensing appropriate to your use |
| Distribution | Source configuration templates | Your own bundle identifiers, signing identities and store accounts |

The public snapshot uses fresh Git history and excludes private operational documents, marketing work, recorded conversations, production configurations, build products and signing material. References to omitted assets describe integration points; they do not distribute those assets or establish rights to obtain them.

## Backend boundary

The existing application startup mounts an authenticated account runtime. A compatible backend is required for that lifecycle and for hosted services. Configuring an OpenAI-compatible key does not by itself replace authentication, model catalogues, cloud synchronization, avatar selection or execution-lease APIs.

The backend is not included in this release. A local guest mode or self-hosted backend would be a separate implementation requiring its own tests. Do not treat a working login screen as acceptance of end-to-end chat.

## Avatar boundary

Unity is the current avatar backend. The release retains source such as C#, shaders and native bridge code, package references and project settings, while omitting models, textures, scenes, serialized art assets, animation clips and player exports. This is an integration source distribution, not a complete Unity content project.

Some scene-building and validation tools retain assumptions about the original bundled model and animation controller. They require adaptation and replacement content before building a new avatar player. Supplying an arbitrary VRM file alone does not satisfy those tools. No fallback WebView avatar renderer is supplied.

## Platform status

| Platform | Source boundary |
| --- | --- |
| Android | Platform source is included. The Unity library integration is conditional on a local export. Missing content still limits avatar behavior; native dependencies and device permissions require validation. |
| iOS / iPadOS | Platform source is included. The Xcode project links a UnityFramework export, which must be rebuilt from your replacement content. Your own signing and device validation are required. |
| macOS | Platform source is included. Debug tolerates a missing Unity sidecar; Release packaging requires the sidecar. This does not establish a complete desktop runtime without replacement content. |
| Windows / Linux / Web | Flutter scaffolding and capability-gated source are present. Feature parity and a complete distribution are not claimed. |

The dependency lock requires Flutter 3.44 or newer; the package SDK constraint is Dart `^3.11.5`. Native configuration currently uses iOS 16.4+, Android API 26+ and Java 17. The retained Unity project targets Unity 6000.5.2f1. These are source requirements, not a promise that every newer toolchain is tested.

Local model capabilities are intentionally platform-gated. Desktop opt-in LLM/ASR/TTS paths are not a claim of full offline operation on mobile or Web. External libraries, media and services used by generated works may require connectivity.

## Verification and contribution claims

Tests validate the boundaries they exercise. A passing protocol or widget test does not establish a device cold launch, native renderer compatibility, hardware behavior or production readiness. Record the command, platform and result for changes, and identify skipped verification explicitly.

See [third-party notices](../THIRD_PARTY_NOTICES.md) before adding assets or distributing a binary.

The small Silero VAD detector is bundled with a verified upstream SHA-256 and its MIT notice; see `assets/sherpa_models/silero-vad-v5/PROVENANCE.md`.
