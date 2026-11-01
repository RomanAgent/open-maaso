import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('immersive pages declare their native-safe backdrop boundary', () {
    for (final path in <String>[
      'lib/src/features/home/presentation/home_page.dart',
      'lib/src/features/auth/presentation/login_page.dart',
      'lib/src/features/agent_space/presentation/agent_space_page.dart',
    ]) {
      final source = File(path).readAsStringSync();

      expect(source, contains('app_glass.dart'), reason: path);
      expect(source, contains('AppGlassScaffold('), reason: path);
      if (path.endsWith('/login_page.dart')) {
        expect(source, contains('backdropKind: _presentingWorld'));
        expect(source, contains('? GlassBackdropKind.platformView'));
        expect(source, contains(': GlassBackdropKind.flutter'));
        expect(source, contains('LoginDoorwayArtwork('));
      } else {
        expect(
          source,
          contains('backdropKind: GlassBackdropKind.platformView'),
          reason: path,
        );
      }
      expect(source, isNot(contains('return Scaffold(')), reason: path);
      expect(
        source,
        isNot(contains('package:liquid_glass_widgets')),
        reason: path,
      );
      expect(source, isNot(contains('adventure_chrome.dart')), reason: path);
      expect(source, isNot(contains('AdventurePanel(')), reason: path);
    }
  });

  test('Login keeps opaque auth controls and transient dialog chrome', () {
    final source = File(
      'lib/src/features/auth/presentation/login_page.dart',
    ).readAsStringSync();

    expect(source, contains('AppGlassField('));
    expect(source, contains('AppGlassButton('));
    expect(source, contains('class _OpaqueIconButton'));
    expect(source, contains('class _ImmersiveActionButton'));
    expect(source, contains('AppGlassIconButton('));
    expect(source, isNot(contains('BackdropFilter(')));
    expect(source, contains('showAppGlassDialog<void>('));
    expect(source, isNot(contains('return showDialog<void>(')));
    // The offline poster covers the form until the same route presents the
    // Unity doorway underneath it; the native underlay stays transparent.
    expect(source, contains('backdropKind: _presentingWorld'));
    expect(source, contains('LoginDoorwayArtwork('));
    expect(source, contains('UnityAvatarView('));
    expect(source, contains('backgroundColor: Colors.transparent'));
  });

  test('Home fixed overlay panels use the shared glass surface', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();

    expect(source, contains('AppGlassSurface('));
    expect(source, contains('AppGlassSurfaceBehavior.automatic'));
  });
}
