import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

from tool.unity.import_modular_anime_character import (
    DEFAULT_ROOT_ASSET_PATHS,
    import_assets,
)


class ModularAnimeCharacterImportTest(unittest.TestCase):
    def test_default_roots_only_publish_the_retained_female_look(self) -> None:
        self.assertEqual(
            DEFAULT_ROOT_ASSET_PATHS,
            (
                "Assets/Rukha93/ModularAnimeCharacter/Prefabs/F_FullBody.prefab",
                "Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/F_top.010_shirtandtie.fbx",
                "Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/F_bot.004_skinnyjeans.fbx",
                "Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/F_shoes.006_lowsneakers.fbx",
                "Assets/Rukha93/ModularAnimeCharacter/Prefabs/HairStyles/C_hair_medium.001.prefab",
            ),
        )

    def test_imports_only_reachable_assets_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            package_path = root / "fixture.unitypackage"
            project_path = root / "UnityProject"
            shared_guid = "b" * 32
            texture_guid = "d" * 32

            self._write_package(
                package_path,
                {
                    "a" * 32: (
                        "Assets/Vendor/Female.prefab",
                        f"female references guid: {shared_guid}\n".encode(),
                    ),
                    "c" * 32: (
                        "Assets/Vendor/Male.prefab",
                        f"male references guid: {shared_guid}\n".encode(),
                    ),
                    shared_guid: (
                        "Assets/Vendor/Shared.mat",
                        (
                            'material references {"guid": "'
                            f'{texture_guid}"'
                            "}\n"
                        ).encode(),
                    ),
                    texture_guid: (
                        "Assets/Vendor/Shared.png",
                        b"png fixture",
                    ),
                    "e" * 32: (
                        "Assets/Vendor/Unused.asset",
                        b"unused",
                    ),
                },
            )

            first = import_assets(
                package_path=package_path,
                project_path=project_path,
                root_asset_paths=(
                    "Assets/Vendor/Female.prefab",
                    "Assets/Vendor/Male.prefab",
                ),
            )
            second = import_assets(
                package_path=package_path,
                project_path=project_path,
                root_asset_paths=(
                    "Assets/Vendor/Female.prefab",
                    "Assets/Vendor/Male.prefab",
                ),
            )

            self.assertEqual(first, second)
            self.assertEqual(
                first["assets"],
                [
                    "Assets/Vendor/Female.prefab",
                    "Assets/Vendor/Male.prefab",
                    "Assets/Vendor/Shared.mat",
                    "Assets/Vendor/Shared.png",
                ],
            )
            self.assertTrue((project_path / "Assets/Vendor/Female.prefab").is_file())
            self.assertTrue(
                (project_path / "Assets/Vendor/Female.prefab.meta").is_file()
            )
            self.assertEqual(
                (project_path / "Assets/Vendor/Shared.png").read_bytes(),
                b"png fixture",
            )
            self.assertFalse(
                (project_path / "Assets/Vendor/Unused.asset").exists()
            )
            manifest = json.loads(
                (
                    project_path
                    / "Assets/MaasoAvatar/Characters/ModularAnime/import_manifest.json"
                ).read_text()
            )
            self.assertEqual(manifest, first)

    def test_removes_assets_from_the_previous_managed_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            package_path = root / "fixture.unitypackage"
            project_path = root / "UnityProject"
            self._write_package(
                package_path,
                {
                    "a" * 32: (
                        "Assets/Vendor/Female.prefab",
                        b"female",
                    ),
                    "b" * 32: (
                        "Assets/Vendor/Male.prefab",
                        b"male",
                    ),
                    "c" * 32: (
                        "Assets/Vendor/Unused.prefab",
                        b"unused",
                    ),
                },
            )

            import_assets(
                package_path=package_path,
                project_path=project_path,
                root_asset_paths=(
                    "Assets/Vendor/Female.prefab",
                    "Assets/Vendor/Male.prefab",
                    "Assets/Vendor/Unused.prefab",
                ),
            )
            self.assertTrue(
                (project_path / "Assets/Vendor/Unused.prefab").is_file()
            )

            import_assets(
                package_path=package_path,
                project_path=project_path,
                root_asset_paths=(
                    "Assets/Vendor/Female.prefab",
                    "Assets/Vendor/Male.prefab",
                ),
            )

            self.assertFalse(
                (project_path / "Assets/Vendor/Unused.prefab").exists()
            )
            self.assertFalse(
                (project_path / "Assets/Vendor/Unused.prefab.meta").exists()
            )

    def test_rejects_unsafe_package_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            package_path = root / "unsafe.unitypackage"
            self._write_package(
                package_path,
                {
                    "a" * 32: (
                        "Assets/../escaped.prefab",
                        b"unsafe",
                    ),
                },
            )

            with self.assertRaisesRegex(ValueError, "unsafe Unity asset path"):
                import_assets(
                    package_path=package_path,
                    project_path=root / "UnityProject",
                    root_asset_paths=("Assets/../escaped.prefab",),
                )

    def test_reports_missing_root_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            package_path = root / "missing.unitypackage"
            self._write_package(
                package_path,
                {
                    "a" * 32: (
                        "Assets/Vendor/Female.prefab",
                        b"female",
                    ),
                },
            )

            with self.assertRaisesRegex(KeyError, "Male.prefab"):
                import_assets(
                    package_path=package_path,
                    project_path=root / "UnityProject",
                    root_asset_paths=(
                        "Assets/Vendor/Female.prefab",
                        "Assets/Vendor/Male.prefab",
                    ),
                )

    @staticmethod
    def _write_package(
        package_path: Path,
        entries: dict[str, tuple[str, bytes]],
    ) -> None:
        with tarfile.open(package_path, "w:gz") as archive:
            for guid, (asset_path, payload) in entries.items():
                ModularAnimeCharacterImportTest._add_bytes(
                    archive,
                    f"{guid}/pathname",
                    asset_path.encode() + b"\n00",
                )
                ModularAnimeCharacterImportTest._add_bytes(
                    archive,
                    f"{guid}/asset",
                    payload,
                )
                ModularAnimeCharacterImportTest._add_bytes(
                    archive,
                    f"{guid}/asset.meta",
                    f"fileFormatVersion: 2\nguid: {guid}\n".encode(),
                )

    @staticmethod
    def _add_bytes(archive: tarfile.TarFile, name: str, payload: bytes) -> None:
        info = tarfile.TarInfo(name)
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))


if __name__ == "__main__":
    unittest.main()
