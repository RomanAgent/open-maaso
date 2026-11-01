import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/media_share_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('maaso/share-test');
  const gateway = PlatformMediaShareGateway(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'media sharing preserves text, existing file, and popover origin',
    () async {
      final directory = await Directory.systemTemp.createTemp('maaso-share-');
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/image.png',
      ).writeAsBytes([1, 2]);
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return true;
      });

      expect(
        await gateway.share(
          text: 'Creator media',
          filePath: ' ${file.path} ',
          origin: const Rect.fromLTWH(12, 24, 48, 48),
        ),
        isTrue,
      );
      expect(received!.method, 'share');
      expect(received!.arguments['text'], 'Creator media');
      expect(received!.arguments['filePath'], file.path);
      expect(received!.arguments['origin'], {
        'left': 12.0,
        'top': 24.0,
        'width': 48.0,
        'height': 48.0,
      });
    },
  );

  test('missing files retain the existing text-only share fallback', () async {
    Map<Object?, Object?>? arguments;
    messenger.setMockMethodCallHandler(channel, (call) async {
      arguments = call.arguments as Map<Object?, Object?>;
      return true;
    });
    expect(
      await gateway.share(text: 'Video link', filePath: '/missing/maaso.mp4'),
      isTrue,
    );
    expect(arguments!['text'], 'Video link');
    expect(arguments!.containsKey('filePath'), isFalse);
    expect(arguments!.containsKey('origin'), isFalse);
  });

  test('platform rejection and unavailable plugin return false', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await gateway.share(text: 'link'), isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await gateway.share(text: 'link'), isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await gateway.share(text: 'link'), isFalse);
    messenger.setMockMethodCallHandler(channel, null);
    expect(await gateway.share(text: 'link'), isFalse);
  });
}
