"""Boundary tests for public-export checks; all token material is synthetic."""

import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from check_public_export import (
    check_repository, content_findings, forbidden_path, LICENSED_MODELS, PUBLIC_FIXTURES,
)


class PublicExportTests(unittest.TestCase):
    def test_official_avatar_has_exact_reviewed_bytes_and_redistribution_metadata(self):
        name = "unity/masso_avatar/Assets/MaasoAvatar/Models/Default/OpenMaaso.vrm"
        root = Path(__file__).resolve().parents[1]
        data = (root / name).read_bytes()
        self.assertIsNone(forbidden_path(name))
        self.assertEqual(content_findings(name, data), [])
        self.assertEqual(
            content_findings(name, data[:-1] + bytes([data[-1] ^ 1])),
            [(name, 0, "licensed-model-checksum")],
        )
        self.assertIsNotNone(forbidden_path("assets/unreviewed-avatar.vrm"))
        magic, version, total = struct.unpack_from("<4sII", data)
        self.assertEqual((magic, version, total), (b"glTF", 2, len(data)))
        length, chunk_kind = struct.unpack_from("<II", data, 12)
        self.assertEqual(chunk_kind, 0x4E4F534A)
        document = json.loads(data[20:20 + length])
        model = document["extensions"]["VRMC_vrm"]
        self.assertEqual(model["specVersion"], "1.0")
        meta = model["meta"]
        self.assertEqual(meta["authors"], ["pixiv Inc."])
        self.assertEqual(meta["licenseUrl"], "https://vrm.dev/licenses/1.0/")
        self.assertTrue(meta["allowRedistribution"])
        self.assertEqual(meta["avatarPermission"], "everyone")
        self.assertEqual(meta["commercialUsage"], "corporation")
        self.assertEqual(meta["modification"], "allowModificationRedistribution")
        self.assertFalse(meta["allowAntisocialOrHateUsage"])
        self.assertIn("hips", model["humanoid"]["humanBones"])
        self.assertFalse(any(item.get("uri") for item in document.get("buffers", [])))
        self.assertFalse(any(item.get("uri") for item in document.get("images", [])))

    def test_private_inputs_and_unreviewed_models_are_rejected(self):
        for name in (
            ".store-release-secrets/account.json", "build/log.txt",
            ".env", ".env.production", "secrets.env", "keys/upload.p8",
            "ios/key.mobileprovision", "android/key.properties",
            "android/app/google-services.json", "ios/Runner/GoogleService-Info.plist",
            "assets/private.vrm", "assets/private.gguf", "assets/unknown.onnx",
            "../outside.txt",
        ):
            with self.subTest(name=name):
                self.assertIsNotNone(forbidden_path(name))

    def test_templates_and_reviewed_licensed_model_are_allowed(self):
        for name in (
            ".env.example", ".env.production.template", "docs/setup.md",
            "android/app/google-services.json.example", "lib/main.dart",
            next(iter(LICENSED_MODELS)),
        ):
            with self.subTest(name=name):
                self.assertIsNone(forbidden_path(name))

    def test_tokens_and_machine_paths_are_reported_without_values(self):
        samples = (
            ("sk-" + "A9b_" * 8, "provider-token"),
            ("ghp_" + "A9b" * 12, "provider-token"),
            ("AIza" + "A9b_" * 9, "provider-token"),
            ("-----BEGIN " + "PRIVATE KEY-----", "private-key"),
            ("eyJ" + "A" * 12 + "." + "B" * 12 + "." + "C" * 12, "jwt"),
            ("/Users/" + "sample/project/file.dart", "machine-path"),
            ("/home/" + "sample/project/file.dart", "machine-path"),
            ("C:" + "\\Users\\sample\\project", "machine-path"),
        )
        for sample, category in samples:
            with self.subTest(category=category):
                result = content_findings("lib/example.dart", ("safe\n" + sample).encode())
                self.assertIn(("lib/example.dart", 2, category), result)
                self.assertNotIn(sample, repr(result))

    def test_task_names_storage_keys_and_dynamic_auth_are_not_tokens(self):
        source = (
            "com.example.scheduled-task-v4-global-cleanup-journal-source-fault.v1\n"
            "schema: tripo-task-cleanup-local-generated-assets/1\n"
            "authorization: 'Bearer $accessToken'\n"
            "keyLlmApiKey = 'llm_api_key'\n"
            "import 'package:maaso/src/features/home/application/home.dart';\n"
        )
        self.assertEqual(content_findings("lib/example.dart", source.encode()), [])

    def test_reviewed_model_must_keep_its_exact_bytes(self):
        name = next(iter(LICENSED_MODELS))
        self.assertEqual(
            content_findings(name, b"replaced model"),
            [(name, 0, "licensed-model-checksum")],
        )
        root = Path(__file__).resolve().parents[1]
        self.assertEqual(hashlib.sha256((root / name).read_bytes()).hexdigest(), LICENSED_MODELS[name])

    def test_dummy_fixture_exception_cannot_hide_another_token(self):
        name = "test/action_audit_log_test.dart"
        fixture = next(iter(PUBLIC_FIXTURES[(name, "provider-token")])).encode()
        self.assertEqual(content_findings(name, fixture), [])
        self.assertEqual(len(content_findings("lib/other.dart", fixture)), 1)
        replaced = ("const secret = '" + "sk-" + "A9b_" * 8 + "';").encode()
        self.assertEqual(content_findings(name, replaced), [(name, 1, "provider-token")])

    def test_privacy_path_fixtures_are_exact_and_path_scoped(self):
        name = "test/server_request_failure_log_test.dart"
        for fixture in PUBLIC_FIXTURES[(name, "machine-path")]:
            self.assertEqual(content_findings(name, fixture.encode()), [])
            self.assertTrue(content_findings("lib/production.dart", fixture.encode()))
        changed = ("const localPath = '" + "/Users/" + "another/private.dart';").encode()
        self.assertEqual(content_findings(name, changed), [(name, 1, "machine-path")])

    def test_scan_is_tracked_only_and_refuses_parent_repository(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            with self.assertRaises(ValueError):
                check_repository(root)
            (root / "safe.txt").write_text("no credentials here\n")
            (root / ".env").write_text("private local settings\n")
            subprocess.run(["git", "-C", str(root), "add", "safe.txt"], check=True)
            self.assertEqual(check_repository(root), (1, []))
            subprocess.run(["git", "-C", str(root), "add", ".env"], check=True)
            count, findings = check_repository(root)
            self.assertEqual(count, 2)
            self.assertIn((".env", 0, "environment-secrets"), findings)
            child = root / "nested"
            child.mkdir()
            with self.assertRaises(ValueError):
                check_repository(child)


if __name__ == "__main__":
    unittest.main()
