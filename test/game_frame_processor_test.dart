import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/features/widgets_hub/application/game_frame_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'frame normalization bounds pixels and binds clean JPEG bytes',
    () async {
      final source = image.Image(width: 1000, height: 500);
      image.fill(source, color: image.ColorRgb8(20, 110, 180));
      final frame = await processGameFrame(
        Uint8List.fromList(image.encodePng(source)),
      );
      expect(frame.width, 640);
      expect(frame.height, 320);
      expect(frame.jpegBytes.length, lessThanOrEqualTo(gameFrameMaximumBytes));
      expect(frame.contentHash, sha256.convert(frame.jpegBytes).toString());
      expect(frame.fingerprint, hasLength(1024));
      expect(image.decodeJpg(frame.jpegBytes)!.width, 640);
      expect(() => frame.jpegBytes[0] = 0, throwsUnsupportedError);
    },
  );
  test('malformed and oversized inputs fail without becoming frames', () async {
    await expectLater(
      processGameFrame(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    await expectLater(
      processGameFrame(Uint8List(4 * 1024 * 1024 + 1)),
      throwsFormatException,
    );
    final huge = image.Image(width: 4097, height: 1);
    await expectLater(
      processGameFrame(Uint8List.fromList(image.encodePng(huge))),
      throwsFormatException,
    );
  });
  test(
    'difference ignores slight encoding noise but sees local board changes',
    () {
      ProcessedGameFrame frame(
        String hash,
        Uint8List pixels, {
        int width = 640,
      }) => ProcessedGameFrame(
        jpegBytes: Uint8List.fromList([1]),
        contentHash: hash,
        width: width,
        height: 320,
        fingerprint: pixels,
      );
      final gray = Uint8List.fromList(List.filled(1024, 80));
      final first = frame('a', gray);
      expect(gameFramesDiffer(null, first), isTrue);
      expect(
        gameFramesDiffer(
          first,
          frame('b', Uint8List.fromList(List.filled(1024, 81))),
        ),
        isFalse,
      );
      final local = Uint8List.fromList(gray);
      for (final i in [0, 1, 32, 33]) {
        local[i] = 255;
      }
      expect(gameFramesDiffer(first, frame('c', local)), isTrue);
      expect(gameFramesDiffer(first, frame('a', gray, width: 320)), isTrue);
      expect(
        () => gameFramesDiffer(first, first, threshold: double.nan),
        throwsArgumentError,
      );
    },
  );
}
