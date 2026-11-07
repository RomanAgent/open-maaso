# Public-release asset policy

The native launcher and splash assets use the official monochrome Maaso mark,
with its original black ring/star geometry and transparent logo background.
`assets/brand/official-launcher-assets.json` records the reviewed paths and
SHA-256 hashes. These brand assets contain no character or room artwork.

The original `assets/brand/home_room.png` and `login_doorway.png` are retained
byte-for-byte from Maaso. The runtime uses the original Coastal V4 room and
shared entry resources, rather than a generic floor or replacement doorway.
The room geometry is Maaso-authored; its PBR inputs have recorded CC0-1.0
provenance. See [the room asset notice](../../assets/brand/original-room.PROVENANCE.md)
and [texture provenance](../assets/coastal-texture-provenance.json).

Only `assets/model_store/agent.png` remains a generated legacy fallback icon.
The active free-VRM cover is a verified full-body render, with its own model
license notice.

## Check the assets

```bash
python3 tool/generate_placeholder_assets.py --check
```

The standard-library generator recreates only the legacy model-store fallback.
`--check` verifies the official launcher/splash manifest and the reviewed
`generated-scene-assets.json` hashes. Regeneration preserves the real login
poster, official icons, model cover and free model. Scene renders require
their documented Unity capture; they must not be replaced with placeholders.

The README hero follows Maaso White Frost v2: a pure-white canvas, neutral text, a borderless muted capsule, and small reference-blue accents. It uses the official Maaso logo from `assets/brand/masso_monochrome_logo.svg` with a transparent background at the project owner's request. The original circle and star geometry are preserved; the white background rectangle and invisible filter are removed. The black ring and four-point star replace the temporary open-maaso lettermark. The hero composition remains an illustration, not an application screenshot or evidence of a completed avatar/native rendering experience. The native launcher/splash set uses the same official mark.

## Product screenshots

`showcase/` contains unedited native iPhone screenshots captured from the installed Maaso app on November 1, 2026. They are reference product media, separate from the generated placeholder set and its regeneration script. The screenshots depict separately licensed characters. Those character sources are not included or relicensed by the repository's MIT license. The reviewed room geometry and CC0 texture derivatives are documented separately. Capture provenance, observed screen states and asset credits are recorded in [showcase/README.md](showcase/README.md).

## Adding real content

Supply artwork and models with documented rights to use and redistribute. Preserve attribution and any third-party terms. Character model covers must be actual full-body renders showing the complete head, hands, and feet; do not present an abstract placeholder or a cropped diagnostic as a model cover.

Original paid characters, purchased motions and generated Unity players remain outside this public source release. The reviewed Maaso room and CC0 texture derivatives are included. The MIT license for project-owned source does not grant rights to those excluded materials or to independently obtained third-party content. See [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
