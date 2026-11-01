import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';

void main() {
  test('selects reviewed macOS and Windows Unity bundle variants', () {
    for (final platform in <String>['macos', 'windows']) {
      final model = ApprovedAvatarModel.fromJson(<String, dynamic>{
        'id': 42,
        'modelKey': 'official.desktop.avatar',
        'displayName': 'Desktop Avatar',
        'modelSource': 'official',
        'compatibility': <String, Object>{
          'backends': <String>['unity'],
        },
        'platformAssets': <String, Object>{
          'ios': _asset('ios'),
          'android': _asset('android'),
          platform: _asset(platform),
        },
      }, platform: platform);

      expect(model.selectedPlatform, platform);
      expect(model.assetUrl, 'https://cdn.example.com/avatar-$platform.bundle');
      expect(model.isLoadableOnDevice, isTrue);
      expect(model.toAvatarOption().config, containsPair('platform', platform));
    }
  });

  test(
    'desktop selection omits remote asset queries but keeps builtin version',
    () {
      final source = File(
        'lib/src/core/services/avatar_model_catalog_service.dart',
      ).readAsStringSync();

      expect(source, contains('TargetPlatform.macOS ||'));
      expect(
        source,
        contains(
          'TargetPlatform.windows => const AvatarSelectionAssetOptions.none(',
        ),
      );
      expect(
        source,
        contains('builtinCatalogVersion: avatarBuiltinCatalogVersion'),
      );
    },
  );
}

Map<String, Object> _asset(String platform) => <String, Object>{
  'platform': platform,
  'bundleVersion': 'v1',
  'assetUrl': 'https://cdn.example.com/avatar-$platform.bundle',
  'assetSha256': 'a' * 64,
  'assetBytes': 4096,
  'runtimeConfig': <String, Object>{'assetName': 'DesktopAvatar'},
};
