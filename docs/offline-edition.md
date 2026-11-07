# Original Maaso UI with local services

The default entry is `lib/main.dart` → the original `MaasoApp` and original
router. `MAASO_OFFLINE_EDITION=true` selects local service adapters within that
same dependency graph. It does not mount a separate simplified application.
The host theme, page layouts, navigation and controls are retained. The visible edition changes are model/API-key configuration in the existing
Settings panel, the replacement free VRM character/cover, and removal of
membership cards and membership navigation. Original Coastal V4 Home and login
resources are retained with reviewed source ownership and CC0 texture provenance.

## Account and storage

The original login fields are prefilled with `test` / `test123456`.
`LocalTestAuthClient` is an in-process transport: it opens no socket and
returns a local session through the existing `AuthSessionService` transaction.
`AccountSessionLifecycleService` still owns account mount, retirement and DB
fences. A local account requires no remote device lease, discovery or handoff.

The app identity is `org.openmaaso.app`, separate from commercial Maaso.
The original `DBService` and account storage scope hold conversations, memory,
widgets, tasks and skills. `LocalOriginalBackend` supplies original validated
profile/privacy DTO clients in process, using the same account DB.
The demonstration account has initial editable local user/Agent profiles.
Signing out retains data; original account deletion performs local erasure
through its existing explicit confirmation and scoped purge flow.

No API key is stored in these records. The original `LLMConfigController`
retains account-scoped secure storage and its retirement/cancellation fences.
Never put a user key in source, build-time defines, work HTML or logs.

## Models and speech

The original Settings panel supports OpenAI, Anthropic Claude, Google Gemini,
DeepSeek, Qwen, Doubao, Kimi, Zhipu GLM, SiliconFlow, Groq, Ollama and Custom.
OpenAI-compatible providers retain the original streaming/tool client;
Anthropic and Gemini use protocol adapters. Saved endpoint/model examples are
editable. Model calls are disabled until the user enables a configuration.
Saving does not run automatic cloud-health probes. No Maaso inference proxy or
RTC token is needed. HTTPS is required for remote endpoints; loopback HTTP is
supported. `127.0.0.1` on a phone refers to that phone.

A freeform offline LLM is not bundled. No-key turns explain how to configure a
model. A remote provider needs connectivity; a loopback model can run without
an internet route when such a service exists on the device.

`AgentPipelineRuntimeService(localEdition:true)` selects installed system TTS.
The existing queue, generation, stop and avatar speech boundaries remain in
use. No cloud TTS or automatic voice-model download is selected. Bundled VAD
preparation fails closed if its asset cannot be copied; it cannot silently
fall back to a download. Installed voices and physical playback still need
acceptance on each target device.

## Original catalogs and generated works

`AgentGameCloudService` and `AppletCatalogService` use local account widgets and
local metadata. Original creation, feeds, saved-work player and companion
controls remain in place. Local publishing adds a device-local listing; it
does not create a public web URL. The local adapter never creates a cloud quota
or pretends that a hosted upload succeeded.

The original Surface host applies local-edition network isolation when loading
HTML, preserving the saved source and the work's authored visual style.
Self-contained HTML/CSS/JavaScript can run offline. Remote dependencies need to
be embedded for an offline work. Native account/device authority and model
keys are not exposed to authored HTML.

The original Skill Store and workshop remain. Their local repository stores
prompt packages, installs, enable/disable state, likes and evolution drafts.
Local standard tests report structural validation only, not evaluated model
behavior. BLE uses the existing transport, facade and original applet.

## Free character

The default `unity://masso/avatar_agent` loads the bundled Pixiv
`VRM1_Constraint_Twist_Sample v1.0.1` through the existing Unity runtime.
Its provenance and **VRM Public License 1.0** notice accompany
`unity/masso_avatar/Assets/MaasoAvatar/Models/Default/OpenMaaso.vrm`.
It is not an MIT/CC0 model. Source hashes and redistribution metadata are
checked by the public-export script. The cover is an actual full-body Unity
render. The native Unity export remains a separate build step.

General workshop imports may be stored locally, but rendering arbitrary local
VRM files still requires the existing renderer's local-import integration;
do not claim that storage alone proves an imported model can be selected.
Commercial characters and purchased motions remain excluded. The included
Coastal V4 room is Maaso-authored geometry using reviewed CC0 texture inputs;
its runtime dependency hashes are recorded in `assets/brand/original-room-assets.json`.

## Explicit boundaries

- Remote synchronization, shared execution leases, handoff, Firebase and push
  are not started by the local default.
- Membership cards, plan navigation and membership service registration are
  absent from the local edition. Model dispatch depends on the enabled provider
  configuration and its key, with a no-key loopback exception for local models.
  Daily token statistics are measurements, not an admission quota.
- Cloud image/video generation, remote visual perception, public moderation,
  public URLs and other routes without local contracts return unavailable.
  Their original pages are retained; backend elimination is not proof of full
  historical capability parity.
- The older `offline_*` storage/provider helpers and tests are not evidence of
  the active original-page bootstrap or of device acceptance.

## Validation

Relevant boundaries include `local_test_auth_client_test.dart`,
`local_original_backend_test.dart`, `local_skill_marketplace_test.dart`,
`original_ui_local_catalog_test.dart`, `local_edition_model_integration_test.dart`
and `local_bundled_speech_model_test.dart`, plus original login/settings,
routing, protocol, Surface, avatar and voice regressions.

A successful unit test or native build does not prove physical-device cold
launch, audible TTS, BLE transfer, background notification delivery or a live
provider account. README reference screenshots depict the earlier Maaso build;
they document the original interface, not a new-device acceptance receipt.
