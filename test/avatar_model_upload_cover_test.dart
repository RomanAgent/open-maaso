import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';

import 'helpers/avatar_upload_cover_fixture.dart';

void main() {
  test('keeps an immutable, hashed snapshot of the confirmed PNG', () async {
    final original = avatarCoverPngBytes();
    final cover = await AvatarModelUploadCover.fromBytes(
      fileName: 'cover.png',
      bytes: original,
    );
    final digest = sha256.convert(original).toString();
    original[0] = 0;
    expect(cover.contentType, 'image/png');
    expect(cover.width, 96);
    expect(cover.height, 144);
    expect(cover.sha256Hex, digest);
    expect(sha256.convert(cover.bytes).toString(), digest);
    expect(() => cover.bytes[0] = 0, throwsUnsupportedError);
  });

  test('accepts JPEG after checking actual encoded content', () async {
    final cover = await AvatarModelUploadCover.fromBytes(
      fileName: 'full-body.JPEG',
      bytes: img.encodeJpg(img.Image(width: 80, height: 120)),
    );
    expect(cover.contentType, 'image/jpeg');
    expect((cover.width, cover.height), (80, 120));
  });

  test(
    'a later local file change does not replace the confirmed cover',
    () async {
      final dir = await Directory.systemTemp.createTemp('maaso-cover-snapshot');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/cover.png');
      await file.writeAsBytes(avatarCoverPngBytes());
      final cover = await AvatarModelUploadCover.fromFile(file);
      await file.writeAsString('changed');
      expect(cover.bytes, avatarCoverPngBytes());
      expect(sha256.convert(cover.bytes).toString(), cover.sha256Hex);
    },
  );

  test(
    'rejects wrong extensions, forged MIME and invalid image bytes',
    () async {
      for (final (name, bytes) in [
        ('cover.svg', Uint8List.fromList('<svg/>'.codeUnits)),
        ('cover.jpg', avatarCoverPngBytes()),
        ('cover.png', Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10])),
      ]) {
        await expectLater(
          AvatarModelUploadCover.fromBytes(fileName: name, bytes: bytes),
          throwsA(isA<AvatarUploadCoverException>()),
        );
      }
    },
  );

  test('rejects empty, oversized and out of range dimensions', () async {
    for (final bytes in [
      Uint8List(0),
      Uint8List(AvatarModelUploadCover.maxBytes + 1),
    ]) {
      await expectLater(
        AvatarModelUploadCover.fromBytes(fileName: 'cover.png', bytes: bytes),
        throwsA(
          isA<AvatarUploadCoverException>().having(
            (e) => e.code,
            'code',
            'size',
          ),
        ),
      );
    }
    await expectLater(
      AvatarModelUploadCover.fromBytes(
        fileName: 'cover.png',
        bytes: avatarCoverPngBytes(width: 63),
      ),
      throwsA(
        isA<AvatarUploadCoverException>().having(
          (e) => e.code,
          'code',
          'dimensions',
        ),
      ),
    );
  });
  test(
    'rejects oversized PNG and JPEG dimensions before native decoding',
    () async {
      final png = Uint8List.fromList(avatarCoverPngBytes());
      ByteData.sublistView(png).setUint32(16, 8193);
      final jpeg = Uint8List.fromList([
        0xff,
        0xd8,
        0xff,
        0xc0,
        0,
        11,
        8,
        0,
        64,
        0x20,
        0x01,
        1,
        1,
        0x11,
        0,
        0xff,
        0xd9,
      ]);
      for (final (name, bytes) in [('wide.png', png), ('wide.jpg', jpeg)]) {
        await expectLater(
          AvatarModelUploadCover.fromBytes(fileName: name, bytes: bytes),
          throwsA(
            isA<AvatarUploadCoverException>().having(
              (e) => e.code,
              'code',
              'dimensions',
            ),
          ),
        );
      }
    },
  );

  test(
    'rejects excessive JPEG component sampling before native decoding',
    () async {
      final jpeg = Uint8List.fromList([
        0xff,
        0xd8,
        0xff,
        0xc0,
        0,
        11,
        8,
        0,
        64,
        0,
        64,
        1,
        1,
        0xff,
        0,
        0xff,
        0xd9,
      ]);
      await expectLater(
        AvatarModelUploadCover.fromBytes(fileName: 'sampling.jpg', bytes: jpeg),
        throwsA(
          isA<AvatarUploadCoverException>().having(
            (e) => e.code,
            'code',
            'format',
          ),
        ),
      );
    },
  );

  test(
    'JPEG EXIF orientation does not change encoded upload dimensions',
    () async {
      final image = img.Image(width: 80, height: 120);
      image.exif.imageIfd.orientation = 6;
      final cover = await AvatarModelUploadCover.fromBytes(
        fileName: 'rotated.jpg',
        bytes: img.encodeJpg(image),
      );
      expect((cover.width, cover.height), (80, 120));
    },
  );
}
