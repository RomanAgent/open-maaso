import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'package:sembast/sembast_memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_contract.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';

void main() {
  AppInvocationProducedImage output(List<int> bytes, String mime) =>
      AppInvocationProducedImage(
        producerOutputKey: 'output-1',
        mime: mime,
        bytes: Uint8List.fromList(bytes),
      );
  test(
    'PNG alpha and JPEG original encoding remain byte-exact while thumbnail is separate JPEG',
    () {
      final pixels = image.Image(width: 3, height: 2, numChannels: 4);
      pixels.setPixelRgba(0, 0, 23, 42, 99, 0);
      pixels.setPixelRgba(2, 1, 23, 42, 99, 255);
      final png = image.encodePng(pixels);
      final prepared = prepareInvocationImage(output(png, 'image/png'));
      expect(prepared.bytes, orderedEquals(png));
      expect(image.decodePng(prepared.bytes)!.getPixel(0, 0).a, 0);
      expect(prepared.attachment.thumbnailJpeg, isNotEmpty);
      expect(() => prepared.bytes[0] = 0, throwsUnsupportedError);
      final jpeg = image.encodeJpg(pixels, quality: 90);
      expect(
        prepareInvocationImage(output(jpeg, 'image/jpeg')).bytes,
        orderedEquals(jpeg),
      );
    },
  );
  test('MIME/signature mismatch and malformed payload are rejected', () {
    final png = image.encodePng(image.Image(width: 2, height: 2));
    expect(
      () => prepareInvocationImage(output(png, 'image/jpeg')),
      throwsFormatException,
    );
    expect(
      () => prepareInvocationImage(output([1, 2, 3], 'image/png')),
      throwsFormatException,
    );
    expect(() => output([1], 'text/html'), throwsFormatException);
  });
  test('header dimensions enforce 4096 edge and 12M decoded pixel budget', () {
    Uint8List header(int width, int height) {
      final original = Uint8List.fromList(
        image.encodePng(image.Image(width: 1, height: 1)),
      );
      final data = ByteData.sublistView(original);
      data.setUint32(16, width);
      data.setUint32(20, height);
      var crc = 0xffffffff;
      for (final byte in original.sublist(12, 29)) {
        crc ^= byte;
        for (var bit = 0; bit < 8; bit++) {
          crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
        }
      }
      data.setUint32(29, crc ^ 0xffffffff);
      return original;
    }

    expect(
      () => prepareInvocationImage(output(header(4097, 1), 'image/png')),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          'invocation_image_dimensions',
        ),
      ),
    );
    expect(
      () => prepareInvocationImage(output(header(4000, 4000), 'image/png')),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          'invocation_image_dimensions',
        ),
      ),
    );
    final legal = image.encodePng(image.Image(width: 4096, height: 1));
    expect(
      prepareInvocationImage(output(legal, 'image/png')).bytes,
      orderedEquals(legal),
    );
  });
  test(
    'journal reader preserves originals and rejects MIME, size and hash conflicts',
    () async {
      final db = await databaseFactoryMemory.openDatabase(
        'output-reader-integrity',
      );
      final service = ChatMediaService(
        database: db,
        isCurrent: () => true,
        baseUri: Uri.https('example.invalid'),
        accessToken: () async => 'unused',
      );
      final bytes = image.encodePng(
        image.Image(width: 2, height: 2, numChannels: 4),
      );
      final prepared = prepareInvocationImage(output(bytes, 'image/png'));
      try {
        await service.persist(prepared);
        Future<Uint8List?> read({String? id, String? mime, int? length}) =>
            db.transaction(
              (tx) => service.readInvocationOutput(
                tx,
                id: id ?? prepared.attachment.id,
                mime: mime ?? prepared.mime,
                byteLength: length ?? prepared.bytes.length,
              ),
            );
        final one = await read(), two = await read();
        expect(one, orderedEquals(bytes));
        expect(two, orderedEquals(bytes));
        expect(() => one![0] = 0, throwsUnsupportedError);
        expect(await read(id: 'f' * 64), isNull);
        await expectLater(read(mime: 'image/jpeg'), throwsFormatException);
        await expectLater(
          read(length: prepared.bytes.length + 1),
          throwsFormatException,
        );
        final corrupt = Uint8List.fromList(prepared.bytes)..[0] = 0;
        await stringMapStoreFactory
            .store('chat_media.v1')
            .record(prepared.attachment.id)
            .put(db, {'mime': 'image/png', 'data': base64Encode(corrupt)});
        await expectLater(read(), throwsFormatException);
      } finally {
        await service.shutdown();
        await db.close();
      }
    },
  );

  test(
    'journal reader rechecks account after a queued database read',
    () async {
      final db = await databaseFactoryMemory.openDatabase(
        'output-reader-retired',
      );
      var current = true;
      final service = ChatMediaService(
        database: db,
        isCurrent: () => current,
        baseUri: Uri.https('example.invalid'),
        accessToken: () async => 'unused',
      );
      final prepared = prepareInvocationImage(
        output(image.encodePng(image.Image(width: 2, height: 2)), 'image/png'),
      );
      await service.persist(prepared);
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = db.transaction((tx) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final reading = service.readInvocationOutput(
        db,
        id: prepared.attachment.id,
        mime: prepared.mime,
        byteLength: prepared.bytes.length,
      );
      final rejected = expectLater(reading, throwsStateError);
      current = false;
      release.complete();
      await blocker;
      await rejected;
      await service.shutdown();
      await db.close();
    },
  );

  test('producer bytes are frozen and receipt data is bounded', () {
    final bytes = Uint8List.fromList(
      image.encodePng(image.Image(width: 1, height: 1)),
    );
    final received = output(bytes, 'image/png');
    bytes[0] = 0;
    expect(received.bytes[0], 137);
    expect(
      () => AppInvocationProducedImage(
        producerOutputKey: 'too-big',
        mime: 'image/png',
        bytes: Uint8List(12 * 1024 * 1024 + 1),
      ),
      throwsFormatException,
    );
    expect(
      () =>
          appInvocationResultJson.canonicalize({'tooMuch': 'a' * (64 * 1024)}),
      throwsFormatException,
    );
  });
}
