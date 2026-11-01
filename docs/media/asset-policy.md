# Public-release asset policy

This source release uses original geometric placeholders in place of the original application's branded images, room pictures, launcher artwork, splash images, and generic model-store fallback image. The replacement set consists of a blue circular mark with a white square, or a neutral white-to-blue background. These generated placeholder files contain no original character pixels, room artwork, purchased content, or model renders.

The existing filenames and pixel dimensions are retained so application and native asset references remain valid. Compatibility names such as `home_room.png`, `login_doorway.png`, and `assets/model_store/agent.png` describe their historical code locations; the public placeholder files do not contain a room, a doorway, or a character. The model-store image is an abstract fallback icon, not a model cover or evidence of a full-body render.

## Recreate the placeholders

Run from the repository root with Python 3.10 or newer:

```bash
python3 tool/generate_placeholder_assets.py
python3 tool/generate_placeholder_assets.py --check
```

The generator uses only the Python standard library. It contains a table of output paths and dimensions and draws the pixels from geometric formulas. It does not fetch network resources, load an original image, require a font, or depend on a private checkout. The Windows ICO contains multiple sizes of the same newly generated mark.

The first command overwrites every path listed in the generator, including the Windows ICO. Keep custom artwork elsewhere or commit your changes before regenerating. `--check` performs an exact byte comparison against the deterministic generated outputs without changing files.

The README hero follows Maaso White Frost v2: a pure-white canvas, neutral text, a borderless muted capsule, and small reference-blue accents. It uses the official Maaso logo from `assets/brand/masso_monochrome_logo.svg` with a transparent background at the project owner's request. The original circle and star geometry are preserved; the white background rectangle and invisible filter are removed. The black ring and four-point star replace the temporary open-maaso lettermark. The hero composition remains an illustration, not an application screenshot or evidence of a completed avatar/native rendering experience. The generated application placeholder set described above is separate from this official documentation logo.

## Product screenshots

`showcase/` contains unedited native iPhone screenshots captured from the installed Maaso app on November 1, 2026. They are reference product media, separate from the generated placeholder set and its regeneration script. The screenshots depict separately licensed character and room content; those 3D sources are not included or relicensed by the repository's MIT license. Capture provenance, observed screen states and asset credits are recorded in [showcase/README.md](showcase/README.md).

## Adding real content

Supply artwork and models with documented rights to use and redistribute. Preserve attribution and any third-party terms. Character model covers must be actual full-body renders showing the complete head, hands, and feet; do not present an abstract placeholder or a cropped diagnostic as a model cover.

Original licensed characters, room assets, and generated Unity players are intentionally outside this public release. The MIT license for project-owned source does not grant rights to those excluded materials or to independently obtained third-party content. See [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
