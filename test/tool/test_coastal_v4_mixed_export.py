"""Portable pure-Python provenance gates for the isolated mixed V4 candidate."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tool/blender/coastal_bedroom_v4/export_mixed_v4.py'
spec = importlib.util.spec_from_file_location('export_mixed_v4_test', SCRIPT)
mixed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mixed)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


class MixedV4ExportTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.baseline_dir = self.root / 'promoted'
        textures = self.baseline_dir / 'Textures'
        textures.mkdir(parents=True)
        names = ['Baked_Floor', 'Baked_BedroomTrim'] + [f'Baked_Old_{i:02}' for i in range(31)]
        materials, artifacts = [], {}
        for name in names:
            relative = f'Textures/{name}.png'
            (self.baseline_dir / relative).write_bytes(name.encode())
            artifacts[relative] = mixed.sha(self.baseline_dir / relative)
            materials.append(dict(name=name, shading='display_baked', texture=relative,
                                  opacity=1, doubleSided=False))
        (self.baseline_dir / 'PersonalSpaceV4.fbx').write_bytes(b'frozen-fbx')
        manifest = dict(status='ready_for_unity', sourceSha256=mixed.OLD_SOURCE,
                        recipeSha256=mixed.OLD_RECIPE,
                        fbxSha256=mixed.sha(self.baseline_dir / 'PersonalSpaceV4.fbx'),
                        materials=materials, artifactHashes=artifacts,
                        meshes=[dict(name=f'Mesh_{i:02}', material=names[i % 33],
                                     sourceObjectNames=[f'Source_{i:02}'], triangles=1)
                                for i in range(96)])
        write_json(self.baseline_dir / 'manifest.json', manifest)
        self.baseline, self.baseline_sha = mixed.require_baseline(
            self.baseline_dir, mixed.sha(self.baseline_dir / 'manifest.json'))

    def test_baseline_hashes_and_manifest_are_checked(self):
        (self.baseline_dir / 'Textures/Baked_Old_00.png').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'texture changed'):
            mixed.require_baseline(self.baseline_dir, self.baseline_sha)
        with self.assertRaisesRegex(ValueError, 'manifest changed'):
            mixed.require_baseline(self.baseline_dir)

    def test_new_atlas_requires_exact_source_recipe_and_color_receipt(self):
        cache = self.root / 'cache'
        old_cache = mixed.CACHE
        mixed.CACHE = cache
        self.addCleanup(setattr, mixed, 'CACHE', old_cache)
        key = 'Floor'
        stamp = dict(source=mixed.NEW_SOURCE, size=4096, samples=64, version=4,
                     unwrapVersion='v4:' + mixed.NEW_RECIPE, freezeVersion=1)
        write_json(cache / f'{key}.json', stamp)
        (cache / f'{key}.exr').write_bytes(b'exr')
        raw = cache / 'undenoised' / f'Baked_{key}.png'
        raw.parent.mkdir(parents=True)
        raw.write_bytes(b'original')
        settings = {'view': 'AgX'}
        write_json(cache / 'undenoised' / f'{key}.control.json',
                   dict(atlas=key, bakeSignature=stamp,
                        exrSha256=mixed.sha(cache / f'{key}.exr'),
                        pngSha256=mixed.sha(raw), colorSettings=settings))
        output = self.root / 'denoised' / f'Baked_{key}.png'
        output.parent.mkdir()
        output.write_bytes(b'oidn')
        (output.parent / f'Raw_{key}.png').write_bytes(b'original')
        receipt = dict(atlas=key, bakeSignature=stamp, sourceMode='exr',
                       sourceSha256=mixed.sha(cache / f'{key}.exr'),
                       originalSha256=mixed.sha(raw), outputSha256=mixed.sha(output),
                       rawControl={'maxDelta': 0, 'pixelsOverOne': 0},
                       colorSettings=settings)
        write_json(output.parent / f'{key}.receipt.json', receipt)
        self.assertEqual(mixed.require_new_receipt(key, output), receipt)
        output.write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'image or color-control'):
            mixed.require_new_receipt(key, output)
        output.write_bytes(b'oidn')
        stamp['source'] = mixed.OLD_SOURCE
        write_json(cache / f'{key}.json', stamp)
        with self.assertRaisesRegex(ValueError, 'source/recipe'):
            mixed.require_new_receipt(key, output)

    def test_lineage_retains_old_source_and_all_texture_hashes(self):
        new = copy.deepcopy(self.baseline)
        new['sourceSha256'] = mixed.NEW_SOURCE
        new['recipeSha256'] = mixed.NEW_RECIPE
        for key in mixed.NEW_GROUPS:
            new['artifactHashes'][f'Textures/Baked_{key}.png'] = '1' * 64
        digests = {row['name']: '2' * 64 for row in new['materials']}
        lineage = mixed.make_lineage(self.baseline, new, self.baseline_sha, digests)
        self.assertEqual(len(lineage), 33)
        self.assertEqual(sum(not row['reused'] for row in lineage.values()), 2)
        for material in new['materials']:
            item = lineage[material['name']]
            self.assertEqual(item['textureHashes'],
                             {path: new['artifactHashes'][path]
                              for path in mixed.texture_paths(material)})
            if material['name'] in ('Baked_Floor', 'Baked_BedroomTrim'):
                self.assertEqual(item['sourceManifestSha256'], '')
                self.assertEqual(item['bakeSourceSha256'], mixed.NEW_SOURCE)
            else:
                self.assertEqual(item['sourceManifestSha256'], self.baseline_sha)
                self.assertEqual(item['bakeRecipeSha256'], mixed.OLD_RECIPE)

    def test_reused_source_object_and_material_changes_fail(self):
        new = copy.deepcopy(self.baseline)
        new['meshes'][2]['sourceObjectNames'] = ['incorrect']
        with self.assertRaisesRegex(ValueError, 'sourceObjectNames'):
            mixed.validate_mesh_rows(self.baseline, new)
        new = copy.deepcopy(self.baseline)
        new['materials'][2]['opacity'] = 0.5
        with self.assertRaisesRegex(ValueError, 'Material recipe changed'):
            mixed.make_lineage(self.baseline, new, self.baseline_sha,
                               {row['name']: '2' * 64 for row in new['materials']})

    def test_texture_path_cannot_escape_candidate(self):
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            mixed.texture_paths({'name': 'bad', 'texture': 'Textures/../secret.png'})


if __name__ == '__main__':
    unittest.main()
