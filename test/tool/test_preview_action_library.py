import importlib.util
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'tool/unity/preview_action_library.py'
spec = importlib.util.spec_from_file_location('preview_actions', TOOL)
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


class PreviewActionLibraryTest(unittest.TestCase):
    def test_native_inventory_matches_pinned_sources_without_fbx_inputs(self):
        project = ROOT / 'unity/masso_avatar'
        records, clips = preview.open_annie_inventory(project)
        self.assertEqual(len(records), 63)
        self.assertEqual(len({clip['id'] for clip in clips}), 63)
        self.assertTrue(all(clip['imported'] and clip['asset'].endswith('.anim') for clip in clips))
        self.assertEqual([clip['id'] for clip in clips[:6]], [
            'annie_wave', 'annie_think', 'annie_dance', 'annie_idle_a', 'annie_listen_a', 'annie_g_offer_r'])
        self.assertEqual(sum(clip['category'] in ('talk', 'phrase') for clip in clips), 40)
        self.assertTrue(all(record['format'] == 'open_annie_native' for record in records))
        self.assertTrue(all(len(record['nativeSha256']) == 64 and record['license'] == 'CC0-1.0' for record in records))
        with patch.object(preview, 'sha256', return_value='mismatch'):
            with self.assertRaisesRegex(ValueError, 'does not match its manifest'):
                preview.open_annie_inventory(project)

    def test_inventory_cli_needs_no_source_directory_and_never_launches_unity(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(TOOL), '--open-annie', '--inventory-only',
                                     '--limit', '6', '--unity-bin', '/missing/unity', '--output-dir', directory],
                                    capture_output=True, text=True, check=True)
            manifest = json.loads((Path(directory) / 'input-manifest.json').read_text())
            self.assertEqual(len(manifest['clips']), 63, 'The render limit must not truncate provenance.')
            self.assertIn('63 installed native', result.stdout)
            self.assertFalse((Path(directory) / 'unity-capture.log').exists())

    def test_cli_rejects_ambiguous_source_and_invalid_limits(self):
        for arguments in [[], ['--open-annie', '--source-dir', '/tmp'],
                          ['--open-annie', '--limit', '0'], ['--open-annie', '--limit', '1001']]:
            result = subprocess.run([sys.executable, str(TOOL), *arguments], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, arguments)

    def test_fbx_inventory_preserves_exact_match_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, project = root / 'source', root / 'project'
            (source / 'emotion').mkdir(parents=True)
            importer = project / 'Assets/MaasoAvatar/Editor/MaasoHumanoidIdleImporter.cs'
            importer.parent.mkdir(parents=True)
            importer.write_text('{ "Wave", "wave" }')
            original = source / 'emotion/Wave.fbx'
            original.write_bytes(b'fixture-fbx')
            native = project / 'Assets/wave.fbx'
            native.write_bytes(original.read_bytes())
            native.with_suffix('.anim').write_text('existing clip')
            records, clips = preview.inventory(source, project)
            self.assertEqual(clips[0]['id'], 'wave')
            self.assertTrue(clips[0]['imported'])
            self.assertEqual(clips[0]['asset'], 'Assets/wave.anim')
            self.assertEqual(records[0]['sha256'], preview.sha256(original))

    def test_render_limit_forwarding_and_failed_process_stage_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / 'tool/unity/action_preview/MaasoActionCatalogBatchCapture.cs'
            template.parent.mkdir(parents=True)
            template.write_text('// template fixture')
            project = root / 'unity/masso_avatar'
            staged = project / 'Assets/MaasoAvatar/Editor/MaasoActionCatalogBatchCapture.cs'
            staged.parent.mkdir(parents=True)
            unity = root / 'fake-unity'
            unity.write_text('not executable; subprocess is mocked')
            entry = {'id': 'annie_wave', 'imported': True}
            with patch.object(preview, '__file__', str(root / 'tool/unity/preview_action_library.py')), \
                    patch.object(preview, 'open_annie_inventory', return_value=([{}], [entry])), \
                    patch.object(sys, 'argv', ['preview', '--open-annie', '--limit', '6', '--unity-bin', str(unity),
                                              '--output-dir', str(root / 'out')]), \
                    patch.object(preview.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'fixture')) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    preview.main()
            command = run.call_args.args[0]
            self.assertEqual(command[command.index('-maasoPreviewLimit') + 1], '6')
            self.assertFalse(staged.exists())
            self.assertFalse(Path(str(staged) + '.meta').exists())

    def test_native_gallery_counts_and_categories_follow_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            clips, records = [], []
            for index, category in enumerate(['idle', 'listen', 'gesture', 'action', 'talk', 'phrase']):
                cid, source = 'annie_fixture_' + str(index), '/fixture/pack/' + str(index) + '.json'
                frames = out / 'frames' / cid
                frames.mkdir(parents=True)
                (frames / 'complete.txt').write_text('2')
                clips.append({'id': cid, 'source': source, 'name': cid, 'category': category, 'fps': 12,
                              'frameCount': 2, 'duration': 1.0, 'asset': 'native.anim', 'imported': True})
                records.append({'source': source, 'sha256': 'a' * 64, 'relative': str(index) + '.json',
                                'format': 'open_annie_native'})
            (out / 'capture.json').write_text(json.dumps({'clips': clips}))
            (out / 'source-inventory.json').write_text(json.dumps(records))
            encoded = json.dumps({'streams': [{'nb_frames': '2', 'width': 480, 'height': 640, 'duration': '.167'}]})
            with patch.object(sys, 'argv', ['gallery', str(out)]), \
                    patch('shutil.which', side_effect=lambda value: value), \
                    patch('subprocess.run'), patch('subprocess.check_output', return_value=encoded):
                runpy.run_path(str(ROOT / 'tool/unity/action_preview/build_gallery.py'), run_name='__main__')
            document = (out / 'index.html').read_text()
            self.assertIn('全部 6', document)
            self.assertIn('6 个原生动作', document)
            self.assertNotIn('全部 29', document)
            self.assertIn('原始动作 JSON', document)
            self.assertIn('data-filter="phrase"', document)
            self.assertIn('上半身素材叠在基础 idle', document)
            self.assertIn('Foot IK disabled', json.loads((out / 'catalog.json').read_text())['render'])

    def test_contact_sheets_cover_native_lower_and_upper_body_categories(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            clips = []
            for category in ['idle', 'fidget', 'listen', 'gesture', 'action', 'talk', 'phrase']:
                cid = 'annie_' + category
                clips.append({'id': cid, 'name': cid, 'category': category, 'duration': 1.0})
                for frame in range(5):
                    Image.new('RGB', (8, 8), (250, 250, 250)).save(out / f'{cid}-{frame}.png')
            (out / 'capture.json').write_text(json.dumps({'clips': clips}))
            with patch.object(sys, 'argv', ['contact-sheets', str(out)]):
                runpy.run_path(str(ROOT / 'tool/unity/action_preview/contact_sheets.py'), run_name='__main__')
            self.assertEqual(len(list((out / 'contact-sheets').glob('annie-*.jpg'))), 7)


if __name__ == '__main__':
    unittest.main()
