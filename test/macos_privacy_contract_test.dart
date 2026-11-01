import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS declares user-facing hardware privacy reasons', () {
    final infoPlist = File('macos/Runner/Info.plist').readAsStringSync();

    for (final key in <String>[
      'NSMicrophoneUsageDescription',
      'NSCameraUsageDescription',
      'NSBluetoothAlwaysUsageDescription',
    ]) {
      expect(infoPlist, contains('<key>$key</key>'), reason: key);
    }
    expect(infoPlist, contains('voice conversations'));
    expect(infoPlist, contains('visual features you start'));
    expect(infoPlist, contains('companion devices you choose'));
  });

  test('debug and release sandboxes permit declared hardware access', () {
    for (final path in <String>[
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final entitlements = File(path).readAsStringSync();
      for (final key in <String>[
        'com.apple.security.device.audio-input',
        'com.apple.security.device.camera',
        'com.apple.security.device.bluetooth',
      ]) {
        expect(
          entitlements,
          contains('<key>$key</key>\n\t<true/>'),
          reason: '$path $key',
        );
      }
    }
  });
}
