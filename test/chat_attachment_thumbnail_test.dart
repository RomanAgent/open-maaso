import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/models/chat_attachment.dart';
import 'package:maaso/src/features/chat/presentation/media/chat_attachment_preview.dart';

const _thumbnailKey = ValueKey('attachment-thumbnail');

ChatAttachment _attachment({String id = 'a', int width = 32}) {
  final pixels = image.Image(width: width, height: 24);
  image.fill(pixels, color: image.ColorRgb8(40, 90, 200));
  final jpeg = image.encodeJpg(pixels);
  return ChatAttachment(
    id: id * 64,
    kind: 'image',
    byteLength: jpeg.length,
    thumbnailJpeg: base64Encode(jpeg),
  );
}

Widget _host(ChatAttachment attachment, {double size = 84}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: ChatAttachmentThumbnail(
        key: _thumbnailKey,
        attachment: attachment,
        size: size,
        onTap: () {},
      ),
    ),
  ),
);

MemoryImage _provider(WidgetTester tester) =>
    tester.widget<Image>(find.byType(Image)).image as MemoryImage;

Future<void> _decodeThumbnail(WidgetTester tester) async {
  final provider = _provider(tester);
  await tester.runAsync(() async {
    final ready = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!ready.isCompleted) ready.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!ready.isCompleted) ready.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    try {
      await ready.future;
    } finally {
      stream.removeListener(listener);
    }
  });
  await tester.pump();
  expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
}

void main() {
  testWidgets(
    'decoded thumbnail keeps its image stream and frame through parent rebuilds',
    (tester) async {
      final attachment = _attachment();
      await tester.pumpWidget(_host(attachment));
      await _decodeThumbnail(tester);
      final provider = _provider(tester);
      final frame = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(frame.width, 32);

      for (var tick = 0; tick < 40; tick++) {
        // Database refreshes recreate metadata objects; scroll/fade frames can
        // also rebuild the bubble or resize a composer preview.
        await tester.pumpWidget(
          _host(
            ChatAttachment.fromJson(attachment.toJson()),
            size: tick.isEven ? 84 : 100,
          ),
          duration: const Duration(milliseconds: 16),
        );
        expect(_provider(tester), same(provider));
        expect(
          tester.widget<RawImage>(find.byType(RawImage)).image,
          same(frame),
          reason: 'A rendered thumbnail must never return to an empty frame.',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'replacement clears the old frame and evicts its account-local cache entry',
    (tester) async {
      final first = _attachment();
      await tester.pumpWidget(_host(first));
      await _decodeThumbnail(tester);
      final oldProvider = _provider(tester);

      // A new thumbnail with the same attachment ID must still replace bytes.
      await tester.pumpWidget(_host(_attachment(width: 16)));
      final replacement = _provider(tester);
      expect(replacement, isNot(same(oldProvider)));
      expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isFalse);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(oldProvider).tracked,
        isFalse,
      );
      await _decodeThumbnail(tester);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 16);

      // Reusing the widget for a different record never retains its old frame,
      // even when both thumbnails contain the same pixels.
      await tester.pumpWidget(_host(_attachment(id: 'b', width: 16)));
      expect(_provider(tester), isNot(same(replacement)));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
      await _decodeThumbnail(tester);
      final lastProvider = _provider(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        PaintingBinding.instance.imageCache.statusForKey(lastProvider).tracked,
        isFalse,
      );

      await tester.pumpWidget(_host(first));
      expect(_provider(tester), isNot(same(oldProvider)));
      await _decodeThumbnail(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing a thumbnail replaces it with the placeholder', (
    tester,
  ) async {
    final first = _attachment();
    await tester.pumpWidget(_host(first));
    await _decodeThumbnail(tester);
    final provider = _provider(tester);
    await tester.pumpWidget(
      _host(ChatAttachment(id: first.id, kind: 'image', byteLength: 10)),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    expect(
      PaintingBinding.instance.imageCache.statusForKey(provider).tracked,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
