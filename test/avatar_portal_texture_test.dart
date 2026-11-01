import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_texture.dart';

void main() {
  testWidgets('Mac scene texture fills its viewport and retains Apple flip', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 800,
              height: 600,
              child: AvatarPortalTexture(
                fillViewport: true,
                lease: AvatarPortalLease(
                  textureId: 90,
                  width: 1080,
                  height: 810,
                  generation: 2,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(Texture)), const Size(800, 600));
      expect(find.byKey(AvatarPortalTexture.logicalViewportKey), findsNothing);
      final correction = tester.widget<Transform>(
        find.byKey(AvatarPortalTexture.appleOrientationCorrectionKey),
      );
      expect(correction.transform.storage[5], -1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
  const highLease = AvatarPortalLease(
    textureId: 71,
    width: 320,
    height: 560,
    generation: 1,
  );

  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets('${platform.name} applies the zero-copy vertical correction', (
      tester,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = platform;
        await _pumpTexture(
          tester,
          lease: highLease,
          parentSize: const Size(800, 600),
        );

        final correction = tester.widget<Transform>(
          find.byKey(AvatarPortalTexture.appleOrientationCorrectionKey),
        );
        expect(correction.transform.storage[5], -1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('portal keeps its fixed logical size in a large host', (
    tester,
  ) async {
    await _pumpTexture(
      tester,
      lease: highLease,
      parentSize: const Size(800, 600),
    );

    expect(
      tester.getSize(find.byKey(AvatarPortalTexture.logicalViewportKey)),
      AvatarPortalTexture.logicalViewportSize,
    );
    expect(
      tester.getSize(find.byType(Texture)),
      AvatarPortalTexture.logicalViewportSize,
    );
  });

  testWidgets('portal scales down without stretching in a smaller host', (
    tester,
  ) async {
    const parentSize = Size(152, 266);
    await _pumpTexture(tester, lease: highLease, parentSize: parentSize);

    final textureSize = tester.getSize(find.byType(Texture));
    expect(textureSize, parentSize);
    expect(textureSize.aspectRatio, closeTo(highLease.aspectRatio, 0.0001));
  });

  testWidgets('quality profiles retain their source aspect ratio', (
    tester,
  ) async {
    const balancedLease = AvatarPortalLease(
      textureId: 72,
      width: 288,
      height: 496,
      generation: 2,
    );
    await _pumpTexture(
      tester,
      lease: balancedLease,
      parentSize: const Size(800, 600),
    );

    final textureSize = tester.getSize(find.byType(Texture));
    expect(textureSize.width, AvatarPortalTexture.logicalViewportSize.width);
    expect(textureSize.aspectRatio, closeTo(balancedLease.aspectRatio, 0.0001));
    expect(
      textureSize.height,
      lessThanOrEqualTo(AvatarPortalTexture.logicalViewportSize.height),
    );
  });
}

Future<void> _pumpTexture(
  WidgetTester tester, {
  required AvatarPortalLease lease,
  required Size parentSize,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: parentSize.width,
          height: parentSize.height,
          child: AvatarPortalTexture(lease: lease),
        ),
      ),
    ),
  );
}
