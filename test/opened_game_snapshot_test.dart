import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/widgets_hub/presentation/opened_game_snapshot.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

class _ExistingWebKitPlayer extends Fake implements WebKitWebViewController {
  @override
  int get webViewIdentifier => 42;
}

class _ExistingAndroidPlayer extends Fake implements AndroidWebViewController {
  @override
  int get webViewIdentifier => 84;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('maaso/game_snapshot');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'captures the existing iOS player identifier without navigating',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final bytes = Uint8List.fromList([255, 216, 255, 217]);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return bytes;
      });
      final controller = WebViewController.fromPlatform(
        _ExistingWebKitPlayer(),
      );
      expect(await OpenedGameSnapshot.capture(controller), bytes);
      expect(calls.single.method, 'captureOpenedPlayer');
      expect(calls.single.arguments, {'webViewIdentifier': 42});
    },
  );

  test(
    'Android uses its existing exact WebView and rejects oversized bytes',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = WebViewController.fromPlatform(
        _ExistingAndroidPlayer(),
      );
      expect(OpenedGameSnapshot.isSupported(controller), isTrue);
      expect(
        OpenedGameSnapshot.isSupported(
          WebViewController.fromPlatform(_ExistingWebKitPlayer()),
        ),
        isFalse,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.arguments, {'webViewIdentifier': 84});
        return Uint8List.fromList([255, 216, 255, 217]);
      });
      expect(await OpenedGameSnapshot.capture(controller), isNotNull);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => Uint8List(256 * 1024 + 1),
      );
      expect(await OpenedGameSnapshot.capture(controller), isNull);
    },
  );

  test('unsupported platforms do not ask for native screenshots', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });
    expect(
      await OpenedGameSnapshot.capture(
        WebViewController.fromPlatform(_ExistingWebKitPlayer()),
      ),
      isNull,
    );
    expect(calls, 0);
  });

  test(
    'a missing or failed snapshot never interrupts an opened game',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'player_closed');
      });
      expect(
        await OpenedGameSnapshot.capture(
          WebViewController.fromPlatform(_ExistingWebKitPlayer()),
        ),
        isNull,
      );
    },
  );
}
