# Public-release asset policy

The native launcher and splash assets use the official monochrome Maaso mark,
with its original black ring/star geometry and transparent logo background.
`assets/brand/official-launcher-assets.json` records the reviewed paths and
SHA-256 hashes. These brand assets contain no character or room artwork.

Only two legacy fallback files remain generated placeholders:
`assets/brand/home_room.png` and `assets/model_store/agent.png`.
Their compatibility filenames are retained; they are not model covers.
`assets/brand/login_doorway.png` is a real render of the project-owned
procedural doorway used by the original login transition. Its source and
capture provenance are recorded in
[login-doorway.PROVENANCE.md](../../assets/brand/login-doorway.PROVENANCE.md).
The active free-VRM cover is `assets/brand/offline_avatar_preview.png`, a real
full-body Unity render showing the head, hands and feet.

## Check the assets

```bash
python3 tool/generate_placeholder_assets.py --check
```

The standard-library generator recreates only the two legacy placeholders.
`--check` verifies the official launcher/splash manifest and the reviewed
`generated-scene-assets.json` hashes. Regeneration preserves the real login
poster, official icons, model cover and free model. Scene renders require
their documented Unity capture; they must not be replaced with placeholders.

The README hero follows Maaso White Frost v2: a pure-white canvas, neutral text, a borderless muted capsule, and small reference-blue accents. It uses the official Maaso logo from `assets/brand/masso_monochrome_logo.svg` with a transparent background at the project owner's request. The original circle and star geometry are preserved; the white background rectangle and invisible filter are removed. The black ring and four-point star replace the temporary open-maaso lettermark. The hero composition remains an illustration, not an application screenshot or evidence of a completed avatar/native rendering experience. The native launcher/splash set uses the same official mark.

## Product screenshots

`showcase/` contains unedited native iPhone screenshots captured from the installed Maaso app on November 1, 2026. They are reference product media, separate from the generated placeholder set and its regeneration script. The screenshots depict separately licensed character and room content; those 3D sources are not included or relicensed by the repository's MIT license. Capture provenance, observed screen states and asset credits are recorded in [showcase/README.md](showcase/README.md).

## Adding real content

Supply artwork and models with documented rights to use and redistribute. Preserve attribution and any third-party terms. Character model covers must be actual full-body renders showing the complete head, hands, and feet; do not present an abstract placeholder or a cropped diagnostic as a model cover.

Original licensed characters, room assets, and generated Unity players are intentionally outside this public release. The MIT license for project-owned source does not grant rights to those excluded materials or to independently obtained third-party content. See [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
