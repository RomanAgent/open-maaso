# Original Maaso Coastal V4 room

This is the original room and shared entrance used by Maaso, restored without
changing its meshes, materials, textures, camera anchors or runtime prefabs.
It replaces the temporary generic floor/doorway used during the local-port work.
The human avatar remains the independently licensed free Pixiv VRM.

## Geometry and generated content

The Maaso project authored the room in Blender from a user-provided design
reference. Its original construction scripts are under
`tool/blender/coastal_v2/` and `tool/blender/coastal_bedroom_v4/` in the source
project. V4 extends that same living room with the existing bedroom and shared
entry. The promoted runtime manifest identifies 96 room meshes and the
reviewed FBX, not an avatar model:

- `PersonalSpaceV4.fbx`: SHA-256
  `e935d7d37436e74e32f58cd0e3e899a8da7096c290d0a01b9e065c43863ea8d5`
- Original authoring source identity in the promoted manifest:
  `a18e70d228ca51155bae0a4ea6a492ac691a76af00c5b08a9bcad119b1e065d0`

The seascape backdrop was generated for this project; it is not a photograph
of a specified location. Wall art, furniture, plants, entry lettering and
the volumetric-cloud resources are project-authored/generated content.
The authoring `.blend` and raw texture downloads are not required by the
runtime player and are not duplicated in this runtime asset set.

## Texture sources

`UPSTREAM_TEXTURE_SOURCES.json` preserves the original source URLs, authors,
licenses and checksums. All 23 listed source maps were checked against their
local source SHA-256 values before restoring this runtime set. The five
upstream materials are:

| Material | Source | Terms |
| --- | --- | --- |
| Rough Linen | Poly Haven | CC0-1.0 |
| Oak Veneer 01 | Poly Haven | CC0-1.0 |
| White Plaster 02 | Poly Haven | CC0-1.0 |
| Hessian 380 | Poly Haven | CC0-1.0 |
| Travertine009 | ambientCG | CC0-1.0 |

Their official asset terms permit use and redistribution of the asset files,
including commercial use: [Poly Haven](https://polyhaven.com/license),
[ambientCG](https://docs.ambientcg.com/license/). These CC0 terms apply to the
referenced source materials; Maaso's authored geometry/code and the separate
Pixiv character retain their respective project/model terms.

The earlier blanket description of this room as excluded licensed artwork
was based on a generic script comment, not these actual source terms.
No original paid character, purchased motion or operational credential is
included in this room set.
