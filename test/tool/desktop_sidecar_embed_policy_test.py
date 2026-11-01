"""Execute the real embed phase against disposable, minimal macOS exports."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "macos/embed_unity_sidecar.sh"


class SidecarEmbedPolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="maaso-helper-policy-")
        self.root = Path(self.temp.name)
        self.app = self.root / "unity/masso_avatar/Builds/macOS/MaasoAvatar.app"
        self.data = self.app / "Contents/Resources/Data"
        self.data.mkdir(parents=True)
        executable = self.app / "Contents/MacOS/MaasoAvatar"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture, never executed\n")
        executable.chmod(0o700)
        paths = re.search(
            r"protocol_source_paths='([^']+)'", SCRIPT.read_text()
        ).group(1).splitlines()
        digest = hashlib.sha256()
        for relative in paths:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = (relative + "\n").encode()
            path.write_bytes(payload)
            digest.update(relative.encode() + b"\0" + payload + b"\0")
        (self.data / "maaso-sidecar-protocol.sha256").write_text(
            digest.hexdigest() + "\n"
        )
        self.output = self.root / "output"
        self.destination = self.output / "Maaso.app/Contents/Helpers/MaasoAvatar.app"
        self.environment = {
            **os.environ,
            "SRCROOT": str(self.root / "macos"),
            "TARGET_BUILD_DIR": str(self.output),
            "CONTENTS_FOLDER_PATH": "Maaso.app/Contents",
            "CONFIGURATION": "Debug",
            "MAASO_REQUIRE_UNITY_SIDECAR": "1",
            "CODE_SIGNING_ALLOWED": "NO",
        }

    def tearDown(self):
        self.temp.cleanup()

    def embed(self, properties):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(properties))
        return subprocess.run(
            ["/bin/sh", str(SCRIPT)],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_rejects_regular_and_wrongly_typed_helpers_before_copy(self):
        for value in (None, False, "true", 1):
            with self.subTest(value=value):
                properties = {"CFBundleIdentifier": "com.futurpals.maaso.avatar-sidecar"}
                if value is not None:
                    properties["LSUIElement"] = value
                result = self.embed(properties)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("background UI agent", result.stderr)
                self.assertFalse(self.destination.exists())

    def test_rejects_default_unity_identity_before_copy(self):
        result = self.embed({
            "LSUIElement": True,
            "CFBundleIdentifier": "com.DefaultCompany.3D-Project",
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_embeds_agent_without_changing_unity_startup_properties(self):
        properties = {
            "LSUIElement": True,
            "CFBundleIdentifier": "com.futurpals.maaso.avatar-sidecar",
            "NSPrincipalClass": "PlayerApplication",
            "NSMainNibFile": "MainMenu",
        }
        result = self.embed(properties)
        self.assertEqual(result.returncode, 0, result.stderr)
        copied = plistlib.loads((self.destination / "Contents/Info.plist").read_bytes())
        self.assertEqual(copied, properties)
        self.assertEqual(
            (self.destination / "Contents/Resources/Data/maaso-sidecar-protocol.sha256").read_bytes(),
            (self.data / "maaso-sidecar-protocol.sha256").read_bytes(),
        )


if __name__ == "__main__":
    unittest.main()
