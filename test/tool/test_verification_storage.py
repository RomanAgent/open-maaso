import importlib.util
from pathlib import Path
import plistlib
import tempfile
import time
import unittest


SPEC = importlib.util.spec_from_file_location(
    "verification_storage", Path(__file__).resolve().parents[2] / "tool/verification_storage.py"
)
storage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(storage)


class VerificationStorageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(self.temporary.cleanup)

    def group(self, name, method="debugging"):
        group = self.root / name / "device-build"
        group.mkdir(parents=True)
        (group / "ExportOptions.plist").write_bytes(plistlib.dumps({"method": method}))
        (group / "receipt.json").write_text('{"installed":true}')
        archive = group / "Runner.xcarchive"
        (archive / "Products/Applications").mkdir(parents=True)
        (archive / "Info.plist").write_bytes(plistlib.dumps({"ArchiveVersion": 2}))
        (archive / "generated-data").write_bytes(b"binary")
        payload = group / "development-device/Payload/Runner.app"
        payload.mkdir(parents=True)
        (payload / "Info.plist").write_bytes(plistlib.dumps({"CFBundleName": "Runner"}))
        export = group / "development-export"
        export.mkdir()
        (export / "Runner.ipa").write_bytes(b"archive")
        return group

    def proposal(self):
        # All test fixtures old enough; disable group retention to exercise filters.
        return storage.inventory(self.root, keep_newest=0, now=time.time() + 172800)

    def test_only_generated_bundles_and_no_mutation(self):
        group = self.group("old")
        (group / "unique-script.py").write_text("print('evidence')")
        (group / "previous-unity-export").mkdir()
        result = self.proposal()
        self.assertEqual(len(result["candidates"]), 3)
        self.assertTrue(all(Path(item["path"]).exists() for item in result["candidates"]))
        self.assertTrue((group / "receipt.json").exists())
        self.assertFalse(any("unity" in item["path"] for item in result["candidates"]))

    def test_unknown_and_shipping_exports_preserved(self):
        for name, method in (("store", "app-store-connect"), ("adhoc", "release-testing")):
            self.group(name, method)
        missing = self.group("missing")
        (missing / "ExportOptions.plist").unlink()
        self.assertEqual(self.proposal()["candidates"], [])

    def test_git_worktree_and_nested_git_preserved(self):
        worktree = self.group("checkout")
        (worktree.parent / ".git").write_text("gitdir: elsewhere")
        group = self.group("nested")
        (group / "Runner.xcarchive/.git").mkdir()
        paths = [item["path"] for item in self.proposal()["candidates"]]
        self.assertFalse(any("checkout" in path or ".xcarchive" in path for path in paths))

    def test_symlink_boundaries_preserved(self):
        original = self.group("original")
        (original.parent / ".keep").touch()
        (self.root / "linked").symlink_to(original.parent, target_is_directory=True)
        group = self.group("another")
        (group / "linked-Runner.xcarchive").symlink_to(original / "Runner.xcarchive")
        paths = [item["path"] for item in self.proposal()["candidates"]]
        self.assertEqual(len(paths), 3)
        self.assertTrue(all("another" in path for path in paths))

    def test_keep_marker_and_newest_two_groups(self):
        self.group("old")
        protected = self.group("protected")
        (protected / ".keep").touch()
        self.group("new")
        result = storage.inventory(self.root, keep_newest=2, now=time.time() + 172800)
        self.assertEqual(result["candidates"], [])

    def test_recent_changes_protected(self):
        self.group("active")
        result = storage.inventory(self.root, keep_newest=0)
        self.assertEqual(result["candidates"], [])
        self.assertEqual(result["kept"][0]["reason"], "changed within retention age")

    def test_in_progress_empty_group_does_not_evict_latest_complete_bundles(self):
        self.group("complete-one")
        self.group("complete-two")
        active = self.root / "active/device-build"
        active.mkdir(parents=True)
        (active / "ExportOptions.plist").write_bytes(
            plistlib.dumps({"method": "debugging"})
        )
        result = storage.inventory(self.root, keep_newest=2, now=time.time() + 172800)
        self.assertEqual(result["candidates"], [])

    def test_mixed_store_and_development_group_preserved(self):
        group = self.group("mixed")
        (group / "StoreExportOptions.plist").write_bytes(
            plistlib.dumps({"method": "app-store-connect"})
        )
        self.assertEqual(self.proposal()["candidates"], [])

    def test_generated_name_without_bundle_structure_preserved(self):
        group = self.group("old")
        (group / "notes-Runner.xcarchive").mkdir()
        (group / "development-device/Payload/source.app").mkdir()
        self.assertEqual(len(self.proposal()["candidates"]), 3)


if __name__ == "__main__":
    unittest.main()
