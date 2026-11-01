import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/sherpa_model_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Set<String> bundledAssets;
  setUpAll(() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    bundledAssets = manifest.listAssets().toSet();
  });

  test(
    'brand bundle contains only runtime backgrounds and tray artwork',
    () async {
      const runtimeArtwork = <String>{
        'assets/brand/home_room.png',
        'assets/brand/login_doorway.png',
        'assets/brand/masso_launcher_foreground.png',
        'assets/brand/masso_macos_status_icon.png',
      };

      expect(
        bundledAssets.where((path) => path.startsWith('assets/brand/')).toSet(),
        runtimeArtwork,
        reason:
            'Retired logos and native icon/splash generation sources must '
            'not be copied into the Flutter runtime bundle.',
      );
      for (final path in runtimeArtwork) {
        expect(
          (await rootBundle.load(path)).lengthInBytes,
          greaterThan(0),
          reason: path,
        );
      }
    },
  );

  test(
    'catalog avatar previews and offline voice model remain loadable',
    () async {
      const avatarPreviews = <String>{'assets/model_store/agent.png'};
      final voiceModels = SherpaModelRegistry.sileroVad.bundledAssets!;
      expect(bundledAssets, isNot(contains('assets/model_store/matt.png')));
      expect(avatarPreviews, isNotEmpty);
      expect(voiceModels, isNotEmpty);

      for (final path in {...avatarPreviews, ...voiceModels.keys}) {
        expect(bundledAssets, contains(path));
        expect(
          (await rootBundle.load(path)).lengthInBytes,
          greaterThan(0),
          reason: path,
        );
      }
    },
  );

  test('retired action-store preview media stays outside the runtime bundle', () {
    expect(
      bundledAssets.where((path) => path.startsWith('assets/motion_previews/')),
      isEmpty,
      reason:
          'Official actions run from Unity clips; retired store preview videos '
          'and capture evidence must not ship as Flutter runtime assets.',
    );
  });

  test('marketing sources and their fonts stay outside the runtime bundle', () {
    expect(
      bundledAssets.where(
        (path) =>
            path.startsWith('assets/banners/') ||
            (path.startsWith('assets/fonts/') &&
                !path.startsWith('assets/fonts/Orbitron/')),
      ),
      isEmpty,
    );
  });
}
