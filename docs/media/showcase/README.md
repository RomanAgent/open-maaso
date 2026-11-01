# Maaso product screenshots

These are real, unedited native screenshots of the installed Maaso iPhone app, captured on **2026-11-01 (Asia/Shanghai)**. They are not generated concept images, UI test fixtures, or screenshots of a freshly built open-maaso checkout.

The user operated the iPhone Mirroring unlock. UI navigation used the actual app. After a mirroring input failure, the user manually opened Snake, the arcade shooter, and its companion panel. Xcode's device capture command recorded the active iPhone display directly as PNG. No image crop, retouch, synthetic interface, added chat text, or composited character was used. Each source image is 1179 × 2556 pixels and remains byte-for-byte identical to the native capture.

## What each image shows

| File | Observed screen | Scope |
| --- | --- | --- |
| `home.png` | Home with the selected Avatar, room and composer | Current product UI |
| `game-request.png` | Composer containing the public demo prompt “Create a rocket game” | Creation request input; not a completed generation |
| `mini-games.png` | My Games library with existing saved games | Actual saved-game library, with original displayed values |
| `gameplay.png` | Snake running in the game player | Existing playable work opened by the user; not the result of the new rocket prompt |
| `space-shooter.png` | A vertical arcade shooter, identified by the user as 雷霆战机, running in the player | Existing playable work opened by the user |
| `game-companion.png` | “Play together” companion settings opened from the shooter | Controls for companionship, voice, chat frequency and hints; not a recorded voice conversation or autonomous play demonstration |

These captures are separate UI states, not a claimed single successful prompt-to-game-to-voice session. Live voice quality, autonomous game success, backend deployment and a clean-clone native build were not evaluated by this screenshot task. Running the open-source client still requires its documented backend and asset prerequisites.

## Privacy and provenance

Visible content was checked for credentials, contact details, account identifiers, private messages and notifications. The only entered prompt is the public demonstration text above. PNG metadata contains color-space and image dimensions; no GPS, owner, device serial or text metadata was found. Device identifiers and raw device receipts are not published.

| File | SHA-256 |
| --- | --- |
| `home.png` | `4871b40a68c3d0280004028ef671096bd4550f386ab420e7146e21d4522dbb4e` |
| `game-request.png` | `b06578cb5ed48b13954e929d0adbebee9cf1760cf7886f0ac596bcdfa1123d9e` |
| `gameplay.png` | `172115ddf5d17457bb37d6c47d1f349f5acfe45123e84538064df028480ef425` |
| `space-shooter.png` | `33043d8852887d943e546fc211ec6099a4ebd57272d9527c15aaab4684200a16` |
| `game-companion.png` | `22535e5a9ff63e452076f184518235f26955d63fb8688f65703e386d5eac9550` |
| `mini-games.png` | `9e9fde3bdacd2feeacb76fb2a2c8e89e834cfb26196ffde6ae6f2c39aa4b5caf` |

## Asset credits and scope

The screenshots depict Maaso product content. The Joy character is by **bologendheng**: [Joy — Rigged Sportswear Collection](https://www.cgtrader.com/3d-models/character/woman/joy-rigged-sportswear-collection). The character, room and game content have their own applicable terms. The source repository's MIT license does not relicense depicted third-party assets, and their 3D models, textures and Unity bundles are not distributed here. These PNGs are provided as product-reference screenshots at the project owner's request.

Keep these captures distinct from project-owned source, neutral generated placeholders, and independently obtained third-party content. See [THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md) and the [asset policy](../asset-policy.md).
