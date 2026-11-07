# Original Maaso Home and login resources

This edition retains the original Coastal V4 runtime resource closure,
original Home/login poster bytes, room camera and depth-of-field settings.
Only the character is replaced with the separately licensed free Pixiv VRM.
No original paid character or motion pack is included in this room closure.

The room geometry was authored for Maaso in Blender. Texture source records
identify five PBR groups from Poly Haven and ambientCG under CC0-1.0;
`docs/assets/coastal-texture-provenance.json` retains their source URLs,
authors and downloaded-map hashes. Their current source license pages are:

- https://polyhaven.com/license
- https://docs.ambientcg.com/license/

Maaso-authored baked atlases, window/sea imagery and volumetric cloud resources
are included as runtime presentation assets. The exact 167 room assets and
metadata are hash-pinned in `original-room-assets.json`. The FBX geometry is
also an exact-path/checksum exception in the public-export checker; other raw
models remain rejected. Original character models remain excluded.

Home and login posters are pinned in `generated-scene-assets.json` and are
protected from placeholder regeneration. The former generic primitive doorway
was an incorrect migration substitute and is no longer used.
