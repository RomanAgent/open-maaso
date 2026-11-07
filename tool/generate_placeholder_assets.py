#!/usr/bin/env python3
"""Regenerate original geometric public-release placeholders using only stdlib.

The table records asset paths and dimensions, not original artwork.
No source images, external assets, fonts, network, or third-party modules are used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from functools import lru_cache
from pathlib import Path
import struct
import zlib

# path, width, height, style; compatibility names preserve existing references.
OUTPUTS = (
    ('android/app/src/main/res/drawable-hdpi/android12splash.png', 360, 360, 'transparent'),
    ('android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png', 162, 162, 'transparent'),
    ('android/app/src/main/res/drawable-hdpi/ic_launcher_foreground_light.png', 162, 162, 'transparent'),
    ('android/app/src/main/res/drawable-hdpi/splash.png', 480, 240, 'transparent'),
    ('android/app/src/main/res/drawable-mdpi/android12splash.png', 240, 240, 'transparent'),
    ('android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png', 108, 108, 'transparent'),
    ('android/app/src/main/res/drawable-mdpi/ic_launcher_foreground_light.png', 108, 108, 'transparent'),
    ('android/app/src/main/res/drawable-mdpi/splash.png', 320, 160, 'transparent'),
    ('android/app/src/main/res/drawable-night-hdpi/android12splash.png', 360, 360, 'transparent'),
    ('android/app/src/main/res/drawable-night-mdpi/android12splash.png', 240, 240, 'transparent'),
    ('android/app/src/main/res/drawable-night-xhdpi/android12splash.png', 480, 480, 'transparent'),
    ('android/app/src/main/res/drawable-night-xxhdpi/android12splash.png', 720, 720, 'transparent'),
    ('android/app/src/main/res/drawable-night-xxxhdpi/android12splash.png', 960, 960, 'transparent'),
    ('android/app/src/main/res/drawable-v21/background.png', 1, 1, 'background'),
    ('android/app/src/main/res/drawable-xhdpi/android12splash.png', 480, 480, 'transparent'),
    ('android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png', 216, 216, 'transparent'),
    ('android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground_light.png', 216, 216, 'transparent'),
    ('android/app/src/main/res/drawable-xhdpi/splash.png', 640, 320, 'transparent'),
    ('android/app/src/main/res/drawable-xxhdpi/android12splash.png', 720, 720, 'transparent'),
    ('android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png', 324, 324, 'transparent'),
    ('android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground_light.png', 324, 324, 'transparent'),
    ('android/app/src/main/res/drawable-xxhdpi/splash.png', 960, 480, 'transparent'),
    ('android/app/src/main/res/drawable-xxxhdpi/android12splash.png', 960, 960, 'transparent'),
    ('android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png', 432, 432, 'transparent'),
    ('android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground_light.png', 432, 432, 'transparent'),
    ('android/app/src/main/res/drawable-xxxhdpi/splash.png', 1280, 640, 'transparent'),
    ('android/app/src/main/res/drawable/background.png', 1, 1, 'background'),
    ('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72, 72, 'icon'),
    ('android/app/src/main/res/mipmap-hdpi/ic_launcher_light.png', 72, 72, 'icon'),
    ('android/app/src/main/res/mipmap-mdpi/ic_launcher.png', 48, 48, 'icon'),
    ('android/app/src/main/res/mipmap-mdpi/ic_launcher_light.png', 48, 48, 'icon'),
    ('android/app/src/main/res/mipmap-xhdpi/ic_launcher.png', 96, 96, 'icon'),
    ('android/app/src/main/res/mipmap-xhdpi/ic_launcher_light.png', 96, 96, 'icon'),
    ('android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png', 144, 144, 'icon'),
    ('android/app/src/main/res/mipmap-xxhdpi/ic_launcher_light.png', 144, 144, 'icon'),
    ('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png', 192, 192, 'icon'),
    ('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_light.png', 192, 192, 'icon'),
    ('assets/brand/home_room.png', 900, 1950, 'background'),
    ('assets/brand/login_doorway.png', 900, 936, 'background'),
    ('assets/brand/masso_android12_splash_logo.png', 960, 960, 'transparent'),
    ('assets/brand/masso_launcher_foreground.png', 1024, 1024, 'transparent'),
    ('assets/brand/masso_launcher_icon.png', 1024, 1024, 'icon'),
    ('assets/brand/masso_launcher_icon_day.png', 1024, 1024, 'icon'),
    ('assets/brand/masso_macos_app_icon.png', 1024, 1024, 'icon'),
    ('assets/brand/masso_macos_status_icon.png', 40, 40, 'transparent'),
    ('assets/brand/masso_splash_logo.png', 1280, 640, 'transparent'),
    ('assets/model_store/agent.png', 768, 1152, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png', 1024, 1024, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png', 20, 20, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png', 40, 40, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png', 60, 60, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png', 29, 29, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png', 58, 58, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png', 87, 87, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png', 40, 40, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png', 80, 80, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png', 120, 120, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-50x50@1x.png', 50, 50, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-50x50@2x.png', 100, 100, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-57x57@1x.png', 57, 57, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-57x57@2x.png', 114, 114, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png', 120, 120, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png', 180, 180, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-72x72@1x.png', 72, 72, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-72x72@2x.png', 144, 144, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png', 76, 76, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png', 152, 152, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png', 167, 167, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-1024x1024@1x.png', 1024, 1024, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-20x20@1x.png', 20, 20, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-20x20@2x.png', 40, 40, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-20x20@3x.png', 60, 60, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-29x29@1x.png', 29, 29, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-29x29@2x.png', 58, 58, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-29x29@3x.png', 87, 87, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-40x40@1x.png', 40, 40, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-40x40@2x.png', 80, 80, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-40x40@3x.png', 120, 120, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-50x50@1x.png', 50, 50, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-50x50@2x.png', 100, 100, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-57x57@1x.png', 57, 57, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-57x57@2x.png', 114, 114, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-60x60@2x.png', 120, 120, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-60x60@3x.png', 180, 180, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-72x72@1x.png', 72, 72, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-72x72@2x.png', 144, 144, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-76x76@1x.png', 76, 76, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-76x76@2x.png', 152, 152, 'icon'),
    ('ios/Runner/Assets.xcassets/AppIconLight.appiconset/Icon-Light-83.5x83.5@2x.png', 167, 167, 'icon'),
    ('ios/Runner/Assets.xcassets/LaunchBackground.imageset/background.png', 1, 1, 'background'),
    ('ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png', 320, 160, 'transparent'),
    ('ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png', 640, 320, 'transparent'),
    ('ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png', 960, 480, 'transparent'),
    ('macos/Runner/AppIcon.icon/Assets/Mark.png', 1024, 1024, 'transparent'),
    ('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png', 1024, 1024, 'icon'),
    ('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png', 128, 128, 'icon'),
    ('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png', 16, 16, 'icon'),
    ('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png', 256, 256, 'icon'),
    ('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png', 32, 32, 'icon'),
    ('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png', 512, 512, 'icon'),
    ('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png', 64, 64, 'icon'),
    ('web/favicon.png', 16, 16, 'icon'),
    ('web/icons/Icon-192.png', 192, 192, 'icon'),
    ('web/icons/Icon-512.png', 512, 512, 'icon'),
    ('web/icons/Icon-maskable-192.png', 192, 192, 'icon'),
    ('web/icons/Icon-maskable-512.png', 512, 512, 'icon'),
)

def _chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def _blend(bottom: tuple[int, int, int, int], top: tuple[int, int, int], coverage: float) -> tuple[int, int, int, int]:
    coverage = max(0.0, min(1.0, coverage))
    alpha = bottom[3] / 255.0
    combined = coverage + alpha * (1.0 - coverage)
    if combined == 0.0:
        return (0, 0, 0, 0)
    rgb = tuple(round((top[i] * coverage + bottom[i] * alpha * (1.0 - coverage)) / combined) for i in range(3))
    return (*rgb, round(combined * 255.0))


@lru_cache(maxsize=None)
def make_png(width: int, height: int, style: str) -> bytes:
    """Draw a blue circular mark with a white square or a neutral background."""
    rows = bytearray()
    scale = min(width, height)
    radius = scale * 0.31
    square = scale * 0.105
    cx, cy = width / 2.0, height / 2.0
    for y in range(height):
        rows.append(0)  # PNG filter: None.
        ratio = y / max(1, height - 1)
        background = (round(255 - ratio * 9), round(255 - ratio * 5), 255, 255)
        for x in range(width):
            pixel = (0, 0, 0, 0) if style == "transparent" else background
            if style != "background":
                distance = ((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2) ** 0.5
                pixel = _blend(pixel, (24, 115, 242), radius - distance + 0.5)
                edge = max(abs(x + 0.5 - cx), abs(y + 0.5 - cy))
                pixel = _blend(pixel, (255, 255, 255), square - edge + 0.5)
            rows.extend(pixel)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", header) + _chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + _chunk(b"IEND", b"")


def make_ico() -> bytes:
    """Create an ICO containing PNG images, supported by modern Windows."""
    sizes = (16, 24, 32, 48, 64, 128, 256)
    blobs = [make_png(size, size, "icon") for size in sizes]
    header = struct.pack("<HHH", 0, 1, len(sizes))
    directory = bytearray()
    offset = 6 + 16 * len(sizes)
    for size, blob in zip(sizes, blobs):
        dimension = 0 if size == 256 else size
        directory.extend(struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(blob), offset))
        offset += len(blob)
    return header + bytes(directory) + b"".join(blobs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check every output matches the deterministic generated placeholder.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    # Original Home and login artwork are presentation resources. Regeneration
    # must never replace either with a placeholder.
    expected = [(path, make_png(width, height, style)) for path, width, height, style in OUTPUTS if path == 'assets/model_store/agent.png']
    manifest = root / 'assets/brand/official-launcher-assets.json'
    official = json.loads(manifest.read_text())
    scene_assets = json.loads((root / 'assets/brand/generated-scene-assets.json').read_text())
    if 'windows/runner/resources/app_icon.ico' not in official:
        expected.append(("windows/runner/resources/app_icon.ico", make_ico()))
    failures = []
    for path, payload in expected:
        output = root / path
        if args.check:
            if not output.is_file() or output.read_bytes() != payload:
                failures.append(path)
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(payload)
    if args.check:
        for path, digest in {**official, **scene_assets}.items():
            asset = root / path
            if not asset.is_file() or hashlib.sha256(asset.read_bytes()).hexdigest() != digest:
                failures.append(path)
    if failures:
        for path in failures:
            print("Asset differs or is missing:", path)
        return 1
    print(("Verified" if args.check else "Generated"), len(expected), "original placeholder assets.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
