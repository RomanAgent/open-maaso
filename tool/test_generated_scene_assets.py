"""Keep real login artwork outside the legacy placeholder regeneration path."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import generate_placeholder_assets as generator


class GeneratedSceneAssetsTests(unittest.TestCase):
    def test_regeneration_preserves_real_login_render_and_check_detects_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            brand = root / "assets/brand"
            brand.mkdir(parents=True)
            poster = brand / "login_doorway.png"
            poster.write_bytes(b"reviewed procedural doorway render")
            icon = root / "windows/runner/resources/app_icon.ico"
            icon.parent.mkdir(parents=True)
            icon.write_bytes(b"official brand icon")
            (brand / "official-launcher-assets.json").write_text(json.dumps({
                "windows/runner/resources/app_icon.ico": hashlib.sha256(icon.read_bytes()).hexdigest(),
            }))
            (brand / "generated-scene-assets.json").write_text(json.dumps({
                "assets/brand/login_doorway.png": hashlib.sha256(poster.read_bytes()).hexdigest(),
            }))
            outputs = (
                ("assets/brand/home_room.png", 1, 1, "background"),
                ("assets/brand/login_doorway.png", 1, 1, "background"),
                ("assets/model_store/agent.png", 1, 1, "icon"),
            )
            with mock.patch.object(generator, "__file__", str(root / "tool/generator.py")), mock.patch.object(generator, "OUTPUTS", outputs):
                with mock.patch("sys.argv", ["generator"]):
                    self.assertEqual(generator.main(), 0)
                self.assertEqual(poster.read_bytes(), b"reviewed procedural doorway render")
                self.assertEqual(icon.read_bytes(), b"official brand icon")
                with mock.patch("sys.argv", ["generator", "--check"]):
                    self.assertEqual(generator.main(), 0)
                    poster.write_bytes(b"incorrect replacement")
                    self.assertEqual(generator.main(), 1)


if __name__ == "__main__":
    unittest.main()
