import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS entitlements allow outgoing network clients', () {
    for (final path in [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final entitlements = File(path).readAsStringSync();

      expect(entitlements, contains('com.apple.security.network.client'));
      expect(
        entitlements,
        contains('<true/>'),
        reason: '$path must enable outgoing network access',
      );
    }
  });

  test('macOS entitlements declare the default Keychain access group', () {
    final emptyKeychainGroup = RegExp(
      r'<key>keychain-access-groups</key>\s*'
      r'(?:<array\s*/>|<array>\s*</array>)',
    );

    for (final path in [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final entitlements = File(path).readAsStringSync();

      expect(
        emptyKeychainGroup.allMatches(entitlements),
        hasLength(1),
        reason:
            '$path must declare one empty keychain-access-groups array so '
            'flutter_secure_storage can use the app default group',
      );
    }
  });
}
