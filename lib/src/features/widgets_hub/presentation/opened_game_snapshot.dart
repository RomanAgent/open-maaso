import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Reads only the identified visible mobile game player, never a whole screen.
abstract final class OpenedGameSnapshot {
  static const _channel = MethodChannel('maaso/game_snapshot');

  static bool isSupported(WebViewController controller) {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => controller.platform is WebKitWebViewController,
      TargetPlatform.android => controller.platform is AndroidWebViewController,
      _ => false,
    };
  }

  static Future<Uint8List?> capture(WebViewController controller) async {
    if (!isSupported(controller)) return null;
    final platform = controller.platform;
    final identifier = switch (platform) {
      WebKitWebViewController() => platform.webViewIdentifier,
      AndroidWebViewController() => platform.webViewIdentifier,
      _ => null,
    };
    if (identifier == null) return null;
    try {
      final bytes = await _channel
          .invokeMethod<Uint8List>('captureOpenedPlayer', {
            'webViewIdentifier': identifier,
          })
          .timeout(const Duration(seconds: 3));
      return bytes != null && bytes.length <= 256 * 1024 ? bytes : null;
    } on Exception {
      // Cover generation is optional and must never interrupt the game.
      return null;
    }
  }
}
