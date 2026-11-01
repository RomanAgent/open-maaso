import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  const trayLogoPath = 'assets/brand/masso_macos_status_icon.png';
  const macAppIconPath = 'assets/brand/masso_macos_app_icon.png';
  const mobileIconPath = 'assets/brand/masso_launcher_icon_day.png';

  test('macOS tray uses a transparent template image', () {
    final source = File(
      'lib/src/desktop/infrastructure/'
      'tray_manager_desktop_companion_gateway.dart',
    ).readAsStringSync();

    expect(source, contains("'$trayLogoPath'"));
    expect(
      source,
      contains('Platform.isMacOS ? _macMenuBarIconPath : _iconPath'),
    );
    expect(source, contains('isTemplate: Platform.isMacOS'));
    expect(source, contains('iconSize: 20'));
    _expectTransparentLogo(trayLogoPath);
  });

  test('menu bar mark is 18 logical points with clear uncropped edges', () {
    final icon = _readPng(trayLogoPath);
    expect(icon.width, 40);
    expect(icon.height, 40);
    var left = icon.width;
    var top = icon.height;
    var right = -1;
    var bottom = -1;
    for (final pixel in icon) {
      if (pixel.x < 2 || pixel.y < 2 || pixel.x >= 38 || pixel.y >= 38) {
        expect(pixel.a, 0, reason: 'Keep a 1 pt clear margin on every edge');
      }
      if (pixel.a < 128) continue;
      expect(<num>[pixel.r, pixel.g, pixel.b], <num>[0, 0, 0]);
      if (pixel.x < left) left = pixel.x;
      if (pixel.y < top) top = pixel.y;
      if (pixel.x > right) right = pixel.x;
      if (pixel.y > bottom) bottom = pixel.y;
    }
    expect((right - left + 1) / 2, 18);
    expect((bottom - top + 1) / 2, 18);
    expect(left, icon.width - right - 1, reason: 'Keep the mark centered');
    expect(top, icon.height - bottom - 1, reason: 'Keep the mark centered');
  });

  test('macOS app icon configuration uses the synchronized mobile artwork', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final macOSConfig = RegExp(
      r'macos:\s*\n\s*generate:\s*true\s*\n\s*image_path:\s*([^\s]+)',
    ).firstMatch(pubspec);

    expect(macOSConfig, isNotNull);
    expect(macOSConfig!.group(1), macAppIconPath);
    _expectOpaqueWhiteLogo(_readPng(macAppIconPath), macAppIconPath);
  });

  test('macOS preserves the compiled native icon at launch', () {
    final appDelegate = File(
      'macos/Runner/AppDelegate.swift',
    ).readAsStringSync();

    expect(appDelegate, isNot(contains('applicationIconImage =')));
    expect(appDelegate, isNot(contains('forAsset: "$macAppIconPath"')));
  });

  test('native icon separates the mobile mark from its white background', () {
    const folder = 'macos/Runner/AppIcon.icon';
    final config =
        jsonDecode(File('$folder/icon.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(config['fill'], <String, String>{
      'solid': 'srgb:1.00000,1.00000,1.00000,1.00000',
    });
    final group = (config['groups'] as List).single as Map<String, dynamic>;
    final layer = (group['layers'] as List).single as Map<String, dynamic>;
    expect(layer['image-name'], 'Mark.png');
    expect(layer['glass'], isNot(false));
    expect(layer['position'], isNull, reason: 'Do not add another inset');
    expect((group['translucency'] as Map)['enabled'], isTrue);
    const markPath = '$folder/Assets/Mark.png';
    _expectTransparentLogo(markPath);
    final mark = _readPng(markPath);
    final mobile = _readPng(mobileIconPath);
    expect(mark.width, mobile.width);
    // The native layer must reproduce the mobile silhouette over white,
    // not place an opaque white square inside a second system icon canvas.
    var largestDifference = 0.0;
    for (final pixel in mark) {
      final target = mobile.getPixel(pixel.x, pixel.y);
      final alpha = pixel.a / 255;
      for (final pair in <(num, num)>[
        (pixel.r, target.r),
        (pixel.g, target.g),
        (pixel.b, target.b),
      ]) {
        final difference = (pair.$1 * alpha + 255 * (1 - alpha) - pair.$2)
            .abs();
        if (difference > largestDifference) largestDifference = difference;
      }
    }
    expect(largestDifference, lessThanOrEqualTo(1));
  });

  test('Xcode compiles the layered icon for every application configuration', () {
    final project = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(project, contains('lastKnownFileType = folder.iconcomposer.icon'));
    expect(project, contains('path = Runner/AppIcon.icon'));
    final resources = RegExp(
      r'/\* Begin PBXResourcesBuildPhase section \*/([\s\S]*?)/\* End PBXResourcesBuildPhase section \*/',
    ).firstMatch(project)!.group(1)!;
    expect(resources, contains('AppIcon.icon in Resources'));
    expect(
      RegExp(
        'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;',
      ).allMatches(project).length,
      3,
    );
  });

  test('macOS master exactly matches the mobile white artwork', () {
    final mobileBytes = File(mobileIconPath).readAsBytesSync();
    for (final path in <String>[
      macAppIconPath,
      'ios/Runner/Assets.xcassets/AppIconLight.appiconset/'
          'Icon-Light-1024x1024@1x.png',
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
    ]) {
      expect(
        File(path).readAsBytesSync(),
        orderedEquals(mobileBytes),
        reason: '$path must not change mobile artwork, inset or background',
      );
    }
  });

  test('generated macOS icons preserve white background and mobile scale', () {
    for (final size in <int>[16, 32, 64, 128, 256, 512, 1024]) {
      final path =
          'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png';
      final icon = _readPng(path);
      expect(icon.width, size, reason: path);
      _expectOpaqueWhiteLogo(icon, path);
    }
  });

  test('Windows ICO replaces the Flutter template at every native size', () {
    const path = 'windows/runner/resources/app_icon.ico';
    final decoder = image.IcoDecoder();
    expect(decoder.startDecode(File(path).readAsBytesSync()), isNotNull);
    const sizes = <int>[16, 24, 32, 48, 64, 128, 256];
    expect(decoder.numFrames(), sizes.length);
    for (var i = 0; i < sizes.length; i++) {
      final icon = decoder.decodeFrame(i);
      expect(icon, isNotNull, reason: '$path frame $i');
      expect(icon!.width, sizes[i]);
      _expectOpaqueWhiteLogo(icon, '$path frame $i');
      expect(
        icon.every((pixel) => pixel.r == pixel.g && pixel.g == pixel.b),
        isTrue,
        reason: 'The mobile artwork is monochrome, not the blue Flutter icon',
      );
    }
  });
}

void _expectTransparentLogo(String path) {
  final logo = image.decodePng(File(path).readAsBytesSync());

  expect(logo, isNotNull, reason: '$path must be a valid PNG');
  expect(logo!.width, logo.height, reason: '$path must be square');
  expect(logo.getPixel(0, 0).a, 0, reason: '$path must have clear corners');
  expect(
    logo.getPixel(logo.width ~/ 2, logo.height ~/ 2).a,
    greaterThan(0),
    reason: '$path must retain visible logo pixels',
  );
}

image.Image _readPng(String path) {
  final decoded = image.decodePng(File(path).readAsBytesSync());
  expect(decoded, isNotNull, reason: '$path must be a valid PNG');
  return decoded!;
}

void _expectOpaqueWhiteLogo(image.Image logo, String label) {
  expect(logo.height, logo.width, reason: '$label must be square');
  expect(
    logo.every((pixel) => pixel.a == 255),
    isTrue,
    reason: '$label must not expose the Dock or wallpaper through the icon',
  );
  final corner = logo.getPixel(0, 0);
  expect(<num>[corner.r, corner.g, corner.b], <num>[255, 255, 255]);
  final center = logo.getPixel(logo.width ~/ 2, logo.height ~/ 2);
  expect(<num>[center.r, center.g, center.b], <num>[0, 0, 0]);

  var left = logo.width;
  var top = logo.height;
  var right = -1;
  var bottom = -1;
  for (final pixel in logo) {
    if (pixel.r >= 250 && pixel.g >= 250 && pixel.b >= 250) continue;
    if (pixel.x < left) left = pixel.x;
    if (pixel.y < top) top = pixel.y;
    if (pixel.x > right) right = pixel.x;
    if (pixel.y > bottom) bottom = pixel.y;
  }
  final mobileInset = logo.width * 102 / 1024;
  expect(left, closeTo(mobileInset, 1), reason: label);
  expect(top, closeTo(mobileInset, 1), reason: label);
  expect(right, closeTo(logo.width - mobileInset - 1, 1), reason: label);
  expect(bottom, closeTo(logo.height - mobileInset - 1, 1), reason: label);
}
