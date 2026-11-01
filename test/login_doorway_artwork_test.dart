import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/auth/presentation/login_doorway_artwork.dart';

void main() {
  for (final size in [
    const Size(393, 852 * .48),
    const Size(800, 766 * .48),
    const Size(393, 150),
    const Size(852, 180),
  ]) {
    testWidgets('the whole doorway rug remains visible in $size', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.fromSize(
              size: size,
              child: const LoginDoorwayArtwork(),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage('assets/brand/login_doorway.png'),
          tester.element(find.byType(LoginDoorwayArtwork)),
        );
      });
      await tester.pumpAndSettle();
      final image = tester.renderObject<RenderImage>(find.byType(RawImage));
      final sourceSize = Size(
        image.image!.width.toDouble(),
        image.image!.height.toDouble(),
      );
      final fitted = applyBoxFit(image.fit!, sourceSize, image.size);
      final sourceRect = image.alignment
          .resolve(TextDirection.ltr)
          .inscribe(fitted.source, Offset.zero & sourceSize);
      // The baked reference rug occupies this rectangle in the real source.
      // Cropping either its WELCOME lettering or lower lip fails this check.
      final rug = Rect.fromLTRB(
        sourceSize.width * .15,
        sourceSize.height * .67,
        sourceSize.width * .85,
        sourceSize.height * .965,
      );
      expect(sourceRect.left, lessThanOrEqualTo(rug.left));
      expect(sourceRect.top, lessThanOrEqualTo(rug.top));
      expect(sourceRect.right, greaterThanOrEqualTo(rug.right));
      expect(sourceRect.bottom, greaterThanOrEqualTo(rug.bottom));
      expect(tester.takeException(), isNull);
    });
  }
}
