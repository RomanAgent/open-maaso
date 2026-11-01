import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // User-uploaded JPEG covers remain valid. Only the maintained builtin
  // renders share this transparent-background asset contract.
  const covers = <String, String>{'Joy': 'assets/model_store/agent.png'};

  for (final cover in covers.entries) {
    test('${cover.key} bundled cover has transparent full-body margins', () async {
      final asset = await rootBundle.load(cover.value);
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      expect(bytes.length, greaterThan(33), reason: cover.value);
      expect(
        bytes.take(8),
        orderedEquals(<int>[137, 80, 78, 71, 13, 10, 26, 10]),
        reason: 'Bundled model artwork must remain a PNG: ${cover.value}',
      );
      expect(
        bytes[25],
        6,
        reason: 'Use a real RGBA render rather than a baked background.',
      );

      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          expect(image.width * 3, image.height * 2);
          final pixels = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(pixels, isNotNull);

          var left = image.width;
          var top = image.height;
          var right = -1;
          var bottom = -1;
          var visiblePixels = 0;
          var transparentPixels = 0;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              final alpha = pixels!.getUint8((y * image.width + x) * 4 + 3);
              if (alpha == 0) transparentPixels++;
              if (alpha <= 3) continue;
              visiblePixels++;
              left = math.min(left, x);
              top = math.min(top, y);
              right = math.max(right, x);
              bottom = math.max(bottom, y);
            }
          }
          expect(
            visiblePixels,
            greaterThan(0),
            reason: 'Cover must not be blank.',
          );
          expect(
            transparentPixels,
            greaterThan(0),
            reason: 'The cover background must be transparent.',
          );

          // Visible-pixel bounds establish transparent framing only; they
          // cannot identify a person or prove that every body part is present.
          final margins = <String, double>{
            'left': left / image.width,
            'top': top / image.height,
            'right': (image.width - 1 - right) / image.width,
            'bottom': (image.height - 1 - bottom) / image.height,
          };
          for (final margin in margins.entries) {
            expect(
              margin.value,
              greaterThanOrEqualTo(.08),
              reason:
                  '${cover.value} needs transparent space at its ${margin.key} edge.',
            );
          }
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    });
  }
}
