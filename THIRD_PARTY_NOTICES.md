# Third-party notices

The root [MIT license](LICENSE) covers original open-maaso code and documentation. It does not replace a dependency's license, grant rights to third-party artwork or model weights, or license a hosted service. Existing file-level notices take precedence for their files.

## Source included in this repository

| Component | License / attribution | Included notices |
| --- | --- | --- |
| `third_party/webview_flutter_android` | BSD-3-Clause; the Flutter Authors | `LICENSE`, `AUTHORS`, `UPSTREAM_SOURCE.json`, `MAASO_PATCH.md` in the component directory |
| `third_party/webview_flutter_wkwebview` | BSD-3-Clause; the Flutter Authors | `LICENSE`, `AUTHORS`, `UPSTREAM_SOURCE.json`, `MAASO_PATCH.md` in the component directory |
| Orbitron font, if present under `assets/fonts/Orbitron` | SIL Open Font License 1.1; the Orbitron Project Authors; reserved font name Orbitron | `assets/fonts/Orbitron/OFL.txt` |

The WebView forks preserve their upstream license and document local invocation-isolation modifications. Replacing them with unmodified package releases removes required integration APIs.

## Dependencies resolved during development

`pubspec.yaml` and `pubspec.lock` define the actual dependency set. The entries below highlight terms that affect packaging; they are not a complete software bill of materials.

| Dependency | Observed license / boundary |
| --- | --- |
| `flutter_blue_plus` 2.3.11 | FlutterBluePlus License v1.5. Its license requires a commercial license for use by for-profit organizations. BSD notices also remain relevant to portions identified by that package. This is not an unrestricted MIT/BSD dependency. Consult the installed package's `LICENSE` and `NOTICE.md`. |
| `ffmpeg_kit_flutter_new_min` | LGPL-3.0. Review the exact linked FFmpeg build, corresponding-source and relinking obligations before distributing binaries. A “min” build name does not remove its license requirements. |
| `llamadart`, `llamadart_llama_cpp_flutter` | MIT at the Flutter package layer. Downloaded native artifacts and language-model weights need their own notices and terms. |
| `sherpa_onnx` | Apache-2.0 at the runtime layer. Speech and VAD model files have separate provenance and license requirements. |
| `volc_engine_rtc` | MIT for the Flutter wrapper. Native RTC SDKs and the hosted RTC service have their own terms, accounts and configuration requirements. |
| Firebase, Google ML Kit and platform SDKs | Wrapper packages, native SDKs, service terms and platform requirements must each be considered. No production service entitlement is supplied by this repository. |
| Unity and UniVRM | Unity Editor/player terms apply independently. UniVRM packages retain their upstream licenses. Package references do not convey an avatar or art license. |

Before shipping an application, collect notices from the exact resolved Dart packages and native dependencies, and include the required notices and source offers with the distribution. The root MIT license is not a statement that every optional dependency is suitable for every commercial use.

## Open Annie integration

The Unity integration includes local C# import/playback code referring to Open Annie motion data. The source snapshot omits the motion JSON, baked animations, avatars and artwork.

[Open Annie's upstream notice](https://github.com/rehan-remade/open-annie/blob/main/NOTICE) attributes its code to the open-annie authors under Apache-2.0, and separately identifies its authored motion pack as CC0-1.0. These terms must not be generalized to its avatar models or other assets. If you add upstream code, include its Apache license and relevant notices, and identify modifications. If you import motion data, preserve its provenance and asset license. Local integration code alone does not prove that a missing asset has been licensed or tested.

## Bundled Silero VAD

The [Silero VAD upstream license](https://github.com/snakers4/silero-vad/blob/master/LICENSE) identifies MIT licensing and credits the Silero Team. The sherpa-onnx runtime's Apache license is a separate license. The bundled 643854-byte VAD artifact was byte-for-byte verified against the official sherpa-onnx release download. Its SHA-256, source URL, verification date and the Silero MIT license are retained under `assets/sherpa_models/silero-vad-v5/`. This small detector is the only bundled model; large LLM/ASR/TTS weights are excluded.

## Excluded content

Production credentials, signing material, account data, large LLM/ASR/TTS weights, character models, purchased animations, room assets and private operational records are excluded. The original commercial application's character art and Unity player exports are not licensed through this source release. Supply your own appropriately licensed assets and build your own player exports. Names of third-party products identify integrations and do not imply endorsement.

## Product screenshot media

The README gallery contains rendered product screenshots, separately documented in [the capture notes and credits](docs/media/showcase/README.md). Their depicted character, room and game content is not relicensed by the root MIT license. These reference PNGs do not include or grant redistribution rights to the original 3D assets.
