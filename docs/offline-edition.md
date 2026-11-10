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
editable. `apiOnlyModelConfiguration` derives readiness from a valid saved
endpoint, model and key; there is no Cloud off switch. A legacy saved disabled
bit cannot suppress a valid configuration, and incomplete settings cannot
admit a model request. Saving does not run automatic cloud-health probes.
The configured API is the only inference service: no Maaso inference proxy,
RTC token or local-LLM fallback is used. HTTPS is required for remote endpoints;
explicit loopback HTTP services can omit the key. `127.0.0.1` on a phone refers
to that phone. Keys are transmitted only to the selected endpoint for requests.

A freeform offline LLM is not bundled. Missing-configuration turns explain
how to configure a model; a provider failure is reported rather than changing
inference services. A remote provider needs connectivity; an explicitly
configured loopback model can run without an internet route when such a
service exists on the device.

The conversation path is user speech recognition or text → configured model
API → local phone TTS. `AgentPipelineRuntimeService(localEdition:true)` selects
`SystemTtsEngine`: iOS installed voices and Android non-network voices synthesize
PCM/WAV through a request-scoped native bridge. The resulting audio enters
`MaasoTtsPlugin`'s existing utterance queue, player and mouth timing; generation,
stop, cancellation and pause/resume boundaries remain in use. The app's sound
preference still controls spoken playback. No cloud TTS or automatic voice-model
download is selected. Missing voices leave text available. Bundled VAD
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

The bundled controller includes a project-authored Humanoid `standard_walk`
cycle; [its authoring and tests](avatar/free-vrm-walk.md) are documented
separately. Home presence entry and Agent Space already request that exact
state. The previous Idle-only controller caused entry to fail with
`walk_unavailable`, producing the visible Retry state, and prevented a walking
pose during room travel. The supplied cycle fixes that missing dependency;
native presence/locomotion retain ownership of translation with root motion
disabled. No entry watchdog or rendered-frame readiness gate was bypassed.
Receiver Play Mode probes reproduce the old missing-state failure and cover
corrected cold entry, rendered completion, re-entry and mid-entry cancellation.
These are Editor results, not phone acceptance receipts.

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
  absent from the local edition. Model dispatch depends only on the saved
  provider configuration and its key, with an explicit no-key loopback exception.
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
and `local_bundled_speech_model_test.dart`, plus the `api_only_*` configuration,
settings and runtime tests. `app_theme_account_rebind_test.dart` and
`avatar_world_theme_service_test.dart` cover account/theme propagation;
`system_tts_engine_test.dart`, utterance/pause/playback/VAD tests cover the
local speech boundary. Home entrance/startup and presence-transition tests
retain failure-code, selection-generation, rendered-frame and cancellation
fences. The focused source workflow runs these alongside the existing
login/settings, routing, protocol and Surface regressions.

A successful unit test or native build does not prove physical-device cold
launch, audible TTS, BLE transfer, background notification delivery or a live
provider account. README reference screenshots depict the earlier Maaso build;
they document the original interface, not a new-device acceptance receipt.
